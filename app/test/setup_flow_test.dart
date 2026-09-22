import 'dart:async';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/models/setup_step.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/notification_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/providers/setup_provider.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/screens/setup/setup_flow.dart';
import 'package:bond_inbox/screens/setup/setup_where_body.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/notify/desktop_notification_service.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/system/system_info.dart';
import 'package:bond_inbox/widgets/probe_status.dart' show ProbeStatus;
import 'package:bond_inbox/widgets/pane_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_desktop_notifier.dart';
import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/memory_token_store.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// A store whose writes fail — the Finish that cannot be saved.
class _UnwritableStore extends SetupStore {
  _UnwritableStore(super.db);

  @override
  Future<void> set(String key, String value) async =>
      throw StateError('disk is read-only');
}

/// The whole wizard, walked end to end.
///
/// The models are seeded as ALREADY DOWNLOADED — a ledger saying done and
/// three files on disk — so this file is about the walk rather than about the
/// downloader, which has its own suite. Everything real is built in `setUp`,
/// because a `testWidgets` body runs in a fake-async zone where a filesystem
/// future never completes.
void main() {
  late Directory support;
  late BondDatabase db;
  late SetupStore store;
  late FakeSystemInfo system;
  late FakeAuthSession auth;
  late FakeDesktopNotifier notifier;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;
  late StreamController<MessageSettled> settles;
  late DesktopNotificationService notifications;
  late ProviderContainer container;
  late ModelManifest manifest;

  String folder() => p.join(support.path, 'models');

  /// The wizard's world. [overStore] is for the one case that needs a store
  /// which cannot be written.
  void makeContainer({SetupStore? overStore}) {
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // The models folder is `AppPaths.models` with the preference left
      // empty, which is what an untouched install really has.
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest),
      systemInfoProvider.overrideWithValue(system),
      modelServerSupervisorProvider.overrideWithValue(supervisor),
      authSessionProvider.overrideWithValue(auth),
      desktopNotifierProvider.overrideWithValue(notifier),
      desktopNotificationServiceProvider.overrideWithValue(notifications),
      if (overStore != null) setupStoreProvider.overrideWithValue(overStore),
    ]);
    addTearDown(container.dispose);
  }

  setUp(() async {
    support = await Directory.systemTemp.createTemp('bond-flow');
    db = testDb();
    store = SetupStore(db);
    manifest = testManifest();
    system = FakeSystemInfo()
      ..hardwareInfo = const HardwareInfo(
        chip: 'Apple M3 Max',
        memoryBytes: 68719476736,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      )
      ..free = 200 * 1024 * 1024 * 1024;
    auth = FakeAuthSession(signedIn: true);
    notifier = FakeDesktopNotifier();
    runner = FakeProcessRunner();
    settles = StreamController<MessageSettled>.broadcast();
    notifications = DesktopNotificationService(
      events: settles.stream,
      notifier: notifier,
      enabled: () => false,
    );
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: support,
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => manifest.toPreset(folder()),
      routerPort: () => 8080,
      onPortMoved: (_) async {},
      // Off, so Finish's fire-and-forget `ensureRunning` is the no-op it is
      // in a hand-servers build. Finish writes no preference about it since
      // Round H: the build define decides, and the wizard's callback is a
      // no-op closure until Phase 7 deletes it.
      managed: () => false,
    );

    // The set, already here: a ledger saying done and three files on disk.
    var ledger = DownloadLedger.empty;
    for (final model in manifest.models) {
      final file = File(p.join(folder(), model.relativePath));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(model.sizeBytes, 7));
      ledger = ledger.record(FileDownloadState(
        id: model.id,
        status: DownloadStatus.done,
        receivedBytes: model.sizeBytes,
        totalBytes: model.sizeBytes,
        sha256: model.sha256,
      ));
    }
    await store.recordDownload(ledger);

    makeContainer();
  });

  tearDown(() async {
    notifications.dispose();
    await settles.close();
    await supervisor.dispose();
    await db.close();
    if (support.existsSync()) await support.delete(recursive: true);
  });

  var finishes = 0;

  /// Three bare pumps — the idiom this suite uses wherever an indeterminate
  /// progress indicator can be on screen and `pumpAndSettle` would never
  /// return.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester) async {
    finishes = 0;
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SetupFlow(onFinished: () => finishes++),
      ),
    ));
    await settle(tester);
  }

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(SetupFlow.continueKey));
    await tester.tap(find.byKey(SetupFlow.continueKey));
    await settle(tester);
  }

  /// Whether the way forward is available. Disabled rather than absent on a
  /// wizard, so the step never reads as a dead end.
  bool continueEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(SetupFlow.continueKey)).onPressed !=
      null;

  /// The arrow itself, not the tooltip wrapped around it — `byTooltip` finds
  /// the wrapper, and the disabled state lives on the button.
  bool backEnabled(WidgetTester tester) => tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_back),
          )
          .onPressed !=
      null;

  testWidgets('the whole walk, welcome to finish', (tester) async {
    await mount(tester);

    // 1 — Welcome. Nowhere to go back to, and the button says so.
    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('Step 1 of 9'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
    expect(backEnabled(tester), isFalse);

    await tapContinue(tester);

    // 2 — Your Mac.
    expect(find.text('Your Mac'), findsOneWidget);
    expect(find.text('Step 2 of 9'), findsOneWidget);
    expect(find.text('Apple M3 Max'), findsOneWidget);
    expect(find.text('64.0 GB'), findsOneWidget);
    expect(backEnabled(tester), isTrue);
    expect(await store.get(SetupStore.setupKey), 'device');

    await tapContinue(tester);

    // 3 — Where the models run. Both cards, nothing chosen, no way forward
    // until one of them is pressed.
    expect(find.text('Where the models run'), findsOneWidget);
    expect(find.text('Step 3 of 9'), findsOneWidget);
    expect(find.byKey(SetupWhereBody.boxCardKey), findsOneWidget);
    expect(find.byKey(SetupWhereBody.localCardKey), findsOneWidget);
    expect(continueEnabled(tester), isFalse);
    expect(await store.get(SetupStore.setupKey), 'where');

    await tester.tap(find.byKey(SetupWhereBody.localCardKey));
    await settle(tester);
    await tapContinue(tester);

    // 4 — Models. This Mac, so all three.
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Step 4 of 9'), findsOneWidget);
    expect(find.text('Finds related messages'), findsOneWidget);

    await tapContinue(tester);

    // 5 — Storage. Everything is already here, so there is nothing to fit.
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Step 5 of 9'), findsOneWidget);
    expect(find.text(folder()), findsOneWidget);
    expect(find.text('All models are already in this folder.'), findsOneWidget);

    await tapContinue(tester);

    // 6 — Download. A seeded set starts no run at all.
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Step 6 of 9'), findsOneWidget);
    expect(find.text('All models are on this Mac.'), findsOneWidget);
    expect(find.text('Ready'), findsNWidgets(3));

    await tapContinue(tester);

    // 7 — Sign in. Already signed in, so one sentence and a Continue.
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Step 7 of 9'), findsOneWidget);
    expect(find.text("You're signed in."), findsOneWidget);
    expect(find.text('Bond Inbox'), findsNothing);

    await tapContinue(tester);

    // 8 — Notifications. The press is the ask.
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Step 8 of 9'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    expect(notifier.authorizeCalls, 0);

    await tapContinue(tester);

    expect(notifier.authorizeCalls, 1);

    // 9 — All set.
    expect(find.text('All set'), findsOneWidget);
    expect(find.text('Step 9 of 9'), findsOneWidget);
    expect(find.text('Bond is ready.'), findsOneWidget);
    expect(find.text(folder()), findsOneWidget);
    expect(find.text('Bond runs it on port 8080'), findsOneWidget);
    expect(find.text('Jared'), findsOneWidget);
    expect(find.text('on'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);
    // The step recorded on ARRIVAL here is the one before it. `done` is the
    // gate's sentinel and only Finish writes it, so a quit on this screen
    // resumes on Notifications rather than letting the next launch past the
    // gate with the managed server still off.
    expect(await store.get(SetupStore.setupKey), 'notifications');

    await tapContinue(tester);

    expect(finishes, 1);
    expect(await store.get(SetupStore.setupKey), 'done');
    // Not written by Finish: the build define decides, and the suite runs
    // without the hand-servers define, so the constant answers true.
    expect(container.read(appPrefsProvider).managedServer, managedServerDefault);
  });

  testWidgets('a 16 GB Mac is told what it gets, and offered two models',
      (tester) async {
    // The same walk on the other rung. The wizard reads the machine at the
    // device step and hands the RESOLVED manifest to every step after it.
    system.hardwareInfo = const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 17179869184,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    await mount(tester);
    await tapContinue(tester);

    expect(find.text('16.0 GB'), findsOneWidget);
    expect(
      find.textContaining('is not downloaded here'),
      findsOneWidget,
    );

    await tapContinue(tester);
    await tester.tap(find.byKey(SetupWhereBody.localCardKey));
    await settle(tester);
    await tapContinue(tester);

    expect(find.text('Models'), findsOneWidget);
    expect(find.textContaining('Bond downloads two models'), findsOneWidget);
    expect(find.text('Writes drafts and replies'), findsNothing);
  });

  testWidgets('signed out, the sign-in step is the only way past itself',
      (tester) async {
    // The fixture's flag is public so a test can be the other person: a
    // keychain with nothing in it yet, which is what a real first run has.
    auth.signedIn = false;

    await mount(tester);
    await tapContinue(tester);
    await tapContinue(tester);
    await tester.tap(find.byKey(SetupWhereBody.localCardKey));
    await settle(tester);
    for (var step = 0; step < 4; step++) {
      await tapContinue(tester);
    }

    expect(find.text('Step 7 of 9'), findsOneWidget);
    expect(
      find.text('Sign in to your Bond workspace to read your mail.'),
      findsOneWidget,
    );
    // No Continue at all: signing in is what advances the step, and a button
    // beside it would offer a way past the one thing this step is for.
    expect(find.byKey(SetupFlow.continueKey), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);

    // Signing in advances rather than re-probing: the session answered a
    // microsecond ago.
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Step 8 of 9'), findsOneWidget);
    expect(auth.signIns, 1);
  });

  testWidgets('a Finish that cannot be saved keeps the step and says so',
      (tester) async {
    makeContainer(overStore: _UnwritableStore(db));
    await mount(tester);
    await tapContinue(tester);
    await tapContinue(tester);
    await tester.tap(find.byKey(SetupWhereBody.localCardKey));
    await settle(tester);
    for (var step = 0; step < 6; step++) {
      await tapContinue(tester);
    }
    expect(find.text('All set'), findsOneWidget);

    await tapContinue(tester);

    // The wizard does not hand over an inbox whose setup is not on disk: the
    // gate would only show the flow again, from the top.
    expect(finishes, 0);
    expect(find.text('All set'), findsOneWidget);
    expect(
      find.text('Setup could not be saved. Try Finish again.'),
      findsOneWidget,
    );
  });

  testWidgets('Back walks the steps in reverse and persists as it goes',
      (tester) async {
    await mount(tester);
    await tapContinue(tester);
    await tapContinue(tester);
    expect(find.text('Step 3 of 9'), findsOneWidget);
    expect(find.text('Where the models run'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await settle(tester);

    expect(find.text('Your Mac'), findsOneWidget);
    expect(await store.get(SetupStore.setupKey), 'device');

    await tester.tap(find.byTooltip('Back'));
    await settle(tester);

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(backEnabled(tester), isFalse);
    expect(await store.get(SetupStore.setupKey), 'welcome');
  });

  group('Where the models run', () {
    /// The wizard with a REAL prefs notifier over an in-memory keychain, so
    /// the box choice can be followed all the way to the placement, the
    /// address and the key it writes. `appPrefsProvider` builds a
    /// `SecureTokenStore`, which throws under `flutter test`.
    ///
    /// [initial] is how a case says which install this is. `boxUrlDefault` is
    /// empty under `flutter test`, so `defaultModelPlacement` reads local
    /// across the suite and a case that wants the compiled-address build says
    /// so with `AppPrefs(modelPlacement: box, boxUrl: …)`.
    late MemoryTokenStore tokens;
    late AppPrefsNotifier prefs;

    void makeWithPrefs({
      Future<ModelProbeResult> Function(String url, {String? bearer})? probe,
      AppPrefs? initial,
    }) {
      tokens = MemoryTokenStore();
      // Disposed by the container that owns the override, not here.
      prefs =
          AppPrefsNotifier(MessageStore(db), initial: initial, tokens: tokens);
      container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        appPathsProvider.overrideWithValue(AppPaths(support)),
        modelManifestProvider.overrideWithValue(manifest),
        systemInfoProvider.overrideWithValue(system),
        modelServerSupervisorProvider.overrideWithValue(supervisor),
        authSessionProvider.overrideWithValue(auth),
        desktopNotifierProvider.overrideWithValue(notifier),
        desktopNotificationServiceProvider.overrideWithValue(notifications),
        appPrefsProvider.overrideWith((_) => prefs),
        if (probe != null)
          setupControllerProvider.overrideWith((ref) => SetupController(
                store: ref.watch(setupStoreProvider),
                system: system,
                manifest: manifest,
                downloader: ref.watch(modelDownloaderProvider),
                supervisor: supervisor,
                paths: AppPaths(support),
                readPrefs: () => prefs.state,
                // Nothing to write: whether the app runs its own server is a
                // build define now, exactly as the provider wires it.
                setManagedServer: (_) async {},
                setModelsFolder: prefs.setModelsFolder,
                applyTierDefaults: prefs.applyTierDefaults,
                probe: probe,
                useBox: ({
                  required baseUrl,
                  required key,
                  required hardwareTier,
                }) =>
                    prefs.useBoxOrigin(
                      baseUrl: baseUrl,
                      key: key,
                      hardwareTier: hardwareTier,
                    ),
                usePlacement: (placement, {required hardwareTier}) => prefs
                    .usePlacement(placement, hardwareTier: hardwareTier),
                auth: () => auth,
                notifier: notifier,
                seedAuthorization: (_) {},
              )),
      ]);
      addTearDown(container.dispose);
    }

    /// Welcome, Your Mac, and there.
    Future<void> reachWhere(WidgetTester tester) async {
      await mount(tester);
      await tapContinue(tester);
      await tapContinue(tester);
      expect(find.text('Where the models run'), findsOneWidget);
    }

    testWidgets('both cards say what they mean, and neither is chosen',
        (tester) async {
      await reachWhere(tester);

      expect(find.text(SetupWhereBody.boxTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.boxBlurb), findsOneWidget);
      expect(find.text(SetupWhereBody.localTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.localBlurb), findsOneWidget);
      // The three controls belong to the box and are not up until it is
      // picked.
      expect(find.byKey(SetupWhereBody.urlKey), findsNothing);
      expect(find.byKey(SetupWhereBody.keyFieldKey), findsNothing);
      expect(continueEnabled(tester), isFalse);
    });

    testWidgets('the box card reveals the address, the key and Check server',
        (tester) async {
      await reachWhere(tester);

      await tester.tap(find.byKey(SetupWhereBody.boxCardKey));
      await settle(tester);

      expect(find.byKey(SetupWhereBody.urlKey), findsOneWidget);
      expect(find.byKey(SetupWhereBody.keyFieldKey), findsOneWidget);
      expect(find.byKey(SetupWhereBody.checkKey), findsOneWidget);
      expect(find.text('Box address'), findsOneWidget);
      expect(find.text('Access key'), findsOneWidget);
      expect(find.text('https://box.example.com'), findsOneWidget);
      // The key field hides what is typed into it.
      expect(
        tester
            .widget<TextField>(find.byKey(SetupWhereBody.keyFieldKey))
            .obscureText,
        isTrue,
      );
    });

    testWidgets('neither field alone opens the way forward', (tester) async {
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.boxCardKey));
      await settle(tester);
      expect(continueEnabled(tester), isFalse);

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com',
      );
      await settle(tester);
      expect(continueEnabled(tester), isFalse,
          reason: 'an address with no key adopts a box that will refuse');

      await tester.enterText(find.byKey(SetupWhereBody.keyFieldKey), 'k');
      await settle(tester);
      expect(continueEnabled(tester), isTrue);
    });

    testWidgets(
        'the box card is chosen on a fresh install with a compiled address, '
        'and the way forward waits for the key', (tester) async {
      // What a build carrying `BOND_BOX_URL` really has on a first run: the
      // placement default is the box and the address is the compiled one.
      makeWithPrefs(
        initial: const AppPrefs(
          modelPlacement: ModelPlacement.box,
          boxBigUrl: 'https://box.example.com/prose/v1/chat/completions',
          boxSmallUrl: 'https://box.example.com/bulk/v1/chat/completions',
        ),
      );
      await reachWhere(tester);

      // Chosen, so the three controls are up and the address is filled.
      expect(find.byKey(SetupWhereBody.urlKey), findsOneWidget);
      expect(find.byKey(SetupWhereBody.checkKey), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(SetupWhereBody.urlKey))
            .controller!
            .text,
        'https://box.example.com',
      );
      // And the question the card did NOT answer is still open.
      expect(continueEnabled(tester), isFalse,
          reason: 'a preselected box still waits for the key');

      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await settle(tester);
      expect(continueEnabled(tester), isTrue);
    });

    testWidgets('Check server reports both models', (tester) async {
      final asked = <(String, String?)>[];
      makeWithPrefs(probe: (url, {bearer}) async {
        asked.add((url, bearer));
        // The writing slot answers and the inbox slot does not, which is the
        // whole reason one press asks both.
        return url.contains('/prose/')
            ? const ModelProbeResult(reachable: true, modelIds: ['qwen3.8'])
            : const ModelProbeResult(
                reachable: false,
                error: 'Not reachable',
              );
      });
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.boxCardKey));
      await settle(tester);
      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com',
      );
      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await settle(tester);

      await tester.tap(find.byKey(SetupWhereBody.checkKey));
      await settle(tester);

      // Both slots, the writing one first, each with the typed key.
      expect(asked, [
        (
          'https://box.example.com/prose/v1/chat/completions',
          'sk-fixture-not-a-real-box-key',
        ),
        (
          'https://box.example.com/bulk/v1/chat/completions',
          'sk-fixture-not-a-real-box-key',
        ),
      ]);
      expect(find.text(SetupWhereBody.proseProbeLabel), findsOneWidget);
      expect(find.text(SetupWhereBody.bulkProbeLabel), findsOneWidget);
      expect(find.byType(ProbeStatus), findsNWidgets(2));
      expect(find.text('Reachable · 1 model'), findsOneWidget);
      expect(find.text('Not reachable'), findsOneWidget);
    });

    testWidgets(
        'the box choice writes the placement and the key and the next step '
        'lists ONE model', (tester) async {
      makeWithPrefs();
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.boxCardKey));
      await settle(tester);
      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com',
      );
      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await settle(tester);

      await tapContinue(tester);

      // The placement, the address, and the key in the keychain under BOTH
      // derived ids rather than in a preference.
      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.effectiveBoxBigUrl,
          'https://box.example.com/prose/v1/chat/completions');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'],
          'sk-fixture-not-a-real-box-key');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxBulkId'],
          'sk-fixture-not-a-real-box-key');
      // Derived, not stored: nothing in the target list, nothing in the stage
      // map, and the two specs resolved from the one address.
      expect(prefs.state.targets, isEmpty);
      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.state.boxProseSpec.url,
          'https://box.example.com/prose/v1/chat/completions');
      expect(prefs.state.boxBulkSpec.url,
          'https://box.example.com/bulk/v1/chat/completions');
      expect(prefs.state.draftPolicy, DraftPolicy.needsYou);

      // And the models step is about what THIS Mac downloads, which on the
      // box placement is the embedding model alone.
      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Step 4 of 9'), findsOneWidget);
      expect(find.text('Test Embed'), findsOneWidget);
      expect(find.text('Test Bulk'), findsNothing);
      expect(find.text('Test Prose'), findsNothing);
    });

    testWidgets('an address with no scheme is refused and nothing is written',
        (tester) async {
      makeWithPrefs();
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.boxCardKey));
      await settle(tester);
      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'box.example.com',
      );
      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await settle(tester);

      // The button stays live, so the press can say why it is refused.
      expect(continueEnabled(tester), isTrue);
      await tapContinue(tester);

      expect(find.text(SetupWhereBody.addressRefusalText), findsOneWidget);
      expect(find.text('Where the models run'), findsOneWidget,
          reason: 'a refused address does not advance the wizard');
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.boxBigUrl, isEmpty);
      expect(tokens.values, isEmpty);

      // Typing clears it.
      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com',
      );
      await settle(tester);
      expect(find.text(SetupWhereBody.addressRefusalText), findsNothing);
    });

    testWidgets('this Mac writes local and the next step lists three',
        (tester) async {
      makeWithPrefs();
      await reachWhere(tester);

      await tester.tap(find.byKey(SetupWhereBody.localCardKey));
      await settle(tester);
      await tapContinue(tester);

      // No key and nothing stored: on a first run `usePlacement` finds no
      // entry the app wrote, and what it leaves is a fresh install with this
      // machine's tier defaults applied.
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.targets, isEmpty);
      expect(tokens.values, isEmpty);

      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Test Embed'), findsOneWidget);
      expect(find.text('Test Bulk'), findsOneWidget);
      expect(find.text('Test Prose'), findsOneWidget);
    });

    testWidgets('a box install that chooses This Mac keeps the address and '
        'the key', (tester) async {
      makeWithPrefs();
      // The install this wizard is re-entered on: the address, the key in the
      // keychain and the placement.
      await prefs.useBoxOrigin(
        baseUrl: 'https://box.example.com',
        key: 'sk-fixture-not-a-real-box-key',
        hardwareTier: MachineTier.full,
      );
      expect(prefs.state.modelPlacement, ModelPlacement.box);

      await reachWhere(tester);
      // The stored answer is seeded, so the box card opens chosen, and the
      // stored key answers the empty field: Continue is live without a second
      // paste, and the field says why.
      expect(continueEnabled(tester), isTrue,
          reason: 'a key already in the keychain answers the field');
      expect(find.text(SetupWhereBody.keyStoredHint), findsOneWidget);

      await tester.tap(find.byKey(SetupWhereBody.localCardKey));
      await settle(tester);
      await tapContinue(tester);

      // The work moves here, and the way back is not thrown away: changing
      // where the models run is not forgetting how to reach the box.
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.state.boxBigUrl,
          'https://box.example.com/prose/v1/chat/completions');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'],
          'sk-fixture-not-a-real-box-key');

      // And the models step is about this Mac again.
      expect(find.text('Test Prose'), findsOneWidget);
    });

    testWidgets('a box install re-entered continues with the field blank and '
        'keeps its key', (tester) async {
      makeWithPrefs();
      await prefs.useBoxOrigin(
        baseUrl: 'https://box.example.com',
        key: 'sk-fixture-not-a-real-box-key',
        hardwareTier: MachineTier.full,
      );

      await reachWhere(tester);
      await tapContinue(tester);

      // Still the box, still the same key under both ids, and the models
      // step is the box's one model.
      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.boxBigUrl,
          'https://box.example.com/prose/v1/chat/completions');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'],
          'sk-fixture-not-a-real-box-key');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxBulkId'],
          'sk-fixture-not-a-real-box-key');
      expect(find.text('Test Prose'), findsNothing);
    });

    testWidgets('a quit on this step resumes here, having adopted nothing',
        (tester) async {
      makeWithPrefs();
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.boxCardKey));
      await settle(tester);

      // The step is recorded on ARRIVAL, and the choice is not.
      expect(await store.get(SetupStore.setupKey), 'where');
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.targets, isEmpty);
    });
  });

  testWidgets('the pane carries the step title and the counter', (tester) async {
    await mount(tester);

    // One pane, not eight screens: the title and the count are the chrome,
    // and the step is what changes inside it.
    expect(find.byType(PaneSurface), findsOneWidget);
    expect(find.text(SetupStep.welcome.title), findsOneWidget);
  });
}
