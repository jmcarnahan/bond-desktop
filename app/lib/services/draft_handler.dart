import 'dart:convert';

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'llm/draft_task.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
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
/// It only ever writes to the `drafts` table. Nothing in this class — and
/// nothing this class calls — touches Microsoft Graph: a suggestion is text in
/// sqlite until a person presses Send, and keeping the model's output on this
/// side of that line is what makes "never auto-send" a property of the code
/// rather than a promise in a comment.
class DraftHandler extends WorkHandler {
  static const String _source = 'email';

  /// A reply is longer than a label. The default 512 is enough to truncate a
  /// 150-word draft mid-sentence, and a cut-off draft is grammar-valid, so
  /// nothing downstream would notice. The answer now carries the two short
  /// options as well as the long form, so the ceiling went up with it.
  static const int _maxTokens = 1536;

  /// A yes/no and one sentence. Room for the sentence to run long, and no room
  /// for the model to start drafting inside the decision.
  static const int _decisionMaxTokens = 256;

  /// Two past replies, clipped: a tone sample, not a second thread.
  static const int _styleExamples = 2;
  static const int _styleExampleCap = 750;

  final MessageStore _store;
  final LlmClient _client;
  final ActivityLog _log;

  /// Where this stage lands for the home screen. Defaulted to the disabled
  /// recorder, so a test that builds this handler writes nothing extra.
  final PipelineProgress _progress;

  DraftHandler(
    this._store,
    this._client, {
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _progress = progress;

  @override
  String get kind => 'draft';

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    await _progress.noteDraft(source, id, state: 'running');

    final row = await _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Nothing to answer
    // and nothing wrong — the item is done, not failed.
    if (row == null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'deleted'});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
    }

    // The user's own mail. Extraction only ever enqueues inbound messages, so
    // this is the guard rather than a case — and it is here for the reason
    // every guard in this handler is: the queue can hand over a row that has
    // changed since it was written.
    if (row['direction'] != 'inbound') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'outbound'});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
    }

    // Queued, then GATED before the worker reached it — the [ExtractHandler]
    // exit, at the one other point in the pipeline that can be reached after
    // triage has changed its mind. Answering a newsletter is the waste this
    // stops. The `teams_source` exception is the same legacy tolerance: a chat
    // stored before chats were triaged is `skipped` for a reason no judgement
    // stands behind.
    if (row['triage_status'] == 'skipped' &&
        row['gate_reason'] != 'teams_source') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'gated'});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
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

    final replyTo = Message.fromRow(row);
    final key = row['conversation_key'] as String? ?? '';
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

    final decision = await runTask(
      _client,
      const ReplyDecisionTask(),
      ReplyDecisionInput(
        context: context,
        message: replyTo,
        aboutMe: aboutMe,
        now: DateTime.now(),
      ),
      // Zero, like every judgement in this app: the same message must get the
      // same verdict twice, or a re-drain would offer a suggestion the last
      // one did not.
      temperature: 0,
      maxTokens: _decisionMaxTokens,
    );

    if (!decision.needsReply) {
      // A real END state, not a failure: the model read the conversation and
      // said nobody is waiting. The reason is recorded so a person looking at
      // the activity row can see what it read.
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'no_reply_needed', 'why': decision.reason});
      await _progress.noteDraft(source, id, state: 'skipped');
      return;
    }

    final result = await runTask(
      _client,
      const DraftTask(),
      DraftInput(
        thread: thread,
        replyTo: replyTo,
        // Mail only. `recentOutboundToSender` matches on `to_json`, which a
        // chat never writes ('[]'), so the skip only makes explicit what the
        // LIKE would answer anyway — and a chat needs it less: the thread tail
        // already carries the owner's own chat voice, turn by turn.
        styleExamples: source == 'email'
            ? await _styleExamplesFor(source, replyTo.fromAddress)
            : const [],
        storylineSummary: await _storylineSummaryFor(source, key),
        aboutMe: aboutMe,
        now: DateTime.now(),
      ),
      // Zero, like extraction: pressing Regenerate should change the draft
      // because the thread changed, not because the sampler rolled differently.
      temperature: 0,
      maxTokens: _maxTokens,
    );

    if (result.replyBody.isEmpty) {
      // A retryable failure, deliberately. An empty answer from a local model
      // is usually a one-off, and the worker's retry-once policy is exactly the
      // right response — writing the blank draft instead would put an empty
      // composer in front of the user as though it were a suggestion.
      throw const LlmFormatException('The local model drafted an empty reply.');
    }

    await _store.upsertDraft(
      source: source,
      conversationKey: key,
      replyToMessageId: replyTo.id,
      body: result.replyBody,
      evidence: result.evidence,
      // Null rather than `[]`: "the model offered no short replies" and "the
      // options were read and there were none" are the same thing to every
      // reader, and one of the two spellings is shorter.
      optionsJson: result.options.isEmpty
          ? null
          : jsonEncode([
              for (final option in result.options)
                {'stance': option.stance, 'body': option.body},
            ]),
      status: 'suggested',
    );
    await _progress.noteDraft(source, id, state: 'done');
    _log.note({'chars': result.replyBody.length});
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
      final body = (row['body_text'] as String?)?.trim();
      final preview = (row['body_preview'] as String?)?.trim();
      final text = (body != null && body.isNotEmpty) ? body : (preview ?? '');
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
