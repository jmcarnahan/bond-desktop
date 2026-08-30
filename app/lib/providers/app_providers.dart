import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import '../data/message_store.dart';
import '../services/ai_worker.dart';
import '../services/attention_service.dart';
import '../services/draft_handler.dart';
import '../services/drain_gate.dart';
import '../services/extract_handler.dart';
import '../services/graph_auth.dart';
import '../services/graph_mail.dart';
import '../services/graph_teams.dart';
import '../services/llm/embeddings_client.dart';
import '../services/llm/llm_client.dart';
import '../services/storyline_handler.dart';
import '../services/storyline_service.dart';
import '../services/sync_service.dart';
import '../services/teams_sync.dart';
import '../services/triage_queue.dart';

/// One [GraphAuth] for the whole app. Sharing the instance is what makes the
/// in-memory access token and the single-flight refresh guard mean anything —
/// a second instance would hold its own copy of both.
final graphAuthProvider = Provider<GraphAuth>((ref) => GraphAuth());

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

final graphMailProvider =
    Provider<GraphMail>((ref) => GraphMail(ref.watch(graphAuthProvider)));

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
    ref.watch(graphMailProvider),
    ref.watch(messageStoreProvider),
  ),
);

final graphTeamsProvider =
    Provider<GraphTeams>((ref) => GraphTeams(ref.watch(graphAuthProvider)));

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
  final auth = ref.watch(graphAuthProvider);
  return TeamsSync(
    ref.watch(graphTeamsProvider),
    ref.watch(messageStoreProvider),
    canSync: () => auth.hasScope('chat.read'),
  );
});

/// The local model. Constructing it opens nothing — the first call is what
/// discovers whether a server is listening.
final llmClientProvider = Provider<LlmClient>((ref) => LlmClient());

/// The one gate both drains hold while at the model server. One instance for
/// the app, or it would serialize nothing — see [DrainGate].
final drainGateProvider = Provider<DrainGate>((ref) => DrainGate());

/// The triage worker. Exactly one for the whole app: it is a serial queue over
/// shared rows, and a second instance would claim the same messages.
final triageQueueProvider = Provider<TriageQueue>((ref) {
  final queue = TriageQueue(
    ref.watch(messageStoreProvider),
    ref.watch(llmClientProvider),
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
        ref.watch(llmClientProvider),
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
/// actions. Stateless beyond its store and client, so a second instance would
/// be harmless — it is a provider because the handlers and the notifier must
/// agree on the same store.
final storylineServiceProvider = Provider<StorylineService>(
  (ref) => StorylineService(
    ref.watch(messageStoreProvider),
    ref.watch(llmClientProvider),
  ),
);
