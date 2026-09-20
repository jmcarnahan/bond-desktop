import 'dart:convert';
import 'dart:typed_data';

import '../data/message_store.dart';
import '../models/draft_provenance.dart';
import '../models/draft_request.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'attachments/attachment_markers.dart';
import 'attachments/attachment_retriever.dart';
import 'cloud_drafts.dart';
import 'context/context_retriever.dart';
import 'draft_stream.dart';
import 'llm/draft_task.dart';
import 'llm/embeddings_client.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/model_slots.dart' show LlmTargetSpec;
import 'llm/partial_json.dart';
import 'llm/reply_decision_task.dart';
import 'pipeline_progress.dart';

/// Decides whether ONE message needs an answer, and writes one when it does.
///
/// `entity_id` is a source message id — this queue works at the grain of the
/// thing being answered, because that is what a suggestion is about. A thread
/// that gets a second question gets a second decision and a second draft
/// rather than living with the answer to the first.
///
/// Two model calls, and the first is the point. The fast triage's
/// `reply_expected` is a guess made on one message in isolation, and the
/// enqueue in front of this handler treats it as nothing more than a coarse
/// pre-gate; this is where the model that will do the writing reads the actual
/// conversation and says whether writing is warranted. A `no` costs one small
/// call and stores nothing.
///
/// The draft call STREAMS when this handler was given a live [DraftStreamBus]
/// — which the app always does and no test does unless it is testing the
/// stream. What goes on the bus is the text a person is waiting to read, as it
/// is written: the reply body and the short options, never the evidence
/// sentence. What does NOT change is everything else. The prompt, the schema,
/// the token budget, the retry policy and the stored row are what they were,
/// the row is written once when the call finishes, and a `done` event says the
/// call has ended — written or failed — so a listener drops its preview and
/// reads the row instead. The guards that skip an item exit BEFORE the stream
/// opens and publish nothing, which is right: nobody was shown a preview.
///
/// It only ever writes to the `drafts` table. Nothing in this class — and
/// nothing this class calls — touches Microsoft Graph: a suggestion is text in
/// sqlite until a person presses Send, and keeping the model's output on this
/// side of that line is what makes "never auto-send" a property of the code
/// rather than a promise in a comment.
class DraftHandler extends WorkHandler {
  static const String _source = 'email';

  /// A reply is longer than a label. The default 512 is enough to truncate a
  /// 150-word draft mid-sentence, and a cut-off draft is grammar-valid, so
  /// nothing downstream would notice. The answer carries the two short options
  /// as well as the long form, so the ceiling has to clear both.
  ///
  /// 768 is that ceiling, measured rather than guessed. Completion tokens on
  /// the golden drafts: the 27B median 155, p90 270, max 316; Opus 5 median
  /// 355, p90 521, max 584. The live activity log's `draft` rows over 57
  /// entries: median 182, p90 244, max 301. So 768 is 2.4× the largest LOCAL
  /// draft ever measured (316 tokens on the 27B) and 1.2× the largest cloud
  /// one (655, Opus 5 on the shipped rules; 584 before this round) — room over
  /// the model that does the work, and a real ceiling over the ones that do
  /// not. The old 1,536 was five times the local maximum and bought nothing
  /// but more time for a wedged model to ramble.
  ///
  /// Public because the live benches (`llm_golden_live_test.dart`,
  /// `llm_prose_live_test.dart`) draft at the handler's budget; a bench that
  /// repeats the number instead of reading it measures a prompt this app does
  /// not send.
  static const int draftMaxTokens = 768;

  /// The newest turns of [thread] that `DraftTask` renders — the same window
  /// it cuts, so a rule about "what the prompt shows" reads the same list.
  static List<Message> _shownTail(List<Message> thread) =>
      thread.length > DraftTask.maxThreadMessages
          ? thread.sublist(thread.length - DraftTask.maxThreadMessages)
          : thread;

  /// A yes/no and one sentence. Room for the sentence to run long, and no room
  /// for the model to start drafting inside the decision.
  static const int _decisionMaxTokens = 256;

  /// Two past replies, clipped: a tone sample, not a second thread.
  static const int _styleExamples = 2;
  static const int _styleExampleCap = 750;

  final MessageStore _store;
  final LlmClient _client;

  /// Where the reply DECISION goes. Its own stage (`reply_decision`) and so
  /// its own client: the decision is a yes/no under a tight schema and the
  /// draft is prose, so a machine with a second server can put the cheap half
  /// of a prefetch somewhere else. Defaults to [_client], which is the
  /// one-client behaviour every test and every bench here gets.
  final LlmClient _decisionClient;

  final ActivityLog _log;

