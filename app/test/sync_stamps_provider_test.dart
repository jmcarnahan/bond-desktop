import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/activity_provider.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/services/sync_service.dart' show mailLastReconcileKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The four freshness stamps on their own.
///
/// The settings screen reads these instead of the activity snapshot, so the
/// contract worth pinning is the one the snapshot already keeps: nothing before
/// a pass has run, the stamp after, and a re-read on every recorded event so
/// an open Settings pane follows a sync that lands behind it.
void main() {
  late BondDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = testDb();
    container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('a mailbox nothing has pulled has no stamps', () async {
    final stamps = await container.read(syncStampsProvider.future);

    expect(stamps.mailIso, isNull);
    expect(stamps.teamsIso, isNull);
    expect(stamps.sweepIso, isNull);
    expect(stamps.reconcileIso, isNull);
  });

  test('the reconcile carries a stamp of its own', () async {
    final store = MessageStore(db);
    // Written by the mail pass rather than by the recorder, because the
    // reconcile runs on a cadence of its own: it is not a pass the activity
    // log stamps, and a reader asking whether the safety net is alive cannot
    // tell from the mail stamp beside it.
    await store.setPref(mailLastReconcileKey, '2026-09-05T10:00:00.000Z');

    final stamps = await container.read(syncStampsProvider.future);
    expect(stamps.reconcileIso, '2026-09-05T10:00:00.000Z');
    expect(stamps.mailIso, isNull);
  });

  test('a recorded pass stamps its own side and nobody else\'s', () async {
    // Held, or the autoDispose provider is torn down between the reads and
    // the second read would be a fresh computation rather than a re-read.
    container.listen(syncStampsProvider, (_, _) {});
    await container.read(syncStampsProvider.future);

    await container.read(activityLogProvider).record('sync_mail', count: 2);
    // The provider hears at most one event per [activityTickWindow], at the
    // window's end.
    await Future<void>.delayed(activityTickWindow);
    // The event goes out on a stream; give the provider the turn it needs to
    // hear it and start the re-read.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final stamps = await container.read(syncStampsProvider.future);
    expect(stamps.mailIso, isNotNull);
    expect(DateTime.tryParse(stamps.mailIso!), isNotNull);
    expect(stamps.teamsIso, isNull);
    expect(stamps.sweepIso, isNull);
  });

  test('a failed pass leaves the stamp where it was', () async {
    final store = MessageStore(db);
    await store.setPref(activityLastSyncTeamsKey, '2026-09-05T10:00:00.000Z');
    container.listen(syncStampsProvider, (_, _) {});
    await container.read(syncStampsProvider.future);

    await container
        .read(activityLogProvider)
        .record('sync_teams', status: 'error');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final stamps = await container.read(syncStampsProvider.future);
    expect(stamps.teamsIso, '2026-09-05T10:00:00.000Z');
  });

  test('a burst of events inside one tick window is one re-read, and it ends '
      'on the last write', () async {
    final counted = _StampReadCountingStore(db);
    final burstContainer = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        messageStoreProvider.overrideWithValue(counted),
      ],
    );
    addTearDown(burstContainer.dispose);
    burstContainer.listen(syncStampsProvider, (_, _) {});
    await burstContainer.read(syncStampsProvider.future);
    counted.mailReads = 0;

    // Five passes recorded back to back, as a drain burst records its items:
    // an in-memory insert is far under the window, so all five land in it.
    final log = burstContainer.read(activityLogProvider);
    for (var i = 1; i <= 5; i++) {
      await log.record('sync_mail', count: i);
    }
    await Future<void>.delayed(
      activityTickWindow + const Duration(milliseconds: 100),
    );

    final stamps = await burstContainer.read(syncStampsProvider.future);
    expect(counted.mailReads, 1, reason: 'one re-read per window, not five');
    expect(stamps.mailIso, await counted.getPref(activityLastSyncMailKey));
  });
}

/// Counts the stamp provider's reads of the mail stamp, which is one per run
/// of the provider.
class _StampReadCountingStore extends MessageStore {
  _StampReadCountingStore(super.db);

  int mailReads = 0;

  @override
  Future<String?> getPref(String key) {
    if (key == activityLastSyncMailKey) mailReads++;
    return super.getPref(key);
  }
}
