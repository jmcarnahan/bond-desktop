import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../services/attention.dart';
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
import '../services/mcp/bond_mcp_client.dart';
import '../services/mcp/mcp_attachment_backend.dart';
import '../services/mcp/mcp_auth.dart';
import '../services/mcp/mcp_mail_backend.dart';
import '../services/mcp/mcp_people_backend.dart';
import '../services/mcp/mcp_teams_backend.dart';
import '../services/message_search.dart';
import '../services/models/model_downloader.dart';
import '../services/models/model_manifest.dart';
import '../services/server/llama_binary.dart';
import '../services/server/model_server_supervisor.dart';
import '../services/server/process_runner.dart';
import '../services/server/server_state.dart';
import '../services/system/system_info.dart';
import '../services/system/updater.dart';
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
import '../services/storyline_handler.dart';
import '../services/storyline_service.dart';
import '../services/sync_service.dart';
import '../services/teams_sync.dart';
import '../services/triage_queue.dart';
import '../widgets/app_rail.dart' show RailSection;
import 'navigation_provider.dart';
import 'notify_routing.dart';
import 'prefs_provider.dart';

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

/// The three providers the app consumes, and the one switch between the two
/// backends.
///
/// They WATCH the mode rather than reading it once, so `setBackendMode` and
/// `setMcpServerUrl` rebuild this whole graph on their own — the sync service,
/// the Teams connector, the draft notifier and the screens all watch down to
/// here, and every one of them follows. That is the entire mechanism; nothing
/// invalidates anything by hand.
final authSessionProvider = Provider<AuthSession>((ref) {
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
/// a closure with `ref.read`, on the rule [llmClientProvider] states: a
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
    buildPreset: () => ref
        .read(modelManifestProvider)
        .toPreset(ref.read(appPrefsProvider).effectiveModelsFolder(paths)),
    routerPort: () => ref.read(appPrefsProvider).routerPort,
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
        unawaited(
          pumpTriageThenWorkers(
            triage: () => ref.read(triageQueueProvider).pump(),
            workers: () => ref.read(aiWorkersProvider).pumpAll(),
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

/// The user's attention floor, read fresh on every call.
///
/// A shared closure rather than three copies of the same four lines, because
/// three things now judge against this number and they have to judge against
/// the SAME one: the settle machine deciding whether to interrupt, the
/// needs-you handler moving a chip after a re-verdict, and the sync's one-shot
/// backfill raising chips over history. A slider read differently by any of
/// them is a tile disagreeing with the toast it came from.
Future<double> Function() attentionThresholdReader(MessageStore store) =>
    () async {
      final raw = await store.getPref(attentionThresholdKey);
      return (raw == null ? null : double.tryParse(raw)) ??
          AttentionTuning.defaultThreshold;
    };

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
    attentionThreshold: attentionThresholdReader(store),
  );
  unawaited(coordinator.start());
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

final mailBackendProvider = Provider<MailBackend>((ref) {
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

/// What the UI asks for a file: cache first, connector second, row updated.
final attachmentBytesProvider = Provider<AttachmentBytes>(
  (ref) => StoreAttachmentBytes(
    store: ref.watch(messageStoreProvider),
    backend: ref.watch(attachmentBackendProvider),
    cache: ref.watch(attachmentCacheProvider),
    pdfThumbnailer: ref.watch(pdfThumbnailerProvider),
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
/// stand-in that never touches the network.
final syncServiceProvider = Provider<MailSync>(
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
    // same floor the settle machine judges live mail against.
    attentionThreshold: attentionThresholdReader(ref.watch(messageStoreProvider)),
    // `ref.read` inside the closure, never `watch`: watching would rebuild
    // this provider — and abort the drain running on it — the moment someone
    // moved the setting, the same hazard [llmClientProvider] documents below.
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
  ),
);

final teamsBackendProvider = Provider<TeamsBackend>((ref) {
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

/// The local model. Constructing it opens nothing — the first call is what
/// discovers whether a server is listening.
///
/// Every round trip it makes is reported to the activity log, which holds the
/// tally until the queue that made the calls records the item they were for —
/// so the panel shows "three model calls, nine seconds" on one extraction row
/// rather than three rows nobody can attribute.
///
/// It still watches ONLY the activity log. The user's choice of model reaches
/// it through [LlmClient]'s resolver, which is read at call time: a model
/// change must not rebuild this provider, because everything downstream —
/// [aiWorkerProvider], [storylineServiceProvider], [triageQueueProvider] —
/// watches it, and rebuilding those mid-drain would abort work in flight to
/// change which server the NEXT request goes to.
///
/// `ref.read` inside the closure, not `watch`, on the precedent
/// [embeddingsClientProvider] set: the callback outlives this body, and the
/// client guards the read itself.
final llmClientProvider = Provider<LlmClient>(
  (ref) => LlmClient(
    resolveTarget: () => ref.read(appPrefsProvider).proseTarget,
    onCall: ref.watch(activityLogProvider).noteLlmCall,
    // Sized to the longest draft this app can legitimately ask for; see
    // [LlmClient.proseTimeout] for the arithmetic.
    timeout: LlmClient.proseTimeout,
  ),
);

/// The second chat model, on its own server (`make fast`), and the reason
/// there are two.
///
/// The 27B answers a triage call in about thirteen seconds; the small model
/// answers the same call in about two. Everything routed here is a LABEL under
/// a tight schema that Dart re-validates afterwards — triage, extraction,
/// storyline membership — and none of it needs 27B judgement to come out
/// right. What stays on [llmClientProvider] is the prose: drafted replies and
/// storyline titles, where the difference between the two models is something
/// a person reads.
///
/// Down is down, per server: a call to a server that is not running throws
/// [LlmUnavailableException] and the drain parks, exactly as it always has.
/// There is deliberately no fallback to the other server — silently answering
/// bulk work on the 27B would turn "the fast server is off" into "the app got
/// mysteriously slow".
///
/// Observed by the same activity log as the 27B: since the split THIS is the
/// client that makes most of the app's model calls, and a log that only saw
/// the 27B would show a mailbox that apparently triaged itself for free.
final fastLlmClientProvider = Provider<LlmClient>(
  (ref) => LlmClient(
    // Still the constructed fallback, and it still matters: it is what the
    // client answers with if the resolver ever throws, and what
    // `llm_routing_test.dart` pins the compiled default against.
    baseUrl: LlmClient.fastBaseUrl,
    // Its own name as well as its own URL: a runtime that serves more than one
    // model routes on this field, so the bulk server's client must say which
    // of them it is asking for rather than inherit the big server's answer.
    model: LlmClient.fastModel,
    // Read at call time, exactly as [llmClientProvider] explains: the stored
    // slot moves the next request without rebuilding this client.
    resolveTarget: () => ref.read(appPrefsProvider).fastTarget,
    onCall: ref.watch(activityLogProvider).noteLlmCall,
  ),
);

/// The FAST lane's gate: the triage drain and the fast worker, and nothing
/// else.
///
/// It keeps those two drains from running at once, because both send their
/// bulk work to the fast server: overlapping them would double-book its slots
/// and have each drain's byte-identical system prompt evict the other's from
/// the KV prefix cache. It deliberately does NOT serialize the handful of
/// requests one drain has in flight — those are batched by the server on
/// purpose, and are what the slot count is sized for.
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
    // Bulk work: the fast server. See [fastLlmClientProvider].
    ref.watch(fastLlmClientProvider),
    // Triage fetches its own bodies rather than waiting for a human to open
    // the thread. Taken off [MailSync], so this stays typed to the interface
    // a test can override.
    ensureBody: ref.watch(syncServiceProvider).ensureMessageBody,
    // The FAST lane's gate: this drain and the fast worker share the fast
    // server, and nothing else is on it.
    gate: ref.watch(fastDrainGateProvider),
    activityLog: ref.watch(activityLogProvider),
    progress: ref.watch(pipelineProgressProvider),
    // The knock on the worker's door. Extraction and needs-you are no longer
    // handed a message triage has not spoken about, so a worker drain that
    // won the gate first leaves them pending and would sit on them until the
    // next sync — this is what makes it walk again the moment the gates have
    // answered. Reaching forward to [aiWorkerProvider], declared further down
    // this file, is ordinary Riverpod: a provider resolves where it is READ,
    // which is inside this callback, long after both exist. Unawaited because
    // a worker drain is minutes of model time and the triage pump that fires
    // it must not wait for it; the guard is for the read itself, which throws
    // against a torn-down container.
    onDrained: () async {
      try {
        unawaited(ref.read(aiWorkerProvider).pump());
      } catch (_) {}
    },
    // A gate landing on a message whose thread has nothing kept left in it
    // leaves an embedding, storyline memberships and a queued filing behind.
    // `read` inside the closure, on the same precedent as the pumps above:
    // this is called long after the body returns.
    onGated: (source, id) => ref
        .read(gateRepairServiceProvider)
        .afterGate(source, id, reason: 'extracted_then_gated'),
  );
  ref.onDispose(queue.dispose);
  return queue;
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
        ? 'is not running — see Settings › Models › Local server'
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
    // Bulk work on the fast server: one small structured call per
    // directory-fed draft, which is the slot every other per-item call in
    // this app already lands on — [fastLlmClientProvider].
    fastClient: ref.watch(fastLlmClientProvider),
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
    threshold: attentionThresholdReader(ref.watch(messageStoreProvider)),
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
/// Its own load on the fast server is one kind at a time at K=3 — needs-you,
/// then extraction — and the gate it shares with the triage drain is what
/// keeps that K=3 off the back of triage's. The fourth slot is the STORYLINE
/// lane's: that lane is on a gate of its own and its membership confirms are
/// fast-server calls, so the worst case at that server is three plus one,
/// which is `FAST_SLOTS`.
final Provider<AiWorker> aiWorkerProvider = Provider<AiWorker>((ref) {
  return _lane(
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
        // Bulk work: the fast server. See [fastLlmClientProvider].
        ref.watch(fastLlmClientProvider),
        activityLog: ref.watch(activityLogProvider),
        // A verdict this pass CHANGES has to move the chip beside it, and
        // moving it means re-asking `notifyWorthy` — which needs the recorder
        // to write through and the same floor the settle machine used.
        progress: ref.watch(pipelineProgressProvider),
        attentionThreshold:
            attentionThresholdReader(ref.watch(messageStoreProvider)),
        owner: _ownerLookup(ref),
      ),
      // Extraction next, and it drains completely before either storyline
      // handler starts. That order is the point: extraction is what writes the
      // embeddings both storyline passes compare, so running them alongside it
      // would have them clustering a mailbox half of which has no vector yet.
      ExtractHandler(
        ref.watch(messageStoreProvider),
        // Bulk work: the fast server. See [fastLlmClientProvider].
        ref.watch(fastLlmClientProvider),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
        progress: ref.watch(pipelineProgressProvider),
        // The draft lane, woken as the row is written rather than at the end
        // of this drain — `AttachmentDigestHandler.onRequeue`'s shape, and the
        // same `read`-inside-a-closure reasoning: a `watch` here would be a
        // cycle through the provider being built, and a `read` from inside a
        // drain is a read of a worker that already exists. On a sixty-message
        // backlog this is the difference between a prefetch starting seconds
        // after its extraction and minutes after it.
        onDraftQueued: () => unawaited(ref.read(draftWorkerProvider).pump()),
        // When a reply is written ahead of being asked for — the user's
        // setting, read at the moment each message finishes rather than
        // captured here. `ref.read` inside the closure, never `watch`, in
        // [contextRetrieverProvider]'s `selectExpand` shape and for its
        // reason: a watch would rebuild this provider, and the worker holding
        // it mid-drain, the moment somebody moved the control.
        draftPolicy: () => ref.read(appPrefsProvider).draftPolicy,
      ),
      // After extraction and before the storylines. After, because the summary
      // it embeds is triage's and the drain order keeps the fast server's slots
      // for extraction while there is extraction left to do. Before, because it
      // talks to no model at all: a park here is a park on the embedding
      // server, and it parks only its own kind, so a missing `make embed` must
      // never be allowed to sit in front of the storyline queue.
      EmbedHandler(
        ref.watch(messageStoreProvider),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
      ),
      // Reading the documents, then understanding them — in that order,
      // because the digest below has nothing to read until the words are
      // stored. Both sit here, after the message embeddings and ahead of the
      // storylines, so a recap written later in this same drain can see a
      // digest that landed at the top of it. Neither is in the notification
      // settle set: an attachment must never hold up a verdict about the
      // message it came with.
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
        // Bulk work: the fast server. See [fastLlmClientProvider].
        ref.watch(fastLlmClientProvider),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
        // The worker this handler runs inside, read at CALL time — the same
        // shape as needs-you's owner lookup. A `watch` here would be a cycle
        // through the provider being built; a `read` from inside a drain is a
        // read of a worker that already exists. `pump` on a running drain only
        // sets a flag and hands back that drain's future, which is why it is
        // not awaited: see [AttachmentDigestHandler].
        onRequeue: () => unawaited(ref.read(aiWorkerProvider).pump()),
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
        // Bulk work: the fast server. See [fastLlmClientProvider].
        ref.watch(fastLlmClientProvider),
        ref.watch(embeddingsClientProvider),
        activityLog: ref.watch(activityLogProvider),
      ),
      ContextBriefHandler(
        ref.watch(contextStoreProvider),
        ref.watch(fastLlmClientProvider),
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
    // IS that signal: extraction, embedding and the needs-you judgement all
    // drain here. Gated on the count because `onDrained` fires after an empty
    // drain too — a Restore or a Regenerate enqueues a row directly, and an
    // ungated requeue would run a whole sweep after every idle pump.
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
});

/// The STORYLINE lane's worker: the six passes, in the order their arguments
/// require, behind a gate of their own.
///
/// All six in ONE worker, and that is the decision rather than an accident of
/// where they were. They are mixed-slot — assignment, the audit, the recruit
/// and the sweep's confirms are fast-server calls; the sweep's naming, the
/// refresh and the recap are the 27B's — so neither server is the thing that
/// groups them. What groups them is that they mutate shared membership, and
/// the ordering arguments below only hold while they run one after another in
/// this list: refresh before recruit, audit between them, recap after the
/// sweep.
///
/// Off the fast lane entirely, which is the point: a twelve-to-twenty-three
/// second recap used to sit in front of the next message's triage.
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
    handlers: [
      // The only handler on this lane, and the only one of the fourteen a
      // person sits and waits for. A draft is prose they send under their own
      // name — the one place the bigger model earns its seconds.
      //
      // It still reads the storyline summary as background, which used to be
      // guaranteed by drafting LAST in one list. It no longer is: a draft
      // prefetched seconds after its extraction may be written before the
      // sweep that would have named its storyline. That is the trade the
      // split makes on purpose — a background sentence against minutes of
      // waiting — and the storyline lane's `onDrained` pumps this one, so the
      // next draft after a sweep has it.
      DraftHandler(
        ref.watch(messageStoreProvider),
        ref.watch(llmClientProvider),
        activityLog: ref.watch(activityLogProvider),
        attachments: ref.watch(attachmentRetrieverProvider),
        contextDirs: ref.watch(contextRetrieverProvider),
        // The same client both retrievers above hold, handed to the handler
        // so the message being answered is embedded once for the two of them.
        embeddings: ref.watch(embeddingsClientProvider),
        progress: ref.watch(pipelineProgressProvider),
        // The prose server's width, read at every launch decision — see
        // `DraftHandler.concurrency`. `read` inside the closure, never
        // `watch`: a width change must move the next draft, not rebuild the
        // worker holding the drain that is writing this one.
        concurrency: () => ref.read(appPrefsProvider).proseParallel,
        // The live bus, so the draft streams. Every other build of this
        // handler takes the disabled default and makes the plain call.
        stream: ref.watch(draftStreamBusProvider),
      ),
    ],
    gate: draftDrainGateProvider,
  );
});

/// Who the owner is, from the account the sync signed in with.
///
/// A callback, not a value: the account is a keychain read, and both callers
/// are built by plenty that never drains. Each caller asks once, on the first
/// item that reaches a model. Until the answer arrives the needs-you prompt
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

/// The storyline logic, shared by the two work handlers and by the UI's user
/// actions. Stateless beyond its store and clients, so a second instance would
/// be harmless — it is a provider because the handlers and the notifier must
/// agree on the same store.
///
/// The one place the routing split runs through a single object: membership is
/// a label and goes to the fast server, naming is prose and stays on the 27B.
///
/// The same embedding client the extraction handler holds, deliberately: a
/// thread whose embed failed there is one this service re-embeds itself when
/// the assignment pass reaches it, and two clients would mean two dedupe sets
/// and two rows in the activity panel for one server being down.
final storylineServiceProvider = Provider<StorylineService>(
  (ref) => StorylineService(
    ref.watch(messageStoreProvider),
    ref.watch(llmClientProvider),
    confirmClient: ref.watch(fastLlmClientProvider),
    activityLog: ref.watch(activityLogProvider),
    embeddings: ref.watch(embeddingsClientProvider),
    // Only the user actions write through it — see [StorylineService]. The
    // recorder watches the store and the bus, both of which outlive a backend
    // switch, so taking it here costs this provider nothing it did not
    // already depend on.
    progress: ref.watch(pipelineProgressProvider),
    // The library, for the recap's directory footer and the charter offer.
    contextStore: ref.watch(contextStoreProvider),
    // The overlap rule in `assignConversation` counts shared people who are
    // not the owner; the same closure the needs-you handler takes.
    owner: _ownerLookup(ref),
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
