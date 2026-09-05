// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/archive_provider.dart';
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
}
