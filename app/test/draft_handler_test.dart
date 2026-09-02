import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

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
  String evidence = 'Jordan is asking whether the launch still lands on Thursday.',
  String replyBody = 'Hi Sarah — Friday works. I will send the addendum today.',
  List<Map<String, String>> options = const [],
}) =>
    {'evidence': evidence, 'reply_body': replyBody, 'options': options};

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seedInbound({
    String id = 'm2',
    String key = 'conv-1',
    String receivedAt = '2026-08-29T10:00:00Z',
    String address = 'sarah@x.com',
    String body = 'Can we still ship on Thursday?',
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Re: Launch date',
      'from_name': 'Sarah',
      'from_address': address,
      'received_at': receivedAt,
      'body_text': body,
    });
  }

  Future<void> seedOutbound({
    String id = 'o1',
    String key = 'conv-1',
    String receivedAt = '2026-08-27T10:00:00Z',
    String to = 'sarah@x.com',
    String body = 'Thanks Sarah — I will check and come back to you. — Jo',
  }) async {
    await store.upsertMessage({
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
      await seedInbound(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedInbound(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      final draft = (await store.getDraft('email', 'conv-1'))!;
      expect(draft['status'], 'suggested');
      expect(draft['reply_to_message_id'], 'm2');
      expect(draft['body'], startsWith('Hi Sarah — Friday works.'));
      expect(
        draft['evidence'],
        'Jordan is asking whether the launch still lands on Thursday.',
      );
      expect(draft['graph_draft_id'], isNull,
          reason: 'nothing here has touched Graph');
    });

    test('runs at temperature 0 with a budget big enough for a reply',
        () async {
      await seedInbound();
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      expect(llm.temperatures, [0.0]);
      // The default 512 is enough to truncate a 150-word draft mid-sentence,
      // and a cut-off draft is still grammar-valid. The answer now carries the
      // short options as well as the long form, so the ceiling went up with it.
      expect(llm.tokenBudgets, [1536]);
    });

    test('ties on received_at break on source_message_id, like everywhere else',
        () async {
      await seedInbound(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      await seedInbound(id: 'm9', receivedAt: '2026-08-29T10:00:00Z');

      await runOne(DraftHandler(store, FakeLlm([answer()])));

      expect((await store.getDraft('email', 'conv-1'))!['reply_to_message_id'], 'm9');
    });
  });

  group('what goes into the prompt', () {
    test('the LO\'s past replies to this sender, as a tone sample', () async {
      await seedOutbound(body: 'Sounds good — I will confirm by noon. — Jo');
      await seedInbound();

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('style_examples'));
      expect(llm.userMessages.single, contains('I will confirm by noon'));
    });

    test('and nothing when the LO has never written to them', () async {
      await seedOutbound(to: 'someone.else@x.com');
      await seedInbound();

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, isNot(contains('style_examples')));
    });

    test('the about-me preference, read from the store', () async {
      await seedInbound();
      await store.setPref(aboutMeKey, 'I own the website redesign and the launch.');

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('about_me'));
      expect(llm.userMessages.single, contains('I own the website redesign'));
    });

    test('the storyline summary, when the thread is in one', () async {
      await seedInbound();
      await store.insertStoryline(
        id: 's1',
        title: 'Website redesign',
        summary: 'Closing 9/15, lock expires 9/10.',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('s1', 'email', 'conv-1', addedBy: 'auto');

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('storyline_summary'));
      expect(llm.userMessages.single, contains('lock expires 9/10'));
    });

    test('the whole thread, both directions', () async {
      await seedOutbound(body: 'What is the current expiry? — Jo');
      await seedInbound(body: 'It expires Wednesday.');

      final llm = FakeLlm([answer()]);
      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages.single, contains('What is the current expiry?'));
      expect(llm.userMessages.single, contains('It expires Wednesday.'));
    });
  });

  group('the cases that spend no model time', () {
    test('a conversation that already has a draft is left alone', () async {
      await seedInbound();
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'an existing draft',
      );
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages, isEmpty);
      expect((await store.getDraft('email', 'conv-1'))!['body'], 'an existing draft');
    });

    test('a conversation with no inbound mail is done, not failed', () async {
      await seedOutbound();
      final llm = FakeLlm([answer()]);

      await runOne(DraftHandler(store, llm));

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraft('email', 'conv-1'), isNull);
    });
  });

  group('the short replies', () {
    test('are stored beside the long form, stance and body', () async {
      await seedInbound();
      final llm = FakeLlm([
        answer(options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
          {'stance': 'Propose Monday', 'reply_body': 'Could we say Monday?'},
        ]),
      ]);

      await runOne(DraftHandler(store, llm));

      final draft = (await store.getDraft('email', 'conv-1'))!;
      final stored = jsonDecode(draft['options_json'] as String) as List;
      expect(stored, [
        {'stance': 'Confirm Thursday', 'body': 'Thursday still works.'},
        {'stance': 'Propose Monday', 'body': 'Could we say Monday?'},
      ]);
      expect(draft['options_dismissed'], 0);
      expect(draft['body'], startsWith('Hi Sarah — Friday works.'));
    });

    test('are null, not an empty array, when the model offered none', () async {
      // The two spellings say the same thing to every reader, and one of them
      // is shorter.
      await seedInbound();

      await runOne(DraftHandler(store, FakeLlm([answer()])));

      expect((await store.getDraft('email', 'conv-1'))!['options_json'], isNull);
    });

    test('a half-written option does not reach the row', () async {
      await seedInbound();
      final llm = FakeLlm([
        answer(options: const [
          {'stance': '', 'reply_body': 'unlabelled'},
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
        ]),
      ]);

      await runOne(DraftHandler(store, llm));

      final draft = (await store.getDraft('email', 'conv-1'))!;
      expect(jsonDecode(draft['options_json'] as String), [
        {'stance': 'Confirm Thursday', 'body': 'Thursday still works.'},
      ]);
    });
  });

  group('an empty draft', () {
    test('throws rather than storing a blank suggestion, options or not',
        () async {
      // The long form is the product; options that arrived alongside a blank
      // reply are not a reason to store a draft the worker should retry.
      await seedInbound();
      final llm = FakeLlm([
        answer(replyBody: '   ', options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday works.'},
        ]),
      ]);

      await expectLater(
        runOne(DraftHandler(store, llm)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraft('email', 'conv-1'), isNull);
    });

    test('throws rather than storing a blank suggestion', () async {
      await seedInbound();
      final llm = FakeLlm([answer(replyBody: '   ')]);

      await expectLater(
        runOne(DraftHandler(store, llm)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraft('email', 'conv-1'), isNull);
    });

    test('and the worker retries it once, then gives up', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'conv-1');
      final llm = FakeLlm([answer(replyBody: ''), answer(replyBody: '')]);
      final worker = AiWorker(store, handlers: [DraftHandler(store, llm)]);
      addTearDown(worker.dispose);

      await worker.pump();
      await worker.pump();

      expect(await store.workCounts('draft'), {'error': 1});
      expect(llm.userMessages, hasLength(2),
          reason: 'one retry, then the item is left alone');
    });
  });

  group('through the worker', () {
    test('a queued conversation is drafted and marked done', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'conv-1');
      final worker = AiWorker(
        store,
        handlers: [DraftHandler(store, FakeLlm([answer()]))],
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(await store.workCounts('draft'), {'done': 1});
      expect(await store.getDraft('email', 'conv-1'), isNotNull);
    });

    test('a model server that is down leaves the item queued and undrafted',
        () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'conv-1');
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

      expect(await store.workCounts('draft'), {'pending': 1});
      expect(await store.getDraft('email', 'conv-1'), isNull);
    });
  });
}
