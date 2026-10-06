import 'dart:async';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart' show MessageStore;
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/models/setup_step.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/notification_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart'
    show AppPrefsNotifier, initialAppPrefsProvider, modelPlacementKey;
import 'package:bond_inbox/providers/setup_provider.dart';
import 'package:bond_inbox/screens/setup/setup_gate.dart';
import 'package:bond_inbox/screens/setup/setup_welcome_body.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_downloader.dart';
import 'package:bond_inbox/services/models/model_ensurer.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/notify/desktop_notification_service.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/system/system_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart' show IOClient;

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_desktop_notifier.dart';
import 'fixtures/fake_hub_server.dart';
import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/recording_ensurer.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// A platform that refuses to describe the machine.
class _RefusingSystemInfo extends FakeSystemInfo {
  @override
  Future<HardwareInfo> hardware() async => throw StateError('no channel');
}

/// A platform that never answers at all — the hang, rather than the throw.
class _SilentSystemInfo extends FakeSystemInfo {
  @override
  Future<HardwareInfo> hardware() => Completer<HardwareInfo>().future;
}

/// A store whose reads fail — the unreadable-database case the gate has to
/// survive.
class _UnreadableStore extends SetupStore {
  _UnreadableStore(super.db);

  @override
  Future<String?> get(String key) async => throw StateError('no database');
}

