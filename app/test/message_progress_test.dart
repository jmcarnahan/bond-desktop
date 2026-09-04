import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// `message_progress` — the row per message that the home screen reads, and
/// the writes that move it through the pipeline.
///
/// The thing this file is really about is that the row is the app's memory of
/// what it DECIDED, not a cache of what is currently true. A settled row is
/// history: nothing that happens to the thread afterwards may rewrite it.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProgressBus bus;
  late PipelineProgress progress;
  late List<ProgressTick> ticks;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    bus = ProgressBus();
    progress = PipelineProgress(store, bus: bus);
    ticks = [];
    bus.ticks.listen(ticks.add);
  });

  tearDown(() async {
    bus.dispose();
    await db.close();
  });

  Future<void> ingest(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String? receivedAt = '2026-09-01T10:00:00Z',
    String triageStatus = 'pending',
    String? gateReason,
    String direction = 'inbound',
    bool isRead = false,
    String? urgency,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': 'Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': receivedAt,
      'is_read': isRead ? 1 : 0,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
      'created_at': '2026-09-01T09:00:00Z',
      'updated_at': '2026-09-01T09:00:00Z',
    });
    if (urgency != null) {
      await db.customUpdate(
        'UPDATE messages SET urgency = ?, needs_action = 1 '
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable(urgency), Variable(source), Variable(id)],
      );
    }
  }

  Future<Map<String, Object?>> progressOf(
    String id, {
    String source = 'email',
  }) async =>
      (await db
              .customSelect(
                'SELECT * FROM message_progress '
                'WHERE source = ? AND source_message_id = ?',
                variables: [Variable(source), Variable(id)],
              )
              .getSingle())
          .data;

  group('ingest', () {
    test('a fresh message starts with a row that says nothing has happened',
        () async {
      await ingest('m1');

      final row = await progressOf('m1');
      expect(row['ingest_state'], 'done');
      expect(row['triage_state'], 'pending');
      expect(row['extract_state'], 'pending');
      expect(row['storyline_state'], 'pending');
      expect(row['draft_state'], 'pending');
      expect(row['settle_state'], 'pending');
      expect(row['outcome'], 'pending');
      expect(row['dropped'], 0);
      expect(row['drop_reason'], null);
      expect(row['needs_you'], 0);
      expect(row['received_at'], '2026-09-01T10:00:00Z');
      expect(row['conversation_key'], 'c1');
      // Nothing is stamped: no stage has finished.
      expect(row['triage_at'], null);
      expect(row['settle_at'], null);
    });

    test('a message with no timestamp is paged by when it was stored',
        () async {
      // A chat backfill and a Graph payload missing `receivedDateTime` both
      // land here, and `received_at` is the paging cursor — a NULL in it is a
      // row the feed could never reach.
      await ingest('m1', receivedAt: null);

      expect((await progressOf('m1'))['received_at'], '2026-09-01T09:00:00Z');
    });

    test('a message the gate threw out at ingest lands finished and dropped',
        () async {
      await ingest(
        'm1',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
      );

      final row = await progressOf('m1');
      expect(row['triage_state'], 'skipped');
      expect(row['extract_state'], 'skipped');
      expect(row['storyline_state'], 'skipped');
      // Drafting with the rest: nothing will ever queue a reply for mail the
      // gate threw out, so the bar stops here rather than waiting on it.
      expect(row['draft_state'], 'skipped');
      expect(row['settle_state'], 'done');
      expect(row['outcome'], 'dropped');
      expect(row['dropped'], 1);
      expect(row['drop_reason'], 'newsletter');
    });

    test('a skip with no reason behind it is not a drop', () async {
      // `skipped` with no `gate_reason` is the legacy Teams tolerance — a row
      // stored before chats were triaged like mail. Nobody judged it, so
      // hiding it under the "show dropped" toggle would be a claim about a
      // verdict that was never reached.
      await ingest('m1', triageStatus: 'skipped');

      final row = await progressOf('m1');
      expect(row['triage_state'], 'skipped');
      expect(row['dropped'], 0);
      expect(row['outcome'], 'pending');
    });

    test('re-ingesting a message leaves the progress it has made alone',
        () async {
      await ingest('m1');
      await progress.noteTriage('email', 'm1', state: 'done', urgency: 'high');

      // What a delta feed replaying a page does.
      await ingest('m1');

      final row = await progressOf('m1');
      expect(row['triage_state'], 'done');
      expect(row['urgency'], 'high');
    });

    test('the write says whether the pipeline had heard of this one', () async {
      // What the sync services turn into an ingest tick. After the fact there
      // is nothing in the row to tell an insert from a replay, so the write
      // itself has to answer — and a gate-dropped message is finished by then,
      // with no later stage left to announce it.
      final row = {
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'received_at': '2026-09-01T10:00:00Z',
      };

      final first = await store.upsertMessage(row);
      expect(
        first,
        (await store.pageHomeFeed()).single.receivedAt,
        reason: 'the answer is the key the feed sorts and pages on',
      );

      expect(
        await store.upsertMessage(row),
        isNull,
        reason: 'a delta page replaying itself is not an arrival',
      );
    });

    test('each connector gets its own row for a colliding id', () async {
      await ingest('m1');
      await ingest('m1', source: 'teams', conversationKey: 'chat-1');

      expect((await progressOf('m1'))['conversation_key'], 'c1');
      expect(
        (await progressOf('m1', source: 'teams'))['conversation_key'],
        'chat-1',
      );
    });
  });

  group('stage writes', () {
    test('triage moves through running and stamps only when it finishes',
        () async {
      await ingest('m1');

      await progress.noteTriage('email', 'm1', state: 'running');
      var row = await progressOf('m1');
      expect(row['triage_state'], 'running');
      expect(row['triage_at'], null);

      await progress.noteTriage('email', 'm1', state: 'done', urgency: 'high');
      row = await progressOf('m1');
      expect(row['triage_state'], 'done');
      expect(row['urgency'], 'high');
      expect(row['triage_at'], isNotNull);
    });

    test('a park puts triage back to waiting and stamps nothing', () async {
      await ingest('m1');
      await progress.noteTriage('email', 'm1', state: 'running');

      await progress.noteTriage('email', 'm1', state: 'pending');

      final row = await progressOf('m1');
      expect(row['triage_state'], 'pending');
      expect(row['triage_at'], null);
      expect(row['outcome'], 'pending');
    });

    test('a gate at triage time finishes the whole row, not one stage',
        () async {
      await ingest('m1');
      await progress.noteTriage('email', 'm1', state: 'running');

      await progress.noteTriage(
        'email',
        'm1',
        state: 'skipped',
        gateReason: 'no_reply',
      );

      // The extract and storyline queues honour the gate by never running, so
      // nothing downstream is ever going to write those columns.
      final row = await progressOf('m1');
      expect(row['triage_state'], 'skipped');
      expect(row['extract_state'], 'skipped');
      expect(row['storyline_state'], 'skipped');
      // Drafting with the rest: nothing will ever queue a reply for mail the
      // gate threw out, so the bar stops here rather than waiting on it.
      expect(row['draft_state'], 'skipped');
      expect(row['settle_state'], 'done');
      expect(row['outcome'], 'dropped');
      expect(row['dropped'], 1);
      expect(row['drop_reason'], 'no_reply');
    });

    test('a late gate does not erase an extraction that already happened',
        () async {
      await ingest('m1');
      await progress.noteExtract('email', 'm1', state: 'done');

      await progress.noteTriage(
        'email',
        'm1',
        state: 'skipped',
        gateReason: 'newsletter',
      );

      final row = await progressOf('m1');
      expect(row['extract_state'], 'done');
      expect(row['storyline_state'], 'skipped');
    });

    test('extract stamps on every terminal state and not on running',
        () async {
      await ingest('m1');

      await progress.noteExtract('email', 'm1', state: 'running');
      expect((await progressOf('m1'))['extract_at'], null);

      await progress.noteExtract('email', 'm1', state: 'error');
      final row = await progressOf('m1');
      expect(row['extract_state'], 'error');
      expect(row['extract_at'], isNotNull);
    });

    test('a note about a message with no row is a no-op, not a failure',
        () async {
      await progress.noteExtract('email', 'ghost', state: 'done');

      await pumpEventQueue();
      expect(ticks, isEmpty);
    });
  });

  group('the storyline fan-out', () {
    test('one assignment writes every message of the thread', () async {
      await ingest('m1');
      await ingest('m2', receivedAt: '2026-09-01T11:00:00Z');
      await ingest('other', conversationKey: 'c2');

      await progress.noteStoryline(
        'email',
        'c1',
        state: 'done',
        storylineId: 'sl-1',
      );

      expect((await progressOf('m1'))['storyline_id'], 'sl-1');
      expect((await progressOf('m2'))['storyline_id'], 'sl-1');
      expect((await progressOf('other'))['storyline_state'], 'pending');
      await pumpEventQueue();
      expect(ticks.map((t) => t.sourceMessageId), unorderedEquals(['m1', 'm2']));
    });

    test('a settled row is history and does not join later', () async {
      await ingest('m1');
      await ingest('m2', receivedAt: '2026-09-01T11:00:00Z');
      // m1 was already announced to the user last week.
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );

      await progress.noteStoryline(
        'email',
        'c1',
        state: 'done',
        storylineId: 'sl-1',
      );

      expect((await progressOf('m1'))['storyline_id'], null);
      expect((await progressOf('m2'))['storyline_id'], 'sl-1');
    });

    test('an outcome with no storyline behind it keeps the one already stored',
        () async {
      await ingest('m1');
      await progress.noteStoryline(
        'email',
        'c1',
        state: 'done',
        storylineId: 'sl-1',
      );

      // A later pass finding no candidate is not a retraction.
      await progress.noteStoryline('email', 'c1', state: 'done');

      expect((await progressOf('m1'))['storyline_id'], 'sl-1');
    });
  });

  group('settling', () {
    /// Everything but the drafting stage, which the tests below say their own
    /// thing about: a settle only closes the row when the suggestion is in.
    Future<void> finishDraft(String id) =>
        progress.noteDraft('email', id, state: 'skipped');

    test('a message the user was told about is done and not dropped',
        () async {
      await ingest('m1');
      await finishDraft('m1');

      await progress.noteSettled(
        'email',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );

      final row = await progressOf('m1');
      expect(row['settle_state'], 'done');
      expect(row['outcome'], 'done');
      expect(row['dropped'], 0);
      expect(row['needs_you'], 1);
      expect(row['settle_at'], isNotNull);
    });

    test('one the user got to first is done, not dropped', () async {
      await ingest('m1');
      await finishDraft('m1');

      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'read',
        dropped: false,
      );

      final row = await progressOf('m1');
      expect(row['outcome'], 'done');
      expect(row['dropped'], 0);
      // The reason is only recorded when it explains a drop; nothing has to
      // explain a message that simply finished.
      expect(row['drop_reason'], null);
    });

    test('one the app judged unworthy is dropped, with the reason', () async {
      await ingest('m1');
      await finishDraft('m1');

      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'not_worthy',
        dropped: true,
      );

      final row = await progressOf('m1');
      expect(row['outcome'], 'dropped');
      expect(row['dropped'], 1);
      expect(row['drop_reason'], 'not_worthy');
    });

    test('the toast does not wait for the reply suggestion, the outcome does',
        () async {
      await ingest('m1');

      await progress.noteSettled(
        'email',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );

      // Everything the user is told about is written; the row is simply not
      // finished, because the suggestion is not in sqlite yet.
      final row = await progressOf('m1');
      expect(row['settle_state'], 'done');
      expect(row['needs_you'], 1);
      expect(row['outcome'], 'pending');
    });

    test('and the draft write is what closes it, without a sweep', () async {
      await ingest('m1');
      await progress.noteTriage('email', 'm1', state: 'done');
      await progress.noteExtract('email', 'm1', state: 'done');
      await progress.noteStoryline('email', 'c1', state: 'done');
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'read',
        dropped: false,
      );

      await progress.noteDraft('email', 'm1', state: 'done');

      // The bar completes the moment the suggestion lands, rather than at
      // whatever distance the next settle sweep happens to be.
      expect((await progressOf('m1'))['outcome'], 'done');
    });

    test('a draft landing early cannot close a row still being worked',
        () async {
      await ingest('m1');

      await progress.noteDraft('email', 'm1', state: 'done');

      final row = await progressOf('m1');
      expect(row['draft_state'], 'done');
      expect(row['outcome'], 'pending');
    });

    test('and one landing on a dropped row leaves the verdict alone',
        () async {
      await ingest('m1', triageStatus: 'skipped', gateReason: 'newsletter');

      await progress.noteDraft('email', 'm1', state: 'skipped');

      expect((await progressOf('m1'))['outcome'], 'dropped');
    });
  });

  group('the settle sweep', () {
    /// Everything a row needs to be sweepable: every stage terminal, and a
    /// score on its thread.
    Future<void> finishStages(String id) async {
      await progress.noteTriage('email', id, state: 'done');
      await progress.noteExtract('email', id, state: 'done');
      await progress.noteStoryline('email', 'c1', state: 'done');
      await progress.noteDraft('email', id, state: 'skipped');
    }

    test('it closes a row whose stages are all finished', () async {
      await ingest('m1');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.9);

      expect(await progress.sweepSettled(threshold: 0.5), 1);

      final row = await progressOf('m1');
      expect(row['settle_state'], 'done');
      expect(row['outcome'], 'done');
    });

    test('it leaves a message the pipeline is still working on alone',
        () async {
      await ingest('m1');
      await progress.noteTriage('email', 'm1', state: 'done');
      await store.writeAttentionScore('email', 'c1', 0.9);

      expect(await progress.sweepSettled(threshold: 0.5), 0);
      expect((await progressOf('m1'))['settle_state'], 'pending');
    });

    test('it waits for the score, which is the last thing written', () async {
      await ingest('m1');
      await finishStages('m1');

      // No `conversation_ai` row at all: the ranking pass has not run, and the
      // coordinator may still have an opinion about this message.
      expect(await progress.sweepSettled(threshold: 0.5), 0);
      expect((await progressOf('m1'))['settle_state'], 'pending');
    });

    test('it does not re-close what the coordinator already settled',
        () async {
      await ingest('m1');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.9);
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'not_worthy',
        dropped: true,
      );

      expect(await progress.sweepSettled(threshold: 0.5), 0);
      expect((await progressOf('m1'))['outcome'], 'dropped');
    });

    test('a dropped row that reaches the sweep stays dropped', () async {
      await ingest('m1', triageStatus: 'skipped', gateReason: 'newsletter');
      await store.writeAttentionScore('email', 'c1', 0.9);

      // Already `settle_state = 'done'` from the gate, so the sweep passes
      // over it — and if it ever did not, the outcome would still say dropped.
      expect(await progress.sweepSettled(threshold: 0.5), 0);
      expect((await progressOf('m1'))['outcome'], 'dropped');
    });

    test('needs_you is judged against the threshold it was handed', () async {
      await ingest('m1', urgency: 'high');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.6);

      expect(await progress.sweepSettled(threshold: 0.9), 1);
      expect((await progressOf('m1'))['needs_you'], 0);
    });

    test('an ask over the threshold reads as needing the user', () async {
      await ingest('m1', urgency: 'high');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.6);

      expect(await progress.sweepSettled(threshold: 0.5), 1);
      expect((await progressOf('m1'))['needs_you'], 1);
    });

    test('a message already read needs nobody, however loud it is', () async {
      await ingest('m1', urgency: 'urgent', isRead: true);
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.95);

      expect(await progress.sweepSettled(threshold: 0.5), 1);
      // The coordinator's decision table drops a read message before
      // worthiness is asked; the sweep, which sees rows the coordinator never
      // did, has to carry that guard itself.
      expect((await progressOf('m1'))['needs_you'], 0);
    });

    test('a thread the user finished needs nobody', () async {
      await ingest('m1', urgency: 'high');
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c1',
        'state': 'done',
      });
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.95);

      await progress.sweepSettled(threshold: 0.5);

      expect((await progressOf('m1'))['needs_you'], 0);
    });

    test('a thread parked in Later needs nobody', () async {
      await ingest('m1', urgency: 'high');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.95);
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: 'later',
        reason: 'user',
      );

      await progress.sweepSettled(threshold: 0.5);

      expect((await progressOf('m1'))['needs_you'], 0);
    });

    test('a message with no ask in it needs nobody, whatever it scores',
        () async {
      await ingest('m1');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.99);

      await progress.sweepSettled(threshold: 0.5);

      expect((await progressOf('m1'))['needs_you'], 0);
    });
    test('it waits for the reply suggestion too', () async {
      await ingest('m1');
      await progress.noteTriage('email', 'm1', state: 'done');
      await progress.noteExtract('email', 'm1', state: 'done');
      await progress.noteStoryline('email', 'c1', state: 'done');
      await store.writeAttentionScore('email', 'c1', 0.9);

      expect(await progress.sweepSettled(threshold: 0.5), 0);
      expect((await progressOf('m1'))['settle_state'], 'pending');
    });

    test('it finishes a row that was settled and then left open', () async {
      await ingest('m1');
      await progress.noteTriage('email', 'm1', state: 'done');
      await progress.noteExtract('email', 'm1', state: 'done');
      await progress.noteStoryline('email', 'c1', state: 'done');
      await store.writeAttentionScore('email', 'c1', 0.9);
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );
      // A quit between the draft stage landing and the outcome being closed —
      // the one gap the draft write cannot close for itself. Written by hand
      // because going through the recorder would close the row on the way.
      await db.customUpdate(
        "UPDATE message_progress SET draft_state = 'done' "
        "WHERE source_message_id = 'm1'",
      );

      expect((await progressOf('m1'))['outcome'], 'pending');
      expect(await progress.sweepSettled(threshold: 0.5), 1);
      expect((await progressOf('m1'))['outcome'], 'done');
    });

    test('and leaves that row\'s verdict about the user exactly as it was',
        () async {
      await ingest('m1', urgency: 'high');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.9);
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );
      // The user has since READ the message, which is what would make the
      // SQL twin answer 0.
      await db.customUpdate(
        "UPDATE messages SET is_read = 1 WHERE source_message_id = 'm1'",
      );

      await progress.sweepSettled(threshold: 0.5);

      // A chip once earned survives being read. It clears when the user
      // replies or marks the thread done — never because their eyes passed
      // over it.
      expect((await progressOf('m1'))['needs_you'], 1);
      expect((await progressOf('m1'))['settle_at'], isNotNull);
    });
  });

  group('the needs-you exit', () {
    test('it flips the whole thread and says which rows it flipped', () async {
      await ingest('m1');
      await ingest('m2', receivedAt: '2026-09-01T11:00:00Z');
      await ingest('other', conversationKey: 'c2');
      for (final id in ['m1', 'm2', 'other']) {
        await db.customUpdate(
          'UPDATE message_progress SET needs_you = 1 '
          'WHERE source_message_id = ?',
          variables: [Variable(id)],
        );
      }

      final cleared = await store.clearNeedsYou('email', 'c1');

      expect(
        cleared.map((r) => r.sourceMessageId),
        unorderedEquals(['m1', 'm2']),
      );
      expect(cleared.first.receivedAt, isNotEmpty);
      expect((await progressOf('m1'))['needs_you'], 0);
      expect((await progressOf('other'))['needs_you'], 1);
    });

    test('a row that was never asking is not reported as having changed',
        () async {
      await ingest('m1');

      // Guarded on `needs_you = 1`, so a thread of forty read messages does
      // not produce forty ticks saying nothing happened.
      expect(await store.clearNeedsYou('email', 'c1'), isEmpty);
    });

    test('the recorder ticks once per row it actually cleared', () async {
      await ingest('m1');
      await db.customUpdate(
        "UPDATE message_progress SET needs_you = 1 "
        "WHERE source_message_id = 'm1'",
      );

      await progress.clearNeedsYou('email', 'c1');
      await pumpEventQueue();

      expect(ticks, hasLength(1));
      expect(ticks.single.sourceMessageId, 'm1');
      expect(ticks.single.receivedAt, '2026-09-01T10:00:00Z');
      expect((await progressOf('m1'))['needs_you'], 0);
    });

    test('and the disabled recorder clears nothing', () async {
      await ingest('m1');
      await db.customUpdate(
        "UPDATE message_progress SET needs_you = 1 "
        "WHERE source_message_id = 'm1'",
      );

      await const PipelineProgress.disabled().clearNeedsYou('email', 'c1');

      expect((await progressOf('m1'))['needs_you'], 1);
    });
  });

  group('the recorder itself', () {
    test('every write ticks the bus once, with the message it was about',
        () async {
      await ingest('m1');

      await progress.noteTriage('email', 'm1', state: 'running');
      await progress.noteExtract('email', 'm1', state: 'done');
      // A broadcast stream delivers on a microtask, so the last publish is
      // still in flight the instant `publish` returns — which is the whole
      // point: nothing on the pipeline's paths waits for a listener.
      await pumpEventQueue();

      expect(ticks, hasLength(2));
      expect(ticks.first.stage, 'triage');
      expect(ticks.first.state, 'running');
      expect(ticks.first.sourceMessageId, 'm1');
      expect(ticks.first.receivedAt, '2026-09-01T10:00:00Z');
      expect(ticks.last.stage, 'extract');
    });

    test('the disabled recorder writes nothing and emits nothing', () async {
      await ingest('m1');
      const off = PipelineProgress.disabled();

      await off.noteTriage('email', 'm1', state: 'done');
      await off.noteExtract('email', 'm1', state: 'done');
      await off.noteStoryline('email', 'c1', state: 'done');
      await off.noteSettled(
        'email',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );
      expect(await off.sweepSettled(threshold: 0.5), 0);
      expect(await off.assignedStorylineId('email', 'c1'), null);

      await pumpEventQueue();
      expect((await progressOf('m1'))['triage_state'], 'pending');
      expect(ticks, isEmpty);
    });

    test('a bus nobody built drops what it is handed', () {
      const off = ProgressBus.disabled();
      final seen = <ProgressTick>[];
      off.ticks.listen(seen.add);

      off.publish(
        const ProgressTick(
          source: 'email',
          sourceMessageId: 'm1',
          stage: 'triage',
          state: 'done',
          receivedAt: '2026-09-01T10:00:00Z',
        ),
      );
      off.dispose();

      expect(seen, isEmpty);
    });
  });

  test('wiping the mailbox takes the progress rows with it', () async {
    await ingest('m1');

    await store.wipeAll();

    final rows =
        await db.customSelect('SELECT * FROM message_progress').get();
    expect(rows, isEmpty);
  });
}
