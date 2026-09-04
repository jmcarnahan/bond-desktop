import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The settle pass — what the inbox does once its two queues have drained.
///
/// What it is for: [ConversationsNotifier.load] scores the mailbox before the
/// pumps it starts have finished, so the frame on screen is right and what the
/// model learned a second later is not. The settle pass scores it again,
/// closes out the rows the notification coordinator was never going to reach,
/// and puts the result on screen.
///
/// It queues nothing. Drafting work is written from the end of extraction, per
/// message, so it lands mid-drain and the drafting handler — last in the
/// worker's order — takes it on the same pass.

/// A [MailSync] that never touches a socket.
class FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// Counts the list reads, so a trailing reload can be told from a missing one.
class RecordingStore extends MessageStore {
  final List<String> log;

  RecordingStore(super.db, this.log);

  @override
  Future<List<Conversation>> loadConversations({
    List<String> sources = const ['email'],
    ConversationState? state,
  }) {
    log.add('read');
    return super.loadConversations(sources: sources, state: state);
  }
}

/// A triage queue that never calls a model. It logs on COMPLETION rather than
/// on entry, so the order the log records is the order things finished in —
/// which is the only order this file has an opinion about.
class FakeTriage extends TriageQueue {
  final List<String> log;

  /// Run at the end of each pump: what triage learning something looks like.
  final Future<void> Function()? onPumped;

  FakeTriage(MessageStore store, this.log, {this.onPumped})
      : super(store, LlmClient(baseUrl: 'http://127.0.0.1:1/never-dialled'));

  @override
  Future<void> pump() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await onPumped?.call();
    log.add('triage');
  }
}

class FakeWorker extends AiWorker {
  final List<String> log;

  FakeWorker(super.store, this.log) : super(handlers: const []);

  @override
  Future<void> pump() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    log.add('ai');
  }
}

/// A handler that does nothing but exist — enough for a real [AiWorker] drain
/// to report progress, which is the thing under test.
class NoopHandler extends WorkHandler {
  @override
  String get kind => 'extract';

  @override
  Future<void> run(Map<String, Object?> item) async {}
}

/// Logs every rescore, and can be told to fail one of them.
class FakeAttention extends AttentionService {
  final List<String> log;

  /// Which call throws, counting from 1. Null never throws.
  final int? failOnCall;

  int calls = 0;

  FakeAttention(super.store, this.log, {this.failOnCall});

  @override
  Future<int> recomputeAll({
    List<String> sources = const ['email'],
    DateTime? now,
  }) async {
    calls++;
    log.add('recompute');
    if (calls == failOnCall) throw StateError('scoring fell over');
    return 0;
  }
}

