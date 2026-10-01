import 'dart:convert';

import '../data/message_store.dart';
import '../models/draft_policy.dart';
import '../models/extraction_models.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'attention.dart';
import 'conversation_cta.dart';
import 'conversation_state.dart';
import 'decision/needs_you_predicate.dart';
import 'embed_handler.dart';
import 'llm/embeddings_client.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/message_text_task.dart';
import 'reply_policy.dart' show replySuppressed, replyVerdict;
import 'pipeline_progress.dart';
import 'storyline_cards.dart' show clusteringCardFor;

// The card builders moved to `clustering_card.dart` in Round E Phase 1, and
// the row recipe came with them out of `storyline_service.dart` — which is
// what ended the cycle between those two files, each of which used to import
// the other for half of one recipe.
//
// The two BUILDERS are re-exported and the rest is not, on purpose. A dozen
// tests and two fixtures describe the card's shape and have always reached for
// it here, beside the hash they check it with; anything that wants the
// VARIANT, the row recipe or the shipped constant is asking about the vector
// and imports the module by name.
export 'clustering_card.dart' show buildClusteringCard, buildConversationCard;

/// The MESSAGE-TEXT stage: writes one kept message's text, then files it,
/// queues its thread's storyline assign when the thread's card changed,
/// embeds the message for search, and queues its draft.
///
/// One generative call per kept message, [MessageTextTask]: the summary, the
/// reader's action items and the deadline (onto `messages`), and the topics
/// and project (into `extraction_json`, beside the decision model's intent
/// and importance). It runs AFTER triage, which since the decision model is
/// no language-model call at all — so the rail, notify-worthy and filing have
/// the row state within ~100 ms and the text fills in here.
///
/// **The work kind is still `extract`**, and the class keeps its name. A
/// rename would need a work-kind migration of every queued row and a requeue,
/// and would move the activity kind, the progress stage (`extract_state`, which
/// the settle machine waits on) and the activity panel's words with it — all
/// for a label. The kind names the stage's slot in the pipeline, not the task
/// it runs.
///
/// It decides whether a thread's assign is OWED — by the clustering card's
/// hash, since the card is built from the text this stage writes — and
/// queues it, waking the storyline lane per thread. It does not embed the
/// card: the assign pass (`StorylineService._keptVectorFor`) is the one
/// writer of a conversation vector.
///
/// The halves are deliberately unequal. The text is the work and its failure
/// is the item's failure; the message embedding is an optimisation on top,
/// and an embedding server that is down must never cost a message the text
/// that already succeeded.
class ExtractHandler extends WorkHandler {
  static const String _source = 'email';

  /// What a storyline work row is LABELLED with, which is a different thing
  /// from [_source]. The `source` column on those rows is a label and not a
  /// scope — their entity ids are storyline ids, and a storyline spans both
  /// connectors — so a chat message queues its storyline's recap under the
  /// same label a mail message does. See `StorylineService._workSource`, which
  /// is the authority; changing one without the other would strand the rows
  /// the other writes.
  static const String _storylineWorkSource = 'email';

  final MessageStore _store;
  final LlmClient _client;
  final EmbeddingsClient _embeddings;
  final ActivityLog _log;

  /// Where this stage lands for the home screen. Defaulted to the disabled
  /// recorder, so a test that builds this handler writes nothing extra.
  final PipelineProgress _pipeline;

  /// Told the moment a `draft` row is written, so the draft lane can walk.
  ///
  /// Since the drains were split, the draft this handler queues is drained by
  /// a worker that has no idea it was queued. Without this the prefetch would
  /// wait for the fast drain to end — which, on a sixty-message backlog, is
  /// minutes after the extraction that asked for it.
  ///
  /// Null in tests and in the benches that measure the fast lane alone.
  final void Function()? onDraftQueued;

  /// Told the moment a `storyline` (assign) row is written, so the storyline
  /// lane can walk.
  ///
  /// [onDraftQueued]'s reason, for the other lane: since the drains were
  /// split the storyline lane was woken only by the fast drain's `onDrained`,
  /// that is after the WHOLE extraction backlog, so on a replay every assign
  /// waited for every extraction. With this the lane walks as each thread's
  /// card lands.
  ///
  /// Null in tests and in the benches that measure the fast lane alone.
  final void Function()? onStorylineQueued;

