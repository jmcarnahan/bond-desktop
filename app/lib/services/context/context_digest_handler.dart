import 'dart:convert';

import '../../data/context_store.dart';
import '../../models/context_models.dart';
import '../activity_log.dart';
import '../ai_worker.dart';
import '../llm/context_digest_task.dart';
import '../llm/embeddings_client.dart';
import '../llm/json_task.dart';
import '../llm/llm_client.dart';

/// Turns one file of the owner's own project into the record a reply reads
/// instead of opening it.
///
/// Its own kind rather than the tail of the reconcile pass, and for the same
/// reason the attachment digest is not the tail of the text handler: the two
/// talk to different servers. Reading a folder is the disk plus the embedder;
/// understanding a file is the fast slot. Folded together, a fast server that
/// is not running would hold back the passages as well — and the passages are
/// what retrieval wants whether or not any model has read them.
///
/// The digest lands in two places on purpose. On the file row it is what the
/// brief's file map is built from; as a passage of the file it is the one
/// passage a question about FINDINGS can land on, because a question about a
/// conclusion very rarely shares vocabulary with the code that produced it.
///
/// Concurrency one: one fast-slot call per file, and the queue behind it is
/// already draining as fast as the server answers.
class ContextDigestHandler extends WorkHandler {
  /// A digest is a RECORD of one file — a purpose, a few findings, the
  /// questions it answers — which is a fraction of this even for a long file.
  static const int _maxTokens = 512;

  /// How many characters a file needs to be worth a call. Points at the
  /// store's constant so the queue's eligibility test and this guard are the
  /// same number: two numbers here would be a directory whose progress line
  /// never reached its own total.
  static const int minChars = ContextStore.digestMinChars;

  final ContextStore _context;
  final LlmClient _client;
  final EmbeddingsClient _embeddings;
  final ActivityLog _log;

