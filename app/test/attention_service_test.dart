import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

void main() {
  late BondDatabase db;
  late MessageStore store;
  late AttentionService service;

  /// Pinned so the recency decay is the same on every run.
  final now = DateTime.utc(2026, 8, 29, 12);
  const String justNow = '2026-08-29T11:00:00Z';

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    service = AttentionService(store);
  });

  tearDown(() async => db.close());

  /// One thread with one inbound message and, optionally, an extraction on it.
  Future<void> seed(
    String key, {
    String state = 'waiting',
    String from = 'eric@x.com',
    String? intent,
    String? importance,
    String receivedAt = justNow,
    String? ctaText,
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'cta_text': ctaText,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
    await store.upsertMessage({
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_address': from,
      'received_at': receivedAt,
    });
    if (intent == null && importance == null) return;
    await store.writeExtraction(
      'email',
      '$key-m1',
      jsonEncode({
        'intent': intent ?? 'fyi',
        'importance': importance ?? 'normal',
      }),
    );
  }

  Future<String?> bucketOf(String key) async =>
      (await store.getConversationAi('email', key))?['bucket'] as String?;
  Future<String?> reasonOf(String key) async =>
      (await store.getConversationAi('email', key))?['bucket_reason'] as String?;
  Future<double?> scoreOf(String key) async =>
      ((await store.getConversationAi('email', key))?['attention_score'] as num?)
          ?.toDouble();

  group('scoring', () {
    test('scores every open thread and says how many', () async {
      await seed('c1', state: 'needs_reply');
      await seed('c2');

      expect(await service.recomputeAll(now: now), 2);
      expect(await scoreOf('c1'), isNotNull);
      expect(await scoreOf('c2'), isNotNull);
    });

    test('skips threads the LO has closed', () async {
      await seed('c1', state: 'done');

      expect(await service.recomputeAll(now: now), 0);
      expect(await scoreOf('c1'), isNull);
    });

    test('a needs-reply thread outranks a waiting one', () async {
      await seed('c1', state: 'needs_reply');
      await seed('c2', state: 'waiting');
      await service.recomputeAll(now: now);

      expect((await scoreOf('c1'))!, greaterThan((await scoreOf('c2'))!));
    });

    test('a later sender scores zero', () async {
      await seed('c1', state: 'needs_reply');
      await store.setSenderPref('eric@x.com', 'later');

      await service.recomputeAll(now: now);
      expect(await scoreOf('c1'), 0);
    });

    test('the intent from the extraction reaches the score', () async {
      await seed('c1', state: 'needs_reply', intent: 'question');
      await seed('c2', state: 'needs_reply', intent: 'fyi');
      await service.recomputeAll(now: now);

      expect((await scoreOf('c1'))!, greaterThan((await scoreOf('c2'))!));
    });

    test('an older thread scores below an identical newer one', () async {
      await seed('c1', state: 'needs_reply', receivedAt: justNow);
      await seed('c2', state: 'needs_reply', receivedAt: '2026-08-01T11:00:00Z');
      await service.recomputeAll(now: now);

      expect((await scoreOf('c1'))!, greaterThan((await scoreOf('c2'))!));
    });

    test('a corrupt extraction blob does not stop the pass', () async {
      await seed('c1', state: 'needs_reply');
      await store.writeExtraction('email', 'c1-m1', 'not json at all');

      expect(await service.recomputeAll(now: now), 1);
      expect(await scoreOf('c1'), isNotNull);
    });

    test('a thread with no messages at all still scores', () async {
      await store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'needs_reply',
        'last_message_at': justNow,
      });

      expect(await service.recomputeAll(now: now), 1);
      expect(await scoreOf('c1'), isNotNull);
    });

    test('an empty mailbox is a no-op', () async {
      expect(await service.recomputeAll(now: now), 0);
    });

    test('the pass is idempotent', () async {
      await seed('c1', state: 'needs_reply', intent: 'question');
      await service.recomputeAll(now: now);
      final first = await scoreOf('c1');
      await service.recomputeAll(now: now);

      expect(await scoreOf('c1'), first);
    });
  });

  group('bucket sweep', () {
    test('files a low-value fyi into Later', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'low_value');
    });

    test('and clears it again once the message stops being low-value', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);
      expect(await bucketOf('c1'), 'later');

      await store.writeExtraction(
        'email',
        'c1-m1',
        jsonEncode({'intent': 'request', 'importance': 'high'}),
      );
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
      expect(await reasonOf('c1'), isNull);
    });

    test('never defers a thread awaiting the LO', () async {
      await seed('c1', state: 'needs_reply', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
    });

    test('leaves a thread with no extraction in the inbox', () async {
      await seed('c1');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
    });

    test('a later sender rule defers even a high-importance request', () async {
      await seed('c1', intent: 'request', importance: 'high');
      await store.setSenderPref('eric@x.com', 'later');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'sender_pref');
    });

    test('a keep rule beats the model and clears a low_value bucket', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);
      expect(await bucketOf('c1'), 'later');

      await store.setSenderPref('eric@x.com', 'keep');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
    });

    test('the sweep never clears a bucket a sender rule put there', () async {
      await seed('c1', intent: 'request', importance: 'high');
      await store.setSenderPref('eric@x.com', 'later');
      store.rebucketSender('eric@x.com', bucket: 'later');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'sender_pref');
    });

    test('and never touches a thread a person deferred by hand', () async {
      // `user` is the most specific instruction anyone gave about this thread.
      // Nothing automatic gets to undo it in either direction.
      await seed('c1', intent: 'request', importance: 'high');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'user');
    });

    test('a keep rule does not undo a hand-deferred thread either', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      await store.setSenderPref('eric@x.com', 'keep');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'user');
    });

    test('the LATEST inbound sender decides which rule applies', () async {
      // Two senders on one thread; the newer one owns it.
      await store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'waiting',
        'last_message_at': justNow,
        'last_inbound_at': justNow,
      });
      await store.upsertMessage({
        'source_message_id': 'm-old',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'news@bulk.com',
        'received_at': '2026-08-01T10:00:00Z',
      });
      await store.upsertMessage({
        'source_message_id': 'm-new',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'dana@y.com',
        'received_at': justNow,
      });
      await store.setSenderPref('news@bulk.com', 'later');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull,
          reason: "the newsletter no longer owns a thread Dana replied on");
    });

    test('a done thread is swept but not scored', () async {
      await seed('c1', state: 'done', intent: 'fyi', importance: 'low');

      expect(await service.recomputeAll(now: now), 0);
      expect(await bucketOf('c1'), 'later');
      expect(await scoreOf('c1'), isNull);
    });
  });
}
