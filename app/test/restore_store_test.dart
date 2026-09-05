// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The two writes behind Restore, against a real database.
///
/// Both are reversals of one-way writes — `restoreMessage` undoes a gate
/// verdict the triage claim keeps re-deriving, `restoreProgress` undoes the
/// cascade a gate skip runs over the whole progress row — so what is worth
/// pinning is not that they wrote something, but that nothing they were meant
/// to clear survives them.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seed(
    String id, {
    String source = 'email',
    String receivedAt = '2026-09-01T10:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'c-$id',
      'direction': 'inbound',
      'subject': 'Weekly roundup',
      'from_name': 'Alex Rivera',
      'from_address': 'alex.rivera@example.com',
      'received_at': receivedAt,
      'created_at': receivedAt,
      'updated_at': receivedAt,
    });
  }

  Future<Map<String, Object?>> messageOf(String id,
          {String source = 'email'}) async =>
      (await db.customSelect(
        'SELECT * FROM messages WHERE source = ? AND source_message_id = ?',
        variables: [Variable(source), Variable(id)],
      ).getSingle())
          .data;

  Future<Map<String, Object?>> progressOf(String id,
          {String source = 'email'}) async =>
      (await db.customSelect(
        'SELECT * FROM message_progress '
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable(source), Variable(id)],
      ).getSingle())
          .data;

  test('restoreMessage stamps the override and clears the gate verdict',
      () async {
    await seed('m-news');
    // Everything a failed, gated life leaves on the row.
    await db.customUpdate(
      "UPDATE messages SET triage_status = 'skipped', "
      "gate_reason = 'newsletter', triage_attempts = 4, "
      "triage_error = 'model unavailable' "
      "WHERE source_message_id = 'm-news'",
    );

    await store.restoreMessage('email', 'm-news');

    final row = await messageOf('m-news');
    expect(row['gate_override'], 'user');
    expect(row['triage_status'], 'pending');
    expect(row['gate_reason'], null);
    // A restore is a fresh ask, not a retry: what the row spent before the
    // gate took it is not held against the run the owner just asked for.
    expect(row['triage_attempts'], 0);
    expect(row['triage_error'], null);
  });

  test('restoreProgress reverses the gate skip cascade', () async {
    await seed('m-news');
    // Through the real writer, so the cascade under test is the one the
    // pipeline actually performs rather than a hand-written approximation.
    await store.writeTriageProgress(
      'email',
      'm-news',
      state: 'skipped',
      gateReason: 'newsletter',
    );
    expect((await progressOf('m-news'))['dropped'], 1);

    final receivedAt = await store.restoreProgress('email', 'm-news');
    expect(receivedAt, '2026-09-01T10:00:00Z');

    final row = await progressOf('m-news');
    for (final stage in [
      'triage_state',
      'extract_state',
      'storyline_state',
      'draft_state',
      'settle_state',
    ]) {
      expect(row[stage], 'pending', reason: '$stage should be reopened');
    }
    for (final at in [
      'triage_at',
      'extract_at',
      'storyline_at',
      'draft_at',
      'settle_at',
    ]) {
      expect(row[at], null, reason: '$at should be unset');
    }
    expect(row['outcome'], 'pending');
    expect(row['dropped'], 0);
    expect(row['drop_reason'], null);
    // The message itself was never in doubt — only what the pipeline made of
    // it was.
    expect(row['ingest_state'], 'done');
  });

  test('restoreProgress clears a drop reason the settle path cannot', () async {
    await seed('m-quiet');
    await store.writeSettledProgress(
      'email',
      'm-quiet',
      needsYou: false,
      reason: 'not_worthy',
      dropped: true,
    );
    expect((await progressOf('m-quiet'))['drop_reason'], 'not_worthy');

    await store.restoreProgress('email', 'm-quiet');

    // `writeSettledProgress` only ever writes the reason on the way DOWN (its
    // `CASE WHEN ?2 = 1`), so a row it un-drops keeps the stale reason. This
    // is the one writer that clears it, and the restored row must not carry
    // the old verdict forward.
    final row = await progressOf('m-quiet');
    expect(row['dropped'], 0);
    expect(row['drop_reason'], null);
  });

  test('restoreProgress on a message with no progress row returns null',
      () async {
    expect(await store.restoreProgress('email', 'never-stored'), null);
  });

  test('capPendingTriage never demotes a restored message', () async {
    // Three pending inbound messages, oldest first — a cap of 1 keeps only
    // the newest, so both of the others are outside the window.
    await seed('old-restored', receivedAt: '2026-08-01T09:00:00Z');
    await seed('old-plain', receivedAt: '2026-08-01T10:00:00Z');
    await seed('fresh', receivedAt: '2026-09-01T10:00:00Z');
    await store.restoreMessage('email', 'old-restored');

    await store.capPendingTriage(1);

    // The stamp is the user's explicit ask for this one row, and the backlog
    // sweep is exactly where a restore from deep in the archive would
    // otherwise be undone the moment a first sync ran.
    expect((await messageOf('old-restored'))['triage_status'], 'pending');

    final plain = await messageOf('old-plain');
    expect(plain['triage_status'], 'skipped');
    expect(plain['gate_reason'], 'backlog');

    expect((await messageOf('fresh'))['triage_status'], 'pending');
  });
}
