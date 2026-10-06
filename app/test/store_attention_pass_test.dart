import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/counting_interceptor.dart';

/// `MessageStore.writeAttentionPass`: the attention pass's writes in one
/// batch, each the same write the per-thread methods make.
void main() {
  late CountingInterceptor counter;
  late BondDatabase db;
  late MessageStore store;

  /// Older than any stamp the store writes.
  const oldStamp = '2000-01-01T00:00:00.000000Z';

  setUp(() {
    counter = CountingInterceptor();
    db = countingTestDb(counter);
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<Map<String, Object?>?> rowOf(String key) =>
      store.getConversationAi('email', key);

  // What the pass hands over: the instant it started.
  String stamp() => MessageStore.isoStamp(DateTime.now());

  Future<void> ageStamp(String key) => db.customUpdate(
        'UPDATE conversation_ai SET updated_at = ? '
        "WHERE source = 'email' AND conversation_key = ?",
        variables: [Variable(oldStamp), Variable(key)],
      );

  test('a missing row is created with the score and a stamp', () async {
    await store.writeAttentionPass(
      stamp: stamp(),
      scores: [(source: 'email', key: 'c1', score: 0.75)],
      buckets: const [],
    );

    final row = (await rowOf('c1'))!;
    expect(row['attention_score'], 0.75);
    expect(row['bucket'], isNull);
    expect(row['updated_at'], isA<String>());
  });

  test('a missing row is created with the bucket and its reason', () async {
    await store.writeAttentionPass(
      stamp: stamp(),
      scores: const [],
      buckets: [
        (source: 'email', key: 'c1', bucket: 'later', reason: 'low_value'),
      ],
    );

    final row = (await rowOf('c1'))!;
    expect(row['bucket'], 'later');
    expect(row['bucket_reason'], 'low_value');
    expect(row['attention_score'], isNull);
  });

  test("an existing row keeps every column the pass does not own", () async {
    final embedding = Uint8List.fromList([1, 2, 3, 4]);
    await store.upsertConversationAi(
      'email',
      'c1',
      embedding: embedding,
      embeddedHash: 'hash-1',
      embedModel: 'embed-test',
    );
    await store.setSnoozedUntil('email', 'c1', '2026-09-01T09:00:00.000000Z');
    await store.setConversationBucket('email', 'c1',
        bucket: 'later', reason: 'low_value');

    // A score alone leaves the bucket where it was.
    await store.writeAttentionPass(
      stamp: stamp(),
      scores: [(source: 'email', key: 'c1', score: 0.5)],
      buckets: const [],
    );
    var row = (await rowOf('c1'))!;
    expect(row['attention_score'], 0.5);
    expect(row['bucket'], 'later');
    expect(row['bucket_reason'], 'low_value');

    // A bucket alone leaves the score where it was.
    await store.writeAttentionPass(
      stamp: stamp(),
      scores: const [],
      buckets: [(source: 'email', key: 'c1', bucket: null, reason: null)],
    );
    row = (await rowOf('c1'))!;
    expect(row['attention_score'], 0.5);
    expect(row['bucket'], isNull, reason: 'a null bucket is written');
    expect(row['bucket_reason'], isNull);

    // And neither touched the embedding or the date.
    expect(row['embedding'], embedding);
    expect(row['embedded_hash'], 'hash-1');
    expect(row['embed_model'], 'embed-test');
    expect(row['snoozed_until'], '2026-09-01T09:00:00.000000Z');
  });

  test('both kinds of write stamp updated_at', () async {
    await store.writeAttentionPass(
      stamp: stamp(),
      scores: [(source: 'email', key: 'c1', score: 0.5)],
      buckets: [
        (source: 'email', key: 'c2', bucket: 'later', reason: 'sender_pref'),
      ],
    );
    await ageStamp('c1');
    await ageStamp('c2');

    // The same values again: still written, still stamped.
    await store.writeAttentionPass(
      stamp: stamp(),
      scores: [(source: 'email', key: 'c1', score: 0.5)],
      buckets: [
        (source: 'email', key: 'c2', bucket: 'later', reason: 'sender_pref'),
      ],
    );

    for (final key in ['c1', 'c2']) {
      final stamp = (await rowOf(key))!['updated_at'] as String;
      expect(stamp.compareTo(oldStamp), greaterThan(0), reason: key);
    }
  });

  test('the whole pass is one batch', () async {
    counter.reset();
    await store.writeAttentionPass(
      stamp: stamp(),
      scores: [
        (source: 'email', key: 'c1', score: 0.5),
        (source: 'teams', key: 'c2', score: 0.25),
      ],
      buckets: [
        (source: 'email', key: 'c1', bucket: 'later', reason: 'low_value'),
      ],
    );

    expect(counter.batched, 1);
    expect(counter.singleWrites, 0);
    expect((await store.getConversationAi('teams', 'c2'))!['attention_score'],
        0.25);
  });

  test('an empty call issues nothing', () async {
    counter.reset();
    await store.writeAttentionPass(
      scores: const [],
      buckets: const [],
      stamp: stamp(),
    );

    expect(counter.batched, 0);
    expect(counter.singleWrites, 0);
    expect(counter.selects, isEmpty);
  });
}
