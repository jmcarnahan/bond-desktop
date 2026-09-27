import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// "Sending a reply marks it done", as a property of what is STORED.
///
/// This one preference can take a thread out of the pile without anybody
/// dismissing it, so the state a fresh install is in — and the state an
/// unreadable value reads as — is OFF. Only the one spelling the notifier
/// writes turns it on: an absent key, a hand-edited word or a string from a
/// build that meant something else all leave mail where the reader left it.

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

  test('a fresh install leaves a replied thread in the pile', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(replySendMarksDoneKey), isNull);
    expect(ref.read(appPrefsProvider).replySendMarksDone, isFalse);
  });

  test('turning it on lands in app_prefs and in the state', () async {
    final store = MessageStore(db);
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setReplySendMarksDone(true);

    expect(await store.getPref(replySendMarksDoneKey), 'true');
    expect(ref.read(appPrefsProvider).replySendMarksDone, isTrue);
    // And it is what a cold start would read, not only what the notifier is
    // holding: the send path reads this on the first reply of the session.
    expect((await AppPrefsNotifier.read(store)).replySendMarksDone, isTrue);
  });

  test('turning it off writes the off value rather than clearing the key',
      () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    await prefs.setReplySendMarksDone(true);
    await prefs.setReplySendMarksDone(false);

    expect(await store.getPref(replySendMarksDoneKey), 'false');
    expect(ref.read(appPrefsProvider).replySendMarksDone, isFalse);
    expect((await AppPrefsNotifier.read(store)).replySendMarksDone, isFalse);
  });

  test('a value nobody here wrote reads as off, never as on', () async {
    final store = MessageStore(db);
    // The failure mode worth pinning: anything that is not 'true' has to leave
    // threads in the pile, because the wrong guess here dismisses mail.
    for (final stored in ['TRUE', 'yes', '1', '', 'maybe']) {
      await store.setPref(replySendMarksDoneKey, stored);

      expect(
        (await AppPrefsNotifier.read(store)).replySendMarksDone,
        isFalse,
        reason: stored,
      );
    }
  });
}
