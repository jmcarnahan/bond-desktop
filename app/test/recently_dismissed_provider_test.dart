// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/dismissed_thread.dart';
import 'package:bond_inbox/models/message_models.dart' show ConversationState;
import 'package:bond_inbox/providers/recently_dismissed_provider.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Recently dismissed tab's reader. The store read is pinned in
/// `store_label_rules_test.dart`'s `recently_dismissed` group; this pins what
/// the notifier adds on top: the window it asks for, re-reading on every
/// entry, and the Dropped pile's "once loaded, never blank".

/// A store whose read fails on demand. Everything else is the real store's.
class _FailingStore extends MessageStore {
  _FailingStore(super.db);

  bool failNext = false;

  @override
  Future<List<DismissedThread>> recentlyDismissed({
    required String sinceIso,
  }) async {
    if (failNext) {
      failNext = false;
      throw StateError('the dismissals are unreadable');
    }
    return super.recentlyDismissed(sinceIso: sinceIso);
  }
}

void main() {
  late BondDatabase db;
  late _FailingStore store;

  setUp(() {
    db = testDb();
    store = _FailingStore(db);
  });

  tearDown(() => db.close());

  Future<void> dismiss(String key, {required Duration ago}) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Thread $key',
      'state': 'needs_reply',
      'last_message_at': MessageStore.isoStamp(DateTime.now().toUtc()),
    });
    await store.setConversationState('email', key, ConversationState.done);
    await db.customUpdate(
      'UPDATE conversations SET state_changed_at = ? '
      'WHERE conversation_key = ?',
      variables: [
        Variable(
            MessageStore.isoStamp(DateTime.now().toUtc().subtract(ago))),
        Variable(key),
      ],
    );
  }

  List<String> keysOf(RecentlyDismissedNotifier n) =>
      [for (final row in n.state.rows) row.conversation.id];

  test('reads nothing until it is asked, and the last seven days when it is',
      () async {
    await dismiss('this-week', ago: const Duration(days: 2));
    await dismiss('last-month', ago: const Duration(days: 30));
    final notifier = RecentlyDismissedNotifier(store);
    addTearDown(notifier.dispose);

    expect(notifier.state.loaded, isFalse);
    expect(notifier.state.rows, isEmpty);

    await notifier.refresh();

    expect(notifier.state.loaded, isTrue);
    expect(keysOf(notifier), ['this-week']);
  });

  test('every entry re-reads, so a dismissal made meanwhile appears',
      () async {
    await dismiss('first', ago: const Duration(hours: 3));
    final notifier = RecentlyDismissedNotifier(store);
    addTearDown(notifier.dispose);
    await notifier.refresh();
    expect(keysOf(notifier), ['first']);

    await dismiss('second', ago: const Duration(hours: 1));
    await notifier.refresh();

    expect(keysOf(notifier), ['second', 'first']);
  });

  test('the window is measured from the injected clock', () async {
    await dismiss('c1', ago: const Duration(days: 2));
    final notifier = RecentlyDismissedNotifier(
      store,
      now: () => DateTime.now().add(const Duration(days: 6)),
    );
    addTearDown(notifier.dispose);

    await notifier.refresh();

    expect(keysOf(notifier), isEmpty,
        reason: 'two days ago is eight days before a clock six days ahead');
  });

  test('a failed read keeps the rows and says so', () async {
    await dismiss('c1', ago: const Duration(hours: 1));
    final notifier = RecentlyDismissedNotifier(store);
    addTearDown(notifier.dispose);
    await notifier.refresh();

    store.failNext = true;
    await notifier.refresh();

    expect(keysOf(notifier), ['c1']);
    expect(notifier.state.error, isNotNull);

    await notifier.refresh();
    expect(notifier.state.error, isNull);
  });

  test('a row shown again leaves at once', () async {
    await dismiss('c1', ago: const Duration(hours: 2));
    await dismiss('c2', ago: const Duration(hours: 1));
    final notifier = RecentlyDismissedNotifier(store);
    addTearDown(notifier.dispose);
    await notifier.refresh();

    notifier.noteShown('email', 'c2');

    expect(keysOf(notifier), ['c1']);
  });
}
