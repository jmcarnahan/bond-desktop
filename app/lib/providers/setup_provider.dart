import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/app_paths.dart';
import '../data/setup_store.dart';
import '../models/setup_step.dart';
import '../services/backend/auth_session.dart';
import '../services/models/disk_preflight.dart';
import '../services/models/download_state.dart';
import '../services/models/model_downloader.dart';
import '../services/models/model_manifest.dart';
import '../services/notify/desktop_notifier.dart';
import '../services/server/model_server_supervisor.dart';
import '../services/system/system_info.dart';
import 'app_providers.dart';
import 'notification_provider.dart';
import 'prefs_provider.dart';

/// Everything the first-run wizard has learned so far.
///
/// One immutable value for the whole flow rather than a notifier per step,
/// because the steps are not independent: the storage step's preflight is
/// about the folder the download step will write into, the download step's
/// "all here" is what enables the sign-in step, and a Back that threw away
/// what a step had probed would re-probe the machine on every arrow.
///
/// Nullable fields are "not asked yet" and are drawn as such — a spinner and
/// a sentence — rather than as a zero. [hardware] null is `Checking this
/// Mac…`; [disk] null is `Checking free space…`; [notificationsGranted] null
/// is a step that has not put the question yet.
@immutable
class SetupState {
  /// [SetupController.init] has read the store. Nothing is drawn before this:
  /// a frame on the defaults would show step one to somebody resuming at the
  /// download.
  final bool loaded;

  final SetupStep step;

  /// What `main()` recorded about the sandbox-container copy, when it
  /// recorded anything. The welcome step is the only place it is mentioned.
  final MigrationReport? migration;

  final HardwareInfo? hardware;

  final DiskPreflight? disk;

  /// The EFFECTIVE folder — the controller resolves "the app's own folder"
  /// once, so no body has to know what an empty preference means.
  final String modelsFolder;

  final int routerPort;

  /// The latest position of each file, by [ModelFile.id]. A file with no
  /// entry has not been looked at yet.
  final Map<String, DownloadProgress> downloads;

  /// A run is in progress. A PAUSED run still counts: the run has not ended,
  /// and the buttons a paused run offers are the running ones.
  final bool downloadRunning;

  final bool downloadPaused;

  /// Every file in the manifest is done in the ledger AND present on disk.
  final bool downloadsComplete;

  final bool signedIn;

  final String? accountName;

  /// Null until the notifications step actually asked.
  final bool? notificationsGranted;

  /// Finish is in flight: the managed preference is being written and the
  /// server started.
  final bool finishing;

  /// The last Finish did not save. The All set step says so and offers the
  /// button again, because a wizard that left for the inbox on a half-written
  /// finish would be claiming a setup that is not on disk.
  final bool finishFailed;

  const SetupState({
    this.loaded = false,
    this.step = SetupStep.welcome,
    this.migration,
    this.hardware,
    this.disk,
    this.modelsFolder = '',
    this.routerPort = 0,
    this.downloads = const {},
    this.downloadRunning = false,
    this.downloadPaused = false,
    this.downloadsComplete = false,
    this.signedIn = false,
    this.accountName,
    this.notificationsGranted,
    this.finishing = false,
    this.finishFailed = false,
  });

  SetupState copyWith({
    bool? loaded,
    SetupStep? step,
    MigrationReport? migration,
    bool clearMigration = false,
    HardwareInfo? hardware,
    bool clearHardware = false,
    DiskPreflight? disk,
    bool clearDisk = false,
    String? modelsFolder,
    int? routerPort,
    Map<String, DownloadProgress>? downloads,
    bool? downloadRunning,
    bool? downloadPaused,
    bool? downloadsComplete,
    bool? signedIn,
    String? accountName,
    bool clearAccountName = false,
    bool? notificationsGranted,
    bool clearNotificationsGranted = false,
    bool? finishing,
    bool? finishFailed,
  }) =>
      SetupState(
        loaded: loaded ?? this.loaded,
        step: step ?? this.step,
        migration: clearMigration ? null : (migration ?? this.migration),
        hardware: clearHardware ? null : (hardware ?? this.hardware),
        disk: clearDisk ? null : (disk ?? this.disk),
        modelsFolder: modelsFolder ?? this.modelsFolder,
        routerPort: routerPort ?? this.routerPort,
        downloads: downloads ?? this.downloads,
        downloadRunning: downloadRunning ?? this.downloadRunning,
        downloadPaused: downloadPaused ?? this.downloadPaused,
        downloadsComplete: downloadsComplete ?? this.downloadsComplete,
        signedIn: signedIn ?? this.signedIn,
        accountName:
            clearAccountName ? null : (accountName ?? this.accountName),
        notificationsGranted: clearNotificationsGranted
            ? null
            : (notificationsGranted ?? this.notificationsGranted),
        finishing: finishing ?? this.finishing,
        finishFailed: finishFailed ?? this.finishFailed,
      );

