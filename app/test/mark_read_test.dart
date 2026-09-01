import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// What opening a thread writes: the local flip, and the ack the server is
/// owed. The ack itself is somebody else's drain — nothing here sends anything.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// One message on `c1`, unread inbound unless told otherwise.
  Future<void> message(
    String id, {
    String conversationKey = 'c1',
    String direction = 'inbound',
    int isRead = 0,
    String receivedAt = '2026-08-28T10:00:00Z',
  }) =>
      store.upsertMessage({
        'source_message_id': id,
        'conversation_key': conversationKey,
        'direction': direction,
        'is_read': isRead,
        'received_at': receivedAt,
      });

  Future<List<Map<String, Object?>>> workRows() async => [
        for (final row in await db
            .customSelect('SELECT * FROM work_items ORDER BY entity_id ASC')
            .get())
          Map<String, Object?>.from(row.data),
      ];

  Future<Map<String, int>> readStateById() async => {
        for (final row
            in await db.customSelect('SELECT * FROM messages').get())
          row.data['source_message_id'] as String:
              row.data['is_read'] as int,
      };

  List<String> payloadOf(Map<String, Object?> work) => [
        for (final id in jsonDecode(work['payload_json'] as String) as List)
          id as String,
      ];

  group('markConversationRead', () {
    test('flips the unread inbound mail and nothing else', () async {
      await message('m1');
      await message('m2');
      await message('m3', isRead: 1);
      await message('m4', direction: 'outbound');
      await message('m5', conversationKey: 'c2');

      final flipped = await store.markConversationRead('email', 'c1');

      expect(flipped, 2);
      expect(await readStateById(), {
        'm1': 1,
        'm2': 1,
        'm3': 1,
        // The user's own mail was never unread and is not written to.
        'm4': 0,
        // Another thread entirely.
        'm5': 0,
      });
    });

    test('queues one ack carrying the ids it just flipped', () async {
      await message('m1');
      await message('m2');
      await message('m3', isRead: 1);

      await store.markConversationRead('email', 'c1');

      final work = (await workRows()).single;
      expect(work['task_kind'], 'mark_read');
      expect(work['source'], 'email');
      expect(work['entity_id'], 'c1');
      expect(work['status'], 'pending');
      expect(work['attempts'], 0);
      // The set that WAS unread — the one already-read message is not in it.
      expect(payloadOf(work), unorderedEquals(['m1', 'm2']));
    });

    test('a thread with nothing unread returns 0 and queues nothing', () async {
      await message('m1', isRead: 1);
      await message('m2', direction: 'outbound', isRead: 1);

      expect(await store.markConversationRead('email', 'c1'), 0);

      expect(await workRows(), isEmpty,
          reason: 'reopening read mail must cost the server nothing');
    });

    test('a second read merges into the ack still queued', () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');

      // New mail arrives before anything drained the first ack.
      await message('m2', receivedAt: '2026-08-28T11:00:00Z');
      final flipped = await store.markConversationRead('email', 'c1');

      expect(flipped, 1, reason: 'only the new message needed flipping');
      final work = (await workRows()).single;
      expect(payloadOf(work), ['m2', 'm1'],
          reason: 'both ids, newest first, neither repeated');
      expect(work['status'], 'pending');
    });

    test('a drained ack is re-queued rather than left done', () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');
      await store.writeWork('mark_read', 'email', 'c1',
          status: 'error', error: 'the server said no', attempts: 2);

      await message('m2', receivedAt: '2026-08-28T11:00:00Z');
      await store.markConversationRead('email', 'c1');

      final work = (await workRows()).single;
      expect(work['status'], 'pending');
      expect(work['attempts'], 0);
      expect(work['error'], isNull);
      expect(payloadOf(work), ['m2', 'm1']);
    });

    test('a malformed payload costs the new ids nothing', () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');
      await db.customUpdate(
        "UPDATE work_items SET payload_json = '{oops' "
        "WHERE task_kind = 'mark_read'",
      );

      await message('m2', receivedAt: '2026-08-28T11:00:00Z');
      await store.markConversationRead('email', 'c1');

      expect(payloadOf((await workRows()).single), ['m2']);
    });

    test('the same key under another source is its own thread', () async {
      await message('m1');
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-m1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'is_read': 0,
        'received_at': '2026-08-28T10:00:00Z',
      });

      expect(await store.markConversationRead('teams', 'c1'), 1);

      expect((await readStateById())['m1'], 0);
      expect((await workRows()).single['source'], 'teams');
    });
  });

  group('clearCta', () {
    test('takes the ask off the thread and quiets its urgency', () async {
      await store.upsertConversation({
        'conversation_key': 'c1',
        'cta_text': 'Send the homepage copy',
        'cta_urgency': 'urgent',
      });

      await store.clearCta('email', 'c1');

      final c = (await store.loadConversations()).single;
      expect(c.ctaText, isNull);
      expect(c.ctaUrgency, CtaUrgency.normal);
    });
  });
}
