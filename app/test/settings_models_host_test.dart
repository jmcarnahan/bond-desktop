import 'dart:async';
import 'dart:io';

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
import 'package:bond_inbox/services/decision/decision_client.dart'
    show DecisionServerKind;
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:bond_inbox/widgets/settings_models_page.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_decision_client.dart';
import 'fixtures/fake_process_runner.dart';
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
  Future<void> ensureBodiesFor(
    String conversationKey,
    List<String> sourceMessageIds,
  ) async {}

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

/// A supervisor that only counts `ensurePreset`, for the Check wire.
class _CountingSupervisor extends ModelServerSupervisor {
  _CountingSupervisor(Directory support)
      : super(
          runner: FakeProcessRunner(),
          supportDir: support,
          binaryPath: () => '/usr/bin/true',
          buildPreset: () => testManifest().toPreset(support.path),
          routerPort: () => 8080,
          onPortMoved: (_) async {},
          managed: () => true,
        );

  int presets = 0;

  @override
  Future<void> ensurePreset() async => presets++;
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

  /// The app's own server, for the one case about the placement moving it.
  ///
  /// Everything it needs on disk is made HERE rather than in a test body: a
  /// `testWidgets` body runs inside a fake-async zone where a real filesystem
  /// future never completes, and awaiting one there hangs the run.
  late Directory support;
  late String modelsFolder;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    support = await Directory.systemTemp.createTemp('models-host');
    modelsFolder = p.join(support.path, 'models');
    runner = FakeProcessRunner();
    // Every file the fixture's own manifest names, so a launch under either
    // placement passes the preflight.
    final all = testManifest().toPreset(modelsFolder);
    for (final model in all.models) {
      final path = all.modelPath(model);
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsString('gguf');
    }
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: support,
      // A binary that resolves, so a start that did not happen is the
      // placement's doing rather than a missing executable's.
      binaryPath: () => '/usr/bin/true',
      // The rule `managedManifestProvider` applies, read SYNCHRONOUSLY off
      // the preferences: the placement is what moves the set, and awaiting
      // that provider's future here would deadlock — it completes in the
      // widget test's fake-async zone, which cannot advance while `runAsync`
      // is holding the body.
      buildPreset: () {
        final prefs = container.read(appPrefsProvider);
        return testManifest()
            .forRoles(
              hardwareTier: MachineTier.full,
              decisionManaged: prefs.decisionSpec.id == localDecisionId,
              generativeManagedId:
                  prefs.generativeSpec.id == localGenerativeId
                      ? routerProseId
                      : null,
            )
            .toPreset(modelsFolder);
      },
      routerPort: () => 8080,
      onPortMoved: (_) async {},
      managed: () => true,
    );
  });

  tearDown(() async {
    await supervisor.dispose();
    await db.close();
    if (support.existsSync()) await support.delete(recursive: true);
  });

  Future<void> pumpInbox(WidgetTester tester, {Updater? updater}) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        keepingDecisionClient(),
        noCommandHeads(),
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
    bool withServer = false,
    ModelServerSupervisor? server,
    FakeDecisionClient? decision,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        if (decision != null)
          decisionClientProvider.overrideWithValue(decision)
        else
          keepingDecisionClient(),
          noCommandHeads(),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        modelManifestProvider.overrideWithValue(testManifest()),
        // The app's own server, for the case that watches it follow the
        // placement. Left alone everywhere else: the other cases are about
        // preferences and clients, and a supervisor over a fake runner would
        // only add filesystem work to them.
        if (withServer || server != null)
          modelServerSupervisorProvider.overrideWithValue(server ?? supervisor),
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Taps one segment of one role's placement control, by its label.
  Future<void> tapSegment(WidgetTester tester, Key control, String label) async {
    final target =
        find.descendant(of: find.byKey(control), matching: find.text(label));
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Connect on the generative form moves the live client',
      (tester) async {
    const url = 'https://box.example.com/prose/v1/chat/completions';
    final probe = _ScriptedProbe(const {
      url: ModelProbeResult(reachable: true, modelIds: ['qwen3-27b-fp8']),
    });
    await pumpHost(tester, probe: probe);
    // Taken BEFORE the write: the assertion below is that this exact instance
    // follows the preferences, because everything downstream watches it and a
    // rebuild mid-drain would abort work in flight.
    final before = container.read(stageLlmClientProvider('triage'));

    await openHostSection(tester, 'Models');
    await tapSegment(tester, SettingsModelsPage.generativeModeKey,
        SettingsModelsPage.yourServerLabel);

    await tester.enterText(
      find.byKey(ModelServersForm.urlKey(ServerFormRole.generative)),
      url,
    );
    await tester.pump();
    // No key typed: the keychain plugin throws under `flutter test`, and what
    // a typed key does is pinned in `model_servers_form_test.dart`.
    await tapKey(tester, ModelServersForm.connectKey(ServerFormRole.generative));
    await settle(tester);

    expect(probe.asked, [(url, null)]);

    final prefs = container.read(appPrefsProvider);
    expect(prefs.modelPlacement, ModelPlacement.box);
    expect(prefs.specForStage('triage')?.id, boxProseId);
    expect(prefs.specForStage('triage')?.model, 'qwen3-27b-fp8');
    expect(prefs.specForStage('draft_reply')?.id, boxProseId);
    // The decision role did not move.
    expect(prefs.decisionPlacement, ModelPlacement.local);

    final after = container.read(stageLlmClientProvider('triage'));
    expect(identical(before, after), isTrue);
    expect(after.baseUrl, url);
    expect(after.model, 'qwen3-27b-fp8');
  });

  testWidgets('Connect on the decision form writes the decision role only',
      (tester) async {
    const url = 'https://box.example.com/decide/v1/embeddings';
    final probe = _ScriptedProbe(const {
      url: ModelProbeResult(reachable: true, modelIds: ['bond-decide-x']),
    });
    await pumpHost(tester, probe: probe);

    await openHostSection(tester, 'Models');
    await tapSegment(tester, SettingsModelsPage.decisionModeKey,
        SettingsModelsPage.yourServerLabel);
    await tester.enterText(
      find.byKey(ModelServersForm.urlKey(ServerFormRole.decision)),
      url,
    );
    await tester.pump();
    await tapKey(tester, ModelServersForm.connectKey(ServerFormRole.decision));
    await settle(tester);

    final prefs = container.read(appPrefsProvider);
    expect(prefs.decisionPlacement, ModelPlacement.box);
    expect(prefs.decisionSpec.id, boxDecideId);
    expect(prefs.decisionSpec.url, url);
    expect(prefs.decisionSpec.model, 'bond-decide-x');
    expect(prefs.modelPlacement, ModelPlacement.local);
  });

  testWidgets('Connect to a Kev server says so under the form', (tester) async {
    const url = 'https://box.example.com/decide/v1/systemone';
    final probe = _ScriptedProbe(const {
      url: ModelProbeResult(
          reachable: true, modelIds: ['bond-decide-kev4b-fixture']),
    });
    final decision = FakeDecisionClient.fixed(fakeAnswers())
      ..serverKind = DecisionServerKind.systemOne;
    await pumpHost(tester, probe: probe, decision: decision);

    await openHostSection(tester, 'Models');
    await tapSegment(tester, SettingsModelsPage.decisionModeKey,
        SettingsModelsPage.yourServerLabel);
    await tester.enterText(
      find.byKey(ModelServersForm.urlKey(ServerFormRole.decision)),
      url,
    );
    await tester.pump();
    await tapKey(tester, ModelServersForm.connectKey(ServerFormRole.decision));
    await settle(tester);

    expect(decision.checks, ['$url|bond-decide-kev4b-fixture']);
    final prefs = container.read(appPrefsProvider);
    expect(prefs.decisionSpec.id, boxDecideId);
    expect(prefs.decisionSpec.url, url);
    expect(
      tester
          .widget<Text>(find.byKey(SettingsModelsPage.decisionKindKey))
          .data,
      SettingsModelsPage.systemOneKindText,
    );
  });

  testWidgets('Settings opened on a Kev server asks its kind once, says it, '
      'and never asks for the heads file', (tester) async {
    const url = 'http://127.0.0.1:18302/v1/systemone';
    await store.setPref(decisionPlacementKey, ModelPlacement.box.name);
    await store.setPref(decisionUrlKey, url);
    await store.setPref(decisionModelKey, 'bond-decide-kev4b-fixture');
    final decision = FakeDecisionClient.fixed(fakeAnswers())
      ..detectedKind = DecisionServerKind.systemOne;
    await pumpHost(tester, probe: _ScriptedProbe(const {}), decision: decision);

    await openHostSection(tester, 'Models');
    await settle(tester);

    expect(decision.detects, ['$url|bond-decide-kev4b-fixture']);
    expect(
      tester
          .widget<Text>(find.byKey(SettingsModelsPage.decisionKindKey))
          .data,
      SettingsModelsPage.systemOneKindText,
    );
    final status = tester
        .widget<Text>(find.byKey(SettingsModelsPage.decisionStatusKey))
        .data;
    expect(status, isNot(contains('Not installed')));
    expect(status, startsWith('Connected · bond-decide-kev4b-fixture'));
  });

  testWidgets('Connect refuses a server that is not the decision model, and '
      'writes nothing', (tester) async {
    // The embedding model on its own port: it lists a name and answers
    // /v1/models, so only the identity probe can tell.
    const url = 'http://127.0.0.1:8081/v1/embeddings';
    const refusal = 'The server at http://127.0.0.1:8081 is not the decision '
        "model: its tokenizer is not ModernBERT's.";
    final probe = _ScriptedProbe(const {
      url: ModelProbeResult(reachable: true, modelIds: ['bond-embed']),
    });
    final decision = FakeDecisionClient.fixed(fakeAnswers())
      ..serverRefusal = refusal;
    await pumpHost(tester, probe: probe, decision: decision);

    await openHostSection(tester, 'Models');
    await tapSegment(tester, SettingsModelsPage.decisionModeKey,
        SettingsModelsPage.yourServerLabel);
    await tester.enterText(
      find.byKey(ModelServersForm.urlKey(ServerFormRole.decision)),
      url,
    );
    await tester.pump();
    await tapKey(tester, ModelServersForm.connectKey(ServerFormRole.decision));
    await settle(tester);

    expect(decision.checks, ['$url|bond-embed']);
    final error = tester.widget<InlineAlert>(
        find.byKey(ModelServersForm.errorKey(ServerFormRole.decision)));
    expect(error.text, refusal);
    expect(find.textContaining('Connected'), findsNothing);
    final prefs = container.read(appPrefsProvider);
    expect(prefs.decisionPlacement, ModelPlacement.local);
    expect(prefs.decisionSpec.url, isNot(url));
  });

  /// The server this Mac runs follows the placement, not only the launch.
  ///
  /// Real filesystem work either way, so the start goes inside `runAsync` and
  /// each restart is waited for with the run-and-pump pair — `runAsync` lets
  /// the real event loop deliver the result and the pump flushes the
  /// continuation waiting for it in the fake-async queue.
  testWidgets('a generative placement switch restarts the local server onto '
      "the placements' set", (tester) async {
    const url = 'https://box.example.com/prose/v1/chat/completions';
    final probe = _ScriptedProbe(const {
      url: ModelProbeResult(reachable: true, modelIds: ['qwen3-27b-fp8']),
    });
    await pumpHost(tester, probe: probe, withServer: true);
    await tester.runAsync(() => supervisor.ensureRunning());
    await tester.pump();
    expect(runner.starts, hasLength(1));

    await openHostSection(tester, 'Models');
    await tapSegment(tester, SettingsModelsPage.generativeModeKey,
        SettingsModelsPage.yourServerLabel);
    await tester.enterText(
      find.byKey(ModelServersForm.urlKey(ServerFormRole.generative)),
      url,
    );
    await tester.pump();
    await tapKey(tester, ModelServersForm.connectKey(ServerFormRole.generative));
    await settle(tester);
    for (var i = 0; i < 100 && runner.starts.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(container.read(appPrefsProvider).modelPlacement, ModelPlacement.box);
    expect(runner.starts, hasLength(2));
    var written = await tester.runAsync(
      () => supervisor.presetFile.readAsString(),
    );
    expect(written, contains('[$routerEmbedId]'));
    expect(written, isNot(contains('[$routerProseId]')));
    expect(written, isNot(contains('[$routerBulkId]')));

    await tapSegment(tester, SettingsModelsPage.generativeModeKey,
        SettingsModelsPage.thisMacLabel);
    await settle(tester);
    for (var i = 0; i < 100 && runner.starts.length < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(
      container.read(appPrefsProvider).modelPlacement,
      ModelPlacement.local,
    );
    expect(runner.starts, hasLength(3));
    written = await tester.runAsync(
      () => supervisor.presetFile.readAsString(),
    );
    expect(written, contains('[$routerEmbedId]'));
    expect(written, contains('[$routerProseId]'));
    // One generative model: the 4B is not served beside the 27B.
    expect(written, isNot(contains('[$routerBulkId]')));

    unawaited(supervisor.dispose());
    await tester.pump();
  });

  testWidgets('This Mac re-applies the rule', (tester) async {
    final probe = _ScriptedProbe(const {});
    await pumpHost(tester, probe: probe);
    await container.read(appPrefsProvider.notifier).useGenerative(
          placement: ModelPlacement.box,
          url: 'https://box.example.com/prose/v1/chat/completions',
          model: 'qwen3-27b-fp8',
          hardwareTier: MachineTier.full,
        );
    await tester.pump();
    await tester.pump();

    await openHostSection(tester, 'Models');
    await tapSegment(tester, SettingsModelsPage.generativeModeKey,
        SettingsModelsPage.thisMacLabel);
    await settle(tester);

    final prefs = container.read(appPrefsProvider);
    expect(prefs.modelPlacement, ModelPlacement.local);
    expect(prefs.specForStage('triage')?.id, localGenerativeId);
    expect(prefs.specForStage('draft_reply')?.id, localGenerativeId);
  });

  testWidgets('choosing the 4B writes the managed model and asks for the '
      'preset', (tester) async {
    final server = _CountingSupervisor(support);
    await pumpHost(tester, probe: _ScriptedProbe(const {}), server: server);
    await openHostSection(tester, 'Models');
    await tapSegment(tester, SettingsModelsPage.generativeManagedKey,
        SettingsModelsPage.model4bLabel);
    await settle(tester);

    final prefs = container.read(appPrefsProvider);
    expect(prefs.generativeManagedModel, routerBulkId);
    expect(prefs.generativeSpec.model, routerBulkId);
    expect(server.presets, greaterThanOrEqualTo(1));
  });

  testWidgets('Check on the decision model asks the supervisor for the '
      'preset', (tester) async {
    final server = _CountingSupervisor(support);
    await pumpHost(tester, probe: _ScriptedProbe(const {}), server: server);
    await openHostSection(tester, 'Models');
    final before = server.presets;
    final heads = container.read(decisionHeadsProvider);

    await tapKey(tester, SettingsModelsPage.checkDecisionKey);
    await settle(tester);

    // The make-decide-install-while-running path: the router is asked to
    // pick up the placements' preset, which restarts it only when the hash
    // moved.
    expect(server.presets, before + 1);
    // And the heads cache is left alone: it re-reads on a new mtime by
    // itself, and rebuilding it would rebuild the decision client and the
    // triage queue under it mid-drain.
    expect(identical(container.read(decisionHeadsProvider), heads), isTrue);
    expect(tester.takeException(), isNull);
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
  testWidgets('a generative remote reads its status through the placement',
      (tester) async {
    await pumpInbox(tester);
    final notifier = container.read(appPrefsProvider.notifier);
    await notifier.useGenerative(
      placement: ModelPlacement.box,
      url: 'https://box.example.com/prose/v1/chat/completions',
      model: 'qwen3-27b-fp8',
      hardwareTier: MachineTier.full,
    );
    await tester.pump();
    await tester.pump();

    await openSection(tester, 'Models');

    // No key was typed, and the generative line says the one thing left to
    // do; the decision model stays on this Mac.
    expect(
      tester
          .widget<Text>(find.byKey(SettingsModelsPage.generativeStatusKey))
          .data,
      SettingsModelsPage.keyNeededText,
    );
    expect(find.byKey(SettingsModelsPage.checkDecisionKey), findsOneWidget);
  });
}
