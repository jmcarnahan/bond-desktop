import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// The activity log's preference, as a property of what is STORED.
///
/// `app_prefs` is a TEXT table, so "off" has to survive a round trip through a
/// string — and the state a fresh install is in is an absent key, not a stored
/// 'false'. Both are pinned here because the rail reads this on every build:
/// a preference that parsed the wrong way would put a door to the machine room
/// in front of every user who never asked for one.

void main() {
  late Database db;

  ProviderContainer container() {
    final made = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(made.dispose);
    return made;
  }

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
  });

  tearDown(() => db.close());

  test('a fresh install has no activity log', () {
    final ref = container();

    expect(MessageStore(db).getPref(showActivityLogKey), isNull);
    expect(ref.read(appPrefsProvider).showActivityLog, isFalse);
  });

  test('turning it on lands in app_prefs and in the state', () {
    final store = MessageStore(db);
    final ref = container();

    ref.read(appPrefsProvider.notifier).setShowActivityLog(true);

    expect(store.getPref(showActivityLogKey), 'true');
    expect(ref.read(appPrefsProvider).showActivityLog, isTrue);
  });

  test('turning it off writes the off value rather than clearing the key', () {
    final store = MessageStore(db);
    final ref = container();
    final prefs = ref.read(appPrefsProvider.notifier);

    prefs.setShowActivityLog(true);
    prefs.setShowActivityLog(false);

    expect(store.getPref(showActivityLogKey), 'false');
    expect(ref.read(appPrefsProvider).showActivityLog, isFalse);
  });

  test('it survives a relaunch', () {
    container().read(appPrefsProvider.notifier).setShowActivityLog(true);

    final relaunched = container();
    expect(relaunched.read(appPrefsProvider).showActivityLog, isTrue);
  });

  test('anything else stored reads as off', () {
    // Hand-edited, or written by a build that meant something else by the key.
    // A preference that does not parse must not be able to turn a diagnostic
    // pane on for someone who never asked for it.
    MessageStore(db).setPref(showActivityLogKey, 'yes');

    expect(container().read(appPrefsProvider).showActivityLog, isFalse);
  });
}
