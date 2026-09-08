import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The reads and the one write behind "what happened to this message".
///
/// Two properties carry most of it. The reads have to gather THREE grains —
/// the message, its thread, and its attachments — because that is how the
/// pipeline files its work, and a screen that showed only the message's own
/// rows would answer "nothing happened" about a message whose whole story is
/// on its thread. And the LIKE that reaches the attachment rows has to be
/// escaped, or a message id carrying an underscore would collect a stranger's
/// work.
///
/// [MessageStore.dropMessage] is the write, and what it does NOT touch is the
/// point: the verdict stays, the override stays, the finished stages stay, and
/// Restore has to be able to undo the whole thing.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One message and the `message_progress` row `upsertMessage` writes with it.
  Future<void> seed(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String subject = 'Renewal paperwork',
    String receivedAt = '2026-09-01T08:00:00Z',
    String triageStatus = 'triaged',
    String direction = 'inbound',
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': conversationKey,
        'direction': direction,
        'subject': subject,
        'from_name': 'Dana Whitfield',
        'from_address': 'dana@example.com',
        'body_text': 'Could you look at the DPA before Friday?',
        'received_at': receivedAt,
        'triage_status': triageStatus,
      });

  Future<void> logEvent(
    String kind,
    String entityId, {
    String source = 'email',
    String status = 'ok',
  }) =>
      store.recordActivity(
        kind: kind,
        status: status,
        source: source,
        entityId: entityId,
      );

  Future<Map<String, Object?>> messageRow(String id,
          {String source = 'email'}) async =>
      (await store.getMessageRow(source, id))!;

  Future<Map<String, Object?>> progressRow(String id,
          {String source = 'email'}) async =>
      (await store.getProgressRow(source, id))!;

  group('activityForEntity', () {
    test('gathers the message, its thread, and its attachments — and nothing '
        'a wildcard would have swept up', () async {
      // An id with an underscore in it: unescaped, `m_1|%` reads `_` as "any
      // character" and would collect `mX1|att9` below, which belongs to a
      // different message entirely.
      await seed('m_1', conversationKey: 'c1');

      await logEvent('triage', 'm_1');
      await logEvent('storyline', 'c1');
      await logEvent('attachment_text', 'm_1|att1');
      await logEvent('attachment_text', 'mX1|att9');
      await logEvent('triage', 'somebody-else');

      final events = await store.activityForEntity(
        sourceMessageId: 'm_1',
        conversationKey: 'c1',
      );

      // Newest first, and exactly the three grains.
      expect(
        [for (final row in events) row['entity_id']],
        ['m_1|att1', 'c1', 'm_1'],
      );
    });

    test('reads events written under another connector, because their source '
        'column is the WORK\'s and not the message\'s', () async {
      await seed('m1');
      await logEvent('storyline', 'c1', source: 'teams');

      final events = await store.activityForEntity(
        sourceMessageId: 'm1',
        conversationKey: 'c1',
      );

      expect(events, hasLength(1));
      expect(events.single['source'], 'teams');
    });

    test('honours its limit', () async {
      await seed('m1');
      for (var i = 0; i < 5; i++) {
        await logEvent('triage', 'm1');
      }

      expect(
        await store.activityForEntity(
          sourceMessageId: 'm1',
          conversationKey: 'c1',
          limit: 2,
        ),
        hasLength(2),
      );
    });
  });

  group('workItemsFor', () {
    test('gathers the same three grains, and stops at the connector',
        () async {
      await seed('m_1', conversationKey: 'c1');

      await store.enqueueWork('extract', 'email', 'm_1');
      await store.enqueueWork('storyline', 'email', 'c1');
      await store.enqueueWork('attachment_text', 'email', 'm_1|att1');
      await store.enqueueWork('attachment_text', 'email', 'mX1|att9');
      // The same id under a second connector is a different item of work, not
      // the same one seen twice — `work_items` keys on the source.
      await store.enqueueWork('extract', 'teams', 'm_1');

      final work = await store.workItemsFor('email', 'm_1', 'c1');

      expect(
        {for (final row in work) row['entity_id']},
        {'m_1', 'c1', 'm_1|att1'},
      );
      expect([for (final row in work) row['source']], everyElement('email'));
    });

    test('carries what a stuck row is stuck on', () async {
      await seed('m1');
      await store.enqueueWork('extract', 'email', 'm1');
      await store.writeWork(
        'extract',
        'email',
        'm1',
        status: 'error',
        error: 'model server off',
      );

      final work = await store.workItemsFor('email', 'm1', 'c1');

      expect(work.single['status'], 'error');
      expect(work.single['error'], 'model server off');
      expect(work.single['task_kind'], 'extract');
    });
  });

  group('the thread\'s storylines', () {
    setUp(() async {
      await store.insertStoryline(
        id: 'sl-live',
        title: 'Acme renewal',
        status: 'active',
        createdBy: 'auto',
      );
      await store.insertStoryline(
        id: 'sl-dismissed',
        title: 'Parking permits',
        status: 'dismissed',
        createdBy: 'auto',
      );
    });

    /// The stamps are set by hand: two writes a microsecond apart would order
    /// correctly and prove nothing about the ORDER BY.
    Future<void> stampMember(String storylineId, String at) => db.customUpdate(
          'UPDATE storyline_members SET added_at = ? WHERE storyline_id = ? '
          'AND source = ? AND conversation_key = ?',
          variables: [
            Variable(at),
            Variable(storylineId),
            Variable('email'),
            Variable('c1'),
          ],
        );

    test('membershipsForThread carries the title and status of each — '
        'including a storyline nobody kept', () async {
      await store.addStorylineMember(
        'sl-live',
        'email',
        'c1',
        addedBy: 'auto',
        evidence: 'Same renewal thread',
      );
      await store.addStorylineMember(
        'sl-dismissed',
        'email',
        'c1',
        addedBy: 'user',
        evidence: 'Filed by hand',
      );
      await stampMember('sl-live', '2026-09-01T08:00:00.000000Z');
      await stampMember('sl-dismissed', '2026-09-02T08:00:00.000000Z');

      final rows = await store.membershipsForThread('email', 'c1');

      // Newest first, and the dismissed one is present: the filing HAPPENED,
      // and a history that showed only what still stands is a history of the
      // present.
      expect([for (final row in rows) row['storyline_id']],
          ['sl-dismissed', 'sl-live']);
      expect(rows.first['title'], 'Parking permits');
      expect(rows.first['status'], 'dismissed');
      expect(rows.first['added_by'], 'user');
      expect(rows.first['evidence'], 'Filed by hand');
      expect(rows.last['title'], 'Acme renewal');
      expect(rows.last['status'], 'active');
    });

    test('another thread\'s memberships stay out of it', () async {
      await store.addStorylineMember('sl-live', 'email', 'c9',
          addedBy: 'auto');

      expect(await store.membershipsForThread('email', 'c1'), isEmpty);
    });

    test('blocksForThread carries both hands, newest first', () async {
      await store.removeStorylineMember(
        'sl-live',
        'email',
        'c1',
        block: true,
        blockedBy: 'user',
        evidence: 'Not this one',
      );
      await store.removeStorylineMember(
        'sl-dismissed',
        'email',
        'c1',
        block: true,
        blockedBy: 'audit',
        evidence: 'Re-check disagreed',
      );
      Future<void> stampBlock(String storylineId, String at) =>
          db.customUpdate(
            'UPDATE storyline_member_blocks SET blocked_at = ? '
            'WHERE storyline_id = ?',
            variables: [Variable(at), Variable(storylineId)],
          );
      await stampBlock('sl-live', '2026-09-01T08:00:00Z');
      await stampBlock('sl-dismissed', '2026-09-02T08:00:00Z');

      final rows = await store.blocksForThread('email', 'c1');

      expect([for (final row in rows) row['storyline_id']],
          ['sl-dismissed', 'sl-live']);
      expect([for (final row in rows) row['blocked_by']], ['audit', 'user']);
      expect(rows.last['evidence'], 'Not this one');
      expect(rows.last['title'], 'Acme renewal');
    });

    test('a block outlives the storyline it was written about', () async {
      await store.removeStorylineMember(
        'sl-live',
        'email',
        'c1',
        block: true,
        blockedBy: 'user',
        evidence: 'Not this one',
      );
      await db.customStatement("DELETE FROM storylines WHERE id = 'sl-live'");

      final rows = await store.blocksForThread('email', 'c1');

      // The LEFT JOIN is the contract: the block is the record, and it is
      // still true that somebody wrote it.
      expect(rows.single['storyline_id'], 'sl-live');
      expect(rows.single['title'], isNull);
      expect(rows.single['status'], isNull);
    });
  });

  group('the raw rows', () {
    test('getProgressRow hands back the stage clocks nothing else carries',
        () async {
      await seed('m1');
      await store.writeExtractProgress('email', 'm1', state: 'done');

      final row = await progressRow('m1');

      expect(row['source_message_id'], 'm1');
      expect(row['conversation_key'], 'c1');
      expect(row['extract_state'], 'done');
      expect(row['extract_at'], isNotNull);
      expect(await store.getProgressRow('email', 'ghost'), isNull);
    });

    test('the thread\'s AI state round-trips', () async {
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: 'later',
        reason: 'quiet thread',
      );
      await store.writeAttentionScore('email', 'c1', 0.42);

      final row = (await store.getConversationAi('email', 'c1'))!;

      expect(row['bucket'], 'later');
      expect(row['bucket_reason'], 'quiet thread');
      expect(row['attention_score'], closeTo(0.42, 0.0001));
      expect(await store.getConversationAi('email', 'c9'), isNull);
    });
  });

  group('textSearchMessages and the dropped filter', () {
    setUp(() async {
      await seed('kept', subject: 'Invoice 4471 is overdue');
      await seed(
        'gone',
        conversationKey: 'c2',
        subject: 'Invoice newsletter',
      );
      await store.writeSettledProgress(
        'email',
        'gone',
        needsYou: false,
        reason: 'newsletter',
        dropped: true,
      );
    });

    test('the archive keeps its meaning by default', () async {
      final rows = await store.textSearchMessages('invoice');

      // "I know I got that email" is the whole reason the read exists.
      expect({for (final row in rows) row.sourceMessageId}, {'kept', 'gone'});
    });

    test('and Home can ask for the same filter its table is under', () async {
      final rows =
          await store.textSearchMessages('invoice', includeDropped: false);

      expect([for (final row in rows) row.sourceMessageId], ['kept']);
    });
  });

  group('dropMessage', () {
    Future<String?> notifyState(String id, {String source = 'email'}) async {
      final rows = await db.customSelect(
        'SELECT state FROM message_notify '
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable<String>(source), Variable<String>(id)],
      ).get();
      return rows.isEmpty ? null : rows.single.data['state'] as String?;
    }

    Future<int> feedbackCount() async =>
        (await db.customSelect('SELECT COUNT(*) AS n FROM feedback_events')
                .getSingle())
            .data['n'] as int;

    test('a settled message becomes dropped, and keeps what actually ran',
        () async {
      await seed('m1');
      await store.writeExtractProgress('email', 'm1', state: 'done');
      await store.writeSettledProgress(
        'email',
        'm1',
        needsYou: true,
        reason: 'asks for the DPA',
        dropped: false,
      );

      expect(await store.dropMessage('email', 'm1'), isTrue);

      final message = await messageRow('m1');
      expect(message['triage_status'], 'skipped');
      expect(message['gate_reason'], 'user');

      final progress = await progressRow('m1');
      expect(progress['outcome'], 'dropped');
      expect(progress['dropped'], 1);
      expect(progress['drop_reason'], 'user');
      // The cascade closes PENDING stages only, so a stage that finished keeps
      // its answer — the screen still shows what the app got out of the
      // message before the owner threw it away.
      expect(progress['extract_state'], 'done');
      expect(progress['settle_state'], 'done');
    });

    test('the whole thread\'s chips go, and no verdict is rewritten',
        () async {
      await seed('m1');
      await seed('m2', receivedAt: '2026-09-01T09:00:00Z');
      for (final id in const ['m1', 'm2']) {
        await store.writeNeedsYouVerdict(
          'email',
          id,
          verdict: true,
          reason: 'asks for the DPA by Friday',
        );
        await store.writeSettledProgress(
          'email',
          id,
          needsYou: true,
          reason: 'asks for the DPA',
          dropped: false,
        );
      }

      await store.dropMessage('email', 'm1');

      // The snapshot the rails read clears for every message of the thread…
      expect((await progressRow('m1'))['needs_you'], 0);
      expect((await progressRow('m2'))['needs_you'], 0);
      // …and the judge's own answer is left exactly where it was. An Ignore is
      // the owner saying they do not want this message, not that the judge
      // misread it.
      expect((await messageRow('m1'))['needs_you_verdict'], 1);
      expect((await messageRow('m2'))['needs_you_verdict'], 1);
    });

    test('the thread stops holding an open ask', () async {
      await seed('m1');
      await store.writeNeedsYouVerdict(
        'email',
        'm1',
        verdict: true,
        reason: 'asks for the DPA by Friday',
      );
      expect(await store.hasOpenAsk('email', 'c1'), isTrue);

      await store.dropMessage('email', 'm1');

      // Through the gate clause of the open-ask predicate rather than through
      // the verdict, which is why the verdict never had to move.
      expect(await store.hasOpenAsk('email', 'c1'), isFalse);
    });

    test('it is written down as the owner\'s own thumbs-down', () async {
      await seed('m1');

      await store.dropMessage('email', 'm1');

      final rows =
          await db.customSelect('SELECT * FROM feedback_events').get();
      expect(rows, hasLength(1));
      expect(rows.single.data['scope'], 'message');
      // Connector-qualified: a message id is only unique inside the connector
      // that issued it, and two sources may well hand out the same string.
      expect(rows.single.data['scope_key'], 'email/m1');
      expect(rows.single.data['direction'], 'down');
      expect(rows.single.data['origin'], 'explicit');
    });

    test('an id nothing is stored under writes nothing at all', () async {
      await seed('m1');

      expect(await store.dropMessage('email', 'ghost'), isFalse);

      expect(await feedbackCount(), 0);
      expect((await messageRow('m1'))['triage_status'], 'triaged');
      expect((await progressRow('m1'))['dropped'], 0);
    });

    test('Restore is the exact way back', () async {
      await seed('m1');
      await store.writeExtractProgress('email', 'm1', state: 'done');
      await store.dropMessage('email', 'm1');

      await store.restoreMessage('email', 'm1');
      await store.restoreProgress('email', 'm1');

      final message = await messageRow('m1');
      expect(message['triage_status'], 'pending');
      expect(message['gate_reason'], isNull);
      // The stamp the gates cannot outvote — an Ignore never wrote it, and a
      // Restore after one puts it back.
      expect(message['gate_override'], 'user');

      final progress = await progressRow('m1');
      expect(progress['dropped'], 0);
      expect(progress['drop_reason'], isNull);
      expect(progress['outcome'], 'pending');
      expect(progress['triage_state'], 'pending');
      expect(progress['extract_state'], 'pending');
    });

    test('a triage result that lands after an Ignore is discarded', () async {
      // The queue claims a row and the model answers a minute later. An Ignore
      // pressed in between is the owner's own gate, and the answer that lands
      // afterwards must not reopen the message they just threw out.
      await seed('m1');
      await store.dropMessage('email', 'm1');

      await store.writeTriage(
        'email',
        'm1',
        status: 'triaged',
        result: const TriageResult(
          urgency: 'high',
          category: 'work',
          summary: 'asks for the DPA',
          needsAction: true,
          actionItems: [],
          replyExpected: true,
        ),
      );

      final message = await messageRow('m1');
      expect(message['triage_status'], 'skipped');
      expect(message['gate_reason'], 'user');
      expect(await store.hasOpenAsk('email', 'c1'), isFalse);
    });

    test('an Ignore settles the pending notify row', () async {
      // Otherwise the next coordinator sweep re-decides a row the owner has
      // already thrown out — and every admitted row settles exactly once.
      await seed('m1');
      await store.admitNotifyCandidates(
        armedAtIso: '2026-01-01T00:00:00.000000Z',
        recencyFloorIso: '2026-08-01T00:00:00.000000Z',
        deadlineIso: '2026-09-01T09:00:00.000000Z',
      );
      expect(await notifyState('m1'), 'pending');

      await store.dropMessage('email', 'm1');

      expect(await notifyState('m1'), 'suppressed');
    });

    test('a message the owner had already restored stays ignorable',
        () async {
      await seed('m1', triageStatus: 'skipped');
      await store.restoreMessage('email', 'm1');

      expect(await store.dropMessage('email', 'm1'), isTrue);

      final message = await messageRow('m1');
      expect(message['triage_status'], 'skipped');
      // Untouched on purpose: `triage_status` is what the handlers read, so
      // the message stays out, and the override is still there for the next
      // Restore to mean something.
      expect(message['gate_override'], 'user');
    });
  });
}
