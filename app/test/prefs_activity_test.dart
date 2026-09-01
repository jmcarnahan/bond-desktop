import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The activity log's preference, as a property of what is STORED.
///
/// `app_prefs` is a TEXT table, so "off" has to survive a round trip through a
/// string — and the state a fresh install is in is an absent key, not a stored
/// 'false'. Both are pinned here because the rail reads this on every build:
/// a preference that parsed the wrong way would put a door to the machine room
/// in front of every user who never asked for one.

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

  test('a fresh install has no activity log', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(showActivityLogKey), isNull);
    expect(ref.read(appPrefsProvider).showActivityLog, isFalse);
  });

  test('turning it on lands in app_prefs and in the state', () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setShowActivityLog(true);

    expect(await store.getPref(showActivityLogKey), 'true');
    expect(ref.read(appPrefsProvider).showActivityLog, isTrue);
  });

  test('turning it off writes the off value rather than clearing the key',
      () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    await prefs.setShowActivityLog(true);
    await prefs.setShowActivityLog(false);

    expect(await store.getPref(showActivityLogKey), 'false');
    expect(ref.read(appPrefsProvider).showActivityLog, isFalse);
  });

  test('it survives a relaunch', () async {
    await (await container())
        .read(appPrefsProvider.notifier)
        .setShowActivityLog(true);

    final relaunched = await container();
    expect(relaunched.read(appPrefsProvider).showActivityLog, isTrue);
  });

  test('anything else stored reads as off', () async {
    // Hand-edited, or written by a build that meant something else by the key.
    // A preference that does not parse must not be able to turn a diagnostic
    // pane on for someone who never asked for it.
    await MessageStore(db).setPref(showActivityLogKey, 'yes');

    expect((await container()).read(appPrefsProvider).showActivityLog, isFalse);
  });
}
