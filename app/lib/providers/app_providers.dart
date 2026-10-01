import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// `show BondDatabase`: drift generates row classes (Message, Conversation,
// Storyline, …) whose names collide with the app's models.
import '../data/app_paths.dart';
import '../data/context_store.dart';
import '../data/database.dart' show BondDatabase;
import '../data/db.dart' show appDatabasePath;
import '../data/message_store.dart';
import '../data/setup_store.dart';
import '../services/activity_log.dart';
import '../services/ai_worker.dart';
import '../services/ai_workers.dart';
import '../services/attachments/attachment_bytes.dart';
import '../services/attachments/attachment_cache.dart';
import '../services/attachments/attachment_digest_handler.dart';
import '../services/attachments/attachment_retriever.dart';
import '../services/attachments/attachment_text_handler.dart';
import '../services/attachments/html_snapshot.dart' show htmlSnapshotPng;
import '../services/attention_service.dart';
import '../services/backend/attachment_backend.dart';
import '../services/backend/auth_session.dart';
import '../services/backend/mail_backend.dart';
import '../services/backend/people_backend.dart';
import '../services/backend/teams_backend.dart';
import '../services/context/context_brief_handler.dart';
import '../services/context/context_digest_handler.dart';
import '../services/context/context_reconcile_handler.dart';
import '../services/context/context_retriever.dart';
import '../services/context/directory_access.dart';
import '../services/cloud_drafts.dart';
import '../services/decision/decision_client.dart';
import '../services/decision/decision_heads_file.dart';
import '../services/decision/decision_input.dart' show decisionOwnerString;
import '../services/decision/needs_you_exemplars.dart';
import '../services/draft_handler.dart';
import '../services/draft_stream.dart';
import '../services/drain_gate.dart';
import '../services/embed_handler.dart';
import '../services/extract_handler.dart';
import '../services/gate_repair_service.dart';
import '../services/graph_attachment_backend.dart';
import '../services/graph_auth.dart';
import '../services/graph_mail.dart';
import '../services/graph_people.dart';
import '../services/graph_teams.dart';
import '../services/identity_guard.dart';
import '../services/profile_photos.dart';
import '../services/llm/embeddings_client.dart';
import '../services/llm/llm_client.dart';
import '../services/llm/model_slots.dart';
import '../services/mcp/bond_mcp_client.dart';
import '../services/mcp/mcp_attachment_backend.dart';
import '../services/mcp/mcp_auth.dart';
import '../services/mcp/mcp_mail_backend.dart';
import '../services/mcp/mcp_people_backend.dart';
import '../services/mcp/mcp_teams_backend.dart';
import '../services/message_search.dart';
import '../services/models/managed_model_status.dart';
import '../services/models/model_downloader.dart';
import '../services/models/model_manifest.dart';
import '../services/server/llama_binary.dart';
import '../services/server/model_server_supervisor.dart';
import '../services/server/process_runner.dart';
import '../services/server/server_state.dart';
import '../services/system/system_info.dart';
import '../services/system/updater.dart';
import '../services/needs_you_edits.dart';
import '../services/needs_you_handler.dart';
import '../services/notification_coordinator.dart';
import '../services/owner_lookup.dart';
import '../services/notify/desktop_notifier.dart';
import '../services/pipeline_progress.dart';
import '../services/pipeline_repair_service.dart';
import '../services/progress_bus.dart';
import '../services/notify/local_desktop_notifier.dart';
import '../services/read_ack_queue.dart';
import '../services/restore_service.dart';
import '../services/sample/sample_backends.dart';
import '../services/sample/sample_data.dart';
import '../services/sample/sample_env.dart';
import '../services/storyline_handler.dart';
import '../services/storyline_judge.dart';
import '../services/storyline_service.dart';
import '../services/sync_service.dart';
import '../services/teams_sync.dart';
import '../services/triage_queue.dart';
import '../widgets/app_rail.dart' show RailSection;
import 'navigation_provider.dart';
import 'notify_routing.dart';
import 'prefs_provider.dart';
import 'setup_provider.dart' show setupRestartProvider;

/// One [GraphAuth] for the whole app. Sharing the instance is what makes the
/// in-memory access token and the single-flight refresh guard mean anything —
/// a second instance would hold its own copy of both, and the three SDK
/// backends below are built from this one.
///
/// Typed concretely on purpose: this is the override point for a test that
/// wants a real [GraphAuth] over a faked socket. Nothing in the app reads it —
/// the app consumes [authSessionProvider], [mailBackendProvider] and
/// [teamsBackendProvider], which is what makes swapping the backend a change to
/// those three bodies and nothing else.
final graphAuthProvider = Provider<GraphAuth>((ref) => GraphAuth());

/// When this run of the app started, or null where nothing has said.
///
/// Overridden with `DateTime.now()` in `main()`. The null default is what the
/// processing indicator reads as "show nothing": a widget test that has not
/// deliberately opted in gets the quiet answer, so the indicator arrives with
/// zero churn across the existing suite rather than a hundred rows that
/// suddenly say "thinking…".
final sessionStartProvider = Provider<DateTime?>((ref) => null);

/// Whether this session is allowed to run model work at all.
///
/// A REMEMBERED preference that starts on, seeded here from
/// [AppPrefs.processingOn]. It was session state until Round H, off at every
/// launch so the owner could point the stages at the right servers before
/// anything was spent on the wrong one. The placement rule answers that now:
/// the default server IS the measured one, and a missing key or a dead address
/// parks with a sentence instead of spending attempts. Turning it off still
/// stands the models down for the rest of the session, and it is remembered,
/// so a machine left off comes back off.
///
/// `read` and never `watch`. A watch would rebuild this notifier on every
/// unrelated preference write and reset the switch mid-drain, which is
/// [_enabledReader]'s reasoning exactly. It is safe because `main()` awaits
/// `AppPrefsNotifier.read` before `runApp` and injects the result through
/// `initialAppPrefsProvider`, so the state is populated at the first read.
///
/// It gates the four drains and nothing else. Mail and Teams keep syncing
/// while it is off — the inbox stays current, the models stay idle — and the
/// two things that dial a server without being a drain keep working too:
/// the Models page's Check and Connect probes, which is how a server is
/// checked in the first place, and the query embedding behind the Find field,
/// which a person is waiting on.
final processingProvider =
    StateNotifierProvider<ProcessingNotifier, bool>(
  (ref) => ProcessingNotifier(ref.read(appPrefsProvider).processingOn),
);

/// The switch's state, and the one thing that moves it.
///
/// [initial] stays an optional POSITIONAL parameter: two test overrides
/// construct this notifier bare to say "off, whatever the preferences hold",
/// and the seed belongs to the provider above rather than to the class.
class ProcessingNotifier extends StateNotifier<bool> {
  ProcessingNotifier([super.initial = false]);

  void set(bool on) => state = on;
}

/// The pane the app opens on.
///
/// Home, because the whole point of that screen is to be left up: it is what
/// the app looks like when nobody has asked it for anything in particular.
///
/// A provider rather than a constant so the screen tests that predate Home —
/// they assert on a section overview from the first frame — can override it
/// back to the section they were written against. `home_screen_test.dart` is
/// deliberately the one that does NOT override, which is what pins this
/// default.
///
/// Importing `app_rail.dart` for [RailSection] puts a widget import in a
/// provider file, which is the precedent `navigation_provider.dart` set: the
/// rail's stops ARE the app's section vocabulary.
final initialSectionProvider = Provider<RailSection>(
  (ref) => RailSection.home,
);

/// The MCP session and the wire client under it, built together because they
/// are circular: the client asks the session for a bearer token at every
/// connect, and the session makes its `connection_status` and profile calls
/// through the client. `late final` is what ties that knot — the callback is
/// only ever invoked on a connect, which is long after this body returns.
///
/// One per (mode, server URL). Rebuilt when either changes, which is why the
/// client is closed on dispose: the old connection points at the old server.
final mcpStackProvider = Provider<({McpAuthSession auth, BondMcpClient client})>(
  (ref) {
    final url = Uri.parse(
      ref.watch(appPrefsProvider.select((p) => p.mcpServerUrl)),
    );
    late final McpAuthSession auth;
    final client = BondMcpHttpClient(url, getBearer: () => auth.validJwt());
    auth = McpAuthSession(mcpUrl: url, mcpClient: client);
    ref.onDispose(client.close);
    return (auth: auth, client: client);
  },
);

/// The recorded sample a sandbox build serves (`BOND_SAMPLE_DIR`), parsed
/// once and shared by the four data backends. Read only in a sandbox build:
/// every arm that watches it is behind `sampleModeOn`, so a normal build never
/// starts the parse.
final sampleDataProvider = Provider<Future<SampleData>>(
  (ref) => SampleData.load(sampleDirDefine),
);

/// The three providers the app consumes, and the one switch between the two
/// backends.
///
/// They WATCH the mode rather than reading it once, so `setBackendMode` and
/// `setMcpServerUrl` rebuild this whole graph on their own — the sync service,
/// the Teams connector, the draft notifier and the screens all watch down to
/// here, and every one of them follows. That is the entire mechanism; nothing
/// invalidates anything by hand.
final authSessionProvider = Provider<AuthSession>((ref) {
  // The sample sandbox arm comes FIRST in all five, before the mode is read,
  // so a sandbox build never watches `mcpStackProvider` and never opens an
  // MCP connection. Only the manifest is read for the session, so the auth
  // gate answers before the full parse finishes.
  if (sampleModeOn) {
    return SampleAuthSession(SampleOwner.load(sampleDirDefine));
  }
  final mode = ref.watch(appPrefsProvider.select((p) => p.backendMode));
  return mode == backendModeSdk
      ? ref.watch(graphAuthProvider)
      : ref.watch(mcpStackProvider).auth;
});

/// The open database. Overridden in `main()` after the async open, and in
/// tests with an in-memory one.
///
/// It throws rather than defaulting because opening the real file is async
/// and a Provider body cannot be: a default that silently opened `:memory:`
/// would give a release build an inbox that empties itself on every launch.
final dbProvider = Provider<BondDatabase>(
  (ref) => throw UnimplementedError(
    'dbProvider must be overridden with an open database (see main()).',
  ),
);

final messageStoreProvider =
    Provider<MessageStore>((ref) => MessageStore(ref.watch(dbProvider)));

/// The owner's own local directories — a SECOND store over the same database,
/// for the reason [ContextStore] gives: nothing it holds is mailbox data, and
/// none of it is wiped when an identity changes.
final contextStoreProvider =
    Provider<ContextStore>((ref) => ContextStore(ref.watch(dbProvider)));

/// What this machine can be asked about itself — chip, memory, free disk, and
/// the two calls that keep it awake while a model loads. The real one is a
/// method channel onto the Runner's Swift, on [directoryAccessProvider]'s
/// pattern; a test overrides it with `FakeSystemInfo` and touches no channel.
final systemInfoProvider = Provider<SystemInfo>((ref) => const ChannelSystemInfo());

/// This Mac's chip, memory and OS version, for the Settings fact line that
/// says which tier the machine is in and why. A report, never a judgement:
/// every decision made on this machine's size goes through
/// [machineTierProvider], so there is one rule and one place it lives.
final hardwareInfoProvider = FutureProvider<HardwareInfo>(
  (ref) => ref.watch(systemInfoProvider).hardware(),
);

