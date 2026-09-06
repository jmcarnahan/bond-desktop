import 'dart:convert';

import '../../data/message_store.dart';
import '../../models/attachment_models.dart';
import '../../models/message_models.dart';
import '../activity_log.dart';
import '../ai_worker.dart';
import '../llm/attachment_digest_task.dart';
import '../llm/embeddings_client.dart';
import '../llm/json_task.dart';
import '../llm/llm_client.dart';
import 'attachment_policy.dart';

/// Turns one document's words into the record a person reads instead of
/// opening it.
///
/// Its own kind rather than the tail of [AttachmentTextHandler], because the
/// two talk to different servers: reading a file is Graph plus the embedder,
/// and understanding it is the fast slot. Folded together, a fast server that
/// is not running would hold back the words as well — and the words are what
/// search, retrieval and the panel's Text segment want whether or not any
/// model has read them.
///
/// Concurrency stays at the inherited 1. It is one fast-slot call per
/// document, and the queue behind it is already draining as fast as the server
/// answers.
class AttachmentDigestHandler extends WorkHandler {
  final MessageStore _store;
  final LlmClient _client;
  final EmbeddingsClient _embeddings;
  final ActivityLog _log;

  AttachmentDigestHandler(
    this._store,
    this._client,
    this._embeddings, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'attachment_digest';

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? 'email';
    final entityId = item['entity_id'] as String? ?? '';
    final (messageId, attachmentId) = splitAttachmentEntityId(entityId);
    if (attachmentId.isEmpty) {
      _skip('malformed_entity');
      return;
    }

    final row = await _store.attachmentRow(source, messageId, attachmentId);
    if (row == null) {
      _skip('deleted');
      return;
    }
    if (row['digest_status'] == 'done') {
      // A re-queue over finished work. Free, and the guard is what makes a
      // restore idempotent.
      _skip('already_digested');
      return;
    }
    if (row['text_status'] != 'done') {
      // Only the text handler queues this kind, and only with words — so this
      // is a resurrection, not the ordinary case.
      _skip('no_text');
      return;
    }

    final message = await _store.getMessageRow(source, messageId);
    if (message == null) {
      _skip('deleted');
      return;
    }
    // Gated between the words landing and this claim. The words are already
    // stored and stay; what is refused is spending a model call on them.
    final (eligible, why) = attachmentTextPolicy(message, row);
    if (!eligible) {
      _skip(why ?? 'ineligible');
      return;
    }

    final text = await _store.attachmentTextOf(source, messageId, attachmentId);
    if (text == null || text.isEmpty) {
      // The status says there are words and the table has none. Closing the
      // digest here is what stops the pair being re-examined on every drain.
      await _store.setAttachmentDigest(
        source,
        messageId,
        attachmentId,
        status: 'skipped',
      );
      _skip('no_text');
      return;
    }

    // A single row carries no attachments, and the covering message of a chat
    // file is very often nothing BUT the file — hydrated, its body reads
    // `Shared a file: …` to the prompt instead of nothing at all. The same
    // rule every single-row prompt path follows (see needs-you).
    var covering = Message.fromRow(message);
    if (message['has_attachments'] == 1) {
      covering = covering.withAttachments(
        await _store.attachmentRefsFor(
          source,
          messageId,
          conversationKey: message['conversation_key'] as String?,
        ),
      );
    }

    // Exceptions propagate: `LlmUnavailableException` parks this kind, a bad
    // answer spends an attempt. The worker owns that ladder.
    final digest = await runTask(
      _client,
      const AttachmentDigestTask(),
      AttachmentDigestInput(
        message: covering,
        name: row['name'] as String?,
        contentType: row['content_type'] as String?,
        size: (row['size'] as num?)?.toInt() ?? 0,
        text: text,
        now: DateTime.now(),
      ),
      temperature: 0,
    );

    await _store.setAttachmentDigest(
      source,
      messageId,
      attachmentId,
      status: 'done',
      digestJson: jsonEncode(digest.toJson()),
    );

    await _embedDigest(source, messageId, attachmentId, digest);

    // The needs-you re-verdict — a document that asks for something can change
    // whether its message wants the owner — lands in the next phase, together
    // with the fence that puts these digests in front of the needs-you prompt.
    // Requeuing before that fence exists would spend a model call on a
    // re-judgement that cannot see what changed.

    _log.note({
      'kind': digest.kind,
      'facts': digest.facts.length,
      'asks': digest.asks.length,
    });
  }

  /// Files the digest as a passage of its own document.
  ///
  /// The one passage that says what the whole file is about, which is what a
  /// person's own words usually search for — "the renewal terms", not a phrase
  /// from page nine. It is appended rather than written into the chunk list so
  /// a re-extraction's [MessageStore.replaceChunks] cannot renumber around it.
  ///
  /// An embedding server that is down does NOT throw here, unlike in the text
  /// handler: the digest is already written and already paid for, and parking
  /// the kind would put that model call at risk of being spent twice. The
  /// chunk keeps a NULL embedding, which is invisible to the index and to
  /// every KNN until something re-reads the document.
  Future<void> _embedDigest(
    String source,
    String messageId,
    String attachmentId,
    AttachmentDigest digest,
  ) async {
    final body = [
      if (digest.summary.isNotEmpty) digest.summary,
      ...digest.facts,
    ].join('\n');
    if (body.isEmpty) return;

    final id = await _store.appendChunk(
      source,
      messageId,
      attachmentId,
      locator: 'digest',
      text: body,
    );
    final result = await _embeddings.embedResult(
      body,
      prefix: EmbeddingsClient.documentPrefix,
    );
    final vector = result.vector;
    if (vector == null) return;
    await _store.setChunkEmbedding(
      id,
      embedding: encodeEmbedding(vector),
      dims: vector.length,
      embedModel: EmbeddingsClient.documentModelTag,
    );
    await _store.indexPendingChunks();
  }

  void _skip(String reason) => _log
    ..noteStatus('skipped')
    ..note({'reason': reason});
}
