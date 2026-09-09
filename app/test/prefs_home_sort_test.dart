import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Inbox's reading order, as a property of what is STORED.
///
/// An enum written by name into a TEXT table, so it has the two failure modes
/// `prefs_people_sort_test.dart` pins for the People orders: a fresh install is
/// an ABSENT key rather than a stored default, and a value nobody here wrote —
/// hand-edited, or a spelling a later build stopped using — has to read as the
/// default rather than throw on the Inbox's first frame.

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

  test('a fresh install reads newest first', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(homeSortKey), isNull);
    expect(ref.read(appPrefsProvider).homeSort, HomeSort.newest);
  });

  test('Oldest first lands in app_prefs under its own name and reads back',
      () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setHomeSort(HomeSort.oldest);

    expect(await store.getPref(homeSortKey), 'oldest');
    expect(ref.read(appPrefsProvider).homeSort, HomeSort.oldest);
    // And it is what a cold start would read, not only what the notifier is
    // holding — the feed is built from the stored value on the first frame.
    expect((await AppPrefsNotifier.read(store)).homeSort, HomeSort.oldest);
  });

  test('and back again, so the choice is reversible', () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    await prefs.setHomeSort(HomeSort.oldest);
    await prefs.setHomeSort(HomeSort.newest);

    expect(await store.getPref(homeSortKey), 'newest');
    expect(ref.read(appPrefsProvider).homeSort, HomeSort.newest);
  });

  test('a value nobody here wrote reads as newest first', () async {
    final store = MessageStore(db);
    await store.setPref(homeSortKey, 'sideways');

    expect((await AppPrefsNotifier.read(store)).homeSort, HomeSort.newest);
  });
}
