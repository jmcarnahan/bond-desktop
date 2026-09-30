import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/services/llm/llm_client.dart'
    show DecisionUnavailableException;
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/storyline_state.dart';
import 'package:bond_inbox/services/storyline_judge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The storyline questions asked of the decision model: the state each one
/// renders, the one batch per call, the body fetch before a preview is
/// judged, and the park when the decision server is down.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late FakeDecisionClient decision;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    decision = FakeDecisionClient.storyline();
  });

  tearDown(() async => db.close());

  Future<void> thread(
    String key, {
    String source = 'email',
    String subject = 'Lisbon offsite',
    String? body = 'Here are the three venues.',
    String? preview,
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'participants_json': jsonEncode(const []),
    });
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'to_json': jsonEncode(const []),
      'received_at': '2026-09-01T09:00:00Z',
      'body_text': body,
      'body_preview': preview,
      'triage_status': 'triaged',
    });
  }

  const offsite = Storyline(
    id: 'sl-1',
    title: 'Lisbon offsite',
    summary: 'Venues are being compared.',
    charter: 'Planning the Lisbon team offsite in October.',
    status: 'active',
    createdBy: 'user',
  );

  group('memberOf', () {
    test('renders the charter over each thread and asks in ONE batch',
        () async {
      await thread('c1');
      await thread('c2', subject: 'Quarterly invoices', body: 'Invoice 42.');
      decision.yes(StorylineQuestion.memberOf, 'Invoice 42', 0.1);
      decision.yes(StorylineQuestion.memberOf, 'three venues', 0.9);
      final judge = StorylineJudge(decision: decision, store: store);

      final p = await judge.memberOf(offsite, [
        (source: 'email', key: 'c1'),
        (source: 'email', key: 'c2'),
      ]);

      expect(p, [0.9, 0.1]);
      expect(decision.asks, hasLength(1));
      expect(decision.asks.single.question, StorylineQuestion.memberOf);
      expect(
        decision.asks.single.states.first,
        renderStorylineMembership(
          title: 'Lisbon offsite',
          charter: 'Planning the Lisbon team offsite in October.',
          threadText: 'Subject: Lisbon offsite\n'
              'People: Dana Whitfield\n'
              'Newest messages, oldest first:\n'
              'Dana Whitfield: Here are the three venues.',
        ),
      );
    });

    test('a storyline with no charter renders (none), never its summary',
        () async {
      await thread('c1');
      final judge = StorylineJudge(decision: decision, store: store);

      await judge.memberOf(
        const Storyline(
          id: 'sl-2',
          title: 'Lisbon offsite',
          summary: 'Venues are being compared.',
          charter: '  ',
          status: 'suggested',
          createdBy: 'auto',
        ),
        [(source: 'email', key: 'c1')],
      );

      final state = decision.asks.single.states.single;
      expect(state, contains('Charter: (none)'));
      expect(state, isNot(contains('Venues are being compared.')));
    });

    test('with neither, the renderer says (none)', () async {
      await thread('c1');
      final judge = StorylineJudge(decision: decision, store: store);

      await judge.memberOf(
        const Storyline(
          id: 'sl-3',
          title: 'Lisbon offsite',
          status: 'suggested',
          createdBy: 'auto',
        ),
        [(source: 'email', key: 'c1')],
      );

      expect(decision.asks.single.states.single, contains('Charter: (none)'));
    });

    test('no threads asks nothing', () async {
      final judge = StorylineJudge(decision: decision, store: store);
      expect(await judge.memberOf(offsite, const []), isEmpty);
      expect(decision.asks, isEmpty);
    });

    test('a decision failure PROPAGATES, so the lane parks', () async {
      await thread('c1');
      decision.askError =
          const DecisionUnavailableException('The decision server is down.');
      final judge = StorylineJudge(decision: decision, store: store);

      expect(
        judge.memberOf(offsite, [(source: 'email', key: 'c1')]),
        throwsA(isA<DecisionUnavailableException>()),
      );
    });
  });

  group('the body fetch', () {
    /// What a successful fetch writes: the message's own body.
    Future<void> landBody(String key, String body) => store.upsertMessage({
          'source': 'email',
          'source_message_id': '$key-m1',
          'conversation_key': key,
          'direction': 'inbound',
          'subject': 'Lisbon offsite',
          'from_name': 'Dana Whitfield',
          'from_address': 'dana@example.com',
          'to_json': jsonEncode(const []),
          'received_at': '2026-09-01T09:00:00Z',
          'body_text': body,
          'triage_status': 'triaged',
        });

    test('fetches only the rows still showing their preview, and rebuilds',
        () async {
      await thread('c1', body: null, preview: 'Preview of the whole chain');
      final fetched = <String>[];
      final judge = StorylineJudge(
        decision: decision,
        store: store,
        ensureBodies: (source, key, ids) async {
          fetched.add('$source/$key ${ids.join(',')}');
          await landBody(key, 'The fetched body.');
        },
      );

      await judge.memberOf(offsite, [(source: 'email', key: 'c1')]);

      expect(fetched, ['email/c1 c1-m1']);
      expect(decision.asks.single.states.single, contains('The fetched body.'));
      expect(decision.asks.single.states.single,
          isNot(contains('Preview of the whole chain')));
    });

    test('a thread with its bodies is never fetched', () async {
      await thread('c1');
      var fetches = 0;
      final judge = StorylineJudge(
        decision: decision,
        store: store,
        ensureBodies: (_, _, _) async => fetches++,
      );

      await judge.memberOf(offsite, [(source: 'email', key: 'c1')]);

      expect(fetches, 0);
    });

    test('a failed fetch is judged on the preview and not asked again soon',
        () async {
      await thread('c1', body: null, preview: 'Preview of the whole chain');
      var now = DateTime(2026, 9, 29, 12);
      var fetches = 0;
      final judge = StorylineJudge(
        decision: decision,
        store: store,
        now: () => now,
        ensureBodies: (_, _, _) async {
          fetches++;
          throw StateError('mail is down');
        },
      );

      await judge.memberOf(offsite, [(source: 'email', key: 'c1')]);
      // The next candidate of the same pass: no second round trip.
      await judge.memberOf(offsite, [(source: 'email', key: 'c1')]);

      expect(fetches, 1);
      expect(decision.asks.first.states.single,
          contains('Preview of the whole chain'));

      now = now.add(StorylineJudge.fetchRetryAfter);
      await judge.memberOf(offsite, [(source: 'email', key: 'c1')]);
      expect(fetches, 2, reason: 'asked again once the window is over');
    });

    test('a fetch that throws partway still rebuilds with what landed',
        () async {
      await thread('c1', body: null, preview: 'Preview of the whole chain');
      final judge = StorylineJudge(
        decision: decision,
        store: store,
        ensureBodies: (_, key, _) async {
          await landBody(key, 'The fetched body.');
          throw StateError('the second message failed');
        },
      );

      await judge.memberOf(offsite, [(source: 'email', key: 'c1')]);

      expect(decision.asks.single.states.single, contains('The fetched body.'));
    });
  });

  test('memberOfEach builds one text and asks one state per storyline',
      () async {
    await thread('c1', body: null, preview: 'Preview of the whole chain');
    var fetches = 0;
    decision.yes(StorylineQuestion.memberOf, 'Storyline title: Budget', 0.2);
    decision.yes(StorylineQuestion.memberOf, 'Storyline title: Lisbon', 0.9);
    final judge = StorylineJudge(
      decision: decision,
      store: store,
      ensureBodies: (_, _, _) async => fetches++,
    );

    final p = await judge.memberOfEach(
      [
        offsite,
        const Storyline(id: 'sl-b', title: 'Budget review', status: 'active'),
      ],
      (source: 'email', key: 'c1'),
    );

    expect(p, [0.9, 0.2]);
    expect(fetches, 1);
    expect(decision.asks, hasLength(1));
    expect(decision.asks.single.states, hasLength(2));
  });

  test('ensureReady throws the park and asks nothing', () async {
    final judge = StorylineJudge(decision: decision, store: store);
    await judge.ensureReady();
    expect(decision.readyChecks, 1);

    decision.askError =
        const DecisionUnavailableException('The decision server is down.');
    await expectLater(
        judge.ensureReady(), throwsA(isA<DecisionUnavailableException>()));
    expect(decision.asks, isEmpty);
  });

  test('charterSpecific asks the charter question over title and charter',
      () async {
    decision.yes(StorylineQuestion.charterSpecific, 'Lisbon', 0.8);
    final judge = StorylineJudge(decision: decision, store: store);

    final p = await judge.charterSpecific(
      'Lisbon offsite',
      'Planning the Lisbon team offsite in October.',
    );

    expect(p, 0.8);
    expect(decision.asks.single.question, StorylineQuestion.charterSpecific);
    expect(
      decision.asks.single.states.single,
      renderStorylineCharter(
        title: 'Lisbon offsite',
        charter: 'Planning the Lisbon team offsite in October.',
      ),
    );
  });

  test('sameEffort asks both orders of each pair and averages them', () async {
    await thread('c1');
    await thread('c2', subject: 'Venue deposit', body: 'Deposit is due.');
    await thread('c3', subject: 'Quarterly invoices', body: 'Invoice 42.');
    // The first match wins: A-then-B reads the venues first, B-then-A reads
    // the deposit first, so the two orders answer differently.
    decision.yes(StorylineQuestion.sameEffort,
        'Thread A:\nSubject: Lisbon offsite', 0.9);
    decision.yes(StorylineQuestion.sameEffort,
        'Thread A:\nSubject: Venue deposit', 0.7);
    decision.yes(StorylineQuestion.sameEffort, 'Invoice 42', 0.1);
    final judge = StorylineJudge(decision: decision, store: store);

    final p = await judge.sameEffort([
      ((source: 'email', key: 'c1'), (source: 'email', key: 'c2')),
      ((source: 'email', key: 'c2'), (source: 'email', key: 'c3')),
    ]);

    expect(p[0], closeTo(0.8, 1e-9));
    expect(p[1], closeTo(0.4, 1e-9));
    // One batch, both orders of both pairs.
    expect(decision.asks, hasLength(1));
    expect(decision.asks.single.states, hasLength(4));
  });

  group('MembershipAnswer', () {
    test('the evidence is a templated sentence carrying the percentage', () {
      expect(
        MembershipAnswer.of(0.824).evidence,
        'The decision model put this thread at 82% for this storyline.',
      );
    });
  });

  group('StorylinePolicy', () {
    test('the numbers fitted on the golden set', () {
      expect(StorylinePolicy.acceptActive, 0.50);
      expect(StorylinePolicy.acceptSuggested, 0.74);
      expect(StorylinePolicy.assignRetrievalFloor, 0.30);
      expect(StorylinePolicy.assignTopK, 3);
      // A storyline nobody kept is held to the higher bar.
      expect(StorylinePolicy.acceptSuggested,
          greaterThan(StorylinePolicy.acceptActive));
    });
  });
}
