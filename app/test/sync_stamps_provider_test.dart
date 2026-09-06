import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/activity_provider.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The three freshness stamps on their own.
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
  });

  test('a recorded pass stamps its own side and nobody else\'s', () async {
    // Held, or the autoDispose provider is torn down between the reads and
    // the second read would be a fresh computation rather than a re-read.
    container.listen(syncStampsProvider, (_, _) {});
    await container.read(syncStampsProvider.future);

    await container.read(activityLogProvider).record('sync_mail', count: 2);
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
}