/// This Mac's tier, recomputed from its memory whenever it is asked for and
/// stored nowhere: the models folder can move to another Mac, and the wizard,
/// the gate and the server supervisor must each read the machine they are on.
/// Unknown memory resolves to [MachineTier.full], the never-refuse rule.
/// A read that FAILS answers [MachineTier.full] too, and that is the same rule
/// as a zero rather than a second one. This future is awaited where the server
/// is launched, on a path with no `try` above it and no way to report a
/// [ServerFailed], so a rejected future would take the launch down over a fact
/// the app could not read. Nothing is refused for that.
/// A channel that never answers resolves [MachineTier.full] too, after
/// [hardwareProbeTimeout], because `ModelServerSupervisor._launch` awaits
/// `buildPreset()` before it emits anything: an unbounded wait there is no
/// server, no `ServerFailed` and nothing on screen, which is worse than every
/// answer this provider can give. That blind answer is REVISABLE: a channel
/// that answers after the timeout re-derives the tier, so the Settings fact
/// line and the button beside it cannot end up describing different machines.
final machineTierProvider = FutureProvider<MachineTier>((ref) async {
  // Set when the timeout answered for a read that had not landed yet. It is
  // what makes that answer revisable, and it is false on every other path.
  var answeredBlind = false;

  // LISTEN rather than watch, and the difference is the whole design here.
  // Watching the hardware STATE would invalidate this provider on the ordinary
  // loading-to-data step, and every caller reads `.future` exactly ONCE —
  // `setup_gate.dart`, `inbox_screen.dart` and the supervisor's preset. An
  // invalidation mid-flight drops the future they are holding, and it is never
  // completed: the gate then never decides and the launch never starts. So the
  // rebuild is asked for by hand, in the one case where the tier and the
  // machine can disagree: a channel that answered AFTER the timeout had
  // already resolved [MachineTier.full] off nothing. Without it a 16 GiB Mac
  // whose channel was slow would sit under a fact line reading 16 GB beside an
  // enabled button writing the full tier's stage picks.
  //
  // Nothing fires on the fast path, where the value arrives before the timeout
  // and `answeredBlind` is still false, and a channel that never answers never
  // changes state, so it stays `full` — the never-refuse rule. A rejection is
  // not a value either, and re-deriving one would only answer `full` again.
  ref.listen<AsyncValue<HardwareInfo>>(hardwareInfoProvider, (_, next) {
    if (answeredBlind && next.hasValue) ref.invalidateSelf();
  });

  // The timeout is a Timer of this provider's own, cancelled on dispose, and
  // NOT `Future.timeout`: that helper's timer belongs to nobody, so a host
  // whose hardware read never lands (every widget test that mounts Settings
  // over a silent platform) tears its tree down with the timer still pending,
  // which the test binding reports as a failure. Here the timer dies with the
  // provider, and a hardware answer that lands first cancels it.
  final answer = Completer<MachineTier>();
  final timer = Timer(hardwareProbeTimeout, () {
    if (answer.isCompleted) return;
    answeredBlind = true;
    debugPrint('tier: this Mac has not answered in $hardwareProbeTimeout, '
        'assuming the full tier until it does');
    answer.complete(machineTierFor(HardwareInfo.unknown.memoryBytes));
  });
  ref.onDispose(timer.cancel);

  // Over [hardwareInfoProvider] rather than the channel again: one round trip
  // and one future, so the fact line and the button are reading the same
  // answer about the same machine. Watched synchronously, as a watch must be.
  ref.watch(hardwareInfoProvider.future).then<void>((hardware) {
    if (!answer.isCompleted) {
      answer.complete(machineTierFor(hardware.memoryBytes));
    }
  }, onError: (Object e) {
    debugPrint('tier: could not read this Mac, assuming the full tier: $e');
    if (!answer.isCompleted) {
      answer.complete(machineTierFor(HardwareInfo.unknown.memoryBytes));
    }
  }).whenComplete(timer.cancel);

  return answer.future;
});

/// What this Mac SERVES on its managed router, under the role placements:
/// the embedding model always, the decision model when it runs here, and the
/// managed generative model (the 27B or the 4B, by `managedGenerativeIdFor`)
/// when that runs here. The hardware tier's view, so a Mac under the full
/// tier's floor is never asked for the 27B.
///
/// [machineTierProvider] still answers what this MAC could hold and stays the
/// question for the Settings fact line and the wizard. This one answers what
/// it WILL serve, and the supervisor's preset is built from it.
///
/// Watched through `select`s on the three facts it needs: [AppPrefs] has no
/// `==`, so watching the whole object would re-derive this on every
/// preference write in the app, and each re-derivation hands the supervisor a
/// new future to await.
final managedManifestProvider = FutureProvider<ModelManifest>((ref) async {
  final manifest = ref.watch(modelManifestProvider);
  final decisionManaged = ref.watch(
    appPrefsProvider.select((p) => p.decisionSpec.id == localDecisionId),
  );
  final generativeManaged = ref.watch(
    appPrefsProvider.select(
      (p) => p.managedServer && p.generativeSpec.id == localGenerativeId,
    ),
  );
  final storedGenerative =
      ref.watch(appPrefsProvider.select((p) => p.generativeManagedModel));
  final tier = await ref.watch(machineTierProvider.future);
  return manifest.forRoles(
    hardwareTier: tier,
    decisionManaged: decisionManaged,
    generativeManagedId: generativeManaged
        ? managedGenerativeIdFor(tier, storedGenerative)
        : null,
  );
});

/// Every folder the app owns. `main()` OVERRIDES this with the located
/// directory, exactly as it overrides [dbProvider], because
/// `getApplicationSupportDirectory()` is async and a provider body cannot be.
///
/// The default is a path under the system temp directory that nothing creates.
/// It exists so a widget test can build the graph without reaching the real
/// support directory, and it is never written to in one: every writer here is
/// behind the managed server, which is off by default.
final appPathsProvider = Provider<AppPaths>(
  (ref) => AppPaths(
    Directory(p.join(Directory.systemTemp.path, 'bond-desktop-unlocated')),
  ),
);

/// Which checkpoints this build downloads — `assets/models/manifest.json`,
/// parsed once in `main()` and handed in here.
///
/// It throws rather than defaulting, exactly as [dbProvider] does and for the
/// same reason: reading an asset is async and a provider body cannot be. A
/// Dart-constant fallback would be worse than a throw — it would be a SECOND
/// place the three checkpoints are named, and the whole point of the manifest
/// is that there is only one.
final modelManifestProvider = Provider<ModelManifest>(
  (ref) => throw UnimplementedError(
    'modelManifestProvider must be overridden with the loaded manifest '
    '(see main()).',
  ),
);

/// The first-run and machine-local bookkeeping — a THIRD store over the same
/// database, for [contextStoreProvider]'s reason: nothing in it is mailbox
/// data and none of it is wiped when an identity changes.
final setupStoreProvider =
    Provider<SetupStore>((ref) => SetupStore(ref.watch(dbProvider)));

/// The app's own llama-server, when it runs one.
///
/// Constructing it starts nothing: `ServerBootstrap` calls `ensureRunning()`
/// once at launch, and that is a no-op while the preference is off.
///
/// It watches the PATHS and the PLATFORM and nothing else. Every preference it
/// needs — the port, the folder, whether it is managed at all — is read inside
/// a closure with `ref.read`, on the rule [stageLlmClientProvider] states: a
/// provider that watched the prefs would be rebuilt the moment somebody moved
/// a setting, and rebuilding this one mid-drain would tear down the supervisor
/// holding the server the drain is talking to. Late binding costs nothing here
/// — every one of these is consulted at the top of a start, never cached.
final modelServerSupervisorProvider = Provider<ModelServerSupervisor>((ref) {
  final paths = ref.watch(appPathsProvider);
  final system = ref.watch(systemInfoProvider);
  final supervisor = ModelServerSupervisor(
    runner: const SystemProcessRunner(),
    supportDir: paths.support,
    binaryPath: LlamaBinary.resolve,
    // The ROLES' manifest ([managedManifestProvider]): the models this Mac
    // serves under the two placements, out of the hardware tier's view, so a
    // role on the owner's server drops its model out of memory here. Asked
    // freshly each start, like the folder and the port beside it, and
    // awaited rather than guessed.
    //
    // It is also where the prefs LEARN the machine tier (`setMachineTier`):
    // the managed generative target's model id depends on it, and this build
    // precedes every request the managed router can answer. And an entry
    // whose files are missing (the decision model before `make
    // decide-install`, a chosen generative model not yet downloaded) is left
    // out, because the server refuses to start with a preset file missing and
    // that must not cost the other models: that role parks on its own.
    buildPreset: () async {
      final tier = await ref.read(machineTierProvider.future);
      ref.read(appPrefsProvider.notifier).setMachineTier(tier);
      final folder = ref.read(appPrefsProvider).effectiveModelsFolder(paths);
      final served = (await ref.read(managedManifestProvider.future))
          .withPresentFiles(folder);
      // What the router will serve, so a managed target naming a model left
      // out (not downloaded, not installed) parks rather than 400s.
      ref.read(appPrefsProvider.notifier).setServedManagedIds({
        for (final model in served.models) model.id,
      });
      return served.toPreset(folder);
    },
    routerPort: () => ref.read(appPrefsProvider).routerPort,
    // A port the app had to move to is REMEMBERED, and remembered before the
    // child is spawned: the preference is what the clients dial and what the
    // next launch's adoption compares its record against.
    onPortMoved: (port) =>
        ref.read(appPrefsProvider.notifier).setRouterPort(port),
    managed: () => ref.read(appPrefsProvider).managedServer,
    beginActivity: system.beginActivity,
    endActivity: system.endActivity,
    // The two drains park when a server is down and do not poll to find out it
    // came back, so something has to tell them. Guarded and `read`, on
    // [embeddingsClientProvider]'s precedent: this callback outlives the body
    // and fires from a health poll, where a torn-down container must cost
    // nothing rather than throw on a timer.
    onReady: () {
      try {
        // Chained, not launched side by side, for the reason every other
        // caller chains — see [pumpTriageThenWorkers]. Every lane, because a
        // server coming back is news to all three and the fast lane's own
        // `onDrained` would only reach the others if it had work of its own.
        //
        // Behind `ready` FIRST, which is new in Round H and is what closes the
        // bearer window: the keychain prefetch is a round trip after `main`
        // injects the preferences, and with processing starting on this pump
        // could beat it and send one unauthenticated request per stage. One
        // await on a future that is normally already complete.
        //
        // And pumped EITHER WAY. `ready` can reject now that the read path
        // writes (the Round G migration), and an unhandled rejection here
        // would cost the supervisor its first pump for the whole session; a
        // prefs load that failed is one 401 the user can see, not a pipeline
        // that never starts.
        Future<void> pump() => pumpTriageThenWorkers(
              triage: () => ref.read(triageQueueProvider).pump(),
              workers: () => ref.read(aiWorkersProvider).pumpAll(),
            );
        unawaited(
          ref.read(appPrefsProvider.notifier).ready.then(
                (_) => pump(),
                onError: (Object _, StackTrace _) => pump(),
              ),
        );
      } catch (_) {}
    },
  );
  ref.onDispose(supervisor.dispose);
  return supervisor;
});

/// The server's state, for the widgets that draw it. Watched by the settings
/// card and by nothing that runs work — see the supervisor above for why the
/// clients must never watch this.
final serverStateProvider = StreamProvider<ServerState>(
  (ref) => ref.watch(modelServerSupervisorProvider).states,
);

/// Where `make decide-install` must put the decision model for this app to
/// read it, when that is not the Makefile's `DECIDE_DIR` default: the decide
/// entry's folder inside a models folder the wizard moved. Null while the
/// models folder is the default one, where the plain command already lands —
/// and then the manifest is never read, so a host that did not override it
/// still builds.
final decideInstallDirProvider = Provider<String?>((ref) {
  final paths = ref.watch(appPathsProvider);
  final folder = ref.watch(
    appPrefsProvider.select((prefs) => prefs.effectiveModelsFolder(paths)),
  );
  if (p.equals(folder, paths.models.path)) return null;
  final decide =
      ref.watch(modelManifestProvider).byRoleOrNull(ModelRole.decide);
  if (decide == null) return null;
  return p.dirname(p.join(folder, decide.relativePath));
});

