import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import '../data/message_store.dart';
import '../services/ai_worker.dart';
import '../services/attention_service.dart';
import '../services/backend/auth_session.dart';
import '../services/backend/mail_backend.dart';
import '../services/backend/teams_backend.dart';
import '../services/draft_handler.dart';
import '../services/drain_gate.dart';
import '../services/extract_handler.dart';
import '../services/graph_auth.dart';
import '../services/graph_mail.dart';
import '../services/graph_teams.dart';
import '../services/llm/embeddings_client.dart';
import '../services/llm/llm_client.dart';
import '../services/mcp/bond_mcp_client.dart';
import '../services/mcp/mcp_auth.dart';
import '../services/mcp/mcp_mail_backend.dart';
import '../services/mcp/mcp_teams_backend.dart';
import '../services/storyline_handler.dart';
import '../services/storyline_service.dart';
import '../services/sync_service.dart';
import '../services/teams_sync.dart';
import '../services/triage_queue.dart';
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
final dbProvider = Provider<Database>(
  (ref) => throw UnimplementedError(
    'dbProvider must be overridden with an open database (see main()).',
  ),
);

final messageStoreProvider =
    Provider<MessageStore>((ref) => MessageStore(ref.watch(dbProvider)));

final mailBackendProvider = Provider<MailBackend>((ref) {
  final mode = ref.watch(appPrefsProvider.select((p) => p.backendMode));
  return mode == backendModeSdk
      ? GraphMail(ref.watch(graphAuthProvider))
      : McpMailBackend(ref.watch(mcpStackProvider).client);
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
  );
});

/// The local model. Constructing it opens nothing — the first call is what
/// discovers whether a server is listening.
final llmClientProvider = Provider<LlmClient>((ref) => LlmClient());

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
final fastLlmClientProvider =
    Provider<LlmClient>((ref) => LlmClient(baseUrl: LlmClient.fastBaseUrl));

/// The one gate both drains hold while at the model server. One instance for
/// the app, or it would serialize nothing — see [DrainGate].
final drainGateProvider = Provider<DrainGate>((ref) => DrainGate());

/// The triage worker. Exactly one for the whole app: it is a serial queue over
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
  );
  ref.onDispose(queue.dispose);
  return queue;
});

/// The embedding server. A second llama-server on its own port, started by
/// `make embed` — and, unlike the model above, entirely optional at runtime:
/// with nothing listening, every call returns null and the app is exactly what
/// it was before this phase.
final embeddingsClientProvider =
    Provider<EmbeddingsClient>((ref) => EmbeddingsClient());

/// The AI work queue. One for the whole app, for the same reason there is one
/// [triageQueueProvider]: it is a serial queue over shared rows.
///
/// Its handlers drain in list order, so the order here is the order the work
/// happens in.
final aiWorkerProvider = Provider<AiWorker>((ref) {
  final storylines = ref.watch(storylineServiceProvider);
  final worker = AiWorker(
    ref.watch(messageStoreProvider),
    handlers: [
      // Extraction first, and it drains completely before either storyline
      // handler starts. That order is the point: extraction is what writes the
      // embeddings both storyline passes compare, so running them alongside it
      // would have them clustering a mailbox half of which has no vector yet.
      ExtractHandler(
        ref.watch(messageStoreProvider),
        // Bulk work: the fast server. See [fastLlmClientProvider].
        ref.watch(fastLlmClientProvider),
        ref.watch(embeddingsClientProvider),
      ),
      // Assignment before the sweep: a thread that joins an existing storyline
      // is one fewer unassigned thread for the sweep to propose a new group
      // around.
      StorylineAssignHandler(storylines),
      StorylineSweepHandler(storylines),
      // Last, and after both storyline passes: a draft reads the storyline
      // summary as background, so drafting before the sweep has run would
      // write the one reply for this thread without it.
      //
      // The only handler still on the 27B. A draft is prose the user sends
      // under their own name — the one place the bigger model earns its
      // seconds.
      DraftHandler(
        ref.watch(messageStoreProvider),
        ref.watch(llmClientProvider),
      ),
    ],
    gate: ref.watch(drainGateProvider),
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
final storylineServiceProvider = Provider<StorylineService>(
  (ref) => StorylineService(
    ref.watch(messageStoreProvider),
    ref.watch(llmClientProvider),
    confirmClient: ref.watch(fastLlmClientProvider),
  ),
);
