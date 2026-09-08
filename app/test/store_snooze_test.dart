import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The date a deferral carries, and what happens when it arrives.
///
/// The claim worth pinning hardest is the REASON a resurfaced thread comes
/// back with. Anything but `'user'` and the scoring sweep owns the row again,
/// which would file it straight back to Later on the very next pass — the
/// date would look ignored and nobody could see why.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedThread(
    String key, {
    String source = 'email',
    String subject = 'The lease',
    String receivedAt = '2026-09-04T10:00:00.000Z',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.test',
      'received_at': receivedAt,
      'body_text': 'The body.',
    });
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': 'waiting',
      'last_message_at': receivedAt,
    });
  }

  Future<Map<String, Object?>?> ai(String key, {String source = 'email'}) =>
      store.getConversationAi(source, key);

  group('setSnoozedUntil', () {
    test('writes a date onto a thread with no AI row at all', () async {
      await seedThread('c1');
      await store.setSnoozedUntil('email', 'c1', '2026-09-11T09:00:00.000Z');

      expect((await ai('c1'))?['snoozed_until'], '2026-09-11T09:00:00.000Z');
    });

    test('clears it, and leaves the bucket beside it alone', () async {
      await seedThread('c1');
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: 'later',
        reason: 'user',
      );
      await store.setSnoozedUntil('email', 'c1', '2026-09-11T09:00:00.000Z');
      await store.setSnoozedUntil('email', 'c1', null);

      final row = await ai('c1');
      expect(row?['snoozed_until'], isNull);
      expect(row?['bucket'], 'later');
      expect(row?['bucket_reason'], 'user');
    });
  });

  group('resurfaceDue', () {
    Future<void> defer(String key, String? until) async {
      await store.setConversationBucket(
        'email',
        key,
        bucket: 'later',
        reason: 'user',
      );
      if (until != null) await store.setSnoozedUntil('email', key, until);
    }

    test('a date that has arrived brings the thread back as the user\'s own',
        () async {
      await seedThread('c1');
      await defer('c1', '2026-09-05T09:00:00.000Z');

      final moved = await store.resurfaceDue('2026-09-06T08:00:00.000Z');

      expect(moved, 1);
      final row = await ai('c1');
      expect(row?['bucket'], isNull);
      // Not 'due', not 'low_value': the sweep re-files anything that is not
      // the user's own decision, and this IS the user's own decision.
      expect(row?['bucket_reason'], 'user');
      expect(row?['snoozed_until'], isNull);
    });

    test('a date still ahead is left where it is', () async {
      await seedThread('c1');
      await defer('c1', '2026-09-20T09:00:00.000Z');

      expect(await store.resurfaceDue('2026-09-06T08:00:00.000Z'), 0);
      final row = await ai('c1');
      expect(row?['bucket'], 'later');
      expect(row?['snoozed_until'], '2026-09-20T09:00:00.000Z');
    });

    test('a deferral with no date is never touched', () async {
      // Every sender-rule thread is this shape, and a rule has no "when".
      await seedThread('c1');
      await defer('c1', null);

      expect(await store.resurfaceDue('2027-01-01T00:00:00.000Z'), 0);
      expect((await ai('c1'))?['bucket'], 'later');
    });

    test('a sender rule\'s thread is never handed back by a date', () async {
      // Deferred by hand with a date, then the sender was muted: the rule
      // owns the row now, and the date it inherited must not pull the thread
      // out from under the rule — and stamp it `user`, which the sweep never
      // touches again.
      await seedThread('c1');
      await defer('c1', '2026-09-01T09:00:00.000Z');
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: 'later',
        reason: 'sender_pref',
      );

      expect(await store.resurfaceDue('2026-09-06T08:00:00.000Z'), 0);
      final row = await ai('c1');
      expect(row?['bucket'], 'later');
      expect(row?['bucket_reason'], 'sender_pref');
    });

    test('a sender rule drops the date in both directions', () async {
      await seedThread('c1');
      await defer('c1', '2026-09-01T09:00:00.000Z');

      await store.rebucketSender('dana@example.test', bucket: 'later');
      expect((await ai('c1'))?['snoozed_until'], isNull);

      await store.setSnoozedUntil('email', 'c1', '2026-09-01T09:00:00.000Z');
      await store.rebucketSender('dana@example.test', bucket: null);
      expect((await ai('c1'))?['snoozed_until'], isNull);
      expect((await ai('c1'))?['bucket'], isNull);
    });

    test('a thread that is not in Later keeps its own reason', () async {
      await seedThread('c1');
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: null,
        reason: 'low_value',
      );
      await store.setSnoozedUntil('email', 'c1', '2026-09-01T09:00:00.000Z');

      expect(await store.resurfaceDue('2026-09-06T08:00:00.000Z'), 0);
      expect((await ai('c1'))?['bucket_reason'], 'low_value');
    });

    test('several due rows all move, and the count says how many', () async {
      await seedThread('c1');
      await seedThread('c2', subject: 'The survey');
      await seedThread('c3', subject: 'The plat');
      await defer('c1', '2026-09-01T09:00:00.000Z');
      await defer('c2', '2026-09-02T09:00:00.000Z');
      await defer('c3', '2026-12-01T09:00:00.000Z');

      expect(await store.resurfaceDue('2026-09-06T08:00:00.000Z'), 2);
      expect((await ai('c3'))?['bucket'], 'later');
    });
  });

  test('loadConversations carries the date', () async {
    await seedThread('c1');
    await store.setConversationBucket(
      'email',
      'c1',
      bucket: 'later',
      reason: 'user',
    );
    await store.setSnoozedUntil('email', 'c1', '2026-09-11T09:00:00.000Z');

    final rows = await store.loadConversations();
    expect(rows.single.snoozedUntil, '2026-09-11T09:00:00.000Z');
  });

  test('a thread with no AI row reads as no date rather than a wrong one',
      () async {
    await seedThread('c1');
    expect((await store.loadConversations()).single.snoozedUntil, isNull);
  });

  group('messageById', () {
    test('finds one row, and says nothing about a key it does not have',
        () async {
      await seedThread('c1');

      final hit = await store.messageById('email', 'c1-m1');
      expect(hit?.id, 'c1-m1');
      expect(hit?.subject, 'The lease');
      expect(await store.messageById('email', 'nope'), isNull);
      // The source is half the key: a chat and a mail message may share an id.
      expect(await store.messageById('teams', 'c1-m1'), isNull);
    });
  });

  group('extractionFor', () {
    test('decodes what the handler wrote', () async {
      await seedThread('c1');
      await store.writeExtraction(
        'email',
        'c1-m1',
        '{"evidence":"They want the survey back.","topics":["survey"],'
            '"people":["Dana Whitfield"],"organizations":[],'
            '"project":"Lot 14","intent":"request","importance":"high"}',
      );

      final result = await store.extractionFor('email', 'c1-m1');
      expect(result?.evidence, 'They want the survey back.');
      expect(result?.topics, ['survey']);
      expect(result?.intent, 'request');
      expect(result?.project, 'Lot 14');
    });

    test('nothing stored is null', () async {
      await seedThread('c1');
      expect(await store.extractionFor('email', 'c1-m1'), isNull);
    });

    test('a blob that will not parse is null, never a throw', () async {
      // A panel reads this. A stale row must cost one absent section, not the
      // render around it.
      await seedThread('c1');
      await store.writeExtraction('email', 'c1-m1', 'not json at all');
      expect(await store.extractionFor('email', 'c1-m1'), isNull);

      await store.writeExtraction('email', 'c1-m1', '["a list, not an object"]');
      expect(await store.extractionFor('email', 'c1-m1'), isNull);
    });
  });
}