/// The three role models this Mac would run, with what each costs and
/// whether it is on disk.
///
/// The Managed block's rows are this plus one live fact, and the live fact is
/// not here: `ServerLoading.loaded` moves while somebody is looking at the
/// page, so the widget joins it from [serverStateProvider] and this future
/// stays a reading of the DISK. A few `stat` calls per invalidation, not per
/// frame, which is why the ledger check keeps its `existsSync` — a file can
/// be deleted under a row the ledger still calls done.
///
/// Re-read on exactly two events: **Set up again**, through
/// [setupRestartProvider], because a download can have re-run; and the server
/// reaching ready, because that is when weights that landed during a wizard
/// have certainly been read. Watched through a `select` onto a bool so the
/// states on the way there — one per model as each loads — do not re-run it.
///
/// Three rows keyed `decision`, `generative` and `embed`. The generative row
/// is the managed model this Mac's tier would serve (the 27B on the full
/// tier unless the owner chose the 4B; the 4B on the inbox tier).
/// [ManagedModelStatus.inUse] says whether the placements actually serve it:
/// a role on the owner's server keeps its weights on this disk and holds none
/// of them in memory. The decision row is hand-installed: on disk means the
/// GGUF AND its heads file are in the models folder, with no ledger.
final managedModelsStatusProvider =
    FutureProvider<List<ManagedModelStatus>>((ref) async {
  ref.watch(setupRestartProvider);
  ref.watch(
    serverStateProvider.select((state) => state.valueOrNull is ServerReady),
  );
  final paths = ref.watch(appPathsProvider);
  final master = ref.watch(modelManifestProvider);
  final storedGenerative =
      ref.watch(appPrefsProvider.select((p) => p.generativeManagedModel));
  final tier = await ref.watch(machineTierProvider.future);
  final manifest = master.forTier(tier);
  // What the placements' own preset is built from, so the ids it lists are
  // exactly the files this Mac is asked to serve.
  final served = (await ref.watch(managedManifestProvider.future))
      .models
      .map((file) => file.id)
      .toSet();
  final ledger = await ref.watch(setupStoreProvider).downloadLedger();
  final folder = ref.read(appPrefsProvider).effectiveModelsFolder(paths);

  final rows = <ManagedModelStatus>[];
  // The router id is the FILE's own id: the same manifest builds the router
  // preset, so `ServerLoading.loaded` is keyed by exactly these.
  void add(String roleId, ModelFile? file) {
    if (file == null) return;
    final local = file.isLocal;
    rows.add(ManagedModelStatus(
      roleId: roleId,
      displayName: file.displayName,
      bytes: local
          ? file.sizeBytes + (file.heads?.sizeBytes ?? 0)
          : file.downloadBytes,
      onDisk: local
          ? ModelManifest.localInstalled(file, folder)
          : ledger.isCurrent(file) &&
              File(p.join(folder, file.relativePath)).existsSync(),
      routerId: file.id,
      inUse: served.contains(file.id),
      local: local,
      headsOnDisk: switch (file.headsRelativePath) {
        null => true,
        final heads => File(p.join(folder, heads)).existsSync(),
      },
    ));
  }

  final generativeId = managedGenerativeIdFor(tier, storedGenerative);
  ModelFile? generative;
  for (final file in manifest.models) {
    if (file.id == generativeId) generative = file;
  }
  add('decision', manifest.byRoleOrNull(ModelRole.decide));
  add('generative', generative ?? manifest.byRoleOrNull(ModelRole.bulk));
  add('embed', manifest.byRoleOrNull(ModelRole.embed));
  return rows;
});

/// The thing that fills the models folder.
///
/// It watches the platform, the store and the paths — the three collaborators
/// it is BUILT from — and reads the folder inside a closure, on
/// [modelServerSupervisorProvider]'s rule: a provider that watched the prefs
/// would be rebuilt the moment somebody moved a setting, and rebuilding this
/// one mid-download would abandon a transfer that is hours in. Late binding
/// costs nothing: the folder is consulted at the top of a run, never cached.
final modelDownloaderProvider = Provider<ModelDownloader>((ref) {
  final system = ref.watch(systemInfoProvider);
  final store = ref.watch(setupStoreProvider);
  final paths = ref.watch(appPathsProvider);
  final downloader = ModelDownloader(
    manifest: ref.watch(modelManifestProvider),
    modelsFolder: () =>
        ref.read(appPrefsProvider).effectiveModelsFolder(paths),
    readLedger: store.downloadLedger,
    writeLedger: store.recordDownload,
    sha256: system.sha256,
    beginActivity: system.beginActivity,
    endActivity: system.endActivity,
  );
  ref.onDispose(downloader.dispose);
  return downloader;
});

/// How a picked folder stays readable after a relaunch. The real one is a
/// method channel onto the Runner's Swift; a test overrides it with
/// [PlainDirectoryAccess], which keeps no bookmark and resolves none, and
/// every caller falls back to the stored path.
final directoryAccessProvider =
    Provider<DirectoryAccess>((_) => const ChannelDirectoryAccess());

/// Enforces the one-identity-per-database rule at every completed sign-in.
/// See [IdentityGuard] for why it is a guard rather than a convention.
///
/// The attachment cache is cleared alongside the rows, and has to be: it is a
/// tree of somebody's documents under Application Support, and a wipe that left
/// it standing would hand the next person to sign in the files whose rows it had
/// just deleted.
final identityGuardProvider = Provider<IdentityGuard>(
  (ref) => IdentityGuard(
    ref.watch(messageStoreProvider),
    onWipe: () async {
      // STARTED here, not awaited here. Emptying the cache is a recursive
      // delete of up to two gigabytes, and the sign-in handover must not sit
      // behind a disk. It is safe to let it run on: `wipeAll` has already
      // deleted every row that pointed at those files, so nothing in the app
      // can reach one — this is hygiene on disk rather than part of the
      // one-identity invariant, and it reports its own failure.
      unawaited(
        ref.read(attachmentCacheProvider).clear().catchError(
              (Object e) =>
                  debugPrint('attachment cache not cleared on wipe: $e'),
            ),
      );
      // The LINKS and nothing else, and this one is rows rather than disk.
      // A link names a conversation key or a storyline id that the wipe has
      // just deleted, so leaving it would let a new identity's room — which
      // can be handed the same conversation key by the same connector —
      // inherit the previous account's directories and quote one person's
      // project into another person's reply. The directories themselves stay
      // registered: they are the user's own folders on their own disk, and
      // have nothing to do with whose mailbox was signed in. Started and not
      // awaited for the reason above it, and safe for the same one: the rows
      // that could reach a link through a conversation are already gone.
      unawaited(
        ref.read(contextStoreProvider).unlinkAll().catchError(
              (Object e) => debugPrint('context links not cleared on wipe: $e'),
            ),
      );
    },
  ),
);

/// One recorder for the app. It watches ONLY the store, so a backend switch —
/// which rebuilds the session, both backends, the sync service and the queues
/// — leaves the log and its stream standing, and a panel open across the
/// switch keeps its subscription.
final activityLogProvider = Provider<ActivityLog>((ref) {
  final log = ActivityLog(ref.watch(messageStoreProvider));
  ref.onDispose(log.dispose);
  return log;
});

/// The pipeline's live wire. It watches NOTHING, for [activityLogProvider]'s
/// reason turned up one notch: a backend switch rebuilds the queues that
/// publish onto it, and a home screen open across that switch has to keep the
/// subscription it already has or its table would freeze mid-sync.
final progressBusProvider = Provider<ProgressBus>((ref) {
  final bus = ProgressBus();
  ref.onDispose(bus.dispose);
  return bus;
});

/// Where a draft's words are announced while the model is writing them.
///
/// Beside [progressBusProvider] and watching nothing, for exactly its reason:
/// a composer open across a backend switch has to keep the subscription it
/// already has, or the preview it is showing would stop growing mid-sentence.
final draftStreamBusProvider = Provider<DraftStreamBus>((ref) {
  final bus = DraftStreamBus();
  ref.onDispose(bus.dispose);
  return bus;
});

/// The recorder every stage writes through. Watches only the store and the
/// bus, so it outlives a backend switch along with them.
final pipelineProgressProvider = Provider<PipelineProgress>(
  (ref) => PipelineProgress(
    ref.watch(messageStoreProvider),
    bus: ref.watch(progressBusProvider),
  ),
);

/// The Needs You slider, read fresh on every call: the store-level twin of
/// [AppPrefs.needsYouThreshold] for the services that cannot import the
/// providers.
///
/// A shared closure rather than copies of the same lines, because several
/// things judge against this number and they have to judge against the SAME
/// one: the settle machine deciding whether to interrupt, the needs-you
/// handler moving a chip after a re-decision, the sync's backfill raising
/// chips over history, and the text and draft passes choosing what to do
/// first. A slider read differently by any of them is a tile disagreeing with
/// the toast it came from. Parsed the one way, by
/// [MessageStore.needsYouThreshold].
Future<double> Function() needsYouThresholdReader(MessageStore store) =>
    store.needsYouThreshold;

/// The settle machine. Watches ONLY the store and the log, so a backend
/// switch — which rebuilds the session, both backends, the sync service and
/// the queues — leaves it standing: rebuilding it would reset the arm and
/// re-admit the switch-sync backlog as "new mail".
final notificationCoordinatorProvider = Provider<NotificationCoordinator>((ref) {
  final store = ref.watch(messageStoreProvider);
  final coordinator = NotificationCoordinator(
    store,
    activityLog: ref.watch(activityLogProvider),
    progress: ref.watch(pipelineProgressProvider),
    needsYouThreshold: needsYouThresholdReader(store),
  );
  unawaited(coordinator.start());
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

final mailBackendProvider = Provider<MailBackend>((ref) {
  if (sampleModeOn) return SampleMailBackend(ref.watch(sampleDataProvider));
  final mode = ref.watch(appPrefsProvider.select((p) => p.backendMode));
  return mode == backendModeSdk
      ? GraphMail(ref.watch(graphAuthProvider))
      : McpMailBackend(ref.watch(mcpStackProvider).client);
});

/// The organization's directory, behind whichever backend is selected.
///
/// The same switch as the two above it, and it follows the mode for the same
/// reason: a session pointed at the Bond server must not be searching Graph
/// directly with a token it does not hold.
final peopleBackendProvider = Provider<PeopleBackend>((ref) {
  if (sampleModeOn) return SamplePeopleBackend(ref.watch(sampleDataProvider));
  final mode = ref.watch(appPrefsProvider.select((p) => p.backendMode));
  return mode == backendModeSdk
      ? GraphPeople(ref.watch(graphAuthProvider))
      : McpPeopleBackend(ref.watch(mcpStackProvider).client);
});

/// Faces for avatars, over whichever directory backend is selected.
///
/// Disabled until an account is stored, and that is the load-bearing part: a
/// signed-out app — and every widget test, which stores no account — asks the
/// directory nothing, so an avatar is initials and no call is made to find out
/// what everybody already knows.
final profilePhotosProvider = Provider<ProfilePhotos>((ref) {
  final auth = ref.watch(authSessionProvider);
  return DirectoryProfilePhotos(
    ref.watch(peopleBackendProvider),
    enabled: () async => (await auth.storedAccount) != null,
  );
});

/// Attachment words and bytes, from whichever connector the app is on.
///
/// The third arm of the backend switch, and the one where the two
/// implementations are genuinely different: the MCP server carries the document
/// extractors, so a Word file comes back as text from it and as
/// `skipped/no_extractor` from Graph. Bytes, inline images and OneDrive
/// thumbnails are identical on both.
final attachmentBackendProvider = Provider<AttachmentBackend>((ref) {
  if (sampleModeOn) {
    return SampleAttachmentBackend(ref.watch(sampleDataProvider));
  }
  final mode = ref.watch(appPrefsProvider.select((p) => p.backendMode));
  return mode == backendModeSdk
      ? GraphAttachmentBackend(ref.watch(graphAuthProvider))
      : McpAttachmentBackend(ref.watch(mcpStackProvider).client);
});

/// Where fetched attachments live on this disk.
///
/// The root is a CLOSURE rather than a resolved path because
/// `getApplicationSupportDirectory` is a platform channel with nobody on the
/// other end in a widget test: resolved lazily, a screen that never opens an
/// attachment never calls it. It watches nothing, so a backend switch leaves the
/// cache — and every file already in it — exactly where it was.
final attachmentCacheProvider = Provider<AttachmentCache>(
  (ref) => AttachmentCache(
    () async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'attachments'),
    ),
  ),
);

