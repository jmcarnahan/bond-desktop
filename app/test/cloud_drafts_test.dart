import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/cloud_drafts.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';

/// The ledger behind "Cloud drafts today: N of cap", and the two preferences
/// it is read against.
///
/// The claims here are the ones no screen can make: that "today" is the
/// person's day rather than UTC's, that the count is a SUM of what each row
/// said it sent rather than a tally of rows, that a row of another kind or
/// another day is not in it, and that neither preference can be written to a
/// value the app would then have to defend against.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// One activity row, stamped where the test wants it.
  Future<void> seedEvent({
    String kind = 'draft',
    String? detailJson = '{"cloud":1}',
    Duration ago = const Duration(minutes: 5),
  }) async {
    await store.recordActivity(
      kind: kind,
      status: 'ok',
      source: 'email',
      entityId: 'm1',
      detailJson: detailJson,
    );
    // Stamped afterwards: `recordActivity` writes `now`, and a row of another
    // day is the whole point of one of the cases below.
    final at = DateTime.now().toUtc().subtract(ago).toIso8601String();
    await db.customUpdate(
      'UPDATE activity_events SET created_at = ? '
      'WHERE id = (SELECT MAX(id) FROM activity_events)',
      variables: [Variable(at)],
    );
  }

  CloudDraftLedger ledgerOf({int cap = 50, DateTime Function()? now}) =>
      CloudDraftLedger(store, cap: () => cap, now: now);

  group('startOfDayIso', () {
    test('is local midnight, written as the UTC string the rows carry', () {
      final now = DateTime(2026, 9, 19, 14, 30);
      final iso = CloudDraftLedger.startOfDayIso(now);

      final parsed = DateTime.parse(iso);
      expect(parsed.isUtc, isTrue);
      expect(parsed.toLocal(), DateTime(2026, 9, 19));
      expect(iso, endsWith('Z'));
    });

    test('a moment just after midnight still starts that same day', () {
      final iso = CloudDraftLedger.startOfDayIso(DateTime(2026, 9, 19, 0, 1));
      expect(DateTime.parse(iso).toLocal(), DateTime(2026, 9, 19));
    });
  });

  group('usedToday', () {
    test('nothing recorded is nothing sent', () async {
      expect(await ledgerOf().usedToday(), 0);
    });

    test('sums the counts across draft and draft_improve rows', () async {
      await seedEvent(detailJson: '{"cloud":2}');
      await seedEvent(kind: 'draft_improve');

      expect(await ledgerOf().usedToday(), 3);
    });

    test('ignores yesterday, another kind, and a row with no count', () async {
      await seedEvent(ago: const Duration(days: 2));
      await seedEvent(kind: 'triage');
      await seedEvent(detailJson: '{"chars":140}');
      await seedEvent(detailJson: null);

      expect(await ledgerOf().usedToday(), 0);
    });

    test('counts only what landed since local midnight', () async {
      await seedEvent();
      await seedEvent(ago: const Duration(days: 2));

      expect(await ledgerOf().usedToday(), 1);
    });
  });

  group('refusal', () {
    test('is null while there is room', () async {
      await seedEvent();
      expect(await ledgerOf(cap: 2).refusal(), isNull);
    });

    test('is the one line at the cap, naming the cap', () async {
      await seedEvent();
      await seedEvent(kind: 'draft_improve');

      expect(
        await ledgerOf(cap: 2).refusal(),
        "Cloud drafts are at today's cap of 2. Raise it under Settings, "
        'Processing.',
      );
    });

    test('reads the cap through the closure, every time it is asked',
        () async {
      var cap = 5;
      final ledger = CloudDraftLedger(store, cap: () => cap);
      await seedEvent();

      expect(await ledger.refusal(), isNull);
      cap = 1;
      expect(await ledger.refusal(), isNotNull);
    });
  });

  group('DraftRoutes.none', () {
    test('routes nowhere and stands for nothing', () {
      expect(DraftRoutes.none.draftTarget(), isNull);
      expect(DraftRoutes.none.improveTarget(), isNull);
      expect(DraftRoutes.none.standing(), isFalse);
      expect(DraftRoutes.none.ledger, isNull);
    });
  });

  group('the two preferences', () {
    Future<AppPrefsNotifier> notifier() async {
      final made = AppPrefsNotifier(store, tokens: MemoryTokenStore());
      addTearDown(made.dispose);
      await made.ready;
      return made;
    }

    test('default to off and fifty', () async {
      final prefs = await AppPrefsNotifier.read(store);
      expect(prefs.cloudDraftsStanding, isFalse);
      expect(prefs.cloudDraftsDailyCap, 50);
    });

    test('the standing switch writes the one spelling the read honours',
        () async {
      await (await notifier()).setCloudDraftsStanding(true);

      expect(await store.getPref(cloudDraftsStandingKey), 'true');
      expect((await AppPrefsNotifier.read(store)).cloudDraftsStanding, isTrue);
    });

    test('and turning it back off is read as off', () async {
      final prefs = await notifier();
      await prefs.setCloudDraftsStanding(true);
      await prefs.setCloudDraftsStanding(false);

      expect((await AppPrefsNotifier.read(store)).cloudDraftsStanding, isFalse);
    });

    test('the cap clamps at both ends, in the state and in the table',
        () async {
      final prefs = await notifier();

      await prefs.setCloudDraftsDailyCap(0);
      expect(prefs.state.cloudDraftsDailyCap, 1);
      expect(await store.getPref(cloudDraftsDailyCapKey), '1');

      await prefs.setCloudDraftsDailyCap(5000);
      expect(prefs.state.cloudDraftsDailyCap, 1000);
      expect(await store.getPref(cloudDraftsDailyCapKey), '1000');
    });

    test('a cap in range round-trips', () async {
      await (await notifier()).setCloudDraftsDailyCap(200);
      expect((await AppPrefsNotifier.read(store)).cloudDraftsDailyCap, 200);
    });

    test('a cap nobody this app wrote reads as the default', () async {
      await store.setPref(cloudDraftsDailyCapKey, 'lots');
      expect((await AppPrefsNotifier.read(store)).cloudDraftsDailyCap, 50);
    });

    test('a stored cap out of range is clamped on the read', () async {
      await store.setPref(cloudDraftsDailyCapKey, '90000');
      expect((await AppPrefsNotifier.read(store)).cloudDraftsDailyCap, 1000);
    });
  });
}
