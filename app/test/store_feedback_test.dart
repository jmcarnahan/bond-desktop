import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedConversation(
    String key, {
    String state = 'waiting',
    String lastMessageAt = '2026-08-28T10:00:00Z',
    String? lastInboundAt,
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': lastMessageAt,
      'last_inbound_at': lastInboundAt ?? lastMessageAt,
    });
  }

  Future<void> seedMessage(
    String key,
    String id, {
    String direction = 'inbound',
    String? from,
    String receivedAt = '2026-08-28T10:00:00Z',
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'from_address': from,
      'received_at': receivedAt,
    });
  }

  Future<List<Map<String, Object?>>> events() async => [
        for (final row in await db
            .customSelect('SELECT * FROM feedback_events ORDER BY id ASC')
            .get())
          Map<String, Object?>.from(row.data),
      ];

  group('feedback_events', () {
    test('appends, and appends again rather than replacing', () async {
      await store.recordFeedback(
        scope: 'sender',
        scopeKey: 'eric@x.com',
        direction: 'down',
        origin: 'explicit',
      );
      await store.recordFeedback(
        scope: 'sender',
        scopeKey: 'eric@x.com',
        direction: 'up',
        origin: 'explicit',
      );

      final rows = await events();
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['direction']), ['down', 'up']);
      // The history is the point: a table that kept only the latest answer
      // could not tell "changed their mind once" from "has always said this".
      expect(rows.first['id'], isNot(rows.last['id']));
    });

    test('carries scope, key, direction, origin and a stamp', () async {
      await store.recordFeedback(
        scope: 'thread',
        scopeKey: 'c1',
        direction: 'up',
        origin: 'implicit',
      );

      final row = (await events()).single;
      expect(row['scope'], 'thread');
      expect(row['scope_key'], 'c1');
      expect(row['direction'], 'up');
      expect(row['origin'], 'implicit');
      expect(DateTime.tryParse(row['created_at'] as String), isNotNull);
    });
  });

  group('sender_prefs', () {
    test('round-trips through whatever casing the mail carried', () async {
      await store.setSenderPref('Eric.Nolan@X.com', 'later');

      expect(await store.getSenderPref('eric.nolan@x.com'), 'later');
      expect(await store.getSenderPref('ERIC.NOLAN@X.COM'), 'later');
      expect(await store.allSenderPrefs(), {'eric.nolan@x.com': 'later'});
    });

    test('a second write replaces rather than duplicating', () async {
      await store.setSenderPref('eric@x.com', 'later');
      await store.setSenderPref('eric@x.com', 'keep');

      expect(await store.getSenderPref('eric@x.com'), 'keep');
      expect(await store.allSenderPrefs(), hasLength(1));
    });

    test('null deletes the rule, which is not the same as storing one',
        () async {
      await store.setSenderPref('eric@x.com', 'later');
      await store.setSenderPref('eric@x.com', null);

      expect(await store.getSenderPref('eric@x.com'), isNull);
      expect(await store.allSenderPrefs(), isEmpty);
    });

    test('deleting a rule nobody set is harmless', () async {
      await store.setSenderPref('nobody@x.com', null);
      expect(await store.allSenderPrefs(), isEmpty);
    });

    test('a sender nobody has ruled on has no rule', () async {
      expect(await store.getSenderPref('stranger@x.com'), isNull);
    });
  });

  group('app_prefs', () {
    test('set then get', () async {
      await store.setPref('attention_threshold', '0.7');
      expect(await store.getPref('attention_threshold'), '0.7');
    });

    test('a second set overwrites', () async {
      await store.setPref('about_me', 'first');
      await store.setPref('about_me', 'second');
      expect(await store.getPref('about_me'), 'second');
    });

    test('an unset key is null, not an empty string', () async {
      expect(await store.getPref('never_written'), isNull);
    });
  });

  group('setConversationBucket', () {
    test('writes bucket and reason, creating the ai row if needed', () async {
      await seedConversation('c1');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'low_value');

      final ai = (await store.getConversationAi('email', 'c1'))!;
      expect(ai['bucket'], 'later');
      expect(ai['bucket_reason'], 'low_value');
    });

    test('null clears both columns', () async {
      await seedConversation('c1');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      await store.setConversationBucket('email', 'c1', bucket: null);

      final ai = (await store.getConversationAi('email', 'c1'))!;
      expect(ai['bucket'], isNull);
      expect(ai['bucket_reason'], isNull);
    });

    test('leaves an embedding on the same row alone', () async {
      await seedConversation('c1');
      await store.upsertConversationAi('email', 'c1', embeddedHash: 'h1');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');

      expect((await store.getConversationAi('email', 'c1'))!['embedded_hash'],
          'h1');
    });
  });

  group('writeAttentionScore', () {
    test('writes, and creating the ai row if needed', () async {
      await seedConversation('c1');
      await store.writeAttentionScore('email', 'c1', 1.25);
      expect((await store.getConversationAi('email', 'c1'))!['attention_score'],
          1.25);
    });

    test('does not disturb a bucket sitting on the same row', () async {
      await seedConversation('c1');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      await store.writeAttentionScore('email', 'c1', 0.5);

      final ai = (await store.getConversationAi('email', 'c1'))!;
      expect(ai['bucket'], 'later');
      expect(ai['bucket_reason'], 'user');
      expect(ai['attention_score'], 0.5);
    });
  });

  group('bucketReasons', () {
    test('lists only the threads that are actually bucketed', () async {
      await seedConversation('c1');
      await seedConversation('c2');
      await seedConversation('c3');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      await store.setConversationBucket('email', 'c2',
          bucket: 'later', reason: 'low_value');
      await store.writeAttentionScore('email', 'c3', 1);

      expect(await store.bucketReasons(), {'c1': 'user', 'c2': 'low_value'});
    });
  });

  group('loadConversations carries the AI columns', () {
    test('bucket and attention score come back on the row', () async {
      await seedConversation('c1');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      await store.writeAttentionScore('email', 'c1', 1.5);

      final conversation = (await store.loadConversations()).single;
      expect(conversation.bucket, 'later');
      expect(conversation.attentionScore, 1.5);
    });

    test('a thread with no ai row still loads, with both null', () async {
      await seedConversation('c1');
      final conversation = (await store.loadConversations()).single;
      expect(conversation.bucket, isNull);
      expect(conversation.attentionScore, isNull);
    });

    test('the ordering is unchanged by the join', () async {
      await seedConversation('old', lastMessageAt: '2026-08-01T10:00:00Z');
      await seedConversation('new', lastMessageAt: '2026-08-28T10:00:00Z');
      await store.setConversationBucket('email', 'new', bucket: 'later');

      expect((await store.loadConversations()).map((c) => c.id),
          ['new', 'old']);
    });

    test('the state filter still works', () async {
      await seedConversation('c1', state: 'needs_reply');
      await seedConversation('c2', state: 'waiting');

      final rows =
          await store.loadConversations(state: ConversationState.needsReply);
      expect(rows.map((c) => c.id), ['c1']);
    });
  });

  group('rebucketSender', () {
    test('moves exactly the threads that sender owns, and counts them',
        () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'eric@x.com');
      await seedConversation('c2');
      await seedMessage('c2', 'm2', from: 'eric@x.com');
      await seedConversation('c3');
      await seedMessage('c3', 'm3', from: 'dana@y.com');

      final affected = await store.rebucketSender('eric@x.com',
          bucket: 'later');

      expect(affected, 2);
      final buckets = {
        for (final c in await store.loadConversations()) c.id: c.bucket,
      };
      expect(buckets, {'c1': 'later', 'c2': 'later', 'c3': null});
      expect(await store.bucketReasons(),
          {'c1': 'sender_pref', 'c2': 'sender_pref'});
    });

    test('matches whatever casing the message carried', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'Eric@X.com');

      expect(await store.rebucketSender('eric@x.com', bucket: 'later'), 1);
    });

    test('the LATEST inbound sender owns the thread', () async {
      // A newsletter the LO forwarded on, answered by a colleague. Silencing
      // the newsletter must not bury the colleague's reply.
      await seedConversation('c1');
      await seedMessage('c1', 'm1',
          from: 'news@bulk.com', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage('c1', 'm2',
          from: 'dana@y.com', receivedAt: '2026-08-28T10:00:00Z');

      expect(await store.rebucketSender('news@bulk.com', bucket: 'later'), 0);
      expect((await store.loadConversations()).single.bucket, isNull);

      expect(await store.rebucketSender('dana@y.com', bucket: 'later'), 1);
      expect((await store.loadConversations()).single.bucket, 'later');
    });

    test('outbound mail never makes anyone the owner', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1',
          from: 'eric@x.com', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage('c1', 'm2',
          direction: 'outbound',
          from: 'me@lo.com',
          receivedAt: '2026-08-28T10:00:00Z');

      expect(await store.rebucketSender('me@lo.com', bucket: 'later'), 0);
      expect(await store.rebucketSender('eric@x.com', bucket: 'later'), 1);
    });

    test('null clears the bucket and its reason', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'eric@x.com');
      await store.rebucketSender('eric@x.com', bucket: 'later');

      expect(await store.rebucketSender('eric@x.com', bucket: null), 1);
      expect((await store.loadConversations()).single.bucket, isNull);
      expect(await store.bucketReasons(), isEmpty);
    });

    test('a sender with no mail changes nothing and reports nothing', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'eric@x.com');

      expect(await store.rebucketSender('stranger@x.com', bucket: 'later'), 0);
    });

    test('running it twice reports the same count both times', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'eric@x.com');

      expect(await store.rebucketSender('eric@x.com', bucket: 'later'), 1);
      expect(await store.rebucketSender('eric@x.com', bucket: 'later'), 1);
    });
  });

  group('senderReplyRates', () {
    test('counts a sender answered in every thread as 1.0', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'eric@x.com');
      await seedMessage('c1', 'm2', direction: 'outbound', from: 'me@lo.com');

      expect((await store.senderReplyRates())['eric@x.com'], 1.0);
    });

    test('and one never answered as 0', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'news@bulk.com');

      expect((await store.senderReplyRates())['news@bulk.com'], 0.0);
    });

    test('one of two threads answered is a half', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'eric@x.com');
      await seedMessage('c1', 'm2', direction: 'outbound', from: 'me@lo.com');
      await seedConversation('c2');
      await seedMessage('c2', 'm3', from: 'eric@x.com');

      expect((await store.senderReplyRates())['eric@x.com'], 0.5);
    });

    test('two messages in one thread still count as one thread', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1',
          from: 'eric@x.com', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage('c1', 'm2',
          from: 'eric@x.com', receivedAt: '2026-08-02T10:00:00Z');

      expect((await store.senderReplyRates())['eric@x.com'], 0.0);
    });

    test('casing is folded together', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'Eric@X.com');
      await seedConversation('c2');
      await seedMessage('c2', 'm2', from: 'eric@x.com');
      await seedMessage('c2', 'm3', direction: 'outbound', from: 'me@lo.com');

      expect(await store.senderReplyRates(), {'eric@x.com': 0.5});
    });

    test('mail with no sender address is skipped, not keyed on empty',
        () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1');

      expect(await store.senderReplyRates(), isEmpty);
    });
  });

  group('latestInboundMeta', () {
    test('returns the newest inbound message per conversation', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'old',
          from: 'a@x.com', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage('c1', 'new',
          from: 'b@x.com', receivedAt: '2026-08-28T10:00:00Z');

      final meta = (await store.latestInboundMeta())['c1']!;
      expect(meta['source_message_id'], 'new');
      expect(meta['from_address'], 'b@x.com');
      expect(meta['received_at'], '2026-08-28T10:00:00Z');
    });

    test('ignores outbound mail however recent', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'in',
          from: 'a@x.com', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage('c1', 'out',
          direction: 'outbound',
          from: 'me@lo.com',
          receivedAt: '2026-08-28T10:00:00Z');

      expect((await store.latestInboundMeta())['c1']!['source_message_id'],
          'in');
    });

    test('joins the extraction of that message and no other', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'old',
          from: 'a@x.com', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage('c1', 'new',
          from: 'a@x.com', receivedAt: '2026-08-28T10:00:00Z');
      await store.writeExtraction(
          'email', 'old', jsonEncode({'intent': 'request'}));
      await store.writeExtraction('email', 'new', jsonEncode({'intent': 'fyi'}));

      final raw =
          (await store.latestInboundMeta())['c1']!['extraction_json'] as String;
      expect(jsonDecode(raw), {'intent': 'fyi'});
    });

    test('a message with no extraction comes back with a null blob', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'a@x.com');

      expect((await store.latestInboundMeta())['c1']!['extraction_json'],
          isNull);
    });

    test('a thread with only outbound mail is absent entirely', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', direction: 'outbound', from: 'me@lo.com');

      expect(await store.latestInboundMeta(), isEmpty);
    });

    test('the tie-break is deterministic across reads', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'aaa',
          from: 'a@x.com', receivedAt: '2026-08-28T10:00:00Z');
      await seedMessage('c1', 'zzz',
          from: 'z@x.com', receivedAt: '2026-08-28T10:00:00Z');

      // Same second, so `source_message_id DESC` decides — and must decide the
      // same way every time, or a sender rule would apply on one pass and not
      // the next.
      for (var i = 0; i < 5; i++) {
        expect((await store.latestInboundMeta())['c1']!['from_address'],
            'z@x.com');
      }
      expect(await store.rebucketSender('z@x.com', bucket: 'later'), 1);
      expect(await store.rebucketSender('a@x.com', bucket: 'later'), 0);
    });

    test('an empty source list reads nothing rather than everything', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', from: 'a@x.com');

      expect(await store.latestInboundMeta(sources: const []), isEmpty);
    });
  });
}
