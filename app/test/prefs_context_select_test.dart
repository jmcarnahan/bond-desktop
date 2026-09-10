import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The section-pick preference, as a property of what is STORED.
///
/// It is one of the two switches in this app that default ON, so its read has
/// to be the inverse of every other one: anything that is not the exact string
/// this notifier writes for "off" leaves the feature on. `app_prefs` is a TEXT
/// table, so both halves of that — an absent key on a fresh install, and a
/// value somebody hand-edited — are pinned here.
///
/// Getting the polarity wrong in either direction is a real cost: read the
/// wrong way and every directory-fed draft either stops reading closer for
/// people who never turned it off, or keeps spending a model call for the
/// person who did.
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

  test('a fresh install reads two sections in full', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(contextSelectExpandKey), isNull);
    expect(ref.read(appPrefsProvider).contextSelectExpand, isTrue);
  });

  test('turning it off lands in app_prefs and in the state', () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setContextSelectExpand(false);

    expect(await store.getPref(contextSelectExpandKey), 'false');
    expect(ref.read(appPrefsProvider).contextSelectExpand, isFalse);
  });

  test('and turning it back on writes the on value', () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    await prefs.setContextSelectExpand(false);
    await prefs.setContextSelectExpand(true);

    expect(await store.getPref(contextSelectExpandKey), 'true');
    expect(ref.read(appPrefsProvider).contextSelectExpand, isTrue);
  });

  test('off survives a relaunch', () async {
    await (await container())
        .read(appPrefsProvider.notifier)
        .setContextSelectExpand(false);

    final relaunched = await container();
    expect(relaunched.read(appPrefsProvider).contextSelectExpand, isFalse);
  });

  test('anything else stored reads as on', () async {
    // Hand-edited, or written by a build that meant something else by the
    // key. A preference that does not parse must not be able to turn a
    // feature off for someone who never asked for that.
    await MessageStore(db).setPref(contextSelectExpandKey, 'no');

    expect(
      (await container()).read(appPrefsProvider).contextSelectExpand,
      isTrue,
    );
  });
}