  /// When suggested replies are written, read at the moment a message is
  /// finished rather than when this handler was built.
  ///
  /// A CLOSURE and not a value, the `ContextRetriever.selectExpand` shape: the
  /// policy is a SETTING (`AppPrefs.draftPolicy`, Settings › Suggested
  /// replies), and a handler that had captured it would go on prefetching for
  /// the rest of the drain after somebody turned it off.
  ///
  /// Null answers [DraftPolicy.all] — today's pre-gate, byte for byte — so
  /// every test and both benches measure the pipeline they were written
  /// against. The APP passes the pref.
  final DraftPolicy Function()? _draftPolicy;

  /// How many message-text calls may be in flight, read on every claim
  /// (`LlmTargetSpec.textParallel` of the stage's target), so a target change
  /// in Settings takes effect on the next claim. Null answers 3, which every
  /// test and bench keeps.
  final int Function()? _textParallel;

  ExtractHandler(
    this._store,
    this._client,
    this._embeddings, {
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
    this.onDraftQueued,
    this.onStorylineQueued,
    // `this._draftPolicy` and not a plain parameter: the caller still writes
    // `draftPolicy:`, which is what a private field formal is named.
    this._draftPolicy,
    this._textParallel,
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress;

  @override
  String get kind => 'extract';

  /// The target's text width ([_textParallel]), three when nothing says.
  ///
  /// Extraction is a queue whose items are genuinely independent: each reads
  /// one message and writes that message's own row. The two things it touches
  /// beyond that survive being reordered — the bucket filing is guarded to
  /// the thread's newest inbound message, and the recap and assign requeues
  /// are idempotent by construction (`requeueWork` on a key that is already
  /// queued is the same row).
  ///
  /// The width is the target's, not a constant: Your server takes eight
  /// message-text calls (the build's box has sixteen sequences in its
  /// prose-only profile, beside the drafts and the storyline lane, and a
  /// typed address with fewer slots queues the rest), while a small local
  /// server keeps at least three, where past a small batch each request
  /// slows down enough that the first result takes longer to reach the
  /// screen.
  @override
  int get concurrency => _textParallel?.call() ?? 3;

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    await _pipeline.noteExtract(source, id, state: 'running');

    final row = await _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Nothing to extract
    // and nothing wrong — the item is done, not failed. The worker would
    // otherwise write `ok` on a row where no model ran, so it is told
    // `skipped` instead.
    if (row == null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'deleted'});
      await _pipeline.noteExtract(source, id, state: 'skipped');
      // Drafting is enqueued from the end of this method, so an early return
      // is also the last word on whether a reply will ever be suggested. The
      // stage is closed here rather than left `pending`, or the bar would wait
      // forever on work nothing is going to queue.
      await _pipeline.noteDraft(source, id, state: 'skipped');
      return;
    }

