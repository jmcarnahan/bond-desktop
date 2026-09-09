import 'dart:async';

// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/models/home_sort.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/services/message_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The home feed's paging, against a real database.
///
/// The walk back through history is the part worth pinning: it is a keyset
/// cursor over a two-column key, and the failure it exists to rule out — a row
/// skipped or shown twice where several messages share a timestamp across a
/// page boundary — is invisible until someone scrolls.

/// A store that can be made slow or made to fail, so the notifier's two guards
/// can be exercised. Everything it does not intercept is the real store's.
class _FlakyStore extends MessageStore {
  _FlakyStore(super.db);

  int pageCalls = 0;
  bool failNextPage = false;

  /// What the last read actually asked for. The notifier's whole job here is
  /// turning its state into these arguments, and a test that only looked at
  /// the rows could not tell a threshold that was passed from one that was
  /// not.
  HomeFilter? lastFilter;
  String? lastSinceIso;
  bool? lastAscending;
  double? lastThreshold;
  List<String>? lastSources;

  /// Held open, the read never returns — which is how a second [loadMore] can
  /// arrive while the first is still in flight.
  Completer<void>? gate;

  @override
  Future<List<HomeFeedRow>> pageHomeFeed({
    String? beforeReceivedAt,
    String? beforeSourceMessageId,
    int limit = 50,
    HomeFilter filter = HomeFilter.fromOthers,
    String? sinceIso,
    bool ascending = false,
    double threshold = 0,
    List<String> sources = const ['email', 'teams'],
  }) async {
    pageCalls++;
    lastFilter = filter;
    lastSinceIso = sinceIso;
    lastAscending = ascending;
    lastThreshold = threshold;
    lastSources = sources;
    final held = gate;
    if (held != null) await held.future;
    if (failNextPage) {
      failNextPage = false;
      throw StateError('the local feed is unreadable');
    }
    return super.pageHomeFeed(
      beforeReceivedAt: beforeReceivedAt,
      beforeSourceMessageId: beforeSourceMessageId,
      limit: limit,
      filter: filter,
      sinceIso: sinceIso,
      ascending: ascending,
      threshold: threshold,
      sources: sources,
    );
  }
}

