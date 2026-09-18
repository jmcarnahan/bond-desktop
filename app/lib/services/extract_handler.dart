import 'dart:convert';

import '../data/message_store.dart';
import '../models/draft_policy.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'attention.dart';
import 'conversation_state.dart';
import 'embed_handler.dart';
import 'llm/embeddings_client.dart';
import 'llm/extract_task.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'pipeline_progress.dart';
// `show`: the clustering card, which this file and `StorylineService._reembed`
// both write. One recipe over one data source, so the two cannot drift apart
// and the hash column means one thing.
import 'storyline_service.dart' show clusteringCardForConversationRow;

/// Extracts structured facts from one message, then refreshes its thread's
/// embedding if the thread now reads differently.
///
/// The two halves are deliberately unequal. The extraction is the work and its
/// failure is the item's failure; the embedding is an optimisation on top, and
/// an embedding server that is down must never cost a message the extraction
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
  /// `AttachmentDigestHandler.onRequeue`'s shape, and the same reason in a
  /// different lane: since the drains were split, the draft this handler
  /// queues is drained by a worker that has no idea it was queued. Without
  /// this the prefetch would wait for the fast drain to end — which, on a
  /// sixty-message backlog, is minutes after the extraction that asked for it.
  ///
  /// Null in tests and in the benches that measure the fast lane alone.
  final void Function()? onDraftQueued;

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

  ExtractHandler(
    this._store,
    this._client,
    this._embeddings, {
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
    this.onDraftQueued,
    // `this._draftPolicy` and not a plain parameter: the caller still writes
    // `draftPolicy:`, which is what a private field formal is named.
    this._draftPolicy,
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress;

  @override
  String get kind => 'extract';

  /// Three at a time, where every other kind is one.
  ///
  /// Extraction is the one queue whose items are genuinely independent: each
  /// reads one message and writes that message's own row. The two things it
  /// touches beyond that survive being reordered — the bucket filing is
  /// guarded to the thread's newest inbound message, the embedding refresh is
  /// last-writer-wins exactly as it already was under the serial drain (the
  /// stored hash makes a repeat free, so the next extraction self-heals it),
  /// and the storyline requeue is idempotent by construction (`requeueWork`
  /// on a key that is already queued is the same row).
  ///
  /// Three and not more: it is the batch the fast server is started with slots
  /// for (`FAST_SLOTS`), and past a small batch each individual request slows
  /// down enough that the first result takes longer to reach the screen.
  @override
  int get concurrency => 3;

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

    final result = await runTask(
      _client,
      const ExtractTask(),
      ExtractionInput(message, DateTime.now()),
      // Zero, not the default: the same email must yield the same facts twice,
      // or a re-extraction would move a conversation between clusters for no
      // reason a human could see.
      temperature: 0,
    );
    await _store.writeExtraction(source, id, jsonEncode(result.toJson()));
    // After the write and before the two optional passes below: the facts are
    // stored, so the stage is done however the bucket filing and the embedding
    // refresh go.
    await _pipeline.noteExtract(source, id, state: 'done');
    // Enough of the answer to make the activity row readable without opening
    // the extraction itself. Five topics, because the row is one line.
    _log.note({
      'intent': result.intent,
      'importance': result.importance,
      'topics': result.topics.take(5).toList(),
      if (result.project.isNotEmpty) 'project': result.project,
    });

    await _fileBucket(source, row, result);
    await _refreshCard(source, row);
    await _queueRecap(source, row);
    await _embedMessage(source, row);
    await _queueDraft(source, id, row);
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
  /// Deliberately outside [_refreshCard], and not behind a successful embed:
  /// an embedding server that is down must not cost the recap a message. The
  /// requeue is idempotent by construction — `requeueWork` is keyed on
  /// `(kind, source, entity_id)` — so a storyline whose threads take ten
  /// messages in one drain gets one recap, which is also the pass reading the
  /// whole burst at once instead of ten times.
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

    if (policy == DraftPolicy.all) {
      if (!asksForAReply(row)) return _skipDraft(source, id, 'no_cue');
      return _enqueueDraft(source, id);
    }

    // [DraftPolicy.needsYou]: the narrow pre-gate first, because it is free,
    // and the count only for the messages that passed it.
    if (!prefetchWorthy(row)) return _skipDraft(source, id, 'not_prefetched');

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
  /// also findable, with no second queue having had to drain first. It carries
  /// [_refreshCard]'s hard constraint — the extraction is already stored, so
  /// nothing here may throw and turn a succeeded item into a retried one — and
  /// drops one of its habits: there is no requeue. The `embed_message` queue
  /// enqueued at sync time IS the healing path, and it parks on the same
  /// unreachable server until `make embed` is running, so queueing anything
  /// from here would only be a second name for the same wait.
  ///
  /// The summary it embeds is TRIAGE's, not this handler's extraction output.
  /// That is deliberate: the card has to be buildable from the message row
  /// alone, or [EmbedHandler] could not produce the same card without
  /// re-running an extraction to get it.
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
    // Asked about the THREAD, not about this row's own verdict: the message
    // being filed on can be a quiet FYI while an older message in the same
    // thread is still an unanswered ask, and the thread is the unit being
    // filed.
    //
    // Needs-you drains ahead of extract in the same pass (see the handler
    // order in `app_providers.dart`), so this message's own verdict is
    // normally already written by the time this runs. When it is not — a
    // needs-you row that parked on an unreachable server, say — the attention
    // sweep on the next list load asks the same question again and corrects
    // the bucket.
    final openAsk = await _store.hasOpenAsk(source, key);
    final bucket = bucketFor(
      senderPref: senderPref,
      intent: result.intent,
      importance: result.importance,
      needsReply: (conversation['state'] as String?) == 'needs_reply',
      needsYouVerdict: openAsk,
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

  /// Re-embeds this message's thread, if what the thread says about itself
  /// actually changed.
  ///
  /// Every way this can fail returns quietly, and that is a constraint rather
  /// than a preference: the extraction is already stored by the time it runs,
  /// and an item marked failed here would be re-run — spending a model call to
  /// redo work that succeeded — to retry an optimisation. Nothing below may
  /// throw.
  ///
  /// The storyline requeue is the part that has to survive an embedding server
  /// being down. It used to sit behind a successful embed, which made a
  /// missing server a silent DROP: no vector, no requeue, and the thread was
  /// never considered for a storyline again until something else happened to
  /// re-extract it. Now an unreachable server still queues the work and lets
  /// the storyline pass park on it — which is the one thing that gets the
  /// thread looked at again once `make embed` is running.
  /// Runs AFTER `writeExtraction`, and that ordering is load-bearing now that
  /// the card is built from the stored facts rather than from the result in
  /// hand: `newestInboundCardData` has to be able to read the topics this
  /// extraction just wrote.
  Future<void> _refreshCard(String source, Map<String, Object?> row) async {
    final key = row['conversation_key'] as String?;
    if (key == null || key.isEmpty) return;
    final conversation = await _store.getConversationRow(source, key);
    if (conversation == null) {
      // No thread to group means no pass will ever be queued for it, and a
      // stage nobody is going to write must not read as owed: the settle
      // machine now waits on this column, and it would wait out its deadline.
      await _pipeline.noteStoryline(source, key, state: 'skipped');
      return;
    }

    // One recipe over one data source. The extraction was written a few lines
    // above, so `newestInboundCardData` already returns this message's topics
    // when this message IS the thread's newest kept inbound, and the older
    // message's when it is not — which is the point. `StorylineService._reembed`
    // heals a missing vector from exactly this call, and while these two built
    // their cards out of different things they could write the same
    // `embedded_hash` column for two different texts: extracting the fifth
    // message of a thread would store a hash over a card nothing else would
    // ever produce, and the next heal would re-embed a thread that had not
    // changed. One thread has one card.
    final card = clusteringCardForConversationRow(
      conversation,
      await _store.newestInboundCardData(source, key),
    );
    final hash = cardHash(card);

    // The whole reason a hash is stored: re-extracting the same thread's tenth
    // message must not spend an embedding call to arrive at the same vector.
    //
    // The tag is half of that question, exactly as it is in `EmbedHandler`'s
    // message corpus. The hash says the CARD has not changed; the tag says the
    // stored vector was taken over the card this build builds. Without it a
    // tag bump — a card change, which is what bumps it — would leave every
    // re-extracted thread whose card happened not to change carrying an
    // orphaned vector forever, invisible to a sweep that filters on the tag.
    final stored = await _store.getConversationAi(source, key);
    if (stored != null &&
        stored['embedded_hash'] == hash &&
        stored['embed_model'] == EmbeddingsClient.modelTag) {
      // The same vector is the same answer, so the pass is not queued — and
      // the stage is closed HERE, with the storyline the thread already sits
      // in, because nothing else would ever write it for this message. The
      // settle machine reads this column now; left `pending`, a reply that
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

    final embedded = await _embeddings.embedResult(card);
    final vector = embedded.vector;
    if (vector == null) {
      // Either way the old embedding and the old hash are left alone, so the
      // next pass tries again. What differs is whether there is anything to
      // try FOR: a server that is not running will have a vector for this
      // thread later, so the storyline pass is queued now and parks until it
      // does; a server that answered nonsense will answer the same nonsense
      // next time, and queueing a pass that can only park is worse than
      // nothing.
      if (embedded.outcome == EmbedOutcome.unavailable) {
        _log.note({'embed': 'unavailable'});
        await _store.requeueWork('storyline', source, key);
      } else {
        _log.note({'embed': 'rejected'});
        // No pass is coming for a vector the server refused, so the stage is
        // closed as skipped rather than left owed — see the unchanged-card
        // branch above for why an owed stage nobody will write is worse.
        await _pipeline.noteStoryline(source, key, state: 'skipped');
      }
      return;
    }

    await _store.upsertConversationAi(
      source,
      key,
      embedding: encodeEmbedding(vector),
      embeddedHash: hash,
      embedModel: EmbeddingsClient.modelTag,
    );

    // Only after a vector actually landed, and a REQUEUE rather than an
    // enqueue: what a thread should be grouped with is a function of its
    // embedding, so every time that changes the answer may change with it.
    // `enqueueWork` would ignore the row after the first time it ran, which
    // would mean each thread is only ever considered on its first message.
    await _store.requeueWork('storyline', source, key);
  }

}

/// Whether a stored message looks, on its own row, like something the user
/// might have to answer.
///
/// This is [DraftPolicy.all]'s pre-gate — one of three policies, and the
/// widest of them. It is a PRE-GATE and nothing more: the verdict that decides
/// whether a suggestion is written comes from the big model behind the draft
/// queue, which reads the whole conversation, and this only decides which
/// messages are worth asking about. [prefetchWorthy] is the narrower gate
/// [DraftPolicy.needsYou] uses, and under [DraftPolicy.onDemand] neither runs.
/// If this proves too tight for someone who has chosen `all`, this is the line
/// to widen: the false negatives are silent, and a message it drops is never
/// drafted for at all.
///
/// Five signals, and any one of them is enough: the needs-you stage read the
/// message and called it the user's to answer, the sender is waiting, the
/// reader has to do something, the message is loud, or it names a date. Read
/// off the row rather than re-judged, because the point is to be cheap — the
/// expensive judgement is the model call this gate decides whether to spend.
///
/// The first is the odd one out: the other four are the fast triage's fields
/// ABOUT the message, while `needs_you_verdict` is the needs-you stage's answer
/// about the message as a whole. It is on the row here because NeedsYouHandler
/// is registered ahead of ExtractHandler in the worker precisely so its verdict
/// is written before this reads it, and it is what puts a message in front of
/// the drafting model when triage saw no reply cue at all. NULL — the handler
/// errored, or never ran — and 0 change nothing, and the gate degrades to
/// exactly the four-signal shape it had.
///
/// Outbound mail answers false. The user's own message needs no reply from
/// them, and extraction only ever sees inbound rows anyway, so this is a guard
/// rather than a case.
///
/// The flags come back as INTEGERs — sqlite has no bool, and a STRICT column
/// holds 0 or 1 — so each is compared against 1 rather than trusted to be
/// truthy.
bool asksForAReply(Map<String, Object?> row) {
  if (row['direction'] != 'inbound') return false;
  return row['needs_you_verdict'] == 1 ||
      row['reply_expected'] == 1 ||
      row['needs_action'] == 1 ||
      row['urgency'] == 'urgent' ||
      row['urgency'] == 'high' ||
      (row['deadline'] as String?)?.isNotEmpty == true;
}

/// Whether a stored message is worth the drafting model's IDLE time — the
/// narrower pre-gate [DraftPolicy.needsYou] uses.
///
/// Two signals where [asksForAReply] takes five, and the three it drops are
/// the ones that fire on ordinary mail: `reply_expected` is triage's guess from
/// one message in isolation, `needs_action` is its guess that something is to
/// be done, which a receipt and a reminder both trip, and a `deadline` is a
/// date the message mentions, which a calendar invitation and a newsletter
/// both carry. What is left is
/// the needs-you stage's whole-message verdict and triage's loudness — the
/// messages a person would have opened first anyway, which is exactly the set
/// worth having an answer ready for before they ask.
///
/// It is not a second opinion about whether a reply is warranted; the big
/// model still decides that behind the queue. It decides which messages get
/// asked about without anyone having pressed a button.
///
/// [asksForAReply]'s disciplines, for its reasons: outbound answers false, and
/// the flags are INTEGERs compared against 1 rather than trusted to be truthy.
bool prefetchWorthy(Map<String, Object?> row) {
  if (row['direction'] != 'inbound') return false;
  return row['needs_you_verdict'] == 1 ||
      row['urgency'] == 'urgent' ||
      row['urgency'] == 'high';
}

/// The text a conversation is embedded from.
///
/// Always four segments joined by ` | `, empty ones included: the shape is
/// fixed so the same thread produces the same card twice, which is what makes
/// [cardHash] a usable "has anything changed" test. Order runs from most to
/// least stable — subject, who is on it, what it is about, what was last said
/// — so a passing remark moves the vector less than a change of topic.
String buildConversationCard({
  required String? subject,
  required List<String> participants,
  required List<String> topics,
  required String? summary,
}) =>
    [
      subject?.trim() ?? '',
      participants.join(', '),
      topics.join(', '),
      summary?.trim() ?? '',
    ].join(' | ');

/// The text a conversation is EMBEDDED from, which is [buildConversationCard]
/// with one decision folded in: whether the people on the thread are part of
/// the vector.
///
/// The one recipe for the clustering corpus, and the reason it exists apart
/// from the card builder is that the card builder has other readers. The
/// naming and membership PROMPTS read a card too, and they keep their people
/// whatever this flag says — who is on a thread is the strongest thing a
/// model can be told about it. The vector is the opposite case: in a mailbox
/// where one team is on everything, the same names in every card pull every
/// pair of threads together, and the sweep then proposes the team rather than
/// the work. Round D Phase 1 measures both variants through `make
/// golden-sweep` (`SWEEP_CARD=participants|topics`); `StorylineTuning
/// .participantsInClusteringCard` is what the app passes.
///
/// Dropping the people leaves the segment EMPTY rather than removing it: the
/// card is four ` | `-joined segments by contract, and a three-segment card
/// would make [cardHash] disagree with itself about nothing.
String buildClusteringCard({
  required String? subject,
  required List<String> participants,
  required List<String> topics,
  required String? summary,
  required bool withParticipants,
}) =>
    buildConversationCard(
      subject: subject,
      participants: withParticipants ? participants : const [],
      topics: topics,
      summary: summary,
    );

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
