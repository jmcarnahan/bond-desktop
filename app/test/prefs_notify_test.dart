import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// How a settle announces itself, which is the one setting in `app_prefs` that
/// DEFAULTS ON — so its read is the inverse of every other one here.
///
/// That inversion is half the subject of this file: the app spends minutes
/// deciding a message needs the user, and a preference that read the ordinary
/// way would leave every install silent until someone went looking for a
/// switch. The other half is the migration. This three-way setting replaced a
/// ribbon on/off switch, and the one decision worth carrying across is the
/// decision to be quiet — an install that had turned the ribbon off must not
/// come back from the upgrade posting OS notifications.

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

  test('a fresh install gets the loudest of the three', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(notifyStyleKey), isNull);
    expect(ref.read(appPrefsProvider).notifyStyle, NotifyStyle.native);
    // And the ribbon runs underneath it — native mode is silent while the app
    // is frontmost, so the ribbon is what the user sees there.
    expect(ref.read(appPrefsProvider).notifyRibbon, isTrue);
  });

  test('each stored style parses back to itself', () async {
    for (final (stored, style) in [
      ('off', NotifyStyle.off),
      ('in_app', NotifyStyle.inApp),
      ('native', NotifyStyle.native),
    ]) {
      await MessageStore(db).setPref(notifyStyleKey, stored);

      expect((await container()).read(appPrefsProvider).notifyStyle, style,
          reason: stored);
    }
  });

  test('a value nobody here wrote cannot silence the app', () async {
    await MessageStore(db).setPref(notifyStyleKey, 'banana');

    expect(
      (await container()).read(appPrefsProvider).notifyStyle,
      NotifyStyle.native,
    );
  });

  test('the ribbon runs in both of the modes that are not off', () async {
    final store = MessageStore(db);

    await store.setPref(notifyStyleKey, 'in_app');
    expect((await container()).read(appPrefsProvider).notifyRibbon, isTrue);

    await store.setPref(notifyStyleKey, 'native');
    expect((await container()).read(appPrefsProvider).notifyRibbon, isTrue);

    await store.setPref(notifyStyleKey, 'off');
    expect((await container()).read(appPrefsProvider).notifyRibbon, isFalse);
  });

  group('the switch this replaced', () {
    test('a ribbon that was turned off stays off', () async {
      // The only decision the old switch could record, and the only one worth
      // carrying: someone who asked for quiet does not get toasts instead.
      await MessageStore(db).setPref(notifyRibbonKey, 'false');
      final ref = await container();

      expect(ref.read(appPrefsProvider).notifyStyle, NotifyStyle.off);
      expect(ref.read(appPrefsProvider).notifyRibbon, isFalse);
    });

    test('anything else it left behind reads as on', () async {
      await MessageStore(db).setPref(notifyRibbonKey, 'banana');

      expect(
        (await container()).read(appPrefsProvider).notifyStyle,
        NotifyStyle.native,
      );
    });

    test('and it loses to a style the user has since chosen', () async {
      final store = MessageStore(db);
      await store.setPref(notifyRibbonKey, 'false');
      await store.setPref(notifyStyleKey, 'in_app');

      expect(
        (await container()).read(appPrefsProvider).notifyStyle,
        NotifyStyle.inApp,
      );
    });
  });

  test('a chosen style lands in app_prefs and in the state', () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setNotifyStyle(NotifyStyle.off);

    expect(await store.getPref(notifyStyleKey), 'off');
    expect(ref.read(appPrefsProvider).notifyStyle, NotifyStyle.off);
  });

  test('it survives a relaunch, and comes back on again', () async {
    await (await container())
        .read(appPrefsProvider.notifier)
        .setNotifyStyle(NotifyStyle.off);

    final relaunched = await container();
    expect(relaunched.read(appPrefsProvider).notifyStyle, NotifyStyle.off);

    await relaunched
        .read(appPrefsProvider.notifier)
        .setNotifyStyle(NotifyStyle.inApp);
    expect(await MessageStore(db).getPref(notifyStyleKey), 'in_app');
    expect(
      (await container()).read(appPrefsProvider).notifyStyle,
      NotifyStyle.inApp,
    );
  });
}
