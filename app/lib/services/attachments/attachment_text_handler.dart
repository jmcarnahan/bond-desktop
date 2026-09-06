import '../../data/message_store.dart';
import '../../models/attachment_models.dart';
import '../activity_log.dart';
import '../ai_worker.dart';
import '../backend/attachment_backend.dart';
import '../graph_mail.dart';
import '../graph_teams.dart';
import '../llm/embeddings_client.dart';
import '../llm/llm_client.dart';
import 'attachment_chunker.dart';
import 'attachment_policy.dart';

/// Reads one attached document and files its passages.
///
/// **Two servers, and neither of them is a chat model.** It talks to Graph for
/// the words and to the embedding server for the vectors, which is what fixes
/// where it sits in the drain: a park here is a park on `make embed`, the
/// worker parks one kind at a time, and so a missing embedding server leaves
/// the storyline and draft queues — on an entirely different machine port —
/// draining normally behind it.
///
/// The digest is a SEPARATE kind for the mirror-image reason. Reading a
/// document and understanding it are different costs against different
/// servers, and folding them together would mean a fast server that is not
/// running holds back the words too — words that search, retrieval and the
/// panel's Text segment all want whether or not any model has read them.
///
/// Concurrency two: one Graph fetch dominates an item's wall clock, the embeds
/// behind it are sub-second, and two items touch disjoint rows.
class AttachmentTextHandler extends WorkHandler {
  final MessageStore _store;
  final AttachmentBackend _backend;
  final EmbeddingsClient _embeddings;
  final ActivityLog _log;

  AttachmentTextHandler(
    this._store,
    this._backend,
    this._embeddings, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'attachment_text';

  @override
  int get concurrency => 2;

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? 'email';
    final entityId = item['entity_id'] as String? ?? '';
    final (messageId, attachmentId) = splitAttachmentEntityId(entityId);
    if (attachmentId.isEmpty) {
      // A work row that cannot be parsed still has to be able to complete.
      _skip('malformed_entity');
      return;
    }

    final row = await _store.attachmentRow(source, messageId, attachmentId);
    if (row == null) {
      // Queued, then the message was deleted before the worker reached it.
      // Done, not failed.
      _skip('deleted');
      return;
    }
    final message = await _store.getMessageRow(source, messageId);
    if (message == null) {
      _skip('deleted');
      return;
    }

    // Asked AGAIN, after the sync already asked it: a message can be gated
    // between the enqueue and the claim — the user files the thread, a
    // re-triage skips it — and a judgement made only at enqueue time would
    // leave this fetching a document nobody will ever be shown.
    final (eligible, why) = attachmentTextPolicy(message, row);
    if (!eligible) {
      await _store.setAttachmentText(
        source,
        messageId,
        attachmentId,
        status: 'skipped',
        reason: why,
      );
      _skip(why ?? 'ineligible');
      return;
    }

    // The resume path. The words landed on an earlier pass and the embedding
    // server went away part-way through the passages; the item came back
    // `pending` with nothing spent, and what is left to do is the tail.
    if (row['text_status'] == 'done') {
      final pending =
          await _store.unembeddedChunks(source, messageId, attachmentId);
      if (pending.isEmpty) {
        // A raced enqueue, or a requeue of finished work.
        _skip('already_extracted');
        return;
      }
      final embedded = await _embedChunks(
        [for (final chunk in pending) (id: chunk.id, text: chunk.text)],
        chunks: pending.length,
      );
      await _store.indexPendingChunks();
      await _store.enqueueWork('attachment_digest', source, entityId);
      _log.note({'chunks': pending.length, 'embedded': embedded, 'resumed': 1});
      return;
    }

    final ref = AttachmentRef.fromRow(
      row,
      conversationKey: message['conversation_key'] as String?,
    );

    final watch = Stopwatch()..start();
    final AttachmentText extracted;
    try {
      extracted = await _backend.extractText(ref);
    } on AttachmentUnavailable catch (e) {
      // The seam says a refusal comes back as a skipped [AttachmentText] and
      // never as a throw. This is here so the STORE's state does not depend on
      // that promise being kept: a permanent refusal that arrived as an
      // exception is still a permanent refusal.
      await _store.setAttachmentText(
        source,
        messageId,
        attachmentId,
        status: 'skipped',
        reason: e.reason,
      );
      _skip(e.reason);
      return;
    } on GraphMailException catch (e) {
      if (!_isGone(e.statusCode)) rethrow;
      await _markGone(source, messageId, attachmentId);
      return;
    } on GraphTeamsException catch (e) {
      if (!_isGone(e.statusCode)) rethrow;
      await _markGone(source, messageId, attachmentId);
      return;
    }
    // Everything else propagates on purpose: `NotSignedIn` and
    // `ReconsentRequired` park the whole drain, a 5xx or a dropped socket
    // spends an attempt. `AiWorker` owns that ladder and this handler must not
    // hold a second opinion about it.

    // Written before the outcome is judged, because the cost of reading a
    // document is exactly what tells a slow drain from a big mailbox — and a
    // skip that cost a 10 MB download is worth seeing.
    _log.note({
      'fetch_ms': watch.elapsedMilliseconds,
      'bytes': extracted.fetchedBytes,
    });

    if (extracted.status != 'ok') {
      await _store.setAttachmentText(
        source,
        messageId,
        attachmentId,
        status: 'skipped',
        reason: extracted.reason,
      );
      _skip(extracted.reason ?? 'empty');
      return;
    }

    final text = extracted.text ?? '';
    await _store.setAttachmentText(
      source,
      messageId,
      attachmentId,
      status: 'done',
      text: text,
      truncated: extracted.truncated,
    );

    final chunks = chunkAttachmentText(
      text,
      contentType: ref.contentType ?? '',
      name: ref.name,
    );
    // Deterministic, so a retry after a park re-derives exactly these passages
    // and replaces them with themselves rather than doubling them.
    final ids = await _store.replaceChunks(
      source,
      messageId,
      attachmentId,
      [
        for (var i = 0; i < chunks.length; i++)
          (seq: i, locator: chunks[i].locator, text: chunks[i].text),
      ],
    );

    final embedded = await _embedChunks(
      [
        for (var i = 0; i < ids.length; i++) (id: ids[i], text: chunks[i].text),
      ],
      chunks: chunks.length,
    );

    await _store.indexPendingChunks();
    // Only now, and only with words: a document with nothing in it has nothing
    // for a model to read, and queuing one anyway would spend a fast-slot call
    // establishing that.
    await _store.enqueueWork('attachment_digest', source, entityId);

    _log.note({
      'chars': text.length,
      'chunks': chunks.length,
      'embedded': embedded,
      'truncated': extracted.truncated,
    });
  }

