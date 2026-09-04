import 'dart:async';

// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  /// Held open, the read never returns — which is how a second [loadMore] can
  /// arrive while the first is still in flight.
  Completer<void>? gate;

  @override
  Future<List<HomeFeedRow>> pageHomeFeed({
    String? beforeReceivedAt,
    String? beforeSourceMessageId,
    int limit = 50,
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    pageCalls++;
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
      includeDropped: includeDropped,
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

  group('setIncludeDropped', () {
    test('reveals the dropped rows and writes the choice down', () async {
      await seed('m1', receivedAt: '2026-09-03T09:00:00Z');
      await seed(
        'm2',
        receivedAt: '2026-09-03T10:00:00Z',
        gateReason: 'newsletter',
      );

      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        // Preloaded, like `main()` does it: without this the prefs notifier
        // reads the database on a future nobody awaits, and that read lands
        // after the test has closed it.
        initialAppPrefsProvider.overrideWithValue(const AppPrefs()),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(homeFeedProvider.notifier);
      await notifier.load();
      expect(idsOf(container.read(homeFeedProvider).rows), ['m1']);

      await notifier.setIncludeDropped(true);

      expect(idsOf(container.read(homeFeedProvider).rows), ['m2', 'm1']);
      expect(container.read(homeFeedProvider).includeDropped, isTrue);
      expect(
        await MessageStore(db).getPref(homeShowDroppedKey),
        'true',
        reason: 'the toggle is a setting, not a mood',
      );
      expect(container.read(appPrefsProvider).homeShowDropped, isTrue);
    });

    test('a stored choice is what the feed opens on', () async {
      await seed('m1', receivedAt: '2026-09-03T09:00:00Z');
      await seed(
        'm2',
        receivedAt: '2026-09-03T10:00:00Z',
        gateReason: 'newsletter',
      );
      final store = MessageStore(db);
      await store.setPref(homeShowDroppedKey, 'true');

      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider
            .overrideWithValue(await AppPrefsNotifier.read(store)),
      ]);
      addTearDown(container.dispose);

      await container.read(homeFeedProvider.notifier).load();

      expect(container.read(homeFeedProvider).includeDropped, isTrue);
      expect(idsOf(container.read(homeFeedProvider).rows), ['m2', 'm1']);
    });
  });
}
