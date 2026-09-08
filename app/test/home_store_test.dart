import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
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
    String? updatedAt,
    // Triaged by default: `work_open` reads a pending triage as work in
    // flight (the queue claims `messages.triage_status` directly, there is
    // no work row), so a seed that left the column at its default would make
    // every row here look busy.
    String triageStatus = 'triaged',
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
      'triage_status': triageStatus,
    });
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

  group('the tiles', () {
    test('every number comes off the same window', () async {
      await seed('m1', urgency: 'high', needsYou: true);
      await seed('m2', source: 'teams', conversationKey: 'chat-1');
      await seed('m3', dropped: true, dropReason: 'newsletter');
      await seed('m4', outcome: 'pending');
      await seed('m5', extractState: 'error');
      await seed('m6', storylineId: 'sl-1');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
      );

      expect(metrics.total, 6);
      expect(metrics.emails, 5);
      expect(metrics.teams, 1);
      expect(metrics.urgent, 1);
      expect(metrics.dropped, 1);
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
      );

      expect(metrics.urgent, 2);
    });

    test('a message errored in two stages is still one message', () async {
      await seed('m1', triageState: 'error', extractState: 'error');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
      );

      expect(metrics.errored, 1);
    });

    test('anything older than the window is not in it', () async {
      await seed('old', receivedAt: '2026-08-20T10:00:00Z');
      await seed('new');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
      );

      expect(metrics.total, 1);
    });

    test('an empty mailbox reads as zeros rather than nulls', () async {
      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
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
      );

      expect(metrics.inFlight, 1);
      expect(metrics.stalled, 0);
    });

    test('a finished row cannot be stalled, however old it is', () async {
      await seed('m1', updatedAt: '2026-08-01T09:40:00Z');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
      );

      expect(metrics.stalled, 0);
    });

    test('a row that moved inside the window is not stalled yet', () async {
      await seed('m1', outcome: 'pending', updatedAt: '2026-09-01T09:50:00Z');

      final metrics = await store.homeMetrics(
        sinceIso: '2026-09-01T00:00:00Z',
        stalledBeforeIso: stalledCutoff,
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

      final all = await store.pageHomeFeed(includeDropped: true);
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

    test('onlyDropped answers with the filtered pile, newest first', () async {
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

      final pile = await store.pageHomeFeed(onlyDropped: true);

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

      final first = await store.pageHomeFeed(limit: 1, onlyDropped: true);
      final second = await store.pageHomeFeed(
        beforeReceivedAt: first.last.receivedAt,
        beforeSourceMessageId: first.last.sourceMessageId,
        limit: 5,
        onlyDropped: true,
      );

      expect(first.map((r) => r.sourceMessageId), ['d2']);
      expect(second.map((r) => r.sourceMessageId), ['d1', 'd3']);
    });

    test('the two piles never overlap, whichever end is asked for', () async {
      await seed('live', receivedAt: '2026-09-01T13:00:00Z');
      await seed('gone', receivedAt: '2026-09-01T12:00:00Z', dropped: true);

      expect(
        (await store.pageHomeFeed(onlyDropped: true))
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

    test('the text search carries them', () async {
      await seedExplained();

      expectExplained((await store.textSearchMessages('Launch')).single);
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
}
