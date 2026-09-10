import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/models/setup_step.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/setup_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// "Set up again", and what it is careful NOT to throw away.
///
/// Starting the wizard over must not re-copy a mailbox that is already here
/// or re-download twenty-three gigabytes that already are: the migration
/// record and the download ledger both describe work that HAPPENED, and both
/// are still true on the way back through the flow.
void main() {
  late BondDatabase db;
  late SetupStore store;

  setUp(() {
    db = testDb();
    store = SetupStore(db);
  });

  tearDown(() => db.close());

  test('the wizard bookkeeping goes, the expensive facts stay', () async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await store.set(SetupStore.containerMigrationKey, '{"migrated":true}');
    await store.set(SetupStore.downloadKey, '{"version":1,"files":{}}');
    await store.set('something_else', 'x');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final restart = container.read(setupRestartProvider.notifier);

    await restartSetupWith(store: store, restart: restart);

    final left = await store.all();
    expect(left.keys.toSet(), SetupStore.keptOnRestart);
    expect(left[SetupStore.containerMigrationKey], '{"migrated":true}');
    expect(left[SetupStore.downloadKey], '{"version":1,"files":{}}');
    expect(left.containsKey(SetupStore.setupKey), isFalse);
    expect(left.containsKey('something_else'), isFalse);
  });

  test('the key is already gone by the time the counter moves', () async {
    // The ORDER is the point. The gate re-reads the store the moment the
    // counter changes, so a bump before the clear would race it and find the
    // key still saying `done` — the app on screen and no wizard.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final restart = container.read(setupRestartProvider.notifier);

    String? whenBumped = SetupStep.done.name;
    var bumps = 0;
    final remove = restart.addListener((_) async {
      bumps++;
      // Read from INSIDE the listener, which is where the gate reads it.
      whenBumped = await store.get(SetupStore.setupKey);
    }, fireImmediately: false);
    addTearDown(remove);

    await restartSetupWith(store: store, restart: restart);
    // The listener's own read is a future; let it land.
    await Future<void>.delayed(Duration.zero);

    expect(bumps, 1);
    expect(whenBumped, isNull);
  });

  test('the counter moves, which is what the gate is listening to', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final restart = container.read(setupRestartProvider.notifier);
    expect(container.read(setupRestartProvider), 0);

    await restartSetupWith(store: store, restart: restart);
    expect(container.read(setupRestartProvider), 1);

    // A counter rather than a flag: the interesting event is the CHANGE, and
    // a second restart has to be a second signal.
    await restartSetupWith(store: store, restart: restart);
    expect(container.read(setupRestartProvider), 2);
  });

  test('the widget-side entry point reaches the same two effects', () async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);

    await restartSetupWith(
      store: container.read(setupStoreProvider),
      restart: container.read(setupRestartProvider.notifier),
    );

    expect(await store.get(SetupStore.setupKey), isNull);
    expect(container.read(setupRestartProvider), 1);
  });
}