  ContextDigestHandler(
    this._context,
    this._client,
    this._embeddings, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'context_digest';

  @override
  int get concurrency => 1;

  /// The entity id of one file: the directory AND the row.
  ///
  /// The row id alone would be enough to find the file, and would be the
  /// wrong key anyway — the directory it belongs to is what decides whether
  /// this call happens at all (its `digests` switch), and a queued item that
  /// cannot answer "whose file is this" would have to read the row to find
  /// out it should not have been queued.
  static String entityIdFor(String dirId, int fileId) => '$dirId|$fileId';

  /// [entityIdFor] read back, or null for anything that is not one.
  ///
  /// A `|` cannot appear in a directory id — sixteen hex characters — so the
  /// split is unambiguous whatever a hand-written row contains.
  static (String, int)? splitEntityId(String entityId) {
    final bar = entityId.indexOf('|');
    if (bar <= 0 || bar == entityId.length - 1) return null;
    final fileId = int.tryParse(entityId.substring(bar + 1));
    if (fileId == null) return null;
    return (entityId.substring(0, bar), fileId);
  }

  @override
  Future<void> run(Map<String, Object?> item) async {
    final split = splitEntityId(item['entity_id'] as String? ?? '');
    if (split == null) {
      _skip('malformed_entity');
      return;
    }
    final (dirId, fileId) = split;

    final file = await _context.fileById(fileId);
    if (file == null || file.dirId != dirId) {
      // Queued, then the FILE was deleted — or moved to another directory —
      // before the worker reached it. Done, not failed. Its own reason
      // rather than the directory's `gone`: the activity panel turns these
      // words into a sentence for a person, and "the directory is no longer
      // registered" is a different thing to have happened than one file
      // going away from a project that is still there.
      _skip('file_gone');
      return;
    }

    final dir = await _context.directory(dirId);
    if (dir == null) {
      _skip('gone');
      return;
    }
    if (!dir.digests) {
      // The switch went off between the enqueue and the claim. The row is
      // deliberately left `pending` rather than closed: turning summaries
      // back on must digest this file, not skip it forever.
      _skip('off');
      return;
    }

    if (file.digestStatus == 'done') {
      // A requeue over finished work — free, and the guard is what makes the
      // reconcile pass's per-pass requeue idempotent.
      _skip('already_digested');
      return;
    }

    if (file.textChars < minChars) {
      // Closed on the ROW, not only in the log. A file this short is not
      // going to grow words by being asked again, and leaving it `pending`
      // would put it back at the head of the next pass's worklist forever.
      await _context.setFileDigest(fileId, status: 'skipped');
      _skip('too_short');
      return;
    }

    final text = await _context.fileText(fileId);
    if (text == null || text.isEmpty) {
      // The row says there are words and the table has none. Closing the
      // digest here is what stops the pair being re-examined on every pass.
      await _context.setFileDigest(fileId, status: 'skipped');
      _skip('no_text');
      return;
    }

    // Exceptions propagate: `LlmUnavailableException` parks this kind, a bad
    // answer spends an attempt. The worker owns that ladder — but only for
    // the WORK row, and the work row is not the memory that matters here.
    // The reconcile pass revives every `done` or `error` digest row of a
    // pending file on the pass after next, so a file the model can never
    // answer for would be asked again a minute later, for ever, holding one
    // of the pass's capped slots each time. The FILE row has to remember
    // that the model gave up, and `filesPendingDigest` selects `pending`
    // only, so an `error` there leaves the worklist until the bytes change
    // and `resetFileDigest` puts it back.
    final ContextFileDigest digest;
    try {
      digest = await runTask(
        _client,
        const ContextDigestTask(),
        ContextDigestInput(
          relPath: file.relPath,
          kind: file.kind,
          text: text,
          now: DateTime.now(),
        ),
        temperature: 0,
        maxTokens: _maxTokens,
      );
    } on LlmUnavailableException {
      // The server, not the answer. Parked with no attempt spent, so the
      // file is still owed a digest and must stay `pending`.
      rethrow;
    } catch (e) {
      // The worker's own rule, not a restatement of it: a 400 is fatal on
      // the first attempt there, and a file row that waited for a second
      // attempt the worker will never make would be `pending` for good.
      final attempts = ((item['attempts'] as num?)?.toInt() ?? 0) + 1;
      if (AiWorker.isFatal(e, attempts)) {
        await _context.setFileDigest(fileId, status: 'error');
        _log.note({'digest_error': '$e'});
      }
      // Rethrown either way: the work row still has to record the failure
      // and spend the attempt, which is what decides whether there is a
      // retry at all.
      rethrow;
    }

    await _context.setFileDigest(
      fileId,
      status: 'done',
      digestJson: jsonEncode(digest.toJson()),
    );

    await _embedDigest(file.relPath, fileId, digest);

    _log.note({
      'kind_hint': digest.kindHint,
      'findings': digest.findings.length,
      'questions': digest.questionsAnswered.length,
    });
  }

  /// Files the digest as a passage of its own file.
  ///
  /// Appended rather than written into the chunk list, so a re-extraction's
  /// `replaceChunks` cannot renumber around it, and carrying the chunker's
  /// own header convention — every stored passage opens with
  /// `<relPath> · <locator>` — because the renderer strips that first line
  /// and prints the path off the file row instead.
  ///
  /// An embedding server that is down does NOT throw here, unlike in the
  /// reconcile pass: the digest is already written and already PAID FOR, and
  /// parking the kind would put that model call at risk of being spent
  /// twice. The passage keeps a NULL embedding, which is invisible to the
  /// index and to every KNN until something re-reads the file.
  Future<void> _embedDigest(
    String relPath,
    int fileId,
    ContextFileDigest digest,
  ) async {
    final body = [
      if (digest.purpose.isNotEmpty) digest.purpose,
      ...digest.findings,
      ...digest.questionsAnswered,
    ].join('\n');
    if (body.isEmpty) return;

    // The stored passage, and the string the vector is OF. They have to be
    // the same one: the reconcile pass's tail embeds `chunk_text` verbatim
    // when it picks up a passage this handler left un-embedded, so embedding
    // the body alone here would give the same row two different vectors
    // depending on which server was up the day it was written.
    final passage = '$relPath · digest\n$body';

    final chunkId = await _context.appendChunk(
      fileId,
      locator: 'digest',
      text: passage,
    );
    // The word index needs no vector. Filed here, before the embedding call,
    // so that a digest written while the embedding server is down is still
    // findable by the words it contains — which for a digest is most of its
    // value, since the findings are the one passage of a file phrased the
    // way a question about it is.
    await _context.ensureKeywordIndex();

    final result = await _embeddings.embedResult(
      passage,
      prefix: EmbeddingsClient.documentPrefix,
    );
    final vector = result.vector;
    if (vector == null) return;
    await _context.setChunkEmbedding(
      chunkId,
      // The vector's own width, not the index's constant: a wrong-width blob
      // has to be visibly wrong in the table rather than quietly refused.
      embedding: encodeEmbedding(vector),
      dims: vector.length,
      embedModel: EmbeddingsClient.documentModelTag,
    );
    await _context.indexPendingChunks();
  }

  void _skip(String reason) => _log
    ..noteStatus('skipped')
    ..note({'reason': reason});
}