  @override
  bool operator ==(Object other) =>
      other is SetupState &&
      other.runtimeType == runtimeType &&
      other.loaded == loaded &&
      other.step == step &&
      other.migration == migration &&
      other.hardware == hardware &&
      other.disk == disk &&
      other.modelsFolder == modelsFolder &&
      other.routerPort == routerPort &&
      _sameDownloads(other.downloads, downloads) &&
      other.downloadRunning == downloadRunning &&
      other.downloadPaused == downloadPaused &&
      other.downloadsComplete == downloadsComplete &&
      other.signedIn == signedIn &&
      other.accountName == accountName &&
      other.notificationsGranted == notificationsGranted &&
      other.finishing == finishing &&
      other.finishFailed == finishFailed;

  static bool _sameDownloads(
    Map<String, DownloadProgress> a,
    Map<String, DownloadProgress> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        loaded,
        step,
        migration,
        hardware,
        disk,
        modelsFolder,
        routerPort,
        Object.hashAll([
          for (final key in downloads.keys.toList()..sort())
            Object.hash(key, downloads[key]),
        ]),
        downloadRunning,
        downloadPaused,
        downloadsComplete,
        signedIn,
        accountName,
        notificationsGranted,
        finishing,
        finishFailed,
      );

  @override
  String toString() => 'SetupState(${step.name}, loaded: $loaded, '
      'complete: $downloadsComplete, signedIn: $signedIn)';
}

/// Drives the first run: which step, what each step probed, what it wrote.
///
/// It takes its collaborators rather than reaching for providers, which is
/// what lets `setup_controller_test.dart` run the whole flow against a
/// loopback hub and an in-memory database with no widget anywhere. The three
/// preference writes arrive as CLOSURES for a second reason:
/// `AppPrefsNotifier.state` is protected, and a controller that read it from
/// outside would be `invalid_use_of_protected_member` — so this one is told
/// what it needs and hands back what it changed.
///
/// [auth] is late-bound because the backend mode is a setting: a session
/// captured at construction would be the wrong one for anybody who switched
/// backends between opening the wizard and reaching the sign-in step.
class SetupController extends StateNotifier<SetupState> {
  SetupController({
    required this.store,
    required this.system,
    required this.manifest,
    required this.downloader,
    required this.supervisor,
    required this.paths,
    required this.readPrefs,
    required this.setManagedServer,
    required this.setModelsFolder,
    required this.auth,
    required this.notifier,
    required this.seedAuthorization,
  }) : super(const SetupState());

  final SetupStore store;
  final SystemInfo system;
  final ModelManifest manifest;
  final ModelDownloader downloader;
  final ModelServerSupervisor supervisor;
  final AppPaths paths;
  final AppPrefs Function() readPrefs;
  final Future<void> Function(bool) setManagedServer;
  final Future<void> Function(String) setModelsFolder;
  final AuthSession Function() auth;
  final DesktopNotifier notifier;
  final void Function(bool granted) seedAuthorization;

  /// What the STORE said, read once in [init]. The downloader keeps its own
  /// from the moment a run starts, and [_ledger] is the fallback for before
  /// that — a relaunch has to know the set is already complete without
  /// starting a run to find out.
  DownloadLedger _ledger = DownloadLedger.empty;

  /// The effective models folder as it stood when the wizard opened, so
  /// [finish] can tell a run that MOVED the weights from one that did not.
  String _folderAtInit = '';

  StreamSubscription<DownloadProgress>? _progress;

  /// The downloader's own ledger once it has one, this controller's otherwise.
  /// An empty ledger on a downloader that has never run is not an answer.
  DownloadLedger get _currentLedger =>
      downloader.ledger.files.isEmpty ? _ledger : downloader.ledger;

