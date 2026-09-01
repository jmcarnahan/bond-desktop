import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// An [LlmClient] that answers from a script, records what it was asked, and
/// never opens a socket.
class FakeLlm extends LlmClient {
  final List<Object> script;
  final List<String> userMessages = [];
  final List<double> temperatures = [];
  final List<int> tokenBudgets = [];

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
    userMessages.add(user);
    temperatures.add(temperature);
    tokenBudgets.add(maxTokens);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

Map<String, dynamic> answer({
  String evidence = 'Sarah is asking to extend the rate lock through Friday.',
  String replyBody = 'Hi Sarah — Friday works. I will send the addendum today.',
}) =>
    {'evidence': evidence, 'reply_body': replyBody};

void main() {
  late Database db;
  late MessageStore store;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  void seedInbound({
    String id = 'm2',
    String key = 'conv-1',
    String receivedAt = '2026-08-29T10:00:00Z',
    String address = 'sarah@x.com',
    String body = 'Can we extend the lock through Friday?',
  }) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Re: Rate lock',
      'from_name': 'Sarah',
      'from_address': address,
      'received_at': receivedAt,
      'body_text': body,
    });
  }

  void seedOutbound({
    String id = 'o1',
    String key = 'conv-1',
    String receivedAt = '2026-08-27T10:00:00Z',
    String to = 'sarah@x.com',
    String body = 'Thanks Sarah — I will check and come back to you. — Jo',
  }) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'outbound',
      'to_json': '["$to"]',
      'received_at': receivedAt,
      'body_text': body,
    });
  }

  Future<void> runOne(DraftHandler handler, {String key = 'conv-1'}) =>
      handler.run({'task_kind': 'draft', 'source': 'email', 'entity_id': key});

  group('the happy path', () {
    test('writes a suggested draft against the NEWEST inbound message',
        () async {
      seedInbound(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      seedInbound(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      final draft = store.getDraft('email', 'conv-1')!;
      expect(draft['status'], 'suggested');
      expect(draft['reply_to_message_id'], 'm2');
      expect(draft['body'], startsWith('Hi Sarah — Friday works.'));
      expect(
        draft['evidence'],
        'Sarah is asking to extend the rate lock through Friday.',
      );
      expect(draft['graph_draft_id'], isNull,
          reason: 'nothing here has touched Graph');
    });

    test('runs at temperature 0 with a budget big enough for a reply',
        () async {
      seedInbound();
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      expect(llm.temperatures, [0.0]);
      // The default 512 is enough to truncate a 150-word draft mid-sentence,
      // and a cut-off draft is still grammar-valid.
      expect(llm.tokenBudgets, [1024]);
    });

    test('ties on received_at break on source_message_id, like everywhere else',
        () async {
      seedInbound(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      seedInbound(id: 'm9', receivedAt: '2026-08-29T10:00:00Z');

      await runOne(DraftHandler(store, FakeLlm([answer()])));

      expect(store.getDraft('email', 'conv-1')!['reply_to_message_id'], 'm9');
    });
  });

  group('what goes into the prompt', () {
    test('the LO\'s past replies to this sender, as a tone sample', () async {
      seedOutbound(body: 'Sounds good — I will confirm by noon. — Jo');
      seedInbound();

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('style_examples'));
      expect(llm.userMessages.single, contains('I will confirm by noon'));
    });

    test('and nothing when the LO has never written to them', () async {
      seedOutbound(to: 'someone.else@x.com');
      seedInbound();

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, isNot(contains('style_examples')));
    });

    test('the about-me preference, read from the store', () async {
      seedInbound();
      store.setPref(aboutMeKey, 'I own rate locks and closing dates.');

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('about_me'));
      expect(llm.userMessages.single, contains('I own rate locks'));
    });

    test('the storyline summary, when the thread is in one', () async {
      seedInbound();
      store.insertStoryline(
        id: 's1',
        title: 'Willow St purchase',
        summary: 'Closing 9/15, lock expires 9/10.',
        status: 'active',
        createdBy: 'auto',
      );
      store.addStorylineMember('s1', 'email', 'conv-1', addedBy: 'auto');

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('storyline_summary'));
      expect(llm.userMessages.single, contains('lock expires 9/10'));
    });

    test('the whole thread, both directions', () async {
      seedOutbound(body: 'What is the current expiry? — Jo');
      seedInbound(body: 'It expires Wednesday.');

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('What is the current expiry?'));
      expect(llm.userMessages.single, contains('It expires Wednesday.'));
    });
  });

  group('the cases that spend no model time', () {
    test('a conversation that already has a draft is left alone', () async {
      seedInbound();
      store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'an existing draft',
      );
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages, isEmpty);
      expect(store.getDraft('email', 'conv-1')!['body'], 'an existing draft');
    });

    test('a conversation with no inbound mail is done, not failed', () async {
      seedOutbound();
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages, isEmpty);
      expect(store.getDraft('email', 'conv-1'), isNull);
    });
  });

  group('an empty draft', () {
    test('throws rather than storing a blank suggestion', () async {
      seedInbound();
      final llm = FakeLlm([answer(replyBody: '   ')]);

      await expectLater(
        runOne(DraftHandler(store, llm)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(store.getDraft('email', 'conv-1'), isNull);
    });

    test('and the worker retries it once, then gives up', () async {
      seedInbound();
      store.enqueueWork('draft', 'email', 'conv-1');
      final llm = FakeLlm([answer(replyBody: ''), answer(replyBody: '')]);
      final worker = AiWorker(store, handlers: [DraftHandler(store, llm)]);
      addTearDown(worker.dispose);

      await worker.pump();
      await worker.pump();

      expect(store.workCounts('draft'), {'error': 1});
      expect(llm.userMessages, hasLength(2),
          reason: 'one retry, then the item is left alone');
    });
  });

  group('through the worker', () {
    test('a queued conversation is drafted and marked done', () async {
      seedInbound();
      store.enqueueWork('draft', 'email', 'conv-1');
      final worker = AiWorker(
        store,
        handlers: [DraftHandler(store, FakeLlm([answer()]))],
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(store.workCounts('draft'), {'done': 1});
      expect(store.getDraft('email', 'conv-1'), isNotNull);
    });

    test('a model server that is down leaves the item queued and undrafted',
        () async {
      seedInbound();
      store.enqueueWork('draft', 'email', 'conv-1');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            FakeLlm([const LlmUnavailableException('not reachable')]),
          ),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(store.workCounts('draft'), {'pending': 1});
      expect(store.getDraft('email', 'conv-1'), isNull);
    });
  });
}
