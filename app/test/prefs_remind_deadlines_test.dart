import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// "Remind me in To Do about deadlines", as a property of what is STORED.
///
/// ON by default: the reminder lands in the owner's own To Do and emails
/// nobody. So only the one spelling the notifier writes for off reads as
/// off; an absent key or a value nobody here wrote leaves it on.

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

  test('a fresh install reminds about deadlines', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(remindDeadlinesKey), isNull);
    expect(ref.read(appPrefsProvider).remindDeadlines, isTrue);
    expect(const AppPrefs().remindDeadlines, isTrue);
  });

  test('turning it off lands in app_prefs, in the state and on a cold start',
      () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setRemindDeadlines(false);

    expect(await store.getPref(remindDeadlinesKey), 'false');
    expect(ref.read(appPrefsProvider).remindDeadlines, isFalse);
    expect((await AppPrefsNotifier.read(store)).remindDeadlines, isFalse);
  });

  test('turning it back on writes the on value', () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    await prefs.setRemindDeadlines(false);
    await prefs.setRemindDeadlines(true);

    expect(await store.getPref(remindDeadlinesKey), 'true');
    expect(ref.read(appPrefsProvider).remindDeadlines, isTrue);
    expect((await AppPrefsNotifier.read(store)).remindDeadlines, isTrue);
  });

  test('a value nobody here wrote reads as on', () async {
    final store = MessageStore(db);
    for (final stored in ['TRUE', 'no', '0', '', 'maybe']) {
      await store.setPref(remindDeadlinesKey, stored);

      expect(
        (await AppPrefsNotifier.read(store)).remindDeadlines,
        isTrue,
        reason: stored,
      );
    }
  });

  test('copyWith carries it', () {
    const prefs = AppPrefs();
    expect(prefs.copyWith(remindDeadlines: false).remindDeadlines, isFalse);
    expect(
      prefs.copyWith(remindDeadlines: false).copyWith().remindDeadlines,
      isFalse,
    );
  });
}
