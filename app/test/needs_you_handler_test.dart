import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart' show TriageResult;
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart'
    show needsYouYesReason;
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart';
import 'package:bond_inbox/services/extract_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart'
    show DecisionMisconfiguredException, DecisionUnavailableException;
import 'package:bond_inbox/services/needs_you_handler.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// One answer for one task, with a hook that runs at the moment of the call —
/// which is how the drain-order test below observes the mailbox as extraction
/// found it. The needs-you handler takes no language model at all, so the
/// only calls this ever sees are extraction's.
ScriptedLlm scriptedLlm(
  Object answer, {
  required String schemaName,
  FutureOr<void> Function()? onCall,
}) =>
    ScriptedLlm(
      answers: {schemaName: answer},
      onCall: onCall == null ? null : (_) => onCall(),
    );

/// An [EmbeddingsClient] over a scripted socket, so extraction can finish
/// without a server.
EmbeddingsClient fakeEmbeddings() => EmbeddingsClient(
      baseUrl: 'http://localhost:8081/v1/embeddings',
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [0.6, 0.8]
              }
            ]
          }),
          200,
        );
      }),
    );

/// The message-text stage's answer (the handler behind the `extract` kind).
const Map<String, dynamic> messageText = {
  'summary': 'Dana wants the DPA looked at.',
  'action_items': ['Review the DPA'],
  'deadline': '',
  'topics': ['DPA'],
  'project': 'Acme renewal',
};

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seed({
    String source = 'email',
    String id = 'm1',
    String direction = 'inbound',
    int addressedMe = 1,
    String triageStatus = 'triaged',
    String? gateReason,
    String body = 'Alex, can you sign off on the wayfinding sheet?',
    String receivedAt = '2026-08-29T10:00:00Z',
    int hasAttachments = 0,
    String fromAddress = 'dana@northwind.example.com',
  }) async {
    await store.upsertMessage({
      'has_attachments': hasAttachments,
      'source': source,
      'source_message_id': id,
      'conversation_key': 'chat-1',
      'direction': direction,
      'from_name': 'Dana',
      'from_address': fromAddress,
      'to_json': '["lo@x.com"]',
      'received_at': receivedAt,
      'body_text': body,
      'addressed_me': addressedMe,
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
  }

  /// A stored decision, as the triage pass writes it.
  Future<void> decide(
    double needsYou, {
    String source = 'email',
    String id = 'm1',
    bool ownerKnown = true,
    String intent = 'question',
  }) =>
      store.writeDecision(
        source,
        id,
        fakeDecision(fakeAnswers(needsYou: needsYou, intent: intent)),
        qhash: decisionQhash,
        ownerKnown: ownerKnown,
      );

  /// The probability as triage writes it onto the row.
  Future<void> writeP(double? p, {String source = 'email', String id = 'm1'}) =>
      store.writeNeedsYouP(source, id, p: p, reason: 'Asks you a question.');

  NeedsYouHandler handler({
    FakeDecisionClient? decision,
    Future<({String? name, String? address})?> Function()? owner,
    PipelineProgress progress = const PipelineProgress.disabled(),
  }) =>
      NeedsYouHandler(
        store,
        decisionClient: decision ?? FakeDecisionClient.never(),
        owner: owner,
        progress: progress,
      );

  Future<void> runOne(
    NeedsYouHandler handler, {
    String source = 'email',
    String id = 'm1',
  }) =>
      handler.run({
        'task_kind': 'needs_you',
        'source': source,
        'entity_id': id,
      });

  Future<Map<String, Object?>> answerOf(
    String source,
    String id,
  ) async {
    final row = (await store.getMessageRow(source, id))!;
    return {'p': row['needs_you_p'], 'reason': row['needs_you_reason']};
  }

  Future<bool> ownerKnownOf(String source, String id) async =>
      (await store.decisionFor(source, id))!.ownerKnown;

  group('guards', () {
    test('a message gated after the enqueue is left undecided', () async {
      await seed(triageStatus: 'skipped', gateReason: 'newsletter');

      await runOne(handler());

      expect((await answerOf('email', 'm1'))['p'], isNull);
    });

    test('a chat skipped-by-birth is still decided', () async {
      await seed(
        source: 'teams',
        id: 't1',
        triageStatus: 'skipped',
        gateReason: 'teams_source',
      );
      final decision = FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.7));

      await runOne(handler(decision: decision),
          source: 'teams', id: 't1');

      expect(decision.calls, hasLength(1));
      expect((await answerOf('teams', 't1'))['p'], closeTo(0.7, 1e-9));
    });

    test('the owner writing in their own chat is left undecided', () async {
      await seed(direction: 'outbound');

      await runOne(handler());

      expect((await answerOf('email', 'm1'))['p'], isNull);
    });

    test('a message deleted before the worker reached it completes', () async {
      await runOne(handler(), id: 'gone');
    });
  });

  group('a trusted decision', () {
    for (final p in const [0.05, 0.3, 0.5, 0.65, 0.95]) {
      test('a message decided with the owner known at p=$p is left as it is',
          () async {
        // No band: whatever the probability, the slider reads it as it stands.
        await seed();
        await decide(p);
        await writeP(p);
        final decision = FakeDecisionClient.never();

        await runOne(handler(decision: decision));

        expect(decision.calls, isEmpty);
        expect(await answerOf('email', 'm1'),
            {'p': p, 'reason': 'Asks you a question.'});
      });
    }

    test('a Teams direct chat gets no floor: its probability is its answer',
        () async {
      await seed(source: 'teams', id: 't1', fromAddress: 'teams:u-1');
      await decide(0.1, source: 'teams', id: 't1');
      await writeP(0.1, source: 'teams', id: 't1');

      await runOne(handler(), source: 'teams', id: 't1');

      expect((await answerOf('teams', 't1'))['p'], 0.1);
    });

    test("a row that lost the decision's p gets it back, with the template",
        () async {
      // A row an older build wrote 1.0 on: the trusted decision is what the
      // row reads again, and no model is asked.
      await seed();
      await decide(0.42, intent: 'approval');
      await writeP(1.0);

      await runOne(handler());

      final answer = await answerOf('email', 'm1');
      expect(answer['p'], closeTo(0.42, 1e-9));
      expect(answer['reason'], 'Asks you to approve something.');
    });

    test('an attachment digest with an ask sends nothing to a model', () async {
      // The digest's asks stay on the file card; the probability is the
      // decision model's.
      await seed(body: 'See attached.', hasAttachments: 1);
      await store.upsertAttachments('email', 'm1', [
        {'attachment_id': 'a1', 'ordinal': 0, 'kind': 'file', 'name': 'A.pdf'},
      ]);
      await store.setAttachmentDigest(
        'email',
        'm1',
        'a1',
        status: 'done',
        digestJson: jsonEncode(const AttachmentDigest(
          summary: 'A lease addendum.',
          asks: ['Sign and return by Thursday'],
        ).toJson()),
      );
      await decide(0.2);
      await writeP(0.2);

      await runOne(handler());

      expect((await answerOf('email', 'm1'))['p'], 0.2);
    });

    test('a needs-you text an older build saved is never read', () async {
      // The slider is the one control; the stored text is inert.
      await seed();
      await decide(0.5);
      await writeP(0.5);
      await store.setPref(needsYouRulesKey, 'Invoices always need me.');
      final decision = FakeDecisionClient.never();

      await runOne(handler(decision: decision));

      expect(decision.calls, isEmpty);
      expect((await answerOf('email', 'm1'))['p'], 0.5);
    });
  });

  group("the owner's Needs You answer", () {
    // `applyDecision` stores the owner's answer in the decision row; the
    // copy step copies that COLUMN, so it can never write the model's p back.
    Future<void> decideOverridden({String answer = 'no', bool exact = false}) =>
        store.writeDecision(
          'email',
          'm1',
          fakeDecision(fakeAnswers(needsYou: 0.9, intent: 'request')
              .withNeedsYou(answer, exact: exact)),
          qhash: decisionQhash,
          ownerKnown: true,
          extraKeys: {
            'owner_answer': answer,
            'owner_label_id': 7,
            'owner_cosine': exact ? 1.0 : 0.99,
            'owner_exact': exact,
          },
        );

    test('the copy step keeps an overridden 0.0 and words it', () async {
      await seed();
      await decideOverridden();
      await writeP(0.9);
      final decision = FakeDecisionClient.never();

      await runOne(handler(decision: decision));

      expect(decision.calls, isEmpty);
      expect(await answerOf('email', 'm1'), {
        'p': 0.0,
        'reason': 'You removed a message like this from Needs You.',
      });
    });

    test('an exact addition copies as 1.0 with its own sentence', () async {
      await seed();
      await decideOverridden(answer: 'yes', exact: true);
      await writeP(null);

      await runOne(handler());

      expect(await answerOf('email', 'm1'), {
        'p': 1.0,
        'reason': 'You added this message to Needs You.',
      });
    });

    test('a re-decide applies the label through the handler', () async {
      await seed();
      final exemplars = NeedsYouExemplars(store);
      await store.writeNeedsYouLabel(
        source: 'email',
        conversationKey: 'chat-1',
        sourceMessageId: 'm1',
        answer: 'no',
        origin: 'remove',
      );

      await runOne(NeedsYouHandler(
        store,
        decisionClient:
            FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.9)),
        exemplars: exemplars,
      ));

      expect(await answerOf('email', 'm1'), {
        'p': 0.0,
        'reason': 'You removed this message from Needs You.',
      });
    });
  });

  group('deciding again', () {
    test('a message with no decision is decided by the decision model',
        () async {
      await seed();
      final decision = FakeDecisionClient.fixed(
        fakeAnswers(needsYou: 0.8, intent: 'request'),
      );

      await runOne(handler(
        decision: decision,
        owner: () async =>
            (name: 'Alex Rivera', address: 'alex.rivera@rivermail.example.com'),
      ));

      expect(decision.calls, hasLength(1));
      expect(decision.calls.single.owner,
          'Alex Rivera <alex.rivera@rivermail.example.com>');
      expect(await answerOf('email', 'm1'),
          {'p': closeTo(0.8, 1e-9), 'reason': 'Asks you to do something.'});
      // And the decision is stored, as the triage pass would have stored it.
      final stored = await store.decisionFor('email', 'm1');
      expect(stored!.needsYouP, closeTo(0.8, 1e-9));
      expect(stored.ownerKnown, isTrue);
    });

    test('a decision stored under another question set is undecided, and is '
        'decided again', () async {
      // The first decision model's row (qhash 6eba…): it answered other
      // questions, so decisionFor reads it as no decision at all.
      await seed();
      await store.writeDecision(
        'email',
        'm1',
        fakeDecision(fakeAnswers(needsYou: 0.1)),
        qhash: '6eba387492208260',
        ownerKnown: true,
      );
      await writeP(0.1);
      expect(await store.decisionFor('email', 'm1'), isNull);
      final decision = FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.7));

      await runOne(handler(
        decision: decision,
        owner: () async =>
            (name: 'Alex Rivera', address: 'alex.rivera@rivermail.example.com'),
      ));

      expect(decision.calls, hasLength(1));
      expect((await answerOf('email', 'm1'))['p'], closeTo(0.7, 1e-9));
      final stored = await store.decisionFor('email', 'm1');
      expect(stored!.needsYouP, closeTo(0.7, 1e-9));
    });

    test('a re-decide writes the whole state, exactly as the install-time '
        're-decide writes it', () async {
      // Two identical triaged messages in two threads, each with its text,
      // an extraction and a thread whose CTA the old decision folded.
      final moved = fakeAnswers(
        urgency: 'high',
        category: 'personal',
        needsAction: 0.8,
        replyExpected: 0.7,
        needsYou: 0.66,
        intent: 'request',
        importance: 'high',
      );
      for (final id in ['m1', 'm2']) {
        await store.upsertMessage({
          'source': 'email',
          'source_message_id': id,
          'conversation_key': 'conv-$id',
          'direction': 'inbound',
          'from_name': 'Dana',
          'from_address': 'dana@northwind.example.com',
          'to_json': '["lo@x.com"]',
          'received_at': '2026-08-29T10:00:00Z',
          'body_text': 'Alex, can you sign off on the wayfinding sheet?',
          'addressed_me': 1,
          'triage_status': 'triaged',
        });
        await store.upsertConversation({
          'source': 'email',
          'conversation_key': 'conv-$id',
          'subject': 'Wayfinding',
          'state': 'needs_reply',
          'last_message_at': '2026-08-29T10:00:00Z',
          'last_inbound_at': '2026-08-29T10:00:00Z',
        });
        await store.updateConversationTriage(
          'email',
          'conv-$id',
          ctaUrgency: 'low',
          category: 'work',
          keepCtaText: true,
        );
        await store.writeTriage(
          'email',
          id,
          status: 'triaged',
          result: const TriageResult(
            urgency: 'low',
            category: 'work',
            needsAction: false,
            replyExpected: false,
          ),
        );
        await store.writeMessageText(
          'email',
          id,
          summary: 'Dana asks for a sign-off.',
          actionItems: const ['Sign off'],
          deadline: '',
        );
        await store.writeExtraction(
          'email',
          id,
          jsonEncode({
            'topics': ['wayfinding'],
            'project': 'Signage',
            'intent': 'fyi',
            'importance': 'low',
          }),
        );
      }

      // m1 through this handler (no decision stored), m2 through the
      // install-time re-decide.
      await runOne(handler(decision: FakeDecisionClient.fixed(moved)));
      await TriageQueue(store, decisionClient: FakeDecisionClient.fixed(moved))
          .redecide([(source: 'email', id: 'm2')]);

      Future<Map<String, Object?>> stateOf(String id) async {
        final row = (await store.getMessageRow('email', id))!;
        final conversation =
            (await store.getConversationRow('email', 'conv-$id'))!;
        final extraction =
            jsonDecode((await store.getExtraction('email', id))!) as Map;
        return {
          for (final k in [
            'urgency',
            'category',
            'needs_action',
            'reply_expected',
            'needs_you_p',
            'needs_you_reason',
            'triage_status',
          ])
            k: row[k],
          'intent': extraction['intent'],
          'importance': extraction['importance'],
          'topics': extraction['topics'],
          'cta_urgency': conversation['cta_urgency'],
          'thread_category': conversation['category'],
        };
      }

      final viaHandler = await stateOf('m1');
      expect(viaHandler, {
        'urgency': 'high',
        'category': 'personal',
        'needs_action': 1,
        'reply_expected': 1,
        'needs_you_p': closeTo(0.66, 1e-9),
        'needs_you_reason': 'Asks you to do something.',
        'triage_status': 'triaged',
        'intent': 'request',
        'importance': 'high',
        'topics': ['wayfinding'],
        'cta_urgency': 'high',
        'thread_category': 'personal',
      });
      expect(viaHandler, await stateOf('m2'));
    });

    test('the input carries the thread before the message, as triage builds it',
        () async {
      await seed(
        id: 'earlier',
        body: 'Alex, the wayfinding sheet is ready for you.',
        receivedAt: '2026-08-29T09:00:00Z',
      );
      await seed(
        id: 'later',
        body: 'Following up on this.',
        receivedAt: '2026-08-29T11:00:00Z',
      );
      await seed();
      final decision = FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.6));

      await runOne(handler(decision: decision));

      final input = decision.calls.single;
      expect(input.tail, hasLength(1));
      expect(input.tail.single.text,
          contains('the wayfinding sheet is ready for you'));
    });

    test('an ownerless decision is decided again once the owner is known',
        () async {
      await seed();
      await decide(0.9, ownerKnown: false);
      final decision = FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.2));

      await runOne(handler(
        decision: decision,
        owner: () async => (name: 'Alex Rivera', address: null),
      ));

      expect(decision.calls.single.owner, 'Alex Rivera');
      expect((await answerOf('email', 'm1'))['p'], closeTo(0.2, 1e-9));
      expect(await ownerKnownOf('email', 'm1'), isTrue);
    });

    test('an ownerless decision is kept, not re-decided, while the owner is '
        'still unknown', () async {
      // Without this a pass run before the keychain answers would decide the
      // same message again on every requeue.
      await seed();
      await decide(0.6, ownerKnown: false);
      await writeP(0.6);
      final decision = FakeDecisionClient.never();

      await runOne(handler(decision: decision));

      expect(decision.calls, isEmpty);
      expect((await answerOf('email', 'm1'))['p'], 0.6);
      expect(await ownerKnownOf('email', 'm1'), isFalse);
    });

    test('an ownerless decision the row lost is copied back while the owner '
        'is unknown', () async {
      await seed();
      await decide(0.6, ownerKnown: false, intent: 'approval');
      final decision = FakeDecisionClient.never();

      await runOne(handler(decision: decision));

      expect(decision.calls, isEmpty);
      expect(await answerOf('email', 'm1'),
          {'p': closeTo(0.6, 1e-9), 'reason': 'Asks you to approve something.'});
    });

    test('an owner still unknown is decided ownerless, and written anyway',
        () async {
      // An undecided row is a message nobody sees; an ownerless probability
      // is better than that, and the next requeue decides it again.
      await seed();
      final decision = FakeDecisionClient.fixed(
        fakeAnswers(needsYou: 0.7, intent: 'question'),
      );

      await runOne(handler(decision: decision));

      expect(decision.calls.single.owner, isNull);
      expect(await answerOf('email', 'm1'),
          {'p': closeTo(0.7, 1e-9), 'reason': 'Asks you a question.'});
      expect(await ownerKnownOf('email', 'm1'), isFalse);
    });

    test('a decision server that is down propagates, and nothing falls back',
        () async {
      await seed();
      final decision = FakeDecisionClient(
        (_) => throw const DecisionUnavailableException('decide is down'),
      );

      await expectLater(
        runOne(handler(decision: decision)),
        throwsA(isA<DecisionUnavailableException>()),
      );
      expect((await answerOf('email', 'm1'))['p'], isNull);
      expect(await store.decisionFor('email', 'm1'), isNull);
    });

    test('a refused heads file propagates the same way', () async {
      await seed();
      final decision = FakeDecisionClient(
        (_) => throw const DecisionMisconfiguredException('heads refused'),
      );

      await expectLater(
        runOne(handler(decision: decision)),
        throwsA(isA<DecisionMisconfiguredException>()),
      );
      expect((await answerOf('email', 'm1'))['p'], isNull);
    });

    test('the template reason is the one triage writes', () async {
      await seed();
      final answers = fakeAnswers(needsYou: 0.4, intent: 'scheduling');

      await runOne(handler(
        decision: FakeDecisionClient.fixed(answers),
      ));

      expect((await answerOf('email', 'm1'))['reason'],
          needsYouYesReason(answers));
    });
  });

  // The Needs You chip on the home screen is a snapshot taken at settle time,
  // and nothing else in the app would reconcile it with an answer written
  // afterwards.
  group('the chip that follows the answer', () {
    late ProgressBus bus;
    late PipelineProgress progress;
    late List<ProgressTick> ticks;

    setUp(() {
      bus = ProgressBus();
      progress = PipelineProgress(store, bus: bus);
      ticks = [];
      bus.ticks.listen(ticks.add);
    });

    tearDown(() => bus.dispose());

    /// A message the coordinator already settled as needing nobody, on a
    /// thread the user has not answered — the shape a new answer has to move.
    /// `reply_expected` is set so the chip's own reader agrees that an ask is
    /// there whichever signal it reads.
    Future<void> seedSettled({String? lastOutboundAt}) async {
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'chat-1',
        'subject': 'The DPA',
        'state': 'needs_reply',
        'last_message_at': '2026-08-29T10:00:00Z',
        'last_outbound_at': lastOutboundAt,
      });
      await seed();
      await db.customUpdate(
        "UPDATE messages SET reply_expected = 1 WHERE source_message_id = 'm1'",
      );
      await progress.noteSettled(
        'email',
        'm1',
        needsYou: false,
        reason: 'not_worthy',
        dropped: false,
      );
      await store.writeAttentionScore('email', 'chat-1', 0.9);
    }

    Future<Object?> flagOf(String id) async => (await db
            .customSelect(
              'SELECT needs_you FROM message_progress '
              'WHERE source = ? AND source_message_id = ?',
              variables: [Variable('email'), Variable(id)],
            )
            .getSingle())
        .data['needs_you'];

    test('an answer that crosses the slider raises the chip and says so',
        () async {
      await seedSettled();
      ticks.clear();

      await runOne(handler(
        decision: FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.9)),
        progress: progress,
      ));

      expect(await flagOf('m1'), 1);
      await pumpEventQueue();
      expect(ticks.single.sourceMessageId, 'm1');
      expect(ticks.single.stage, 'settle');
    });

    test('an answer below the slider moves nothing', () async {
      await seedSettled();
      ticks.clear();

      await runOne(handler(
        decision: FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.1)),
        progress: progress,
      ));

      await pumpEventQueue();
      expect(ticks, isEmpty);
      expect(await flagOf('m1'), 0);
    });

    test('the same answer twice writes nothing the second time', () async {
      await seedSettled();
      await runOne(handler(
        decision: FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.9)),
        progress: progress,
      ));
      await pumpEventQueue();
      ticks.clear();

      // Decided now, with the owner unknown; deciding again lands on the same
      // side of the slider.
      await runOne(handler(
        decision: FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.85)),
        progress: progress,
      ));

      await pumpEventQueue();
      expect(ticks, isEmpty);
      expect(await flagOf('m1'), 1);
    });

    test('a thread the user already answered is not re-chipped', () async {
      await seedSettled(lastOutboundAt: '2026-08-29T12:00:00Z');

      await runOne(handler(
        decision: FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.9)),
        progress: progress,
      ));

      expect((await answerOf('email', 'm1'))['p'], closeTo(0.9, 1e-9));
      expect(await flagOf('m1'), 0);
    });

    test('and a handler with no recorder decides exactly as before', () async {
      await seedSettled();

      await runOne(handler(
        decision: FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.9)),
      ));

      expect((await answerOf('email', 'm1'))['p'], closeTo(0.9, 1e-9));
      expect(await flagOf('m1'), 0);
    });
  });

  group('drain order', () {
    test('the probability is on the row before extraction reads it', () async {
      // Triaged, and it has to be: the worker is not handed a `needs_you` or
      // an `extract` item while its message is still `pending`
      // (`MessageStore.claimPendingWork`).
      await seed();
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'chat-1',
        'subject': 'Acme renewal',
        'state': 'needs_reply',
        'last_message_at': '2026-08-29T10:00:00Z',
      });
      await store.enqueueWork('extract', 'email', 'm1');
      await store.enqueueWork('needs_you', 'email', 'm1');

      Object? pWhenExtractRan;
      final llm = scriptedLlm(
        messageText,
        schemaName: 'message_text',
        onCall: () async {
          pWhenExtractRan =
              (await store.getMessageRow('email', 'm1'))!['needs_you_p'];
        },
      );
      // Provider order: needs-you, then extraction. The row has no decision,
      // so the needs-you pass decides it, and the one language-model call this
      // drain makes is extraction's.
      final worker = AiWorker(
        store,
        handlers: [
          NeedsYouHandler(
            store,
            decisionClient:
                FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.75)),
          ),
          ExtractHandler(store, llm, fakeEmbeddings()),
        ],
      );
      addTearDown(worker.dispose);

      await worker.pump();

      expect(llm.calls.length, 1, reason: 'extraction really ran');
      expect(pWhenExtractRan, closeTo(0.75, 1e-9));
      expect(await store.workCounts('needs_you', sources: const ['email']),
          {'done': 1});
      expect(await store.workCounts('extract', sources: const ['email']),
          {'done': 1});
    });
  });

  test('the qhash stored on a re-decision is the heads file the app expects',
      () async {
    await seed();

    await runOne(handler(
      decision: FakeDecisionClient.fixed(fakeAnswers(needsYou: 0.5)),
    ));

    final row = (await db
            .customSelect("SELECT qhash FROM message_decisions "
                "WHERE source_message_id = 'm1'")
            .getSingle())
        .data;
    expect(row['qhash'], decisionQhash);
  });
}
