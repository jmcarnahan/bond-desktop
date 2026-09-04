import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/draft_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:drift/drift.dart' show Variable;
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

/// The reply-decision call's answer. It comes FIRST in every script: the
/// handler asks whether a reply is owed before it spends anything writing one.
Map<String, dynamic> decision({
  bool needsReply = true,
  String reason = 'Sarah is waiting on a date.',
}) =>
    {'needs_reply': needsReply, 'reason': reason};

Map<String, dynamic> answer({
  String evidence = 'Jordan is asking whether the launch still lands on Thursday.',
  String replyBody = 'Hi Sarah — Friday works. I will send the addendum today.',
  List<Map<String, String>> options = const [],
}) =>
    {'evidence': evidence, 'reply_body': replyBody, 'options': options};


void main() {
  late BondDatabase db;
  late MessageStore store;
  late PipelineProgress progress;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    progress = PipelineProgress(store);
  });

  tearDown(() async => db.close());

  Future<void> seedInbound({
    String id = 'm2',
    String key = 'conv-1',
    String receivedAt = '2026-08-29T10:00:00Z',
    String address = 'sarah@x.com',
    String body = 'Can we still ship on Thursday?',
    String triageStatus = 'pending',
    String? gateReason,
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
      'triage_status': triageStatus,
      'gate_reason': gateReason,
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

  Future<void> seedChat({
    String id = 'chat-1-m1',
    String key = 'chat-1',
    String receivedAt = '2026-08-29T10:00:00Z',
    String body = 'Any word on the CD?',
  }) async {
    await store.upsertMessage({
      'source': 'teams',
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      // A namespaced Graph id, which is what the connector stores. There is no
      // address to match a past reply against.
      'from_address': 'teams:u1',
      'received_at': receivedAt,
      'body_text': body,
    });
  }

  /// The work item is keyed on the MESSAGE now: `entity_id` is a source
  /// message id, not a conversation key.
  Future<void> runOne(
    DraftHandler handler, {
    String id = 'm2',
    String source = 'email',
  }) =>
      handler.run({'task_kind': 'draft', 'source': source, 'entity_id': id});

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

  group('the happy path', () {
    test('writes a suggested draft against the message it was queued for',
        () async {
      await seedInbound(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedInbound(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress), id: 'm1');

      // m1, not the thread's newest message: the queue works at the grain of
      // the thing being answered.
      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['status'], 'suggested');
      expect(draft['conversation_key'], 'conv-1');
      expect(draft['body'], startsWith('Hi Sarah — Friday works.'));
      expect(
        draft['evidence'],
        'Jordan is asking whether the launch still lands on Thursday.',
      );
      expect(draft['graph_draft_id'], isNull,
          reason: 'nothing here has touched Graph');
      expect((await progressOf('m1'))['draft_state'], 'done');
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('the decision runs first, cheap, and the draft after it', () async {
      await seedInbound();
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      // Both at zero: the same message must get the same verdict and the same
      // reply twice. The budgets differ because the answers do — a yes/no and
      // a sentence, then a reply long enough to send.
      expect(llm.temperatures, [0.0, 0.0]);
      expect(llm.tokenBudgets, [256, 1536]);
    });

    test('the draft stage lands done and stamps the row', () async {
      await seedInbound();

      await runOne(
        DraftHandler(store, FakeLlm([decision(), answer()]), progress: progress),
      );

      final row = await progressOf('m2');
      expect(row['draft_state'], 'done');
      expect(row['draft_at'], isNotNull);
    });

    test('and it closes the row when it is the last stage left', () async {
      await seedInbound();
      await progress.noteTriage('email', 'm2', state: 'done');
      await progress.noteExtract('email', 'm2', state: 'done');
      await progress.noteStoryline('email', 'conv-1', state: 'done');
      await progress.noteSettled(
        'email',
        'm2',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );

      // The toast has already gone out; the row is not finished until the
      // suggestion is in sqlite.
      expect((await progressOf('m2'))['outcome'], 'pending');

      await runOne(
        DraftHandler(store, FakeLlm([decision(), answer()]), progress: progress),
      );

      expect((await progressOf('m2'))['outcome'], 'done');
    });
  });

  group('the decision', () {
    test('a no stores nothing and spends one call', () async {
      await seedInbound();
      final llm = FakeLlm([
        decision(needsReply: false, reason: 'A receipt, nobody is waiting.'),
        answer(),
      ]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, hasLength(1),
          reason: 'the drafting model is never reached');
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      // A real end state: the model read the thread and said no reply is owed.
      expect((await progressOf('m2'))['draft_state'], 'skipped');
    });

    test('reads the message and the thread before it', () async {
      await seedOutbound(body: 'What is the current expiry? — Jo');
      await seedInbound(body: 'It expires Wednesday.');
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.first, contains('It expires Wednesday.'));
      expect(llm.userMessages.first, contains('What is the current expiry?'));
      expect(llm.userMessages.first, contains('Decide about ONLY this'));
    });

    test('and never a message that landed after the one it is judging',
        () async {
      await seedInbound(
        id: 'm1',
        receivedAt: '2026-08-20T10:00:00Z',
        body: 'Can we still ship on Thursday?',
      );
      await seedInbound(
        id: 'm2',
        receivedAt: '2026-08-29T10:00:00Z',
        body: 'Never mind, we shipped it.',
      );
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress), id: 'm1');

      // The thread is cut off at the message being answered, so the answer to
      // m1 is the same answer however far behind the queue was.
      for (final prompt in llm.userMessages) {
        expect(prompt, contains('Can we still ship on Thursday?'));
        expect(prompt, isNot(contains('Never mind, we shipped it.')));
      }
    });
  });

  group('what goes into the drafting prompt', () {
    test('the user\'s past replies to this sender, as a tone sample', () async {
      await seedOutbound(body: 'Sounds good — I will confirm by noon. — Jo');
      await seedInbound();

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('style_examples'));
      expect(llm.userMessages.last, contains('I will confirm by noon'));
    });

    test('and nothing when the user has never written to them', () async {
      await seedOutbound(to: 'someone.else@x.com');
      await seedInbound();

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, isNot(contains('style_examples')));
    });

    test('the about-me preference, read from the store', () async {
      await seedInbound();
      await store.setPref(aboutMeKey, 'I own the website redesign and the launch.');

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      // Both calls get it: who the owner is decides whether THEY have to
      // answer as much as it decides how the answer reads.
      for (final prompt in llm.userMessages) {
        expect(prompt, contains('about_me'));
        expect(prompt, contains('I own the website redesign'));
      }
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

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('storyline_summary'));
      expect(llm.userMessages.last, contains('lock expires 9/10'));
    });

    test('the whole thread, both directions', () async {
      await seedOutbound(body: 'What is the current expiry? — Jo');
      await seedInbound(body: 'It expires Wednesday.');

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('What is the current expiry?'));
      expect(llm.userMessages.last, contains('It expires Wednesday.'));
    });

    test('the email channel note, alongside the style fence', () async {
      await seedOutbound(body: 'Sounds good — I will confirm by noon. — Jo');
      await seedInbound();

      final llm = FakeLlm([decision(), answer()]);
      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages.last, contains('This is an email thread.'));
      expect(llm.userMessages.last, contains('style_examples'));
    });
  });

  group('a chat drafts through the same handler', () {
    test('and gets the chat channel note, not the email one', () async {
      await seedChat();
      final llm = FakeLlm([
        decision(),
        answer(replyBody: 'Sending it over now.'),
      ]);

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(
        llm.userMessages.last,
        contains('This is an instant-message chat.'),
      );
      expect(
        llm.userMessages.last,
        isNot(contains('This is an email thread.')),
      );
      expect((await store.getDraftForMessage('teams', 'chat-1-m1'))!['body'],
          'Sending it over now.');
    });

    test('with no style fence — a chat has no addressed past replies',
        () async {
      // `recentOutboundToSender` matches on `to_json`, which a chat never
      // writes, so this is the skip made visible: the sample the LIKE could
      // never have found does not appear as an empty fence either.
      await seedChat();
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-1-o1',
        'conversation_key': 'chat-1',
        'direction': 'outbound',
        'received_at': '2026-08-28T10:00:00Z',
        'body_text': 'On it — will check this afternoon.',
      });
      final llm = FakeLlm([decision(), answer()]);

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(llm.userMessages.last, isNot(contains('style_examples')));
      // The owner's own chat voice is already in the thread, turn by turn.
      expect(
        llm.userMessages.last,
        contains('On it — will check this afternoon.'),
      );
    });

    test('and its thread lines name the sender rather than the Graph id',
        () async {
      await seedChat();
      final llm = FakeLlm([decision(), answer()]);

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(llm.userMessages.last, contains('From: Sarah Whitfield'));
      expect(llm.userMessages.last, isNot(contains('teams:u1')));
    });
  });

  group('the cases that spend no model time', () {
    test('a message that already has an answer is left alone', () async {
      await seedInbound();
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'an existing draft',
      );
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          'an existing draft');
      // Done, not skipped: this message has its suggestion.
      expect((await progressOf('m2'))['draft_state'], 'done');
    });

    test('a message that vanished is done, not failed', () async {
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('the user\'s own message is skipped', () async {
      await seedOutbound();
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress), id: 'o1');

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'o1'), isNull);
      expect((await progressOf('o1'))['draft_state'], 'skipped');
    });

    test('a message triage gated after the enqueue is skipped', () async {
      await seedInbound(triageStatus: 'skipped', gateReason: 'newsletter');
      final llm = FakeLlm([decision(), answer()]);

      await runOne(DraftHandler(store, llm, progress: progress));

      expect(llm.userMessages, isEmpty);
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      expect((await progressOf('m2'))['draft_state'], 'skipped');
    });

    test('but a chat skipped by birth still gets an answer', () async {
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-1-m1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Sarah Whitfield',
        'from_address': 'teams:u1',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Any word on the CD?',
        'triage_status': 'skipped',
        'gate_reason': 'teams_source',
      });
      final llm = FakeLlm([decision(), answer()]);

      await runOne(
        DraftHandler(store, llm, progress: progress),
        id: 'chat-1-m1',
        source: 'teams',
      );

      expect(await store.getDraftForMessage('teams', 'chat-1-m1'), isNotNull);
    });
  });

  group('the short replies', () {
    test('are stored beside the long form, stance and body', () async {
      await seedInbound();
      final llm = FakeLlm([
        decision(),
        answer(options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
          {'stance': 'Propose Monday', 'reply_body': 'Could we say Monday?'},
        ]),
      ]);

      await runOne(DraftHandler(store, llm, progress: progress));

      final draft = (await store.getDraftForMessage('email', 'm2'))!;
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

      await runOne(
        DraftHandler(store, FakeLlm([decision(), answer()]), progress: progress),
      );

      expect((await store.getDraftForMessage('email', 'm2'))!['options_json'],
          isNull);
    });

    test('a half-written option does not reach the row', () async {
      await seedInbound();
      final llm = FakeLlm([
        decision(),
        answer(options: const [
          {'stance': '', 'reply_body': 'unlabelled'},
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday still works.'},
        ]),
      ]);

      await runOne(DraftHandler(store, llm, progress: progress));

      final draft = (await store.getDraftForMessage('email', 'm2'))!;
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
        decision(),
        answer(replyBody: '   ', options: const [
          {'stance': 'Confirm Thursday', 'reply_body': 'Thursday works.'},
        ]),
      ]);

      await expectLater(
        runOne(DraftHandler(store, llm, progress: progress)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('throws rather than storing a blank suggestion', () async {
      await seedInbound();
      final llm = FakeLlm([decision(), answer(replyBody: '   ')]);

      await expectLater(
        runOne(DraftHandler(store, llm, progress: progress)),
        throwsA(isA<LlmFormatException>()),
      );
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
    });

    test('and the worker retries it once, then gives up', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final llm = FakeLlm([
        decision(),
        answer(replyBody: ''),
        decision(),
        answer(replyBody: ''),
      ]);
      final worker = AiWorker(
        store,
        handlers: [DraftHandler(store, llm, progress: progress)],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();
      await worker.pump();

      expect(await store.workCounts('draft'), {'error': 1});
      expect(llm.userMessages, hasLength(4),
          reason: 'one retry, then the item is left alone');
      // Red only once the retries are gone — a bar that showed it in between
      // would report a state the pipeline does not consider final.
      expect((await progressOf('m2'))['draft_state'], 'error');
    });
  });

  group('through the worker', () {
    test('a queued message is drafted and marked done', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            FakeLlm([decision(), answer()]),
            progress: progress,
          ),
        ],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(await store.workCounts('draft'), {'done': 1});
      expect(await store.getDraftForMessage('email', 'm2'), isNotNull);
    });

    test('a server that is down during the DECISION leaves the item queued',
        () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            FakeLlm([const LlmUnavailableException('not reachable')]),
            progress: progress,
          ),
        ],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(await store.workCounts('draft'), {'pending': 1});
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      // Waiting, not finished and not failed: nothing about this message went
      // wrong, and the stage must not read terminal.
      expect((await progressOf('m2'))['draft_state'], 'pending');
    });

    test('and one that goes down during the DRAFT does the same', () async {
      await seedInbound();
      await store.enqueueWork('draft', 'email', 'm2');
      final worker = AiWorker(
        store,
        handlers: [
          DraftHandler(
            store,
            FakeLlm([
              decision(),
              const LlmUnavailableException('not reachable'),
            ]),
            progress: progress,
          ),
        ],
        progress: progress,
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(await store.workCounts('draft'), {'pending': 1});
      expect(await store.getDraftForMessage('email', 'm2'), isNull);
      expect((await progressOf('m2'))['draft_state'], 'pending');
    });
  });
}
