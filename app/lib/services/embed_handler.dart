import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'extract_handler.dart';
import 'llm/embeddings_client.dart';
import 'llm/llm_client.dart';
import 'llm/message_block.dart';

/// What happened when one message was offered to the embedding server.
///
/// Four cases and not a bool, because the two handlers that share
/// [embedMessageRow] have to make four different decisions: a skip is success,
/// a rejection is a permanent no worth recording and moving past, and an
/// unavailable server is the only one of the four that must stop the queue.
enum MessageEmbedOutcome {
  /// A vector was written.
  embedded,

  /// The stored vector is already the vector this card would produce. No call
  /// was made.
  skipped,

  /// The embedding server is not answering. Nothing is wrong with the message.
  unavailable,

  /// The server answered, and not with a vector. Retrying reproduces it.
  rejected,
}

/// Embeds ONE message into the search corpus, guarding against re-doing work.
///
/// Top-level and shared rather than a method on the handler below, because two
/// callers reach it — [ExtractHandler], which embeds a message the moment its
/// facts land, and [EmbedHandler], which embeds whatever the queue still owes.
/// They must build the same card from the same row and honour the same hash,
/// or each would see the other's vector as stale and the two would spend the
/// rest of the mailbox overwriting each other.
///
/// [row] is a `messages` row as [MessageStore.getMessageRow] returns it.
Future<MessageEmbedOutcome> embedMessageRow(
  MessageStore store,
  EmbeddingsClient embeddings,
  String source,
  Map<String, Object?> row,
) async {
  final id = row['source_message_id'] as String? ?? '';
  final body = row['body_text'] as String?;
  final card = buildMessageCard(
    subject: row['subject'] as String?,
    sender: senderLine(Message.fromRow(row)),
    // The stored triage summary when there is one. The preview is the fallback
    // for a message whose body never came down with the delta.
    summary: row['summary'] as String?,
    body: (body?.isNotEmpty ?? false) ? body : row['body_preview'] as String?,
  );
  final hash = cardHash(card);

  // Both halves matter. The hash says the text has not changed; the tag says
  // the stored vector was made the way this build makes them. Checking the tag
  // is what lets a prefix or model change self-heal — every row written under
  // the old tag re-embeds on its next pass instead of being trusted forever.
  final meta = await store.messageVectorMeta(source, id);
  if (meta != null &&
      meta['embedded_hash'] == hash &&
      meta['embed_model'] == EmbeddingsClient.documentModelTag) {
    return MessageEmbedOutcome.skipped;
  }

  final result = await embeddings.embedResult(
    card,
    prefix: EmbeddingsClient.documentPrefix,
  );
  final vector = result.vector;
  if (vector == null) {
    return result.outcome == EmbedOutcome.unavailable
        ? MessageEmbedOutcome.unavailable
        : MessageEmbedOutcome.rejected;
  }

  await store.upsertMessageVector(
    source: source,
    sourceMessageId: id,
    embedding: encodeEmbedding(vector),
    // The vector's own width, not the index's constant: a wrong-width blob has
    // to be visibly wrong in the table rather than quietly refused by vec0.
    dims: vector.length,
    embeddedHash: hash,
    embedModel: EmbeddingsClient.documentModelTag,
    receivedAt: (row['received_at'] ?? row['created_at']) as String?,
  );
  // Straight into the nearest-neighbour index, so the message is searchable as
  // soon as it is embedded. The upsert cleared `indexed_at`, so this picks up
  // exactly the row just written plus anything an earlier failure left behind.
  await store.indexPendingVectors();
  return MessageEmbedOutcome.embedded;
}

/// The queue that gives every message a search vector.
///
/// It exists for the two cases the fast path cannot cover: the BACKLOG, which
/// is every message that arrived before this feature did, and the HEALING of
/// messages whose embedding server was down when their extraction ran. In the
/// ordinary case [ExtractHandler] has already embedded the message by the time
/// this item is claimed, and the hash guard makes the item free.
///
/// No model is involved. That matters for where it sits in the drain: a park
/// here is a park on the EMBEDDING server, and the worker parks one kind at a
/// time, so a missing `make embed` leaves the storyline and draft queues —
/// which talk to a different server entirely — draining normally behind it.
class EmbedHandler extends WorkHandler {
  final MessageStore _store;
  final EmbeddingsClient _embeddings;
  final ActivityLog _log;

  EmbedHandler(
    this._store,
    this._embeddings, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'embed_message';

  // Concurrency stays at the inherited 1. Embedding is sub-second local work
  // against a 300M model, and the queue is usually all hash-guard hits — there
  // is no wait here worth overlapping.

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? 'email';
    final id = item['entity_id'] as String? ?? '';

    final row = await _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Done, not failed.
    if (row == null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'deleted'});
      return;
    }

    // Queued at sync time while the message was still `pending`, then gated by
    // triage. Honouring the verdict here is what keeps a newsletter out of the
    // search corpus — and one sender's newsletters are alike enough that a
    // handful of them would crowd out real answers.  The `teams_source`
    // exception is legacy tolerance: a chat row stored before chats were
    // triaged is `skipped` for no judgement anyone made.
    if (row['triage_status'] == 'skipped' &&
        row['gate_reason'] != 'teams_source') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'gated'});
      return;
    }

    switch (await embedMessageRow(_store, _embeddings, source, row)) {
      case MessageEmbedOutcome.embedded:
        // Nothing else: a normal return is what marks the item done.
        _log.note({'embed': 'ok'});
      case MessageEmbedOutcome.skipped:
        _log
          ..noteStatus('skipped')
          ..note({'reason': 'unchanged'});
      case MessageEmbedOutcome.rejected:
        // Done, deliberately. The server read the request and said no, so the
        // next attempt reads the same no; and the client's own `onFail` has
        // already written the one `embed_fail` row this is worth.
        _log.note({'embed': 'rejected'});
      case MessageEmbedOutcome.unavailable:
        // The one case that must NOT spend an attempt: the same request will
        // succeed once `make embed` is running. Throwing this parks this kind
        // only and puts the item back to `pending`.
        throw const LlmUnavailableException('embedding server unavailable');
    }
  }
}
