import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Thread state as a fact about the messages the gate KEPT.
///
/// The fold at ingest sets `needs_reply` the moment an inbound lands, and the
/// gates speak afterwards — at the claim, at an Ignore, at a backlog
/// demotion. `refoldThreadState` is how the thread finds out, and everything
/// here is about the ONE direction it is allowed to move in: a gate drop only
/// ever takes an obligation away, and a Restore only ever gives one back.
///
/// The asymmetry is the state machine's own (`conversation_state.dart`): a
/// kept inbound must be STRICTLY newer than the newest outbound to ask for a
/// reply, so a tie settles the thread.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedConversation(
    String key, {
    String source = 'email',
    String state = 'needs_reply',
    String? ctaText,
    String ctaUrgency = 'normal',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': key,
      'state': state,
      'cta_text': ctaText,
      'cta_urgency': ctaUrgency,
    });
  }

  Future<void> seedMessage(
    String key,
    String id, {
    String source = 'email',
    String direction = 'inbound',
    String receivedAt = '2026-09-01T10:00:00Z',
    String triageStatus = 'triaged',
    String? gateReason,
    bool restored = false,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'from_name': 'Sarah Vance',
      'from_address': 'sarah@example.com',
      'received_at': receivedAt,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
    if (restored) await store.restoreMessage(source, id);
  }

  Future<Map<String, Object?>> conversation(
    String key, {
    String source = 'email',
  }) async =>
      (await store.getConversationRow(source, key))!;

  /// The Needs You chip, raised straight on the progress row: the settle pass
  /// is what normally writes it and this file is not testing the settle pass.
  Future<void> raiseChip(String id) async {
    await db.customUpdate(
      'UPDATE message_progress SET needs_you = 1 '
      'WHERE source = ? AND source_message_id = ?',
      variables: [Variable('email'), Variable(id)],
    );
  }

  Future<int> chipsOn(String key) async {
    final rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM message_progress '
          'WHERE source = ? AND conversation_key = ? AND needs_you = 1',
          variables: [Variable('email'), Variable(key)],
        )
        .getSingle();
    return (rows.data['n'] as num).toInt();
  }

  group('a gate drop lowers the thread', () {
    test('a thread whose only inbound was gated folds back to waiting',
        () async {
      await seedConversation('c1', ctaText: 'Send the signed order form');
      await seedMessage('c1', 'm1');
      await raiseChip('m1');
      // The gate speaks, late, exactly as the triage queue's tier one does.
      await store.writeTriage('email', 'm1',
          status: 'skipped', gateReason: 'no_reply');

      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        'waiting',
      );

      final row = await conversation('c1');
      expect(row['state'], 'waiting');
      // An ask can only come from a kept message, and there is none left.
      expect(row['cta_text'], isNull);
      expect(row['cta_urgency'], 'normal');
      expect(await chipsOn('c1'), 0);
      // "waiting since the gate spoke" is a different row from "waiting since
      // last month", and only `setConversationState` knows.
      expect(row['state_changed_at'], isNotNull);
      expect(row['state_changed_at'], isNot(''));
    });

    test('a kept inbound newer than the gated one keeps the thread asking',
        () async {
      await seedConversation('c1', ctaText: 'Send the signed order form');
      await seedMessage('c1', 'm1', receivedAt: '2026-09-01T09:00:00Z');
      await seedMessage('c1', 'm2', receivedAt: '2026-09-01T11:00:00Z');
      await store.writeTriage('email', 'm1',
          status: 'skipped', gateReason: 'newsletter');

      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        isNull,
      );

      final row = await conversation('c1');
      expect(row['state'], 'needs_reply');
      // Nothing moved, so nothing was cleared either.
      expect(row['cta_text'], 'Send the signed order form');
    });

    test('a kept inbound older than the newest outbound folds to waiting',
        () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-09-01T09:00:00Z');
      await seedMessage(
        'c1',
        'sent-1',
        direction: 'outbound',
        receivedAt: '2026-09-01T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );

      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        'waiting',
      );
      final row = await conversation('c1');
      expect(row['state'], 'waiting');
      // A kept inbound exists, so the CTA is left alone — the thread simply
      // has nothing outstanding, which is not the same as nothing said.
      expect(await chipsOn('c1'), 0);
    });

    test('a tie between a reply and the mail it answers settles the thread',
        () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-09-01T10:00:00Z');
      await seedMessage(
        'c1',
        'sent-1',
        direction: 'outbound',
        receivedAt: '2026-09-01T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );

      // The fold's own asymmetry, re-read off the table: STRICTLY newer.
      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        'waiting',
      );
    });

    test('an outbound is the owner\'s word whatever the gate stamped it',
        () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-09-01T09:00:00Z');
      await seedMessage(
        'c1',
        'sent-1',
        direction: 'outbound',
        receivedAt: '2026-09-01T10:00:00Z',
        // Every outbound is born `skipped`/`outbound`; a kept clause on this
        // side would throw away every reply the thread contains.
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );

      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        'waiting',
      );
    });

    test('a lowering refold never raises a waiting thread', () async {
      await seedConversation('c1', state: 'waiting');
      await seedMessage('c1', 'm1');

      // A kept inbound and no outbound: the rule COMPUTES `needs_reply`, and
      // this direction still refuses to write it. A widened window's threads
      // must not be reopened by a refold.
      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        isNull,
      );
      expect((await conversation('c1'))['state'], 'waiting');
    });

    test('done is a human\'s decision and neither direction moves it',
        () async {
      await seedConversation('c1', state: 'done', ctaText: 'Old ask');
      await seedMessage('c1', 'm1');
      await store.writeTriage('email', 'm1',
          status: 'skipped', gateReason: 'self');

      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        isNull,
      );
      expect(
        await store.refoldThreadState('email', 'm1', restored: true),
        isNull,
      );
      final row = await conversation('c1');
      expect(row['state'], 'done');
      expect(row['cta_text'], 'Old ask');
    });

    test('a message under no thread row, and a message nobody stored',
        () async {
      await seedMessage('ghost', 'm1');
      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        isNull,
      );
      expect(
        await store.refoldThreadState('email', 'never-stored', restored: false),
        isNull,
      );
    });
  });

  group('what counts as kept', () {
    test('a chat born skipped under teams_source is a real message', () async {
      await seedConversation('chat-1', source: 'teams');
      await seedMessage(
        'chat-1',
        'chat-m1',
        source: 'teams',
        triageStatus: 'skipped',
        gateReason: 'teams_source',
      );

      expect(
        await store.refoldThreadState('teams', 'chat-m1', restored: false),
        isNull,
      );
      expect(
        (await conversation('chat-1', source: 'teams'))['state'],
        'needs_reply',
      );
    });

    test('a settle-time not_worthy drop is a verdict, not a gate', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1');
      // The settle pass writes on `message_progress` and leaves
      // `messages.triage_status` alone — which is exactly why the thread does
      // not move.
      await store.writeSettledProgress(
        'email',
        'm1',
        needsYou: false,
        reason: 'not_worthy',
        dropped: true,
      );

      expect(
        await store.refoldThreadState('email', 'm1', restored: false),
        isNull,
      );
      expect((await conversation('c1'))['state'], 'needs_reply');
    });
  });

  group('a restore raises the thread', () {
    test('restoring the newest inbound puts the thread back on the hook',
        () async {
      await seedConversation('c1', state: 'waiting');
      await seedMessage(
        'c1',
        'm1',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
      );
      // What `RestoreService` does before it asks for the refold.
      await store.restoreMessage('email', 'm1');

      expect(
        await store.refoldThreadState('email', 'm1', restored: true),
        'needs_reply',
      );
      expect((await conversation('c1'))['state'], 'needs_reply');
    });

    test('a raise never lowers, however the rule computes', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-09-01T09:00:00Z');
      await seedMessage(
        'c1',
        'sent-1',
        direction: 'outbound',
        receivedAt: '2026-09-01T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );

      // `waiting` is what the rule computes, and this direction refuses it.
      expect(
        await store.refoldThreadState('email', 'm1', restored: true),
        isNull,
      );
      expect((await conversation('c1'))['state'], 'needs_reply');
    });

    test('restoring a message older than the user\'s reply asks nothing',
        () async {
      await seedConversation('c1', state: 'waiting');
      await seedMessage(
        'c1',
        'm1',
        receivedAt: '2026-09-01T09:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
      );
      await seedMessage(
        'c1',
        'sent-1',
        direction: 'outbound',
        receivedAt: '2026-09-01T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );
      await store.restoreMessage('email', 'm1');

      expect(
        await store.refoldThreadState('email', 'm1', restored: true),
        isNull,
      );
      expect((await conversation('c1'))['state'], 'waiting');
    });
  });

  group('the backlog demotion tells the threads it demotes', () {
    test('it folds the threads whose last kept inbound it just took away',
        () async {
      await seedConversation('c1');
      await seedConversation('c2');
      await seedMessage('c1', 'old-1',
          receivedAt: '2026-08-01T09:00:00Z', triageStatus: 'pending');
      await seedMessage('c1', 'old-2',
          receivedAt: '2026-08-01T10:00:00Z', triageStatus: 'pending');
      await seedMessage('c2', 'fresh',
          receivedAt: '2026-09-01T10:00:00Z', triageStatus: 'pending');

      // A cap of 1 keeps only `fresh`, so both of c1's messages are demoted.
      expect(await store.capPendingTriage(1), 1);

      expect((await conversation('c1'))['state'], 'waiting');
      expect((await conversation('c2'))['state'], 'needs_reply');
    });

    test('a restored message is exempt, so its thread never moves', () async {
      await seedConversation('c1');
      await seedConversation('c2');
      await seedMessage('c1', 'old-restored',
          receivedAt: '2026-08-01T09:00:00Z',
          triageStatus: 'pending',
          restored: true);
      await seedMessage('c2', 'fresh',
          receivedAt: '2026-09-01T10:00:00Z', triageStatus: 'pending');

      expect(await store.capPendingTriage(1), 0);
      expect((await conversation('c1'))['state'], 'needs_reply');
    });

    test('one thread of four demoted messages is refolded once', () async {
      await seedConversation('c1');
      for (var i = 0; i < 4; i++) {
        await seedMessage('c1', 'old-$i',
            receivedAt: '2026-08-0${i + 1}T09:00:00Z',
            triageStatus: 'pending');
      }
      await seedConversation('c2');
      await seedMessage('c2', 'fresh',
          receivedAt: '2026-09-01T10:00:00Z', triageStatus: 'pending');

      expect(await store.capPendingTriage(1), 1);
    });
  });

  group('a reply a widened window backfilled', () {
    test('settles the thread on the next lowering refold, and that is right',
        () async {
      // The ask, and the answer the user actually sent — five days later, and
      // reached only when the sync window widened. `foldMessage(historical:
      // true)` refused to move state for that Sent copy at ingest, so the
      // thread is still on record as owing a reply.
      await seedConversation('c1', ctaText: 'Send the signed order form');
      await seedMessage('c1', 'ask', receivedAt: '2026-08-12T10:00:00Z');
      await seedMessage(
        'c1',
        'backfilled-reply',
        direction: 'outbound',
        receivedAt: '2026-08-17T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );
      // Something else on the thread the gate throws out, which is all it
      // takes to ask the thread to re-derive itself.
      await seedMessage(
        'c1',
        'newsletter',
        receivedAt: '2026-08-25T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
      );

      expect(
        await store.refoldThreadState(
          'email',
          'newsletter',
          restored: false,
        ),
        'waiting',
        reason: 'the `historical` flag is honoured for RAISING, which this '
            'path never does, and is deliberately not consulted when '
            'lowering: the user DID answer, and this refold reads the whole '
            'mailbox as stored rather than one sync pass',
      );
      expect((await conversation('c1'))['state'], 'waiting');
      expect(
        (await conversation('c1'))['cta_text'],
        'Send the signed order form',
        reason: 'a kept inbound is still on the thread, so the ask it was '
            'written about is not cleared',
      );
    });
  });

  group('the one-shot repair', () {
    test('it lowers exactly the threads that were lying, and counts them',
        () async {
      // Lying: the gate took its only inbound.
      await seedConversation('lying');
      await seedMessage('lying', 'm1',
          triageStatus: 'skipped', gateReason: 'no_reply');
      // Honest: a kept inbound, nothing answered.
      await seedConversation('honest');
      await seedMessage('honest', 'm2');
      // Closed by a human, and holding a gated message besides.
      await seedConversation('closed', state: 'done');
      await seedMessage('closed', 'm3',
          triageStatus: 'skipped', gateReason: 'self');
      // Already quiet, and the rule would raise it — which this never does.
      await seedConversation('quiet', state: 'waiting');
      await seedMessage('quiet', 'm4');
      // A chat under the legacy tolerance, on the other connector.
      await seedConversation('chat-1', source: 'teams');
      await seedMessage('chat-1', 'chat-m1',
          source: 'teams',
          triageStatus: 'skipped',
          gateReason: 'teams_source');

      expect(await store.refoldAllThreadStates(), 1);

      expect((await conversation('lying'))['state'], 'waiting');
      expect((await conversation('honest'))['state'], 'needs_reply');
      expect((await conversation('closed'))['state'], 'done');
      expect((await conversation('quiet'))['state'], 'waiting');
      expect(
        (await conversation('chat-1', source: 'teams'))['state'],
        'needs_reply',
      );
    });

    test('a second run finds nothing left to do', () async {
      await seedConversation('lying');
      await seedMessage('lying', 'm1',
          triageStatus: 'skipped', gateReason: 'backlog');

      expect(await store.refoldAllThreadStates(), 1);
      expect(await store.refoldAllThreadStates(), 0);
    });
  });
}