/// How a PDF's first page becomes a picture — **null by default, deliberately**.
///
/// The only engine that can draw one is pdfrx, and pdfium must not be reachable
/// from a provider build or from any test: `flutter test` has no native library
/// behind it, and a default that reached for one would make every screen test
/// that renders an attachment depend on a binary. `main.dart` overrides this at
/// startup with the real implementation; everything else gets null and simply
/// has no PDF thumbnail.
final pdfThumbnailerProvider = Provider<PdfThumbnailer?>((_) => null);

/// How a web page becomes a picture — the REAL one by default, unlike the PDF
/// thumbnailer above, and the difference is the whole reason this comment
/// exists.
///
/// There is no binary behind it. `htmlSnapshotPng` is a method channel, and a
/// process with no Runner registering that channel — every `flutter test` — gets
/// a `MissingPluginException` the wrapper already turns into null. So the
/// default can be the thing that works in the app without dragging anything
/// into a test, and `main.dart` has no override to remember.
final htmlThumbnailerProvider =
    Provider<HtmlThumbnailer?>((_) => htmlSnapshotPng);

/// What the UI asks for a file: cache first, connector second, row updated.
final attachmentBytesProvider = Provider<AttachmentBytes>(
  (ref) => StoreAttachmentBytes(
    store: ref.watch(messageStoreProvider),
    backend: ref.watch(attachmentBackendProvider),
    cache: ref.watch(attachmentCacheProvider),
    pdfThumbnailer: ref.watch(pdfThumbnailerProvider),
    htmlThumbnailer: ref.watch(htmlThumbnailerProvider),
  ),
);

/// The operating system's notification centre, as this app reaches it.
///
/// Always the REAL notifier, with no test-shaped default: it reports itself
/// unsupported off macOS and Windows, and touches no method channel until
/// something first asks it to authorize or to show — so a test that never
/// settles anything can build this provider freely. A test that DOES settle
/// overrides it with a fake, which is the seam doing its job.
///
/// The tap callback is where navigation is wired in. It lives here rather than
/// in the notifier because `services/` never imports `providers/`: the OS side
/// knows it has a target and nothing about where a thread lives.
final desktopNotifierProvider = Provider<DesktopNotifier>(
  (ref) => LocalDesktopNotifier(
    onTap: (target) =>
        ref.read(navIntentProvider.notifier).request(intentForTarget(target)),
  ),
);

/// Tells the server about reads that already happened locally.
///
/// Held apart from the AI worker although both drain `work_items`, and for the
/// reason [ReadAckQueue] documents: an ack must not queue behind model work.
/// It owns no timer — the two things that pump it are opening a thread and
/// pressing refresh.
final readAckQueueProvider = Provider<ReadAckQueue>((ref) {
  return ReadAckQueue(
    ref.watch(messageStoreProvider),
    ref.watch(mailBackendProvider),
    ref.watch(teamsBackendProvider),
    ref.watch(authSessionProvider),
    activityLog: ref.watch(activityLogProvider),
  );
});

/// Ranking and deferral. Stateless beyond its store, and cheap enough to run
/// on every list load — see [AttentionService] for why it runs there rather
/// than on a schedule of its own.
final attentionServiceProvider = Provider<AttentionService>(
  (ref) => AttentionService(ref.watch(messageStoreProvider)),
);

/// Typed as [MailSync], not [SyncService], so a test can override it with a
/// stand-in that never touches the network. Typed out on the declaration as
/// well: the re-decide reads [triageQueueProvider] at call time and the queue
/// watches this provider, an inference cycle (never a build-time one).
final Provider<MailSync> syncServiceProvider = Provider<MailSync>(
  (ref) => SyncService(
    ref.watch(mailBackendProvider),
    ref.watch(messageStoreProvider),
    activityLog: ref.watch(activityLogProvider),
    // What tells an open home screen that a message exists at all. Every later
    // stage announces itself from the queues; ingest happens here.
    progress: ref.watch(pipelineProgressProvider),
    // A callback, not a value: the account is a keychain read, and this
    // provider is built by plenty that never syncs. The sync asks once, on its
    // first pass; until the answer arrives no message is marked as addressed
    // to the user.
    userAddress: () => ref.read(authSessionProvider).storedAccount.then(
          (account) => account?.mail ?? account?.userPrincipalName,
        ),
    // For the one-shot needs-you backfill, which judges history against the
    // same slider the settle machine judges live mail against.
    needsYouThreshold: needsYouThresholdReader(ref.watch(messageStoreProvider)),
    // `ref.read` inside the closure, never `watch`: watching would rebuild
    // this provider — and abort the drain running on it — the moment someone
    // moved the setting, the same hazard [stageLlmClientProvider] documents
    // below.
    lookbackDays: () => ref.read(appPrefsProvider).mailLookbackDays,
    // What puts one `context_reconcile` per registered directory at the tail
    // of every pass — the whole mechanism by which a directory stays level
    // with the disk without a file-system watcher.
    contextStore: ref.watch(contextStoreProvider),
    // The one-shot over the threads that were filed and embedded before the
    // gates could speak first. `read` inside the closure, for the reason the
    // pumps elsewhere in this file give.
    repairGatedConversations: () =>
        ref.read(gateRepairServiceProvider).repairAll(),
    // The install-time re-decide, on the triage queue that owns the decision
    // writers. `read` inside the closure too: the queue watches this provider
    // for its body fetch.
    redecide: () => ref.read(triageQueueProvider).redecideStale(),
  ),
);

final teamsBackendProvider = Provider<TeamsBackend>((ref) {
  if (sampleModeOn) return SampleTeamsBackend(ref.watch(sampleDataProvider));
  final mode = ref.watch(appPrefsProvider.select((p) => p.backendMode));
  return mode == backendModeSdk
      ? GraphTeams(ref.watch(graphAuthProvider))
      : McpTeamsBackend(ref.watch(mcpStackProvider).client);
});

/// The Teams connector, refreshed only by something the user did.
///
/// Deliberately NOT folded into [syncServiceProvider]: that one is driven by a
/// sixty-second timer, and Microsoft's terms for the Teams messaging endpoints
/// forbid polling them in the background. Keeping the two providers apart is
/// what makes "the timer cannot reach Teams" a fact about the wiring rather
/// than a rule someone has to remember.
///
/// [TeamsSync.syncNow] returns immediately when `Chat.Read` was not granted,
/// so a tenant that refused consent costs zero requests and shows no error.
final teamsSyncProvider = Provider<TeamsSync>((ref) {
  final auth = ref.watch(authSessionProvider);
  return TeamsSync(
    ref.watch(teamsBackendProvider),
    ref.watch(messageStoreProvider),
    canSync: () => auth.hasScope('chat.read'),
    activityLog: ref.watch(activityLogProvider),
    progress: ref.watch(pipelineProgressProvider),
    // `ref.read` inside the closure, never `watch`: watching would rebuild this
    // provider — and abort a refresh running on it — the moment someone moved
    // the setting. The same rule [syncServiceProvider] follows above.
    lookbackDays: () => ref.read(appPrefsProvider).teamsLookbackDays,
  );
});

/// One chat client per pipeline stage. Constructing one opens nothing — the
/// first call is what discovers whether a server is listening.
///
/// **Routing is a rule.** Which server and model a stage dials is resolved at
/// the top of every request by `AppPrefs.specForStage` — every text stage on
/// the ONE generative model, the two draft stages on the optional cloud-drafts
/// target when it is set and allowed — so moving a role is a setting rather
/// than an edit here. What this file still decides is the stage's COMPILED
/// fallback, which is what the client answers with if the resolver ever
/// throws, and its timeout.
///
/// **Down is down.** A call to a server that is not running throws
/// [LlmUnavailableException] and the drain parks, exactly as it always has.
/// There is deliberately no fallback to another target.
///
/// **One activity log for all of them**, so a log shows every call the
/// pipeline paid for.
///
/// It watches ONLY the activity log. The placements, the specs and the bearer
/// are reached by `ref.read` of the NOTIFIER — not the state — INSIDE the
/// resolver closure, on the precedent [embeddingsClientProvider] set: the
/// callback outlives this body, the client guards the read itself, and a
/// `.notifier` read subscribes to nothing. That is what keeps a prefs write
/// from rebuilding a client, and so from tearing down the worker mid-drain
/// that holds it — `llm_routing_test.dart` is what pins it.
final stageLlmClientProvider = Provider.family<LlmClient, String>(
  (ref, stageId) {
    final slot = stageSlot(stageId);
    // What a resolver that threw falls back to. Every text stage is
    // generative now, so the one compiled generative default serves them all.
    const fallback = generativeSlotDefault;
    return LlmClient(
      baseUrl: fallback.baseUrl,
      // Its own name as well as its own URL: a runtime that serves more than
      // one model routes on this field, so a stage's client must say which
      // of them it is asking for.
      model: fallback.model,
      resolveTarget: () =>
          ref.read(appPrefsProvider.notifier).targetForStage(stageId),
      onCall: ref.watch(activityLogProvider).noteLlmCall,
      // Sized to the longest draft this app can legitimately ask for; see
      // [LlmClient.proseTimeout] for the arithmetic. EVERY generative stage
      // gets it since the decision-model round: one generative model does
      // the short calls and the drafts alike, and on the 27B a short call
      // behind a draft in the same slot can wait that long. Anything else
      // (no stage reaches here with another slot today) keeps the generic
      // 120.
      timeout: slot == ModelSlot.generative ? LlmClient.proseTimeout : null,
    );
  },
);

/// The FAST lane's gate: the triage drain and the fast worker, and nothing
/// else.
///
/// It keeps those two drains from running at once. Since the decision-model
/// round's Phase 6 triage no longer calls the generative server (its one
/// model is the decision model), so the old reason — two drains
/// double-booking one server's slots — no longer holds for triage. It still
/// shares the gate for ORDERING: triage speaks before the worker claims a
/// message's needs-you and text work, the yield ticket lets a newly arrived
/// message's triage cut into a long worker drain, and `onDrained` hands the
/// worker the refs triage just wrote. The cost is that a triage pump waits
/// for the worker item already in flight (a text call can be seconds). A
/// separate triage gate — ordering kept by the claim's untriaged guard and
/// `onDrained` alone — is a follow-up round candidate. It deliberately does NOT
/// serialize the handful of requests one drain has in flight — those are
/// batched by the server on purpose, and are what the slot count is sized
/// for.
///
/// One instance for the app, or it would serialize nothing — see [DrainGate].
final fastDrainGateProvider = Provider<DrainGate>((ref) => DrainGate());

/// The STORYLINE lane's gate — the six storyline passes, and the two writers
/// that have to be serialised against them.
///
/// Its own gate rather than the fast one, because the storyline passes are
/// where the 27B's minutes are: a recap behind the fast lane's gate would sit
/// in front of the next message's triage, which is the whole thing the split
/// is for. The two writers it also holds are [gateRepairServiceProvider]'s
/// storyline half and the charter offer wired into [ContextBriefHandler]
/// below; both used to be serialised against the passes by accident, because
/// there was only ever one gate.
final storylineDrainGateProvider = Provider<DrainGate>((ref) => DrainGate());

