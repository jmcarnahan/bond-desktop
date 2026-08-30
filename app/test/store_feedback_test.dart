import 'dart:convert';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late MessageStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  void seedConversation(
    String key, {
    String state = 'waiting',
    String lastMessageAt = '2026-08-28T10:00:00Z',
    String? lastInboundAt,
  }) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': lastMessageAt,
      'last_inbound_at': lastInboundAt ?? lastMessageAt,
    });
  }

  void seedMessage(
    String key,
    String id, {
    String direction = 'inbound',
    String? from,
    String receivedAt = '2026-08-28T10:00:00Z',
  }) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'from_address': from,
      'received_at': receivedAt,
    });
  }

  List<Map<String, Object?>> events() => [
        for (final row in db.select(
          'SELECT * FROM feedback_events ORDER BY id ASC',
        ))
          Map<String, Object?>.from(row),
      ];

  group('feedback_events', () {
    test('appends, and appends again rather than replacing', () {
      store.recordFeedback(
        scope: 'sender',
        scopeKey: 'eric@x.com',
        direction: 'down',
        origin: 'explicit',
      );
      store.recordFeedback(
        scope: 'sender',
        scopeKey: 'eric@x.com',
        direction: 'up',
        origin: 'explicit',
      );

      final rows = events();
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['direction']), ['down', 'up']);
      // The history is the point: a table that kept only the latest answer
      // could not tell "changed their mind once" from "has always said this".
      expect(rows.first['id'], isNot(rows.last['id']));
    });

    test('carries scope, key, direction, origin and a stamp', () {
      store.recordFeedback(
        scope: 'thread',
        scopeKey: 'c1',
        direction: 'up',
        origin: 'implicit',
      );

      final row = events().single;
      expect(row['scope'], 'thread');
      expect(row['scope_key'], 'c1');
      expect(row['direction'], 'up');
      expect(row['origin'], 'implicit');
      expect(DateTime.tryParse(row['created_at'] as String), isNotNull);
    });
  });

  group('sender_prefs', () {
    test('round-trips through whatever casing the mail carried', () {
      store.setSenderPref('Eric.Nolan@X.com', 'later');

      expect(store.getSenderPref('eric.nolan@x.com'), 'later');
      expect(store.getSenderPref('ERIC.NOLAN@X.COM'), 'later');
      expect(store.allSenderPrefs(), {'eric.nolan@x.com': 'later'});
    });

    test('a second write replaces rather than duplicating', () {
      store.setSenderPref('eric@x.com', 'later');
      store.setSenderPref('eric@x.com', 'keep');

      expect(store.getSenderPref('eric@x.com'), 'keep');
      expect(store.allSenderPrefs(), hasLength(1));
    });

    test('null deletes the rule, which is not the same as storing one', () {
      store.setSenderPref('eric@x.com', 'later');
      store.setSenderPref('eric@x.com', null);

      expect(store.getSenderPref('eric@x.com'), isNull);
      expect(store.allSenderPrefs(), isEmpty);
    });

    test('deleting a rule nobody set is harmless', () {
      store.setSenderPref('nobody@x.com', null);
      expect(store.allSenderPrefs(), isEmpty);
    });

    test('a sender nobody has ruled on has no rule', () {
      expect(store.getSenderPref('stranger@x.com'), isNull);
    });
  });

  group('app_prefs', () {
    test('set then get', () {
      store.setPref('attention_threshold', '0.7');
      expect(store.getPref('attention_threshold'), '0.7');
    });

    test('a second set overwrites', () {
      store.setPref('about_me', 'first');
      store.setPref('about_me', 'second');
      expect(store.getPref('about_me'), 'second');
    });

    test('an unset key is null, not an empty string', () {
      expect(store.getPref('never_written'), isNull);
    });
  });

  group('setConversationBucket', () {
    test('writes bucket and reason, creating the ai row if needed', () {
      seedConversation('c1');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'low_value');

      final ai = store.getConversationAi('email', 'c1')!;
      expect(ai['bucket'], 'later');
      expect(ai['bucket_reason'], 'low_value');
    });

    test('null clears both columns', () {
      seedConversation('c1');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      store.setConversationBucket('email', 'c1', bucket: null);

      final ai = store.getConversationAi('email', 'c1')!;
      expect(ai['bucket'], isNull);
      expect(ai['bucket_reason'], isNull);
    });

    test('leaves an embedding on the same row alone', () {
      seedConversation('c1');
      store.upsertConversationAi('email', 'c1', embeddedHash: 'h1');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');

      expect(store.getConversationAi('email', 'c1')!['embedded_hash'], 'h1');
    });
  });

  group('writeAttentionScore', () {
    test('writes, and creating the ai row if needed', () {
      seedConversation('c1');
      store.writeAttentionScore('email', 'c1', 1.25);
      expect(store.getConversationAi('email', 'c1')!['attention_score'], 1.25);
    });

    test('does not disturb a bucket sitting on the same row', () {
      seedConversation('c1');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      store.writeAttentionScore('email', 'c1', 0.5);

      final ai = store.getConversationAi('email', 'c1')!;
      expect(ai['bucket'], 'later');
      expect(ai['bucket_reason'], 'user');
      expect(ai['attention_score'], 0.5);
    });
  });

  group('bucketReasons', () {
    test('lists only the threads that are actually bucketed', () {
      seedConversation('c1');
      seedConversation('c2');
      seedConversation('c3');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      store.setConversationBucket('email', 'c2',
          bucket: 'later', reason: 'low_value');
      store.writeAttentionScore('email', 'c3', 1);

      expect(store.bucketReasons(), {'c1': 'user', 'c2': 'low_value'});
    });
  });

  group('loadConversations carries the AI columns', () {
    test('bucket and attention score come back on the row', () {
      seedConversation('c1');
      store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      store.writeAttentionScore('email', 'c1', 1.5);

      final conversation = store.loadConversations().single;
      expect(conversation.bucket, 'later');
      expect(conversation.attentionScore, 1.5);
    });

    test('a thread with no ai row still loads, with both null', () {
      seedConversation('c1');
      final conversation = store.loadConversations().single;
      expect(conversation.bucket, isNull);
      expect(conversation.attentionScore, isNull);
    });

    test('the ordering is unchanged by the join', () {
      seedConversation('old', lastMessageAt: '2026-08-01T10:00:00Z');
      seedConversation('new', lastMessageAt: '2026-08-28T10:00:00Z');
      store.setConversationBucket('email', 'new', bucket: 'later');

      expect(store.loadConversations().map((c) => c.id), ['new', 'old']);
    });

    test('the state filter still works', () {
      seedConversation('c1', state: 'needs_reply');
      seedConversation('c2', state: 'waiting');

      final rows = store.loadConversations(state: ConversationState.needsReply);
      expect(rows.map((c) => c.id), ['c1']);
    });
  });

  group('rebucketSender', () {
    test('moves exactly the threads that sender owns, and counts them', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'eric@x.com');
      seedConversation('c2');
      seedMessage('c2', 'm2', from: 'eric@x.com');
      seedConversation('c3');
      seedMessage('c3', 'm3', from: 'dana@y.com');

      final affected = store.rebucketSender('eric@x.com', bucket: 'later');

      expect(affected, 2);
      final buckets = {
        for (final c in store.loadConversations()) c.id: c.bucket,
      };
      expect(buckets, {'c1': 'later', 'c2': 'later', 'c3': null});
      expect(store.bucketReasons(), {'c1': 'sender_pref', 'c2': 'sender_pref'});
    });

    test('matches whatever casing the message carried', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'Eric@X.com');

      expect(store.rebucketSender('eric@x.com', bucket: 'later'), 1);
    });

    test('the LATEST inbound sender owns the thread', () {
      // A newsletter the LO forwarded on, answered by a colleague. Silencing
      // the newsletter must not bury the colleague's reply.
      seedConversation('c1');
      seedMessage('c1', 'm1',
          from: 'news@bulk.com', receivedAt: '2026-08-01T10:00:00Z');
      seedMessage('c1', 'm2',
          from: 'dana@y.com', receivedAt: '2026-08-28T10:00:00Z');

      expect(store.rebucketSender('news@bulk.com', bucket: 'later'), 0);
      expect(store.loadConversations().single.bucket, isNull);

      expect(store.rebucketSender('dana@y.com', bucket: 'later'), 1);
      expect(store.loadConversations().single.bucket, 'later');
    });

    test('outbound mail never makes anyone the owner', () {
      seedConversation('c1');
      seedMessage('c1', 'm1',
          from: 'eric@x.com', receivedAt: '2026-08-01T10:00:00Z');
      seedMessage('c1', 'm2',
          direction: 'outbound',
          from: 'me@lo.com',
          receivedAt: '2026-08-28T10:00:00Z');

      expect(store.rebucketSender('me@lo.com', bucket: 'later'), 0);
      expect(store.rebucketSender('eric@x.com', bucket: 'later'), 1);
    });

    test('null clears the bucket and its reason', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'eric@x.com');
      store.rebucketSender('eric@x.com', bucket: 'later');

      expect(store.rebucketSender('eric@x.com', bucket: null), 1);
      expect(store.loadConversations().single.bucket, isNull);
      expect(store.bucketReasons(), isEmpty);
    });

    test('a sender with no mail changes nothing and reports nothing', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'eric@x.com');

      expect(store.rebucketSender('stranger@x.com', bucket: 'later'), 0);
    });

    test('running it twice reports the same count both times', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'eric@x.com');

      expect(store.rebucketSender('eric@x.com', bucket: 'later'), 1);
      expect(store.rebucketSender('eric@x.com', bucket: 'later'), 1);
    });
  });

  group('senderReplyRates', () {
    test('counts a sender answered in every thread as 1.0', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'eric@x.com');
      seedMessage('c1', 'm2', direction: 'outbound', from: 'me@lo.com');

      expect(store.senderReplyRates()['eric@x.com'], 1.0);
    });

    test('and one never answered as 0', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'news@bulk.com');

      expect(store.senderReplyRates()['news@bulk.com'], 0.0);
    });

    test('one of two threads answered is a half', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'eric@x.com');
      seedMessage('c1', 'm2', direction: 'outbound', from: 'me@lo.com');
      seedConversation('c2');
      seedMessage('c2', 'm3', from: 'eric@x.com');

      expect(store.senderReplyRates()['eric@x.com'], 0.5);
    });

    test('two messages in one thread still count as one thread', () {
      seedConversation('c1');
      seedMessage('c1', 'm1',
          from: 'eric@x.com', receivedAt: '2026-08-01T10:00:00Z');
      seedMessage('c1', 'm2',
          from: 'eric@x.com', receivedAt: '2026-08-02T10:00:00Z');

      expect(store.senderReplyRates()['eric@x.com'], 0.0);
    });

    test('casing is folded together', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'Eric@X.com');
      seedConversation('c2');
      seedMessage('c2', 'm2', from: 'eric@x.com');
      seedMessage('c2', 'm3', direction: 'outbound', from: 'me@lo.com');

      expect(store.senderReplyRates(), {'eric@x.com': 0.5});
    });

    test('mail with no sender address is skipped, not keyed on empty', () {
      seedConversation('c1');
      seedMessage('c1', 'm1');

      expect(store.senderReplyRates(), isEmpty);
    });
  });

  group('latestInboundMeta', () {
    test('returns the newest inbound message per conversation', () {
      seedConversation('c1');
      seedMessage('c1', 'old',
          from: 'a@x.com', receivedAt: '2026-08-01T10:00:00Z');
      seedMessage('c1', 'new',
          from: 'b@x.com', receivedAt: '2026-08-28T10:00:00Z');

      final meta = store.latestInboundMeta()['c1']!;
      expect(meta['source_message_id'], 'new');
      expect(meta['from_address'], 'b@x.com');
      expect(meta['received_at'], '2026-08-28T10:00:00Z');
    });

    test('ignores outbound mail however recent', () {
      seedConversation('c1');
      seedMessage('c1', 'in',
          from: 'a@x.com', receivedAt: '2026-08-01T10:00:00Z');
      seedMessage('c1', 'out',
          direction: 'outbound',
          from: 'me@lo.com',
          receivedAt: '2026-08-28T10:00:00Z');

      expect(store.latestInboundMeta()['c1']!['source_message_id'], 'in');
    });

    test('joins the extraction of that message and no other', () {
      seedConversation('c1');
      seedMessage('c1', 'old',
          from: 'a@x.com', receivedAt: '2026-08-01T10:00:00Z');
      seedMessage('c1', 'new',
          from: 'a@x.com', receivedAt: '2026-08-28T10:00:00Z');
      store.writeExtraction('email', 'old', jsonEncode({'intent': 'request'}));
      store.writeExtraction('email', 'new', jsonEncode({'intent': 'fyi'}));

      final raw = store.latestInboundMeta()['c1']!['extraction_json'] as String;
      expect(jsonDecode(raw), {'intent': 'fyi'});
    });

    test('a message with no extraction comes back with a null blob', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'a@x.com');

      expect(store.latestInboundMeta()['c1']!['extraction_json'], isNull);
    });

    test('a thread with only outbound mail is absent entirely', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', direction: 'outbound', from: 'me@lo.com');

      expect(store.latestInboundMeta(), isEmpty);
    });

    test('the tie-break is deterministic across reads', () {
      seedConversation('c1');
      seedMessage('c1', 'aaa',
          from: 'a@x.com', receivedAt: '2026-08-28T10:00:00Z');
      seedMessage('c1', 'zzz',
          from: 'z@x.com', receivedAt: '2026-08-28T10:00:00Z');

      // Same second, so `source_message_id DESC` decides — and must decide the
      // same way every time, or a sender rule would apply on one pass and not
      // the next.
      for (var i = 0; i < 5; i++) {
        expect(store.latestInboundMeta()['c1']!['from_address'], 'z@x.com');
      }
      expect(store.rebucketSender('z@x.com', bucket: 'later'), 1);
      expect(store.rebucketSender('a@x.com', bucket: 'later'), 0);
    });

    test('an empty source list reads nothing rather than everything', () {
      seedConversation('c1');
      seedMessage('c1', 'm1', from: 'a@x.com');

      expect(store.latestInboundMeta(sources: const []), isEmpty);
    });
  });
}