    // Queued, then GATED before the worker reached it. Extraction is enqueued
    // at sync time, while every fresh message is still `pending`; triage runs
    // first and flips newsletters, no-reply senders and auto-generated mail to
    // `skipped`. Honouring that verdict here is what keeps a newsletter from
    // costing a model call, growing an embedding, and — since one sender's
    // newsletters are all alike — clustering into a junk storyline
    // suggestion.
    //
    // "Triage runs first" is enforced at the claim now, not hoped for: the
    // worker is not handed an `extract` item at all while its message is
    // `pending` or `processing` (`MessageStore.claimPendingWork`). This check
    // is the belt to that clause's braces, and it still has work to do — an
    // Ignore landing between the claim and this line, and rows enqueued by an
    // older build. The `teams_source` exception is legacy tolerance: chats are
    // triaged like mail now, but a row stored before that change is `skipped`
    // for a reason no judgement stands behind, and a straggler the sync's
    // backfill window missed should still get its facts pulled.
    if (row['triage_status'] == 'skipped' &&
        row['gate_reason'] != 'teams_source') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'gated'});
      await _pipeline.noteExtract(source, id, state: 'skipped');
      await _pipeline.noteDraft(source, id, state: 'skipped');
      // A gated message may be what an older message of its thread was
      // HELD on (see [_queueAssign]): it read as kept while untriaged, and
      // the thread's newest kept message is now that older one, text and
      // all. So the assign check runs here too. This message's own storyline
      // stage was closed by triage's gate cascade, and the check notes only
      // pending stages.
      await _queueAssign(source, row);
      return;
    }

    var message = Message.fromRow(row);
    // Hydrated only when the row says there is something to hydrate —
    // `loadThread` does this for a whole thread; a single-row read has to ask.
    if (row['has_attachments'] == 1) {
      message = message.withAttachments(await _store.attachmentRefsFor(
        source,
        id,
        conversationKey: row['conversation_key'] as String?,
      ));
    }

    // The context the retired triage call read — the attachment names and
    // the thread tail before this message — so the summary can say what an
    // unanswered question a few messages back is still asking.
    final attachments = await _store.attachmentsForMessage(source, id);
    final key = row['conversation_key'] as String?;
    var thread = const <Message>[];
    if (key != null && key.isNotEmpty) {
      final loaded = await _store.loadThread(key, sources: [source]);
      final receivedAt = message.receivedAt ?? '';
      thread = [
        for (final m in loaded)
          if (m.id != message.id &&
              (m.receivedAt ?? '').compareTo(receivedAt) <= 0)
            m,
      ];
    }

    final text = await runTask(
      _client,
      const MessageTextTask(),
      MessageTextInput(
        message,
        DateTime.now(),
        thread: thread,
        attachments: attachments,
      ),
      // Zero, not the default: the same email must yield the same facts twice,
      // or a re-run would move a conversation between clusters for no reason
      // a human could see.
      temperature: 0,
    );
    await _store.writeMessageText(
      source,
      id,
      summary: text.summary,
      actionItems: text.actionItems,
      deadline: text.deadline,
    );
    // Intent and importance are the decision model's (the triage pass stored
    // its answers); a message decided before this build has none, and reads
    // the quiet middle, exactly as a failed extraction used to.
    final decision = await _store.decisionFor(source, id);
    final decided = decision?.answers.fields;
    final result = ExtractionResult(
      topics: text.topics,
      project: text.project,
      intent: decided?['intent']?.choice ?? 'fyi',
      importance: decided?['importance']?.choice ?? 'normal',
    );
    await _store.writeExtraction(source, id, jsonEncode(result.toJson()));

    // Every reader below reads the ROW — the bucket, the card, the message
    // embedding, the draft pre-gates — so it is read again now the text is
    // on it.
    final written = await _store.getMessageRow(source, id) ?? row;

    // The ask lands on the conversation the moment the text does. Only on a
    // row triage decided: an `error` row has no urgency to fold with.
    if (written['triage_status'] == 'triaged') {
      await foldCtaUp(
        _store,
        source,
        written,
        urgency: written['urgency'] as String? ?? 'normal',
        category: written['category'] as String?,
        needsAction: written['needs_action'] == 1,
        summary: text.summary,
        actionItems: text.actionItems,
        deadline: text.deadline,
      );
    }

    // After the writes and before the optional passes below: the text is
    // stored, so the stage is done however the bucket filing, the assign
    // check and the message embedding go.
    await _pipeline.noteExtract(source, id, state: 'done');
    // Enough of the answer to make the activity row readable without opening
    // the message. Counts and labels, never the summary.
    _log.note({
      'intent': result.intent,
      'importance': result.importance,
      'topics': result.topics.take(5).toList(),
      if (result.project.isNotEmpty) 'project': result.project,
      'action_items': text.actionItems.length,
      if (text.deadline.isNotEmpty) 'deadline': text.deadline,
    });

    await _fileBucket(source, written, result);
    await _queueRecap(source, written);
    await _queueAssign(source, written);
    await _embedMessage(source, written);
    await _queueDraft(source, id, written);
  }

  /// Wakes the running recap of every storyline this message's thread is
  /// filed in.
  ///
  /// The one storyline trigger that has nothing to do with membership. The
  /// assignment queue next door asks "does this thread belong somewhere?" and
  /// runs off the thread's embedding; this asks nothing — a message landing in
  /// a thread that is ALREADY in a storyline changes where that storyline
  /// stands, whether or not its vector moved, and the recap is what a user
  /// opens the storyline to read.
  ///
  /// Not behind any embedding: an embedding server that is down must not cost
  /// the recap a message. The requeue is idempotent by construction —
  /// `requeueWork` is keyed on `(kind, source, entity_id)` — so a storyline
  /// whose threads take ten messages in one drain gets one recap, which is
  /// also the pass reading the whole burst at once instead of ten times.
  ///
  /// Nothing here may throw: the extraction is already stored by the time it
  /// runs, and a failure would re-run the model call that succeeded.
  Future<void> _queueRecap(String source, Map<String, Object?> row) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    for (final storylineId in await _store.storylineIdsFor(source, key)) {
      if (storylineId.isEmpty) continue;
      await _store.requeueWork(
        'storyline_recap',
        _storylineWorkSource,
        storylineId,
      );
    }
  }

  /// Queues this message's thread for the storyline assign, if what the
  /// thread says about itself actually changed — and closes the storyline
  /// stage here when it did not.
  ///
  /// Runs AFTER `writeExtraction`, and that ordering is load-bearing: the
  /// card is built from the STORED facts (`clusteringCardFor`, the one entry
  /// the assign pass builds through), so the topics and summary this
  /// extraction just wrote are in it, and the hash compared here is the hash
  /// the assign pass writes. No embedding happens here: the assign pass
  /// (`StorylineService._keptVectorFor`) is the one writer of a conversation
  /// vector, and this only decides whether the pass is owed.
  ///
  /// Nothing here may throw: the extraction is already stored by the time it
  /// runs, and an item marked failed here would be re-run — spending a model
  /// call to redo work that succeeded — to retry a queue write.
  Future<void> _queueAssign(String source, Map<String, Object?> row) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = await _store.getConversationRow(source, key);
    if (conversation == null) {
      // No thread to group means no pass will ever be queued for it, and a
      // stage nobody is going to write must not read as owed: the settle
      // machine waits on this column, and it would wait out its deadline.
      await _pipeline.noteStoryline(source, key, state: 'skipped');
      return;
    }

    // HELD while the thread's NEWEST kept inbound message has no text yet
    // and its text is still COMING — it is untriaged (`pending` or
    // `processing`: an untriaged message reads as kept), or its `extract`
    // row is `pending` or `processing`. When an older message of the thread
    // is what just finished (the text claim order is not recency, and eight
    // run at once), the card would otherwise be built without the newest
    // message's summary and topics — the pre-extraction card the ledger
    // measured and rejected (45–47/98 on `make golden-sweep` against 60).
    // Nothing is queued and nothing is noted; the hold releases when that
    // newest message's own extract item runs: its extraction calls this, and
    // so does its gated early return if triage drops it meanwhile (the older
    // message is then the newest kept, text and all). Either pass closes this
    // message's storyline stage too, because `noteStoryline` is per
    // conversation. A newest message whose text is NOT coming (its extract
    // row ended `error` or `skipped`, or was never queued) holds nothing:
    // the assign runs on the card there is, as it did before the hold. The
    // one hold nothing releases is a newest message whose extraction ends in
    // a terminal `error` AFTER an older message was held: no pass runs for
    // it, so the thread is not assigned until its next message arrives —
    // rare, and no worse than that errored extraction already is.
    final newest = await _store.clusteringCardData(source, key);
    if (newest != null &&
        newest['summary'] == null &&
        newest['extraction_json'] == null &&
        await _textComing(source, newest)) {
      return;
    }

    final card = await clusteringCardFor(_store, source, key, conversation);
    final hash = cardHash(card);

    // The whole reason a hash is stored: re-extracting the same thread's
    // tenth message must not spend an assign pass (and its embedding call)
    // to arrive at the same vector. The tag is the other half, exactly as in
    // `EmbedHandler`'s message corpus: the hash says the CARD has not
    // changed, the tag says the stored vector was taken over the card this
    // build builds, so a tag bump still queues the pass.
    final stored = await _store.getConversationAi(source, key);
    if (stored != null &&
        stored['embedded_hash'] == hash &&
        stored['embed_model'] == EmbeddingsClient.modelTag) {
      // The same vector is the same answer, so the pass is not queued — and
      // the stage is closed HERE, with the storyline the thread already sits
      // in, because nothing else would ever write it for this message. The
      // settle machine reads this column; left `pending`, a reply that
      // changed nothing about its thread's card would wait out the six-minute
      // deadline before the user heard about it, and its outcome would never
      // close at all.
      await _pipeline.noteStoryline(
        source,
        key,
        state: 'done',
        storylineId: await _pipeline.assignedStorylineId(source, key),
      );
      return;
    }

    // A REQUEUE rather than an enqueue: what a thread should be grouped with
    // is a function of its card, so every time that changes the answer may
    // change with it, and `enqueueWork` would ignore the row after the first
    // time it ran. Queued whatever the embedding server is doing: the pass
    // parks on a down server and embeds the thread when it is back.
    await _store.requeueWork('storyline', source, key);
    // After the row exists, never before it, and guarded, for
    // [_enqueueDraft]'s reasons.
    try {
      onStorylineQueued?.call();
    } catch (_) {}
  }

  /// Whether the text of the message [newest] describes (a
  /// `newestInboundCardData` map) is still on its way: triage has not spoken
  /// on it, or its `extract` row is waiting or at the server.
  Future<bool> _textComing(String source, Map<String, Object?> newest) async {
    const open = {'pending', 'processing'};
    if (open.contains(newest['triage_status'])) return true;
    final id = newest['source_message_id'] as String?;
    if (id == null) return false;
    return open.contains(await _store.workStatusOf('extract', source, id));
  }

  /// Puts this message in front of the drafting model, or closes its draft
  /// stage without one.
  ///
  /// Which of those happens is the user's setting — [DraftPolicy], read
  /// through [_draftPolicy] at this moment rather than when the handler was
  /// built:
  ///
  /// * [DraftPolicy.onDemand] queues nothing (`on_demand`). **Draft reply**
  ///   still works on every thread, so the reply is a keypress away rather
  ///   than absent.
  /// * [DraftPolicy.needsYou] — the default — queues only what
  ///   [prefetchWorthy] admits (`not_prefetched` otherwise), and only while
  ///   fewer than [DraftPolicy.prefetchCap] drafts are already in flight
  ///   (`prefetch_cap` once there are).
  /// * [DraftPolicy.all] is the pre-round behaviour: [asksForAReply] and
  ///   nothing else.
  ///
  /// Whatever the mode, a message that is not queued is `skipped`, not left
  /// waiting: no work row will ever be written for it, and a progress bar that
  /// waited would wait forever. The reason goes on the activity row, which is
  /// the only place there is to put it — the progress row has no reason column.
  Future<void> _queueDraft(
    String source,
    String id,
    Map<String, Object?> row,
  ) async {
    final policy = _draftPolicy?.call() ?? DraftPolicy.all;

    if (policy == DraftPolicy.onDemand) {
      return _skipDraft(source, id, 'on_demand');
    }

    // Ahead of every mode, because it is not a preference: a message a machine
    // wrote has nobody waiting for an answer, and drafting one is work spent to
    // produce a reply the owner could only delete. [replySuppressed] is the one
    // authority on that question — the same one `draft_handler.dart` and
    // `DraftState.suggestable` ask — so the three cannot drift into offering a
    // reply the other two refuse.
    //
    // It sits in `_queueDraft` rather than inside [asksForAReply] or
    // [prefetchWorthy] deliberately: those two are pure readings of the row's
    // own cues, and folding a second question into them would make "did this
    // message ask for something" answer "and is anybody there to ask".
    if (replySuppressed(Message.fromRow(row))) {
      return _skipDraft(source, id, 'automated_sender');
    }

    // The reply decision, ahead of every mode for the same reason: it is the
    // judgement the draft handler would apply first, so a message it says
    // needs no reply is never queued — it cannot take a
    // [DraftPolicy.prefetchCap] slot or cost a queue row. [replyVerdict] is the one rule;
    // the handler asks it again for queue rows written before this existed.
    // A person's **Draft reply** never comes through here.
    final verdict = replyVerdict(
      replyExpectedP: (await _store.decisionFor(source, id))?.replyExpectedP,
      storedReplyExpected: row['reply_expected'],
    );
    if (verdict.skipWhy != null) {
      return _skipDraft(source, id, 'no_reply_needed');
    }

    // The owner's slider, read at this moment like the policy above, so the
    // draft gates judge a message against the number the rail reads.
    final threshold = await _store.needsYouThreshold();

    if (policy == DraftPolicy.all) {
      if (!asksForAReply(row, threshold: threshold)) {
        return _skipDraft(source, id, 'no_cue');
      }
      return _enqueueDraft(source, id);
    }

    // [DraftPolicy.needsYou]: the narrow pre-gate first, because it is free,
    // and the count only for the messages that passed it.
    if (!prefetchWorthy(row, threshold: threshold)) {
      return _skipDraft(source, id, 'not_prefetched');
    }

    // Every source the draft lane drains, not `workCounts`' `['email']`
    // default: a chat is drafted for exactly as mail is, and counting only
    // mail would let a Teams backlog queue an unbounded number of drafts under
    // a cap that could not see them.
    final counts = await _store.workCounts('draft', sources: AiWorker.sources);
    final inFlight = (counts['pending'] ?? 0) + (counts['processing'] ?? 0);
    // SOFT, and deliberately so, in two ways. This handler drains three wide,
    // so three items can read the same count before any of them has written
    // its row and the real ceiling is twelve. And `error` rows are not in
    // flight by this count, though `reviveErroredWork` can put a batch of them
    // back into `pending` in one pass and lift the true number past ten for as
    // long as that pass takes. Both are acceptable on a number whose whole job
    // is "ten, not sixty"; a hard cap would want a transaction around a queue
    // insert to buy two drafts' worth of precision.
    if (inFlight >= DraftPolicy.prefetchCap) {
      return _skipDraft(source, id, 'prefetch_cap');
    }
    return _enqueueDraft(source, id);
  }

  /// One draft row, and the lane that drains it woken.
  Future<void> _enqueueDraft(String source, String id) async {
    await _store.enqueueWork('draft', source, id);
    // After the row exists, never before it: the callback pumps the draft
    // lane, and a lane woken ahead of the write would drain an empty queue
    // and go back to sleep. Guarded like every other lane-waking callback
    // (`AiWorker._fireDrained`): the row is stored and the extraction is
    // done, so a container torn down under the closure must not turn a
    // finished item into a retry of a model call that already succeeded.
    try {
      onDraftQueued?.call();
    } catch (_) {}
  }

  /// This message will never be drafted for, and its stage says so.
  ///
  /// The progress row closes the stage — `skipped` is terminal, so the message
  /// settles exactly as a "no reply needed" one does — and the activity row
  /// carries [reason], which is the only place a reason can go.
  Future<void> _skipDraft(String source, String id, String reason) async {
    await _pipeline.noteDraft(source, id, state: 'skipped');
    _log.note({'draft': reason});
  }

  /// Gives this ONE message its search vector, while the row is already in
  /// hand.
  ///
  /// The fast path for search: by the time a message has been extracted it is
  /// also findable, with no second queue having had to drain first. The
  /// extraction is already stored, so nothing here may throw and turn a
  /// succeeded item into a retried one, and there is no requeue. The
  /// `embed_message` queue enqueued at sync time IS the healing path, and it
  /// parks on the same unreachable server until `make embed` is running, so
  /// queueing anything from here would only be a second name for the same
  /// wait.
  ///
  /// The summary it embeds is the one this handler just wrote onto the
  /// message ROW, read back from the row rather than taken from the result in
  /// hand: the card has to be buildable from the message row alone, or
  /// [EmbedHandler] could not produce the same card without re-running the
  /// text call to get it.
  Future<void> _embedMessage(String source, Map<String, Object?> row) async {
    final outcome = await embedMessageRow(_store, _embeddings, source, row);
    if (outcome == MessageEmbedOutcome.unavailable) {
      _log.note({'message_embed': 'unavailable'});
    }
    if (outcome == MessageEmbedOutcome.rejected) {
      _log.note({'message_embed': 'rejected'});
    }
  }

  /// Files this message's thread into Later, or out of it, the moment the model
  /// has read it.
  ///
  /// The scoring sweep would reach the same answer on the next list load, so
  /// this is purely about when: extraction runs behind a queue that can be
  /// minutes deep, and without this a message would appear in the inbox, sit
  /// there, and then jump to Later while the user was reading the list. Filing it
  /// as the fact lands means the row is only ever drawn once, where it belongs.
  ///
  /// It shares [bucketFor] with the sweep rather than reimplementing the rule —
  /// two copies would drift, and the symptom would be a thread that changes
  /// bucket depending on which pass ran last.
  Future<void> _fileBucket(
    String source,
    Map<String, Object?> row,
    ExtractionResult result,
  ) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = await _store.getConversationRow(source, key);
    if (conversation == null) return;

    // Only the thread's newest inbound message gets to file it. The queue
    // drains newest-first but a backlog can still hand this handler a month-old
    // message, and letting that one decide would file the thread on what its
    // conversation stopped being about.
    final receivedAt = row['received_at'] as String?;
    if (receivedAt == null ||
        receivedAt != conversation['last_inbound_at'] as String?) {
      return;
    }

    // A bucket a person asked for is never re-decided here. `sender_pref` and
    // `user` are both written by an explicit correction, and the automatic pass
    // does not get to overrule someone by arriving later.
    final stored = await _store.getConversationAi(source, key);
    final reason = stored?['bucket_reason'] as String?;
    if (reason == 'user' || reason == 'sender_pref') return;

    final senderPref =
        await _store.getSenderPref(row['from_address'] as String? ?? '');
    // Asked about the THREAD, not about this row's own probability: the
    // message being filed on can be a quiet FYI while an older message in the
    // same thread is still an unanswered ask, and the thread is the unit being
    // filed.
    //
    // Triage writes this message's probability before extraction can claim
    // it, so it is normally on the row by the time this runs. When it is not,
    // the attention sweep on the next list load asks the same question again
    // and corrects the bucket.
    final openAsk = await _store.hasOpenAsk(
      source,
      key,
      threshold: await _store.needsYouThreshold(),
    );
    final bucket = bucketFor(
      senderPref: senderPref,
      intent: result.intent,
      importance: result.importance,
      needsReply: (conversation['state'] as String?) == 'needs_reply',
      needsYou: openAsk,
    );

    if (bucket != null) {
      await _store.setConversationBucket(
        source,
        key,
        bucket: bucket,
        reason: bucketReasonFor(senderPref),
      );
    } else if (reason == 'low_value') {
      // The thread earned its way back: a message that is no longer low-value
      // clears the guess this pass made last time, and nothing else.
      await _store.setConversationBucket(source, key, bucket: null);
    }
  }
}