/// The DRAFT lane's gate. One drain, on the prose server, at
/// `AppPrefs.proseParallel` items in flight.
///
/// A gate of its own so a draft a person is waiting for never sits behind a
/// sweep or twenty recaps. Where this lane and the storyline lane genuinely
/// contend — both send prose to the 27B — the SERVER queues them, which costs
/// the draft one recap rather than a whole drain pass.
final draftDrainGateProvider = Provider<DrainGate>((ref) => DrainGate());

/// What a gate that speaks late has to undo — see [GateRepairService].
///
/// Reaching forward to [storylineServiceProvider], declared further down this
/// file, is ordinary Riverpod: a provider resolves where it is READ, which is
/// inside this callback. There is no cycle to worry about — the storyline
/// service takes the store, the clients, the log, the embeddings, the
/// recorder and the context library, and none of them is a drain.
final gateRepairServiceProvider = Provider<GateRepairService>(
  (ref) => GateRepairService(
    ref.watch(messageStoreProvider),
    ref.watch(storylineServiceProvider),
    activityLog: ref.watch(activityLogProvider),
    // The lane whose passes this repair has to be serialised against — see
    // [GateRepairService]. Until the drains were split, the one shared gate
    // did this by accident.
    storylineGate: ref.watch(storylineDrainGateProvider),
  ),
);

/// The triage worker. Exactly one for the whole app: it is one queue over
/// shared rows, and a second instance would claim the same messages.
final triageQueueProvider = Provider<TriageQueue>((ref) {
  final queue = TriageQueue(
    ref.watch(messageStoreProvider),
    // Triage fetches its own bodies rather than waiting for a human to open
    // the thread. Taken off [MailSync], so this stays typed to the interface
    // a test can override.
    ensureBody: ref.watch(syncServiceProvider).ensureMessageBody,
    // The FAST lane's gate, shared with the fast worker for ordering (see
    // [fastDrainGateProvider]); triage itself calls only the decision model.
    gate: ref.watch(fastDrainGateProvider),
    activityLog: ref.watch(activityLogProvider),
    progress: ref.watch(pipelineProgressProvider),
    // The slider a decision's chip rule reads (`applyDecision`): a re-decided
    // settled message whose answer crosses it has its chip moved.
    needsYouThreshold:
        needsYouThresholdReader(ref.watch(messageStoreProvider)),
    // The processing switch — see [processingProvider] and [_enabledReader].
    enabled: _enabledReader(ref),
    // The knock on the worker's door. Extraction and needs-you are no longer
    // handed a message triage has not spoken about, so a worker drain that
    // won the gate first leaves them pending and would sit on them until the
    // next sync — this is what makes it walk again the moment the gates have
    // answered. Reaching forward to [aiWorkerProvider], declared further down
    // this file, is ordinary Riverpod: a provider resolves where it is READ,
    // which is inside this callback, long after both exist. Unawaited because
    // a worker drain is minutes of model time and the triage pump that fires
    // it must not wait for it; the guard is for the read itself, which throws
    // against a torn-down container. The pairs this drain wrote verdicts for
    // ride along as `first:`, so the worker runs those messages' needs-you
    // and extraction ahead of whatever backlog it was already walking.
    onDrained: (triaged) async {
      try {
        unawaited(ref.read(aiWorkerProvider).pump(first: triaged));
      } catch (_) {}
    },
    // A gate landing on a message whose thread has nothing kept left in it
    // leaves an embedding, storyline memberships and a queued filing behind.
    // `read` inside the closure, on the same precedent as the pumps above:
    // this is called long after the body returns.
    onGated: (source, id) => ref
        .read(gateRepairServiceProvider)
        .afterGate(source, id, reason: 'extracted_then_gated'),
    // The decision model: the ONLY model triage calls — the text is the
    // message-text stage's, on the fast lane. Late-bound (its target resolves
    // per call), so a prefs write rebuilds no queue.
    decisionClient: ref.watch(decisionClientProvider),
    // The decision state's owner line. Asked without waiting (see the
    // queue's `_askOwner`), so a keychain read never holds a claim.
    owner: _ownerLookup(ref),
    // The owner's Needs You answers, which replace the model's inside
    // `applyDecision` — for the claim and the install-time re-decide alike.
    exemplars: ref.watch(needsYouExemplarsProvider),
  );
  ref.onDispose(queue.dispose);
  return queue;
});

/// The owner's Needs You labels in memory (`NeedsYouExemplars`). ONE for the
/// app, shared by every decision path and by the presses, so a press's
/// `invalidate()` is seen by the very next decision anywhere.
final needsYouExemplarsProvider = Provider<NeedsYouExemplars>(
  (ref) => NeedsYouExemplars(ref.watch(messageStoreProvider)),
);

/// "Remove from Needs You" / "Add to Needs You", the sweep inside each press
/// and the undo (`NeedsYouEdits`), over the same decision client, exemplars,
/// owner line and slider as the triage queue. The notifier reloads the list
/// after a press, which already holds the sweep's writes.
final needsYouEditsProvider = Provider<NeedsYouEdits>((ref) {
  final store = ref.watch(messageStoreProvider);
  final owner = memoizedOwner(_ownerLookup(ref));
  final decision = ref.watch(decisionClientProvider);
  return NeedsYouEdits(
    store,
    decision,
    ref.watch(needsYouExemplarsProvider),
    owner: () async => decisionOwnerString(await owner()),
    threshold: needsYouThresholdReader(store),
    progress: ref.watch(pipelineProgressProvider),
    // The processing switch — see [processingProvider] and [_enabledReader]:
    // the sweep and the undo stop when it is off, so a reset is not raced.
    enabled: _enabledReader(ref),
    // Read per press: a stored decision stands in for a model call only
    // under the model the client answers with now.
    modelTag: () => decision.modelTag,
  );
});

/// The embedding server. A second llama-server on its own port, started by
/// `make embed` — and, unlike the model above, entirely optional at runtime:
/// with nothing listening, every call returns null and the app is exactly what
/// it was before this phase.
final embeddingsClientProvider = Provider<EmbeddingsClient>(
  (ref) => EmbeddingsClient(
    // Read at call time, exactly as the two chat clients resolve theirs: the
    // managed router's port moves the next embedding without rebuilding this
    // client or anything downstream of it.
    resolveTarget: () => ref.read(appPrefsProvider).embedRequestTarget,
    // Whose job it is to start the server decides the sentence. `make embed`
    // is the right advice only while the user runs the servers; when the app
    // does, the fix is a card in Settings and naming a Makefile target would
    // send them to a workflow they have opted out of.
    describeUnavailable: () => ref.read(appPrefsProvider).managedServer
        ? 'is not running — see Settings, Models'
        : null,
    // One row per distinct reason, which is what the client's own dedupe
    // already guarantees. `read` and not `watch`: the callback outlives this
    // body and must not make the client depend on the log's lifetime. The
    // guard is for the read itself — against a torn-down container it throws,
    // and this callback sits inside the failure path of a client whose whole
    // contract is that failure costs nothing.
    // Async so the catch still covers the write itself: `record` returns a
    // future, and a fire-and-forget call would put its failure outside this
    // try. The callback's own return value is discarded either way.
    onFail: (reason) async {
      try {
        await ref.read(activityLogProvider).record(
              'embed_fail',
              status: 'error',
              detail: {'reason': reason},
            );
      } catch (_) {}
    },
  ),
);

/// The decision model's heads file, cached (see [DecisionHeadsFile]).
///
/// The path is `<models folder>/<the decide entry's heads path>`, asked on
/// every call because the folder is a preference; READ, never watched, on
/// [modelServerSupervisorProvider]'s rule. A manifest with no decide entry
/// (a test fixture) resolves to a path that is never there, which reads as
/// not installed.
///
/// The manifest is READ inside the path closure rather than watched: the
/// triage queue holds the decision client, so a container that never loaded
/// a manifest (a widget test that builds the queue and never triages) must
/// still be able to build it. An unreadable manifest reads as not installed.
final decisionHeadsProvider = Provider<DecisionHeadsFile>((ref) {
  final paths = ref.watch(appPathsProvider);
  return DecisionHeadsFile(() {
    final ModelManifest manifest;
    try {
      manifest = ref.read(modelManifestProvider);
    } catch (_) {
      return '';
    }
    final heads = manifest.byRoleOrNull(ModelRole.decide)?.headsRelativePath;
    if (heads == null) return '';
    return p.join(
      ref.read(appPrefsProvider).effectiveModelsFolder(paths),
      heads,
    );
  });
});

/// The decision client's HTTP client: the one seam a test overrides with a
/// `MockClient` to see which requests the app's own wiring makes.
final decisionHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// The decision model's client, on the triage path: [triageQueueProvider]
/// runs one decision per kept inbound message before the text call.
///
/// Late-bound on [stageLlmClientProvider]'s rule: the target is resolved
/// through the NOTIFIER at the top of every call — the managed router's
/// `/v1/embeddings` under `bond-decide`, the owner's decision server with its
/// own key, or the hand-started `make decide` server — so a prefs write
/// rebuilds nothing. For an encoder-heads server the heads come off this
/// Mac's disk, and a missing heads file is a [DecisionUnavailableException],
/// which parks the pass rather than failing it. A target on Your server is
/// asked its kind first, and a systemone server (Kev) never reads the heads.
final decisionClientProvider = Provider<DecisionClient>((ref) {
  final heads = ref.watch(decisionHeadsProvider);
  return DecisionClient(
    resolveTarget: () =>
        ref.read(appPrefsProvider.notifier).targetForStage('decision'),
    heads: heads.current,
    client: ref.watch(decisionHttpClientProvider),
    onCall: ref.watch(activityLogProvider).noteLlmCall,
    // Your server is the decision spec's `box-decide` target at that same
    // address. READ at the call, on the resolver's rule; a container torn
    // down mid-drain answers no, and the call takes the encoder path it
    // took before there was a second kind.
    isYourServer: (target) {
      try {
        final spec = ref.read(appPrefsProvider).decisionSpec;
        return spec.id == boxDecideId && spec.url == target.baseUrl;
      } catch (_) {
        return false;
      }
    },
    // The file the managed router serves for the decision role, for the
    // heads pairing check: the router lists only its preset ids, and the
    // preset serves the manifest's file. Null for any other target (the
    // client reads that server's own listing), and for a container without
    // a manifest, which skips the check rather than refusing.
    servedFile: (target) {
      try {
        final prefs = ref.read(appPrefsProvider);
        final spec = prefs.decisionSpec;
        if (!prefs.managedServer ||
            spec.id != localDecisionId ||
            spec.url != target.baseUrl) {
          return null;
        }
        return ref.read(modelManifestProvider).byRoleOrNull(ModelRole.decide)
            ?.file;
      } catch (_) {
        return null;
      }
    },
  );
});

/// A decision Connect's last question before it writes: is the server at
/// [url] the decision model? For llama-server `/v1/models` cannot say — it
/// lists whatever name it was started with — so this is the client's own
/// kind check and identity probe ([DecisionClient.checkServer]; a Kev server
/// is told by the question hash it lists), with the key the write would
/// store: the typed one, else the stored one unless the host changed
/// ([clearKey]). Throws the sentence as an [ArgumentError], which the form
/// draws under its field, and nothing is written. Settings and the wizard
/// both call it, so neither says Connected over the embedding model's port.
Future<void> refuseWrongDecisionServer(
  DecisionClient client,
  AppPrefsNotifier prefs, {
  required String url,
  required String model,
  String? key,
  required bool clearKey,
}) async {
  final refusal = await client.checkServer(
    url: url,
    model: model,
    bearer: key ?? (clearKey ? null : prefs.bearerFor(boxDecideId)),
  );
  if (refusal != null) throw ArgumentError(refusal);
}

