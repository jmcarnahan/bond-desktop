import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// The `drafts` table and the two reads that feed drafting.

void main() {
  late Database db;
  late MessageStore store;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  void seedMessage({
    required String id,
    String key = 'conv-1',
    String direction = 'inbound',
    String? receivedAt = '2026-08-29T10:00:00Z',
    String toJson = '[]',
    String? body,
    String? preview,
  }) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'from_address': 'sarah@x.com',
      'received_at': receivedAt,
      'to_json': toJson,
      'body_text': body,
      'body_preview': preview,
    });
  }

  void seedConversation({
    required String key,
    String state = 'needs_reply',
    double? score = 0.9,
    String? bucket,
  }) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': '2026-08-29T10:00:00Z',
    });
    if (score != null) store.writeAttentionScore('email', key, score);
    if (bucket != null) {
      store.setConversationBucket('email', key, bucket: bucket);
    }
  }

  group('the schema', () {
    test('drafts is STRICT, like every other table', () {
      final sql = db
          .select("SELECT sql FROM sqlite_master WHERE name = 'drafts'")
          .single['sql'] as String;
      expect(sql, contains('STRICT'));
      // AUTOINCREMENT would drag in sqlite's own sqlite_sequence table, which
      // is not STRICT.
      expect(sql, isNot(contains('AUTOINCREMENT')));
    });
  });

  group('CRUD', () {
    test('writes a draft and reads it back', () {
      store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'Friday works.',
        evidence: 'Sarah wants the lock extended.',
      );

      final draft = store.getDraft('email', 'conv-1')!;
      expect(draft['body'], 'Friday works.');
      expect(draft['evidence'], 'Sarah wants the lock extended.');
      expect(draft['status'], 'suggested');
      expect(draft['reply_to_message_id'], 'm1');
      expect(draft['created_at'], isNotNull);
    });

    test('getDraft is null for a conversation with none', () {
      expect(store.getDraft('email', 'nothing'), isNull);
    });

    test('a regenerate replaces the whole draft, Outlook ids included', () {
      store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'first',
        evidence: 'first evidence',
      );
      store.updateDraftStatus(
        'email',
        'conv-1',
        status: 'suggested',
        graphDraftId: 'g1',
        webLink: 'https://outlook/g1',
      );
      final createdAt = store.getDraft('email', 'conv-1')!['created_at'];

      store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'second',
      );

      final draft = store.getDraft('email', 'conv-1')!;
      expect(draft['body'], 'second');
      expect(draft['reply_to_message_id'], 'm2');
      expect(draft['evidence'], isNull);
      // The stale Outlook draft holds text nobody can see any more; a Send
      // pointing at it would send the version that was replaced.
      expect(draft['graph_draft_id'], isNull);
      expect(draft['web_link'], isNull);
      expect(draft['created_at'], createdAt,
          reason: 'when this thread first got a suggestion does not change');
    });

    test('updateDraftStatus writes only the fields it carries', () {
      store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'original',
        evidence: 'why',
      );

      store.updateDraftStatus('email', 'conv-1', status: 'edited');
      var draft = store.getDraft('email', 'conv-1')!;
      expect(draft['status'], 'edited');
      expect(draft['body'], 'original');
      expect(draft['evidence'], 'why');

      store.updateDraftStatus(
        'email',
        'conv-1',
        status: 'sent',
        body: 'what was actually sent',
        graphDraftId: 'g9',
      );
      draft = store.getDraft('email', 'conv-1')!;
      expect(draft['status'], 'sent');
      expect(draft['body'], 'what was actually sent');
      expect(draft['graph_draft_id'], 'g9');
      expect(draft['web_link'], isNull);
    });

    test('deleteDraft removes it', () {
      store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'gone soon',
      );

      store.deleteDraft('email', 'conv-1');

      expect(store.getDraft('email', 'conv-1'), isNull);
    });

    test('drafts are per source as well as per conversation', () {
      store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'email draft',
      );
      store.upsertDraft(
        source: 'teams',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'teams draft',
      );

      expect(store.getDraft('email', 'conv-1')!['body'], 'email draft');
      expect(store.getDraft('teams', 'conv-1')!['body'], 'teams draft');
    });
  });

  group('newestInboundMessage', () {
    test('is the latest inbound one, outbound ignored', () {
      seedMessage(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      seedMessage(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      seedMessage(
        id: 'o1',
        direction: 'outbound',
        receivedAt: '2026-08-30T10:00:00Z',
      );

      expect(
        store.newestInboundMessage('email', 'conv-1')!['source_message_id'],
        'm2',
      );
    });

    test('ties break on source_message_id DESC', () {
      // Two messages stamped the same second are common; without the tie-break
      // sqlite would be free to pick a different one on every read.
      seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      seedMessage(id: 'm9', receivedAt: '2026-08-29T10:00:00Z');
      seedMessage(id: 'm5', receivedAt: '2026-08-29T10:00:00Z');

      expect(
        store.newestInboundMessage('email', 'conv-1')!['source_message_id'],
        'm9',
      );
    });

    test('is null for a thread with nothing inbound', () {
      seedMessage(id: 'o1', direction: 'outbound');

      expect(store.newestInboundMessage('email', 'conv-1'), isNull);
    });
  });

  group('recentOutboundToSender', () {
    test('finds the LO\'s replies to one address, newest first', () {
      seedMessage(
        id: 'o1',
        direction: 'outbound',
        toJson: '["sarah@x.com"]',
        receivedAt: '2026-08-20T10:00:00Z',
        body: 'older reply',
      );
      seedMessage(
        id: 'o2',
        direction: 'outbound',
        toJson: '["sarah@x.com","cc@x.com"]',
        receivedAt: '2026-08-28T10:00:00Z',
        body: 'newer reply',
      );

      final rows = store.recentOutboundToSender('email', 'sarah@x.com');

      expect(rows.map((r) => r['body_text']), ['newer reply', 'older reply']);
    });

    test('matches case-insensitively and respects the limit', () {
      for (var i = 0; i < 5; i++) {
        seedMessage(
          id: 'o$i',
          direction: 'outbound',
          toJson: '["Sarah@X.com"]',
          receivedAt: '2026-08-2${i}T10:00:00Z',
          body: 'reply $i',
        );
      }

      expect(store.recentOutboundToSender('email', 'SARAH@x.com'), hasLength(2));
      expect(
        store.recentOutboundToSender('email', 'sarah@x.com', limit: 4),
        hasLength(4),
      );
    });

    test('never returns inbound mail, and nothing for an empty address', () {
      seedMessage(id: 'm1', toJson: '["sarah@x.com"]');

      expect(store.recentOutboundToSender('email', 'sarah@x.com'), isEmpty);
      expect(store.recentOutboundToSender('email', ''), isEmpty);
    });
  });

  group('needsDraftKeys', () {
    test('picks threads waiting on the LO that score high enough', () {
      seedConversation(key: 'hot', score: 0.9);
      seedConversation(key: 'cold', score: 0.2);
      seedConversation(key: 'answered', state: 'done', score: 0.9);

      expect(store.needsDraftKeys(threshold: 0.5), ['hot']);
    });

    test('excludes anything filed into Later, and keeps un-bucketed threads',
        () {
      seedConversation(key: 'inbox', score: 0.9);
      seedConversation(key: 'deferred', score: 0.95, bucket: 'later');
      seedConversation(key: 'other-bucket', score: 0.99, bucket: 'now');

      // `IS NOT 'later'` rather than `<> 'later'`: NULL <> 'later' is NULL,
      // which would drop every un-bucketed thread.
      expect(
        store.needsDraftKeys(threshold: 0.5),
        ['other-bucket', 'inbox'],
      );
    });

    test('excludes a thread that already has a draft', () {
      seedConversation(key: 'drafted', score: 0.9);
      seedConversation(key: 'undrafted', score: 0.8);
      store.upsertDraft(
        source: 'email',
        conversationKey: 'drafted',
        replyToMessageId: 'm1',
        body: 'already written',
      );

      // This is what makes the enqueue safe to run on every list load.
      expect(store.needsDraftKeys(threshold: 0.5), ['undrafted']);
    });

    test('a dismissed draft still counts as a draft', () {
      seedConversation(key: 'dismissed', score: 0.9);
      store.upsertDraft(
        source: 'email',
        conversationKey: 'dismissed',
        replyToMessageId: 'm1',
        body: 'thrown away',
      );
      store.updateDraftStatus('email', 'dismissed', status: 'dismissed');

      // Otherwise every list load would write back the suggestion the user
      // just closed.
      expect(store.needsDraftKeys(threshold: 0.5), isEmpty);
    });

    test('an unscored thread is excluded', () {
      seedConversation(key: 'unscored', score: null);

      // NULL >= threshold is NULL, not true — and a thread the scorer has never
      // reached has not earned a model call.
      expect(store.needsDraftKeys(threshold: 0.0), isEmpty);
    });

    test('orders by score and caps at the limit', () {
      seedConversation(key: 'a', score: 0.6);
      seedConversation(key: 'b', score: 0.9);
      seedConversation(key: 'c', score: 0.7);

      expect(store.needsDraftKeys(threshold: 0.5), ['b', 'c', 'a']);
      expect(store.needsDraftKeys(threshold: 0.5, limit: 2), ['b', 'c']);
    });

    test('no sources means no keys', () {
      seedConversation(key: 'hot', score: 0.9);

      expect(store.needsDraftKeys(threshold: 0.5, sources: const []), isEmpty);
    });
  });
}
