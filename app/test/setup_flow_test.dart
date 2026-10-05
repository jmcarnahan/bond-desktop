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

    // 3 — Where the models run. Two roles, each with two cards; the
    // decision model opens on This Mac and the generative model on Your
    // server, whose form's own press is the way forward. This walk picks
    // This Mac, and the step's Continue comes up live.
    expect(find.text('Where the models run'), findsOneWidget);
    expect(find.text('Step 3 of 9'), findsOneWidget);
    expect(find.byKey(SetupWhereBody.managedCardKey), findsOneWidget);
    expect(find.byKey(SetupWhereBody.customCardKey), findsOneWidget);
    expect(find.byKey(SetupWhereBody.decisionManagedCardKey), findsOneWidget);
    expect(find.byKey(SetupWhereBody.decisionCustomCardKey), findsOneWidget);
    expect(find.byKey(SetupFlow.continueKey), findsNothing);
    expect(await store.get(SetupStore.setupKey), 'where');

    await tester.tap(find.byKey(SetupWhereBody.managedCardKey));
    await settle(tester);
    expect(continueEnabled(tester), isTrue);
    await tapContinue(tester);

    // 4 — Models. This Mac: the embedding model and the one generative model.
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
    expect(find.text('Ready'), findsNWidgets(2));

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
    // The 4B is this Mac's generative model; the 27B is not offered.
    expect(find.text('Test Prose'), findsNothing);
    expect(find.text('Writes summaries, drafts and storylines'),
        findsOneWidget);
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
    /// a choice can be followed all the way to the placement, the address
    /// and the key it writes. `appPrefsProvider` builds a `SecureTokenStore`,
    /// which throws under `flutter test`.
    ///
    /// [initial] is how a case says which install this is. The generative
    /// model opens on Your server whatever the build (`defaultModelPlacement`),
    /// with an empty address because `boxUrlDefault` is empty under `flutter
    /// test`; a case about This Mac taps its card first, as a person would,
    /// and a case that wants the compiled-address build says so with
    /// `AppPrefs(modelPlacement: box, boxBigUrl: …)`.
    late MemoryTokenStore tokens;
    late AppPrefsNotifier prefs;

    const generativeUrl = 'https://box.example.com/prose/v1/chat/completions';
    const decisionUrl = 'https://box.example.com/decide/v1/embeddings';
    const key = 'sk-fixture-not-a-real-box-key';

    const gen = ServerFormRole.generative;
    const dec = ServerFormRole.decision;

    /// What Connect asked, with the bearer it was handed. A fake's record of
    /// a fixture string, never a real key.
    late List<(String, String?)> asked;

    /// Servers answering one id each: the writing model, or the decision
    /// model on an embeddings address.
    Future<ModelProbeResult> servers(String url, {String? bearer}) async {
      asked.add((url, bearer));
      return url.endsWith('/embeddings')
          ? const ModelProbeResult(reachable: true, modelIds: ['bond-decide-x'])
          : const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']);
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
                probe: probe,
                storedBearer: prefs.bearerFor,
                useGenerative: prefs.useGenerative,
                useDecision: prefs.useDecision,
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

    Future<void> tapKey(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.tap(find.byKey(key));
      await settle(tester);
    }

    /// The install this wizard is re-entered on: the generative remote with
    /// its discovered name and its key in the keychain.
    Future<void> seedUserDefined() => prefs.useGenerative(
          placement: ModelPlacement.box,
          url: generativeUrl,
          model: 'qwen3.8',
          key: key,
          hardwareTier: MachineTier.full,
        );

    testWidgets('both roles say what they mean: the decision model opens on '
        'This Mac, the generative model on Your server', (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);

      expect(find.text(SetupWhereBody.decisionTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.generativeTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.managedBlurb), findsOneWidget);
      expect(find.text(SetupWhereBody.customBlurb), findsOneWidget);
      expect(find.text(SetupWhereBody.decisionManagedBlurb), findsOneWidget);
      expect(find.text(SetupWhereBody.decisionCustomBlurb), findsOneWidget);
      // Each role recommends its own default: the decision model this Mac,
      // the generative model Your server.
      expect(find.text(SetupWhereBody.managedTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.customTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.generativeCustomTitle), findsOneWidget);
      expect(find.text(SetupWhereBody.generativeManagedTitle), findsOneWidget);
      // The generative form is open on an empty address, and its press is the
      // way forward; the decision form waits for its card.
      expect(find.byKey(ModelServersForm.urlKey(gen)), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.urlKey(gen)))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.byKey(ModelServersForm.urlKey(dec)), findsNothing);
      expect(find.byKey(SetupWhereBody.generativeModelKey), findsNothing);
      expect(find.byKey(SetupFlow.continueKey), findsNothing);

      // This Mac: the managed choice comes up, on the 27B for a full Mac.
      await tapKey(tester, SetupWhereBody.managedCardKey);
      expect(find.byKey(ModelServersForm.urlKey(gen)), findsNothing);
      expect(find.byKey(SetupWhereBody.generativeModelKey), findsOneWidget);
      expect(continueEnabled(tester), isTrue);
    });

    testWidgets('Your server for the generative model reveals the form, whose '
        'Continue is the way forward', (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);

      await tapKey(tester, SetupWhereBody.customCardKey);

      expect(find.byKey(ModelServersForm.urlKey(gen)), findsOneWidget);
      expect(find.byKey(ModelServersForm.keyKey(gen)), findsOneWidget);
      // ONE press, and it is the form's.
      expect(
        find.descendant(
          of: find.byKey(ModelServersForm.connectKey(gen)),
          matching: find.text('Continue'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(SetupFlow.continueKey), findsNothing);
      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.keyKey(gen)))
            .obscureText,
        isTrue,
      );
      expect(find.text(ModelServersForm.storedHint), findsNothing);
    });

    testWidgets('a compiled address preselects Your server with the address '
        'filled', (tester) async {
      makeWithPrefs(
        probe: servers,
        initial: const AppPrefs(
          modelPlacement: ModelPlacement.box,
          boxBigUrl: generativeUrl,
        ),
      );
      await reachWhere(tester);

      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.urlKey(gen)))
            .controller!
            .text,
        generativeUrl,
      );
      expect(
        tester.widget<TextField>(find.byKey(ModelServersForm.keyKey(gen)))
            .controller!
            .text,
        isEmpty,
      );
      // The decision model still defaults to this Mac.
      expect(find.byKey(ModelServersForm.urlKey(dec)), findsNothing);
      expect(find.byKey(SetupFlow.continueKey), findsNothing);
    });

    testWidgets('Continue on This Mac writes both roles local and the next '
        'step lists this Mac\'s models', (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.managedCardKey);

      await tapContinue(tester);

      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.decisionPlacement, ModelPlacement.local);
      expect(tokens.values, isEmpty);

      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Test Embed'), findsOneWidget);
      expect(find.text('Test Bulk'), findsNothing);
      expect(find.text('Test Prose'), findsOneWidget);
    });

    testWidgets('choosing the 4B downloads the 4B instead of the 27B',
        (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.managedCardKey);

      await tester.tap(find.descendant(
        of: find.byKey(SetupWhereBody.generativeModelKey),
        matching: find.text(SetupWhereBody.model4bLabel),
      ));
      await settle(tester);
      await tapContinue(tester);

      expect(prefs.state.generativeManagedModel, routerBulkId);
      expect(find.text('Test Bulk'), findsOneWidget);
      expect(find.text('Test Prose'), findsNothing);
    });

    testWidgets('Continue on Your server asks the server, takes the name it '
        'lists, writes the address and the key, and lists ONE model',
        (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.customCardKey);
      await tester.enterText(
          find.byKey(ModelServersForm.urlKey(gen)), generativeUrl);
      await tester.enterText(find.byKey(ModelServersForm.keyKey(gen)), key);
      await settle(tester);

      await tapKey(tester, ModelServersForm.connectKey(gen));

      expect(asked, [(generativeUrl, key)]);
      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(prefs.state.boxBigUrl, generativeUrl);
      expect(prefs.state.effectiveGenerativeModel, 'qwen3.8');
      expect(tokens.values.keys, ['$llmTargetBearerKeyPrefix$boxProseId']);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(prefs.state.draftPolicy, DraftPolicy.needsYou);
      expect(prefs.state.decisionPlacement, ModelPlacement.local);

      expect(find.text('Step 4 of 9'), findsOneWidget);
      expect(find.text('Test Embed'), findsOneWidget);
      expect(find.text('Test Bulk'), findsNothing);
      expect(find.text('Test Prose'), findsNothing);
    });

    testWidgets('the decision form connects its role and the step stays',
        (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      // The generative model on This Mac, so the step's own Continue is the
      // way forward this case reads.
      await tapKey(tester, SetupWhereBody.managedCardKey);

      await tapKey(tester, SetupWhereBody.decisionCustomCardKey);
      // Not connected yet: the step's Continue waits for it.
      expect(continueEnabled(tester), isFalse);
      expect(find.text(SetupController.decisionFirstText), findsOneWidget);

      await tester.enterText(
          find.byKey(ModelServersForm.urlKey(dec)), decisionUrl);
      await tester.enterText(find.byKey(ModelServersForm.keyKey(dec)), key);
      await settle(tester);
      expect(
        find.descendant(
          of: find.byKey(ModelServersForm.connectKey(dec)),
          matching: find.text('Connect'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, ModelServersForm.connectKey(dec));

      expect(asked, [(decisionUrl, key)]);
      expect(prefs.state.decisionPlacement, ModelPlacement.box);
      expect(prefs.state.decisionSpec.url, decisionUrl);
      expect(prefs.state.decisionSpec.model, 'bond-decide-x');
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxDecideId'], key);
      expect(find.text('Where the models run'), findsOneWidget);
      expect(find.byKey(SetupWhereBody.decisionConnectedKey), findsOneWidget);

      await tapContinue(tester);
      expect(find.text('Step 4 of 9'), findsOneWidget);
      expect(prefs.state.decisionPlacement, ModelPlacement.box);
    });

    testWidgets('a decision address that is not an embeddings endpoint is '
        'refused under its field', (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.decisionCustomCardKey);
      await tester.enterText(
          find.byKey(ModelServersForm.urlKey(dec)), generativeUrl);
      await settle(tester);

      await tapKey(tester, ModelServersForm.connectKey(dec));

      expect(find.text(ModelServersForm.decisionEndpointRefusalText),
          findsOneWidget);
      expect(asked, isEmpty);
      expect(prefs.state.decisionPlacement, ModelPlacement.local);
    });

    testWidgets('an address with no scheme is refused under its field and '
        'nothing is written', (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.customCardKey);
      await tester.enterText(
          find.byKey(ModelServersForm.urlKey(gen)), 'box.example.com');
      await tester.enterText(find.byKey(ModelServersForm.keyKey(gen)), key);
      await settle(tester);

      await tapKey(tester, ModelServersForm.connectKey(gen));

      expect(find.text(ModelServersForm.addressRefusalText), findsOneWidget);
      expect(find.text('Where the models run'), findsOneWidget,
          reason: 'a refused address does not advance the wizard');
      // Nothing was written: the placement is still the unstored default,
      // which a wrong write of Your server would equal.
      expect(prefs.state.modelPlacement, defaultModelPlacement);
      expect(await MessageStore(db).getPref(modelPlacementKey), isNull);
      expect(prefs.state.boxBigUrl, isEmpty);
      expect(tokens.values, isEmpty);
      expect(asked, isEmpty,
          reason: 'refused before any server was asked anything');

      await tester.enterText(
          find.byKey(ModelServersForm.urlKey(gen)), generativeUrl);
      await settle(tester);
      expect(find.text(ModelServersForm.addressRefusalText), findsNothing);
    });

    testWidgets('a server that does not answer connects nothing',
        (tester) async {
      makeWithPrefs(probe: (url, {bearer}) async {
        asked.add((url, bearer));
        return const ModelProbeResult(reachable: false, error: 'Not reachable');
      });
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.customCardKey);
      await tester.enterText(
          find.byKey(ModelServersForm.urlKey(gen)), generativeUrl);
      await settle(tester);

      await tapKey(tester, ModelServersForm.connectKey(gen));

      expect(find.text('Not reachable'), findsOneWidget);
      expect(prefs.state.boxBigUrl, isEmpty);
      expect(find.text('Where the models run'), findsOneWidget);
      // Nothing was written: the placement is still the unstored default,
      // which a wrong write of Your server would equal.
      expect(prefs.state.modelPlacement, defaultModelPlacement);
      expect(await MessageStore(db).getPref(modelPlacementKey), isNull);
      expect(tokens.values, isEmpty);
    });

    testWidgets('a third-party address is refused with the sentence',
        (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.customCardKey);
      await tester.enterText(find.byKey(ModelServersForm.urlKey(gen)),
          'https://api.openai.com/v1/chat/completions');
      await tester.enterText(find.byKey(ModelServersForm.keyKey(gen)), key);
      await settle(tester);

      await tapKey(tester, ModelServersForm.connectKey(gen));

      expect(find.text(ModelServersForm.thirdPartyRefusalText), findsOneWidget);
      expect(prefs.state.boxBigUrl, isEmpty);
      expect(find.text('Where the models run'), findsOneWidget);
      // Nothing was written: the placement is still the unstored default,
      // which a wrong write of Your server would equal.
      expect(prefs.state.modelPlacement, defaultModelPlacement);
      expect(await MessageStore(db).getPref(modelPlacementKey), isNull);
      expect(tokens.values, isEmpty);
      expect(asked, isEmpty);
      expect(prefs.state.cloudDraftsConsent, isFalse);
    });

    testWidgets('a user-defined install that chooses This Mac keeps the '
        'address and the key', (tester) async {
      makeWithPrefs(probe: servers);
      await seedUserDefined();
      expect(prefs.state.modelPlacement, ModelPlacement.box);

      await reachWhere(tester);
      expect(find.text(ModelServersForm.storedHint), findsOneWidget);

      await tapKey(tester, SetupWhereBody.managedCardKey);
      await tapContinue(tester);

      expect(prefs.state.modelPlacement, ModelPlacement.local);
      expect(prefs.state.boxBigUrl, generativeUrl);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(find.text('Test Prose'), findsOneWidget);
    });

    testWidgets('a user-defined install re-entered continues with the key '
        'field blank and keeps its key', (tester) async {
      makeWithPrefs(probe: servers);
      await seedUserDefined();

      await reachWhere(tester);
      await tapKey(tester, ModelServersForm.connectKey(gen));

      // The stored key rode the request, looked up by id at the press.
      expect(asked, [(generativeUrl, key)]);
      expect(prefs.state.modelPlacement, ModelPlacement.box);
      expect(tokens.values['$llmTargetBearerKeyPrefix$boxProseId'], key);
      expect(find.text('Step 4 of 9'), findsOneWidget);
    });

    testWidgets('a new host with the key field blank forgets the old key',
        (tester) async {
      makeWithPrefs(probe: servers);
      await seedUserDefined();

      await reachWhere(tester);
      const other = 'https://other.example.com/v1/chat/completions';
      await tester.enterText(find.byKey(ModelServersForm.urlKey(gen)), other);
      await settle(tester);
      await tapKey(tester, ModelServersForm.connectKey(gen));

      // The old host's key never rode to the new one, and it is gone.
      expect(asked, [(other, null)]);
      expect(prefs.state.boxBigUrl, other);
      expect(tokens.values, isEmpty);
      expect(prefs.state.boxBigKeyStored, isFalse);
    });

    testWidgets('a quit on this step resumes here, having adopted nothing',
        (tester) async {
      makeWithPrefs(probe: servers);
      await reachWhere(tester);
      await tapKey(tester, SetupWhereBody.customCardKey);

      expect(await store.get(SetupStore.setupKey), 'where');
      // Nothing was written: the placement is still the unstored default,
      // which a wrong write of Your server would equal.
      expect(prefs.state.modelPlacement, defaultModelPlacement);
      expect(await MessageStore(db).getPref(modelPlacementKey), isNull);
      expect(prefs.state.boxBigUrl, isEmpty);
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
