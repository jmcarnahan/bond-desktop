import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The two reading-order preferences, as properties of what is STORED.
///
/// `app_prefs` is a TEXT table, so oldest-first has to survive a round trip
/// through a string — and the state a fresh install is in is an absent key, not
/// a stored 'false'. Both are pinned here because a preference that parsed the
/// wrong way would hand every new user a storyline running backwards.
///
/// The Needs You order is the same shape with one more failure mode: it is an
/// enum written by name, so a value nobody here wrote — hand-edited, or a
/// spelling a later build stopped using — has to read as the ranking rather
/// than throw.

void main() {
  late BondDatabase db;

  /// The container, with its stored settings already loaded — the notifier
  /// starts on the defaults and reads the database a microtask later, which is
  /// what `main()` waits for before the first frame.
  Future<ProviderContainer> container() async {
    final made = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(made.dispose);
    await made.read(appPrefsProvider.notifier).ready;
    return made;
  }

  setUp(() {
    db = testDb();
  });

  tearDown(() => db.close());

  test('a fresh install reads its storylines oldest first', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(storylineNewestFirstKey), isNull);
    expect(ref.read(appPrefsProvider).storylineNewestFirst, isFalse);
  });

  test('flipping it lands in app_prefs and in the state', () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setStorylineNewestFirst(true);

    expect(await store.getPref(storylineNewestFirstKey), 'true');
    expect(ref.read(appPrefsProvider).storylineNewestFirst, isTrue);
  });

  test('flipping back writes the off value rather than clearing the key',
      () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    await prefs.setStorylineNewestFirst(true);
    await prefs.setStorylineNewestFirst(false);

    expect(await store.getPref(storylineNewestFirstKey), 'false');
    expect(ref.read(appPrefsProvider).storylineNewestFirst, isFalse);
  });

  group('the Needs You order', () {
    test('a fresh install reads the ranking, not the clock', () async {
      final ref = await container();

      expect(await MessageStore(db).getPref(needsYouSortKey), isNull);
      expect(ref.read(appPrefsProvider).needsYouSort, NeedsYouSort.priority);
    });

    test('newest lands in app_prefs under its own name and reads back',
        () async {
      final store = MessageStore(db);
      final ref = await container();

      await ref
          .read(appPrefsProvider.notifier)
          .setNeedsYouSort(NeedsYouSort.newest);

      expect(await store.getPref(needsYouSortKey), 'newest');
      expect(ref.read(appPrefsProvider).needsYouSort, NeedsYouSort.newest);
      // And it is what a cold start would read, not only what the notifier is
      // holding — the rail is built from the stored value on the first frame.
      expect(
        (await AppPrefsNotifier.read(store)).needsYouSort,
        NeedsYouSort.newest,
      );
    });

    test('and back again, so the choice is reversible', () async {
      final store = MessageStore(db);
      final ref = await container();
      final prefs = ref.read(appPrefsProvider.notifier);

      await prefs.setNeedsYouSort(NeedsYouSort.newest);
      await prefs.setNeedsYouSort(NeedsYouSort.priority);

      expect(await store.getPref(needsYouSortKey), 'priority');
      expect(ref.read(appPrefsProvider).needsYouSort, NeedsYouSort.priority);
    });

    test('a value nobody here wrote reads as the ranking', () async {
      // A bad preference must not be able to reorder Needs You into something
      // this app has no rule for — or, worse, stop it from starting.
      final store = MessageStore(db);
      await store.setPref(needsYouSortKey, 'loudest');

      expect(
        (await AppPrefsNotifier.read(store)).needsYouSort,
        NeedsYouSort.priority,
      );
    });
  });
}
