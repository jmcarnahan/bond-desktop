import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:bond_inbox/services/storyline_handler.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// Where each stage of the real pipeline writes its progress.
///
/// The store-level behaviour is `message_progress_test.dart`'s subject; this
/// file is about the wiring — that the queues and handlers actually call the
/// recorder, at the moments that make the bar mean what it says. The
/// interesting cases are all the unhappy ones: a park is not a failure, a
/// retry is not an error, and a gate finishes a message rather than stalling
/// it.

/// An [LlmClient] that answers from a script and never opens a socket.
class FakeLlm extends LlmClient {
  final List<Object> script;

  FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

/// An embedding server that is not running — the state every test here wants,
/// since none of them is about vectors.
EmbeddingsClient downEmbeddings() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((_) async => http.Response('down', 503)),
    );

/// A storyline service whose only behaviour is the verdict a test asked for.
class FakeStorylines extends StorylineService {
  final AssignOutcome outcome;

  FakeStorylines(MessageStore store, this.outcome)
      : super(store, FakeLlm(const [<String, dynamic>{}]));

  @override
  Future<AssignOutcome> assignConversation(String source, String key) async =>
      outcome;
}

/// A handler that always throws what it was given — the two ways the worker
/// decides an item ended badly.
class ThrowingExtract extends WorkHandler {
  final Object error;

  ThrowingExtract(this.error);

  @override
  String get kind => 'extract';

  @override
  Future<void> run(Map<String, Object?> item) async => throw error;
}

/// The storyline pass's version of [ThrowingExtract]: an exception never
/// reaches the handler's own switch, so what happens next is entirely the
/// worker's call.
class ThrowingStoryline extends WorkHandler {
  final Object error;

  ThrowingStoryline(this.error);

  @override
  String get kind => 'storyline';

  @override
  Future<void> run(Map<String, Object?> item) async => throw error;
}

Map<String, dynamic> triageAnswer({String urgency = 'high'}) => {
      'urgency': urgency,
      'category': 'work',
      'summary': 'Jordan asks about the launch date.',
      'needs_action': true,
      'action_items': const ['Call Sarah about the lock'],
      'reply_expected': false,
      'deadline': '',
    };

