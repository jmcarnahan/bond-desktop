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
      // "History" is a TERMINAL stage on a settled row, not the settle alone.
      // m1's storyline pass ran and found nothing, and the user was told that;
      // a thread that keeps growing must not rewrite the row they scrolled by.
      await ingest('m1');
      await progress.noteStoryline('email', 'c1', state: 'done');
      // m1 was already announced to the user last week.
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );

      // m2 arrives afterwards and the thread is assigned.
      await ingest('m2', receivedAt: '2026-09-01T11:00:00Z');
      await progress.noteStoryline(
        'email',
        'c1',
        state: 'done',
        storylineId: 'sl-1',
      );

      expect((await progressOf('m1'))['storyline_id'], null);
      expect((await progressOf('m2'))['storyline_id'], 'sl-1');
    });

    test('a settled row whose storyline stage was still owed completes it',
        () async {
      // The settle race: the coordinator can settle a message in the middle of
      // a sync, before the storyline work for its thread is even enqueued. The
      // stage was OWED, not answered — and refusing the stamp that follows
      // left the row stuck at `outcome = 'pending'` forever.
      await ingest('m1');
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'not_worthy',
        dropped: false,
      );
      expect((await progressOf('m1'))['storyline_state'], 'pending');

      ticks.clear();
      await progress.noteStoryline(
        'email',
        'c1',
        state: 'done',
        storylineId: 'sl-1',
      );

      final row = await progressOf('m1');
      expect(row['storyline_state'], 'done');
      expect(row['storyline_id'], 'sl-1');
      await pumpEventQueue();
      expect(ticks.map((t) => t.sourceMessageId), ['m1']);
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

    test('a judged needs-you yes is an ask nothing else here provides',
        () async {
      // No urgency, no needs_action, no deadline, no CTA — the needs-you
      // verdict is the only clause in the predicate that can be true, so this
      // is the SQL side of the same fact the coordinator's toast reads.
      await ingest('m1');
      await store.writeNeedsYouVerdict('email', 'm1',
          verdict: true, reason: 'names the owner and asks for a date');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.9);

      expect(await progress.sweepSettled(threshold: 0.5), 1);
      expect((await progressOf('m1'))['needs_you'], 1);
    });

    test('a judged needs-you no leaves the message needing nobody', () async {
      await ingest('m1');
      await store.writeNeedsYouVerdict('email', 'm1',
          verdict: false, reason: 'a status update, addressed to the team');
      await finishStages('m1');
      await store.writeAttentionScore('email', 'c1', 0.9);

      expect(await progress.sweepSettled(threshold: 0.5), 1);
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

  // The settle race's cleanup crew. A row that settled mid-sync carries a
  // `pending` storyline stage and an `outcome` that will never close behind
  // it; this pass hands the thread back to the queue, and the loosened
  // `writeStorylineProgress` guard is what lets the answer land.
  group('reviving an owed storyline stage', () {
    /// The stuck shape exactly: settled, storyline never stamped, outcome
    /// still open, not dropped.
    Future<void> seedStuck({
      String id = 'm1',
      String conversationKey = 'c1',
    }) async {
      await ingest(id, conversationKey: conversationKey);
      await progress.noteSettled(
        'email',
        id,
        needsYou: false,
        reason: 'not_worthy',
        dropped: false,
      );
    }

    Future<List<String>> storylineWork() async => [
          for (final row in await db
              .customSelect(
                "SELECT entity_id FROM work_items WHERE task_kind = 'storyline'"
                ' AND status = ? ORDER BY entity_id',
                variables: [Variable('pending')],
              )
              .get())
            row.data['entity_id'] as String,
        ];

    test('a row the settle race left behind gets its pass back', () async {
      await seedStuck();
      expect((await progressOf('m1'))['outcome'], 'pending');

      expect(
        await store.reviveOwedStorylineStages(sources: const ['email']),
        1,
      );
      expect(await storylineWork(), ['c1']);
    });

    test('and one pass is all it takes — the second call finds nothing',
        () async {
      await seedStuck();
      await store.reviveOwedStorylineStages(sources: const ['email']);

      // The work row it just wrote is `pending`, which is exactly what the
      // NOT EXISTS refuses to queue over.
      expect(
        await store.reviveOwedStorylineStages(sources: const ['email']),
        0,
      );

      // And once the pass lands, the row is no longer stuck at all.
      await store.writeWork('storyline', 'email', 'c1', status: 'done');
      await progress.noteStoryline('email', 'c1', state: 'done');
      expect(
        await store.reviveOwedStorylineStages(sources: const ['email']),
        0,
      );
      expect((await progressOf('m1'))['storyline_state'], 'done');
    });

    test('a gate cascade is not a stuck row and stays dropped', () async {
      // A gated message also carries `settle_state = 'done'`, written by the
      // cascade rather than by the coordinator. Queueing the model for mail
      // the gate threw out is what the gate exists to prevent.
      await ingest('m1', triageStatus: 'skipped', gateReason: 'newsletter');
      expect((await progressOf('m1'))['dropped'], 1);

      expect(
        await store.reviveOwedStorylineStages(sources: const ['email']),
        0,
      );
      expect(await storylineWork(), isEmpty);
    });

    test('a conversation the queue is already going to reach is left alone',
        () async {
      await seedStuck();
      await store.enqueueWork('storyline', 'email', 'c1');

      expect(
        await store.reviveOwedStorylineStages(sources: const ['email']),
        0,
      );
    });

    test('a row still being worked is not stuck', () async {
      await ingest('m1');

      expect(
        await store.reviveOwedStorylineStages(sources: const ['email']),
        0,
      );
    });
  });

  // The chip that has to follow the verdict when the verdict moves. Nothing
  // else in the app reconciles `message_progress.needs_you` with
  // `messages.needs_you_verdict`, so a snapshot taken at settle would go on
  // showing an answer the pipeline has since changed its mind about.
  group('the needs-you snapshot', () {
    Future<void> seedSettled({required bool needsYou}) async {
      await ingest('m1');
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: needsYou,
        reason: 'settled',
        dropped: false,
      );
    }

    test('a settled row follows the value it is handed, both ways', () async {
      await seedSettled(needsYou: true);

      expect(
        await store.refreshNeedsYouFlag('email', 'm1', needsYou: false),
        isNotNull,
      );
      expect((await progressOf('m1'))['needs_you'], 0);

      expect(
        await store.refreshNeedsYouFlag('email', 'm1', needsYou: true),
        isNotNull,
      );
      expect((await progressOf('m1'))['needs_you'], 1);
    });

    test('the same value writes nothing and reports nothing', () async {
      // The RETURNING is what the recorder ticks on, so a re-verdict that
      // returned the same answer must not announce itself.
      await seedSettled(needsYou: true);

      expect(
        await store.refreshNeedsYouFlag('email', 'm1', needsYou: true),
        isNull,
      );
    });

    test('an unsettled row is left to take its own snapshot', () async {
      await ingest('m1');

      expect(
        await store.refreshNeedsYouFlag('email', 'm1', needsYou: true),
        isNull,
      );
      expect((await progressOf('m1'))['needs_you'], 0);
    });

    test('a dropped row is never raised', () async {
      // The feed hides dropped rows and the tile sums the column, so a chip
      // raised here would be a count nobody can click through to.
      await ingest('m1');
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'not_worthy',
        dropped: true,
      );

      expect(
        await store.refreshNeedsYouFlag('email', 'm1', needsYou: true),
        isNull,
      );
      expect((await progressOf('m1'))['needs_you'], 0);
    });
  });

  // The one-shot for rows that settled before there was a verdict column to
  // read. Everything here is a row whose snapshot says 0 while the verdict
  // beside it says 1.
  group('the needs-you backfill', () {
    Future<void> seedJudged({
      String conversationKey = 'c1',
      String? lastOutboundAt,
      String state = 'needs_reply',
      String? bucket,
      double score = 0.9,
    }) async {
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': conversationKey,
        'subject': 'Launch date',
        'state': state,
        'last_message_at': '2026-09-01T10:00:00Z',
        'last_outbound_at': lastOutboundAt,
      });
      await ingest('m1', conversationKey: conversationKey);
      await store.writeNeedsYouVerdict('email', 'm1',
          verdict: true, reason: 'names the owner');
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'not_worthy',
        dropped: false,
      );
      if (bucket != null) {
        await store.setConversationBucket('email', conversationKey,
            bucket: bucket);
      }
      await store.writeAttentionScore('email', conversationKey, score);
    }

    test('a judged yes on a live thread gains the chip, and ticks', () async {
      await seedJudged();
      ticks.clear();

      expect(await progress.backfillNeedsYou(threshold: 0.5), 1);
      expect((await progressOf('m1'))['needs_you'], 1);
      await pumpEventQueue();
      expect(ticks.single.sourceMessageId, 'm1');
      expect(ticks.single.stage, 'settle');
    });

    test('a thread the user has already answered does not', () async {
      // `notifyWorthy` has no outbound clause because the coordinator settles
      // before any reply can exist. A chip raised months later has to carry
      // the guard itself.
      await seedJudged(lastOutboundAt: '2026-09-01T12:00:00Z');

      expect(await progress.backfillNeedsYou(threshold: 0.5), 0);
      expect((await progressOf('m1'))['needs_you'], 0);
    });

    test('a thread the user marked done does not', () async {
      await seedJudged(state: 'done');

      expect(await progress.backfillNeedsYou(threshold: 0.5), 0);
    });

    test('a thread parked in Later does not', () async {
      await seedJudged(bucket: 'later');

      expect(await progress.backfillNeedsYou(threshold: 0.5), 0);
    });

    test('and neither does one under the attention floor', () async {
      await seedJudged(score: 0.2);

      expect(await progress.backfillNeedsYou(threshold: 0.5), 0);
    });

    test('a gate-dropped row keeps its drop', () async {
      await ingest('m1', triageStatus: 'skipped', gateReason: 'newsletter');
      await store.writeNeedsYouVerdict('email', 'm1',
          verdict: true, reason: 'names the owner');
      await store.writeAttentionScore('email', 'c1', 0.9);

      expect(await progress.backfillNeedsYou(threshold: 0.5), 0);
      expect((await progressOf('m1'))['needs_you'], 0);
    });
  });

  // Re-pending a retired gate's messages has to re-open their progress rows
  // too, or the settle machine reads the stale cascade as a finished pipeline.
  group('re-pending a retired gate', () {
    test('the progress row goes back with the message', () async {
      await ingest('m1', triageStatus: 'skipped', gateReason: 'teams_source');
      expect((await progressOf('m1'))['outcome'], 'dropped');

      expect(
        await store.rependGatedTriage(
          source: 'email',
          gateReason: 'teams_source',
          sinceIso: '2026-08-01T00:00:00Z',
        ),
        1,
      );

      final message = (await store.getMessageRow('email', 'm1'))!;
      expect(message['triage_status'], 'pending');
      expect(message['gate_reason'], isNull);

      final row = await progressOf('m1');
      expect(row['triage_state'], 'pending');
      expect(row['extract_state'], 'pending');
      expect(row['storyline_state'], 'pending');
      expect(row['settle_state'], 'pending');
      expect(row['dropped'], 0);
      expect(row['drop_reason'], isNull);
      expect(row['outcome'], 'pending');
    });

    test('a message another gate stopped keeps its cascade', () async {
      await ingest('m1', triageStatus: 'skipped', gateReason: 'newsletter');

      expect(
        await store.rependGatedTriage(
          source: 'email',
          gateReason: 'teams_source',
          sinceIso: '2026-08-01T00:00:00Z',
        ),
        0,
      );

      final row = await progressOf('m1');
      expect(row['triage_state'], 'skipped');
      expect(row['dropped'], 1);
      expect(row['outcome'], 'dropped');
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

  group('re-judging the recent window', () {
    /// The work rows for one kind, as `entity_id` → status.
    Future<Map<String, String>> workRows(String kind) async {
      final rows = await db
          .customSelect(
            'SELECT entity_id, status FROM work_items WHERE task_kind = ?',
            variables: [Variable(kind)],
          )
          .get();
      return {
        for (final row in rows)
          row.data['entity_id'] as String: row.data['status'] as String,
      };
    }

    test('a finished judgement inside the window goes back on the queue',
        () async {
      await ingest('m1', triageStatus: 'triaged');
      await store.enqueueWork('needs_you', 'email', 'm1');
      await store.writeWork('needs_you', 'email', 'm1', status: 'done');

      final n = await store.requeueNeedsYouRejudge(
        sinceIso: '2026-08-25T00:00:00Z',
      );

      expect(n, 1);
      expect(await workRows('needs_you'), {'m1': 'pending'});
    });

    test('and a message that was never judged gets its first row', () async {
      // `requeueWork` inserts when there is nothing to revive, which is what
      // reaches a message the first pass never got to.
      await ingest('m1', triageStatus: 'triaged');

      expect(
        await store.requeueNeedsYouRejudge(sinceIso: '2026-08-25T00:00:00Z'),
        1,
      );
      expect(await workRows('needs_you'), {'m1': 'pending'});
    });

    test('a message older than the window is left alone', () async {
      // Those rules were the rules when it landed. History, not a mistake.
      await ingest('m1',
          triageStatus: 'triaged', receivedAt: '2026-08-01T10:00:00Z');

      expect(
        await store.requeueNeedsYouRejudge(sinceIso: '2026-08-25T00:00:00Z'),
        0,
      );
      expect(await workRows('needs_you'), isEmpty);
    });

    test('a gated message is left alone unless it is a legacy chat row',
        () async {
      // The same admission the first judgement had: the pipeline threw the
      // newsletter out, and a rules edit is not a reason to pay a model for it.
      await ingest('m-gated',
          triageStatus: 'skipped', gateReason: 'newsletter');
      await ingest('m-chat',
          triageStatus: 'skipped',
          gateReason: 'teams_source',
          source: 'teams');

      expect(
        await store.requeueNeedsYouRejudge(sinceIso: '2026-08-25T00:00:00Z'),
        1,
      );
      expect(await workRows('needs_you'), {'m-chat': 'pending'});
    });

    test('the cap takes the newest and stops', () async {
      await ingest('m-old',
          triageStatus: 'triaged', receivedAt: '2026-09-01T08:00:00Z');
      await ingest('m-mid',
          triageStatus: 'triaged', receivedAt: '2026-09-01T09:00:00Z');
      await ingest('m-new',
          triageStatus: 'triaged', receivedAt: '2026-09-01T11:00:00Z');

      expect(
        await store.requeueNeedsYouRejudge(
          sinceIso: '2026-08-25T00:00:00Z',
          cap: 2,
        ),
        2,
      );
      expect(
        (await workRows('needs_you')).keys,
        unorderedEquals(['m-new', 'm-mid']),
      );
    });

    test('an item a drain is already holding keeps its claim and its place',
        () async {
      // `requeueWork` refuses to reset a `processing` row — handing an item a
      // worker holds to a second drain is worse than judging it a moment late.
      // It is still counted: it is still going to be judged.
      await ingest('m1', triageStatus: 'triaged');
      await store.enqueueWork('needs_you', 'email', 'm1');
      await store.writeWork('needs_you', 'email', 'm1', status: 'processing');

      expect(
        await store.requeueNeedsYouRejudge(sinceIso: '2026-08-25T00:00:00Z'),
        1,
      );
      expect(await workRows('needs_you'), {'m1': 'processing'});
    });

    test('the owner\'s own messages are never re-judged', () async {
      await ingest('m-out', direction: 'outbound', triageStatus: 'triaged');

      expect(
        await store.requeueNeedsYouRejudge(sinceIso: '2026-08-25T00:00:00Z'),
        0,
      );
      expect(await workRows('needs_you'), isEmpty);
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
