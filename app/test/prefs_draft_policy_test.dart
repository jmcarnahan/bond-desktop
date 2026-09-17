import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// When suggested replies are written, as a property of what is STORED.
///
/// `prefs_home_sort_test.dart`'s shape and its two failure modes, because this
/// is the same kind of setting: a fresh install is an ABSENT key rather than a
/// stored default, and a value nobody here wrote — hand-edited, or a spelling
/// a later build stopped using — has to read as the default rather than throw.
///
/// The default matters more here than for a sort order: it decides how much of
/// the big model's time a backlog spends on replies nobody asked for.

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

  test('a fresh install drafts for the messages that need you', () async {
    final ref = await container();

    expect(await MessageStore(db).getPref(draftPolicyKey), isNull);
    expect(ref.read(appPrefsProvider).draftPolicy, DraftPolicy.needsYou);
  });

  test('each mode lands in app_prefs under its own name and reads back',
      () async {
    final store = MessageStore(db);
    final ref = await container();
    final prefs = ref.read(appPrefsProvider.notifier);

    for (final (policy, stored) in const [
      (DraftPolicy.all, 'all'),
      (DraftPolicy.onDemand, 'onDemand'),
      (DraftPolicy.needsYou, 'needsYou'),
    ]) {
      await prefs.setDraftPolicy(policy);

      expect(await store.getPref(draftPolicyKey), stored);
      expect(ref.read(appPrefsProvider).draftPolicy, policy);
      // And it is what a cold start would read, not only what the notifier is
      // holding — the extract handler asks the stored value on every message.
      expect((await AppPrefsNotifier.read(store)).draftPolicy, policy);
    }
  });

  test('the key is the one the settings screen is named after', () async {
    expect(draftPolicyKey, 'suggested_replies');
  });

  test('a value nobody here wrote reads as the default', () async {
    final store = MessageStore(db);

    for (final raw in const ['needs_you', 'on_demand', 'sideways', '']) {
      await store.setPref(draftPolicyKey, raw);

      expect((await AppPrefsNotifier.read(store)).draftPolicy,
          DraftPolicy.needsYou);
    }
  });

  test('a wipe leaves it alone — it is this person, not this mailbox',
      () async {
    final store = MessageStore(db);
    final ref = await container();
    await ref.read(appPrefsProvider.notifier).setDraftPolicy(DraftPolicy.all);

    await store.wipeAll();

    expect((await AppPrefsNotifier.read(store)).draftPolicy, DraftPolicy.all);
  });
}