/// Whether a stored message looks, on its own row, like something the user
/// might have to answer.
///
/// This is [DraftPolicy.all]'s pre-gate — one of three policies, and the
/// widest of them. It is a PRE-GATE and nothing more: whether a suggestion is
/// written is the decision model's reply probability ([replyVerdict], asked in
/// `_queueDraft` before this and again by the draft handler), and this only
/// decides which of the messages it let through are worth drafting for. [prefetchWorthy] is the narrower gate
/// [DraftPolicy.needsYou] uses, and under [DraftPolicy.onDemand] neither runs.
/// If this proves too tight for someone who has chosen `all`, this is the line
/// to widen: the false negatives are silent, and a message it drops is never
/// drafted for at all.
///
/// Five signals, and any one of them is enough: the message needs the owner
/// at [threshold] ([needsYouAt] over its `needs_you_p`), the sender is
/// waiting, the reader has to do something, the message is loud, or it names a
/// date. Read off the row rather than re-judged, because the point is to be
/// cheap — the expensive work is the draft this gate decides whether to spend.
///
/// The first is the odd one out: the other four are the fast triage's fields
/// ABOUT the message, while `needs_you_p` is the decision model's answer about
/// the message as a whole, and it is what puts a message in front of the
/// drafting model when triage saw no reply cue at all. An undecided message
/// (NULL) adds nothing, and the gate degrades to the four-signal shape.
///
/// Outbound mail answers false. The user's own message needs no reply from
/// them, and extraction only ever sees inbound rows anyway, so this is a guard
/// rather than a case.
///
/// The flags come back as INTEGERs — sqlite has no bool, and a STRICT column
/// holds 0 or 1 — so each is compared against 1 rather than trusted to be
/// truthy.
bool asksForAReply(Map<String, Object?> row, {required double threshold}) {
  if (row['direction'] != 'inbound') return false;
  return needsYouAt((row['needs_you_p'] as num?)?.toDouble(), threshold) ||
      row['reply_expected'] == 1 ||
      row['needs_action'] == 1 ||
      row['urgency'] == 'urgent' ||
      row['urgency'] == 'high' ||
      (row['deadline'] as String?)?.isNotEmpty == true;
}