  /// Reads where the wizard stopped and re-enters that step.
  ///
  /// Every read is guarded: a database that cannot answer must open the
  /// wizard at the top rather than fail to render a screen at all.
  Future<void> init() async {
    final prefs = readPrefs();
    SetupStep step = SetupStep.welcome;
    MigrationReport? migration;
    try {
      step = SetupStep.parse(await store.get(SetupStore.setupKey));
      migration = _readMigration(await store.get(SetupStore.containerMigrationKey));
      _ledger = await store.downloadLedger();
    } on Object catch (e) {
      debugPrint('setup: could not read setup_state: $e');
    }
    // Defensive: nothing writes `done` before [finish], so a store holding it
    // here was edited by hand — and the last step is no place to strand a
    // wizard that has not been through the rest of itself.
    if (step == SetupStep.done) step = SetupStep.welcome;
    final folder = prefs.effectiveModelsFolder(paths);
    _folderAtInit = folder;
    if (!mounted) return;
    state = state.copyWith(
      loaded: true,
      step: step,
      migration: migration,
      modelsFolder: folder,
      routerPort: prefs.routerPort,
      downloadsComplete: _allFilesPresent(folder),
    );
    await _onEnter(step);
  }

  static MigrationReport? _readMigration(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return MigrationReport.fromJson(decoded.cast<String, Object?>());
    } on Object {
      // A record about a copy that already happened is not worth a broken
      // first screen.
      return null;
    }
  }

  Future<void> next() async {
    final target = state.step.next;
    if (target == null) return;
    await _goTo(target);
  }

  Future<void> back() async {
    final target = state.step.previous;
    if (target == null) return;
    await _goTo(target);
  }

  /// Persists the step BEFORE entering it, so a quit mid-probe resumes on the
  /// screen the user was looking at. A write that fails costs a wizard that
  /// starts one step earlier next launch, which is not worth throwing out of
  /// a button press.
  ///
  /// Arriving at [SetupStep.done] records the step BEFORE it instead.
  /// `'done'` is the gate's sentinel and only [finish] may write it: a quit on
  /// the All set screen would otherwise let the next launch straight past the
  /// gate with the managed server still off and no wizard left to turn it on.
  /// A relaunch lands on Notifications, whose Continue re-asks — macOS answers
  /// a settled prompt instantly — and leads back to All set.
  Future<void> _goTo(SetupStep target) async {
    final recorded =
        target == SetupStep.done ? SetupStep.notifications : target;
    try {
      await store.set(SetupStore.setupKey, recorded.name);
    } on Object catch (e) {
      debugPrint('setup: could not record step ${recorded.name}: $e');
    }
    if (!mounted) return;
    state = state.copyWith(step: target);
    await _onEnter(target);
  }

  /// What arriving at a step costs. Everything here is re-run on every
  /// arrival and stored nowhere: a machine's memory, its free space and
  /// whether a session is still valid are all facts that can change between
  /// two visits to the same screen.
  Future<void> _onEnter(SetupStep step) async {
    switch (step) {
      case SetupStep.device:
        await probeHardware();
      case SetupStep.storage:
        await checkStorage();
      case SetupStep.download:
        if (!state.downloadsComplete) await startDownload();
      case SetupStep.signIn:
        await probeSignIn();
      case SetupStep.done:
        await _probeAccount();
      case SetupStep.welcome:
      case SetupStep.models:
      case SetupStep.notifications:
        break;
    }
  }

  Future<void> probeHardware() async {
    final info = await system.hardware();
    if (!mounted) return;
    state = state.copyWith(hardware: info);
  }

  /// An Intel Mac, or an arm64 Mac running the x86_64 build. Either way there
  /// is no Metal backend under the models and the wizard stops here.
  bool get deviceBlocked {
    final hardware = state.hardware;
    if (hardware == null) return false;
    return !hardware.appleSilicon || hardware.rosetta;
  }

  /// Enough memory for the inbox, not enough for the writing model. A
  /// warning rather than a refusal: triage, extraction and search all run on
  /// the two small models, and they fit anywhere.
  bool get lowMemory {
    final hardware = state.hardware;
    if (hardware == null) return false;
    if (hardware.memoryBytes <= 0) return false;
    return hardware.memoryBytes < manifest.byRole(ModelRole.prose).minRamBytes;
  }

  Future<void> checkStorage() async {
    final folder = readPrefs().effectiveModelsFolder(paths);
    final preflight = await checkDisk(
      system: system,
      manifest: manifest,
      ledger: _currentLedger,
      folder: folder,
    );
    if (!mounted) return;
    state = state.copyWith(disk: preflight, modelsFolder: folder);
  }

  /// A folder the user picked. The preference is written first, because
  /// everything downstream — the preflight, the downloader, the preset — reads
  /// the folder rather than being told it.
  Future<void> setFolder(String path) async {
    await setModelsFolder(path);
    if (!mounted) return;
    final folder = readPrefs().effectiveModelsFolder(paths);
    state = state.copyWith(
      modelsFolder: folder,
      downloadsComplete: _allFilesPresent(folder),
    );
    await checkStorage();
  }

  Future<void> startDownload() async {
    if (downloader.running) return;
    await _progress?.cancel();
    _progress = null;
    // The mounted check comes BEFORE the run, not after it: a controller
    // disposed across that `await` would otherwise start a transfer whose
    // stream nothing is left to listen to.
    if (!mounted) return;
    final Stream<DownloadProgress> stream;
    try {
      stream = downloader.run();
    } on StateError catch (e) {
      // A disposed or already-running downloader. Neither is worth a red
      // screen on the step whose whole job is to make progress visible.
      debugPrint('setup: download did not start: $e');
      return;
    }
    state = state.copyWith(downloadRunning: true, downloadPaused: false);
    _progress = stream.listen(
      (progress) {
        if (!mounted) return;
        state = state.copyWith(
          downloads: {...state.downloads, progress.id: progress},
          downloadPaused: progress.status == DownloadStatus.paused
              ? true
              : (progress.status == DownloadStatus.downloading
                  ? false
                  : state.downloadPaused),
        );
      },
      onDone: () {
        if (!mounted) return;
        _ledger = downloader.ledger;
        state = state.copyWith(
          downloadRunning: false,
          downloadPaused: false,
          downloadsComplete: _allFilesPresent(state.modelsFolder),
        );
      },
    );
  }

  Future<void> pauseDownload() async {
    await downloader.pause();
    if (!mounted) return;
    state = state.copyWith(downloadPaused: true);
  }

  Future<void> resumeDownload() async {
    await downloader.resume();
    if (!mounted) return;
    state = state.copyWith(downloadPaused: false);
  }

  /// The run ENDS; the parts stay. `downloadRunning` is cleared by the
  /// stream's completion rather than here, so the buttons follow the
  /// downloader rather than the button press.
  Future<void> cancelDownload() => downloader.cancel();

  Future<void> probeSignIn() async {
    bool signedIn;
    try {
      signedIn = await auth().isSignedIn;
    } on Object catch (e) {
      // A keychain that cannot be read is treated as signed out, exactly as
      // `AuthGate` treats it: the sign-in step is the recoverable answer.
      debugPrint('setup: sign-in probe failed: $e');
      signedIn = false;
    }
    if (!mounted) return;
    state = state.copyWith(signedIn: signedIn);
  }

  Future<void> _probeAccount() async {
    String? name;
    try {
      name = (await auth().storedAccount)?.displayName;
    } on Object catch (e) {
      debugPrint('setup: account lookup failed: $e');
      name = null;
    }
    if (!mounted) return;
    state = state.copyWith(accountName: name, clearAccountName: name == null);
  }

  /// The notifications step's one button.
  ///
  /// The FIRST press is the ask — which is the whole reason this step exists,
  /// rather than letting the first settled message raise a system prompt out
  /// of nowhere. A grant moves on. A DENIAL stays on the step, because the
  /// sentence explaining where to turn them back on is the only thing the
  /// user has not seen yet; their next press continues.
  Future<void> continueFromNotifications() async {
    if (state.notificationsGranted != null) {
      await next();
      return;
    }
    if (!notifier.supported) {
      // No notification centre this app can reach. Seeded as a denial so the
      // dispatcher never asks either, and recorded as one so the done step
      // says `off` rather than claiming something that cannot happen.
      seedAuthorization(false);
      if (!mounted) return;
      state = state.copyWith(notificationsGranted: false);
      await next();
      return;
    }
    final granted = await notifier.ensureAuthorized();
    seedAuthorization(granted);
    if (!mounted) return;
    state = state.copyWith(notificationsGranted: granted);
    if (granted) await next();
  }

  Future<void> openNotificationSettings() => system.openNotificationSettings();

  /// Turns the managed server on, marks the wizard finished, and starts the
  /// server. True only when BOTH writes landed.
  ///
  /// It never throws, but it does REPORT. `'done'` is what the gate reads, so
  /// a Finish that got half way leaves a machine the wizard would be lying
  /// about if it left for the inbox anyway: the answer is to stay on the
  /// screen, say so, and offer the button again.
  Future<bool> finish() async {
    if (mounted) {
      state = state.copyWith(finishing: true, finishFailed: false);
    }
    var saved = false;
    try {
      await setManagedServer(true);
      await store.set(SetupStore.setupKey, SetupStep.done.name);
      saved = true;
      // The server is asked for only once the setup is on disk, and
      // fire-and-forget on `ServerBootstrap`'s reasoning: adopting or spawning
      // a server can take tens of seconds against a
      // twenty-seven-billion-parameter model, and the inbox must open now.
      //
      // A folder that MOVED wants a restart rather than a nudge.
      // `ensureRunning` returns at once on a server that is already ready, so
      // a "Set up again" that pointed the wizard at another disk would leave
      // the router mmap'ing the copies in the old one — which is why the
      // Settings card does folder-then-restart too.
      if (readPrefs().effectiveModelsFolder(paths) != _folderAtInit) {
        unawaited(supervisor.restart());
      } else {
        unawaited(supervisor.ensureRunning());
      }
    } on Object catch (e) {
      debugPrint('setup: finish did not complete: $e');
    }
    if (!mounted) return saved;
    state = state.copyWith(finishing: false, finishFailed: !saved);
    return saved;
  }

  /// Every manifest file done in the ledger AND sitting where the preset will
  /// look for it. `existsSync` rather than the async form because this is
  /// asked from inside a state update: three stats on a local path are
  /// cheaper than the frame a `Future` would cost.
  bool _allFilesPresent(String folder) {
    if (folder.isEmpty) return false;
    final ledger = _currentLedger;
    for (final model in manifest.models) {
      if (!ledger.isDone(model.id)) return false;
      if (!File(p.join(folder, model.relativePath)).existsSync()) return false;
    }
    return true;
  }

  /// The subscription goes FIRST, before anything else and before any await:
  /// Riverpod disposes synchronously and drops whatever a disposal returns,
  /// so a listener still attached past this point outlives the container.
  ///
  /// The download is deliberately NOT cancelled here, and today nothing is
  /// orphaned by that: the only disposal is the gate invalidating this
  /// controller on "Set up again", which the inbox offers only after Finish,
  /// which the download step will not let anybody reach until the run has
  /// ended. If a second way to dispose ever appears, the thing to fix first is
  /// [ModelDownloader.run] — it hands out a single-subscription stream, so a
  /// live run survives with nobody able to re-attach to it.
  @override
  void dispose() {
    _progress?.cancel();
    _progress = null;
    super.dispose();
  }
}

