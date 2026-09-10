import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// `show BondDatabase`: drift generates row classes (Message, Conversation,
// Storyline, …) whose names collide with the app's models.
import '../data/context_store.dart';
import '../data/database.dart' show BondDatabase;
import '../data/db.dart' show appDatabasePath;
import '../data/message_store.dart';
import '../services/activity_log.dart';
import '../services/ai_worker.dart';
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
import '../services/drain_gate.dart';
import '../services/embed_handler.dart';
import '../services/extract_handler.dart';
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
import '../services/needs_you_handler.dart';
import '../services/notification_coordinator.dart';
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
      // The LINKS and nothing else. They name conversation keys and storyline
      // ids the wipe has just deleted, so they would point a new person's
      // rooms at the previous person's directories. The directories
      // themselves stay registered: they are the user's own folders on their
      // own disk, and have nothing to do with whose mailbox was signed in.
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

/// The one gate the two DRAINS hold while at the model servers — servers
/// plural since the split above, which is why the gate is about drains rather
/// than about a server.
///
/// It keeps a triage drain and a worker drain from running at once: both send
/// their bulk work to the fast server, so overlapping them would double-book
/// its slots and have each drain's byte-identical system prompt evict the
/// other's from the KV prefix cache. It deliberately does NOT serialize the
/// handful of requests one drain has in flight — those are batched by the
/// server on purpose, and are what the slot count is sized for.
///
/// One instance for the app, or it would serialize nothing — see [DrainGate].
final drainGateProvider = Provider<DrainGate>((ref) => DrainGate());

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
    gate: ref.watch(drainGateProvider),
    activityLog: ref.watch(activityLogProvider),
    progress: ref.watch(pipelineProgressProvider),
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
    pumpWork: () => ref.read(aiWorkerProvider).pump(),
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
    pumpWork: () => ref.read(aiWorkerProvider).pump(),
    // For the settle backstop a Retry runs when a row owes no stage at all.
    threshold: attentionThresholdReader(ref.watch(messageStoreProvider)),
    activityLog: ref.watch(activityLogProvider),
  ),
);

/// The AI work queue. One for the whole app, for the same reason there is one
/// [triageQueueProvider]: it is one queue over shared rows.
///
/// Its handlers drain in list order, so the order here is the order the work
/// happens in.
final Provider<AiWorker> aiWorkerProvider = Provider<AiWorker>((ref) {
  final storylines = ref.watch(storylineServiceProvider);
  final worker = AiWorker(
    ref.watch(messageStoreProvider),
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
        // A callback, not a value: the account is a keychain read, and this
        // provider is built by plenty that never drains. The handler asks
        // once, on the first message that reaches the model; until the answer
        // arrives the prompt simply names no owner.
        owner: () => ref.read(authSessionProvider).storedAccount.then(
              (account) => account == null
                  ? null
                  : (
                      name: account.displayName,
                      address: account.mail ?? account.userPrincipalName,
                    ),
            ),
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
      ),
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
      // After the sweep and before drafts: a recruit is rare — it only exists
      // when a charter was just saved, or a refresh moved one — and the
      // threads it files are exactly what the draft below should know about.
      StorylineRecruitHandler(storylines),
      // After the recruit, so a thread the recruit just filed is in the recap
      // written on this same drain rather than a pump later — the recap is the
      // storyline screen's centrepiece, and a member the user can see in the
      // timeline while the recap still talks about the group without it is the
      // one inconsistency they would notice. Still ahead of the draft, which
      // is last on its own terms.
      StorylineRecapHandler(storylines),
      // Last, and after both storyline passes: a draft reads the storyline
      // summary as background, so drafting before the sweep has run would
      // write this message's reply without it. Last also means the work
      // extraction queued at the top of this drain is picked up on the same
      // pass rather than waiting for the next sync.
      //
      // The only handler still on the 27B. A draft is prose the user sends
      // under their own name — the one place the bigger model earns its
      // seconds.
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
      ),
    ],
    gate: ref.watch(drainGateProvider),
    activityLog: ref.watch(activityLogProvider),
    progress: ref.watch(pipelineProgressProvider),
  );
  ref.onDispose(worker.dispose);
  return worker;
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