  /// Finds the passages of this thread's documents worth quoting, or null in a
  /// build that has none.
  ///
  /// Nullable rather than defaulted so a handler built without one drafts
  /// exactly as it did before this existed — which is what every test that
  /// predates retrieval, and any future caller with no embedder, gets.
  final AttachmentRetriever? _attachments;

  /// What the owner's own registered directories know about this message, or
  /// null in a build with none. Nullable on [_attachments]' reasoning: a
  /// handler built without one drafts exactly as it did before this existed.
  final ContextRetriever? _contextDirs;

  /// The embedder the two retrievers below are searched with, so that the
  /// message being answered is turned into a vector ONCE for both of them.
  ///
  /// The handler holds it rather than either retriever, because neither of
  /// them can know the other is about to ask the same question. Null leaves
  /// each retriever to build its own — which is what a handler assembled
  /// without an embedder, and every test that predates this, gets.
  final EmbeddingsClient? _embeddings;

  /// Where this stage lands for the home screen. Defaulted to the disabled
  /// recorder, so a test that builds this handler writes nothing extra.
  final PipelineProgress _progress;

  /// Where the draft's words go while they are being written. Disabled by
  /// default, and a disabled bus is not merely silent — the handler passes no
  /// `onText` at all, so the call is byte-identical to the one it made before
  /// streaming existed.
  final DraftStreamBus _stream;

  /// Where an IMPROVE goes — the `draft_improve` stage's client, or null in a
  /// build that has none.
  ///
  /// A second client rather than a second prompt: [improve] sends the same
  /// [DraftTask] bytes this handler already sends, on whatever target that
  /// stage points at. Null is the default, so every construction that
  /// predates this drafts exactly as it did and simply has no Improve.
  final LlmClient? _improveClient;

  /// Where the two draft stages point and whether the standing rule is on,
  /// read at the moment a draft is about to be written. See [DraftRoutes].
  final DraftRoutes _routes;

  DraftHandler(
    this._store,
    this._client, {
    LlmClient? decisionClient,
    LlmClient? improveClient,
    this._routes = DraftRoutes.none,
    ActivityLog? activityLog,
    this._attachments,
    // NAMED `contextDirs` rather than taken as `this._contextDirs`: around
    // this handler `context`, `contextDirs` and `contextJson` are three
    // different things, and the call site reads better saying which one it is
    // handing over.
    ContextRetriever? contextDirs,
    EmbeddingsClient? embeddings,
    this._progress = const PipelineProgress.disabled(),
    this._concurrency,
    this._streams,
    this._stream = const DraftStreamBus.disabled(),
  })  : _decisionClient = decisionClient ?? _client,
        // ignore: prefer_initializing_formals
        _improveClient = improveClient,
        // ignore: prefer_initializing_formals
        _contextDirs = contextDirs,
        // ignore: prefer_initializing_formals
        _embeddings = embeddings,
        _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'draft';

  /// How wide the prose server was started, read at every launch decision.
  ///
  /// A CLOSURE and not a number, because the width is a SETTING
  /// (`AppPrefs.proseParallel`, Settings › Models › Drafts in flight) and the
  /// worker re-reads `concurrency` before launching each item — so moving the
  /// control moves the next draft rather than waiting for a relaunch.
  ///
  /// One when nobody says otherwise, which is what every test, every bench and
  /// a single-slot llama-server gets. Drafts are the one prose kind that may
  /// go wider at all: they are independent of one another, where a recap and a
  /// refresh both write the storyline they are about.
  final int Function()? _concurrency;

  @override
  int get concurrency => _concurrency?.call() ?? 1;

  /// Whether the draft TARGET can stream, read at the same moment the width
  /// is — a closure and not a flag for [_concurrency]'s reason: both are
  /// facts about wherever `draft_reply` currently points, and pointing it
  /// somewhere else must move the next draft rather than the next launch.
  ///
  /// True when nobody says otherwise, which is what every test and every
  /// bench here gets.
  final bool Function()? _streams;

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    await _progress.noteDraft(source, id, state: 'running');

    final row = await _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Nothing to answer
    // and nothing wrong — the item is done, not failed.
    if (row == null) return _skip(source, id, 'deleted');

    // The user's own mail. Extraction only ever enqueues inbound messages, so
    // this is the guard rather than a case — and it is here for the reason
    // every guard in this handler is: the queue can hand over a row that has
    // changed since it was written.
    if (row['direction'] != 'inbound') return _skip(source, id, 'outbound');

    // Queued, then GATED before the worker reached it — the [ExtractHandler]
    // exit, at the one other point in the pipeline that can be reached after
    // triage has changed its mind. Answering a newsletter is the waste this
    // stops. The `teams_source` exception is the same legacy tolerance: a chat
    // stored before chats were triaged is `skipped` for a reason no judgement
    // stands behind.
    if (row['triage_status'] == 'skipped' &&
        row['gate_reason'] != 'teams_source') {
      return _skip(source, id, 'gated');
    }