/// Bumped by "Set up again"; `SetupGate` re-decides on every change.
///
/// A counter rather than a bool because the interesting event is the CHANGE:
/// a flag set to true would have to be set back to false by whoever consumed
/// it, and the gate would then be responsible for resetting the thing it
/// listens to.
final setupRestartProvider = StateProvider<int>((_) => 0);

final setupControllerProvider =
    StateNotifierProvider<SetupController, SetupState>((ref) {
  final paths = ref.watch(appPathsProvider);
  final system = ref.watch(systemInfoProvider);
  return SetupController(
    store: ref.watch(setupStoreProvider),
    system: system,
    manifest: ref.watch(modelManifestProvider),
    downloader: ref.watch(modelDownloaderProvider),
    supervisor: ref.watch(modelServerSupervisorProvider),
    paths: paths,
    // READ, not watched, on `modelServerSupervisorProvider`'s rule: a
    // controller rebuilt because a preference moved would abandon a download
    // that is hours in. Every preference here is consulted at the top of a
    // step, never cached.
    readPrefs: () => ref.read(appPrefsProvider),
    setManagedServer: (on) =>
        ref.read(appPrefsProvider.notifier).setManagedServer(on),
    setModelsFolder: (path) =>
        ref.read(appPrefsProvider.notifier).setModelsFolder(path),
    auth: () => ref.read(authSessionProvider),
    notifier: ref.watch(desktopNotifierProvider),
    // Late-bound: reading the service provider here would build the whole
    // notification stack — the settle stream, the coordinator, the store
    // behind it — at wizard construction, for an answer that is wanted once.
    seedAuthorization: (granted) =>
        ref.read(desktopNotificationServiceProvider).seedAuthorization(granted),
  );
});

/// "Set up again": clears `setup_state` except [SetupStore.keptOnRestart],
/// then bumps the counter the gate watches.
///
/// The order matters. The gate re-reads the store the moment the counter
/// moves, so a bump before the clear would race it and find the key still
/// saying `done`.
Future<void> restartSetupWith({
  required SetupStore store,
  required StateController<int> restart,
}) async {
  try {
    await store.clearExcept(SetupStore.keptOnRestart);
  } on Object catch (e) {
    // Worth saying, not worth refusing: the wizard still opens, and the
    // stored step is where it resumes.
    debugPrint('setup: could not clear setup_state: $e');
  }
  restart.state++;
}

/// The widget-side entry point, for the Settings card's button.
Future<void> restartSetup(WidgetRef ref) => restartSetupWith(
      store: ref.read(setupStoreProvider),
      restart: ref.read(setupRestartProvider.notifier),
    );
