import 'dart:convert';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late MessageStore store;
  late AttentionService service;

  /// Pinned so the recency decay is the same on every run.
  final now = DateTime.utc(2026, 8, 29, 12);
  const String justNow = '2026-08-29T11:00:00Z';

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
    service = AttentionService(store);
  });

  tearDown(() => db.close());

  /// One thread with one inbound message and, optionally, an extraction on it.
  void seed(
    String key, {
    String state = 'waiting',
    String from = 'eric@x.com',
    String? intent,
    String? importance,
    String receivedAt = justNow,
    String? ctaText,
  }) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'cta_text': ctaText,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
    store.upsertMessage({
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_address': from,
      'received_at': receivedAt,
    });
    if (intent == null && importance == null) return;
    store.writeExtraction(
      'email',
      '$key-m1',
      jsonEncode({
        'intent': intent ?? 'fyi',
        'importance': importance ?? 'normal',
      }),
    );
  }

  String? bucketOf(String key) =>
      store.getConversationAi('email', key)?['bucket'] as String?;
  String? reasonOf(String key) =>
      store.getConversationAi('email', key)?['bucket_reason'] as String?;
  double? scoreOf(String key) =>
      (store.getConversationAi('email', key)?['attention_score'] as num?)
          ?.toDouble();

  group('scoring', () {
    test('scores every open thread and says how many', () {
      seed('c1', state: 'needs_reply');
      seed('c2');

      expect(service.recomputeAll(now: now), 2);
      expect(scoreOf('c1'), isNotNull);
      expect(scoreOf('c2'), isNotNull);
    });

    test('skips threads the LO has closed', () {
      seed('c1', state: 'done');

      expect(service.recomputeAll(now: now), 0);
      expect(scoreOf('c1'), isNull);
    });

    test('a needs-reply thread outranks a waiting one', () {
      seed('c1', state: 'needs_reply');
      seed('c2', state: 'waiting');
      service.recomputeAll(now: now);

      expect(scoreOf('c1')!, greaterThan(scoreOf('c2')!));
    });

    test('a later sender scores zero', () {
      seed('c1', state: 'needs_reply');
      store.setSenderPref('eric@x.com', 'later');

      service.recomputeAll(now: now);
      expect(scoreOf('c1'), 0);
    });

    test('the intent from the extraction reaches the score', () {
      seed('c1', state: 'needs_reply', intent: 'question');
      seed('c2', state: 'needs_reply', intent: 'fyi');
      service.recomputeAll(now: now);

      expect(scoreOf('c1')!, greaterThan(scoreOf('c2')!));
    });

    test('an older thread scores below an identical newer one', () {
      seed('c1', state: 'needs_reply', receivedAt: justNow);
      seed('c2', state: 'needs_reply', receivedAt: '2026-08-01T11:00:00Z');
      service.recomputeAll(now: now);

      expect(scoreOf('c1')!, greaterThan(scoreOf('c2')!));
    });

    test('a corrupt extraction blob does not stop the pass', () {
      seed('c1', state: 'needs_reply');
      store.writeExtraction('email', 'c1-m1', 'not json at all');

      expect(service.recomputeAll(now: now), 1);
      expect(scoreOf('c1'), isNotNull);
    });

    test('a thread with no messages at all still scores', () {
      store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'needs_reply',
        'last_message_at': justNow,
      });

      expect(service.recomputeAll(now: now), 1);
      expect(scoreOf('c1'), isNotNull);
    });

    test('an empty mailbox is a no-op', () {
      expect(service.recomputeAll(now: now), 0);
    });

    test('the pass is idempotent', () {
      seed('c1', state: 'needs_reply', intent: 'question');
      service.recomputeAll(now: now);
      final first = scoreOf('c1');
      service.recomputeAll(now: now);

      expect(scoreOf('c1'), first);
    });
  });

  group('bucket sweep', () {
    test('files a low-value fyi into Later', () {
      seed('c1', intent: 'fyi', importance: 'low');
      service.recomputeAll(now: now);

      expect(bucketOf('c1'), 'later');
      expect(reasonOf('c1'), 'low_value');
    });

    test('and clears it again once the message stops being low-value', () {
      seed('c1', intent: 'fyi', importance: 'low');
      service.recomputeAll(now: now);
      expect(bucketOf('c1'), 'later');

      store.writeExtraction(
        'email',
        'c1-m1',
        jsonEncode({'intent': 'request', 'importance': 'high'}),
      );
      service.recomputeAll(now: now);

      expect(bucketOf('c1'), isNull);
      expect(reasonOf('c1'), isNull);
    });

    test('never defers a thread awaiting the LO', () {
      seed('c1', state: 'needs_reply', intent: 'fyi', importance: 'low');
      service.recomputeAll(now: now);

      expect(bucketOf('c1'), isNull);
    });

    test('leaves a thread with no extraction in the inbox', () {
      seed('c1');
      service.recomputeAll(now: now);

      expect(bucketOf('c1'), isNull);
    });

    test('a later sender rule defers even a high-importance request', () {
      seed('c1', intent: 'request', importance: 'high');
      store.setSenderPref('eric@x.com', 'later');
      service.recomputeAll(now: now);

      expect(bucketOf('c1'), 'later');
      expect(reasonOf('c1'), 'sender_pref');
    });

    test('a keep rule beats the model and clears a low_value bucket', () {
      seed('c1', intent: 'fyi', importance: 'low');
      service.recomputeAll(now: now);
      expect(bucketOf('c1'), 'later');

      store.setSenderPref('eric@x.com', 'keep');
      service.recomputeAll(now: now);

      expect(bucketOf('c1'), isNull);
    });

    test('the sweep never clears a bucket a sender rule put there', () {
      seed('c1', intent: 'request', importance: 'high');
      store.setSenderPref('eric@x.com', 'later');
      store.rebucketSender('eric@x.com', bucket: 'later');

      service.recomputeAll(now: now);

      expect(bucketOf('c1'), 'later');
      expect(reasonOf('c1'), 'sender_pref');
    });

    test('and never touches a thread a person deferred by hand', () {
      // `user` is the most specific instruction anyone gave about this thread.
      // Nothing automatic gets to undo it in either direction.
      seed('c1', intent: 'request', importance: 'high');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');

      service.recomputeAll(now: now);

      expect(bucketOf('c1'), 'later');
      expect(reasonOf('c1'), 'user');
    });

    test('a keep rule does not undo a hand-deferred thread either', () {
      seed('c1', intent: 'fyi', importance: 'low');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      store.setSenderPref('eric@x.com', 'keep');

      service.recomputeAll(now: now);

      expect(bucketOf('c1'), 'later');
      expect(reasonOf('c1'), 'user');
    });

    test('the LATEST inbound sender decides which rule applies', () {
      // Two senders on one thread; the newer one owns it.
      store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'waiting',
        'last_message_at': justNow,
        'last_inbound_at': justNow,
      });
      store.upsertMessage({
        'source_message_id': 'm-old',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'news@bulk.com',
        'received_at': '2026-08-01T10:00:00Z',
      });
      store.upsertMessage({
        'source_message_id': 'm-new',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'dana@y.com',
        'received_at': justNow,
      });
      store.setSenderPref('news@bulk.com', 'later');

      service.recomputeAll(now: now);

      expect(bucketOf('c1'), isNull,
          reason: "the newsletter no longer owns a thread Dana replied on");
    });

    test('a done thread is swept but not scored', () {
      seed('c1', state: 'done', intent: 'fyi', importance: 'low');

      expect(service.recomputeAll(now: now), 0);
      expect(bucketOf('c1'), 'later');
      expect(scoreOf('c1'), isNull);
    });
  });
}
