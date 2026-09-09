import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/models/home_sort.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The reads behind the home screen: the tiles, the feed, the live patch, and
/// the hot-storylines strip.
///
/// The paging tests are the load-bearing ones. A keyset cursor over
/// `(received_at, source_message_id)` is only correct if the second half is
/// really used, and the way to prove it is a page boundary that falls in the
/// middle of several messages sharing one timestamp — which a mail sync
/// produces routinely, because a delta page of a batch send arrives with one
/// `receivedDateTime` on every row.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One message, plus the `message_progress` row `upsertMessage` writes with
  /// it, then whatever this test wants that row to say.
  Future<void> seed(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String receivedAt = '2026-09-01T10:00:00Z',
    String? subject = 'Launch date',
    String outcome = 'done',
    bool dropped = false,
    String? dropReason,
    bool needsYou = false,
    String? urgency,
    String? storylineId,
    String triageState = 'done',
    String extractState = 'done',
    String storylineState = 'done',
    bool hasAttachments = false,
    String? updatedAt,
    String? summary,
    String? ctaText,
    // The THREAD's live state and score, which is what the rail's Needs You
    // rule reads — `message_progress.needs_you` is the settle pass's snapshot
    // of one message and the rule deliberately ignores it.
    String? threadState,
    double? attentionScore,
    String? bucket,
    // Triaged by default: `work_open` reads a pending triage as work in
    // flight (the queue claims `messages.triage_status` directly, there is
    // no work row), so a seed that left the column at its default would make
    // every row here look busy.
    //
    // These two ARE `MessageStore.keptMessageSql`, which is what the Needs
    // You filter and tile narrow on — a fact about the message the gate
    // judged, not about the progress row that recorded the judgement.
    String triageStatus = 'triaged',
    String? gateReason,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': receivedAt,
      'created_at': receivedAt,
      'updated_at': receivedAt,
      'has_attachments': hasAttachments ? 1 : 0,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
    // Written straight onto the row: `upsertMessage` never touches the triage
    // columns — that belongs to `writeTriage`, which wants a whole
    // `TriageResult` to say one sentence.
    if (summary != null) {
      await db.customUpdate(
        'UPDATE messages SET summary = ? '
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable(summary), Variable(source), Variable(id)],
      );
    }
    // The ask is a fact about the THREAD, so it is written on the thread row
    // rather than on the message — which is the whole reason the feed joins
    // `conversations` at all.
    if (ctaText != null || threadState != null) {
      await store.upsertConversation({
        'source': source,
        'conversation_key': conversationKey,
        'subject': subject,
        'cta_text': ctaText,
        // The column's own default, so a seed that only wanted an ask still
        // reads as a closed thread rather than as one owing a reply.
        'state': threadState ?? 'done',
      });
    }
    if (attentionScore != null) {
      await store.writeAttentionScore(source, conversationKey, attentionScore);
    }
    if (bucket != null) {
      await store.setConversationBucket(
        source,
        conversationKey,
        bucket: bucket,
        reason: 'sweep',
      );
    }
    await db.customUpdate(
      'UPDATE message_progress SET outcome = ?, dropped = ?, drop_reason = ?, '
      'needs_you = ?, urgency = ?, storyline_id = ?, triage_state = ?, '
      "extract_state = ?, storyline_state = ?, settle_state = 'done' "
      'WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable(outcome),
        Variable(dropped ? 1 : 0),
        Variable(dropReason),
        Variable(needsYou ? 1 : 0),
        Variable(urgency),
        Variable(storylineId),
        Variable(triageState),
        Variable(extractState),
        Variable(storylineState),
        Variable(source),
        Variable(id),
      ],
    );
    // Separate, and only when asked: `upsertMessage` stamps the progress row's
    // `updated_at` with wall-clock time, which is exactly the column the
    // stalled tests need to pin.
    if (updatedAt != null) {
      await db.customUpdate(
        'UPDATE message_progress SET updated_at = ? '
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable(updatedAt), Variable(source), Variable(id)],
      );
    }
  }

  Future<void> seedStoryline(
    String id, {
    String title = 'Website redesign',
    String status = 'active',
  }) =>
      store.insertStoryline(
        id: id,
        title: title,
        status: status,
        createdBy: 'auto',
      );

  /// The cutoff the stalled count is measured against: fifteen minutes before
  /// the fixture's "now" of 10:00. Rows the tests do not stamp carry
  /// wall-clock `updated_at`, which is far later than this, so nothing counts
  /// as stalled unless a test says so.
  const stalledCutoff = '2026-09-01T09:45:00Z';

  /// One row that matches [filter] and one that does not, so a filter that
  /// let everything through would fail as loudly as one that let nothing.
  ///
  /// Shared by the page read's loop and the live patch's, because the whole
  /// point of the patch's flag is that it answers the page read's question.
  Future<void> seedPair(HomeFilter filter) async {
    switch (filter) {
      case HomeFilter.fromOthers:
        await seed('yes');
        await seed('no', dropped: true, conversationKey: 'c2');
      case HomeFilter.needsYou:
        // The THREAD owes a reply, which is the rail's rule; the other
        // thread carries the message-level snapshot and nothing else, so a
        // filter still reading that column would fail here.
        await seed('yes', threadState: 'needs_reply');
        await seed('no', needsYou: true, conversationKey: 'c2');
      case HomeFilter.urgent:
        await seed('yes', urgency: 'high');
        await seed('no', urgency: 'normal', conversationKey: 'c2');
      case HomeFilter.inFlight:
        await seed('yes', outcome: 'pending');
        await seed('no', conversationKey: 'c2');
      case HomeFilter.errors:
        await seed('yes', storylineState: 'error');
        await seed('no', conversationKey: 'c2');
      case HomeFilter.dropped:
        await seed('yes', dropped: true);
        await seed('no', conversationKey: 'c2');
      case HomeFilter.processed:
        await seed('yes');
        await seed('no', outcome: 'pending', conversationKey: 'c2');
    }
  }

  group('the tiles', () {
    test('every number comes off the same read', () async {
      await seed('m1', urgency: 'high', threadState: 'needs_reply');
      await seed('m2', source: 'teams', conversationKey: 'chat-1');
      await seed('m3', dropped: true, dropReason: 'newsletter');
      await seed('m4', outcome: 'pending');
      await seed('m5', extractState: 'error');
      await seed('m6', storylineId: 'sl-1');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.total, 6);
      expect(metrics.emails, 5);
      expect(metrics.teams, 1);
      expect(metrics.urgent, 1);
      expect(metrics.dropped, 1);
      // The thread owing a reply, counted once — the rail's rule, not the
      // message-level snapshot.
      expect(metrics.needsYou, 1);
      expect(metrics.storylined, 1);
      expect(metrics.inFlight, 1);
      expect(metrics.errored, 1);
    });

    test('a message counts as urgent on either of the two loud words',
        () async {
      await seed('m1', urgency: 'urgent');
      await seed('m2', urgency: 'high');
      await seed('m3', urgency: 'normal');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.urgent, 2);
    });

    test('the Urgent tile leaves out a dropped row, the way its filter does',
        () async {
      // Urgency is triage's word about the message and a later drop never
      // rewrites it, so a `not_worthy` verdict at the settle pass leaves a
      // `high` sitting on a row the Urgent filter refuses to show.
      await seed('kept', urgency: 'high');
      await seed(
        'gone',
        urgency: 'high',
        dropped: true,
        dropReason: 'not_worthy',
        conversationKey: 'c2',
      );

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );
      final rows = await store.pageHomeFeed(
        filter: HomeFilter.urgent,
        sinceIso: '2026-09-01T00:00:00Z',
      );

      expect(metrics.urgent, 1);
      expect(
        rows.map((r) => r.sourceMessageId),
        ['kept'],
      );
      expect(
        metrics.urgent,
        rows.length,
        reason: 'the tile is a promise the filter keeps',
      );
    });

    test('a message errored in two stages is still one message', () async {
      await seed('m1', triageState: 'error', extractState: 'error');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.errored, 1);
    });

    test('anything older than the window is not in it', () async {
      await seed('old', receivedAt: '2026-08-20T10:00:00Z');
      await seed('new');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.total, 1);
    });

    test('needs_you ignores the window; the other numbers do not', () async {
      // A thread owing a reply since well before the window opened. It is a
      // pile to burn down, and work owed longest is exactly what a week hides.
      await seed(
        'ancient',
        receivedAt: '2026-08-20T10:00:00Z',
        threadState: 'needs_reply',
      );

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.needsYou, 1);
      // The same row, under the same read, counted by every windowed column as
      // nothing at all — which is the whole point of the scalar subquery.
      expect(metrics.emails, 0);
      expect(metrics.total, 0);
    });

    test('an empty mailbox reads as zeros rather than nulls', () async {
      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.total, 0);
      expect(metrics.dropped, 0);
      expect(metrics.needsYou, 0);
      expect(metrics.stalled, 0);
    });

    test('stalled counts a pending row nobody is working on', () async {
      await seed('m1', outcome: 'pending', updatedAt: '2026-09-01T09:40:00Z');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.inFlight, 1);
      expect(metrics.stalled, 1);
    });

    test('a row with work in flight is slow, not stalled', () async {
      await seed('m1', outcome: 'pending', updatedAt: '2026-09-01T09:40:00Z');
      await store.enqueueWork('extract', 'email', 'm1');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.inFlight, 1);
      expect(metrics.stalled, 0);
    });

    test('a finished row cannot be stalled, however old it is', () async {
      await seed('m1', updatedAt: '2026-08-01T09:40:00Z');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.stalled, 0);
    });

    test('a row that moved inside the window is not stalled yet', () async {
      await seed('m1', outcome: 'pending', updatedAt: '2026-09-01T09:50:00Z');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.inFlight, 1);
      expect(metrics.stalled, 0);
    });
  });

  group('the feed', () {
    test('the newest message is first', () async {
      await seed('early', receivedAt: '2026-09-01T09:00:00Z');
      await seed('late', receivedAt: '2026-09-01T11:00:00Z');

      final page = await store.pageHomeFeed();

      expect(page.map((r) => r.sourceMessageId), ['late', 'early']);
    });

    test('paging over a batch that all landed at once loses nothing',
        () async {
      // Three of the seven share `t2`, so every page boundary that can fall
      // inside a tie will fall inside one at some limit — which is exactly the
      // case a cursor of `received_at` alone gets wrong, by re-reading the tie
      // forever or by stepping over the rest of it.
      await seed('a', receivedAt: '2026-09-01T13:00:00Z');
      await seed('b', receivedAt: '2026-09-01T12:00:00Z');
      await seed('c', receivedAt: '2026-09-01T12:00:00Z');
      await seed('d', receivedAt: '2026-09-01T12:00:00Z');
      await seed('e', receivedAt: '2026-09-01T11:00:00Z');
      await seed('f', receivedAt: '2026-09-01T10:00:00Z');
      await seed('g', receivedAt: '2026-09-01T09:00:00Z');

      for (final limit in [1, 2, 3, 5]) {
        final walked = <String>[];
        String? cursorAt;
        String? cursorId;
        while (true) {
          final page = await store.pageHomeFeed(
            beforeReceivedAt: cursorAt,
            beforeSourceMessageId: cursorId,
            limit: limit,
          );
          if (page.isEmpty) break;
          walked.addAll(page.map((r) => r.sourceMessageId));
          cursorAt = page.last.receivedAt;
          cursorId = page.last.sourceMessageId;
        }
        // No skip, no duplicate, and the tie broken the same way every time.
        expect(walked, ['a', 'd', 'c', 'b', 'e', 'f', 'g'],
            reason: 'walking in pages of $limit');
      }
    });

    test('dropped messages stay out until they are asked for', () async {
      await seed('kept', receivedAt: '2026-09-01T11:00:00Z');
      await seed(
        'gone',
        receivedAt: '2026-09-01T10:00:00Z',
        dropped: true,
        dropReason: 'newsletter',
      );

      expect(
        (await store.pageHomeFeed()).map((r) => r.sourceMessageId),
        ['kept'],
      );

      // `processed` is the filter that shows both piles: everything the app
      // has finished with, whichever side of the gate it ended on.
      final all = await store.pageHomeFeed(filter: HomeFilter.processed);
      expect(all.map((r) => r.sourceMessageId), ['kept', 'gone']);
      expect(all.last.dropped, true);
      expect(all.last.dropReason, 'newsletter');
    });

    test('the cursor keeps hiding dropped rows on the second page', () async {
      await seed('m1', receivedAt: '2026-09-01T13:00:00Z');
      await seed('m2', receivedAt: '2026-09-01T12:00:00Z', dropped: true);
      await seed('m3', receivedAt: '2026-09-01T11:00:00Z');

      final first = await store.pageHomeFeed(limit: 1);
      final second = await store.pageHomeFeed(
        beforeReceivedAt: first.last.receivedAt,
        beforeSourceMessageId: first.last.sourceMessageId,
        limit: 5,
      );

      expect(second.map((r) => r.sourceMessageId), ['m3']);
    });

    test('the dropped filter answers with that pile, newest first', () async {
      await seed('kept', receivedAt: '2026-09-01T13:00:00Z');
      await seed(
        'older',
        receivedAt: '2026-09-01T11:00:00Z',
        dropped: true,
        dropReason: 'newsletter',
      );
      await seed(
        'newer',
        receivedAt: '2026-09-01T12:00:00Z',
        dropped: true,
        dropReason: 'fyi',
      );

      final pile = await store.pageHomeFeed(filter: HomeFilter.dropped);

      expect(pile.map((r) => r.sourceMessageId), ['newer', 'older']);
      expect(pile.map((r) => r.dropReason), ['fyi', 'newsletter']);
    });

    test('the cursor walks the dropped pile without skipping or repeating',
        () async {
      // One timestamp across the page boundary, which is where a cursor that
      // only compared time would show a row twice or lose one.
      await seed('d1', receivedAt: '2026-09-01T12:00:00Z', dropped: true);
      await seed('d2', receivedAt: '2026-09-01T12:00:00Z', dropped: true);
      await seed('live', receivedAt: '2026-09-01T12:00:00Z');
      await seed('d3', receivedAt: '2026-09-01T11:00:00Z', dropped: true);

      final first =
          await store.pageHomeFeed(limit: 1, filter: HomeFilter.dropped);
      final second = await store.pageHomeFeed(
        beforeReceivedAt: first.last.receivedAt,
        beforeSourceMessageId: first.last.sourceMessageId,
        limit: 5,
        filter: HomeFilter.dropped,
      );

      expect(first.map((r) => r.sourceMessageId), ['d2']);
      expect(second.map((r) => r.sourceMessageId), ['d1', 'd3']);
    });

    test('the two piles never overlap, whichever end is asked for', () async {
      await seed('live', receivedAt: '2026-09-01T13:00:00Z');
      await seed('gone', receivedAt: '2026-09-01T12:00:00Z', dropped: true);

      expect(
        (await store.pageHomeFeed(filter: HomeFilter.dropped))
            .map((r) => r.sourceMessageId),
        ['gone'],
      );
      expect(
        (await store.pageHomeFeed()).map((r) => r.sourceMessageId),
        ['live'],
      );
    });

    test('a row carries the storyline it was filed under, by name', () async {
      await seedStoryline('sl-1');
      await seed('m1', storylineId: 'sl-1');
      await seed('m2', receivedAt: '2026-09-01T09:00:00Z');

      final page = await store.pageHomeFeed();

      expect(page.first.storylineTitle, 'Website redesign');
      expect(page.last.storylineId, null);
      expect(page.last.storylineTitle, null);
    });

    test('history keeps its label after the storyline is dismissed', () async {
      await seedStoryline('sl-1', status: 'dismissed');
      await seed('m1', storylineId: 'sl-1');

      // The row records what the app filed this message under at the time.
      expect((await store.pageHomeFeed()).single.storylineTitle,
          'Website redesign');
    });

    test('a connector nobody asked about is not in the feed', () async {
      await seed('mail', receivedAt: '2026-09-01T11:00:00Z');
      await seed('chat', source: 'teams', conversationKey: 'chat-1');

      final page = await store.pageHomeFeed(sources: const ['teams']);

      expect(page.map((r) => r.sourceMessageId), ['chat']);
      expect(await store.pageHomeFeed(sources: const []), isEmpty);
    });

    test('the row carries what the table draws', () async {
      await seed('m1', urgency: 'urgent', needsYou: true, outcome: 'pending');

      final row = (await store.pageHomeFeed()).single;

      expect(row.source, 'email');
      expect(row.subject, 'Launch date');
      expect(row.fromName, 'Sarah');
      expect(row.needsYou, true);
      expect(row.urgency, 'urgent');
      expect(row.outcome, 'pending');
      expect(row.key, (source: 'email', id: 'm1'));
    });

    test('the bar gets the draft stage too — the fifth segment', () async {
      await seed('m1', outcome: 'pending');
      await store.writeDraftProgress('email', 'm1', state: 'running');

      expect((await store.pageHomeFeed()).single.draftState, 'running');
      // The same projection feeds the live patch read, which is the only way
      // the segment ever moves without a reload.
      final patched = await store.progressRowsFor([
        (source: 'email', id: 'm1'),
      ]);
      expect(patched.single.draftState, 'running');
    });
  });

  group('the live patch read', () {
    test('it returns exactly the messages it was asked about', () async {
      await seed('m1');
      await seed('m2', receivedAt: '2026-09-01T09:00:00Z');
      await seed('m3', receivedAt: '2026-09-01T08:00:00Z');

      final rows = await store.progressRowsFor([
        (source: 'email', id: 'm1'),
        (source: 'email', id: 'm3'),
      ]);

      expect(
        rows.map((r) => r.sourceMessageId),
        unorderedEquals(['m1', 'm3']),
      );
    });

    test('it is keyed by connector as well as by id', () async {
      await seed('m1');
      await seed('m1', source: 'teams', conversationKey: 'chat-1');

      final rows = await store.progressRowsFor([(source: 'teams', id: 'm1')]);

      expect(rows.single.source, 'teams');
      expect(rows.single.conversationKey, 'chat-1');
    });

    test('it includes dropped rows — the screen decides what to do with them',
        () async {
      await seed('m1', dropped: true, dropReason: 'not_worthy');

      // A row that has just been dropped is exactly the one the live table
      // needs back, so it can gray it out and animate it away.
      final rows = await store.progressRowsFor([(source: 'email', id: 'm1')]);

      expect(rows.single.dropped, true);
    });

    test('a key nothing is stored under costs nothing', () async {
      await seed('m1');

      final rows = await store.progressRowsFor([
        (source: 'email', id: 'm1'),
        (source: 'email', id: 'ghost'),
      ]);

      expect(rows.map((r) => r.sourceMessageId), ['m1']);
      expect(await store.progressRowsFor(const []), isEmpty);
    });

    test('a burst larger than one chunk comes back whole', () async {
      // 250 keys is two chunks of the store's 200, which is the arithmetic
      // that would silently return a partial patch if it were wrong.
      for (var i = 0; i < 250; i++) {
        await seed('m$i', receivedAt: '2026-09-01T10:00:00Z');
      }

      final rows = await store.progressRowsFor([
        for (var i = 0; i < 250; i++) (source: 'email', id: 'm$i'),
      ]);

      expect(rows, hasLength(250));
    });
  });

  group('progressPatchFor', () {
    /// The flag is the page read's own answer, so it is asked the page read's
    /// own question: for every filter, the row it keeps and the row it throws
    /// away — and BOTH rows come back either way, because a row already on the
    /// table is patched in place whatever the filter now says about it.
    for (final filter in HomeFilter.values) {
      test('${filter.name} flags what it admits and returns what it refuses',
          () async {
        await seedPair(filter);

        final patch = await store.progressPatchFor(
          [(source: 'email', id: 'yes'), (source: 'email', id: 'no')],
          filter: filter,
        );

        expect(patch, hasLength(2));
        expect(
          patch.firstWhere((e) => e.row.sourceMessageId == 'yes').admitted,
          isTrue,
        );
        expect(
          patch.firstWhere((e) => e.row.sourceMessageId == 'no').admitted,
          isFalse,
        );
      });
    }

    test('a tick for the other connector is not admitted', () async {
      // The gap this closed: the live path narrowed by nothing on sources, so
      // a chat ticked its way onto the table while the Mail chip alone was up.
      await seed('m1', source: 'teams', conversationKey: 'chat-1');

      final patch = await store.progressPatchFor(
        [(source: 'teams', id: 'm1')],
        filter: HomeFilter.fromOthers,
        sources: const ['email'],
      );

      expect(patch.single.row.source, 'teams');
      expect(patch.single.admitted, isFalse);
    });

    test('a row from before the window is not admitted', () async {
      await seed('recent', urgency: 'high');
      await seed(
        'old',
        conversationKey: 'c2',
        receivedAt: '2026-08-01T10:00:00Z',
        urgency: 'high',
      );

      final patch = await store.progressPatchFor(
        [(source: 'email', id: 'recent'), (source: 'email', id: 'old')],
        filter: HomeFilter.urgent,
        sinceIso: '2026-09-01T00:00:00Z',
      );

      expect(
        patch.firstWhere((e) => e.row.sourceMessageId == 'recent').admitted,
        isTrue,
      );
      expect(
        patch.firstWhere((e) => e.row.sourceMessageId == 'old').admitted,
        isFalse,
      );
    });

    test('under Needs You only the thread\'s newest kept message is admitted',
        () async {
      // The question one row cannot answer about itself, which is exactly why
      // it is the store's to answer.
      await seed(
        'live-old',
        conversationKey: 'live',
        receivedAt: '2026-09-01T09:00:00Z',
        threadState: 'needs_reply',
      );
      await seed(
        'live-new',
        conversationKey: 'live',
        receivedAt: '2026-09-01T11:00:00Z',
        threadState: 'needs_reply',
      );

      final patch = await store.progressPatchFor(
        [
          (source: 'email', id: 'live-old'),
          (source: 'email', id: 'live-new'),
        ],
        filter: HomeFilter.needsYou,
      );

      expect(
        patch.firstWhere((e) => e.row.sourceMessageId == 'live-new').admitted,
        isTrue,
      );
      expect(
        patch.firstWhere((e) => e.row.sourceMessageId == 'live-old').admitted,
        isFalse,
      );
    });

    test('no chips up admits nothing and still hands back the rows', () async {
      await seed('m1');

      final patch = await store.progressPatchFor(
        [(source: 'email', id: 'm1')],
        filter: HomeFilter.fromOthers,
        sources: const [],
      );

      // Not an empty result: the table's own rows still have to be patched in
      // place, and a read that returned nothing would freeze them.
      expect(patch, hasLength(1));
      expect(patch.single.admitted, isFalse);
    });

    test('a burst larger than one chunk comes back whole', () async {
      // The flag rides on every chunk's SQL, so the arguments have to bind the
      // same way 250 keys in as they do 200.
      for (var i = 0; i < 250; i++) {
        await seed('m$i', conversationKey: 'c$i');
      }

      final patch = await store.progressPatchFor(
        [for (var i = 0; i < 250; i++) (source: 'email', id: 'm$i')],
        filter: HomeFilter.fromOthers,
      );

      expect(patch, hasLength(250));
      expect(patch.every((e) => e.admitted), isTrue);
    });

    test('an empty key list costs nothing', () async {
      expect(
        await store.progressPatchFor(
          const [],
          filter: HomeFilter.fromOthers,
        ),
        isEmpty,
      );
    });
  });

  group('the reasons ride on every row', () {
    /// One message carrying every explanation the pipeline can record, so the
    /// four readers can be asked the same question.
    Future<void> seedExplained() async {
      await seed('m1', storylineId: 'sl-1');
      await store.writeNeedsYouVerdict(
        'email',
        'm1',
        verdict: true,
        reason: 'asks for the DPA by Friday',
      );
      await db.customUpdate(
        "UPDATE messages SET gate_reason = 'addressed_me' "
        'WHERE source = ? AND source_message_id = ?',
        variables: [Variable('email'), Variable('m1')],
      );
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: 'later',
        reason: 'low_value',
      );
      await store.writeAttentionScore('email', 'c1', 0.42);
      await seedStoryline('sl-1');
      await store.addStorylineMember(
        'sl-1',
        'email',
        'c1',
        addedBy: 'auto',
        evidence: 'Same renewal thread',
      );
    }

    void expectExplained(HomeFeedRow row) {
      expect(row.needsYouVerdict, true);
      expect(row.needsYouReason, 'asks for the DPA by Friday');
      expect(row.gateReason, 'addressed_me');
      expect(row.bucket, 'later');
      expect(row.bucketReason, 'low_value');
      expect(row.attentionScore, closeTo(0.42, 0.0001));
      expect(row.storylineEvidence, 'Same renewal thread');
      expect(row.storylineAddedBy, 'auto');
      expect(row.updatedAt, isNotEmpty);
    }

    // Four readers, one projection: a column present on one path and absent
    // on another is a row that explains itself in the feed and goes silent in
    // search, which is worse than never explaining itself at all.
    test('the paging read carries them', () async {
      await seedExplained();

      expectExplained((await store.pageHomeFeed()).single);
    });

    test('the live patch read carries them', () async {
      await seedExplained();

      expectExplained(
        (await store.progressRowsFor([(source: 'email', id: 'm1')])).single,
      );
    });

    test('the keyword search carries them', () async {
      await seedExplained();

      expectExplained((await store.keywordSearchMessages('Launch'))!.single.row);
    });

    test('a message nothing has judged reads null rather than false',
        () async {
      await seed('m1');

      final row = (await store.pageHomeFeed()).single;

      // Null and false are different answers — "nobody has looked" sends a
      // reader somewhere else entirely from "we looked and it is fine".
      expect(row.needsYouVerdict, isNull);
      expect(row.needsYouReason, isNull);
      expect(row.bucket, isNull);
      expect(row.attentionScore, isNull);
      expect(row.storylineEvidence, isNull);
      expect(row.workOpen, false);
    });
  });

  group('the storyline a row is really filed in', () {
    test('falls back to thread membership when the pointer is null', () async {
      await seedStoryline('sl-1');
      await seed('m1');
      await store.addStorylineMember(
        'sl-1',
        'email',
        'c1',
        addedBy: 'user',
        evidence: 'Filed by hand',
      );

      final row = (await store.pageHomeFeed()).single;

      expect(row.storylineId, 'sl-1');
      expect(row.storylineTitle, 'Website redesign');
      expect(row.storylineEvidence, 'Filed by hand');
      expect(row.storylineAddedBy, 'user');
    });

    test('reads the newest membership, and still returns one row', () async {
      await seedStoryline('sl-1', title: 'Website redesign');
      await seedStoryline('sl-2', title: 'Tahoe trip');
      await seed('m1');
      // Both memberships are written directly so their stamps are the test's
      // rather than the wall clock's — `addStorylineMember` stamps `now`, and
      // two calls a millisecond apart would not settle "newer" reliably.
      for (final (id, at) in const [
        ('sl-1', '2026-09-01T10:00:00Z'),
        ('sl-2', '2026-09-02T10:00:00Z'),
      ]) {
        await db.customUpdate(
          'INSERT INTO storyline_members '
          '(storyline_id, source, conversation_key, added_by, evidence, '
          'added_at) VALUES (?, ?, ?, ?, ?, ?)',
          variables: [
            Variable(id),
            Variable('email'),
            Variable('c1'),
            Variable('auto'),
            Variable('joined $id'),
            Variable(at),
          ],
        );
      }

      final page = await store.pageHomeFeed();

      // One row, not two: the memberships are subqueries precisely so a
      // thread in several storylines cannot split its message across them.
      expect(page, hasLength(1));
      expect(page.single.storylineId, 'sl-2');
      expect(page.single.storylineTitle, 'Tahoe trip');
      expect(page.single.storylineEvidence, 'joined sl-2');
    });

    test('a dismissed storyline is not where a row is filed', () async {
      // Member rows survive a dismissal on purpose, so the join to a live
      // status is the only thing keeping a thrown-away suggestion off the
      // feed.
      await seedStoryline('sl-1', status: 'dismissed');
      await seed('m1');
      await store.addStorylineMember(
        'sl-1',
        'email',
        'c1',
        addedBy: 'auto',
        evidence: 'joined sl-1',
      );

      final row = (await store.pageHomeFeed()).single;

      expect(row.storylineId, isNull);
      expect(row.storylineTitle, isNull);
    });

    test('the progress pointer still wins when it is set', () async {
      await seedStoryline('sl-1', title: 'Website redesign');
      await seedStoryline('sl-2', title: 'Tahoe trip');
      await seed('m1', storylineId: 'sl-1');
      await store.addStorylineMember('sl-2', 'email', 'c1', addedBy: 'auto');

      expect((await store.pageHomeFeed()).single.storylineId, 'sl-1');
    });
  });

  group('work_open', () {
    test('reads the message, its thread, and its attachments', () async {
      await seed('m1', conversationKey: 'c1');
      await seed('m2', conversationKey: 'c2');
      await seed('m3', conversationKey: 'c3');
      await seed('m4', conversationKey: 'c4');
      await store.enqueueWork('extract', 'email', 'm1');
      // Storyline work is filed under the conversation key.
      await store.enqueueWork('storyline', 'email', 'c2');
      // And attachment work under '<message id>|<attachment id>'.
      await store.enqueueWork('attachment_text', 'email', 'm3|att-1');
      await store.enqueueWork('extract', 'email', 'm4');
      await store.writeWork('extract', 'email', 'm4', status: 'done');

      final open = {
        for (final row in await store.pageHomeFeed())
          row.sourceMessageId: row.workOpen,
      };

      expect(open, {'m1': true, 'm2': true, 'm3': true, 'm4': false});
    });

    test('a message the triage queue has not reached yet is work in flight',
        () async {
      // Triage has no work row — the queue claims `triage_status` directly —
      // so this is the arm that keeps a large drain from reading as a
      // hundred stalled rows fifteen minutes in.
      await seed('m1', conversationKey: 'c1', triageStatus: 'pending');
      await seed('m2', conversationKey: 'c2', triageStatus: 'processing');
      await seed('m3', conversationKey: 'c3', triageStatus: 'error');

      final rows = await store.pageHomeFeed();
      final open = {for (final row in rows) row.sourceMessageId: row.workOpen};
      expect(open, {'m1': true, 'm2': true, 'm3': false});
    });

    test('an untriaged row is slow, never stalled', () async {
      await seed(
        'm1',
        outcome: 'pending',
        triageState: 'pending',
        triageStatus: 'pending',
        updatedAt: '2026-09-01T09:00:00Z',
      );

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: '2026-09-01T09:45:00Z',
        threshold: 0,
      );

      expect(metrics.inFlight, 1);
      expect(metrics.stalled, 0);
    });

    test('another message whose id is a prefix of this one is not this one',
        () async {
      // The `substr` arm rather than LIKE: a Graph id can contain `_`, and the
      // prefix has to be an exact one up to the separator.
      await seed('m1', conversationKey: 'c1');
      await store.enqueueWork('attachment_text', 'email', 'm10|att-1');

      expect((await store.pageHomeFeed()).single.workOpen, false);
    });
  });

  group('the hot strip', () {
    test('the busiest storyline of the window leads', () async {
      await seedStoryline('sl-1', title: 'Website redesign');
      await seedStoryline('sl-2', title: 'Tahoe trip');
      await seed('m1', storylineId: 'sl-1');
      await seed('m2',
          storylineId: 'sl-1', receivedAt: '2026-09-01T11:00:00Z');
      await seed('m3', storylineId: 'sl-2');

      final hot = await store.hotStorylines(sinceIso: '2026-09-01T00:00:00Z');

      expect(hot.map((s) => s.id), ['sl-1', 'sl-2']);
      expect(hot.first.messageCount, 2);
      expect(hot.first.title, 'Website redesign');
      expect(hot.first.lastAt, '2026-09-01T11:00:00Z');
    });

    test('it counts the window, not the storyline', () async {
      await seedStoryline('sl-old', title: 'Long-running');
      await seedStoryline('sl-new', title: 'This morning');
      for (var i = 0; i < 5; i++) {
        await seed('old$i',
            storylineId: 'sl-old', receivedAt: '2026-08-01T10:00:00Z');
      }
      await seed('new1', storylineId: 'sl-new');
      await seed('new2',
          storylineId: 'sl-new', receivedAt: '2026-09-01T11:00:00Z');

      final hot = await store.hotStorylines(sinceIso: '2026-09-01T00:00:00Z');

      expect(hot.map((s) => s.id), ['sl-new']);
    });

    test('a strip never ranks on rows the feed is hiding', () async {
      await seedStoryline('sl-1');
      await seed('m1', storylineId: 'sl-1', dropped: true);

      expect(await store.hotStorylines(sinceIso: '2026-09-01T00:00:00Z'),
          isEmpty);
    });

    test('a dismissed storyline is not hot, however busy it was', () async {
      await seedStoryline('sl-1', status: 'dismissed');
      await seed('m1', storylineId: 'sl-1');

      expect(await store.hotStorylines(sinceIso: '2026-09-01T00:00:00Z'),
          isEmpty);
    });

    test('it is capped, busiest first', () async {
      for (var i = 0; i < 10; i++) {
        await seedStoryline('sl-$i', title: 'Storyline $i');
        // Storyline i gets i + 1 messages, so the order is unambiguous.
        for (var n = 0; n <= i; n++) {
          await seed('m-$i-$n', storylineId: 'sl-$i');
        }
      }

      final hot = await store.hotStorylines(
        sinceIso: '2026-09-01T00:00:00Z',
        limit: 3,
      );

      expect(hot.map((s) => s.id), ['sl-9', 'sl-8', 'sl-7']);
    });
  });

  group('the words the row carries', () {
    test('the summary is the message and the ask is the thread', () async {
      await seed(
        'm1',
        summary: 'Confirms the launch is on the 14th',
        ctaText: 'Send the signed order form',
      );

      final row = (await store.pageHomeFeed()).single;

      expect(row.summary, 'Confirms the launch is on the 14th');
      expect(row.ctaText, 'Send the signed order form');

      // The same projection feeds the live patch, which is the only path that
      // ever fills these in without a reload.
      final patched = await store.progressRowsFor([
        (source: 'email', id: 'm1'),
      ]);
      expect(patched.single.summary, 'Confirms the launch is on the 14th');
      expect(patched.single.ctaText, 'Send the signed order form');
    });

    test('one ask over a thread of three is still three rows', () async {
      // The join is on the conversations PRIMARY KEY, so it cannot multiply a
      // row — the thing that made the storyline memberships stay subqueries.
      await seed('m1', receivedAt: '2026-09-01T09:00:00Z');
      await seed('m2', receivedAt: '2026-09-01T10:00:00Z');
      await seed(
        'm3',
        receivedAt: '2026-09-01T11:00:00Z',
        ctaText: 'Reply with the dates',
      );

      final page = await store.pageHomeFeed();

      expect(page, hasLength(3));
      expect(
        page.map((r) => r.ctaText),
        everyElement('Reply with the dates'),
        reason: 'the ask is the thread\'s, so every row on it carries it',
      );
    });

    test('a message nobody triaged and a thread with no ask read null',
        () async {
      await seed('m1');

      final row = (await store.pageHomeFeed()).single;

      expect(row.summary, isNull);
      expect(row.ctaText, isNull);
    });
  });

  group('one filter at a time', () {
    for (final filter in HomeFilter.values) {
      test('${filter.name} keeps exactly what it names', () async {
        await seedPair(filter);

        final page = await store.pageHomeFeed(filter: filter);

        expect(page.map((r) => r.sourceMessageId), ['yes']);
      });
    }

    /// H3 as ONE loop: every tile's number is the number of rows under it.
    ///
    /// Seven tiles and seven filters is fourteen chances for a count and a
    /// list to be narrowed on different things, and the two that drifted —
    /// Urgent counting a dropped row its filter refuses, needs-you counting
    /// messages where the filter counts threads — both read fine on their own
    /// tests. This one seeds a mailbox with every awkward row in it and makes
    /// each pair answer the same question.
    ///
    /// `fromOthers` is out because it is the whole feed rather than a tile.
    test('every tile counts exactly the rows its filter shows', () async {
      const window = '2026-09-01T00:00:00Z';
      const threshold = 0.5;

      // A plain kept row, loud.
      await seed('kept', urgency: 'high');
      // Thrown out by the gate before triage ever read it.
      await seed(
        'gated',
        conversationKey: 'c-gated',
        dropped: true,
        dropReason: 'gated',
        triageStatus: 'skipped',
        gateReason: 'sender_muted',
      );
      // Dropped at the SETTLE pass, which is a verdict about a message the
      // gate kept — and still carrying the urgency triage gave it.
      await seed(
        'not-worthy',
        conversationKey: 'c-nw',
        urgency: 'high',
        dropped: true,
        dropReason: 'not_worthy',
      );
      // A thread the rail says is owed an answer.
      await seed(
        'ask',
        conversationKey: 'c-ask',
        threadState: 'needs_reply',
        attentionScore: 0.9,
      );
      // The same shape, deferred — which is the rail's first test.
      await seed(
        'later',
        conversationKey: 'c-later',
        threadState: 'needs_reply',
        attentionScore: 0.9,
        bucket: 'later',
      );
      await seed('err', conversationKey: 'c-err', storylineState: 'error');
      await seed('busy', conversationKey: 'c-busy', outcome: 'pending');

      final metrics = await store.homeMetrics(
        sinceIso: window,
        stalledBeforeIso: stalledCutoff,
        threshold: threshold,
      );

      for (final filter in HomeFilter.values) {
        if (filter == HomeFilter.fromOthers) continue;
        final rows = await store.pageHomeFeed(
          filter: filter,
          // The window a windowed tile counts over, and nothing under the two
          // that count all time — the same pairing the Inbox passes.
          sinceIso: filter.windowed ? window : null,
          threshold: threshold,
        );
        final tile = switch (filter) {
          HomeFilter.needsYou => metrics.needsYou,
          HomeFilter.urgent => metrics.urgent,
          HomeFilter.inFlight => metrics.inFlight,
          HomeFilter.errors => metrics.errored,
          HomeFilter.dropped => metrics.dropped,
          HomeFilter.processed => metrics.total - metrics.inFlight,
          HomeFilter.fromOthers => -1,
        };
        expect(
          tile,
          rows.length,
          reason: 'the ${filter.name} tile says $tile and its filter shows '
              '${rows.length}',
        );
      }

      // And the mailbox really did hold every awkward row — a mix that
      // narrowed to nothing would pass the loop above by counting zeros.
      expect(metrics.needsYou, 1);
      expect(metrics.urgent, 1);
      expect(metrics.dropped, 2);
      expect(metrics.errored, 1);
      expect(metrics.inFlight, 1);
      expect(metrics.total, 7);
    });

    test('processed counts the dropped pile too', () async {
      // The tile above it is `total − in_flight`, and a filter showing fewer
      // rows than its own tile is a tile nobody believes twice.
      await seed('kept', receivedAt: '2026-09-01T11:00:00Z');
      await seed(
        'gone',
        receivedAt: '2026-09-01T10:00:00Z',
        dropped: true,
        conversationKey: 'c2',
      );

      final page = await store.pageHomeFeed(filter: HomeFilter.processed);

      expect(page.map((r) => r.sourceMessageId), ['kept', 'gone']);
    });
  });

  group('Needs You counts threads by the rail rule', () {
    /// One live thread of three messages — two kept, one the user sent — and
    /// one closed thread that still carries an ask. The rail counts the first
    /// and not the second, and everything here is about the tile and the table
    /// agreeing with it.
    Future<void> seedTwoThreads() async {
      await seed(
        'live-old',
        conversationKey: 'live',
        receivedAt: '2026-09-01T09:00:00Z',
        threadState: 'needs_reply',
      );
      await seed(
        'live-new',
        conversationKey: 'live',
        receivedAt: '2026-09-01T11:00:00Z',
        threadState: 'needs_reply',
      );
      await seed(
        'live-sent',
        conversationKey: 'live',
        receivedAt: '2026-09-01T12:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'outbound',
        dropped: true,
        dropReason: 'outbound',
        threadState: 'needs_reply',
      );
      await seed(
        'closed',
        conversationKey: 'closed',
        receivedAt: '2026-09-01T10:00:00Z',
        ctaText: 'Send the signed order form',
      );
    }

    test('the tile counts one thread, not three messages', () async {
      await seedTwoThreads();

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      // The rail's own rule: the closed thread is out however loud its ask is,
      // and the live one is counted once however many messages hang off it.
      expect(metrics.needsYou, 1);
    });

    test('the table shows the newest KEPT message of that thread', () async {
      await seedTwoThreads();

      final page = await store.pageHomeFeed(filter: HomeFilter.needsYou);

      // Not `live-sent`: the user's own message is dropped as outbound, and a
      // thread stands for itself through the newest message the app kept.
      expect(page.map((r) => r.sourceMessageId), ['live-new']);
      expect(page.single.threadState, 'needs_reply');
    });

    test('a thread deferred to Later is out of both', () async {
      await seedTwoThreads();
      await store.setConversationBucket(
        'email',
        'live',
        bucket: 'later',
        reason: 'sweep',
      );

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.needsYou, 0);
      expect(await store.pageHomeFeed(filter: HomeFilter.needsYou), isEmpty);
    });

    test('a thread under the bar is out, and in when the bar drops', () async {
      await seedTwoThreads();
      await store.writeAttentionScore('email', 'live', 0.3);

      Future<int> counted(double threshold) async =>
          (await store.homeMetrics(
            sinceIso: '2026-09-01T00:00:00Z',
            stalledBeforeIso: stalledCutoff,
            threshold: threshold,
          ))
              .needsYou;

      Future<List<String>> listed(double threshold) async => [
            for (final row in await store.pageHomeFeed(
              filter: HomeFilter.needsYou,
              threshold: threshold,
            ))
              row.sourceMessageId,
          ];

      expect(await counted(0.5), 0);
      expect(await listed(0.5), isEmpty);
      // The same slider the rail reads: moving it has to move the tile and the
      // rows under it together, or one of the two is lying.
      expect(await counted(0.2), 1);
      expect(await listed(0.2), ['live-new']);
    });

    test('a chat born skipped under teams_source is kept by both', () async {
      // The one tolerance `MessageStore.keptMessageSql` carries: a chat
      // stored before chats were triaged is `skipped` for a pipeline that did
      // not exist yet, not for anything about the words.
      await seed(
        'chat',
        source: 'teams',
        conversationKey: 'chat-1',
        receivedAt: '2026-09-01T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'teams_source',
        threadState: 'needs_reply',
      );

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.needsYou, 1);
      expect(
        (await store.pageHomeFeed(filter: HomeFilter.needsYou))
            .map((r) => r.sourceMessageId),
        ['chat'],
      );
    });

    test('a settle-time not_worthy drop is still the thread\'s row', () async {
      // `not_worthy` is a verdict ABOUT a kept message — it lives on the
      // progress row and leaves `triage_status` alone — so the thread still
      // has a message anybody could answer.
      await seed(
        'quiet',
        conversationKey: 'live',
        receivedAt: '2026-09-01T10:00:00Z',
        dropped: true,
        dropReason: 'not_worthy',
        threadState: 'needs_reply',
      );

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.needsYou, 1);
      expect(
        (await store.pageHomeFeed(filter: HomeFilter.needsYou))
            .map((r) => r.sourceMessageId),
        ['quiet'],
      );
    });

    test('a gate-skipped message is refused by both', () async {
      await seed(
        'gated',
        conversationKey: 'live',
        receivedAt: '2026-09-01T10:00:00Z',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
        threadState: 'needs_reply',
      );

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.needsYou, 0);
      expect(await store.pageHomeFeed(filter: HomeFilter.needsYou), isEmpty);
    });

    test('a thread with no conversation row is nobody\'s to answer', () async {
      // `message_progress.needs_you` is the settle pass's snapshot of one
      // message; the rule reads the thread, and there is no thread here.
      await seed('orphan', needsYou: true);

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
      );

      expect(metrics.needsYou, 0);
      expect(await store.pageHomeFeed(filter: HomeFilter.needsYou), isEmpty);
    });
  });

  group('the window and the direction', () {
    test('sinceIso bounds the read', () async {
      await seed('inside', receivedAt: '2026-09-01T10:00:00Z');
      await seed('outside', receivedAt: '2026-08-01T10:00:00Z');

      final page = await store.pageHomeFeed(
        sinceIso: '2026-08-25T00:00:00Z',
      );

      expect(page.map((r) => r.sourceMessageId), ['inside']);
    });

    test('the window rides the cursor onto the second page', () async {
      await seed('a', receivedAt: '2026-09-03T10:00:00Z');
      await seed('b', receivedAt: '2026-09-02T10:00:00Z');
      await seed('old', receivedAt: '2026-08-01T10:00:00Z');

      final first = await store.pageHomeFeed(
        limit: 1,
        sinceIso: '2026-08-25T00:00:00Z',
      );
      final second = await store.pageHomeFeed(
        beforeReceivedAt: first.last.receivedAt,
        beforeSourceMessageId: first.last.sourceMessageId,
        limit: 5,
        sinceIso: '2026-08-25T00:00:00Z',
      );

      expect(first.map((r) => r.sourceMessageId), ['a']);
      expect(second.map((r) => r.sourceMessageId), ['b']);
    });

    test('ascending walks oldest first, and its cursor walks forward',
        () async {
      await seed('a', receivedAt: '2026-09-01T09:00:00Z');
      await seed('b', receivedAt: '2026-09-01T10:00:00Z');
      await seed('c', receivedAt: '2026-09-01T11:00:00Z');

      final first = await store.pageHomeFeed(limit: 2, ascending: true);
      final second = await store.pageHomeFeed(
        beforeReceivedAt: first.last.receivedAt,
        beforeSourceMessageId: first.last.sourceMessageId,
        limit: 2,
        ascending: true,
      );

      expect(first.map((r) => r.sourceMessageId), ['a', 'b']);
      // A `<` cursor here would hand back the page that was just read.
      expect(second.map((r) => r.sourceMessageId), ['c']);
    });
  });

  group('the connector chips reach every number', () {
    Future<void> seedBoth() async {
      await seedStoryline('sl-1');
      await seed('mail', storylineId: 'sl-1');
      await seed(
        'chat',
        source: 'teams',
        conversationKey: 'chat-1',
        storylineId: 'sl-1',
      );
    }

    test('the tiles count only what the table is showing', () async {
      await seedBoth();

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
        sources: const ['teams'],
      );

      expect(metrics.total, 1);
    });

    test('except Emails and Teams, which count their connector whatever the '
        'chips say', () async {
      await seedBoth();

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
        sources: const ['email'],
      );

      expect(
        metrics.teams,
        1,
        reason: 'those two tiles ARE the source selector, and a Teams tile '
            'reading 0 because Teams is switched off would be the control '
            'claiming there is nothing to switch to',
      );
      expect(metrics.emails, 1);
      expect(
        metrics.total,
        1,
        reason: 'every other column stays narrowed to the chips',
      );
    });

    test('the hot strip ranks only what the table is showing', () async {
      await seedBoth();

      final hot = await store.hotStorylines(
        sinceIso: '2026-09-01T00:00:00Z',
        sources: const ['teams'],
      );

      expect(hot.single.messageCount, 1);
    });

    test('no connector at all is zeros and empties, never everything',
        () async {
      await seedBoth();

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
        threshold: 0,
        sources: const [],
      );

      expect(metrics.total, 0);
      expect(
        await store.hotStorylines(
          sinceIso: '2026-09-01T00:00:00Z',
          sources: const [],
        ),
        isEmpty,
      );
      expect(await store.pageHomeFeed(sources: const []), isEmpty);
    });
  });

  group('the pipeline pulse', () {
    test('it reads the queue, the triage column and the progress rows',
        () async {
      // Inside the window: settled, dropped, and one the app says is owed.
      await seed('done1', updatedAt: '2026-09-01T09:55:00Z');
      await seed(
        'gone1',
        conversationKey: 'c2',
        dropped: true,
        outcome: 'dropped',
        updatedAt: '2026-09-01T09:56:00Z',
      );
      await seed(
        'owed1',
        conversationKey: 'c3',
        needsYou: true,
        updatedAt: '2026-09-01T09:57:00Z',
      );
      // Outside it, and still pending — so it counts as in flight and as
      // nothing else.
      await seed(
        'stale',
        conversationKey: 'c4',
        outcome: 'pending',
        updatedAt: '2026-09-01T08:00:00Z',
      );

      await store.enqueueWork('extract', 'email', 'e1');
      await store.enqueueWork('extract', 'email', 'e2');
      await store.enqueueWork('draft', 'email', 'd1');
      await store.writeWork('draft', 'email', 'd1', status: 'processing');
      await store.enqueueWork('storyline_sweep', 'email', 'c9');
      // Not pipeline work: a chore run on the user's behalf.
      await store.enqueueWork('mark_read', 'email', 'r1');
      // Outside the window as well, so the counts below are about the three
      // rows that moved inside it.
      await seed(
        'untriaged',
        conversationKey: 'c5',
        triageStatus: 'processing',
        updatedAt: '2026-09-01T08:00:00Z',
      );

      final pulse = await store.pipelinePulse(
        sinceIso: '2026-09-01T09:50:00Z',
      );

      expect(pulse.queued, {'extract': 2, 'storyline': 1});
      expect(pulse.running, {'draft': 1, 'triage': 1});
      expect(pulse.countFor('extract'), 2);
      expect(pulse.countFor('embed'), 0);
      expect(pulse.waiting, 3);
      expect(pulse.working, 2);
      expect(pulse.busy, isTrue);

      // Two: the plain one and the one the app says is owed. A needs-you
      // message is a SETTLED message — the pipeline finished with it and had
      // something to say.
      expect(pulse.recentSettled, 2);
      expect(pulse.recentDropped, 1);
      expect(pulse.recentNeedsYou, 1);
    });

    test('a quiet pipeline reads as quiet rather than as nothing', () async {
      await seed('m1', updatedAt: '2026-09-01T08:00:00Z');

      final pulse = await store.pipelinePulse(
        sinceIso: '2026-09-01T09:50:00Z',
      );

      expect(pulse.queued, isEmpty);
      expect(pulse.running, isEmpty);
      expect(pulse.busy, isFalse);
      expect(pulse.recentSettled, 0);
    });

    test('it counts only the connectors the table is showing', () async {
      await store.enqueueWork('extract', 'email', 'e1');
      await store.enqueueWork('extract', 'teams', 't1');

      final pulse = await store.pipelinePulse(
        sinceIso: '2026-09-01T09:50:00Z',
        sources: const ['teams'],
      );

      expect(pulse.queued, {'extract': 1});
      expect(
        await store.pipelinePulse(
          sinceIso: '2026-09-01T09:50:00Z',
          sources: const [],
        ),
        isA<PipelinePulse>().having((p) => p.busy, 'busy', isFalse),
      );
    });
  });

  group('has_attachments rides the shared projection', () {
    test('a feed row says whether its message carried anything', () async {
      await seed('plain');
      await seed('attached', receivedAt: '2026-09-02T10:00:00Z', hasAttachments: true);

      final rows = await store.pageHomeFeed();

      // The column is on `_homeFeedColumns`, which every read of this shape
      // shares — so `has:file` can be answered off a hit without a second
      // query per row.
      expect(
        {for (final row in rows) row.sourceMessageId: row.hasAttachments},
        {'attached': true, 'plain': false},
      );
    });
  });
}
