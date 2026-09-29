import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The order the backlog claims `extract` items (the message-text stage) in:
/// an item requested in the last few minutes first (an owner-asked requeue),
/// then a needs-you yes, then everything not filed Later before what is,
/// then the decision's importance (high, normal, low), then newest first —
/// over a window of the newest eligible items. ORDER only — what is
/// claimable is unchanged, and every other kind keeps `created_at DESC`.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One triaged inbound message on its own thread, its `extract` item queued
  /// at [minute] past the hour (later = newer).
  Future<void> seed(
    String id, {
    required int minute,
    String? importance,
    String? extractionImportance,
    bool needsYou = false,
    bool later = false,
    String triageStatus = 'triaged',
    String kind = 'extract',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': 'inbound',
      'subject': id,
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'Body of $id',
      'triage_status': triageStatus,
    });
    if (needsYou) {
      // Over the slider's default, which is what the claim reads when no
      // slider has been saved.
      await db.customUpdate(
        'UPDATE messages SET needs_you_p = 0.9 '
        'WHERE source_message_id = ?',
        variables: [Variable<String>(id)],
      );
    }
    if (importance != null) {
      await store.writeDecision(
        'email',
        id,
        fakeDecision(fakeAnswers(importance: importance)),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );
    }
    if (extractionImportance != null) {
      await store.writeExtraction(
        'email',
        id,
        jsonEncode({
          'topics': <String>[],
          'project': '',
          'intent': 'fyi',
          'importance': extractionImportance,
        }),
      );
    }
    if (later) {
      await store.setConversationBucket('email', 'conv-$id',
          bucket: 'later', reason: 'low_value');
    }
    await store.enqueueWork(kind, 'email', id);
    await db.customUpdate(
      'UPDATE work_items SET created_at = ? WHERE entity_id = ? '
      'AND task_kind = ?',
      variables: [
        Variable<String>(
            '2026-08-29T11:${minute.toString().padLeft(2, '0')}:00.000000Z'),
        Variable<String>(id),
        Variable<String>(kind),
      ],
    );
  }

  Future<List<String>> drainOrder(String kind) async {
    final order = <String>[];
    while (true) {
      final item = await store.claimPendingWork(kind);
      if (item == null) return order;
      order.add(item['entity_id'] as String);
    }
  }

  test('needs-you, then Later last, then importance, then newest', () async {
    await seed('ny-low', minute: 1, importance: 'low', needsYou: true);
    await seed('high', minute: 2, importance: 'high');
    await seed('high-later', minute: 9, importance: 'high', later: true);
    await seed('normal-old', minute: 3, importance: 'normal');
    await seed('normal-new', minute: 8, importance: 'normal');
    // No decision: an older build's extraction speaks for it...
    await seed('extracted-high', minute: 4, extractionImportance: 'high');
    // ...and with neither, it reads as normal.
    await seed('undecided', minute: 7);
    await seed('low', minute: 6, importance: 'low');
    await seed('normal-later', minute: 10, importance: 'normal', later: true);

    expect(await drainOrder('extract'), [
      'ny-low',
      // Not Later, by importance; newest first between equals.
      'extracted-high',
      'high',
      'normal-new',
      'undecided',
      'normal-old',
      'low',
      // Later last, by importance within it.
      'high-later',
      'normal-later',
    ]);
  });

  test("needs-you is read at the owner's slider", () async {
    // 0.9 needs the owner at a slider of 0.95 no more than a normal message
    // does, so importance decides between the two.
    await store.setPref(needsYouThresholdKey, '0.95');
    await seed('ny-low', minute: 1, importance: 'low', needsYou: true);
    await seed('high', minute: 2, importance: 'high');

    expect(await drainOrder('extract'), ['high', 'ny-low']);
  });

  test('an owner-asked requeue jumps every priority key', () async {
    await seed('ny-high', minute: 5, importance: 'high', needsYou: true);
    await seed('asked-low', minute: 1, importance: 'low', later: true);
    await store.writeWork('extract', 'email', 'asked-low', status: 'done');
    // What Retry and Restore do: revive with a fresh stamp.
    await store.requeueWork('extract', 'email', 'asked-low',
        refreshCreatedAt: true);

    expect(await drainOrder('extract'), ['asked-low', 'ny-high']);
  });

  test('the priority keys order only the newest window of the backlog',
      () async {
    // A high-importance item OLDER than the window waits behind the window's
    // own items, however important — the bound on the per-claim sort.
    await seed('old-high', minute: 0, importance: 'high', needsYou: true);
    for (var i = 1; i <= MessageStore.textClaimWindow; i++) {
      await store.enqueueWork('extract', 'email', 'bulk-$i');
      await db.customUpdate(
        'UPDATE work_items SET created_at = ? WHERE entity_id = ?',
        variables: [
          Variable<String>('2026-08-29T12:00:00.000000Z'),
          Variable<String>('bulk-$i'),
        ],
      );
    }

    final first = await store.claimPendingWork('extract');
    expect(first!['entity_id'], isNot('old-high'));
  });

  test('which items are claimable is unchanged: untriaged messages wait',
      () async {
    await seed('pending', minute: 5, importance: 'high',
        triageStatus: 'pending');
    await seed('ready', minute: 1, importance: 'low');

    expect(await drainOrder('extract'), ['ready']);
    // The held one is still pending, not lost.
    expect((await store.workCounts('extract'))['pending'], 1);
  });

  test('every other kind keeps newest first', () async {
    await seed('old-high', minute: 1, importance: 'high', needsYou: true,
        kind: 'needs_you');
    await seed('new-low', minute: 5, importance: 'low', kind: 'needs_you');

    expect(await drainOrder('needs_you'), ['new-low', 'old-high']);
  });

  test('a named claim ignores the order and keeps the guard', () async {
    await seed('a', minute: 1, importance: 'low');
    await seed('b', minute: 2, importance: 'high', triageStatus: 'pending');

    expect(await store.claimWorkItem('extract', 'email', 'a'), isNotNull);
    expect(await store.claimWorkItem('extract', 'email', 'b'), isNull);
  });
}
