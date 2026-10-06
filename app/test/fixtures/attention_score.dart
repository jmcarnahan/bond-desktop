import 'package:bond_inbox/data/message_store.dart';

/// Stores one thread's attention score, the way the attention pass stores
/// every thread's: through [MessageStore.writeAttentionPass], stamped now.
///
/// For a test that needs a score on a row and is not about the pass. The
/// store has no single-thread writer of its own any more, because nothing in
/// the app writes one score at a time.
Future<void> writeScore(
  MessageStore store,
  String source,
  String conversationKey,
  double score,
) =>
    store.writeAttentionPass(
      scores: [(source: source, key: conversationKey, score: score)],
      buckets: const [],
      stamp: MessageStore.isoStamp(DateTime.now()),
    );
