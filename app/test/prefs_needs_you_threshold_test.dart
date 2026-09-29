import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/decision/needs_you_predicate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Needs You slider as a stored preference: a cut on the decision model's
/// probability, on the slider's notches and inside its range, read the same
/// way by the notifier and by the store-level reader the services use.
void main() {
  late BondDatabase db;
  late MessageStore store;

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
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  test('a fresh install reads the golden-fitted default', () async {
    final ref = await container();

    expect(await store.getPref(needsYouThresholdKey), isNull);
    expect(ref.read(appPrefsProvider).needsYouThreshold, 0.30);
    expect(const AppPrefs().needsYouThreshold, 0.30);
    expect(await needsYouThresholdReader(store)(), 0.30);
  });

  test('a stored value is parsed by the notifier and by the reader', () async {
    await store.setPref(needsYouThresholdKey, '0.55');
    final ref = await container();

    expect(ref.read(appPrefsProvider).needsYouThreshold, 0.55);
    expect((await AppPrefsNotifier.read(store)).needsYouThreshold, 0.55);
    expect(await needsYouThresholdReader(store)(), 0.55);
  });

  test('an unreadable stored value is the default', () async {
    await store.setPref(needsYouThresholdKey, 'lots');

    expect((await AppPrefsNotifier.read(store)).needsYouThreshold, 0.30);
    expect(await needsYouThresholdReader(store)(), 0.30);
  });

  test('a hand-edited value out of range reads clamped', () async {
    await store.setPref(needsYouThresholdKey, '1.5');
    expect(await needsYouThresholdReader(store)(), 0.95);
    await store.setPref(needsYouThresholdKey, '0');
    expect(await needsYouThresholdReader(store)(), 0.05);
  });

  test('the writer lands in state and in app_prefs', () async {
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setNeedsYouThreshold(0.45);

    expect(ref.read(appPrefsProvider).needsYouThreshold, 0.45);
    expect(await store.getPref(needsYouThresholdKey), '0.45');
    expect(await needsYouThresholdReader(store)(), 0.45);
  });

  test('the writer clamps to the slider range', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setNeedsYouThreshold(0);
    expect(ref.read(appPrefsProvider).needsYouThreshold, 0.05);
    await notifier.setNeedsYouThreshold(1);
    expect(ref.read(appPrefsProvider).needsYouThreshold, 0.95);
    expect(await store.getPref(needsYouThresholdKey), '0.95');
  });

  test('the writer rounds to the nearest notch', () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setNeedsYouThreshold(0.33);
    expect(ref.read(appPrefsProvider).needsYouThreshold, 0.35);
    await notifier.setNeedsYouThreshold(0.32);
    expect(ref.read(appPrefsProvider).needsYouThreshold, 0.30);
    // 0.1 + 0.2 is 0.30000000000000004 in binary; what is stored is the
    // notch's own spelling.
    await notifier.setNeedsYouThreshold(0.1 + 0.2);
    expect(await store.getPref(needsYouThresholdKey), '0.3');
  });

  test('normalizeNeedsYouThreshold over the edges', () {
    expect(normalizeNeedsYouThreshold(double.nan), 0.30);
    expect(normalizeNeedsYouThreshold(-1), 0.05);
    expect(normalizeNeedsYouThreshold(0.95), 0.95);
    expect(normalizeNeedsYouThreshold(0.7), 0.7);
  });
}
