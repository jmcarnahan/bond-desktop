// `show`: drift generates its own row classes from the schema, and this file
// means the database itself.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:bond_inbox/services/storyline_edits.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// What the SPLIT made newly reachable.
///
/// The user actions came out of `storyline_service.dart` unchanged, and the
/// suite that covers their behaviour — `storyline_service_test` — still calls
/// them through the service and is the proof that nothing moved. What could
/// not be tested before is the seam itself: a [StorylineEdits] built with no
/// service behind it at all, and the one collaborator that crosses back to the
/// service handed in as a plain callback.
void main() {
  late BondDatabase db;
  late MessageStore store;

  /// Every storyline id the stub was asked about, in order. The service owns
  /// the real recipe — four other callers there compute the same hash — so
  /// what this file pins is that the edits ask for it rather than keeping a
  /// second recipe of their own.
  late List<String> hashedFor;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    hashedFor = [];
  });

  tearDown(() async => db.close());

  StorylineEdits edits({PipelineProgress? progress, ActivityLog? log}) =>
      StorylineEdits(
        store,
        progress: progress ?? const PipelineProgress.disabled(),
        log: log,
        memberHashOf: (id) async {
          hashedFor.add(id);
          return 'hash-of-$id';
        },
      );

  /// One message on a thread, and with it the `message_progress` row
  /// `upsertMessage` writes — the row the storyline pointer lands on.
  Future<void> seedMessage(
    String key,
    String id, {
    String receivedAt = '2026-08-28T10:00:00Z',
  }) =>
      store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'inbound',
        'subject': 'Harbour Lane survey',
        'from_name': 'Priya Raman',
        'from_address': 'priya@example.com',
        'received_at': receivedAt,
        'body_text': 'The surveyor can come on the ninth.',
        'triage_status': 'triaged',
      });

  Future<void> seedThread(String key, String messageId) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Harbour Lane survey',
      'state': 'waiting',
      'last_message_at': '2026-08-28T10:00:00Z',
      'participants_json': '[]',
    });
    await seedMessage(key, messageId);
  }

  Future<String?> pointerOf(String messageId) async => (await db
          .customSelect(
            'SELECT storyline_id FROM message_progress '
            'WHERE source = ? AND source_message_id = ?',
            variables: [const Variable('email'), Variable(messageId)],
          )
          .getSingle())
      .data['storyline_id'] as String?;

  test('a hand-filed thread stamps the pointer and queues both kinds',
      () async {
    await seedThread('c1', 'm1');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Harbour Lane move',
      status: 'active',
      createdBy: 'user',
    );

    await edits().addThread('sl-1', 'email', 'c1');

    // The member row is what the timeline and the rail read; the pointer is
    // what the home feed and the hot strip read. A filing that wrote only the
    // first appeared on half the app.
    expect((await store.membersOf('sl-1')).single.conversationKey, 'c1');
    expect(await pointerOf('m1'), 'sl-1');
    // Two requeues, not one: what the group is ABOUT changed, and so did where
    // it stands, because the thread brought its own messages.
    expect((await store.nextPendingWork('storyline_refresh'))?['entity_id'],
        'sl-1');
    expect((await store.nextPendingWork('storyline_recap'))?['entity_id'],
        'sl-1');
  });

  test('filing a thread ticks the screen once per message it moved', () async {
    final bus = ProgressBus();
    addTearDown(bus.dispose);
    final ticks = <ProgressTick>[];
    bus.ticks.listen(ticks.add);

    await seedThread('c1', 'm1');
    await seedMessage('c1', 'm2', receivedAt: '2026-08-29T09:00:00Z');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Harbour Lane move',
      status: 'active',
      createdBy: 'user',
    );

    await edits(progress: PipelineProgress(store, bus: bus))
        .addThread('sl-1', 'email', 'c1');
    await pumpEventQueue();

    // The recorder carries the tick and NOT the write, so what this pins is
    // that the edits hand the rows they stamped to the progress recorder they
    // were given. An open home feed patches those rows the moment the user
    // files the thread rather than whenever the next pass touches them.
    expect(ticks.map((t) => t.sourceMessageId), ['m1', 'm2']);
    expect(ticks.map((t) => t.stage).toSet(), {'storyline'});
    expect(ticks.map((t) => t.state).toSet(), {'done'});
  });

  test('unblocking records what it lifted and files nothing back', () async {
    await seedThread('c1', 'm1');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Harbour Lane move',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'keep', addedBy: 'auto');
    await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
    final log = ActivityLog(store);
    addTearDown(log.dispose);

    await edits(log: log).unblockThread('sl-1', 'email', 'c1');

    // The one action in this class that writes an activity row of its own, so
    // it is the one that proves the log reaches the moved bodies.
    final row = ActivityEvent.fromRow((await store.recentActivity()).single);
    expect(row.kind, 'storyline_unblock');
    expect(row.source, 'email');
    expect(row.entityId, 'c1');
    expect(row.detail['storyline_id'], 'sl-1');
    // A withdrawn veto is not a membership: whether the thread belongs is the
    // model's question again.
    expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
    expect((await store.membersOf('sl-1')).map((m) => m.conversationKey),
        ['keep']);
  });

  test('the member hash is the callback the service handed in', () async {
    await seedThread('c1', 'm1');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Harbour Lane move',
      status: 'active',
      createdBy: 'user',
    );

    await edits().addThread('sl-1', 'email', 'c1');

    expect(hashedFor, ['sl-1']);
    expect((await store.getStoryline('sl-1'))?.memberHash, 'hash-of-sl-1');
  });

  test('evicting a gated thread returns how many memberships it took',
      () async {
    await seedThread('c1', 'm1');
    for (final id in ['sl-1', 'sl-2', 'sl-3']) {
      await store.insertStoryline(
        id: id,
        title: 'Harbour Lane move',
        status: 'active',
        createdBy: 'auto',
      );
    }
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await store.addStorylineMember('sl-2', 'email', 'c1', addedBy: 'auto');
    // The owner filed this one by hand, and a gate does not overrule a person.
    await store.addStorylineMember('sl-3', 'email', 'c1', addedBy: 'user');

    final evicted = await edits().evictGatedThread('email', 'c1');

    expect(evicted, 2);
    expect(await store.storylineIdsFor('email', 'c1'), ['sl-3']);
    expect(hashedFor, ['sl-1', 'sl-2']);
  });

  test('a declared storyline is written locked, with its recruit queued',
      () async {
    final id = await edits().declareStoryline(
      title: 'Harbour Lane move',
      charter: 'Everything about the move to Harbour Lane: the survey, the '
          'lease and the fit-out.',
    );

    final storyline = await store.getStoryline(id);
    expect(storyline?.title, 'Harbour Lane move');
    expect(storyline?.status, 'active');
    expect(storyline?.createdBy, 'user');
    // Both the user's word, so both locked: the only thing the model is asked
    // for is the filing.
    expect(storyline?.titleLocked, isTrue);
    expect(storyline?.charterLocked, isTrue);
    // Nothing is in it yet, so there is nothing to describe and nothing to
    // recap — the recruit is the whole queue.
    expect((await store.nextPendingWork('storyline_recruit'))?['entity_id'],
        id);
    for (final kind in const [
      'storyline_refresh',
      'storyline_recap',
      'storyline_audit',
    ]) {
      expect(await store.nextPendingWork(kind), isNull, reason: kind);
    }
    // No members, so no hash was ever asked for.
    expect(hashedFor, isEmpty);
  });
}
