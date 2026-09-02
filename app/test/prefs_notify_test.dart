import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The ribbon's preference, which is the one bool in `app_prefs` that DEFAULTS
/// ON — so its read is the inverse of every other one here.
///
/// That inversion is the whole subject of this file: the app spends minutes
/// deciding a message needs the user, and a preference that read the ordinary
/// way would leave every install silent until someone went looking for a
/// switch. Only the literal 'false' this notifier writes turns it off; an
/// absent key and a hand-edited value both read as on.

void main() {
  late BondDatabase db;

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

  test('a fresh install is told about settles', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(notifyRibbonKey), isNull);
    expect(ref.read(appPrefsProvider).notifyRibbon, isTrue);
  });

  test('the stored off value is the only thing that turns it off', () async {
    await MessageStore(db).setPref(notifyRibbonKey, 'false');

    expect((await container()).read(appPrefsProvider).notifyRibbon, isFalse);
  });

  test('anything else stored reads as on', () async {
    // The inverted read, named: a value nobody here wrote must not be able to
    // silence the app.
    await MessageStore(db).setPref(notifyRibbonKey, 'banana');

    expect((await container()).read(appPrefsProvider).notifyRibbon, isTrue);
  });

  test('turning it off lands in app_prefs and in the state', () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setNotifyRibbon(false);

    expect(await store.getPref(notifyRibbonKey), 'false');
    expect(ref.read(appPrefsProvider).notifyRibbon, isFalse);
  });

  test('it survives a relaunch, and comes back on again', () async {
    await (await container())
        .read(appPrefsProvider.notifier)
        .setNotifyRibbon(false);

    final relaunched = await container();
    expect(relaunched.read(appPrefsProvider).notifyRibbon, isFalse);

    await relaunched.read(appPrefsProvider.notifier).setNotifyRibbon(true);
    expect(await MessageStore(db).getPref(notifyRibbonKey), 'true');
    expect((await container()).read(appPrefsProvider).notifyRibbon, isTrue);
  });
}
