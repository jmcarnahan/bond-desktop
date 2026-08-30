import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import '../data/message_store.dart';
import '../services/ai_worker.dart';
import '../services/extract_handler.dart';
import '../services/graph_auth.dart';
import '../services/graph_mail.dart';
import '../services/llm/embeddings_client.dart';
import '../services/llm/llm_client.dart';
import '../services/sync_service.dart';
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

/// Typed as [MailSync], not [SyncService], so a test can override it with a
/// stand-in that never touches the network.
final syncServiceProvider = Provider<MailSync>(
  (ref) => SyncService(
    ref.watch(graphMailProvider),
    ref.watch(messageStoreProvider),
  ),
);

/// The local model. Constructing it opens nothing — the first call is what
/// discovers whether a server is listening.
final llmClientProvider = Provider<LlmClient>((ref) => LlmClient());

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
  final worker = AiWorker(
    ref.watch(messageStoreProvider),
    handlers: [
      ExtractHandler(
        ref.watch(messageStoreProvider),
        ref.watch(llmClientProvider),
        ref.watch(embeddingsClientProvider),
      ),
    ],
  );
  ref.onDispose(worker.dispose);
  return worker;
});
