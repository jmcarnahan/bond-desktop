import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/system/system_info.dart' show HardwareInfo;
import 'package:bond_inbox/services/system/updater.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/model_slot_editor.dart';
import 'package:bond_inbox/widgets/settings_models_body.dart';
import 'package:bond_inbox/widgets/settings_models_simple.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Models section wired to the real host.
///
/// `settings_models_test.dart` drives the section over closures; this pins the
/// wires themselves — that a Save lands in `app_prefs`, that it moves the LIVE
/// client without rebuilding it, and that About reads the two providers rather
/// than a constant. None of that is visible from the screen's own tests.
///
/// **Bounded pumps only.** `InboxScreen` owns a sixty-second periodic timer, so
/// a `pumpAndSettle` anywhere in this file would never come back.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A Sparkle that answers, remembers what it was told, and counts checks.
///
/// `automatic` is the fake's OWN state and the switch has to follow it after
/// a toggle: that is the wire under test — the host re-reads the updater
/// rather than mirroring what it asked for.
class _FakeUpdater implements Updater {
  bool automatic = false;
  int checks = 0;
  final moves = <bool>[];

  @override
  Future<UpdaterStatus> status() async =>
      UpdaterStatus(available: true, automatic: automatic);

  @override
  Future<void> checkForUpdates() async => checks++;

  @override
  Future<void> setAutomaticChecks(bool on) async {
    moves.add(on);
    automatic = on;
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProviderContainer container;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> pumpInbox(
    WidgetTester tester, {
    Updater? updater,
    HardwareInfo? hardware,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        // The two platform channels a widget test has nobody on the other end
        // of. Overridden rather than faked at the plugin layer: the point of
        // the About section is that it renders whatever the host resolved.
        appInfoProvider.overrideWith((ref) async => (
              version: '1.2.3',
              build: '4',
            )),
        databasePathProvider.overrideWith((ref) async => '/tmp/bond_inbox.db'),
        // The third channel About reads. Left alone, `ChannelUpdater`'s call
        // never comes back inside a widget test (no platform, and the
        // fake-async zone holds the reply), so the status stays loading and
        // About shows no update rows at all — the tests that want a verdict
        // pass a fake.
        if (updater != null) updaterProvider.overrideWithValue(updater),
        // A readable machine, for the one case that presses Reset per-step
        // picks: left alone, the channel answers `HardwareInfo.unknown` at its
        // timeout, and a machine whose memory could not be read is offered no
        // button by design.
        if (hardware != null)
          hardwareInfoProvider.overrideWith((ref) async => hardware),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    await tester.pump();
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(InboxScreen)),
    );
  }

  Future<void> openSection(WidgetTester tester, String title) async {
    // Settings and the activity log live in the icon rail's account menu now
    // (D8), so getting there is two taps. Bounded pumps throughout —
    // `pumpAndSettle` never comes back with InboxScreen's timer running.
    await tester.tap(find.byKey(IconRail.accountMenuKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(IconRail.settingsItemKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final toggle = find.byKey(SettingsSection.toggleKey(title));
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();
  }

  /// The Models section, then the Advanced fold inside it — where the two
  /// slot editors live since Round H.
  Future<void> openAdvanced(WidgetTester tester) async {
    await openSection(tester, 'Models');
    final toggle = find.byKey(
      SettingsSection.toggleKey(SettingsModelsSimple.advancedTitle),
    );
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final target = find.byKey(key);
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a Save moves the live client without rebuilding it',
      (tester) async {
    await pumpInbox(tester);
    // Taken BEFORE the write: the assertion below is that this exact instance
    // follows the pref, because everything downstream watches it and a rebuild
    // mid-drain would abort work in flight.
    final before = container.read(stageLlmClientProvider('triage'));

    await openAdvanced(tester);

    final urlField = find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast));
    await tester.ensureVisible(urlField);
    await tester.pump();
    await tester.enterText(urlField, 'http://127.0.0.1:1/v1/chat/completions');
    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'qwen3-4b',
    );
    await tester.pump();

    await tapKey(tester, ModelSlotEditor.saveKey(ModelSlot.fast));

    expect(
      await store.getPref(fastLlmUrlKey),
      'http://127.0.0.1:1/v1/chat/completions',
    );
    expect(await store.getPref(fastLlmModelKey), 'qwen3-4b');

    final after = container.read(stageLlmClientProvider('triage'));
    expect(identical(before, after), isTrue);
    expect(after.baseUrl, 'http://127.0.0.1:1/v1/chat/completions');
    expect(after.model, 'qwen3-4b');

    // And the Targets list followed, which is what the host's `watch` of the
    // prefs is for: the built-in row is derived from the two slot prefs the
    // Save just wrote, and it re-rendered without anybody reopening the fold.
    expect(find.text('127.0.0.1:1'), findsOneWidget);
  });

