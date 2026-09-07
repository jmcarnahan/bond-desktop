import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// What the anti-join in the backlog enqueues buys.
///
/// `INSERT OR IGNORE … ORDER BY received_at DESC LIMIT cap` on its own counts
/// rows that are already queued against the LIMIT, so the newest [cap]
/// messages fill every slot on every pass and older mail inside the window is
/// never queued at all — not later, not ever, because work rows are never
/// deleted. Excluding queued messages in the statement turns the cap into a
/// pace: each pass files the next [cap] not-yet-queued messages, newest first,
/// and a deep window drains over several of them.

/// A messages row with everything the NOT NULL columns need.
Map<String, Object?> messageRow({
  required String id,
  required String receivedAt,
  String source = 'email',
  String direction = 'inbound',
  String triageStatus = 'pending',
}) =>
    {
      'source': source,
      'source_message_id': id,
      'conversation_key': 'conv-1',
      'direction': direction,
      'subject': 'Subject',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'to_json': '["lo@bond.com"]',
      'received_at': receivedAt,
      'is_read': 0,
      'body_preview': 'Preview',
      'body_text': 'Body',
      'addressed_me': 0,
      'triage_status': triageStatus,
    };

String messageId(int i) => 'm${i.toString().padLeft(3, '0')}';

void main() {
  late BondDatabase db;
  late MessageStore store;

  /// Old enough that every fixture below is inside the window.
  const since = '2026-01-01T00:00:00Z';

  setUp(() async {
    db = testDb();
    store = MessageStore(db);

    // 400 pending inbound messages, one minute apart, oldest first.
    final base = DateTime.utc(2026, 8, 1);
    for (var i = 0; i < 400; i++) {
      await store.upsertMessage(messageRow(
        id: messageId(i),
        receivedAt: base.add(Duration(minutes: i)).toIso8601String(),
      ));
    }
  });

  tearDown(() => db.close());

  Future<List<String>> queued(String kind) async => [
        for (final row in await db
            .customSelect(
              'SELECT entity_id FROM work_items WHERE task_kind = ? '
              'ORDER BY entity_id',
              variables: [Variable<String>(kind)],
            )
            .get())
          row.data['entity_id'] as String,
      ];

  Future<Map<String, String>> statuses(String kind) async => {
        for (final row in await db
            .customSelect(
              'SELECT entity_id, status FROM work_items WHERE task_kind = ? '
              'ORDER BY entity_id',
              variables: [Variable<String>(kind)],
            )
            .get())
          row.data['entity_id'] as String: row.data['status'] as String,
      };

  List<String> idRange(int from, int to) =>
      [for (var i = from; i <= to; i++) messageId(i)];

  test('four passes at cap 150 drain 400 messages: 150, 150, 100, 0', () async {
    final counts = [
      for (var pass = 0; pass < 4; pass++)
        await store.enqueueExtractBacklog(
            cap: 150, sinceIso: since, source: 'email'),
    ];

    expect(counts, [150, 150, 100, 0]);
    expect(await queued('extract'), idRange(0, 399));
  });

  test('each pass takes the newest not-yet-queued first', () async {
    await store.enqueueExtractBacklog(cap: 150, sinceIso: since);
    expect(await queued('extract'), idRange(250, 399));

    await store.enqueueExtractBacklog(cap: 150, sinceIso: since);
    expect(await queued('extract'), idRange(100, 399));
  });

  test('finished work is never re-queued and never blocks the drain', () async {
    await store.enqueueExtractBacklog(cap: 150, sinceIso: since);
    final done = idRange(395, 399);
    for (final id in done) {
      await store.writeWork('extract', 'email', id, status: 'done');
    }

    expect(await store.enqueueExtractBacklog(cap: 150, sinceIso: since), 150);

    final byId = await statuses('extract');
    for (final id in done) {
      expect(byId[id], 'done');
    }
    // The second pass moved on to the next slice rather than reoffering the
    // rows the first one left behind it.
    expect(await queued('extract'), idRange(100, 399));
  });

  test('the embed enqueue paces the same way', () async {
    final counts = [
      for (var pass = 0; pass < 4; pass++)
        await store.enqueueEmbedBacklog(
            cap: 150, sinceIso: since, source: 'email'),
    ];

    expect(counts, [150, 150, 100, 0]);
    expect(await queued('embed_message'), idRange(0, 399));
  });
}
