import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The storyline spine's reading direction, as a property of what is STORED.
///
/// `app_prefs` is a TEXT table, so oldest-first has to survive a round trip
/// through a string — and the state a fresh install is in is an absent key, not
/// a stored 'false'. Both are pinned here because a preference that parsed the
/// wrong way would hand every new user a storyline running backwards.

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
}
