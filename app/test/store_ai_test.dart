import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The AI-side tables: the generic work queue, per-message extractions, and
/// the per-conversation AI row.

Map<String, Object?> messageRow({
  String source = 'email',
  required String id,
  String conversationKey = 'conv-1',
  String direction = 'inbound',
  String? receivedAt = '2026-08-28T10:00:00Z',
  String triageStatus = 'pending',
}) =>
    {
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': 'Subject',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'to_json': '["lo@x.com"]',
      'received_at': receivedAt,
      'body_preview': 'Preview',
      'body_text': 'Body',
      'triage_status': triageStatus,
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// Pins a work row's `created_at`, so an ordering test does not depend on
  /// how many microseconds two inserts happened to be apart.
  Future<void> stampCreated(
      String kind, String entityId, String createdAt) async {
    await db.customUpdate(
      'UPDATE work_items SET created_at = ? '
      'WHERE task_kind = ? AND entity_id = ?',
      variables: [
        Variable(createdAt),
        Variable(kind),
        Variable(entityId),
      ],
    );
  }

  Future<Map<String, Object?>> workRow(String kind, String entityId) async =>
      Map<String, Object?>.from(
        (await db.customSelect(
          'SELECT * FROM work_items WHERE task_kind = ? AND entity_id = ?',
          variables: [Variable(kind), Variable(entityId)],
        ).get())
            .single
            .data,
      );

  group('schema', () {
    test('the AI tables exist and are STRICT', () async {
      final tables = (await db
              .customSelect(
                  "SELECT name, sql FROM sqlite_master WHERE type = 'table'")
              .get())
          .map((r) => (r.data['name'] as String, r.data['sql'] as String))
          .toList();
      final names = tables.map((t) => t.$1).toSet();
      expect(names, containsAll(['work_items', 'message_ai', 'conversation_ai']));
      for (final (_, sql) in tables) {
        expect(sql, contains('STRICT'));
      }
    });
  });

  group('enqueueWork', () {
    test('queues one item as pending', () async {
      await store.enqueueWork('extract', 'email', 'm1', payloadJson: '{"a":1}');

      final row = await workRow('extract', 'm1');
      expect(row['status'], 'pending');
      expect(row['attempts'], 0);
      expect(row['payload_json'], '{"a":1}');
      expect(row['created_at'], isNotNull);
      expect(row['updated_at'], isNotNull);
    });

    test('the same item twice leaves one row, untouched', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      await store.writeWork('extract', 'email', 'm1', status: 'done');
      await store.enqueueWork('extract', 'email', 'm1', payloadJson: 'ignored');

      final rows = await db.customSelect('SELECT * FROM work_items').get();
      expect(rows.length, 1);
      // The whole point of OR IGNORE: a re-enqueue must not resurrect work
      // that is finished, nor stamp over an item in flight.
      expect(rows.single.data['status'], 'done');
      expect(rows.single.data['payload_json'], isNull);
    });

    test('kind and source are part of the identity', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      await store.enqueueWork('embed', 'email', 'm1');
      await store.enqueueWork('extract', 'teams', 'm1');

      expect((await db.customSelect('SELECT * FROM work_items').get()).length, 3);
    });
  });

  group('nextPendingWork', () {
    test('takes the newest item first', () async {
      await store.enqueueWork('extract', 'email', 'old');
      await store.enqueueWork('extract', 'email', 'new');
      await store.enqueueWork('extract', 'email', 'mid');
      await stampCreated('extract', 'old', '2026-08-20T10:00:00Z');
      await stampCreated('extract', 'mid', '2026-08-25T10:00:00Z');
      await stampCreated('extract', 'new', '2026-08-28T10:00:00Z');

      expect((await store.nextPendingWork('extract'))?['entity_id'], 'new');
    });

    test('a batch stamped alike still has one answer', () async {
      await store.enqueueWork('extract', 'email', 'a');
      await store.enqueueWork('extract', 'email', 'b');
      await stampCreated('extract', 'a', '2026-08-28T10:00:00Z');
      await stampCreated('extract', 'b', '2026-08-28T10:00:00Z');

      // Not "b is more important than a" — only that the tie resolves the same
      // way every call, so a drain cannot be handed the same row forever while
      // another starves.
      expect((await store.nextPendingWork('extract'))?['entity_id'], 'b');
    });

    test('only pending rows of the asked-for kind, in the asked-for source',
        () async {
      await store.enqueueWork('extract', 'email', 'done-1');
      await store.writeWork('extract', 'email', 'done-1', status: 'done');
      await store.enqueueWork('extract', 'email', 'busy-1');
      await store.writeWork('extract', 'email', 'busy-1', status: 'processing');
      await store.enqueueWork('other', 'email', 'pending-elsewhere');
      await store.enqueueWork('extract', 'teams', 'pending-teams');

      expect(await store.nextPendingWork('extract'), isNull);
      expect((await store.nextPendingWork('other'))?['entity_id'],
          'pending-elsewhere');
      expect(
        (await store.nextPendingWork('extract', sources: const ['teams']))
            ?['entity_id'],
        'pending-teams',
      );
      expect(await store.nextPendingWork('extract', sources: const []), isNull);
    });
  });

  group('writeWork', () {
    test('records status, error and attempts, and stamps updated_at', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      final before = (await workRow('extract', 'm1'))['updated_at'] as String;

      await store.writeWork('extract', 'email', 'm1',
          status: 'error', error: 'boom', attempts: 2);

      final row = await workRow('extract', 'm1');
      expect(row['status'], 'error');
      expect(row['error'], 'boom');
      expect(row['attempts'], 2);
      expect(
        (row['updated_at'] as String).compareTo(before),
        greaterThanOrEqualTo(0),
      );
    });

    test('a status-only write leaves an earlier error alone', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      await store.writeWork('extract', 'email', 'm1',
          status: 'pending', error: 'first failure', attempts: 1);
      await store.writeWork('extract', 'email', 'm1', status: 'processing');

      final row = await workRow('extract', 'm1');
      expect(row['status'], 'processing');
      expect(row['error'], 'first failure');
      expect(row['attempts'], 1);
    });

    test('only the addressed (kind, source, id) triple moves', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      await store.enqueueWork('extract', 'teams', 'm1');

      await store.writeWork('extract', 'email', 'm1', status: 'done');

      final rows = await db
          .customSelect('SELECT source, status FROM work_items ORDER BY source')
          .get();
      expect(rows[0].data['status'], 'done');
      expect(rows[1].data['source'], 'teams');
      expect(rows[1].data['status'], 'pending');
    });
  });

  group('workCounts', () {
    test('groups one kind by status', () async {
      await store.enqueueWork('extract', 'email', 'a');
      await store.enqueueWork('extract', 'email', 'b');
      await store.enqueueWork('extract', 'email', 'c');
      await store.enqueueWork('other', 'email', 'd');
      await store.writeWork('extract', 'email', 'a', status: 'done');
      await store.writeWork('extract', 'email', 'b', status: 'error');

      expect(await store.workCounts('extract'),
          {'pending': 1, 'done': 1, 'error': 1});
      expect(await store.workCounts('other'), {'pending': 1});
      expect(await store.workCounts('nothing'), isEmpty);
      expect(await store.workCounts('extract', sources: const []), isEmpty);
    });
  });

  group('resetInterruptedWork', () {
    test('revives every claimed row, whatever its kind', () async {
      await store.enqueueWork('extract', 'email', 'a');
      await store.enqueueWork('embed', 'email', 'b');
      await store.enqueueWork('extract', 'email', 'c');
      await store.writeWork('extract', 'email', 'a', status: 'processing');
      await store.writeWork('embed', 'email', 'b', status: 'processing');
      await store.writeWork('extract', 'email', 'c', status: 'done');

      await store.resetInterruptedWork();

      expect((await workRow('extract', 'a'))['status'], 'pending');
      expect((await workRow('embed', 'b'))['status'], 'pending');
      // Finished work is not "interrupted" and must stay finished.
      expect((await workRow('extract', 'c'))['status'], 'done');
    });
  });

  group('reviveErroredWork', () {
    test('an errored row below the ceiling goes back to pending, attempts kept',
        () async {
      await store.enqueueWork('extract', 'email', 'a');
      await store.writeWork('extract', 'email', 'a',
          status: 'error', attempts: 2);

      expect(await store.reviveErroredWork(), 1);

      final row = await workRow('extract', 'a');
      expect(row['status'], 'pending');
      // NOT reset: the next failed attempt re-errors it, so each revival buys
      // exactly one more try on the road to the permanent ceiling.
      expect(row['attempts'], 2);
    });

    test('a row at the ceiling stays down for good', () async {
      await store.enqueueWork('extract', 'email', 'a');
      await store.writeWork('extract', 'email', 'a',
          status: 'error', attempts: 6);

      expect(await store.reviveErroredWork(), 0);
      expect((await workRow('extract', 'a'))['status'], 'error');
    });

    test('done and pending rows are untouched', () async {
      await store.enqueueWork('extract', 'email', 'a');
      await store.enqueueWork('extract', 'email', 'b');
      await store.writeWork('extract', 'email', 'a', status: 'done');

      expect(await store.reviveErroredWork(), 0);
      expect((await workRow('extract', 'a'))['status'], 'done');
      expect((await workRow('extract', 'b'))['status'], 'pending');
    });
  });

  group('enqueueExtractBacklog', () {
    const since = '2026-08-25T00:00:00Z';

    test('queues inbound messages inside the window, newest first, up to cap',
        () async {
      await store
          .upsertMessage(messageRow(id: 'new', receivedAt: '2026-08-28T10:00:00Z'));
      await store
          .upsertMessage(messageRow(id: 'mid', receivedAt: '2026-08-27T10:00:00Z'));
      await store
          .upsertMessage(messageRow(id: 'old', receivedAt: '2026-08-26T10:00:00Z'));

      expect(await store.enqueueExtractBacklog(cap: 2, sinceIso: since), 2);
      expect(
        (await db
                .customSelect('SELECT entity_id FROM work_items ORDER BY entity_id')
                .get())
            .map((r) => r.data['entity_id'])
            .toList(),
        ['mid', 'new'],
      );
    });

    test('skips outbound, skipped and out-of-window messages', () async {
      await store.upsertMessage(messageRow(id: 'keep'));
      await store.upsertMessage(messageRow(id: 'sent', direction: 'outbound'));
      await store.upsertMessage(messageRow(id: 'gated', triageStatus: 'skipped'));
      await store.upsertMessage(messageRow(id: 'errored', triageStatus: 'error'));
      await store.upsertMessage(
          messageRow(id: 'stale', receivedAt: '2026-08-01T10:00:00Z'));
      await store.upsertMessage(messageRow(id: 'other-source', source: 'teams'));

      expect(await store.enqueueExtractBacklog(sinceIso: since), 1);
      expect(
        (await db.customSelect('SELECT entity_id FROM work_items').get())
            .single
            .data['entity_id'],
        'keep',
      );
    });

    test('takes a message triage has already finished with', () async {
      await store.upsertMessage(messageRow(id: 'triaged', triageStatus: 'triaged'));
      await store.upsertMessage(messageRow(id: 'busy', triageStatus: 'processing'));

      expect(await store.enqueueExtractBacklog(sinceIso: since), 2);
    });

    test('a second run adds nothing and resurrects nothing', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.upsertMessage(messageRow(id: 'm2'));
      expect(await store.enqueueExtractBacklog(sinceIso: since), 2);
      await store.writeWork('extract', 'email', 'm1', status: 'done');

      expect(await store.enqueueExtractBacklog(sinceIso: since), 0);

      expect((await workRow('extract', 'm1'))['status'], 'done');
      expect((await workRow('extract', 'm2'))['status'], 'pending');
    });

    test('new mail after a full run queues only the new mail', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.enqueueExtractBacklog(sinceIso: since);
      await store.writeWork('extract', 'email', 'm1', status: 'done');

      await store
          .upsertMessage(messageRow(id: 'm2', receivedAt: '2026-08-29T10:00:00Z'));

      expect(await store.enqueueExtractBacklog(sinceIso: since), 1);
      expect((await store.nextPendingWork('extract'))?['entity_id'], 'm2');
    });
  });

  group('message_ai', () {
    test('writes, reads back, and overwrites in place', () async {
      expect(await store.getExtraction('email', 'm1'), isNull);

      await store.writeExtraction('email', 'm1', '{"evidence":"first"}');
      expect(await store.getExtraction('email', 'm1'), '{"evidence":"first"}');

      await store.writeExtraction('email', 'm1', '{"evidence":"second"}');
      expect(await store.getExtraction('email', 'm1'), '{"evidence":"second"}');
      expect((await db.customSelect('SELECT * FROM message_ai').get()).length, 1);
      expect(
        (await db.customSelect('SELECT extracted_at FROM message_ai').get())
            .single
            .data['extracted_at'],
        isNotNull,
      );
    });

    test('the same id under a different source is a different row', () async {
      await store.writeExtraction('email', 'shared', '{"a":1}');
      await store.writeExtraction('teams', 'shared', '{"a":2}');

      expect(await store.getExtraction('email', 'shared'), '{"a":1}');
      expect(await store.getExtraction('teams', 'shared'), '{"a":2}');
    });
  });

  group('conversation_ai', () {
    Uint8List bytes(List<int> values) => Uint8List.fromList(values);

    test('creates the row on first write', () async {
      expect(await store.getConversationAi('email', 'conv-1'), isNull);

      await store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([1, 2, 3, 4]),
        embeddedHash: 'h1',
        embedModel: 'model-a',
      );

      final row = (await store.getConversationAi('email', 'conv-1'))!;
      expect(row['embedding'], bytes([1, 2, 3, 4]));
      expect(row['embedded_hash'], 'h1');
      expect(row['embed_model'], 'model-a');
      expect(row['updated_at'], isNotNull);
    });

    test('a later embedding write leaves the other AI columns alone', () async {
      await store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([1, 2, 3, 4]),
        embeddedHash: 'h1',
        embedModel: 'model-a',
      );
      // Standing in for the phase that owns these columns: whatever writes a
      // bucket, it must survive the next re-embed.
      await db.customUpdate(
        'UPDATE conversation_ai SET bucket = ?, bucket_reason = ?, '
        'attention_score = ?, snoozed_until = ? '
        'WHERE source = ? AND conversation_key = ?',
        variables: [
          Variable('now'),
          Variable('launch date moved'),
          Variable(0.87),
          Variable('2026-09-01T00:00:00Z'),
          Variable('email'),
          Variable('conv-1'),
        ],
      );

      await store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([9, 9, 9, 9]),
        embeddedHash: 'h2',
        embedModel: 'model-a',
      );

      final row = (await store.getConversationAi('email', 'conv-1'))!;
      expect(row['embedding'], bytes([9, 9, 9, 9]));
      expect(row['embedded_hash'], 'h2');
      expect(row['bucket'], 'now');
      expect(row['bucket_reason'], 'launch date moved');
      expect(row['attention_score'], 0.87);
      expect(row['snoozed_until'], '2026-09-01T00:00:00Z');
    });

    test('an omitted argument is not the same as a null one', () async {
      await store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([1, 2, 3, 4]),
        embeddedHash: 'h1',
        embedModel: 'model-a',
      );

      // Nothing named: a touch, and nothing else.
      await store.upsertConversationAi('email', 'conv-1');
      var row = (await store.getConversationAi('email', 'conv-1'))!;
      expect(row['embedding'], bytes([1, 2, 3, 4]));
      expect(row['embedded_hash'], 'h1');

      // Named as null: cleared.
      await store.upsertConversationAi('email', 'conv-1', embedding: null);
      row = (await store.getConversationAi('email', 'conv-1'))!;
      expect(row['embedding'], isNull);
      expect(row['embedded_hash'], 'h1');
    });

    test('sources are keyed separately', () async {
      await store.upsertConversationAi('email', 'shared', embeddedHash: 'h-email');
      await store.upsertConversationAi('teams', 'shared', embeddedHash: 'h-teams');

      expect((await store.getConversationAi('email', 'shared'))!['embedded_hash'],
          'h-email');
      expect((await store.getConversationAi('teams', 'shared'))!['embedded_hash'],
          'h-teams');
    });
  });
}