  /// Embeds [pending] one POST at a time, and says how many landed.
  ///
  /// [chunks] is only for the note written on the way out of an unavailable
  /// server, so a person reading the activity row can see how far the document
  /// got before the queue parked.
  Future<int> _embedChunks(
    List<({int id, String text})> pending, {
    required int chunks,
  }) async {
    var embedded = 0;
    for (final chunk in pending) {
      final result = await _embeddings.embedResult(
        chunk.text,
        prefix: EmbeddingsClient.documentPrefix,
      );
      final vector = result.vector;
      if (vector == null) {
        if (result.outcome == EmbedOutcome.unavailable) {
          // The text and the passages are KEPT. Throwing parks this kind only
          // and puts the item back to `pending` with no attempt spent; the
          // resume path at the top of [run] picks up exactly the tail that is
          // still un-embedded once `make embed` is running.
          _log.note({'chunks': chunks, 'embedded': embedded});
          throw const LlmUnavailableException('embedding server unavailable');
        }
        // Rejected: the server read the request and said no, so the next
        // attempt reads the same no. The row keeps a NULL embedding, which is
        // invisible to both the index's backfill and every KNN.
        continue;
      }
      await _store.setChunkEmbedding(
        chunk.id,
        embedding: encodeEmbedding(vector),
        // The vector's own width, not the index's constant: a wrong-width blob
        // has to be visibly wrong in the table rather than quietly refused.
        dims: vector.length,
        embedModel: EmbeddingsClient.documentModelTag,
      );
      embedded++;
    }
    return embedded;
  }

  /// 404 and 410 are the two Graph answers that mean the file is not coming
  /// back. Every other status is transport and belongs to the worker's ladder.
  static bool _isGone(int? status) => status == 404 || status == 410;

  Future<void> _markGone(
    String source,
    String messageId,
    String attachmentId,
  ) async {
    await _store.setAttachmentText(
      source,
      messageId,
      attachmentId,
      status: 'skipped',
      reason: 'gone',
    );
    _skip('gone');
  }

  void _skip(String reason) => _log
    ..noteStatus('skipped')
    ..note({'reason': reason});
}
