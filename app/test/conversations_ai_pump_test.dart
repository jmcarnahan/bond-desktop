import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// How the inbox kicks its two queues.
///
/// The one thing worth pinning here: they run one after the other, never at
/// once. Both are serial queues in front of the same single-threaded model
/// server, so overlapping them halves the speed of both and throws away
/// llama-server's prompt cache between every pair of requests.

/// A [MailSync] that never touches a socket.
class FakeSync implements MailSync {
  Object? syncError;

  @override
  Future<void> syncNow() async {
    final error = syncError;
    if (error != null) throw error;
  }

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// Records when it ran, relative to everything else in [log].
class LoggingHandler extends WorkHandler {
  @override
  final String kind;
  final List<String> log;
  final String label;

  LoggingHandler(this.kind, this.log, this.label);

  @override
  Future<void> run(Map<String, Object?> item) async {
    log.add('$label:start');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    log.add('$label:end');
  }
}

/// An [LlmClient] that logs around each call, so a triage run and an AI run
/// can be seen not to overlap.
class LoggingLlm extends LlmClient {
  final List<String> log;

  LoggingLlm(this.log) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    log.add('triage:start');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    log.add('triage:end');
    return {
      'urgency': 'normal',
      'category': 'other',
      'summary': 'A summary.',
      'needs_action': false,
      'action_items': <String>[],
    };
  }
}

void main() {
  late Database db;
  late MessageStore store;
  late FakeSync sync;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
    sync = FakeSync();
  });

  tearDown(() => db.close());

  void seedPendingMessage(String id) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-28T10:00:00Z',
      'body_text': 'body of $id',
      'source_meta_json': '{"headers":{"received":"from mail.example.com"}}',
    });
  }

  /// Both queues are started but not awaited, so a test has to let them run.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('the AI queue runs after triage, never beside it', () async {
    seedPendingMessage('m1');
    store.enqueueWork('extract', 'email', 'm1');
    final log = <String>[];
    final triage = TriageQueue(store, LoggingLlm(log));
    final worker = AiWorker(
      store,
      handlers: [LoggingHandler('extract', log, 'ai')],
    );
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);

    final notifier =
        ConversationsNotifier(store, sync, triage: triage, aiWorker: worker);
    addTearDown(notifier.dispose);

    await notifier.load();
    await settle();

    expect(log, ['triage:start', 'triage:end', 'ai:start', 'ai:end']);
  });

  test('with no triage queue wired, the AI queue still runs', () async {
    store.enqueueWork('extract', 'email', 'm1');
    final log = <String>[];
    final worker = AiWorker(
      store,
      handlers: [LoggingHandler('extract', log, 'ai')],
    );
    addTearDown(worker.dispose);

    final notifier = ConversationsNotifier(store, sync, aiWorker: worker);
    addTearDown(notifier.dispose);

    await notifier.load();
    await settle();

    expect(log, ['ai:start', 'ai:end']);
    expect(store.workCounts('extract'), {'done': 1});
  });

  test('a sync that failed kicks neither queue', () async {
    store.enqueueWork('extract', 'email', 'm1');
    final log = <String>[];
    final worker = AiWorker(
      store,
      handlers: [LoggingHandler('extract', log, 'ai')],
    );
    addTearDown(worker.dispose);
    sync.syncError = StateError('the network is out');

    final notifier = ConversationsNotifier(store, sync, aiWorker: worker);
    addTearDown(notifier.dispose);

    await notifier.load();
    await settle();

    // Nothing new arrived to work on, and the inbox still renders what it has.
    expect(log, isEmpty);
    expect(store.workCounts('extract'), {'pending': 1});
  });

  test('a load that skips the sync kicks neither queue', () async {
    store.enqueueWork('extract', 'email', 'm1');
    final log = <String>[];
    final worker = AiWorker(
      store,
      handlers: [LoggingHandler('extract', log, 'ai')],
    );
    addTearDown(worker.dispose);

    final notifier = ConversationsNotifier(store, sync, aiWorker: worker);
    addTearDown(notifier.dispose);

    // What a progress-driven reload does: re-read sqlite, start nothing.
    await notifier.load(syncFirst: false);
    await settle();

    expect(log, isEmpty);
  });
}
