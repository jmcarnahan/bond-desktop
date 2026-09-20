import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/activity_provider.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The number beside the cap in Settings, Processing: today's cloud drafts,
/// re-read on the activity tick.
///
/// Two claims. It counts what the handler notes and nothing older than local
/// midnight, and it MOVES when a row is recorded through the app's own log,
/// which is the whole liveness mechanism (a bare table write fires no tick,
/// which is why the reset invalidates it by hand).
void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProviderContainer container;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialAppPrefsProvider.overrideWithValue(prefs),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('counts today and not yesterday, and moves on a recorded event',
      () async {
    // Kept alive for the whole test: autoDispose would otherwise drop the
    // provider between reads and the tick would have nothing to refresh.
    final sub = container.listen(cloudDraftsTodayProvider, (_, _) {});
    addTearDown(sub.close);

    final yesterday = DateTime.now().subtract(const Duration(days: 1)).toUtc();
    await store.recordActivity(
      kind: 'draft_improve',
      status: 'ok',
      source: 'email',
      entityId: 'm0',
      detailJson: jsonEncode({'cloud': 2}),
      createdAt: MessageStore.isoStamp(yesterday),
    );
    expect(await container.read(cloudDraftsTodayProvider.future), 0);

    // Through the log, as the handler records it: this is the tick. The
    // stream event lands a microtask after the write, so the container is
    // pumped before the provider is read again.
    Future<int> afterRecord(String kind, int cloud) async {
      await container.read(activityLogProvider).record(
            kind,
            status: 'ok',
            source: 'email',
            entityId: 'm1',
            detail: {'cloud': cloud},
          );
      await container.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return container.read(cloudDraftsTodayProvider.future);
    }

    expect(await afterRecord('draft', 1), 1);
    expect(await afterRecord('draft_improve', 2), 3);
  });
}
