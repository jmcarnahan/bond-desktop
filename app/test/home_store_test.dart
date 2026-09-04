import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
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

  group('the tiles', () {
    test('every number comes off the same window', () async {
      await seed('m1', urgency: 'high', needsYou: true);
      await seed('m2', source: 'teams', conversationKey: 'chat-1');
      await seed('m3', dropped: true, dropReason: 'newsletter');
      await seed('m4', outcome: 'pending');
      await seed('m5', extractState: 'error');
      await seed('m6', storylineId: 'sl-1');

      final metrics =
          await store.homeMetrics(sinceIso: '2026-09-01T00:00:00Z');

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

      final metrics =
          await store.homeMetrics(sinceIso: '2026-09-01T00:00:00Z');

      expect(metrics.urgent, 2);
    });

    test('a message errored in two stages is still one message', () async {
      await seed('m1', triageState: 'error', extractState: 'error');

      final metrics =
          await store.homeMetrics(sinceIso: '2026-09-01T00:00:00Z');

      expect(metrics.errored, 1);
    });

    test('anything older than the window is not in it', () async {
      await seed('old', receivedAt: '2026-08-20T10:00:00Z');
      await seed('new');

      final metrics =
          await store.homeMetrics(sinceIso: '2026-09-01T00:00:00Z');

      expect(metrics.total, 1);
    });

    test('an empty mailbox reads as zeros rather than nulls', () async {
      final metrics =
          await store.homeMetrics(sinceIso: '2026-09-01T00:00:00Z');

      expect(metrics.total, 0);
      expect(metrics.dropped, 0);
      expect(metrics.needsYou, 0);
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