/// Whether a stored message is worth the drafting model's IDLE time — the
/// narrower pre-gate [DraftPolicy.needsYou] uses.
///
/// ONE signal where [asksForAReply] takes five: the message needs the owner at
/// [threshold] ([needsYouAt]), the same predicate Needs You itself is. The
/// four it drops fire on ordinary mail: `reply_expected` is triage's guess
/// from one message in isolation, `needs_action` is its guess that something
/// is to be done, which a receipt and a reminder both trip, a `deadline` is a
/// date the message mentions, which a calendar invitation and a newsletter
/// both carry, and an urgency word is triage's loudness, which the needs-you
/// probability already reads. What is left is exactly the Needs You pile,
/// which is the set worth having an answer ready for before they ask.
///
/// It is not a second opinion about whether a reply is warranted; the decision
/// model's reply probability decides that ([replyVerdict]). It decides which
/// messages get a draft written without anyone having pressed a button.
///
/// [asksForAReply]'s disciplines, for its reasons: outbound answers false, and
/// the flags are INTEGERs compared against 1 rather than trusted to be truthy.
bool prefetchWorthy(Map<String, Object?> row, {required double threshold}) {
  if (row['direction'] != 'inbound') return false;
  return needsYouAt((row['needs_you_p'] as num?)?.toDouble(), threshold);
}

