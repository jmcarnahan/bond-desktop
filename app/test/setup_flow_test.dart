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
import 'package:bond_inbox/widgets/model_servers_form.dart';
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
      // Round H: the build define decides.
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
    expect(find.byKey(SetupWhereBody.managedCardKey), findsOneWidget);
    expect(find.byKey(SetupWhereBody.customCardKey), findsOneWidget);
    expect(continueEnabled(tester), isFalse);
    expect(await store.get(SetupStore.setupKey), 'where');

    await tester.tap(find.byKey(SetupWhereBody.managedCardKey));
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
    // gate with no wizard left to walk.
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
    await tester.tap(find.byKey(SetupWhereBody.managedCardKey));
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
    await tester.tap(find.byKey(SetupWhereBody.managedCardKey));
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
    await tester.tap(find.byKey(SetupWhereBody.managedCardKey));
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
    /// so with `AppPrefs(modelPlacement: box, boxBigUrl: …, boxSmallUrl: …)`.
    late MemoryTokenStore tokens;
    late AppPrefsNotifier prefs;

    /// The user-defined pair, and the fictional string this group types into
    /// the key field.
    const bigUrl = 'https://box.example.com/prose/v1/chat/completions';
    const smallUrl = 'https://box.example.com/bulk/v1/chat/completions';
    const key = 'sk-fixture-not-a-real-box-key';

    /// What Connect asked, with the bearer it was handed. A fake's record of
    /// a fixture string, never a real key.
    late List<(String, String?)> asked;

    /// Two servers answering, one id each, which is what a fresh User defined
    /// install sees: the big address lists the writing model and the small
    /// one the inbox model.
    Future<ModelProbeResult> twoServers(String url, {String? bearer}) async {
      asked.add((url, bearer));
      return url.contains('/prose/')
          ? const ModelProbeResult(reachable: true, modelIds: ['qwen3.8'])
          : const ModelProbeResult(reachable: true, modelIds: ['qwen3-4b']);
    }

    void makeWithPrefs({
      Future<ModelProbeResult> Function(String url, {String? bearer})? probe,
      AppPrefs? initial,
    }) {
      asked = [];
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
                setModelsFolder: prefs.setModelsFolder,
                applyTierDefaults: prefs.applyTierDefaults,
                probe: probe,
                storedBearer: prefs.bearerFor,
                useBox: ({
                  required bigUrl,
                  required smallUrl,
                  required bigModel,
                  required smallModel,
                  bigKey,
                  smallKey,
                  required hardwareTier,
                }) =>
                    prefs.useBox(
                      bigUrl: bigUrl,
                      smallUrl: smallUrl,
                      bigModel: bigModel,
                      smallModel: smallModel,
                      bigKey: bigKey,
                      smallKey: smallKey,
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

    /// The form's own press, which is the way forward under User defined.
    Future<void> tapConnect(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(ModelServersForm.connectKey));
      await tester.tap(find.byKey(ModelServersForm.connectKey));
      await settle(tester);
    }

    /// The install this wizard is re-entered on: both addresses, both
    /// discovered names and the key in the keychain under both ids.
    Future<void> seedUserDefined() => prefs.useBox(
          bigUrl: bigUrl,
          smallUrl: smallUrl,
          bigModel: 'qwen3.8',
          smallModel: 'qwen3-4b',
          bigKey: key,
          smallKey: key,
          hardwareTier: MachineTier.full,
        );

    testWidgets('both cards say what they mean, and neither is chosen',
        (tester) async {
      makeWithPrefs(probe: twoServers);
      await reachWhere(tester);

      expect(find.text(SetupWhereBody.managedTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.managedBlurb), findsOneWidget);
      expect(find.text(SetupWhereBody.customTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.customBlurb), findsOneWidget);
      // The form belongs to User defined and is not up until it is picked.
      expect(find.byKey(ModelServersForm.bigUrlKey), findsNothing);
      expect(continueEnabled(tester), isFalse);
    });

    testWidgets('the User defined card reveals the form, whose Continue is '
        'the way forward', (tester) async {
      makeWithPrefs(probe: twoServers);
      await reachWhere(tester);

      await tester.tap(find.byKey(SetupWhereBody.customCardKey));
      await settle(tester);

      expect(find.byKey(ModelServersForm.bigUrlKey), findsOneWidget);
      expect(find.byKey(ModelServersForm.smallUrlKey), findsOneWidget);
      expect(find.byKey(ModelServersForm.keyKey), findsOneWidget);
      // ONE press, and it is the form's: a second button reading Continue
      // that wrote nothing is the confusion this round removed.
      expect(find.byKey(ModelServersForm.connectKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ModelServersForm.connectKey),
          matching: find.text('Continue'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(SetupFlow.continueKey), findsNothing);
      // The key field hides what is typed into it, and says nothing about a
      // stored key on a fresh install.
      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.keyKey))
            .obscureText,
        isTrue,
      );
      expect(find.text(ModelServersForm.storedHint), findsNothing);
    });

    testWidgets('a compiled address preselects User defined with both fields '
        'filled', (tester) async {
      // What a build carrying `BOND_BOX_URL` really has on a first run: the
      // placement default is the box and both addresses are the compiled
      // ones.
      makeWithPrefs(
        probe: twoServers,
        initial: const AppPrefs(
          modelPlacement: ModelPlacement.box,
          boxBigUrl: bigUrl,
          boxSmallUrl: smallUrl,
        ),
      );
      await reachWhere(tester);

      // Chosen, so the form is up without a tap and both addresses are in it.
      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.bigUrlKey))
            .controller!
            .text,
        bigUrl,
      );
      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.smallUrlKey))
            .controller!
            .text,
        smallUrl,
      );
      // The one thing a compiled address does not answer.
      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.keyKey))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.byKey(SetupFlow.continueKey), findsNothing);
    });

    testWidgets('Continue on Managed writes local and the next step lists '
        'three', (tester) async {
      makeWithPrefs(probe: twoServers);
      await reachWhere(tester);

      await tester.tap(find.byKey(SetupWhereBody.managedCardKey));
      await settle(tester);
      expect(continueEnabled(tester), isTrue);
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

    testWidgets('Continue on User defined asks both servers, takes the names '
        'they list, writes the pair and the key under both ids, and lists '
        'ONE model', (tester) async {
      makeWithPrefs(probe: twoServers);
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.customCardKey));
      await settle(tester);
      await tester.enterText(find.byKey(ModelServersForm.bigUrlKey), bigUrl);
      await tester.enterText(
          find.byKey(ModelServersForm.smallUrlKey), smallUrl);
      await tester.enterText(find.byKey(ModelServersForm.keyKey), key);
      await settle(tester);

      await tapConnect(tester);

      // Both servers, the big one first, each with the typed key.
      expect(asked, [(bigUrl, key), (smallUrl, key)]);
      // The placement, the pair, the two names the servers listed, and the
      // key in the keychain under BOTH derived ids rather than a preference.
      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.boxBigUrl, bigUrl);
      expect(prefs.state.boxSmallUrl, smallUrl);
      expect(prefs.state.effectiveBoxBigModel, 'qwen3.8');
      expect(prefs.state.effectiveBoxSmallModel, 'qwen3-4b');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxBulkId'], key);
      // Derived, not stored: nothing in the target list and nothing in the
      // stage map.
      expect(prefs.state.targets, isEmpty);
      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.state.draftPolicy, DraftPolicy.needsYou);

      // And the models step is about what THIS Mac downloads, which under
      // User defined is the embedding model alone.
      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Step 4 of 9'), findsOneWidget);
      expect(find.text('Test Embed'), findsOneWidget);
      expect(find.text('Test Bulk'), findsNothing);
      expect(find.text('Test Prose'), findsNothing);
    });

    testWidgets('an address with no scheme is refused under its field and '
        'nothing is written', (tester) async {
      makeWithPrefs(probe: twoServers);
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.customCardKey));
      await settle(tester);
      await tester.enterText(
          find.byKey(ModelServersForm.bigUrlKey), 'box.example.com');
      await tester.enterText(
          find.byKey(ModelServersForm.smallUrlKey), smallUrl);
      await tester.enterText(find.byKey(ModelServersForm.keyKey), key);
      await settle(tester);

      await tapConnect(tester);

      expect(find.text(ModelServersForm.addressRefusalText), findsOneWidget);
      expect(find.text('Where the models run'), findsOneWidget,
          reason: 'a refused address does not advance the wizard');
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.boxBigUrl, isEmpty);
      expect(tokens.values, isEmpty);
      expect(asked, isEmpty,
          reason: 'refused before any server was asked anything');

      // Typing clears it.
      await tester.enterText(find.byKey(ModelServersForm.bigUrlKey), bigUrl);
      await settle(tester);
      expect(find.text(ModelServersForm.addressRefusalText), findsNothing);
    });

    testWidgets('a server that does not answer connects nothing',
        (tester) async {
      makeWithPrefs(probe: (url, {bearer}) async {
        asked.add((url, bearer));
        return url.contains('/prose/')
            ? const ModelProbeResult(reachable: true, modelIds: ['qwen3.8'])
            : const ModelProbeResult(reachable: false, error: 'Not reachable');
      });
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.customCardKey));
      await settle(tester);
      await tester.enterText(find.byKey(ModelServersForm.bigUrlKey), bigUrl);
      await tester.enterText(
          find.byKey(ModelServersForm.smallUrlKey), smallUrl);
      await tester.enterText(find.byKey(ModelServersForm.keyKey), key);
      await settle(tester);

      await tapConnect(tester);

      expect(find.text('Not reachable'), findsOneWidget);
      expect(find.text('Where the models run'), findsOneWidget);
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(tokens.values, isEmpty);
    });

    testWidgets('a third-party big address is refused with the sentence',
        (tester) async {
      makeWithPrefs(probe: (url, {bearer}) async {
        asked.add((url, bearer));
        return const ModelProbeResult(
            reachable: true, modelIds: ['gpt-fixture']);
      });
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.customCardKey));
      await settle(tester);
      // A vendor's service, which is a Settings decision and not a wizard
      // one: there is no consent pane behind a first run.
      await tester.enterText(find.byKey(ModelServersForm.bigUrlKey),
          'https://api.openai.com/v1/chat/completions');
      await tester.enterText(
          find.byKey(ModelServersForm.smallUrlKey), smallUrl);
      await tester.enterText(find.byKey(ModelServersForm.keyKey), key);
      await settle(tester);

      await tapConnect(tester);

      expect(find.text(ModelServersForm.thirdPartyRefusalText), findsOneWidget);
      expect(find.text('Where the models run'), findsOneWidget);
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.boxBigUrl, isEmpty);
      expect(tokens.values, isEmpty);
      expect(prefs.state.cloudDraftsConsent, isFalse);
    });

    testWidgets('a user-defined install that chooses Managed keeps the '
        'addresses and the key', (tester) async {
      makeWithPrefs(probe: twoServers);
      await seedUserDefined();
      expect(prefs.state.modelPlacement, ModelPlacement.box);

      await reachWhere(tester);
      // The stored answer is seeded, so the form opens filled, and the key
      // field says why it is empty.
      expect(find.text(ModelServersForm.storedHint), findsOneWidget);

      await tester.tap(find.byKey(SetupWhereBody.managedCardKey));
      await settle(tester);
      await tapContinue(tester);

      // The work moves here, and the way back is not thrown away: changing
      // where the models run is not forgetting how to reach the servers.
      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.stageTargets, isEmpty);
      expect(prefs.state.boxBigUrl, bigUrl);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);

      // And the models step is about this Mac again.
      expect(find.text('Test Prose'), findsOneWidget);
    });

    testWidgets('a user-defined install re-entered continues with the key '
        'field blank and keeps its key', (tester) async {
      makeWithPrefs(probe: twoServers);
      await seedUserDefined();

      await reachWhere(tester);
      await tapConnect(tester);

      // The stored key rode both requests, looked up by id at the press.
      expect(asked.map((a) => a.$2), [key, key]);
      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.boxBigUrl, bigUrl);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxBulkId'], key);
      expect(find.text('Step 4 of 9'), findsOneWidget);
      expect(find.text('Test Embed'), findsOneWidget);
      expect(find.text('Test Prose'), findsNothing);
    });

    testWidgets('a quit on this step resumes here, having adopted nothing',
        (tester) async {
      makeWithPrefs(probe: twoServers);
      await reachWhere(tester);
      await tester.tap(find.byKey(SetupWhereBody.customCardKey));
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