Map<String, dynamic> extractAnswer() => {
      'evidence': 'Jordan is asking whether the launch date holds.',
      'topics': const ['launch date'],
      'project': 'Website redesign',
      'intent': 'request',
      'importance': 'high',
      'people': const <String>[],
      'dates': const <String>[],
      'amounts': const <String>[],
    };

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProgressBus bus;
  late PipelineProgress progress;
  late List<ProgressTick> ticks;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    bus = ProgressBus();
    progress = PipelineProgress(store, bus: bus);
    ticks = [];
    bus.ticks.listen(ticks.add);
  });

  tearDown(() async {
    bus.dispose();
    await db.close();
  });

  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String? from = 'sarah@example.com',
    String direction = 'inbound',
    String triageStatus = 'pending',
    String? gateReason,
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': conversationKey,
        'direction': direction,
        'subject': 'Launch date',
        'from_name': 'Sarah',
        'from_address': from,
        'received_at': '2026-09-01T10:00:00Z',
        'body_text': 'Does the launch date still hold?',
        'triage_status': triageStatus,
        'gate_reason': gateReason,
      });

  Future<Map<String, Object?>> progressOf(
    String id, {
    String source = 'email',
  }) async =>
      (await db
              .customSelect(
                'SELECT * FROM message_progress '
                'WHERE source = ? AND source_message_id = ?',
                variables: [Variable(source), Variable(id)],
              )
              .getSingle())
          .data;

  List<String> stagesOf(String stage) =>
      [for (final t in ticks.where((t) => t.stage == stage)) t.state];

  group('triage', () {
    test('a drained message runs and then finishes, with its urgency',
        () async {
      await seedMessage('m1');
      final queue = TriageQueue(
        store,
        FakeLlm([triageAnswer()]),
        concurrency: 1,
        progress: progress,
      );
      addTearDown(queue.dispose);

      await queue.pump();
      await pumpEventQueue();

      final row = await progressOf('m1');
      expect(row['triage_state'], 'done');
      expect(row['urgency'], 'high');
      // The claim is what `running` means, and it comes first.
      expect(stagesOf('triage'), ['running', 'done']);
    });

    test('a gated sender finishes the row instead of stalling it', () async {
      await seedMessage('m1', from: 'no-reply@example.com');
      final queue = TriageQueue(
        store,
        FakeLlm([triageAnswer()]),
        concurrency: 1,
        progress: progress,
      );
      addTearDown(queue.dispose);

      await queue.pump();

      final row = await progressOf('m1');
      expect(row['triage_state'], 'skipped');
      expect(row['dropped'], 1);
      expect(row['drop_reason'], 'no_reply');
      expect(row['settle_state'], 'done');
    });

    test('a model server that is not running parks rather than fails',
        () async {
      await seedMessage('m1');
      final queue = TriageQueue(
        store,
        FakeLlm([const LlmUnavailableException('server off')]),
        concurrency: 1,
        progress: progress,
      );
      addTearDown(queue.dispose);

      await queue.pump();
      await pumpEventQueue();

      // Nothing about this message failed, so the bar goes back to waiting.
      expect((await progressOf('m1'))['triage_state'], 'pending');
      expect(stagesOf('triage'), ['running', 'pending']);
    });

    test('a message that fails twice ends in error', () async {
      await seedMessage('m1');
      final queue = TriageQueue(
        store,
        FakeLlm([const LlmException('bad json', 400)]),
        concurrency: 1,
        progress: progress,
      );
      addTearDown(queue.dispose);

      await queue.pump();

      expect((await progressOf('m1'))['triage_state'], 'error');
    });
  });

  group('extraction', () {
    ExtractHandler handler(List<Object> script) => ExtractHandler(
          store,
          FakeLlm(script),
          downEmbeddings(),
          progress: progress,
        );

    test('it runs, then finishes once the facts are stored', () async {
      await seedMessage('m1');

      await handler([extractAnswer()])
          .run({'source': 'email', 'entity_id': 'm1'});
      await pumpEventQueue();

      expect((await progressOf('m1'))['extract_state'], 'done');
      expect(stagesOf('extract'), ['running', 'done']);
    });

    test('a message the gate threw out is skipped, not left running',
        () async {
      await seedMessage(
        'm1',
        triageStatus: 'skipped',
        gateReason: 'newsletter',
      );

      await handler([extractAnswer()])
          .run({'source': 'email', 'entity_id': 'm1'});

      // The ingest gate already finished this row; the handler honouring the
      // verdict must not reopen it.
      expect((await progressOf('m1'))['extract_state'], 'skipped');
    });

    test('a message deleted before the worker reached it is skipped',
        () async {
      await seedMessage('m1');
      await db.customUpdate(
        'DELETE FROM messages WHERE source_message_id = ?',
        variables: [Variable('m1')],
      );

      await handler([extractAnswer()])
          .run({'source': 'email', 'entity_id': 'm1'});

      expect((await progressOf('m1'))['extract_state'], 'skipped');
    });

    test('a server that is down parks the stage, and the worker says so',
        () async {
      await seedMessage('m1');
      await store.enqueueWork('extract', 'email', 'm1');
      final worker = AiWorker(
        store,
        handlers: [ThrowingExtract(const LlmUnavailableException('off'))],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      expect((await progressOf('m1'))['extract_state'], 'pending');
      expect(stagesOf('extract'), ['pending']);
    });

    test('a retry is not an error; the last attempt is', () async {
      await seedMessage('m1');
      await store.enqueueWork('extract', 'email', 'm1');
      final worker = AiWorker(
        store,
        handlers: [ThrowingExtract(StateError('unparseable'))],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      // Both attempts happen inside one drain: the first failure puts the row
      // back to `pending` with an attempt spent, the drain claims it again,
      // and the second is the one the worker gives up on. A bar that showed
      // red in between would be calling a state final that the queue does not.
      expect(stagesOf('extract'), ['pending', 'error']);
      expect((await progressOf('m1'))['extract_state'], 'error');
    });
  });

  group('the storyline pass', () {
    Future<void> assign(AssignOutcome outcome) => StorylineAssignHandler(
          FakeStorylines(store, outcome),
          progress: progress,
        ).run({'source': 'email', 'entity_id': 'c1'});

    test('a thread that was filed carries the storyline it landed in',
        () async {
      await seedMessage('m1');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      await assign(AssignOutcome.assigned);

      final row = await progressOf('m1');
      expect(row['storyline_state'], 'done');
      expect(row['storyline_id'], 'sl-1');
    });

    test('a thread nothing matched is finished, without a storyline',
        () async {
      await seedMessage('m1');

      await assign(AssignOutcome.noCandidate);

      final row = await progressOf('m1');
      expect(row['storyline_state'], 'done');
      expect(row['storyline_id'], null);
    });

    test('a thread the model turned down is finished too', () async {
      await seedMessage('m1');

      await assign(AssignOutcome.rejected);

      expect((await progressOf('m1'))['storyline_state'], 'done');
    });

    test('a thread with no vector yet parks with its queue', () async {
      await seedMessage('m1');

      await assign(AssignOutcome.noVector);

      // The work row parks on an embedding server that is not running, and a
      // bar that claimed `done` would be reporting a verdict nobody reached.
      expect((await progressOf('m1'))['storyline_state'], 'pending');
      expect(stagesOf('storyline'), isEmpty);
    });

    test('a pass that dies for good is an error, said by the worker',
        () async {
      await seedMessage('m1');
      await store.enqueueWork('storyline', 'email', 'c1');
      final worker = AiWorker(
        store,
        handlers: [ThrowingStoryline(StateError('unparseable'))],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await pumpEventQueue();

      // The handler only speaks on success, so without the worker's word the
      // stage would sit at `pending` and the row would never settle. One tick,
      // not one per retry: an item with an attempt left is waiting, not
      // failed.
      expect(stagesOf('storyline'), ['error']);
      expect((await progressOf('m1'))['storyline_state'], 'error');
    });
  });

  group('the settle', () {
    /// One unread inbound message the pipeline has finished with, worth
    /// announcing — every argument turns exactly one of those facts off.
    Future<void> seedCandidate({
      String triageStatus = 'triaged',
      bool replyExpected = true,
      int isRead = 0,
      double attentionScore = 0.9,
    }) async {
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c1',
        'subject': 'Launch date',
        'state': 'needs_reply',
        'last_message_at': '2026-09-02T11:55:00.000Z',
      });
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'subject': 'Launch date',
        'from_name': 'Sarah',
        'received_at': '2026-09-02T11:55:00.000Z',
        'is_read': isRead,
        'created_at': '2026-09-02T12:01:00.000Z',
      });
      await store.writeTriage(
        'email',
        'm1',
        status: triageStatus,
        result: triageStatus == 'triaged'
            ? TriageResult(
                urgency: 'normal',
                category: 'work',
                summary: 'what m1 says',
                needsAction: false,
                actionItems: const [],
                replyExpected: replyExpected,
                deadline: '',
              )
            : null,
      );
      await store.writeAttentionScore('email', 'c1', attentionScore);
      // The pipeline has finished with it, drafting included — a settle
      // writes the verdict either way, but the row is only CLOSED once the
      // reply suggestion (or the decision that none is needed) is stored, and
      // these tests are about the verdict.
      await progress.noteDraft('email', 'm1', state: 'skipped');
    }

    NotificationCoordinator coordinatorAt(DateTime now) {
      final coordinator = NotificationCoordinator(
        store,
        clock: () => now,
        progress: progress,
      );
      coordinator.noteSyncCompleted();
      addTearDown(coordinator.dispose);
      return coordinator;
    }

    test('an announced message is done, needing the user', () async {
      await seedCandidate();

      await coordinatorAt(DateTime.utc(2026, 9, 2, 12)).sweep();

      final row = await progressOf('m1');
      expect(row['settle_state'], 'done');
      expect(row['outcome'], 'done');
      expect(row['dropped'], 0);
      expect(row['needs_you'], 1);
    });

    test('one the user got to first is done, not dropped', () async {
      await seedCandidate(triageStatus: 'pending');
      final coordinator = coordinatorAt(DateTime.utc(2026, 9, 2, 12));
      await coordinator.sweep();
      await store.markConversationRead('email', 'c1');

      await coordinator.sweep();

      final row = await progressOf('m1');
      expect(row['outcome'], 'done');
      expect(row['dropped'], 0);
      // "You got there first" is not "we threw it away", so it stays out of
      // the show-dropped bucket.
      expect(row['drop_reason'], null);
    });

    test('one nothing was asking for is dropped, with the reason', () async {
      await seedCandidate(replyExpected: false);

      await coordinatorAt(DateTime.utc(2026, 9, 2, 12)).sweep();

      final row = await progressOf('m1');
      expect(row['outcome'], 'dropped');
      expect(row['dropped'], 1);
      expect(row['drop_reason'], 'not_worthy');
      expect(row['needs_you'], 0);
    });

    test('one the gate caught after admission is dropped', () async {
      await seedCandidate(triageStatus: 'pending');
      final coordinator = coordinatorAt(DateTime.utc(2026, 9, 2, 12));
      await coordinator.sweep();
      await store.writeTriage('email', 'm1', status: 'skipped');

      await coordinator.sweep();

      final row = await progressOf('m1');
      expect(row['dropped'], 1);
      expect(row['drop_reason'], 'gated');
    });
  });

  test('nothing above is wired to a recorder by default', () async {
    // Every constructor takes the disabled recorder, which is what keeps the
    // rest of the suite from paying for this file's subject.
    await seedMessage('m1');
    final queue = TriageQueue(store, FakeLlm([triageAnswer()]), concurrency: 1);
    addTearDown(queue.dispose);

    await queue.pump();

    // Triage ran — the message is triaged — and said nothing to any bus.
    expect(
      (await store.getMessageRow('email', 'm1'))!['triage_status'],
      'triaged',
    );
    expect((await progressOf('m1'))['triage_state'], 'pending');
    expect(ticks, isEmpty);
  });
}