/// Semantic search over messages.
///
/// A plain `Provider` because it holds nothing: it is the pairing of the
/// embedding client with the store, and the one place that knows a query and a
/// document are embedded under different prefixes.
final messageSearchProvider = Provider<MessageSearch>(
  (ref) => MessageSearch(
    ref.watch(messageStoreProvider),
    ref.watch(embeddingsClientProvider),
    context: ref.watch(contextStoreProvider),
  ),
);

/// The passages of a thread's documents a reply may quote.
///
/// A plain `Provider` for [messageSearchProvider]'s reason and beside it on
/// purpose: the two are the same pairing of store and embedding client, split
/// only by scope — search asks the whole mailbox, this one asks a thread and
/// can never be made to ask more.
final attachmentRetrieverProvider = Provider<AttachmentRetriever>(
  (ref) => AttachmentRetriever(
    ref.watch(messageStoreProvider),
    ref.watch(embeddingsClientProvider),
  ),
);

/// What the owner's own registered directories know about the message being
/// answered.
///
/// A plain `Provider` for [messageSearchProvider]'s reason: it holds nothing
/// and is the pairing of three things that each hold their own state. The
/// mailbox store is here because the query vector is the reply-to MESSAGE's,
/// which is the one fact this retrieval needs from the other side of the
/// store split.
final contextRetrieverProvider = Provider<ContextRetriever>(
  (ref) => ContextRetriever(
    ref.watch(messageStoreProvider),
    ref.watch(contextStoreProvider),
    ref.watch(embeddingsClientProvider),
    // One small structured call per directory-fed draft, on the generative
    // model like every other text stage — [stageLlmClientProvider].
    selectClient: ref.watch(stageLlmClientProvider('context_select')),
    // `ref.read` inside the closure, never `watch`, in the `lookbackDays`
    // shape above and for its reason: watching would rebuild this provider —
    // and the worker holding it, mid-drain — the moment somebody moved the
    // switch. The closure is called while a pack is being built, which is
    // exactly when the current answer is wanted.
    selectExpand: () => ref.read(appPrefsProvider).contextSelectExpand,
  ),
);

/// Restoring one gate-dropped message.
///
/// A plain `Provider` for [messageSearchProvider]'s reason: it holds nothing
/// of its own, it is the wiring between the store, the recorder, and the two
/// drains that have to be woken once the rows are written.
///
/// `read` inside the pump closures, on the callbacks-outlive-the-body
/// precedent documented at [embeddingsClientProvider]: the closures are called
/// long after this body returns, and a `watch` would tie this service's
/// lifetime to the queues'.
final restoreServiceProvider = Provider<RestoreService>(
  (ref) => RestoreService(
    ref.watch(messageStoreProvider),
    progress: ref.watch(pipelineProgressProvider),
    ensureBody: ref.watch(syncServiceProvider).ensureMessageBody,
    pumpTriage: () => ref.read(triageQueueProvider).pump(),
    // Every lane, not the fast one: a restored message owes an extraction AND
    // whatever that extraction queues.
    pumpWork: () => ref.read(aiWorkersProvider).pumpAll(),
    activityLog: ref.watch(activityLogProvider),
  ),
);

/// Retrying the stages one stalled message still owes.
///
/// A plain `Provider` and `read` inside the pump closures, both for
/// [restoreServiceProvider]'s reasons — see its comment; this is the same
/// wiring over the same two drains, for the rows Restore is not about.
final pipelineRepairServiceProvider = Provider<PipelineRepairService>(
  (ref) => PipelineRepairService(
    ref.watch(messageStoreProvider),
    progress: ref.watch(pipelineProgressProvider),
    pumpTriage: () => ref.read(triageQueueProvider).pump(),
    // Every lane, for [restoreServiceProvider]'s reason: a Retry can owe a
    // stage on any of the three.
    pumpWork: () => ref.read(aiWorkersProvider).pumpAll(),
    // For the settle backstop a Retry runs when a row owes no stage at all.
    threshold: needsYouThresholdReader(ref.watch(messageStoreProvider)),
    // An Ignore is a gate arriving after the pipeline has already run.
    onGated: (source, id) => ref
        .read(gateRepairServiceProvider)
        .afterGate(source, id, reason: 'ignored'),
    activityLog: ref.watch(activityLogProvider),
  ),
);

/// The FAST lane's worker — the kinds a new message's first seconds run
/// through, and nothing that dials the 27B.
///
/// One for the whole app, for the same reason there is one
/// [triageQueueProvider]: it is one queue over shared rows. Its handlers drain
/// in list order, so the order here is the order the work happens in — and
/// that order is unchanged from when this list held all fourteen kinds; what
/// left it are the six storyline passes ([storylineWorkerProvider]) and the
/// draft ([draftWorkerProvider]).
///
/// It KEEPS its name and its type. Twenty tests construct an `AiWorker`
/// directly and six read this provider; the fast lane is what every one of
/// them means by "the worker".
///
/// Its own load on the generative server is one kind at a time — needs-you,
/// then extraction at the target's text width (`LlmTargetSpec.textParallel`),
/// then the attachment digests at the same width — and the gate it shares
/// with the triage drain
/// orders the two (triage itself calls only the decision model since the
/// decision-model round; see [fastDrainGateProvider]). The storyline and
/// draft lanes are on gates of their own and dial the same generative model,
/// so the SERVER queues whatever they add.
final Provider<AiWorker> aiWorkerProvider = Provider<AiWorker>((ref) {
  final worker = _lane(
    ref,
    handlers: [
      // First, and it drains completely before extraction starts. The verdict
      // has to be ON the row before anything asks about it: extraction's draft
      // pre-gate reads the message as it stands, and the settle pass asks the
      // same row later in the drain. Running the two alongside each other would
      // have half the mailbox pre-gated against a verdict that had not been
      // written yet.
      NeedsYouHandler(
        ref.watch(messageStoreProvider),
        // The decision model, for a message whose decision is missing or was
        // made without the owner known. The same client the triage pass uses.
        decisionClient: ref.watch(decisionClientProvider),
        activityLog: ref.watch(activityLogProvider),
        // An answer this pass CHANGES has to move the chip beside it, and
        // moving it means re-asking `notifyWorthy` — which needs the recorder
        // to write through and the owner's slider.
        progress: ref.watch(pipelineProgressProvider),
        needsYouThreshold:
            needsYouThresholdReader(ref.watch(messageStoreProvider)),
        owner: _ownerLookup(ref),
        // The owner's Needs You answers, for a re-decide here; the copy step
        // reads them off the stored decision.
        exemplars: ref.watch(needsYouExemplarsProvider),
        // The tag a fresh vector carries now: a stored decision with no
        // vector under it is decided again rather than copied, so the
        // owner's presses can compare it.
        modelTag: () => ref.read(decisionClientProvider).resolvedModelTag(),
      ),
      // The message-text stage next (kind `extract`). The thread's clustering
      // card is built from what it writes, so it is what decides, by the
      // card's hash, whether a thread's storyline assign is owed; it queues
      // the assign and wakes the storyline lane per thread, and the assign
      // pass embeds the card (`StorylineService.vectorFor`). The sweep still
      // waits for this backlog (`StorylineTuning.sweepExtractFloor`).
      ExtractHandler(
        ref.watch(messageStoreProvider),
        // The message-text stage: the one generative call per kept message.
        ref.watch(stageLlmClientProvider('message_text')),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
        progress: ref.watch(pipelineProgressProvider),
        // The draft lane, woken as the row is written rather than at the end
        // of this drain. A `read` inside the closure of a DIFFERENT lane's
        // provider, which is allowed; a `watch` here would be a cycle through
        // the provider being built, and a read of THIS lane's own provider
        // would be the self-dependency the note at the top of this body is
        // about. Guarded, on [_lane]'s own `onDrained` shape: the closure
        // outlives this body and fires from inside a drain, where a
        // torn-down container must cost nothing rather than fail the
        // extraction row. On a sixty-message backlog this is the difference
        // between a prefetch starting seconds after its extraction and
        // minutes after it.
        onDraftQueued: () {
          try {
            unawaited(ref.read(draftWorkerProvider).pump());
          } catch (_) {}
        },
        // The storyline lane, woken as each thread's assign is queued, on
        // `onDraftQueued`'s reasoning and shape: a `read` of a DIFFERENT
        // lane's provider inside the closure, guarded. Without it the lane
        // was woken only by this drain's end, so every assign waited for the
        // whole extraction backlog.
        onStorylineQueued: () {
          try {
            unawaited(ref.read(storylineWorkerProvider).pump());
          } catch (_) {}
        },
        // When a reply is written ahead of being asked for — the user's
        // setting, read at the moment each message finishes rather than
        // captured here. `ref.read` inside the closure, never `watch`, in
        // [contextRetrieverProvider]'s `selectExpand` shape and for its
        // reason: a watch would rebuild this provider, and the worker holding
        // it mid-drain, the moment somebody moved the control.
        draftPolicy: () => ref.read(appPrefsProvider).draftPolicy,
        // How many message-text calls are in flight: the target's text width,
        // read on every claim for [draftPolicy]'s reason.
        textParallel: () =>
            ref.read(appPrefsProvider).specForStage('message_text')
                ?.textParallel ??
            3,
      ),
      // After extraction. The summary it embeds is the text stage's, and the
      // drain order keeps the generative server's slots for extraction while
      // there is extraction left to do. It talks to no chat model: a park
      // here is a park on the embedding server, and it parks only its own
      // kind. The search vector only; search vectors never fed the storyline
      // pool.
      EmbedHandler(
        ref.watch(messageStoreProvider),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
      ),
      // Reading the documents, then understanding them — in that order,
      // because the digest below has nothing to read until the words are
      // stored. Both sit here, after the message text and the message
      // embeddings: the drain reaches a kind only when every kind above it
      // claims nothing, so attachments run after message text. Neither is in
      // the notification settle set: an attachment must never hold up a
      // verdict about the message it came with.
      //
      // The text handler talks to no chat model, so a park here is a park on
      // the embedding server and it parks only its own kind.
      AttachmentTextHandler(
        ref.watch(messageStoreProvider),
        ref.watch(attachmentBackendProvider),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
      ),
      AttachmentDigestHandler(
        ref.watch(messageStoreProvider),
        // The generative model, like every text stage. See
        // [stageLlmClientProvider].
        ref.watch(stageLlmClientProvider('attachment_digest')),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
        // The same text width as extraction, read the same way.
        textParallel: () =>
            ref.read(appPrefsProvider).specForStage('message_text')
                ?.textParallel ??
            3,
      ),
      // The owner's own directories, read here and nowhere else in the drain.
      // It talks to no chat model — the embedding server is its only server —
      // so a park here parks only its own kind, and a missing `make embed`
      // never sits in front of the storylines. Ahead of them and of the
      // drafts on purpose: a reply written later in this same drain reads the
      // index this pass has just brought level with the disk.
      ContextReconcileHandler(
        ref.watch(contextStoreProvider),
        ref.watch(embeddingsClientProvider),
        ref.watch(directoryAccessProvider),
        activityLog: ref.watch(activityLogProvider),
        // Where the pass queues the two kinds below. Both are enqueued from
        // inside the walk, so a directory that changed is digested and
        // re-briefed in the drain that noticed.
        workQueue: ref.watch(messageStoreProvider),
      ),
      // Digests before the brief, and both immediately after the walk that
      // queues them: the brief is compiled FROM the digest map, so a drain
      // that ran it first would compile yesterday's map. Both ahead of the
      // storylines and the drafts, so a reply written later in this same
      // drain reads a brief that already knows what changed this morning.
      ContextDigestHandler(
        ref.watch(contextStoreProvider),
        // The generative model, like every text stage. See
        // [stageLlmClientProvider].
        ref.watch(stageLlmClientProvider('context_file_digest')),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
      ),
      ContextBriefHandler(
        ref.watch(contextStoreProvider),
        ref.watch(stageLlmClientProvider('context_brief')),
        activityLog: ref.watch(activityLogProvider),
        // A new brief is a new answer to "what is this project", which is the
        // other thing a charter can be. Riverpod resolves a provider when it
        // is read rather than where it is declared, so reaching forward to
        // [storylineServiceProvider] — declared further down this file — is
        // ordinary rather than a cycle.
        //
        // Dispatched onto the STORYLINE lane, because the offer writes a
        // storyline's `charterSuggestion` and the refresh pass writes the same
        // column: with the drains split they are two writers on two lanes, and
        // last-writer-wins between them is a suggestion that flickers. The
        // gate makes the offer wait for the pass instead.
        //
        // Not awaited, and the return value is therefore 0: this handler is on
        // the FAST lane, and waiting here would put a sweep in front of the
        // next message's context brief. The cost is one activity row that no
        // longer counts charters offered — `charters_offered` is simply absent
        // now, which is what the key's `if (charters > 0)` guard already does
        // when nothing was offered.
        onBriefChanged: (dirId) async {
          final gate = ref.read(storylineDrainGateProvider);
          final storylines = ref.read(storylineServiceProvider);
          unawaited(
            gate.run(() => storylines.offerDirectoryCharters(dirId)).catchError(
                  (Object e) {
                    debugPrint('charter offer failed: $e');
                    return 0;
                  },
                ),
          );
          return 0;
        },
      ),
    ],
    gate: fastDrainGateProvider,
    // What used to be list position. The storyline and draft rows this lane's
    // handlers just wrote are drained by workers that have no idea they were
    // written, so the end of a fast drain is where they are told. It fires
    // after an EMPTY fast drain too, which is the case that matters most: a
    // Restore or a Regenerate enqueues a row directly, and the lane that owns
    // it has to be woken by something.
    wakes: [storylineWorkerProvider, draftWorkerProvider],
    // The sweep stands down over an unsettled mailbox, so something has to
    // tell it the mailbox settled, and a fast lane that has just gone quiet
    // IS that signal: extraction, which fills the pool, and the needs-you
    // judgement both drain here. Gated on the count because `onDrained` fires
    // after an empty drain too — a Restore or a Regenerate enqueues a row
    // directly, and an ungated requeue would run a whole sweep after every
    // idle pump.
    // `requeueWork` never touches a `processing` sweep, and the requeue both
    // syncs make stays the durable trigger under this one.
    //
    // The count is read before the first `await` on purpose: `onDrained` fires
    // synchronously at the end of the drain, so a pump landing while this hook
    // is suspended would zero it out from under the test below.
    beforeWaking: (worker) async {
      final didWork = worker.lastDrainCount > 0;
      if (didWork) {
        await ref.read(messageStoreProvider).requeueSweep();
      }
    },
  );
  return worker;
});