/// Which screen a launch gets, and when that answer is allowed to change.
///
/// The gate answers ONCE, on `AuthGate`'s pattern: a gate that re-decided on
/// every rebuild would swap the whole screen out from under a download. The
/// two things that may change its mind are the flow reporting itself finished
/// and "Set up again" bumping the counter.
///
/// Everything is created in `setUp` — the temp directory, the supervisor, the
/// database — because a `testWidgets` body runs in a fake-async zone where a
/// real filesystem future never completes.
void main() {
  late Directory support;
  late BondDatabase db;
  late SetupStore store;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;
  late StreamController<MessageSettled> settles;
  late DesktopNotificationService notifications;
  late FakeDesktopNotifier notifier;
  late ProviderContainer container;
  late FakeHubServer hub;

  /// A ledger saying the whole manifest is here, at the digests this build
  /// names — what a machine the gate is allowed to let through really has.
  /// [bump] moves one model's sha, which is the manifest-bump case.
  Future<void> seedLedger({
    bool bump = false,
    MachineTier tier = MachineTier.full,
  }) async {
    final manifest = testManifest().forTier(tier);
    var ledger = DownloadLedger.empty;
    for (final model in manifest.models) {
      ledger = ledger.record(FileDownloadState(
        id: model.id,
        status: DownloadStatus.done,
        receivedBytes: model.sizeBytes,
        totalBytes: model.sizeBytes,
        sha256:
            bump && model.role == ModelRole.prose ? 'f' * 64 : model.sha256,
      ));
    }
    await store.recordDownload(ledger);
  }

  Future<void> makeContainer({
    SetupStore? overStore,
    int memoryBytes = 0,
    SystemInfo? system,
    ModelManifest? manifest,
    ModelEnsurer? ensurer,
    bool realEnsurer = false,
    ModelDownloader? downloader,
    ModelServerSupervisor? server,
  }) async {
    // Read before the first frame, as `main()` does: the gate answers once,
    // and a prefs notifier still on its defaults would answer for the
    // generative model on Your server, the default, instead of the stored
    // This Mac.
    final prefs = await AppPrefsNotifier.read(MessageStore(db));
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialAppPrefsProvider.overrideWithValue(prefs),
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest ?? testManifest()),
      // A downloader pointed at the loopback hub with nothing published on
      // it: the model-bump case opens the wizard ON the download step, and a
      // run against the real Hugging Face is not a thing a test may start.
      modelDownloaderProvider.overrideWithValue(downloader ?? ModelDownloader(
        manifest: testManifest(),
        modelsFolder: () => support.path,
        readLedger: (overStore ?? store).downloadLedger,
        writeLedger: (overStore ?? store).recordDownload,
        sha256: (_) async => null,
        resolveUri: hub.resolveUriFor,
        sleep: (_) async {},
        maxAttempts: 1,
      )),
      systemInfoProvider.overrideWithValue(
        system ??
            (FakeSystemInfo()
              ..hardwareInfo = HardwareInfo(
                chip: 'Apple M2',
                memoryBytes: memoryBytes,
                appleSilicon: true,
                rosetta: false,
                osVersion: '15.6',
              )),
      ),
      modelServerSupervisorProvider.overrideWithValue(server ?? supervisor),
      authSessionProvider.overrideWithValue(FakeAuthSession()),
      desktopNotifierProvider.overrideWithValue(notifier),
      desktopNotificationServiceProvider.overrideWithValue(notifications),
      if (overStore != null) setupStoreProvider.overrideWithValue(overStore),
      // A recording fake unless a case asks for the real one: the real one
      // would start a download over real sockets inside a fake-async body.
      if (!realEnsurer)
        modelEnsurerProvider.overrideWithValue(ensurer ?? RecordingEnsurer()),
    ]);
    addTearDown(container.dispose);
  }

  setUp(() async {
    hub = await FakeHubServer.start();
    support = await Directory.systemTemp.createTemp('bond-gate');
    db = testDb();
    store = SetupStore(db);
    // This Mac, said out loud: the gate's cases are about the files this Mac
    // downloads, and the generative placement defaults to Your server since
    // the default-setup round.
    await MessageStore(db)
        .setPref(modelPlacementKey, ModelPlacement.local.name);
    runner = FakeProcessRunner();
    notifier = FakeDesktopNotifier();
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
      buildPreset: () => testManifest().toPreset(support.path),
      routerPort: () => 8080,
      onPortMoved: (_) async {},
      managed: () => false,
    );
  });

  tearDown(() async {
    await hub.close();
    notifications.dispose();
    await settles.close();
    await supervisor.dispose();
    await db.close();
    if (support.existsSync()) await support.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: SetupGate(child: Text('the app')),
      ),
    ));
    // Three bare pumps, not `pumpAndSettle`: the flow builds a downloader and
    // the first frame is a spinner, and settling on an indeterminate
    // indicator never returns.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a machine that has been set up goes straight through',
      (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer();

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
    expect(find.text('Welcome to Bond'), findsNothing);
  });

  testWidgets('an empty store opens the wizard instead of the app',
      (tester) async {
    await makeContainer();

    await mount(tester);

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('Step 1 of 9'), findsOneWidget);
    expect(find.text('the app'), findsNothing);
  });

  testWidgets('a database that cannot be read shows the wizard',
      (tester) async {
    // The recoverable answer, exactly as `AuthGate` treats an unreadable
    // keychain: the first step costs a click, and a launch that refused to
    // draw anything costs the app.
    await makeContainer(overStore: _UnreadableStore(db));

    await mount(tester);

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('the app'), findsNothing);
  });

  test('a platform that refuses still answers a tier, and it is the full one',
      () async {
    // The tier is awaited where the SERVER is launched, on a path with no
    // `try` above it: a rejected future there would take the launch down and
    // emit no `ServerFailed` at all. Nothing is refused for a fact the app
    // could not read, and that has to hold for a throw as well as for a zero.
    final container = ProviderContainer(overrides: [
      systemInfoProvider.overrideWithValue(_RefusingSystemInfo()),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(machineTierProvider.future), MachineTier.full);
  });

  testWidgets('a channel that goes quiet answers the full tier at the timeout',
      (tester) async {
    // The hang rather than the throw, one level below the gate. The SERVER
    // launch awaits this provider with no `try` above it and emits nothing
    // until `buildPreset()` returns, so an unbounded wait here is no server,
    // no `ServerFailed` and nothing on screen. The timeout lives inside the
    // provider's own `try`, so the wait ends the way a refusal does.
    final container = ProviderContainer(overrides: [
      hardwareInfoProvider
          .overrideWith((ref) => Completer<HardwareInfo>().future),
    ]);
    addTearDown(container.dispose);

    MachineTier? tier;
    unawaited(
      container.read(machineTierProvider.future).then((value) => tier = value),
    );

    await tester.pump(hardwareProbeTimeout + const Duration(seconds: 1));
    await tester.pump();

    expect(tier, MachineTier.full);
  });

  testWidgets('a channel that answers after the timeout re-derives the tier',
      (tester) async {
    // The timeout answers off a read that has not landed, so the answer has to
    // be revisable: a machine left pinned at `full` by a slow channel would be
    // offered the full tier's stage picks under a fact line reading 16 GB, off
    // the same hardware future. Watching the `AsyncValue` and not only the
    // future is what rebuilds this provider when the read finally lands.
    final answers = Completer<HardwareInfo>();
    final container = ProviderContainer(overrides: [
      hardwareInfoProvider.overrideWith((ref) => answers.future),
    ]);
    addTearDown(container.dispose);

    MachineTier? atTimeout;
    unawaited(
      container
          .read(machineTierProvider.future)
          .then((value) => atTimeout = value),
    );

    await tester.pump(const Duration(milliseconds: 2500));
    expect(atTimeout, MachineTier.full, reason: 'nothing has answered yet');

    answers.complete(const HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 17179869184,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    ));
    await tester.pump();
    await tester.pump();

    MachineTier? afterTheAnswer;
    unawaited(
      container
          .read(machineTierProvider.future)
          .then((value) => afterTheAnswer = value),
    );
    await tester.pump();

    expect(afterTheAnswer, MachineTier.inbox);

    // `invalidateSelf` files a zero-duration timer on Riverpod's own refresh
    // scheduler, and the read above rebuilt before it ran. Draining it keeps
    // the binding's "no pending timers" invariant, which is a test fact and
    // not a fact about the provider.
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a platform that never answers does not hold the launch',
      (tester) async {
    // The hang rather than the throw. The gate awaits the tier before it can
    // decide, so a channel that goes quiet would leave the app on a spinner
    // for ever; past the timeout it carries on as an unknown machine, which is
    // the full tier — and this machine IS set up, so it goes through.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer(system: _SilentSystemInfo());

    await mount(tester);
    expect(find.text('the app'), findsNothing,
        reason: 'the gate is still waiting on the machine');

    await tester.pump(hardwareProbeTimeout + const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('an inbox Mac goes through on the two files its tier wants',
      (tester) async {
    // The ledger holds the embedding and inbox models and nothing else,
    // because that is all this machine was ever asked to download. A gate
    // comparing it against the master list would send a finished setup back
    // through the wizard for a writing model it is never going to start.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger(tier: MachineTier.inbox);
    await makeContainer(memoryBytes: 17179869184);

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('a hand-installed decision model that is missing does not '
      'reopen the wizard', (tester) async {
    // A `source: local` decision model is copied in by hand, never
    // downloaded, so it has no ledger row and may not be on disk at all. A
    // missing one parks the decision pass; it must not send a finished setup
    // back through the wizard for a file the wizard cannot fetch.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer(manifest: testManifest(decide: testLocalDecideFile()));

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('a registry decision model that is missing does not reopen the '
      'wizard', (tester) async {
    // Decision D7: the registry's address lives in Settings, which the
    // wizard cannot reach, so its file is best-effort. No row at all.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    final manifest = testManifest(withDecide: true);
    expect(manifest.byRole(ModelRole.decide).isRegistry, isTrue);
    await makeContainer(manifest: manifest);

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('a registry decision model that FAILED does not reopen the '
      'wizard either', (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    final ledger = await store.downloadLedger();
    await store.recordDownload(ledger.record(const FileDownloadState(
      id: routerDecideId,
      status: DownloadStatus.failed,
      sha256: '',
      error: DownloadError.unauthorized,
    )));
    await makeContainer(manifest: testManifest(withDecide: true));

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('a registry EMBEDDING model that is missing reopens the '
      'wizard on the download step', (tester) async {
    // The twin of the decision model's case, and the opposite answer: the
    // embedding model gates setup wherever it is downloaded from, because
    // every stage needs it and the local model server cannot start without
    // it. The hub files are all here; the embed row is not.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await store.recordDownload(
        (await store.downloadLedger()).without(routerEmbedId));
    final manifest = testManifest(embed: testEmbedFile(), withDecide: true);
    expect(manifest.byRole(ModelRole.embed).isRegistry, isTrue);
    await makeContainer(manifest: manifest);

    await mount(tester);

    expect(find.text('the app'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('a registry embedding model that is current goes through, '
      'with the decision model still missing', (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    final embed = testEmbedFile();
    final ledger = await store.downloadLedger();
    await store.recordDownload(ledger.record(FileDownloadState(
      id: embed.id,
      status: DownloadStatus.done,
      receivedBytes: embed.sizeBytes,
      totalBytes: embed.sizeBytes,
      sha256: embed.sha256,
    )));
    await makeContainer(
        manifest: testManifest(embed: embed, withDecide: true));

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('with the registry entry in the manifest, a missing hub file '
      'still reopens the wizard', (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger(bump: true);
    await makeContainer(manifest: testManifest(withDecide: true));

    await mount(tester);

    expect(find.text('the app'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('a full Mac goes through without the 4B', (tester) async {
    // One generative model: the full tier serves the 27B and never asked for
    // the 4B, so a ledger without it is complete.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    var ledger = DownloadLedger.empty;
    for (final id in [routerEmbedId, routerProseId]) {
      final model = testManifest().byId(id);
      ledger = ledger.record(FileDownloadState(
        id: model.id,
        status: DownloadStatus.done,
        receivedBytes: model.sizeBytes,
        totalBytes: model.sizeBytes,
        sha256: model.sha256,
      ));
    }
    await store.recordDownload(ledger);
    await makeContainer(memoryBytes: 68719476736);

    await mount(tester);

    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('the same two files on a full Mac reopen the wizard',
      (tester) async {
    // The other half of the pin: the tier is read off the machine, not off
    // the folder, so the same ledger carried to a 64 GB Mac is incomplete.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger(tier: MachineTier.inbox);
    await makeContainer(memoryBytes: 68719476736);

    await mount(tester);

    expect(find.text('the app'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('a manifest bump reopens the wizard on the download step',
      (tester) async {
    // The stored word still says `done` and the file names have not changed,
    // so nothing downstream would ever notice that the weights on disk are
    // the previous checkpoint. The ledger is what notices.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger(bump: true);
    await makeContainer();

    await mount(tester);

    expect(find.text('the app'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Step 6 of 9'), findsOneWidget);
  });

  testWidgets('"Set up again" brings the wizard back over a running app',
      (tester) async {
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer();
    await mount(tester);
    expect(find.text('the app'), findsOneWidget);

    // What `restartSetup` does, in the order it does it: the key goes first,
    // because the gate re-reads the store the moment the counter moves.
    await restartSetupWith(
      store: store,
      restart: container.read(setupRestartProvider.notifier),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('the app'), findsNothing);
  });

  testWidgets('a second run gets a fresh controller, not the first one\'s state',
      (tester) async {
    await makeContainer();
    await mount(tester);
    expect(find.text('Welcome to Bond'), findsOneWidget);

    // The LIVE controller: the mounted flow built it, so this is the instance
    // the wizard is running on rather than one this test woke up.
    final first = container.read(setupControllerProvider.notifier);

    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    container.read(setupRestartProvider.notifier).state++;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('the app'), findsOneWidget);

    await store.clearExcept(SetupStore.keptOnRestart);
    container.read(setupRestartProvider.notifier).state++;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Back at the top, on a controller of its own: a second run over the first
    // one's `SetupState` would open at the step the last run finished on.
    expect(find.text('Welcome to Bond'), findsOneWidget);
    final second = container.read(setupControllerProvider.notifier);
    expect(identical(first, second), isFalse);
    expect(container.read(setupControllerProvider).loaded, isTrue);
    expect(container.read(setupControllerProvider).step, SetupStep.welcome);
  });

  test('the skip define reads a value, not merely a presence', () {
    // QUICKSTART says `=1`, which is what nearly everybody writes. The three
    // refusals are here so that somebody turning the skip back OFF with `=0`
    // gets the wizard rather than the opposite of what they typed.
    expect(SetupGate.skipsSetup(''), isFalse);
    expect(SetupGate.skipsSetup('0'), isFalse);
    expect(SetupGate.skipsSetup('false'), isFalse);
    expect(SetupGate.skipsSetup('No'), isFalse);
    expect(SetupGate.skipsSetup(' FALSE '), isFalse);
    expect(SetupGate.skipsSetup('1'), isTrue);
    expect(SetupGate.skipsSetup('yes'), isTrue);
  });

  testWidgets('the counter alone does not un-set-up a machine',
      (tester) async {
    // The gate re-DECIDES on the counter; it does not assume the answer. A
    // bump with the key still saying `done` has to leave the app on screen.
    await store.set(SetupStore.setupKey, SetupStep.done.name);
    await seedLedger();
    await makeContainer();
    await mount(tester);

    container.read(setupRestartProvider.notifier).state++;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('the app'), findsOneWidget);
  });

  group('the model ensurer and the wizard flag', () {
    testWidgets('while the wizard shows, the flag says so and nothing is '
        'ensured', (tester) async {
      final ensurer = RecordingEnsurer();
      await makeContainer(ensurer: ensurer);

      await mount(tester);

      expect(find.text('Welcome to Bond'), findsOneWidget);
      expect(container.read(setupShowingProvider), isTrue);
      expect(ensurer.calls, 0);
      // And the ensurer is told to hand over any run of its own.
      expect(ensurer.standDowns, 1);
    });

    testWidgets('once the app shows, the flag clears and the ensurer is '
        'kicked once', (tester) async {
      final ensurer = RecordingEnsurer();
      await store.set(SetupStore.setupKey, SetupStep.done.name);
      await seedLedger();
      await makeContainer(ensurer: ensurer);
      ensurer.flag = () => container.read(setupShowingProvider);

      await mount(tester);

      expect(find.text('the app'), findsOneWidget);
      expect(container.read(setupShowingProvider), isFalse);
      expect(ensurer.calls, 1);
      // Kicked AFTER the flag came down, so the real one would not stand
      // aside.
      expect(ensurer.blockedAtCall, [false]);
    });

    testWidgets('"Set up again" raises the flag and kicks nothing; the way '
        'back to the app kicks again', (tester) async {
      final ensurer = RecordingEnsurer();
      await store.set(SetupStore.setupKey, SetupStep.done.name);
      await seedLedger();
      await makeContainer(ensurer: ensurer);
      await mount(tester);
      expect(ensurer.calls, 1);

      await restartSetupWith(
        store: store,
        restart: container.read(setupRestartProvider.notifier),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Welcome to Bond'), findsOneWidget);
      expect(container.read(setupShowingProvider), isTrue);
      expect(ensurer.calls, 1);
      expect(ensurer.standDowns, greaterThanOrEqualTo(1),
          reason: 'Set up again hands the downloader to the wizard at once');

      // The welcome step's way back, which reaches the gate exactly as
      // Finish does.
      await tester.tap(find.byKey(SetupWelcomeBody.returnToInboxKey));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('the app'), findsOneWidget);
      expect(container.read(setupShowingProvider), isFalse);
      expect(ensurer.calls, 2);
    });

    testWidgets('the real ensurer stands aside while the flag is up',
        (tester) async {
      await makeContainer(realEnsurer: true);
      await mount(tester);
      expect(container.read(setupShowingProvider), isTrue);

      final state = await container.read(modelEnsurerProvider).ensure();

      expect(state.phase, EnsurePhase.idle);
      expect(hub.requests, isEmpty);
    });
  });

  testWidgets('a registry file the wizard\'s run lands AFTER Finish still '
      'reaches the router: the launch kick waits for that run, then asks for '
      'the preset', (tester) async {
    // The default placements: decision on this Mac, generative on Your
    // server. The wizard's set is embed and decide, and Finish can happen
    // while decide is still downloading (decision D7).
    await MessageStore(db).setPref(modelPlacementKey, ModelPlacement.box.name);
    final paths = AppPaths(support);
    final folder = paths.models.path;
    late ModelFile decide;
    late ModelManifest manifest;
    late ModelDownloader downloader;
    final server = _CountingSupervisor(support);
    await tester.runAsync(() async {
      final weights = fakeWeights(512 * 1024, seed: 21);
      final heads = fakeWeights(1536, seed: 22);
      hub.registryContents['bond-decide-mbl-v3swap/model-f16.gguf'] = weights;
      hub.registryContents['bond-decide-mbl-v3swap/heads.json'] = heads;
      decide = testDecideFile(
        sizeBytes: weights.length,
        sha256: sha256Hex(weights),
        headsSizeBytes: heads.length,
        headsSha256: sha256Hex(heads),
      );
      manifest = testManifest(decide: decide);
      // The embedding model is here and current: the gate lets the app
      // through on it alone.
      final embed = manifest.byRole(ModelRole.embed);
      final file = File('$folder/${embed.relativePath}');
      await file.parent.create(recursive: true);
      await file.writeAsString('gguf');
      await store.recordDownload(DownloadLedger.empty.record(FileDownloadState(
        id: embed.id,
        status: DownloadStatus.done,
        receivedBytes: embed.sizeBytes,
        totalBytes: embed.sizeBytes,
        sha256: embed.sha256,
      )));
      await store.set(SetupStore.setupKey, SetupStep.done.name);
      // The widget binding answers every HttpClient with a 400; this case
      // needs the loopback hub, so its client is built without that override
      // (the hub is in-process, so nothing leaves this machine).
      final binding = HttpOverrides.current;
      HttpOverrides.global = null;
      final client = IOClient(HttpClient());
      HttpOverrides.global = binding;
      addTearDown(client.close);
      downloader = ModelDownloader(
        httpClient: client,
        manifest: manifest,
        modelsFolder: () => folder,
        readLedger: store.downloadLedger,
        writeLedger: store.recordDownload,
        sha256: (_) async => null,
        resolveUri: hub.resolveUriFor,
        registryBase: () => hub.registryBase,
        registryToken: (_) => 'test-token-123',
        sleep: (_) async {},
        maxAttempts: 1,
        progressInterval: const Duration(milliseconds: 1),
        ledgerInterval: Duration.zero,
      );
    });
    addTearDown(downloader.dispose);
    await makeContainer(
      manifest: manifest,
      realEnsurer: true,
      downloader: downloader,
      server: server,
      memoryBytes: 64 * 1024 * 1024 * 1024,
    );

    // The wizard's run, still holding the registry leg when Finish lands.
    hub.chunkDelay = const Duration(milliseconds: 20);
    late Future<List<DownloadProgress>> wizardRun;
    await tester.runAsync(() async {
      wizardRun = downloader.run([decide]).toList();
    });

    await mount(tester);
    expect(find.text('the app'), findsOneWidget);
    final ensurer = container.read(modelEnsurerProvider);
    // The kick did not drop: it waits, and says a download is running.
    for (var i = 0; i < 50 && !ensurer.state.value.waiting; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(ensurer.state.value.phase, EnsurePhase.downloading);
    expect(ensurer.state.value.waiting, isTrue);
    expect(server.presets, 0);

    hub.chunkDelay = null;
    final ran = (await tester.runAsync(() => wizardRun))!;
    expect(ran.last.status, DownloadStatus.done);
    for (var i = 0;
        i < 200 && ensurer.state.value.phase != EnsurePhase.done;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }

    expect(ensurer.state.value.phase, EnsurePhase.done);
    expect(ensurer.state.value.waiting, isFalse);
    // Nothing of its own landed, so the preset is asked for, which restarts
    // the router onto the newly present decide file.
    expect(server.presets, greaterThanOrEqualTo(1));
    final ledger = (await tester.runAsync(store.downloadLedger))!;
    expect(ledger.isCurrent(decide), isTrue);
    // The status rows read the disk again when the phase moved.
    final rows = (await tester.runAsync(
        () => container.read(managedModelsStatusProvider.future)))!;
    expect(rows.firstWhere((r) => r.roleId == 'decision').onDisk, isTrue);
  });
}

/// A supervisor that counts what the ensurer asks of it and starts nothing.
class _CountingSupervisor extends ModelServerSupervisor {
  _CountingSupervisor(Directory support)
      : super(
          runner: FakeProcessRunner(),
          supportDir: support,
          binaryPath: () => '/usr/bin/true',
          buildPreset: () => testManifest().toPreset(support.path),
          routerPort: () => 8080,
          onPortMoved: (_) async {},
          managed: () => false,
        );

  int presets = 0;
  int restarts = 0;

  @override
  Future<void> ensurePreset() async => presets++;

  @override
  Future<void> restart() async => restarts++;
}