    // Already answered. Two enqueues racing to the same message is benign —
    // the first one's suggestion is as good as the second's — and returning
    // here spends no model time discovering that.
    if (await _store.getDraftForMessage(source, id) != null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'already_drafted'});
      await _progress.noteDraft(source, id, state: 'done');
      return;
    }

    // What the person who queued this asked for, decoded ONCE — the two id
    // lists the retrievers float first, and whether a person pressed the
    // button at all.
    final request = DraftRequest.fromPayload(item['payload_json']);

    final consulted = request.contextFileIds.length;
    final gathered = await _gather(
      source,
      id,
      row,
      pinnedFirst: request.pinnedAttachmentIds,
      consultFirst: request.contextFileIds,
    );
    final replyTo = gathered.replyTo;
    final key = gathered.key;
    final excerpts = gathered.excerpts;
    final pack = gathered.pack;

    // The decision the person already made, when they made it. A prefetched
    // draft asks the model whether a reply is wanted; an ASKED-FOR one does
    // not, because pressing **Draft reply** is that answer — and a model that
    // came back "no" would leave the person who pressed it an empty box and no
    // sentence. It is also the expensive half of a keypress they are waiting
    // on: one 27B call, about five seconds, off every asked-for draft.
    final decision = request.asked
        ? null
        : await runTask(
            _decisionClient,
            const ReplyDecisionTask(),
            ReplyDecisionInput(
              context: gathered.context,
              message: replyTo,
              aboutMe: gathered.aboutMe,
              attachmentExcerpts: excerpts,
              directories: pack,
              now: DateTime.now(),
            ),
            // Zero, like every judgement in this app: the same message must get
            // the same verdict twice, or a re-drain would offer a suggestion
            // the last one did not.
            temperature: 0,
            maxTokens: _decisionMaxTokens,
          );

    if (decision != null && !decision.needsReply) {
      // A real END state, not a failure: the model read the conversation and
      // said nobody is waiting. The reason is recorded so a person looking at
      // the activity row can see what it read.
      return _skip(source, id, 'no_reply_needed', why: decision.reason);
    }

    // Where this draft is about to go, and whether that is somebody else's
    // machine. Read HERE, once, so the count below and the write above the
    // call agree about the same target.
    final draftSpec = _routes.draftTarget();
    final cloudDraft = draftSpec?.isThirdParty ?? false;
    if (cloudDraft && _routes.ledger == null) {
      // Fail CLOSED: a third-party draft target with nothing counting it is a
      // wiring bug, and the one thing it must not become is an uncapped call.
      throw StateError('a third-party draft target without a ledger');
    }
    if (cloudDraft && !request.asked) {
      // The cap stops a PREFETCH — work nobody is waiting on — before it
      // spends anything. A draft a person pressed for is refused earlier, by
      // the provider, so it never reaches this queue at all.
      final refusal = await _routes.ledger!.refusal();
      if (refusal != null) return _skip(source, id, 'cloud_cap');
    }
    // The standing rule's wiring, checked BEFORE the draft call it would
    // follow: a bug found after the local draft is stored would mark the item
    // for retry and pay for that draft again on every attempt.
    final standing =
        !request.asked && _routes.standing() && _urgentNeedsYou(row);
    if (standing) {
      final improveTarget = _routes.improveTarget();
      if (improveTarget != null) _assertWired(improveTarget);
    }
    // Counted BEFORE the call, so a prompt that left and then failed still
    // counts against the day. The target's ID and never its URL.
    if (cloudDraft) _log.note({'cloud': 1, 'target': draftSpec!.id});

    // One reader per draft, because the paths it reports are positions in THIS
    // answer's object and nothing else. Null when nobody is listening, which
    // is what keeps the call itself unchanged.
    //
    // And null when the TARGET does not stream — one on the Converse wire has
    // nothing to stream at all — so a draft written there makes the plain
    // call rather than a streamed one that would deliver its whole answer in
    // a single delta at the end.
    final reader =
        _stream.enabled && (_streams?.call() ?? true) ? PartialJsonStrings() : null;

    try {
      // Built AFTER the decision and INSIDE this try, exactly where it was
      // built before: the two store reads inside it are the last two this
      // path makes, a draft the model said was not wanted must not pay for
      // them, and one of them throwing must still reach the `done` below.
      final input = await _draftInput(source, gathered);

      final result = await runTask(
        _client,
        const DraftTask(),
        input,
        // Zero, like extraction: pressing Regenerate should change the draft
        // because the thread changed, not because the sampler rolled
        // differently.
        temperature: 0,
        maxTokens: draftMaxTokens,
        // Null when nobody is listening, which is what makes the streamed and
        // unstreamed calls the same call.
        onText: reader == null
            ? null
            : (delta) => _publishDeltas(reader, delta, source, key, id),
      );

      if (result.replyBody.isEmpty) {
        // A retryable failure, deliberately. An empty answer from a local
        // model is usually a one-off, and the worker's retry-once policy is
        // exactly the right response — writing the blank draft instead would
        // put an empty composer in front of the user as though it were a
        // suggestion.
        throw const LlmFormatException(
          'The local model drafted an empty reply.',
        );
      }

      final provenance = _provenanceFor(excerpts, pack);
      // The distinct paths the caption's directory files came from, for the
      // activity row below.
      final directoryFiles = {
        for (final file in provenance.files) file.path,
      }.toList();

      await _store.upsertDraft(
        source: source,
        conversationKey: key,
        replyToMessageId: replyTo.id,
        body: result.replyBody,
        evidence: result.evidence,
        optionsJson: _optionsJson(result),
        // The inventory of what went into the prompt, stored WITH the draft
        // rather than only in the activity row — the composer's caption names
        // what was read, and a caption assembled from the activity log would be
        // a join against a table that gets pruned.
        contextJson: provenance.isNone ? null : provenance.encode(),
        status: 'suggested',
      );
      await _progress.noteDraft(source, id, state: 'done');
      _log.note({
        'chars': result.replyBody.length,
        // Why there is no decision call on this row's timeline: a person asked
        // for it, so the judgement was theirs.
        if (request.asked) 'decision': 'asked',
        // The activity row keeps its own copy, which is not a duplicate of the
        // stored provenance: a person reading the log is asking what the app
        // DID, and the row has to answer after the draft it belongs to has been
        // sent, edited or thrown away.
        if (consulted > 0) 'consulted': consulted,
        if (provenance.documents.isNotEmpty) 'documents': provenance.documents,
        if (provenance.directories.isNotEmpty)
          'directories': provenance.directories,
        if (directoryFiles.isNotEmpty) 'directory_files': directoryFiles,
        if (pack.skills.isNotEmpty) 'skills': pack.skills,
        // How many sections the model asked to read whole, and — when it could
        // not be asked at all — why. The second is not a failure of the draft:
        // the pack below it is the pack there would have been anyway, and this
        // is what says the closer read was the thing that did not happen.
        if (pack.expanded.isNotEmpty) 'expanded': pack.expanded.length,
        if (pack.selectError != null) 'select_error': pack.selectError,
      });

      // The standing rule, AFTER the local draft is stored. That order is the
      // whole safety of it: whatever happens to the second call, the person
      // already has an answer in the box.
      if (standing) {
        await _improveWritten(
          source,
          key,
          replyTo.id,
          input,
          provenance,
          cloudCount: cloudDraft ? 1 : 0,
        );
      }
    } finally {
      // ONE exit for the word "done", covering all of them: the answer
      // written, the answer empty, the call thrown, the row refusing to store.
      // It runs after the body, so on the path that matters — a draft that
      // landed — the listener is told only once the row it will re-read is
      // there.
      _publishStreamDone(source, key, id);
    }
  }

  /// Rewrites the stored draft for [messageId] on the `draft_improve`
  /// target. Null on success; otherwise the one line the composer shows.
  ///
  /// Never in a drain: the composer calls it, so it runs in its own span and
  /// records its own `draft_improve` row. The same [DraftTask] and the same
  /// fenced prompt the local draft used — there is no second prompt in this
  /// app — and no streaming, whatever the target says it can do.
  ///
  /// One thing the rebuilt prompt cannot reproduce: the DOCUMENTS a person
  /// pinned when they first asked. Those ids ride a work row's payload and
  /// are gone by the time the draft is stored, so an improve retrieves them
  /// the way a prefetch does. The directory files come back, because the
  /// stored provenance names them.
  Future<String?> improve(String source, String messageId) async {
    // Read ONCE, here, so the guard and the span agree about the same target.
    final target = _routes.improveTarget();
    // A routed stage with no client, or a third-party one with no ledger, is
    // a wiring bug in the provider graph, not something a person should read
    // a sentence about — and never an uncapped call.
    if (target != null) _assertWired(target);
    return _log.inSpan(() async {
      final watch = Stopwatch()..start();
      final detail = <String, Object?>{};
      var status = 'ok';
      try {
        if (target == null) {
          status = 'skipped';
          detail['reason'] = 'unrouted';
          return 'Pick a target for Improve a draft under Settings, Models '
              'first.';
        }

        final row = await _store.getMessageRow(source, messageId);
        if (row == null) {
          status = 'skipped';
          detail['reason'] = 'deleted';
          return 'This message is no longer stored.';
        }
        final draftRow = await _store.getDraftForMessage(source, messageId);
        if (draftRow == null) {
          status = 'skipped';
          detail['reason'] = 'no_draft';
          return 'There is no draft to improve yet.';
        }

        if (target.isThirdParty) {
          final refusal = await _routes.ledger!.refusal();
          if (refusal != null) {
            status = 'skipped';
            detail['reason'] = 'cloud_cap';
            return refusal;
          }
        }
        detail['target'] = target.id;
        // Before the call, on the prefetch's rule: a prompt that left counts
        // against the day even when the answer never came back.
        if (target.isThirdParty) detail['cloud'] = 1;

        final stored =
            DraftProvenance.decode(draftRow['context_json'] as String?);
        final gathered = await _gather(
          source,
          messageId,
          row,
          pinnedFirst: const [],
          consultFirst: [
            for (final file in stored?.files ?? const []) ?file.fileId,
          ],
        );
        final result = await runTask(
          _improveClient!,
          const DraftTask(),
          await _draftInput(source, gathered),
          temperature: 0,
          maxTokens: draftMaxTokens,
        );
        if (result.replyBody.isEmpty) {
          status = 'error';
          detail['error'] = 'empty';
          return 'The target returned an empty draft, so the local one is '
              'kept.';
        }

        final provenance = _provenanceFor(gathered.excerpts, gathered.pack)
            .copyWith(improvedBy: target.id);
        await _store.upsertDraft(
          source: source,
          conversationKey: gathered.key,
          replyToMessageId: messageId,
          body: result.replyBody,
          evidence: result.evidence,
          optionsJson: _optionsJson(result),
          contextJson: provenance.isNone ? null : provenance.encode(),
          status: 'suggested',
        );
        detail['chars'] = result.replyBody.length;
        return null;
      } on LlmException catch (e) {
        // A CATEGORY, on the row and on the screen, never the client's own
        // sentence: that one names the endpoint it dialled, and a target's URL
        // belongs in Settings, not in an activity row or above a reply box.
        status = 'error';
        detail['error'] = _errorCategory(e);
        // Non-null here: the null case returned before anything could throw.
        final name = target!.name;
        return e is LlmUnavailableException
            ? 'Improve failed. $name did not answer.'
            : 'Improve failed. $name returned an answer that could not be '
                'used.';
      } catch (e) {
        status = 'error';
        detail['error'] = _errorCategory(e);
        return 'Could not improve the draft. The local one is kept.';
      } finally {
        // ONE row for the whole attempt, however it ended. The model call's
        // own tally folds in from this span's slot.
        await _log.record(
          'draft_improve',
          status: status,
          source: source,
          entityId: messageId,
          durationMs: watch.elapsedMilliseconds,
          detail: detail,
        );
      }
    });
  }

  /// The standing rule's half of [improve]: the same second call, made inside
  /// the draft row's own span so the two land on ONE activity row.
  ///
  /// Everything it can go wrong with is a note and a return. The local draft
  /// is already stored, so the worst case here is a person reading the answer
  /// their own machine wrote.
  Future<void> _improveWritten(
    String source,
    String key,
    String replyToId,
    DraftInput input,
    DraftProvenance provenance, {
    required int cloudCount,
  }) async {
    final target = _routes.improveTarget();
    if (target == null) return;
    // Already asserted by [run] before the draft call; kept so a direct
    // caller cannot reach a null client either.
    _assertWired(target);

    if (target.isThirdParty) {
      final refusal = await _routes.ledger!.refusal();
      if (refusal != null) {
        _log.note({'improve': 'cloud_cap'});
        return;
      }
      // Both of them: a prefetch on a third-party draft target that also
      // improves has sent the prompt twice, and the day's count has to say so.
      _log.note({'cloud': cloudCount + 1, 'improve_target': target.id});
    } else {
      _log.note({'improve_target': target.id});
    }

    try {
      final result = await runTask(
        _improveClient!,
        const DraftTask(),
        input,
        temperature: 0,
        maxTokens: draftMaxTokens,
      );
      if (result.replyBody.isEmpty) {
        _log.note({'improve_error': 'empty'});
        return;
      }
      final improved = provenance.copyWith(improvedBy: target.id);
      await _store.upsertDraft(
        source: source,
        conversationKey: key,
        replyToMessageId: replyToId,
        body: result.replyBody,
        evidence: result.evidence,
        optionsJson: _optionsJson(result),
        contextJson: improved.isNone ? null : improved.encode(),
        status: 'suggested',
      );
      _log.note({
        'improved': target.id,
        'improved_chars': result.replyBody.length,
      });
    } catch (e) {
      // The local draft stays. This is an upgrade that did not happen, not a
      // draft that failed, so the row is still `ok`. A category, for the
      // reason [improve] gives: the client's sentence names the endpoint.
      _log.note({'improve_error': _errorCategory(e)});
    }
  }

  /// What went wrong, as one word the row can carry and the ledger can group
  /// on. Never the exception's own text: [LlmClient] spells the endpoint's
  /// URL into it, and a target's URL is a setting, not a log line.
  static String _errorCategory(Object e) => switch (e) {
        LlmUnavailableException() => 'unavailable',
        LlmFormatException() => 'format',
        LlmException() => 'llm',
        _ => 'other',
      };

  /// The two things a routed Improve target must have: a client to dial, and
  /// a ledger when it is somebody else's machine. Missing either is a wiring
  /// bug in the provider graph, thrown rather than skipped so it cannot hide
  /// — and never an uncapped call.
  void _assertWired(LlmTargetSpec target) {
    if (_improveClient == null) {
      throw StateError('improve without a client');
    }
    if (target.isThirdParty && _routes.ledger == null) {
      throw StateError('a third-party improve target without a ledger');
    }
  }

  /// Whether this message is one the standing rule is about: the owner is
  /// actually needed, and soon. The two urgency words are the ones
  /// `extract_handler.dart`'s `asksForAReply` reads, so "urgent" means the
  /// same thing here as it does on the card.
  static bool _urgentNeedsYou(Map<String, Object?> row) =>
      row['needs_you_verdict'] == 1 &&
      (row['urgency'] == 'urgent' || row['urgency'] == 'high');

  /// The short ready-to-send replies as the column stores them, or null.
  ///
  /// Null rather than `[]`: "the model offered no short replies" and "the
  /// options were read and there were none" are the same thing to every
  /// reader, and one of the two spellings is shorter. One helper for all
  /// three writers — the draft, the standing improve and the button.
  static String? _optionsJson(DraftResult result) => result.options.isEmpty
      ? null
      : jsonEncode([
          for (final option in result.options)
            {'stance': option.stance, 'body': option.body},
        ]);

  /// Everything one draft is written from, read once.
  ///
  /// Split out of [run] so that [improve] builds the SAME prompt from the same
  /// reads in the same order. It is a gather and nothing else: no model is
  /// dialled here, and no row is written.
  Future<_Gathered> _gather(
    String source,
    String id,
    Map<String, Object?> row, {
    required List<String> pinnedFirst,
    required List<int> consultFirst,
  }) async {
    var replyTo = Message.fromRow(row);
    final key = row['conversation_key'] as String? ?? '';
    // Hydrated only when the row says there is something to hydrate —
    // `loadThread` does this for a whole thread; a single-row read has to ask.
    if (row['has_attachments'] == 1) {
      replyTo = replyTo.withAttachments(
        await _store.attachmentRefsFor(source, id, conversationKey: key),
      );
    }
    // The thread AS IT WAS when this message landed. Cutting it off here is
    // what makes the answer to a message the same answer however far behind
    // the queue was when it got here — and it keeps the model from replying to
    // something that was said after the message it is answering.
    final thread = await _store.loadThread(
      key,
      sources: [source],
      untilIso: row['received_at'] as String? ?? row['created_at'] as String?,
    );
    final context = [
      for (final message in thread)
        if (message.id != replyTo.id) message,
    ];
    final aboutMe = await _store.getPref(aboutMeKey);

    // ONE retrieval, read by both model calls below. The decision and the
    // draft are asking about the same message on the same thread, so a second
    // pass would be a second embedding call for an answer that cannot come
    // back different.
    //
    // The thread's ids are passed rather than left to be read: this thread is
    // the thread AS IT WAS when the message landed, and a document attached
    // after it must not be quoted in the answer to it.
    //
    // And ONE embedding, for the same reason again. The two retrievals below
    // search two different indexes with the SAME question — what is this
    // message about — and each of them would otherwise embed the card itself
    // when the queue has not reached it yet. The closure is memoised on the
    // future rather than the value, so two awaits of it are one POST even
    // when they overlap; it is passed rather than called here, because each
    // retriever's cheap `LIMIT 1` guard stands in front of it and a thread
    // with neither documents nor directories must still cost nothing.
    final vector = _queryVectorFor(source, id);

    final excerpts = await _excerptsFor(
      source,
      key,
      id,
      threadMessageIds: [for (final message in thread) message.id],
      pinnedFirst: pinnedFirst,
      queryVector: vector,
    );

    // ONE pack, for the same reason there is one retrieval: both calls below
    // ask about the same message on the same thread, and the directories have
    // not changed between the two.
    final pack = await _packFor(
      source,
      key,
      id,
      queryVector: vector,
      consultFirst: consultFirst,
    );

    return _Gathered(
      replyTo: replyTo,
      key: key,
      thread: thread,
      context: context,
      aboutMe: aboutMe,
      excerpts: excerpts,
      pack: pack,
    );
  }

  /// The draft prompt's input, byte for byte what [run] built inline before
  /// [improve] needed the same one.
  Future<DraftInput> _draftInput(String source, _Gathered g) async =>
      DraftInput(
        thread: g.thread,
        replyTo: g.replyTo,
        // Mail only. `recentOutboundToSender` matches on `to_json`, which a
        // chat never writes ('[]'), so the skip only makes explicit what the
        // LIKE would answer anyway — and a chat needs it less: the thread
        // tail already carries the owner's own chat voice, turn by turn.
        //
        // And mail only when the owner has not already spoken in THIS
        // thread — in the part of it the prompt will actually show. Their
        // own turn, on this subject, to this person, is a better tone sample
        // than two old replies to someone else about something else — so
        // when the rendered tail carries one the examples are dropped, and
        // the prompt is shorter for it. The window is
        // [DraftTask.maxThreadMessages], the newest turns; an owner turn
        // older than that is not in the prompt, so it cannot stand in for
        // the examples and they stay.
        styleExamples:
            source == 'email' && !_shownTail(g.thread).any((m) => m.outbound)
                ? await _styleExamplesFor(source, g.replyTo.fromAddress)
                : const [],
        storylineSummary: await _storylineSummaryFor(source, g.key),
        aboutMe: g.aboutMe,
        attachmentExcerpts: g.excerpts,
        directories: g.pack,
        now: DateTime.now(),
      );

  /// What this reply was written from, distinct and in ranked order. Three
  /// passages of one contract are one document to a reader, and three
  /// passages of one analysis are three places in one file — so the documents
  /// collapse by name and the directory files collapse by the tuple that names
  /// a place. Set literals keep insertion order, which is the ranking.
  static DraftProvenance _provenanceFor(
    List<AttachmentExcerpt> excerpts,
    ContextPack pack,
  ) {
    final documents = {
      for (final excerpt in excerpts)
        excerpt.name.isEmpty ? 'a file' : excerpt.name,
    }.toList();
    final files = {
      for (final excerpt in pack.excerpts)
        (
          dir: excerpt.dirName,
          path: excerpt.relPath,
          locator: excerpt.locator,
          // The row id, so the composer's chip can open the file rather than
          // only name it.
          fileId: excerpt.fileId,
        ),
    }.toList();
    return DraftProvenance(
      documents: documents,
      // A pack that rendered nothing named nothing, whatever its own list
      // says. The retriever is the layer that decides which directories
      // contributed and it already answers that way; this is the belt to its
      // braces, because the one thing the caption must never do is tell a
      // person their reply was drafted from a project the model never read.
      directories: pack.isEmpty ? const [] : pack.directories,
      files: files,
      skills: pack.skills,
    );
  }

  /// Feeds one chunk of the streamed answer to the reader and publishes the
  /// parts of it a person is waiting to read.
  ///
  /// Everything else the object carries is dropped here rather than filtered
  /// by the listener, because a bus is a promise about what is on it: the
  /// evidence sentence is the model's note to the app about what it read, and
  /// nobody watches that being typed.
  void _publishDeltas(
    PartialJsonStrings reader,
    String delta,
    String source,
    String key,
    String id,
  ) {
    for (final part in reader.feed(delta)) {
      if (!DraftStreamEvent.isVisible(part.path)) continue;
      _stream.publish(DraftStreamEvent(
        source: source,
        conversationKey: key,
        sourceMessageId: id,
        path: part.path,
        delta: part.delta,
      ));
    }
  }

  /// The draft call has ended, however it ended. A no-op when nobody is
  /// listening.
  void _publishStreamDone(String source, String key, String id) {
    if (!_stream.enabled) return;
    _stream.publish(DraftStreamEvent.done(
      source: source,
      conversationKey: key,
      sourceMessageId: id,
    ));
  }

  /// The passages the two prompts read, or none.
  ///
  /// Every failure here is swallowed on purpose. Retrieval is what makes a
  /// draft better; it is not what makes one possible, and an embedding server
  /// that fell over between the thread load and this call must cost the
  /// citations rather than the reply. The reason is noted so the activity row
  /// says why a draft that should have quoted a file did not.
  Future<List<AttachmentExcerpt>> _excerptsFor(
    String source,
    String key,
    String id, {
    required List<String> threadMessageIds,
    required List<String> pinnedFirst,
    Future<Uint8List?> Function()? queryVector,
  }) async {
    final retriever = _attachments;
    if (retriever == null) return const [];
    try {
      return await retriever.excerptsFor(
        source: source,
        conversationKey: key,
        replyToId: id,
        threadMessageIds: threadMessageIds,
        storylineIds: await _store.storylineIdsFor(source, key),
        pinnedFirst: pinnedFirst,
        queryVector: queryVector,
      );
    } catch (e) {
      _log.note({'excerpts_error': '$e'});
      return const [];
    }
  }

  /// What the owner's own directories know about this message, or an empty
  /// pack.
  ///
  /// [_excerptsFor]'s shape and its reasoning. The retriever swallows its own
  /// failures and answers with the half it has; this catch is for the ones
  /// underneath it — a database that went away, a storyline read that threw —
  /// and it is noted rather than raised because a reply written without the
  /// project is still a reply.
  Future<ContextPack> _packFor(
    String source,
    String key,
    String id, {
    Future<Uint8List?> Function()? queryVector,
    List<int> consultFirst = const [],
  }) async {
    final retriever = _contextDirs;
    if (retriever == null) return ContextPack.empty;
    try {
      return await retriever.packFor(
        source: source,
        conversationKey: key,
        replyToId: id,
        storylineIds: await _store.storylineIdsFor(source, key),
        queryVector: queryVector,
        consultFirst: consultFirst,
      );
    } catch (e) {
      _log.note({'context_error': '$e'});
      return ContextPack.empty;
    }
  }

  /// One closure that answers with this message's query vector, however many
  /// times it is called, or null when there is no embedder to build one with.
  ///
  /// The memo holds the FUTURE and not the value, which is what makes it
  /// correct rather than merely thrifty: two retrievers awaiting the same
  /// unfinished POST both get that POST's answer, where a memo on the value
  /// would let the second one start a duplicate before the first had
  /// returned. A null answer is memoised too — an embedding server that is
  /// down is down for both corpora, and asking it twice is two timeouts in
  /// front of one draft.
  Future<Uint8List?> Function()? _queryVectorFor(String source, String id) {
    final embeddings = _embeddings;
    if (embeddings == null) return null;
    Future<Uint8List?>? cached;
    return () => cached ??= replyToQueryVector(_store, embeddings, source, id);
  }

  /// This message gets no draft, and its stage says so.
  ///
  /// The four ends that are not failures — the row is gone, it is the user's
  /// own mail, triage gated it, or the model read the thread and said nobody
  /// is waiting — record the same three things in the same order: the item is
  /// `skipped` rather than `ok`, [reason] says which end it was, and the
  /// progress row closes the stage so the message settles instead of waiting
  /// for a draft nothing is going to write. [why] carries the model's own
  /// sentence, which only the last of them has.
  ///
  /// Not used for "already drafted": that one is `done`, because the draft the
  /// caller wanted exists.
  Future<void> _skip(
    String source,
    String id,
    String reason, {
    String? why,
  }) async {
    _log
      ..noteStatus('skipped')
      ..note({'reason': reason, 'why': ?why});
    await _progress.noteDraft(source, id, state: 'skipped');
  }

  /// The user's own recent replies to this sender, as writing samples.
  Future<List<String>> _styleExamplesFor(String source, String? address) async {
    if (address == null || address.isEmpty) return const [];
    final rows = await _store.recentOutboundToSender(
      source,
      address,
      limit: _styleExamples,
    );
    final examples = <String>[];
    for (final row in rows) {
      // Markers out, for [buildMessageBlock]'s reason and one of its own: a
      // style example is a sample the model imitates, and `[[att:…]]` in one
      // is a token it would learn to write.
      final body = stripAttachmentMarkers(row['body_text'] as String?).trim();
      final preview =
          stripAttachmentMarkers(row['body_preview'] as String?).trim();
      final text = body.isNotEmpty ? body : preview;
      if (text.isEmpty) continue;
      examples.add(
        text.length > _styleExampleCap
            ? text.substring(0, _styleExampleCap)
            : text,
      );
    }
    return examples;
  }

  /// The first live storyline's summary, when this thread is in one. First
  /// rather than best: `storylineIdsFor` returns them in join order, a thread
  /// is almost always in exactly one, and picking between two summaries is a
  /// judgement this handler has no basis for.
  Future<String?> _storylineSummaryFor(String source, String key) async {
    final ids = await _store.storylineIdsFor(source, key);
    if (ids.isEmpty) return null;
    return (await _store.getStoryline(ids.first))?.summary;
  }
}

/// Everything one draft is written from, gathered once.
///
/// A class rather than a bag of locals because two callers now need exactly
/// the same set: the queue's `run` and the composer's `improve`, which must
/// build the same prompt or the button would be offering a different answer
/// to a different question.
class _Gathered {
  final Message replyTo;
  final String key;
  final List<Message> thread;

  /// The thread WITHOUT the message being answered — what the reply decision
  /// reads, and the one field the draft prompt does not.
  final List<Message> context;

  final String? aboutMe;
  final List<AttachmentExcerpt> excerpts;
  final ContextPack pack;

  const _Gathered({
    required this.replyTo,
    required this.key,
    required this.thread,
    required this.context,
    required this.aboutMe,
    required this.excerpts,
    required this.pack,
  });
}