/// The STORYLINE lane's worker: the six passes, in the order their arguments
/// require, behind a gate of their own.
///
/// All six in ONE worker, and that is the decision rather than an accident of
/// where they were. They were mixed-slot when there were two generating
/// servers (confirms on the 4B, naming and recaps on the 27B); every pass is
/// on the one generative model now, and the server was never the thing that
/// groups them anyway. What groups them is that they mutate shared
/// membership, and the ordering arguments below only hold while they run
/// one after another in this list: refresh before recruit, audit between
/// them, recap after the sweep.
///
/// Off the fast lane entirely, which is the point: a twelve-to-twenty-three
/// second recap used to sit in front of the next message's triage. Woken by
/// the extract handler as each assign is queued (`onStorylineQueued`) as
/// well as by the fast lane's end, so an assign runs while the rest of the
/// extraction backlog is still walking.
final Provider<AiWorker> storylineWorkerProvider = Provider<AiWorker>((ref) {
  final storylines = ref.watch(storylineServiceProvider);
  return _lane(
    ref,
    handlers: [
      // Assignment before the sweep: a thread that joins an existing storyline
      // is one fewer unassigned thread for the sweep to propose a new group
      // around.
      StorylineAssignHandler(
        storylines,
        activityLog: ref.watch(activityLogProvider),
        progress: ref.watch(pipelineProgressProvider),
      ),
      StorylineSweepHandler(storylines),
      // Between the sweep and the recruit, and the position is the point. A
      // refresh may widen a charter, and a widened charter is what the recruit
      // below goes hunting with — so a user's edit refreshes and recruits in
      // ONE drain. The reverse pairing is damped by the same ordering: a
      // recruit that files threads queues a refresh for the next pump rather
      // than this one, which is what keeps the two from chasing each other.
      StorylineRefreshHandler(storylines),
      // Between the refresh and the recruit, and both halves are the point.
      // After the refresh, so a removal's audit judges against the charter the
      // refresh has just narrowed rather than the one that admitted the thread
      // the user threw out. Before the recruit, so the blocks the audit writes
      // already exist when the recruit excludes blocked threads — an audit
      // removal the recruit could not see would be filed straight back in this
      // same drain.
      StorylineAuditHandler(storylines),
      // After the sweep: a recruit is rare — it only exists when a charter
      // was just saved, or a refresh moved one — and the threads it files are
      // exactly what a draft written after this lane should know about.
      StorylineRecruitHandler(storylines),
      // After the recruit, so a thread the recruit just filed is in the recap
      // written on this same drain rather than a pump later — the recap is the
      // storyline screen's centrepiece, and a member the user can see in the
      // timeline while the recap still talks about the group without it is the
      // one inconsistency they would notice. Last in this lane, and this
      // lane's completion is what wakes the draft lane.
      StorylineRecapHandler(storylines),
    ],
    gate: storylineDrainGateProvider,
    // A storyline born in a sweep is background a draft written after it
    // should be able to read, so this lane wakes the draft lane when it is
    // done. No cycle: the draft lane wakes nothing.
    wakes: [draftWorkerProvider],
  );
});

/// Today's cloud-draft count against the cap, for the three places a draft
/// can leave this machine.
///
/// The cap is `read` inside the closure and never watched, on the rule the
/// rest of this file's routing follows: moving the number has to move the
/// next draft rather than rebuild the worker writing this one.
final cloudDraftLedgerProvider = Provider<CloudDraftLedger>(
  (ref) => CloudDraftLedger(
    ref.watch(messageStoreProvider),
    cap: () => ref.read(appPrefsProvider).cloudDraftsDailyCap,
  ),
);

/// The one handler on the DRAFT lane, hoisted so the composer can reach it.
///
/// Its own provider because [DraftHandler.improve] is not queue work: the
/// Improve button calls it straight, while the lane below drains the same
/// object. One instance for both, so the routing closures and the ledger can
/// only ever say one thing.
///
/// It watches the store, its two stage clients, the recorder, the two
/// retrievers, the embedder, progress, the bus and the ledger — and NEVER
/// `appPrefsProvider`. That omission is the whole of why pointing a stage
/// somewhere else rebuilds no worker and aborts no drain.
final draftHandlerProvider = Provider<DraftHandler>((ref) {
  // The only handler on its lane, and the only one of the fourteen a person
  // sits and waits for. A draft is prose they send under their own name — the
  // one place the bigger model earns its seconds.
  //
  // It still reads the storyline summary as background, which used to be
  // guaranteed by drafting LAST in one list. It no longer is: a draft
  // prefetched seconds after its extraction may be written before the sweep
  // that would have named its storyline. That is the trade the split makes on
  // purpose — a background sentence against minutes of waiting — and the
  // storyline lane's `onDrained` pumps this one, so the next draft after a
  // sweep has it.
  return DraftHandler(
    ref.watch(messageStoreProvider),
    ref.watch(stageLlmClientProvider('draft_reply')),
    activityLog: ref.watch(activityLogProvider),
    attachments: ref.watch(attachmentRetrieverProvider),
    contextDirs: ref.watch(contextRetrieverProvider),
    // The same client both retrievers above hold, handed to the handler
    // so the message being answered is embedded once for the two of them.
    embeddings: ref.watch(embeddingsClientProvider),
    progress: ref.watch(pipelineProgressProvider),
    // The DRAFT TARGET's width, read at every launch decision — see
    // `DraftHandler.concurrency`. Through the resolved spec rather than
    // off `proseParallel` directly, so a draft pointed at a GPU box reads
    // that box's slots; the local prose target's width IS `proseParallel`,
    // so a machine that has added nothing reads exactly what it read
    // before. `read` inside the closure, never `watch`: a width change
    // must move the next draft, not rebuild the worker holding the drain
    // that is writing this one.
    concurrency: () =>
        ref.read(appPrefsProvider).specForStage('draft_reply')?.parallel ??
        1,
    // Whether the draft target can stream, on the same rule. A target on
    // the Converse wire has nothing to stream, and one that answers a
    // streamed request badly is a setting away from the plain call.
    streams: () =>
        ref.read(appPrefsProvider).specForStage('draft_reply')?.streams ??
        true,
    // The live bus, so the draft streams. Every other build of this
    // handler takes the disabled default and makes the plain call.
    stream: ref.watch(draftStreamBusProvider),
    // Where an Improve goes. An optional stage, so this client is built on a
    // target that may not exist; `routes.improveTarget` is what says whether
    // the button is offered at all.
    improveClient: ref.watch(stageLlmClientProvider('draft_improve')),
    // Every routing question the handler asks, as closures over the prefs —
    // `read`, never `watch`, for [concurrency]'s reason.
    routes: DraftRoutes(
      draftTarget: () =>
          ref.read(appPrefsProvider).specForStage('draft_reply'),
      improveTarget: () =>
          ref.read(appPrefsProvider).specForStage('draft_improve'),
      standing: () => ref.read(appPrefsProvider).cloudDraftsStanding,
      ledger: ref.watch(cloudDraftLedgerProvider),
    ),
  );
});

/// The DRAFT lane's worker: one handler, on the 27B, at the width the prose
/// server was started with.
///
/// Alone on its gate because of what a draft IS — the one piece of work in
/// this app a person sits and waits for. Behind the old single drain it waited
/// for everything: a sweep of confirms, twenty recaps, the whole pass coming
/// round. Here the worst case is one prose call already at the server.
final Provider<AiWorker> draftWorkerProvider = Provider<AiWorker>((ref) {
  return _lane(
    ref,
    handlers: [ref.watch(draftHandlerProvider)],
    gate: draftDrainGateProvider,
  );
});

/// Who the owner is, from the account the sync signed in with.
///
/// A callback, not a value: the account is a keychain read, and both callers
/// are built by plenty that never drains. Each caller asks once, on the first
/// item that reaches a model. Until the answer arrives the needs-you decision
/// names no owner and the storyline overlap rule counts everyone as not the
/// owner, which is the stricter reading of both.
OwnerLookup _ownerLookup(Ref ref) => () =>
    ref.read(authSessionProvider).storedAccount.then(
          (account) => account == null
              ? null
              : (
                  name: account.displayName,
                  address: account.mail ?? account.userPrincipalName,
                ),
        );

/// Reads the processing switch, for a drain that asks on every launch
/// decision.
///
/// `ref.read` inside the closure and never `watch`, on
/// [contextRetrieverProvider]'s `selectExpand` rule and for its reason: a
/// watch would rebuild every queue in this file — and dispose the one
/// mid-drain — the instant somebody moved the switch, which is the opposite of
/// "finish the item in flight".
///
/// A torn-down container reads as OFF rather than throwing. The closure is
/// called from inside a drain that outlives its container by however long the
/// item at the server takes, and the safe answer there is to start nothing
/// new: [AiWorker.dispose] is already handing back the claims.
bool Function() _enabledReader(Ref ref) => () {
      try {
        return ref.read(processingProvider);
      } catch (_) {
        return false;
      }
    };

