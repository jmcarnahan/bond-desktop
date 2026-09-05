import 'dart:async';

// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/archive_provider.dart';
import 'package:bond_inbox/services/message_search.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Dropped pile's reader, against a real database.
///
/// The walk is the part worth pinning: it is the home feed's keyset cursor
/// pointed at the other end of the same index, and the failure it rules out —
/// a row skipped or shown twice where several messages share a timestamp
/// across a page boundary — is invisible until somebody scrolls.

/// A store whose page read fails on demand, so the "once loaded, never blank"
/// rule can be exercised. Everything it does not intercept is the real
/// store's.
class _FailingStore extends MessageStore {
  _FailingStore(super.db);

  bool failNextPage = false;

  @override
  Future<List<HomeFeedRow>> pageHomeFeed({
    String? beforeReceivedAt,
    String? beforeSourceMessageId,
    int limit = 50,
    bool includeDropped = false,
    bool onlyDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async {
    if (failNextPage) {
      failNextPage = false;
      throw StateError('the dropped pile is unreadable');
    }
    return super.pageHomeFeed(
      beforeReceivedAt: beforeReceivedAt,
      beforeSourceMessageId: beforeSourceMessageId,
      limit: limit,
      includeDropped: includeDropped,
      onlyDropped: onlyDropped,
      sources: sources,
    );
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One message, plus the `message_progress` row `upsertMessage` writes with
  /// it, moved to whichever side of the gate this test needs.
  Future<void> seed(
    MessageStore into,
    String id, {
    String source = 'email',
    String receivedAt = '2026-09-01T10:00:00Z',
    bool dropped = true,
    String dropReason = 'newsletter',
  }) async {
    await into.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'c-$id',
      'direction': 'inbound',
      'subject': 'Weekly roundup',
      'from_name': 'Alex Rivera',
      'from_address': 'alex.rivera@example.com',
      'received_at': receivedAt,
      'created_at': receivedAt,
      'updated_at': receivedAt,
    });
    await db.customUpdate(
      "UPDATE message_progress SET dropped = ?, drop_reason = ?, "
      "outcome = ?, triage_state = 'done', settle_state = 'done' "
      'WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable(dropped ? 1 : 0),
        Variable(dropped ? dropReason : null),
        Variable(dropped ? 'dropped' : 'done'),
        Variable(source),
        Variable(id),
      ],
    );
  }

  test('a refresh loads the newest page and says where the pile ends',
      () async {
    await seed(store, 'd1', receivedAt: '2026-09-01T11:00:00Z');
    await seed(store, 'd2', receivedAt: '2026-09-01T10:00:00Z');
    await seed(store, 'live', dropped: false);

    final notifier = ArchiveNotifier(store);
    addTearDown(notifier.dispose);
    await notifier.refreshDropped();

    expect(
      notifier.state.droppedRows.map((r) => r.sourceMessageId),
      ['d1', 'd2'],
    );
    expect(notifier.state.droppedLoaded, true);
    expect(notifier.state.droppedAtEnd, true,
        reason: 'a short page is the end of the walk');
    expect(notifier.state.droppedError, null);
  });

  test('a full page leaves the walk open', () async {
    for (var i = 0; i < ArchiveNotifier.pageSize; i++) {
      await seed(
        store,
        'd${i.toString().padLeft(3, '0')}',
        receivedAt: '2026-09-01T10:00:00Z',
      );
    }

    final notifier = ArchiveNotifier(store);
    addTearDown(notifier.dispose);
    await notifier.refreshDropped();

    expect(notifier.state.droppedRows, hasLength(ArchiveNotifier.pageSize));
    expect(notifier.state.droppedAtEnd, false);
  });

  test('loading more walks the cursor and appends without repeating',
      () async {
    // The whole pile shares one timestamp, so every page boundary falls where
    // only the second half of the key can separate two rows.
    final ids = [
      for (var i = 0; i < ArchiveNotifier.pageSize + 3; i++)
        'd${i.toString().padLeft(3, '0')}',
    ];
    for (final id in ids) {
      await seed(store, id, receivedAt: '2026-09-01T10:00:00Z');
    }

    final notifier = ArchiveNotifier(store);
    addTearDown(notifier.dispose);
    await notifier.refreshDropped();
    await notifier.loadMoreDropped();

    final walked =
        notifier.state.droppedRows.map((r) => r.sourceMessageId).toList();
    expect(walked, ids.reversed.toList());
    expect(walked.toSet(), hasLength(walked.length), reason: 'no repeats');
    expect(notifier.state.droppedAtEnd, true);
  });

  test('past the end, loading more is a no-op', () async {
    await seed(store, 'd1');

    final notifier = ArchiveNotifier(store);
    addTearDown(notifier.dispose);
    await notifier.refreshDropped();
    final settled = notifier.state;

    await notifier.loadMoreDropped();

    expect(notifier.state, same(settled),
        reason: 'the end of the walk costs no read and no rebuild');
  });

