import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// How far back each connector reaches, as a stored preference.
///
/// The subject of this file is the pair of guards around a number that decides
/// how much mail exists: it is clamped on the way in AND on the way out, and a
/// value that does not parse falls back rather than throwing. A preference
/// cannot be allowed to leave the sync with no window at all.

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

  test('a fresh install reaches back the default window', () async {
    final ref = await container();
    final store = MessageStore(db);

    // Nothing written: the default is a fact about the code, not a row
    // somebody's first launch had to lay down.
    expect(await store.getPref(mailLookbackDaysKey), isNull);
    expect(await store.getPref(teamsLookbackDaysKey), isNull);

    final prefs = ref.read(appPrefsProvider);
    expect(prefs.mailLookbackDays, syncFloorDays);
    expect(prefs.teamsLookbackDays, syncFloorDays);
  });

  test('a set mail lookback round-trips and leaves Teams alone', () async {
    final ref = await container();

    await ref.read(appPrefsProvider.notifier).setMailLookbackDays(45);

    expect(ref.read(appPrefsProvider).mailLookbackDays, 45);
    // The two connectors are separate settings, not one behind two names.
    expect(ref.read(appPrefsProvider).teamsLookbackDays, syncFloorDays);

    // The exact string landed in the table, and a new container reads it back
    // — the state is a cache of the store, not the other way round.
    expect(await MessageStore(db).getPref(mailLookbackDaysKey), '45');
    expect((await container()).read(appPrefsProvider).mailLookbackDays, 45);
  });

  test('a stored value that is not a number falls back, silently', () async {
    await MessageStore(db).setPref(teamsLookbackDaysKey, 'banana');

    final ref = await container();

    expect(ref.read(appPrefsProvider).teamsLookbackDays, syncFloorDays);
    expect(ref.read(appPrefsProvider).mailLookbackDays, syncFloorDays);
  });

  test('a lookback outside the range is clamped, in state and in the table',
      () async {
    final ref = await container();
    final notifier = ref.read(appPrefsProvider.notifier);

    await notifier.setMailLookbackDays(0);
    await notifier.setTeamsLookbackDays(9999);

    expect(ref.read(appPrefsProvider).mailLookbackDays, minLookbackDays);
    expect(ref.read(appPrefsProvider).teamsLookbackDays, maxLookbackDays);

    // Stored clamped, not raw: the next read must not have to clamp again to
    // agree with what is on screen.
    final store = MessageStore(db);
    expect(await store.getPref(mailLookbackDaysKey), '$minLookbackDays');
    expect(await store.getPref(teamsLookbackDaysKey), '$maxLookbackDays');
  });
}
