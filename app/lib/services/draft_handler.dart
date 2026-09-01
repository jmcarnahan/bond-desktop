import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'llm/draft_task.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';

/// Writes one suggested reply for one conversation.
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
  /// nothing downstream would notice.
  static const int _maxTokens = 1024;

  /// Two past replies, clipped: a tone sample, not a second thread.
  static const int _styleExamples = 2;
  static const int _styleExampleCap = 750;

  final MessageStore _store;
  final LlmClient _client;
  final ActivityLog _log;

  DraftHandler(this._store, this._client, {ActivityLog? activityLog})
      : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'draft';

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final key = item['entity_id'] as String? ?? '';

    // Already drafted. Two enqueues racing to the same conversation is
    // benign — the first one's suggestion is as good as the second's — and
    // returning here spends no model time discovering that.
    if (await _store.getDraft(source, key) != null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'already_drafted'});
      return;
    }

    final replyToRow = await _store.newestInboundMessage(source, key);
    // Queued, then the thread's mail went away. Nothing to reply to and
    // nothing wrong: the item is done, not failed.
    if (replyToRow == null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'no_reply_target'});
      return;
    }
    final replyTo = Message.fromRow(replyToRow);

    final result = await runTask(
      _client,
      const DraftTask(),
      DraftInput(
        thread: await _store.loadThread(key, sources: [source]),
        replyTo: replyTo,
        styleExamples: await _styleExamplesFor(source, replyTo.fromAddress),
        storylineSummary: await _storylineSummaryFor(source, key),
        aboutMe: await _store.getPref(aboutMeKey),
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
      status: 'suggested',
    );
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