void main() {
  late BondDatabase db;
  late _FlakyStore store;

  setUp(() {
    db = testDb();
    store = _FlakyStore(db);
  });

  tearDown(() => db.close());

  /// [id] doubles as the tie-break key, so it is fixed width: the cursor
  /// compares it as text.
  Future<void> seed(
    String id, {
    required String receivedAt,
    String source = 'email',
    String? gateReason,
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': 'c-$id',
        'direction': 'in',
        'subject': 'Subject $id',
        'from_name': 'Sender $id',
        'received_at': receivedAt,
        // A gate skip with a reason is what lands a row dropped at ingest.
        if (gateReason != null) 'triage_status': 'skipped',
        'gate_reason': ?gateReason,
      });

  /// Sixty messages, newest first, with a run of them sharing one timestamp
  /// ACROSS the first page's boundary — the shape a keyset cursor gets wrong.
  Future<void> seedSixty() async {
    for (var i = 0; i < 60; i++) {
      final tied = i >= 46 && i <= 53;
      final minute = (tied ? 46 : i).toString().padLeft(2, '0');
      await seed(
        'm${i.toString().padLeft(2, '0')}',
        receivedAt: '2026-09-03T09:$minute:00Z',
      );
    }
  }

  /// The store's own ordering, as a string, so a page walk can be compared
  /// against the whole table.
  List<String> idsOf(List<HomeFeedRow> rows) =>
      [for (final row in rows) row.sourceMessageId];

  group('load', () {
    test('reads the newest page, dropped rows left out', () async {
      await seed('m1', receivedAt: '2026-09-03T09:00:00Z');
      await seed(
        'm2',
        receivedAt: '2026-09-03T10:00:00Z',
        gateReason: 'newsletter',
      );
      await seed('m3', receivedAt: '2026-09-03T11:00:00Z');

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();

      expect(idsOf(notifier.state.rows), ['m3', 'm1']);
      expect(notifier.state.loaded, isTrue);
      expect(notifier.state.atEnd, isTrue, reason: 'a short page is the end');
      expect(notifier.state.loadError, isNull);
    });

    test('a failure keeps the rows and says so; the next one clears it',
        () async {
      await seed('m1', receivedAt: '2026-09-03T09:00:00Z');

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      expect(notifier.state.rows, hasLength(1));

      store.failNextPage = true;
      await notifier.load();
      expect(notifier.state.loadError, homeFeedStaleMessage);
      expect(
        notifier.state.rows,
        hasLength(1),
        reason: 'once loaded, never blank',
      );

      await notifier.load();
      expect(notifier.state.loadError, isNull);
    });
  });

  group('loadMore', () {
    test('walks the whole table with no row skipped or repeated', () async {
      await seedSixty();

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      expect(notifier.state.rows, hasLength(HomeFeedNotifier.pageSize));
      expect(notifier.state.atEnd, isFalse);

      await notifier.loadMore();
      final walked = idsOf(notifier.state.rows);

      expect(walked, hasLength(60));
      expect(walked.toSet(), hasLength(60), reason: 'nothing twice');
      expect(notifier.state.atEnd, isTrue);

      // The same order one unpaged read would have given, which is the only
      // way to say "nothing was skipped" about a cursor.
      final whole = await MessageStore(db).pageHomeFeed(limit: 200);
      expect(walked, idsOf(whole));
    });

    test('a second call while one is in flight is free', () async {
      await seedSixty();

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      final before = store.pageCalls;

      store.gate = Completer<void>();
      final first = notifier.loadMore();
      final second = notifier.loadMore();
      store.gate!.complete();
      store.gate = null;
      await Future.wait([first, second]);

      expect(
        store.pageCalls - before,
        1,
        reason: 'the scroll listener fires on every pixel',
      );
      expect(notifier.state.rows, hasLength(60));
    });

    test('does nothing once the end has been reached', () async {
      await seed('m1', receivedAt: '2026-09-03T09:00:00Z');

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      final before = store.pageCalls;

      await notifier.loadMore();
      expect(store.pageCalls, before);
    });
  });

  /// A stamp [days] before now, in the store's own spelling — the same helper
  /// the window itself is built from. Relative rather than absolute because
  /// the tiles' window is measured from the wall clock, and a fixture pinned
  /// to a date would fall out of it as the calendar moved.
  String daysAgo(int days) =>
      MessageStore.isoStamp(DateTime.now().subtract(Duration(days: days)));

  group('setFilter', () {
    test('a tile filter has no window: it reads the whole feed', () async {
      await seed('recent', receivedAt: daysAgo(1), gateReason: 'newsletter');
      await seed('ancient', receivedAt: daysAgo(30), gateReason: 'newsletter');
      await seed('kept', receivedAt: daysAgo(2));

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();

      expect(idsOf(notifier.state.rows), ['kept']);
      expect(store.lastSinceIso, isNull);

      await notifier.setFilter(HomeFilter.dropped);

      expect(store.lastFilter, HomeFilter.dropped);
      expect(
        store.lastSinceIso,
        isNull,
        reason: 'the tiles count the whole feed, so the rows under a tile are '
            'the whole feed too — otherwise the number is not the number of '
            'rows under it',
      );
      expect(idsOf(notifier.state.rows), ['recent', 'ancient']);
      expect(notifier.state.includeDropped, isTrue);
    });

    test('the filter it is already on is not a second read', () async {
      await seed('m1', receivedAt: daysAgo(1));

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      final before = store.pageCalls;

      await notifier.setFilter(HomeFilter.fromOthers);

      expect(store.pageCalls, before);
    });

    test('the standing search is re-asked, dropped following the filter',
        () async {
      await seed('m1', receivedAt: daysAgo(1));
      final runner = _RecordingRunner();

      final notifier = HomeFeedNotifier(store, searchRunner: runner.call);
      addTearDown(notifier.dispose);
      await notifier.load();
      await notifier.submitSearch('invoice');
      expect(runner.dropped, [false]);

      await notifier.setFilter(HomeFilter.dropped);

      expect(
        runner.dropped,
        [false, true],
        reason: 'a search under the Dropped tile has to reach the pile',
      );

      await notifier.setFilter(HomeFilter.needsYou);

      expect(runner.dropped, [false, true, false]);
    });
  });

  group('setSort', () {
    test('oldest first walks the other way and is written down', () async {
      await seed('m1', receivedAt: daysAgo(3));
      await seed('m2', receivedAt: daysAgo(2));
      await seed('m3', receivedAt: daysAgo(1));

      final stored = <HomeSort>[];
      final notifier = HomeFeedNotifier(
        store,
        persistSort: (value) async => stored.add(value),
      );
      addTearDown(notifier.dispose);
      await notifier.load();
      expect(idsOf(notifier.state.rows), ['m3', 'm2', 'm1']);

      await notifier.setSort(HomeSort.oldest);

      expect(stored, [HomeSort.oldest], reason: 'the order is a habit');
      expect(store.lastAscending, isTrue);
      expect(idsOf(notifier.state.rows), ['m1', 'm2', 'm3']);
    });

    test('the order it is already on is not a second read', () async {
      await seed('m1', receivedAt: daysAgo(1));

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      final before = store.pageCalls;

      await notifier.setSort(HomeSort.newest);

      expect(store.pageCalls, before);
    });

    test('the order the notifier was built on is the order it opens on',
        () async {
      await seed('m1', receivedAt: daysAgo(2));
      await seed('m2', receivedAt: daysAgo(1));

      final notifier = HomeFeedNotifier(store, sort: HomeSort.oldest);
      addTearDown(notifier.dispose);
      await notifier.load();

      expect(notifier.state.sort, HomeSort.oldest);
      expect(idsOf(notifier.state.rows), ['m1', 'm2']);
    });
  });

  group('setSources', () {
    test('an equal list is not a reload, however new the list object is',
        () async {
      await seed('m1', receivedAt: daysAgo(1));

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      final before = store.pageCalls;

      // A fresh object with the same contents, which is what the chips hand
      // over on every rebuild.
      await notifier.setSources(['email', 'teams']);

      expect(store.pageCalls, before);
    });

    test('a different list reloads against it', () async {
      await seed('mail', receivedAt: daysAgo(1));
      await seed('chat', receivedAt: daysAgo(1), source: 'teams');

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      expect(idsOf(notifier.state.rows), hasLength(2));

      await notifier.setSources(const ['teams']);

      expect(store.lastSources, ['teams']);
      expect(idsOf(notifier.state.rows), ['chat']);
    });
  });

  group('setThreshold', () {
    test('the constructor seeds it, and the store is bound to it', () async {
      await seed('m1', receivedAt: daysAgo(1));

      final notifier = HomeFeedNotifier(store, threshold: 0.4);
      addTearDown(notifier.dispose);
      await notifier.load();

      // The rail's slider, read once at build and carried into every page
      // read: the tile and the table have to be counting against one bar.
      expect(notifier.state.threshold, 0.4);
      expect(store.lastThreshold, 0.4);
    });

    test('moving the slider reloads page one against the new bar', () async {
      await seed('m1', receivedAt: daysAgo(1));

      final notifier = HomeFeedNotifier(store);
      addTearDown(notifier.dispose);
      await notifier.load();
      final before = store.pageCalls;

      await notifier.setThreshold(0.6);

      expect(notifier.state.threshold, 0.6);
      expect(store.pageCalls, before + 1);
      expect(store.lastThreshold, 0.6);
    });

    test('the number it is already on is not a second read', () async {
      await seed('m1', receivedAt: daysAgo(1));

      final notifier = HomeFeedNotifier(store, threshold: 0.25);
      addTearDown(notifier.dispose);
      await notifier.load();
      final before = store.pageCalls;

      await notifier.setThreshold(0.25);

      expect(store.pageCalls, before);
    });
  });
}

/// A search runner that answers with nothing and remembers what it was asked.
/// The question under test is which FILTER the query was run against, not what
/// came back.
class _RecordingRunner {
  final dropped = <bool>[];

  Future<MessageSearchResult> call(
    String query, {
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    dropped.add(includeDropped);
    return MessageSearchHits(query, const []);
  }
}
