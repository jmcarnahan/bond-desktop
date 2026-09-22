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
import '../services/llm/model_probe.dart';
import '../services/llm/model_slots.dart';
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

  /// This run of the wizard was opened by "Set up again" on a machine that
  /// was already set up, so the welcome step may offer a way back out. False
  /// on a first run, where there is no inbox behind the wizard to go to.
  final bool canReturnToInbox;

  /// The answer to **Where the models run**, or null until one is given. A
  /// quit on that step resumes there with this still null, so nothing was
  /// adopted and the step asks again.
  final ModelPlacement? placement;

  /// The box address as typed, prefilled from the compiled `boxUrlDefault`.
  ///
  /// The ACCESS KEY is deliberately not here and never will be. This object is
  /// state, state is what gets stored, and a stored key would be a secret in
  /// `setup_state`. The key lives in the step body's own controller and is
  /// handed to `useBox` by value at Continue.
  final String boxUrl;

  /// The WRITING slot's **Check server** answer, or null when none has been
  /// asked for. Carries no token: see `ModelServerProbe.probe`.
  final ModelProbeResult? boxProbe;

  /// The INBOX slot's answer to the same press.
  ///
  /// Two fields rather than one, because the box serves both roles from one
  /// host and a check that reported only the writing slot would call a box
  /// with a dead inbox server healthy. They move together: one press asks
  /// both, and clearing clears both.
  final ModelProbeResult? boxBulkProbe;

  final bool boxProbing;

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
    this.canReturnToInbox = false,
    this.placement,
    this.boxUrl = boxUrlDefault,
    this.boxProbe,
    this.boxBulkProbe,
    this.boxProbing = false,
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
    bool? canReturnToInbox,
    ModelPlacement? placement,
    bool clearPlacement = false,
    String? boxUrl,
    ModelProbeResult? boxProbe,
    ModelProbeResult? boxBulkProbe,
    // Clears BOTH slots' answers: one press asked them, and half a report is
    // worse than none.
    bool clearBoxProbe = false,
    bool? boxProbing,
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
        canReturnToInbox: canReturnToInbox ?? this.canReturnToInbox,
        placement: clearPlacement ? null : (placement ?? this.placement),
        boxUrl: boxUrl ?? this.boxUrl,
        boxProbe: clearBoxProbe ? null : (boxProbe ?? this.boxProbe),
        boxBulkProbe:
            clearBoxProbe ? null : (boxBulkProbe ?? this.boxBulkProbe),
        boxProbing: boxProbing ?? this.boxProbing,
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
      other.finishFailed == finishFailed &&
      other.canReturnToInbox == canReturnToInbox &&
      other.placement == placement &&
      other.boxUrl == boxUrl &&
      other.boxProbe == boxProbe &&
      other.boxBulkProbe == boxBulkProbe &&
      other.boxProbing == boxProbing;

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
        canReturnToInbox,
        // Nested: `Object.hash` takes twenty arguments and the five fields the
        // placement added are the twenty-first onward.
        Object.hash(placement, boxUrl, boxProbe, boxBulkProbe, boxProbing),
      );

  @override
  String toString() => 'SetupState(${step.name}, loaded: $loaded, '
      'complete: $downloadsComplete, signedIn: $signedIn, '
      'placement: ${placement?.name})';
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
    required this.applyTierDefaults,
    this.probe,
    this.storedBearer,
    required this.useBox,
    required this.usePlacement,
    required this.auth,
    required this.notifier,
    required this.seedAuthorization,
  }) : super(const SetupState());

  final SetupStore store;
  final SystemInfo system;

  /// The MASTER manifest, every checkpoint this build knows. Everything that
  /// downloads, checks or starts reads [resolvedManifest] instead.
  final ModelManifest manifest;
  final ModelDownloader downloader;
  final ModelServerSupervisor supervisor;
  final AppPaths paths;
  final AppPrefs Function() readPrefs;
  final Future<void> Function(bool) setManagedServer;
  final Future<void> Function(String) setModelsFolder;

  /// Writes this machine's tier defaults — the stage picks and the draft
  /// policy. A CLOSURE for the same reason the two above are: the prefs
  /// notifier's state is protected, and this controller is told what to do
  /// rather than reaching for the provider.
  final Future<void> Function(MachineTier) applyTierDefaults;

  /// Asks a model server what it serves, for **Check server** on the box.
  /// Null takes the button off the step, the discipline every optional
  /// control in this app follows.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Writes the box address, the one key and the box placement. The two
  /// targets and the stage map are a RULE since Round H and are written
  /// nowhere. A CLOSURE for the reason the three writes above are: the prefs
  /// notifier's state is protected.
  ///
  /// [key] is a SECRET and passes straight through to the keychain. It is
  /// never stored on this controller and never enters [SetupState]. Null
  /// means "keep the stored one": a re-entry with a key already in the
  /// keychain moves on with the field blank rather than asking for a second
  /// paste, the simple Models page's own contract.
  final Future<void> Function({
    required String baseUrl,
    required String? key,
    required MachineTier hardwareTier,
  }) useBox;

  /// Looks up one target's stored token for a check made with the key field
  /// blank. A LOOKUP, never the value, on the widgets' own rule; null when the
  /// host has no keychain to ask, and the check then goes without a key.
  final String? Function(String targetId)? storedBearer;

  /// Moves the install to a placement and clears out the stage entries the app
  /// itself wrote. This Mac's answer to **Where the models run**, wired so
  /// that both answers have one shape.
  final Future<void> Function(
    ModelPlacement placement, {
    required MachineTier hardwareTier,
  }) usePlacement;

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

  /// A file reached `done` while THIS controller was watching.
  ///
  /// [finish] needs it because the supervisor's preset hash covers paths and
  /// arguments, not digests: a server left running over the old weights looks
  /// healthy to `ensureRunning`, and would go on answering from them.
  bool _downloadedThisRun = false;

  /// The downloader's own ledger once it has one, this controller's otherwise.
  /// An empty ledger on a downloader that has never run is not an answer.
  DownloadLedger get _currentLedger =>
      downloader.ledger.files.isEmpty ? _ledger : downloader.ledger;

  /// Reads where the wizard stopped and re-enters that step.
  ///
  /// Every read is guarded: a database that cannot answer must open the
  /// wizard at the top rather than fail to render a screen at all.
  Future<void> init() async {
    // The machine is asked FIRST, before the ledger is read: the tier decides
    // which files the ledger is compared against, and a resume that guessed
    // the full tier on a small Mac would open the download step and fetch a
    // writing model that machine is never going to start. It costs one
    // in-process `sysctl`, and every later arrival re-asks anyway.
    // [probeHardware] neither throws nor waits longer than
    // [hardwareProbeTimeout], so it cannot cost the screen.
    await probeHardware();
    if (!mounted) return;
    final prefs = readPrefs();
    // The stored answer, before anything reads [tier]: the `done` branch below
    // compares the ledger against [resolvedManifest], and on a box install
    // that is the embedding model alone. It also means a re-entry through
    // "Set up again" opens the where step knowing which install this is, so
    // choosing This Mac there writes the undo.
    //
    // ONLY the box is seeded, and since Round H that is a FRESH install on
    // any build with a compiled address: `defaultModelPlacement` is the box
    // whenever `BOND_BOX_URL` was passed. Preselecting the box answers
    // nothing, because the box card keeps the way forward closed until the
    // key field is answered; a preselected This Mac would put a live Continue
    // under a question nobody had been asked. A local re-entry loses nothing
    // by asking again: choosing This Mac there writes the same defaults it
    // already has.
    if (prefs.modelPlacement == ModelPlacement.box) {
      if (!mounted) return;
      state = state.copyWith(placement: ModelPlacement.box);
    }
    // The ADDRESS is the install's whenever one has been saved, and the
    // build's otherwise ([SetupState.boxUrl] opens on `boxUrlDefault`). A
    // re-entry that re-offered the compiled default would put back an address
    // the owner had changed in Settings, on a Continue they read as agreeing
    // to what was on the screen.
    final saved = boxBaseFromProseUrl(prefs.effectiveBoxBigUrl);
    if (saved.isNotEmpty && saved != state.boxUrl) {
      if (!mounted) return;
      state = state.copyWith(boxUrl: saved);
    }
    SetupStep step = SetupStep.welcome;
    MigrationReport? migration;
    var canReturn = false;
    try {
      step = SetupStep.parse(await store.get(SetupStore.setupKey));
      migration = _readMigration(await store.get(SetupStore.containerMigrationKey));
      _ledger = await store.downloadLedger();
      canReturn = await store.get(SetupStore.previousSetupKey) ==
          SetupStep.done.name;
    } on Object catch (e) {
      debugPrint('setup: could not read setup_state: $e');
    }
    // A stored `done` is one of two things. With the ledger describing the
    // manifest this build ships, it is a machine that finished — the last
    // step is no place to strand it, so the wizard opens at the top. With a
    // ledger the manifest has moved past, it is the MODEL BUMP path: the
    // weights on disk are the previous checkpoint, and the download step is
    // where that gets put right — its `_onEnter` starts the transfer for
    // everything missing or stale.
    if (step == SetupStep.done) {
      step = _ledger.matches(resolvedManifest)
          ? SetupStep.welcome
          : SetupStep.download;
    }
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
      canReturnToInbox: canReturn,
    );
    await _onEnter(step);
  }

  // ── Where the models run ─────────────────────────────────────────────────

  /// Picks the GPU server. Nothing is written until Continue: the choice
  /// reveals the three controls and nothing more.
  void chooseBox() {
    if (!mounted) return;
    state = state.copyWith(placement: ModelPlacement.box);
  }

  void chooseLocal() {
    if (!mounted) return;
    state = state.copyWith(placement: ModelPlacement.local);
  }

  /// Records the typed address and drops any probe result taken against the
  /// previous one: a "Reachable" line under a URL that has since been edited
  /// is a report about a different server.
  void setBoxUrl(String value) {
    if (!mounted) return;
    // A check that is out is about the OLD address: its answers are dropped
    // when they land ([_checkSeq]), and the busy flag comes off now rather
    // than when a report nobody wants arrives.
    _checkSeq++;
    state = state.copyWith(
      boxUrl: value,
      clearBoxProbe: true,
      boxProbing: false,
    );
  }

  /// Which **Check server** press is the current one. A press bumps it, an
  /// address edit bumps it, and a check that comes back to a different number
  /// writes nothing: two servers asked in sequence is long enough for a
  /// person to have retyped the address in between.
  int _checkSeq = 0;

  /// Asks BOTH of the box's slots what they serve, with the typed key.
  ///
  /// Both, because the box runs the writing model and the inbox model as two
  /// servers behind one address, and a check that asked only the writing slot
  /// would report a box whose inbox server is down as healthy. The writing
  /// slot is asked first, so the line the reader looks at first is the one
  /// that answers first.
  ///
  /// The address is checked the way every other door checks it: a string that
  /// is not an origin is refused by the form before the press arrives, and
  /// this returns without asking anything of a server it could not name.
  ///
  /// [key] is a SECRET: it goes onto the two requests' `Authorization` headers
  /// and is not stored here, in [SetupState] or in either result. Nothing is
  /// adopted by a check.
  Future<void> checkBox(String key) async {
    final probe = this.probe;
    if (probe == null) return;
    final base = normalizeBoxBaseUrl(state.boxUrl);
    if (base.isEmpty || !isBoxOrigin(base)) return;
    if (!mounted) return;
    final seq = ++_checkSeq;
    state = state.copyWith(boxProbing: true, clearBoxProbe: true);
    // A key just typed beats the stored one; a blank field with a key in the
    // keychain sends that key, looked up by id at the press and held nowhere.
    final token = key.trim();
    final stored = readPrefs().boxKeyStored;
    String? bearer(String targetId) => token.isNotEmpty
        ? token
        : (stored ? storedBearer?.call(targetId) : null);
    final prose = await _probeSlot(probe, '$base/prose/v1/chat/completions',
        bearer: bearer(boxProseId));
    final bulk = await _probeSlot(probe, '$base/bulk/v1/chat/completions',
        bearer: bearer(boxBulkId));
    if (!mounted || seq != _checkSeq) return;
    state = state.copyWith(
      boxProbing: false,
      boxProbe: prose,
      boxBulkProbe: bulk,
    );
  }

  /// One slot's answer, with the guard both of them need.
  ///
  /// `ModelServerProbe` promises never to throw, and a settings-shaped
  /// diagnostic must not be able to strand the wizard anyway.
  Future<ModelProbeResult> _probeSlot(
    Future<ModelProbeResult> Function(String url, {String? bearer}) probe,
    String url, {
    String? bearer,
  }) async {
    try {
      return await probe(url, bearer: bearer);
    } on Object {
      return const ModelProbeResult(
        reachable: false,
        error: 'Could not check the server',
      );
    }
  }

  /// The step's Continue.
  ///
  /// On the box choice it REFUSES to advance with an empty address, an
  /// address that is not an origin, or an empty key: the placement would then
  /// name a server nothing could dial, and every stage would park. The form
  /// says so under the field before the press gets here, and this is the
  /// second half of that rule rather than a second rule.
  ///
  /// This Mac WRITES too, and that is not symmetry for its own sake. A wizard
  /// re-entered through "Set up again" on an install that is already on the
  /// box would otherwise leave `model_placement = box` standing while
  /// `finish()` applied this machine's tier defaults on top — an install
  /// claiming to run locally with every stage still resolving to a server it
  /// no longer means to use. [AppPrefsNotifier.usePlacement] is called
  /// unconditionally rather than only when the stored answer was the box: the
  /// entry sweep finds nothing to drop on a first run, and the tier write is
  /// the one `finish()` was going to make anyway.
  ///
  /// It KEEPS the address and the key, which is the one thing that changed
  /// with Round H's spelling. Changing where the work runs is not forgetting
  /// how to reach the box, and a tester who tries This Mac and goes back
  /// should not have to paste the key again. The simple Models page's **Use
  /// this Mac** already behaves this way.
  ///
  /// The tier is the HARDWARE's, read here rather than through [tier], which
  /// answers `remote` while the placement is still the box.
  Future<void> continueFromWhere(String key) async {
    final hardwareTier = machineTierFor(state.hardware?.memoryBytes ?? 0);
    if (placement == ModelPlacement.box) {
      final base = normalizeBoxBaseUrl(state.boxUrl);
      final token = key.trim();
      if (base.isEmpty || !isBoxOrigin(base)) return;
      // A blank field goes through only when a key is already in the
      // keychain, and then as null, which `useBox` reads as "keep it". The
      // form's Continue is live in exactly that state and no other, so the
      // two halves of the rule agree.
      if (token.isEmpty && !readPrefs().boxKeyStored) return;
      await useBox(
        baseUrl: base,
        key: token.isEmpty ? null : token,
        hardwareTier: hardwareTier,
      );
    } else {
      await usePlacement(ModelPlacement.local, hardwareTier: hardwareTier);
    }
    if (!mounted) return;
    await _goTo(SetupStep.models);
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
      case SetupStep.where:
      case SetupStep.welcome:
      case SetupStep.models:
      case SetupStep.notifications:
        break;
    }
  }

  /// Asks the platform what this Mac is. It never throws and never waits
  /// longer than [hardwareProbeTimeout].
  ///
  /// `ChannelSystemInfo` already turns a missing plugin and a platform
  /// exception into [HardwareInfo.unknown], so reaching the catch means a
  /// channel that threw something else — or, past the timeout, one that did
  /// not answer at all. The answer is the same either way, and it is the
  /// never-refuse one: unknown memory, the full tier, and a device step that
  /// says `unknown` rather than claiming a number.
  Future<void> probeHardware() async {
    HardwareInfo info;
    try {
      info = await system.hardware().timeout(hardwareProbeTimeout);
    } on Object catch (e) {
      debugPrint('setup: could not read this Mac: $e');
      info = HardwareInfo.unknown;
    }
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

  /// What this Mac runs, from the memory the last probe read.
  ///
  /// Recomputed on every read rather than stored, exactly as [lowMemory] was:
  /// the machine is the thing that decides, the probe runs on every arrival,
  /// and a tier written down somewhere would be the models folder's opinion
  /// of a Mac it may have been moved away from. Before the first probe, and
  /// on a machine whose memory could not be read, it is
  /// [MachineTier.full] — the never-refuse rule [machineTierFor] states.
  ///
  /// On [ModelPlacement.box] it is [MachineTier.remote] whatever the memory
  /// is: this Mac serves the embedding model and nothing else, so the models
  /// step lists one file, the storage step sizes one, the download step
  /// fetches one and `init`'s ledger comparison asks for one.
  MachineTier get tier => placement == ModelPlacement.box
      ? MachineTier.remote
      : machineTierFor(state.hardware?.memoryBytes ?? 0);

  /// The answer so far, defaulting to this Mac. Null means nobody has chosen
  /// yet, and the steps before the choice read the same as they always did.
  ModelPlacement get placement => state.placement ?? ModelPlacement.local;

  /// The manifest as [tier] wants it. THE view every step reads: the models
  /// step's rows and total, the disk preflight, the download run, the ledger
  /// check and the preset the supervisor starts.
  ModelManifest get resolvedManifest => manifest.forTier(tier);

  /// Enough memory for the inbox, not enough for the writing model. A
  /// warning rather than a refusal: triage, extraction and search all run on
  /// the two small models, and they fit anywhere.
  ///
  /// It reads the TIER rather than a threshold of its own, so there is one
  /// answer to "is this Mac small" and the sentence the device step shows
  /// cannot disagree with the files the download step fetches.
  ///
  /// It reads the HARDWARE tier directly rather than [tier], because a Mac
  /// pointed at the box is still a small Mac and the device step is still
  /// describing it. [tier] answers what this install runs; this answers what
  /// this machine could.
  bool get lowMemory =>
      state.hardware != null &&
      machineTierFor(state.hardware?.memoryBytes ?? 0) == MachineTier.inbox;

  /// Below the smallest machine the golden set was measured on. Not a third
  /// tier and not a refusal: one more sentence on the device step, because a
  /// machine under [measuredFloorBytes] runs the same two models slower than
  /// any row in the ledger.
  bool get underMeasuredFloor {
    final hardware = state.hardware;
    if (hardware == null) return false;
    if (hardware.memoryBytes <= 0) return false;
    return hardware.memoryBytes < measuredFloorBytes;
  }

  Future<void> checkStorage() async {
    final folder = readPrefs().effectiveModelsFolder(paths);
    final preflight = await checkDisk(
      system: system,
      manifest: resolvedManifest,
      ledger: _currentLedger,
      folder: folder,
    );
    if (!mounted) return;
    state = state.copyWith(disk: preflight, modelsFolder: folder);
  }

  /// A folder the user picked. The preference is written first, because
  /// everything downstream — the preflight, the downloader, the preset — reads
  /// the folder rather than being told it.
  ///
  /// A run in flight is ENDED before the preference moves. [ModelDownloader]
  /// reads the folder once per run, so a transfer that kept going would go on
  /// filling the folder the user has just left — gigabytes nobody will use,
  /// under progress bars describing somewhere else. The parts stay where they
  /// are, exactly as a Cancel leaves them, and the download step starts a new
  /// run into the new folder on the next arrival.
  Future<void> setFolder(String path) async {
    if (downloader.running) await downloader.cancel();
    // The subscription goes with the run: the stream it was listening to is
    // ending, and the flags it would have cleared are cleared here instead.
    await _progress?.cancel();
    _progress = null;
    await setModelsFolder(path);
    if (!mounted) return;
    final folder = readPrefs().effectiveModelsFolder(paths);
    state = state.copyWith(
      modelsFolder: folder,
      downloadRunning: false,
      downloadPaused: false,
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
      // The RESOLVED set, smallest first: an inbox Mac fetches two files and
      // is never shown a bar for a checkpoint it will not start.
      stream = downloader.run(resolvedManifest.bySize);
    } on StateError catch (e) {
      // A disposed or already-running downloader. Neither is worth a red
      // screen on the step whose whole job is to make progress visible.
      debugPrint('setup: download did not start: $e');
      return;
    }
    state = state.copyWith(downloadRunning: true, downloadPaused: false);
    _progress = stream.listen(
      (progress) {
        if (progress.status == DownloadStatus.done) {
          _downloadedThisRun = true;
        }
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
      // BEFORE the managed preference and before the server: the stage picks
      // are what the first drain resolves a target through, and a machine
      // with no writing model must not have six stages pointing at a server
      // this tier never starts. A write that throws leaves the wizard on this
      // screen with the button again, exactly as a half-written setup does.
      // Only on the local placement. `applyTierDefaults` returns at once on
      // [MachineTier.remote] anyway, and saying so here is what keeps the box
      // adoption's stage map obviously untouched by the wizard's last step.
      if (placement == ModelPlacement.local) {
        await applyTierDefaults(tier);
      }
      await setManagedServer(true);
      // The stash exists only while the welcome step is offering a way back;
      // finishing is the end of that offer, and a leftover value would have
      // the NEXT first run think it had an inbox behind it.
      await store.remove(SetupStore.previousSetupKey);
      await store.set(SetupStore.setupKey, SetupStep.done.name);
      saved = true;
      // The server is asked for only once the setup is on disk, and
      // fire-and-forget on `ServerBootstrap`'s reasoning: adopting or spawning
      // a server can take tens of seconds against a
      // twenty-seven-billion-parameter model, and the inbox must open now.
      //
      // A folder that MOVED wants a restart rather than a nudge, and so do
      // WEIGHTS that landed while this wizard was open. `ensureRunning`
      // returns at once on a server that is already ready, and the preset
      // hash it compares covers paths and arguments rather than digests — so
      // a "Set up again" that pointed the wizard at another disk, or a
      // manifest bump that rewrote the files under the same names, would both
      // leave the router serving what it mmap'd before. Which is why the
      // Settings card does folder-then-restart too.
      if (_downloadedThisRun ||
          readPrefs().effectiveModelsFolder(paths) != _folderAtInit) {
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

  /// Leaves the wizard the way it was entered, for somebody who pressed
  /// "Set up again" and meant to look rather than to redo.
  ///
  /// `'done'` is written by [finish] and by this, and by nothing else. The
  /// rule survives because this one never INVENTS the word: it puts back the
  /// value the store already held — stashed by `restartSetupWith` at the
  /// moment it cleared it — and only on a machine where [finish] had written
  /// it before. The stash goes with it, so the offer is not standing the next
  /// time the wizard opens.
  ///
  /// A download this run started is left alone: the run outlives the screen
  /// by [dispose]'s reasoning, and cancelling one an hour in would be a
  /// steeper price than the button implies.
  Future<bool> returnToInbox() async {
    try {
      await store.set(SetupStore.setupKey, SetupStep.done.name);
      await store.remove(SetupStore.previousSetupKey);
    } on Object catch (e) {
      // The gate would only show the wizard again, so the honest answer is to
      // stay here rather than to hand over an inbox the next launch takes
      // back.
      debugPrint('setup: could not return to the inbox: $e');
      return false;
    }
    if (mounted) state = state.copyWith(canReturnToInbox: false);
    return true;
  }

  /// Every manifest file done in the ledger AT THIS MANIFEST'S DIGEST and
  /// sitting where the preset will look for it. `existsSync` rather than the
  /// async form because this is asked from inside a state update: three stats
  /// on a local path are cheaper than the frame a `Future` would cost.
  ///
  /// The digest is what makes a model bump visible. A row that merely says
  /// done can describe the checkpoint before this build's, and a Continue
  /// granted on it would hand over an inbox serving the old weights.
  bool _allFilesPresent(String folder) {
    if (folder.isEmpty) return false;
    final ledger = _currentLedger;
    for (final model in resolvedManifest.models) {
      if (!ledger.isCurrent(model)) return false;
      if (!File(p.join(folder, model.relativePath)).existsSync()) return false;
      // The sidecar as well, on the same reasoning: the preset names it as
      // `model-draft` and the server is started `--offline`, so a Continue
      // granted without it hands over a server that will not start.
      final draft = model.sidecarRelativePath;
      if (draft != null && !File(p.join(folder, draft)).existsSync()) {
        return false;
      }
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
    // Nothing to write: whether this build runs its own server is a define
    // now, not a preference. The callback stays until Phase 7 rewrites the
    // wizard's last step, so the controller keeps one shape across the round.
    setManagedServer: (_) async {},
    setModelsFolder: (path) =>
        ref.read(appPrefsProvider.notifier).setModelsFolder(path),
    applyTierDefaults: (tier) =>
        ref.read(appPrefsProvider.notifier).applyTierDefaults(tier),
    probe: ModelServerProbe().probe,
    storedBearer: ref.read(appPrefsProvider.notifier).bearerFor,
    useBox: ({required baseUrl, required key, required hardwareTier}) =>
        ref.read(appPrefsProvider.notifier).useBoxOrigin(
              baseUrl: baseUrl,
              key: key,
              hardwareTier: hardwareTier,
            ),
    usePlacement: (placement, {required hardwareTier}) => ref
        .read(appPrefsProvider.notifier)
        .usePlacement(placement, hardwareTier: hardwareTier),
    auth: () => ref.read(authSessionProvider),
    notifier: ref.watch(desktopNotifierProvider),
    // Late-bound: reading the service provider here would build the whole
    // notification stack — the settle stream, the coordinator, the store
    // behind it — at wizard construction, for an answer that is wanted once.
    seedAuthorization: (granted) =>
        ref.read(desktopNotificationServiceProvider).seedAuthorization(granted),
  );
});

/// "Set up again": stashes a `done` that was there, clears `setup_state`
/// except [SetupStore.keptOnRestart], then bumps the counter the gate watches.
///
/// The order matters. The gate re-reads the store the moment the counter
/// moves, so a bump before the clear would race it and find the key still
/// saying `done`.
///
/// The stash is what keeps this from being a one-way door. Pressing the
/// button on a machine that was set up used to mean walking all eight steps
/// again with no way out, because the word the gate reads had already gone;
/// [SetupStore.previousSetupKey] holds it so the welcome step can offer
/// **Back to the inbox**. Nothing is stashed on a machine that had not
/// finished — there is no inbox behind that wizard to go back to.
Future<void> restartSetupWith({
  required SetupStore store,
  required StateController<int> restart,
}) async {
  try {
    final current = await store.get(SetupStore.setupKey);
    if (current == SetupStep.done.name) {
      await store.set(SetupStore.previousSetupKey, SetupStep.done.name);
    }
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