  test('an unreadable page keeps the rows already read', () async {
    final flaky = _FailingStore(db);
    await seed(flaky, 'd1');

    final notifier = ArchiveNotifier(flaky);
    addTearDown(notifier.dispose);
    await notifier.refreshDropped();
    expect(notifier.state.droppedRows, hasLength(1));

    flaky.failNextPage = true;
    await notifier.refreshDropped();

    expect(notifier.state.droppedRows.map((r) => r.sourceMessageId), ['d1'],
        reason: 'once loaded, never blank');
    expect(notifier.state.droppedError, isNotNull);

    // And the sentence goes away when a read works again.
    await notifier.refreshDropped();
    expect(notifier.state.droppedError, null);
  });

  group('search', () {
    /// A row shaped enough to be told apart from another one. The search half
    /// of this notifier never reads the database — the runner is the seam —
    /// so a literal is the whole fixture.
    HomeFeedRow row(String id) => HomeFeedRow(
          source: 'email',
          sourceMessageId: id,
          conversationKey: 'c-$id',
          receivedAt: '2026-09-01T10:00:00Z',
          triageState: 'done',
          extractState: 'done',
          storylineState: 'done',
          draftState: 'skipped',
          settleState: 'done',
          outcome: 'done',
          dropped: false,
          subject: 'Invoice $id',
        );

    ArchiveNotifier notifierWith(ArchiveSearchRunner runner) {
      final notifier = ArchiveNotifier(store, searchRunner: runner);
      addTearDown(notifier.dispose);
      return notifier;
    }

    test('a submitted query lands as results', () async {
      final notifier = notifierWith(
        (query) async => ArchiveSearchResult(query, [row('a')], null),
      );

      await notifier.submitSearch('  invoice  ');

      expect(notifier.state.search?.query, 'invoice',
          reason: 'the query is trimmed before it is asked');
      expect(notifier.state.search?.rows.single.sourceMessageId, 'a');
      expect(notifier.state.searching, false);
      expect(notifier.state.searchNotice, null);
    });

    test('a blank query is not a question', () async {
      var asked = 0;
      final notifier = notifierWith((query) async {
        asked++;
        return ArchiveSearchResult(query, const [], null);
      });

      await notifier.submitSearch('   ');

      expect(asked, 0);
      expect(notifier.state.search, null);
      expect(notifier.state.searching, false);
    });

    test('a slow first answer never overwrites a faster second', () async {
      final held = Completer<ArchiveSearchResult>();
      final notifier = notifierWith((query) {
        if (query == 'first') return held.future;
        return Future.value(ArchiveSearchResult(query, [row('b')], null));
      });

      final first = notifier.submitSearch('first');
      await notifier.submitSearch('second');
      expect(notifier.state.search?.query, 'second');

      held.complete(ArchiveSearchResult('first', [row('a')], null));
      await first;

      expect(notifier.state.search?.query, 'second',
          reason: 'the stamp moved before the first query was ever asked');
      expect(notifier.state.search?.rows.single.sourceMessageId, 'b');
    });

    test('a runner that throws says so and leaves the piles alone', () async {
      final notifier = notifierWith(
        (_) async => throw StateError('the index is unreadable'),
      );

      await notifier.submitSearch('invoice');

      expect(notifier.state.searchNotice, isNotNull);
      expect(notifier.state.search, null,
          reason: 'nothing answered, so there is nothing to show');
      expect(notifier.state.searching, false);
    });

    test('a result that only text could answer still lands as results',
        () async {
      final notifier = notifierWith(
        (query) async => ArchiveSearchResult(
          query,
          [row('a')],
          'Text matches only — the embedding server is not reachable.',
        ),
      );

      await notifier.submitSearch('invoice');

      // The difference from Home: the search RAN, so the body swaps and the
      // sentence rides on the rows rather than in place of them.
      expect(notifier.state.search, isNotNull);
      expect(notifier.state.search?.notice, startsWith('Text matches only'));
      expect(notifier.state.searchNotice, null);
    });

    test('leaving search clears it, and a late answer cannot bring it back',
        () async {
      final held = Completer<ArchiveSearchResult>();
      final notifier = notifierWith((_) => held.future);

      final pending = notifier.submitSearch('invoice');
      notifier.exitSearch();
      expect(notifier.state.search, null);
      expect(notifier.state.searching, false);
      expect(notifier.state.searchNotice, null);

      held.complete(ArchiveSearchResult('invoice', [row('a')], null));
      await pending;

      expect(notifier.state.search, null,
          reason: 'the answer belongs to a search that no longer exists');
    });

    test('a failed search stops saying so once one works', () async {
      var fail = true;
      final notifier = notifierWith((query) async {
        if (fail) throw StateError('the index is unreadable');
        return ArchiveSearchResult(query, [row('a')], null);
      });

      await notifier.submitSearch('invoice');
      expect(notifier.state.searchNotice, isNotNull);

      fail = false;
      await notifier.submitSearch('invoice');

      expect(notifier.state.searchNotice, null);
      expect(notifier.state.search, isNotNull);
    });
  });
}