/// One lane's worker, built the way all three are: the store, the lane's
/// handlers and gate, the shared activity log and progress, and — for a lane
/// that feeds others — the lanes to wake when its drain ends.
///
/// The wake is unawaited and guarded on the triage queue's own `onDrained`
/// reasoning: the drains it starts are minutes of model time and this one
/// must not wait for them, and the `read` itself throws against a torn-down
/// container. Why each lane wakes what it wakes is said at the lane.
///
/// [beforeWaking] is a lane's chance to write a row the lane it is about to
/// wake should find waiting. It is AWAITED, and the wakes are not: what it
/// writes has to be pending before the woken drain claims, while the drains
/// that wake starts are minutes of model time nothing here may wait for.
///
/// The worker is a `late final` local because the callback is about the
/// worker that is being built. `onDrained` is a final constructor argument so
/// it cannot be attached afterwards, and `ref.read(aiWorkerProvider)` inside
/// that provider's own build is a circular dependency. The closure captures
/// the late local instead, which is assigned long before any drain can end.
AiWorker _lane(
  Ref ref, {
  required List<WorkHandler> handlers,
  required Provider<DrainGate> gate,
  List<Provider<AiWorker>> wakes = const [],
  Future<void> Function(AiWorker worker)? beforeWaking,
}) {
  late final AiWorker worker;
  worker = AiWorker(
    ref.watch(messageStoreProvider),
    handlers: handlers,
    gate: ref.watch(gate),
    activityLog: ref.watch(activityLogProvider),
    progress: ref.watch(pipelineProgressProvider),
    // The processing switch, on all three lanes — see [_enabledReader].
    enabled: _enabledReader(ref),
    onDrained: wakes.isEmpty && beforeWaking == null
        ? null
        : () {
            unawaited(() async {
              if (beforeWaking != null) {
                try {
                  await beforeWaking(worker);
                } catch (_) {}
              }
              try {
                for (final lane in wakes) {
                  unawaited(ref.read(lane).pump());
                }
              } catch (_) {}
            }());
          },
  );
  ref.onDispose(worker.dispose);
  return worker;
}

/// The three lanes as one value — what a caller outside the pipeline pumps and
/// listens to. See [AiWorkers] for the chain and the merge.
final Provider<AiWorkers> aiWorkersProvider = Provider<AiWorkers>((ref) {
  final workers = AiWorkers(
    fast: ref.watch(aiWorkerProvider),
    storyline: ref.watch(storylineWorkerProvider),
    draft: ref.watch(draftWorkerProvider),
  );
  ref.onDispose(workers.dispose);
  return workers;
});

/// Whether the pipeline is parked, and how much is waiting on it.
///
/// Built from the two drains' own progress streams rather than from a health
/// poll. Both of them already know they parked and why; today that fact dies
/// inside them, and one sentence in the rail is all it takes to turn it into
/// something a person can act on. Nothing here dials anything.
class ParkedFact {
  /// `'model_unavailable'`, `'unauthorized'`, `'session'`, or null when
  /// nothing is parked.
  final String? reason;

  /// Items the two drains still owe, parked or not.
  final int waiting;

  const ParkedFact({this.reason, this.waiting = 0});

  @override
  bool operator ==(Object other) =>
      other is ParkedFact && other.reason == reason && other.waiting == waiting;

  @override
  int get hashCode => Object.hash(reason, waiting);
}

/// The drains' parked state, merged.
///
/// Triage's reason wins when more than one drain has one: it is at the front
/// of the pipeline, and a second sentence about the same server being down is
/// not more information. The count is the sum, because "3 waiting" is about
/// the backlog rather than about which queue holds it.
///
/// **One entry per work KIND, not one `WorkProgress` for the lot.**
/// [AiWorkers] forwards three lanes onto one stream and `_drainAll` emits per
/// handler even when that handler had no rows, so a single slot would let the
/// storyline lane's empty emit overwrite the fast lane's park with null a
/// microsecond after it happened, and replace the whole backlog's count with
/// one kind's. Each kind therefore keeps its own last value, the reason is the
/// first non-null across them in a stable order, and the count is their sum.
///
/// `autoDispose`, because the only listener is the rail and nothing needs this
/// running behind a closed inbox.
final parkedProvider = StreamProvider.autoDispose<ParkedFact>((ref) {
  final controller = StreamController<ParkedFact>();
  TriageProgress? triage;
  // Insertion-ordered by construction, which is the stable order the reason is
  // read in: whichever kind parked first keeps the sentence until it clears.
  final work = <String, WorkProgress>{};

  void emit() {
    if (controller.isClosed) return;
    String? reason = triage?.parkedReason;
    var waiting = triage?.remaining ?? 0;
    for (final progress in work.values) {
      reason ??= progress.parkedReason;
      waiting += progress.remaining;
    }
    controller.add(ParkedFact(reason: reason, waiting: waiting));
  }

  // Errors are swallowed on both: this stream exists to say whether work is
  // stuck, and a failing progress stream must not take the rail down with it.
  final a = ref.watch(triageQueueProvider).progress.listen((event) {
    triage = event;
    emit();
  }, onError: (Object _) {});
  final b = ref.watch(aiWorkersProvider).progress.listen((event) {
    work[event.kind] = event;
    emit();
  }, onError: (Object _) {});

  ref.onDispose(() {
    unawaited(a.cancel());
    unawaited(b.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
});

/// The storyline logic, shared by the two work handlers and by the UI's user
/// actions. Stateless beyond its store and clients, so a second instance would
/// be harmless — it is a provider because the handlers and the notifier must
/// agree on the same store.
///
/// The language-model passes carry their own client, each on its own stage,
/// so the activity log labels each call by its stage. Every stage resolves to
/// the one generative model since the decision-model round
/// ([stageLlmClientProvider]). Membership is not one of them: every
/// "does this thread belong here" is the decision model's `member_of`,
/// through the [StorylineJudge] on the decision client.
///
/// The same embedding client the extraction handler holds, deliberately: a
/// thread whose embed failed there is one this service re-embeds itself when
/// the assignment pass reaches it, and two clients would mean two dedupe sets
/// and two rows in the activity panel for one server being down.
///
/// Typed out: the judge's body fetch reads [syncServiceProvider] at call
/// time, and the sync reaches this provider through the gate repair, so the
/// three declarations form an inference cycle (never a build-time one).
final Provider<StorylineService> storylineServiceProvider =
    Provider<StorylineService>(
  (ref) => StorylineService(
    ref.watch(messageStoreProvider),
    ref.watch(stageLlmClientProvider('storyline_name')),
    judge: StorylineJudge(
      decision: ref.watch(decisionClientProvider),
      store: ref.watch(messageStoreProvider),
      // A mail thread's rendered rows that still show Graph's preview have
      // their bodies fetched before it is judged, because training read every
      // message's own body — those rows only, and no attachment work queued
      // (`ensureBodiesFor`). Teams has no body fetch to ask for, so a chat is
      // judged on what is stored. `ref.read` at the call, never `watch`: the
      // sync provider rebuilding must not rebuild this one mid-drain.
      ensureBodies: (source, conversationKey, ids) async {
        if (source != 'email') return;
        await ref
            .read(syncServiceProvider)
            .ensureBodiesFor(conversationKey, ids);
      },
    ),
    refreshClient: ref.watch(stageLlmClientProvider('storyline_refresh')),
    recapClient: ref.watch(stageLlmClientProvider('storyline_recap')),
    activityLog: ref.watch(activityLogProvider),
    embeddings: ref.watch(embeddingsClientProvider),
    // Only the user actions write through it — see [StorylineService]. The
    // recorder watches the store and the bus, both of which outlive a backend
    // switch, so taking it here costs this provider nothing it did not
    // already depend on.
    progress: ref.watch(pipelineProgressProvider),
    // The library, for the recap's directory footer and the charter offer.
    contextStore: ref.watch(contextStoreProvider),
  ),
);

/// This build's version and build number, for the About section.
///
/// A `FutureProvider` because the answer comes off a platform channel — the
/// bundle's own `Info.plist` on macOS — and a widget cannot await. The record
/// shape keeps the two halves together: the section renders them as
/// `1.0.0 (1)`, and a version with no build behind it is not a thing this app
/// wants to have to reason about.
///
/// In a widget test there is no platform on the other end of that channel and
/// the call throws `MissingPluginException`, which the provider turns into an
/// `AsyncError`. The host reads it with `valueOrNull`, so a test sees null and
/// the About section quietly says 'Version unknown' — nothing is faked and
/// nothing throws. A test that wants a version overrides this provider.
final appInfoProvider = FutureProvider<({String version, String build})>(
  (ref) async {
    final info = await PackageInfo.fromPlatform();
    return (version: info.version, build: info.buildNumber);
  },
);

/// Where the database file is, for the About section.
///
/// Same shape and the same reason as [appInfoProvider]: locating the platform's
/// application-support directory is asynchronous, so the path cannot be read
/// inside a build. It opens nothing — see [appDatabasePath] — so watching it
/// from a settings pane costs one directory lookup, not a second connection.
///
/// `path_provider` is a plugin too, so this also answers null in a widget test
/// unless the test overrides it.
final databasePathProvider = FutureProvider<String>(
  (ref) => appDatabasePath(),
);

/// Sparkle, for the About section's update controls.
///
/// A plain `Provider` over the channel implementation, so a test can hand the
/// host a `NullUpdater` (or a fake) without touching the binary messenger.
final updaterProvider = Provider<Updater>((_) => const ChannelUpdater());

/// What the updater says about itself right now.
///
/// [appInfoProvider]'s shape and, once more, its reason: the answer comes off
/// a platform channel and a widget cannot await. In a widget test that call
/// never comes back at all (nobody is on the other end, and the fake-async
/// zone holds the reply), so the status stays loading and the host passes the
/// About section no update props — the section renders without them rather
/// than throwing or faking a version of Sparkle that is not there. A test that
/// wants a verdict overrides [updaterProvider] with a fake or a `NullUpdater`.
///
/// `autoDispose`, and invalidated after a toggle, for one reason: Sparkle owns
/// the automatic-checks preference AND the last-check time, and both move
/// behind this app's back — a check the user starts from the button ends in
/// Sparkle's window, and Sparkle records the time when that session ends. The
/// settings host is the only watcher, so the value is dropped the moment
/// Settings closes and read afresh on the next open, which is when 'Last
/// checked' has to be true again. The toggle invalidates it in place so the
/// switch shows Sparkle's answer rather than a local copy of what it was asked
/// for.
final updaterStatusProvider = FutureProvider.autoDispose<UpdaterStatus>(
  (ref) => ref.watch(updaterProvider).status(),
);

/// How many explicit Ignores of one sender it takes before the app offers to
/// drop them altogether.
///
/// Offered, never automatic. Three is the point at which a person has said the
/// same thing three times, which is enough to ask a question and nowhere near
/// enough to answer it for them: a sender rule gates everything that address
/// ever sends, and nothing but the owner gets to write one.
const int senderDropOfferAfter = 3;

/// Whether the "Drop every message from this sender" offer belongs on this
/// address's story right now.
///
/// A provider because the answer is two store reads and a widget build cannot
/// await one — the same reason [storylineMembersProvider] is one. False while
/// the read is in flight, which is the right way round: a button that appears
/// a frame late is better than one that flickers away.
///
/// False once the rule exists, so the offer disappears the moment it is taken
/// rather than inviting the owner to write a rule they already wrote. The
/// caller invalidates it after an Ignore and after a drop — see
/// `MessageHistoryHost`.
final senderDropOfferProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, address) async {
  final store = ref.watch(messageStoreProvider);
  // No offer where a rule already stands: `drop` because it is taken, `keep`
  // because offering to gate a sender the owner explicitly kept would be the
  // app arguing with a standing instruction. A `later` sender is still asked
  // — deferring and dropping are different sizes of the same answer.
  final rule = await store.getSenderPref(address);
  if (rule == 'drop' || rule == 'keep') return false;
  final ignores = await store.explicitIgnoreCountForSender(address);
  return ignores >= senderDropOfferAfter;
});