/// How much of a message body reaches its embedding.
///
/// A vector is an average, and averaging over four thousand characters of
/// quoted thread, signature and legal footer produces a vector about email in
/// general rather than about this message. The first 1500 characters are where
/// a person says the thing they wrote to say; everything past that is usually
/// what someone else already said.
const int messageCardBodyCap = 1500;

/// The text ONE MESSAGE is embedded from — the search corpus, where
/// [buildConversationCard] builds the clustering corpus.
///
/// Always four segments joined by ` | `, empty ones included, for the same
/// reason the conversation card is: a fixed shape means the same message
/// produces the same card twice, which is what makes [cardHash] a usable "has
/// anything changed" test. Order runs from most to least stable — subject, who
/// sent it, what triage said it was, what it actually says — so a long body
/// cannot drown out the two lines that identify the message.
String buildMessageCard({
  required String? subject,
  required String sender,
  required String? summary,
  required String? body,
}) {
  final text = (body ?? '').trim();
  final clipped =
      text.length > messageCardBodyCap ? text.substring(0, messageCardBodyCap) : text;
  return [
    stripReFw(subject),
    sender.trim(),
    summary?.trim() ?? '',
    clipped,
  ].join(' | ');
}

/// A cheap content hash: the card's length, then FNV-1a over its UTF-8 bytes.
///
/// FNV-1a and not SHA-256 because nothing adversarial rides on this. It is
/// compared only against the previous card of the SAME conversation, and the
/// cost of the one-in-2^64 collision is a stale embedding on one thread. The
/// length prefix is free and catches the truncations a hash alone would not
/// make obvious in a database dump.
String cardHash(String card) {
  const int prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(card)) {
    hash ^= byte;
    // Dart's int is 64-bit two's complement on this platform and multiplication
    // wraps, which is exactly the arithmetic FNV-1a specifies.
    hash = hash * prime;
  }
  final high = (hash >> 32) & 0xFFFFFFFF;
  final low = hash & 0xFFFFFFFF;
  return '${card.length}-'
      '${high.toRadixString(16).padLeft(8, '0')}'
      '${low.toRadixString(16).padLeft(8, '0')}';
}
