import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/system/system_info.dart' show HardwareInfo;
import 'package:bond_inbox/services/system/updater.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/screens/settings_host.dart';
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:bond_inbox/widgets/settings_models_page.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// The Models section wired to the real host.
///
/// `settings_models_page_test.dart` drives the page over closures; this pins
/// the wires themselves — that a Connect lands in `app_prefs`, that it moves
/// the LIVE client without rebuilding it, and that About reads the two
/// providers rather than a constant. None of that is visible from the
/// screen's own tests.
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

/// A probe that answers per URL and records what rode with each request.
///
/// A subclass rather than an interface: [ModelServerProbe] is a plain class
/// whose two members are both overridable, and a new abstraction for one map
/// would be a wider change than the thing it tests.
class _ScriptedProbe extends ModelServerProbe {
  _ScriptedProbe(this.answers);

  final Map<String, ModelProbeResult> answers;
  final asked = <(String, String?)>[];

  @override
  Future<ModelProbeResult> probe(String completionsUrl, {String? bearer}) async {
    asked.add((completionsUrl, bearer));
    return answers[completionsUrl] ??
        const ModelProbeResult(reachable: true, modelIds: ['a-model']);
  }

  @override
  void close() {}
}

/// An open panel nobody in this file presses.
class _NoDialogs implements FileDialogs {
  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      null;

  @override
  Future<String?> chooseDirectory() async => null;
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

  Future<void> pumpInbox(WidgetTester tester, {Updater? updater}) async {
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
        // The Models section reads `managedModelsStatusProvider`, which reads
        // the manifest, and `modelManifestProvider` throws unless a host
        // overrides it.
        modelManifestProvider.overrideWithValue(testManifest()),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    await tester.pump();
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(InboxScreen)),
    );
  }

  /// The settings host on its own, with a probe a test can script.
  ///
  /// The inbox gives no seam for the probe — it builds the real one — so the
  /// two cases about Connect seat the host directly. Everything below it is
  /// the same container, so the assertions are still about the real wiring.
  Future<void> pumpHost(
    WidgetTester tester, {
    required ModelServerProbe probe,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        modelManifestProvider.overrideWithValue(testManifest()),
        // Connect and Managed both read the machine tier AT THE PRESS, and
        // left alone the channel answers `HardwareInfo.unknown` two seconds
        // later: a press would land after the case had finished looking.
        hardwareInfoProvider.overrideWith((ref) async => const HardwareInfo(
              chip: 'Apple M2 Max',
              memoryBytes: 64 * 1024 * 1024 * 1024,
              appleSilicon: true,
              rosetta: false,
              osVersion: '15.6',
            )),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SettingsHost(
            scope: SettingsScope.ai,
            onBack: () {},
            onHome: () {},
            onCloseSettings: () {},
            fileDialogs: _NoDialogs(),
            onSetProcessing: (on) async {},
            waitForPullsToSettle: () async {},
            onRefreshNow: () async {},
            onSignOut: () async {},
            onOpenActivityLog: () {},
            onForgetThumbnails: () {},
            onToast: (_) {},
            probe: probe,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsHost)),
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

  /// One section of the host pumped alone: no rail to walk, one toggle.
  Future<void> openHostSection(WidgetTester tester, String title) async {
    final toggle = find.byKey(SettingsSection.toggleKey(title));
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

  testWidgets('Connect through the page moves the live client', (tester) async {
    const bigUrl = 'https://box.example.com/prose/v1/chat/completions';
    const smallUrl = 'https://box.example.com/bulk/v1/chat/completions';
    final probe = _ScriptedProbe(const {
      bigUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3-27b-fp8']),
      smallUrl: ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']),
    });
    await pumpHost(tester, probe: probe);
    // Taken BEFORE the write: the assertion below is that this exact instance
    // follows the preferences, because everything downstream watches it and a
    // rebuild mid-drain would abort work in flight.
    final before = container.read(stageLlmClientProvider('triage'));

    await openHostSection(tester, 'Models');
    await tester.tap(find.text(SettingsModelsPage.userDefinedLabel));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byKey(ModelServersForm.bigUrlKey), bigUrl);
    await tester.enterText(find.byKey(ModelServersForm.smallUrlKey), smallUrl);
    await tester.pump();
    // No key typed: the keychain plugin throws under `flutter test`, and what
    // a typed key does to the two requests and the one call is pinned in
    // `model_servers_form_test.dart` with no keychain behind it.
    await tapKey(tester, ModelServersForm.connectKey);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // Both servers were asked, through the host's own probe.
    expect(probe.asked, [(bigUrl, null), (smallUrl, null)]);

    final prefs = container.read(appPrefsProvider);
    expect(prefs.modelPlacement, ModelPlacement.box);
    // The names came from the servers themselves, and the two stages resolve
    // to the two derived specs.
    expect(prefs.specForStage('triage')?.id, boxBulkId);
    expect(prefs.specForStage('triage')?.model, 'qwen3-4b');
    expect(prefs.specForStage('draft_reply')?.id, boxProseId);
    expect(prefs.specForStage('draft_reply')?.model, 'qwen3-27b-fp8');

    final after = container.read(stageLlmClientProvider('triage'));
    expect(identical(before, after), isTrue);
    expect(after.baseUrl, smallUrl);
    expect(after.model, 'qwen3-4b');
  });

  testWidgets('Managed re-applies the rule', (tester) async {
    final probe = _ScriptedProbe(const {});
    await pumpHost(tester, probe: probe);
    await container.read(appPrefsProvider.notifier).useBox(
          bigUrl: 'https://box.example.com/prose/v1/chat/completions',
          smallUrl: 'https://box.example.com/bulk/v1/chat/completions',
          bigModel: 'qwen3-27b-fp8',
          smallModel: 'qwen3-4b',
          hardwareTier: MachineTier.full,
        );
    await tester.pump();
    await tester.pump();

    await openHostSection(tester, 'Models');
    await tester.tap(find.text(SettingsModelsPage.managedLabel));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    final prefs = container.read(appPrefsProvider);
    expect(prefs.modelPlacement, ModelPlacement.local);
    // Back on this Mac's own two, by the rule rather than by a stored row.
    expect(prefs.specForStage('triage')?.id, builtInFastId);
    expect(prefs.specForStage('draft_reply')?.id, builtInProseId);
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
  testWidgets('a user-defined install reads its rows through the placement',
      (tester) async {
    await pumpInbox(tester);
    // An install on two named servers, made the way the page makes one, then
    // one hand pick moving membership onto the small model.
    final notifier = container.read(appPrefsProvider.notifier);
    await notifier.useBox(
      bigUrl: 'https://box.example.com/prose/v1/chat/completions',
      smallUrl: 'https://box.example.com/bulk/v1/chat/completions',
      bigModel: 'qwen3-27b-fp8',
      smallModel: 'qwen3-4b',
      hardwareTier: MachineTier.full,
    );
    await notifier.setStageTarget('storyline_membership', boxBulkId);
    await tester.pump();
    await tester.pump();

    await openSection(tester, 'Models');

    // The big row describes the six steps that agree and counts the one that
    // does not; the small row names the server it dials.
    expect(find.text('Custom · 1 step points elsewhere'), findsOneWidget);
    expect(find.text('qwen3-4b at box.example.com'), findsOneWidget);
    // No key was typed, and the line says the one thing left to do.
    expect(
      tester.widget<Text>(find.byKey(SettingsModelsPage.statusKey)).data,
      SettingsModelsPage.keyNeededText,
    );
  });
}