void main() {
  late BondDatabase db;
  late RecordingStore store;
  late FakeSync sync;
  late List<String> log;

  setUp(() {
    db = testDb();
    log = <String>[];
    store = RecordingStore(db, log);
    sync = FakeSync();
  });

  tearDown(() => db.close());

  /// Both pumps are started and never awaited, so a test has to let the whole
  /// chain — pumps, settle, trailing reload — run.
  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> seedThread({
    String key = 'conv-1',
    String state = 'waiting',
    double? score,
  }) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': '2026-08-29T10:00:00Z',
    });
    if (score != null) await store.writeAttentionScore('email', key, score);
  }

  Future<List<String>> queuedDrafts() async => [
        for (final row in await db
            .customSelect(
              "SELECT entity_id FROM work_items WHERE task_kind = 'draft' "
              "AND status = 'pending' ORDER BY entity_id",
            )
            .get())
          row.data['entity_id'] as String,
      ];

  ConversationsNotifier notifierFor({
    TriageQueue? triage,
    AiWorker? aiWorker,
    AttentionService? attention,
  }) {
    final notifier = ConversationsNotifier(
      store,
      sync,
      triage: triage,
      aiWorker: aiWorker,
      attention: attention,
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  test('the settle pass runs after BOTH queues, not between them', () async {
    final triage = FakeTriage(store, log);
    final worker = FakeWorker(store, log);
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);

    await notifierFor(
      triage: triage,
      aiWorker: worker,
      attention: FakeAttention(store, log),
    ).load();
    await settle();

    // Read as: the load scores and reads for the frame on screen, the queues
    // run, and only then does the mailbox get scored against what they
    // learned — followed by the trailing re-read that puts it on screen.
    expect(log, [
      'recompute',
      'read',
      'triage',
      'ai',
      'recompute',
      'recompute',
      'read',
    ]);
  });

  test('the mailbox is rescored again once the queues have finished',
      () async {
    final triage = FakeTriage(store, log);
    final worker = FakeWorker(store, log);
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);
    final attention = FakeAttention(store, log);

    await notifierFor(triage: triage, aiWorker: worker, attention: attention)
        .load();
    await settle();

    // Once for the frame the user is looking at, once for what the model
    // learned — and once more inside the trailing reload, which is the same
    // load path every other reload takes.
    expect(attention.calls, 3);
  });

  test('exactly one list re-read trails the settle pass', () async {
    final triage = FakeTriage(store, log);
    final worker = FakeWorker(store, log);
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);

    await notifierFor(
      triage: triage,
      aiWorker: worker,
      attention: FakeAttention(store, log),
    ).load();
    await settle();

    expect(log.where((e) => e == 'read'), hasLength(2));
  });

  test('the queue is pumped once — drafting rides the same drain', () async {
    // Nothing here enqueues a draft, and the settle pass does not pump again
    // to look for one: a settle that re-drained would be a loop with a model
    // call in it, and the work drafting needs is written mid-drain by
    // extraction anyway.
    await seedThread();
    final triage = FakeTriage(store, log);
    final worker = FakeWorker(store, log);
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);

    await notifierFor(
      triage: triage,
      aiWorker: worker,
      attention: FakeAttention(store, log),
    ).load();
    await settle();

    expect(await queuedDrafts(), isEmpty);
    expect(log.where((e) => e == 'ai'), hasLength(1));
  });

  test('a Teams refresh settles the same way a mail sync does', () async {
    await seedThread();
    final triage = FakeTriage(
      store,
      log,
      onPumped: () async {
        await store.setConversationState(
          'email',
          'conv-1',
          ConversationState.needsReply,
        );
        await store.writeAttentionScore('email', 'conv-1', 0.9);
      },
    );
    final worker = FakeWorker(store, log);
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);

    final notifier = ConversationsNotifier(
      store,
      sync,
      teamsSync: FakeTeamsRefresh(store),
      triage: triage,
      aiWorker: worker,
      attention: FakeAttention(store, log),
    );
    addTearDown(notifier.dispose);

    await notifier.refreshTeams();
    await settle();

    // A Teams-only session never runs a mail sync, so this path is the only
    // one that would ever score what the queues just learned.
    expect(log.where((e) => e == 'recompute'), hasLength(3));
    expect(log.where((e) => e == 'ai'), hasLength(1));
  });

  test('with no triage queue wired the AI queue still settles', () async {
    final worker = FakeWorker(store, log);
    addTearDown(worker.dispose);

    await notifierFor(
      aiWorker: worker,
      attention: FakeAttention(store, log),
    ).load();
    await settle();

    expect(log, ['recompute', 'read', 'ai', 'recompute', 'recompute', 'read']);
  });

  test('a load that skips the sync starts nothing to settle', () async {
    final triage = FakeTriage(store, log);
    final worker = FakeWorker(store, log);
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);

    await notifierFor(
      triage: triage,
      aiWorker: worker,
      attention: FakeAttention(store, log),
    ).load(syncFirst: false);
    await settle();

    expect(log, ['recompute', 'read']);
  });

  test('a settle pass that falls over is traced, not thrown', () async {
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        printed.add(message ?? '');
    addTearDown(() => debugPrint = original);

    final triage = FakeTriage(store, log);
    final worker = FakeWorker(store, log);
    addTearDown(triage.dispose);
    addTearDown(worker.dispose);

    // The second rescore is the settle pass's; the first one belongs to the
    // load that is already on screen.
    final notifier = notifierFor(
      triage: triage,
      aiWorker: worker,
      attention: FakeAttention(store, log, failOnCall: 2),
    );
    await notifier.load();
    await settle();

    expect(
      printed,
      contains(startsWith('queue pump chain failed:')),
    );
    // The inbox the user is looking at is untouched by it.
    expect(notifier.state, isA<ConversationsLoaded>());
  });

  test('AI progress alone repaints the list', () async {
    // No triage in this cycle at all — a CTA landing from extract, or a thread
    // joining a storyline. Before the AI queue had a listener, the list found
    // out at the next sync.
    await seedThread();
    await store.enqueueWork('extract', 'email', 'm1');
    final worker = AiWorker(store, handlers: [NoopHandler()]);
    addTearDown(worker.dispose);

    final notifier = notifierFor(aiWorker: worker);
    await notifier.load(syncFirst: false);
    final before = log.where((e) => e == 'read').length;

    await worker.pump();
    // Past the 400ms debounce the progress stream reloads on.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(log.where((e) => e == 'read').length, greaterThan(before));
  });
}

/// A Teams connector that lands nothing — [ConversationsNotifier.refreshTeams]
/// only needs one to exist before it kicks the same chain a mail sync does.
/// Subclassed rather than faked to an interface for the reason
/// `teams_refresh_test.dart` records: there is no interface, and inventing one
/// so a test can no-op would put a seam in production code only the test
/// needs.
class FakeTeamsRefresh extends TeamsSync {
  FakeTeamsRefresh(MessageStore store) : super(_UnreachableTeams(), store);

  @override
  Future<void> syncNow() async {}
}

/// Every method a fatal error: this connector is never reached.
class _UnreachableTeams implements TeamsBackend {
  Never _no() => throw StateError('Teams must not be reached here');

  @override
  Future<String> myUserId() => _no();

  @override
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4}) => _no();

  @override
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) => _no();

  @override
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  }) =>
      _no();

  @override
  Future<void> markChatRead(String chatId) => _no();

  @override
  Future<Map<String, dynamic>> sendChatMessage(String chatId, String text) =>
      _no();
}
