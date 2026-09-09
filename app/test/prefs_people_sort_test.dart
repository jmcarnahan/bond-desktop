import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The two People orders, as properties of what is STORED.
///
/// Both are enums written by name into a TEXT table, so each has the same two
/// failure modes: a fresh install is an ABSENT key rather than a stored
/// default, and a value nobody here wrote — hand-edited, or a spelling a later
/// build stopped using — has to read as the default rather than throw on the
/// first frame of the People stop.

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

  group('the People directory order', () {
    test('a fresh install reads recency', () async {
      final ref = await container();

      expect(await MessageStore(db).getPref(peopleSortKey), isNull);
      expect(ref.read(appPrefsProvider).peopleSort, PeopleSort.recent);
    });

    test('By name lands in app_prefs under its own name and reads back',
        () async {
      final store = MessageStore(db);
      final ref = await container();

      await ref.read(appPrefsProvider.notifier).setPeopleSort(PeopleSort.name);

      expect(await store.getPref(peopleSortKey), 'name');
      expect(ref.read(appPrefsProvider).peopleSort, PeopleSort.name);
      // And it is what a cold start would read, not only what the notifier is
      // holding — the directory is built from the stored value on the first
      // frame.
      expect(
        (await AppPrefsNotifier.read(store)).peopleSort,
        PeopleSort.name,
      );
    });

    test('and back again, so the choice is reversible', () async {
      final store = MessageStore(db);
      final ref = await container();
      final prefs = ref.read(appPrefsProvider.notifier);

      await prefs.setPeopleSort(PeopleSort.needsYou);
      await prefs.setPeopleSort(PeopleSort.recent);

      expect(await store.getPref(peopleSortKey), 'recent');
      expect(ref.read(appPrefsProvider).peopleSort, PeopleSort.recent);
    });

    test('a value nobody here wrote reads as recency', () async {
      final store = MessageStore(db);
      await store.setPref(peopleSortKey, 'loudest');

      expect(
        (await AppPrefsNotifier.read(store)).peopleSort,
        PeopleSort.recent,
      );
    });
  });

  group('the person-room order', () {
    test('a fresh install reads newest first', () async {
      final ref = await container();

      expect(await MessageStore(db).getPref(roomSortKey), isNull);
      expect(ref.read(appPrefsProvider).roomSort, RoomSort.newest);
    });

    test('Oldest first lands in app_prefs and reads back', () async {
      final store = MessageStore(db);
      final ref = await container();

      await ref.read(appPrefsProvider.notifier).setRoomSort(RoomSort.oldest);

      expect(await store.getPref(roomSortKey), 'oldest');
      expect(ref.read(appPrefsProvider).roomSort, RoomSort.oldest);
      expect(
        (await AppPrefsNotifier.read(store)).roomSort,
        RoomSort.oldest,
      );
    });

    test('and back again', () async {
      final store = MessageStore(db);
      final ref = await container();
      final prefs = ref.read(appPrefsProvider.notifier);

      await prefs.setRoomSort(RoomSort.oldest);
      await prefs.setRoomSort(RoomSort.newest);

      expect(await store.getPref(roomSortKey), 'newest');
      expect(ref.read(appPrefsProvider).roomSort, RoomSort.newest);
    });

    test('a value nobody here wrote reads as newest first', () async {
      final store = MessageStore(db);
      await store.setPref(roomSortKey, 'sideways');

      expect((await AppPrefsNotifier.read(store)).roomSort, RoomSort.newest);
    });
  });
}