  testWidgets('Use build defaults puts the slot back on the build',
      (tester) async {
    await pumpInbox(tester);
    await container.read(appPrefsProvider.notifier).setFastLlmTarget(
          url: 'http://127.0.0.1:1/v1/chat/completions',
          model: 'qwen3-4b',
        );
    await tester.pump();
    await tester.pump();

    await openAdvanced(tester);
    await tapKey(tester, ModelSlotEditor.resetKey(ModelSlot.fast));

    // Empty, not absent: `clearSlotTarget` writes the empty string, and empty
    // is what "follow the build" is stored as.
    expect(await store.getPref(fastLlmUrlKey), '');
    expect(await store.getPref(fastLlmModelKey), '');
    final triage = container.read(stageLlmClientProvider('triage'));
    expect(triage.baseUrl, LlmClient.fastBaseUrl);
    expect(triage.model, fastModelDefault);
  });

  testWidgets('About shows what the two providers resolved', (tester) async {
    await pumpInbox(tester);
    await openSection(tester, 'About');

    expect(find.text('Bond 1.2.3 (4)'), findsOneWidget);
    expect(find.text('Version 1.2.3 (4)'), findsOneWidget);
    expect(find.text('/tmp/bond_inbox.db'), findsOneWidget);
  });

  testWidgets('About wires the updater when it is there, and re-reads it',
      (tester) async {
    final updater = _FakeUpdater();
    await pumpInbox(tester, updater: updater);
    await openSection(tester, 'About');

    // Both controls are up, and the caption reads the fake's empty history.
    expect(find.byKey(SettingsScreen.checkForUpdatesKey), findsOneWidget);
    expect(find.text('Never checked for updates'), findsOneWidget);
    expect(find.text('Updates are not configured in this build.'),
        findsNothing);
    final tile = find.byType(SwitchListTile);
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tapKey(tester, SettingsScreen.checkForUpdatesKey);
    expect(updater.checks, 1);

    // The move reaches the updater, and the switch then shows what the
    // UPDATER says — the status is re-read, not mirrored. Bounded pumps: the
    // re-read is one awaited future.
    await tester.tap(tile);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(updater.moves, [true]);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });

  testWidgets('About says updates are off in a build with no updater',
      (tester) async {
    // `NullUpdater`, not "no override": inside a widget test the real
    // channel never answers at all (the fake-async zone holds the platform
    // reply forever), so the status stays loading and About shows nothing
    // update-related — which the last assertion of the previous test does
    // not cover and this one does not want. The null seam is what a build
    // whose updater could not start resolves to.
    await pumpInbox(tester, updater: const NullUpdater());
    await openSection(tester, 'About');

    expect(find.text('Updates are not configured in this build.'),
        findsOneWidget);
    expect(find.byKey(SettingsScreen.checkForUpdatesKey), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Version 1.2.3 (4)'), findsOneWidget);
  });

  testWidgets('Sync & data is wired to the real refresh', (tester) async {
    await pumpInbox(tester);
    await openSection(tester, 'Sync & data');

    expect(find.byKey(SettingsScreen.refreshNowKey), findsOneWidget);

    await tapKey(tester, SettingsScreen.refreshNowKey);

    expect(tester.takeException(), isNull);
  });
  testWidgets('on the box the host resolves the rows through the placement, '
      'offers no Drafts in flight, and Reset per-step picks goes back to the '
      'box', (tester) async {
    await pumpInbox(
      tester,
      hardware: const HardwareInfo(
        chip: 'Apple M2 Max',
        memoryBytes: 64 * 1024 * 1024 * 1024,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      ),
    );
    // A box install with no key, made the way the wizard and the page make
    // one, then one hand pick moving membership onto the small model.
    final notifier = container.read(appPrefsProvider.notifier);
    await notifier.useBox(
      baseUrl: 'https://box.example.com',
      hardwareTier: MachineTier.full,
    );
    await notifier.setStageTarget('storyline_membership', boxBulkId);
    // Let the tier resolve before opening the fold: until it does the Reset
    // caption reads `Reading this Mac…` whatever the placement. Bounded pumps,
    // the file's own rule.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    await openAdvanced(tester);

    const custom1 = 'Custom · 1 step points elsewhere · see Advanced';
    expect(find.text(custom1), findsOneWidget);
    expect(find.text('qwen3-4b on the GPU server'), findsOneWidget);
    // Decision 8: the box's width is the server's, not a preference.
    expect(find.text('Drafts in flight'), findsNothing);
    expect(find.text(SettingsModelsBody.boxResetCaption), findsOneWidget);

    await tapKey(tester, SettingsModelsBody.tierDefaultsKey);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final prefs = container.read(appPrefsProvider);
    expect(prefs.modelPlacement, ModelPlacement.box);
    expect(prefs.stageTargets, isNot(contains('storyline_membership')));
    expect(find.text('qwen3.8 on the GPU server'), findsOneWidget);
    expect(find.text(custom1), findsNothing);
  });
}
