import 'dart:typed_data';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

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
  late Database db;
  late MessageStore store;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// Pins a work row's `created_at`, so an ordering test does not depend on
  /// how many microseconds two inserts happened to be apart.
  void stampCreated(String kind, String entityId, String createdAt) {
    db.execute(
      'UPDATE work_items SET created_at = ? '
      'WHERE task_kind = ? AND entity_id = ?',
      [createdAt, kind, entityId],
    );
  }

  Map<String, Object?> workRow(String kind, String entityId) =>
      Map<String, Object?>.from(
        db.select(
          'SELECT * FROM work_items WHERE task_kind = ? AND entity_id = ?',
          [kind, entityId],
        ).single,
      );

  group('schema', () {
    test('the AI tables exist and are STRICT', () {
      final tables = db
          .select("SELECT name, sql FROM sqlite_master WHERE type = 'table'")
          .map((r) => (r['name'] as String, r['sql'] as String))
          .toList();
      final names = tables.map((t) => t.$1).toSet();
      expect(names, containsAll(['work_items', 'message_ai', 'conversation_ai']));
      for (final (_, sql) in tables) {
        expect(sql, contains('STRICT'));
      }
    });
  });

  group('enqueueWork', () {
    test('queues one item as pending', () {
      store.enqueueWork('extract', 'email', 'm1', payloadJson: '{"a":1}');

      final row = workRow('extract', 'm1');
      expect(row['status'], 'pending');
      expect(row['attempts'], 0);
      expect(row['payload_json'], '{"a":1}');
      expect(row['created_at'], isNotNull);
      expect(row['updated_at'], isNotNull);
    });

    test('the same item twice leaves one row, untouched', () {
      store.enqueueWork('extract', 'email', 'm1');
      store.writeWork('extract', 'email', 'm1', status: 'done');
      store.enqueueWork('extract', 'email', 'm1', payloadJson: 'ignored');

      final rows = db.select('SELECT * FROM work_items');
      expect(rows.length, 1);
      // The whole point of OR IGNORE: a re-enqueue must not resurrect work
      // that is finished, nor stamp over an item in flight.
      expect(rows.single['status'], 'done');
      expect(rows.single['payload_json'], isNull);
    });

    test('kind and source are part of the identity', () {
      store.enqueueWork('extract', 'email', 'm1');
      store.enqueueWork('embed', 'email', 'm1');
      store.enqueueWork('extract', 'teams', 'm1');

      expect(db.select('SELECT * FROM work_items').length, 3);
    });
  });

  group('nextPendingWork', () {
    test('takes the newest item first', () {
      store.enqueueWork('extract', 'email', 'old');
      store.enqueueWork('extract', 'email', 'new');
      store.enqueueWork('extract', 'email', 'mid');
      stampCreated('extract', 'old', '2026-08-20T10:00:00Z');
      stampCreated('extract', 'mid', '2026-08-25T10:00:00Z');
      stampCreated('extract', 'new', '2026-08-28T10:00:00Z');

      expect(store.nextPendingWork('extract')?['entity_id'], 'new');
    });

    test('a batch stamped alike still has one answer', () {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      stampCreated('extract', 'a', '2026-08-28T10:00:00Z');
      stampCreated('extract', 'b', '2026-08-28T10:00:00Z');

      // Not "b is more important than a" — only that the tie resolves the same
      // way every call, so a drain cannot be handed the same row forever while
      // another starves.
      expect(store.nextPendingWork('extract')?['entity_id'], 'b');
    });

    test('only pending rows of the asked-for kind, in the asked-for source',
        () {
      store.enqueueWork('extract', 'email', 'done-1');
      store.writeWork('extract', 'email', 'done-1', status: 'done');
      store.enqueueWork('extract', 'email', 'busy-1');
      store.writeWork('extract', 'email', 'busy-1', status: 'processing');
      store.enqueueWork('other', 'email', 'pending-elsewhere');
      store.enqueueWork('extract', 'teams', 'pending-teams');

      expect(store.nextPendingWork('extract'), isNull);
      expect(store.nextPendingWork('other')?['entity_id'], 'pending-elsewhere');
      expect(
        store.nextPendingWork('extract', sources: const ['teams'])?['entity_id'],
        'pending-teams',
      );
      expect(store.nextPendingWork('extract', sources: const []), isNull);
    });
  });

  group('writeWork', () {
    test('records status, error and attempts, and stamps updated_at', () {
      store.enqueueWork('extract', 'email', 'm1');
      final before = workRow('extract', 'm1')['updated_at'] as String;

      store.writeWork('extract', 'email', 'm1',
          status: 'error', error: 'boom', attempts: 2);

      final row = workRow('extract', 'm1');
      expect(row['status'], 'error');
      expect(row['error'], 'boom');
      expect(row['attempts'], 2);
      expect(
        (row['updated_at'] as String).compareTo(before),
        greaterThanOrEqualTo(0),
      );
    });

    test('a status-only write leaves an earlier error alone', () {
      store.enqueueWork('extract', 'email', 'm1');
      store.writeWork('extract', 'email', 'm1',
          status: 'pending', error: 'first failure', attempts: 1);
      store.writeWork('extract', 'email', 'm1', status: 'processing');

      final row = workRow('extract', 'm1');
      expect(row['status'], 'processing');
      expect(row['error'], 'first failure');
      expect(row['attempts'], 1);
    });

    test('only the addressed (kind, source, id) triple moves', () {
      store.enqueueWork('extract', 'email', 'm1');
      store.enqueueWork('extract', 'teams', 'm1');

      store.writeWork('extract', 'email', 'm1', status: 'done');

      final rows = db.select(
          'SELECT source, status FROM work_items ORDER BY source');
      expect(rows[0]['status'], 'done');
      expect(rows[1]['source'], 'teams');
      expect(rows[1]['status'], 'pending');
    });
  });

  group('workCounts', () {
    test('groups one kind by status', () {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      store.enqueueWork('extract', 'email', 'c');
      store.enqueueWork('other', 'email', 'd');
      store.writeWork('extract', 'email', 'a', status: 'done');
      store.writeWork('extract', 'email', 'b', status: 'error');

      expect(store.workCounts('extract'), {'pending': 1, 'done': 1, 'error': 1});
      expect(store.workCounts('other'), {'pending': 1});
      expect(store.workCounts('nothing'), isEmpty);
      expect(store.workCounts('extract', sources: const []), isEmpty);
    });
  });

  group('resetInterruptedWork', () {
    test('revives every claimed row, whatever its kind', () {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('embed', 'email', 'b');
      store.enqueueWork('extract', 'email', 'c');
      store.writeWork('extract', 'email', 'a', status: 'processing');
      store.writeWork('embed', 'email', 'b', status: 'processing');
      store.writeWork('extract', 'email', 'c', status: 'done');

      store.resetInterruptedWork();

      expect(workRow('extract', 'a')['status'], 'pending');
      expect(workRow('embed', 'b')['status'], 'pending');
      // Finished work is not "interrupted" and must stay finished.
      expect(workRow('extract', 'c')['status'], 'done');
    });
  });

  group('reviveErroredWork', () {
    test('an errored row below the ceiling goes back to pending, attempts kept',
        () {
      store.enqueueWork('extract', 'email', 'a');
      store.writeWork('extract', 'email', 'a', status: 'error', attempts: 2);

      expect(store.reviveErroredWork(), 1);

      final row = workRow('extract', 'a');
      expect(row['status'], 'pending');
      // NOT reset: the next failed attempt re-errors it, so each revival buys
      // exactly one more try on the road to the permanent ceiling.
      expect(row['attempts'], 2);
    });

    test('a row at the ceiling stays down for good', () {
      store.enqueueWork('extract', 'email', 'a');
      store.writeWork('extract', 'email', 'a', status: 'error', attempts: 6);

      expect(store.reviveErroredWork(), 0);
      expect(workRow('extract', 'a')['status'], 'error');
    });

    test('done and pending rows are untouched', () {
      store.enqueueWork('extract', 'email', 'a');
      store.enqueueWork('extract', 'email', 'b');
      store.writeWork('extract', 'email', 'a', status: 'done');

      expect(store.reviveErroredWork(), 0);
      expect(workRow('extract', 'a')['status'], 'done');
      expect(workRow('extract', 'b')['status'], 'pending');
    });
  });

  group('enqueueExtractBacklog', () {
    const since = '2026-08-25T00:00:00Z';

    test('queues inbound messages inside the window, newest first, up to cap',
        () {
      store.upsertMessage(messageRow(id: 'new', receivedAt: '2026-08-28T10:00:00Z'));
      store.upsertMessage(messageRow(id: 'mid', receivedAt: '2026-08-27T10:00:00Z'));
      store.upsertMessage(messageRow(id: 'old', receivedAt: '2026-08-26T10:00:00Z'));

      expect(store.enqueueExtractBacklog(cap: 2, sinceIso: since), 2);
      expect(
        db
            .select('SELECT entity_id FROM work_items ORDER BY entity_id')
            .map((r) => r['entity_id'])
            .toList(),
        ['mid', 'new'],
      );
    });

    test('skips outbound, skipped and out-of-window messages', () {
      store.upsertMessage(messageRow(id: 'keep'));
      store.upsertMessage(messageRow(id: 'sent', direction: 'outbound'));
      store.upsertMessage(messageRow(id: 'gated', triageStatus: 'skipped'));
      store.upsertMessage(messageRow(id: 'errored', triageStatus: 'error'));
      store.upsertMessage(
          messageRow(id: 'stale', receivedAt: '2026-08-01T10:00:00Z'));
      store.upsertMessage(messageRow(id: 'other-source', source: 'teams'));

      expect(store.enqueueExtractBacklog(sinceIso: since), 1);
      expect(
        db.select('SELECT entity_id FROM work_items').single['entity_id'],
        'keep',
      );
    });

    test('takes a message triage has already finished with', () {
      store.upsertMessage(messageRow(id: 'triaged', triageStatus: 'triaged'));
      store.upsertMessage(messageRow(id: 'busy', triageStatus: 'processing'));

      expect(store.enqueueExtractBacklog(sinceIso: since), 2);
    });

    test('a second run adds nothing and resurrects nothing', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.upsertMessage(messageRow(id: 'm2'));
      expect(store.enqueueExtractBacklog(sinceIso: since), 2);
      store.writeWork('extract', 'email', 'm1', status: 'done');

      expect(store.enqueueExtractBacklog(sinceIso: since), 0);

      expect(workRow('extract', 'm1')['status'], 'done');
      expect(workRow('extract', 'm2')['status'], 'pending');
    });

    test('new mail after a full run queues only the new mail', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.enqueueExtractBacklog(sinceIso: since);
      store.writeWork('extract', 'email', 'm1', status: 'done');

      store.upsertMessage(messageRow(id: 'm2', receivedAt: '2026-08-29T10:00:00Z'));

      expect(store.enqueueExtractBacklog(sinceIso: since), 1);
      expect(store.nextPendingWork('extract')?['entity_id'], 'm2');
    });
  });

  group('message_ai', () {
    test('writes, reads back, and overwrites in place', () {
      expect(store.getExtraction('email', 'm1'), isNull);

      store.writeExtraction('email', 'm1', '{"evidence":"first"}');
      expect(store.getExtraction('email', 'm1'), '{"evidence":"first"}');

      store.writeExtraction('email', 'm1', '{"evidence":"second"}');
      expect(store.getExtraction('email', 'm1'), '{"evidence":"second"}');
      expect(db.select('SELECT * FROM message_ai').length, 1);
      expect(
        db.select('SELECT extracted_at FROM message_ai').single['extracted_at'],
        isNotNull,
      );
    });

    test('the same id under a different source is a different row', () {
      store.writeExtraction('email', 'shared', '{"a":1}');
      store.writeExtraction('teams', 'shared', '{"a":2}');

      expect(store.getExtraction('email', 'shared'), '{"a":1}');
      expect(store.getExtraction('teams', 'shared'), '{"a":2}');
    });
  });

  group('conversation_ai', () {
    Uint8List bytes(List<int> values) => Uint8List.fromList(values);

    test('creates the row on first write', () {
      expect(store.getConversationAi('email', 'conv-1'), isNull);

      store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([1, 2, 3, 4]),
        embeddedHash: 'h1',
        embedModel: 'model-a',
      );

      final row = store.getConversationAi('email', 'conv-1')!;
      expect(row['embedding'], bytes([1, 2, 3, 4]));
      expect(row['embedded_hash'], 'h1');
      expect(row['embed_model'], 'model-a');
      expect(row['updated_at'], isNotNull);
    });

    test('a later embedding write leaves the other AI columns alone', () {
      store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([1, 2, 3, 4]),
        embeddedHash: 'h1',
        embedModel: 'model-a',
      );
      // Standing in for the phase that owns these columns: whatever writes a
      // bucket, it must survive the next re-embed.
      db.execute(
        'UPDATE conversation_ai SET bucket = ?, bucket_reason = ?, '
        'attention_score = ?, snoozed_until = ? '
        'WHERE source = ? AND conversation_key = ?',
        ['now', 'rate lock expires', 0.87, '2026-09-01T00:00:00Z', 'email', 'conv-1'],
      );

      store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([9, 9, 9, 9]),
        embeddedHash: 'h2',
        embedModel: 'model-a',
      );

      final row = store.getConversationAi('email', 'conv-1')!;
      expect(row['embedding'], bytes([9, 9, 9, 9]));
      expect(row['embedded_hash'], 'h2');
      expect(row['bucket'], 'now');
      expect(row['bucket_reason'], 'rate lock expires');
      expect(row['attention_score'], 0.87);
      expect(row['snoozed_until'], '2026-09-01T00:00:00Z');
    });

    test('an omitted argument is not the same as a null one', () {
      store.upsertConversationAi(
        'email',
        'conv-1',
        embedding: bytes([1, 2, 3, 4]),
        embeddedHash: 'h1',
        embedModel: 'model-a',
      );

      // Nothing named: a touch, and nothing else.
      store.upsertConversationAi('email', 'conv-1');
      var row = store.getConversationAi('email', 'conv-1')!;
      expect(row['embedding'], bytes([1, 2, 3, 4]));
      expect(row['embedded_hash'], 'h1');

      // Named as null: cleared.
      store.upsertConversationAi('email', 'conv-1', embedding: null);
      row = store.getConversationAi('email', 'conv-1')!;
      expect(row['embedding'], isNull);
      expect(row['embedded_hash'], 'h1');
    });

    test('sources are keyed separately', () {
      store.upsertConversationAi('email', 'shared', embeddedHash: 'h-email');
      store.upsertConversationAi('teams', 'shared', embeddedHash: 'h-teams');

      expect(store.getConversationAi('email', 'shared')!['embedded_hash'],
          'h-email');
      expect(store.getConversationAi('teams', 'shared')!['embedded_hash'],
          'h-teams');
    });
  });
}
