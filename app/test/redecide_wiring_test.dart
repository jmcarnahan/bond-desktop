import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The install-time re-decide through the REAL provider wiring.
///
/// `syncServiceProvider` hands the sync a closure that reads
/// `triageQueueProvider` at call time, and the queue reads the sync for its
/// body fetch. Riverpod judges a `ref.read` from a provider's own ref against
/// the dependency graph exactly as it judges a `watch`, so if either side
/// WATCHED the other, the other's read would throw CircularDependencyError
/// (a debug-mode assert) — which is what every debug run did from 2026-09-29
/// until the calendar branch's foreground pass found it: the re-decide
/// failed on every sync pass and the pref that closes it was never written.
/// The hand-built `SyncService` tests cannot see this; only the container
/// can.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<ProviderContainer> container() async {
    final made = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      keepingDecisionClient(),
      noCommandHeads(),
    ]);
    addTearDown(made.dispose);
    await made.read(appPrefsProvider.notifier).ready;
    return made;
  }

  test('the sync re-decides through the queue the rail already built, '
      'and the pref closes', () async {
    final ref = await container();
    // The rail builds the queue before any sync pass runs; the order matters
    // because it is the queue's dependency edges the sync's read is judged
    // against.
    ref.read(triageQueueProvider);
    final sync = ref.read(syncServiceProvider) as SyncService;

    sync.startRedecide();
    await sync.redecideInFlight;

    // Nothing is stored, so the re-decide finds no stale decision and ends
    // complete, which is the only way the pref gets this build's hash. A
    // closure that threw (the cycle) would have left it unset.
    expect(await store.getPref(redecideQhashKey), decisionQhash);
  });

  test('the same with the sync built first', () async {
    final ref = await container();
    final sync = ref.read(syncServiceProvider) as SyncService;
    ref.read(triageQueueProvider);

    sync.startRedecide();
    await sync.redecideInFlight;

    expect(await store.getPref(redecideQhashKey), decisionQhash);
  });

  test('the queue follows a rebuilt sync without rebuilding itself',
      () async {
    final ref = await container();
    final queue = ref.read(triageQueueProvider);
    final before = ref.read(syncServiceProvider);

    // The same switch `backend_switch_test` flips: a new sync service.
    await ref.read(appPrefsProvider.notifier).setBackendMode(backendModeSdk);

    expect(identical(ref.read(syncServiceProvider), before), isFalse,
        reason: 'the switch rebuilds the sync');
    expect(identical(ref.read(triageQueueProvider), queue), isTrue,
        reason: 'the queue reads the sync at call time and need not rebuild');
  });
}
