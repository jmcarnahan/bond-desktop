import 'dart:async';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart';
import 'package:bond_inbox/services/llm/llm_client.dart'
    show DecisionUnavailableException, LlmFormatException;
import 'package:bond_inbox/services/needs_you_edits.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The owner's presses: a label per message with its vector, a re-decide
/// through `applyDecision`, and the sweep of the Needs You list a removal
/// starts.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late NeedsYouExemplars exemplars;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    exemplars = NeedsYouExemplars(store);
  });

  tearDown(() async => db.close());

  /// Four-wide stand-ins for the encoder's vector, keyed by a word in the
  /// body: two templated receipts at cosine 0.99, an unrelated ask at 0.3.
  const vectors = {
    'receipt-one': [1.0, 0.0, 0.0, 0.0],
    'receipt-two': [1.0, 0.1425, 0.0, 0.0],
    'budget': [0.3, 0.9539, 0.0, 0.0],
  };

  List<double> vectorOf(DecisionInput input) {
    final body = input.bodyText ?? '';
    for (final MapEntry(:key, :value) in vectors.entries) {
      if (body.contains(key)) return value;
    }
    return const [0.0, 0.0, 1.0, 0.0];
  }

  /// The model calls every message an ask (0.9), with its vector.
  FakeDecisionClient model({double needsYou = 0.9}) => FakeDecisionClient(
        (input) => fakeDecision(
          fakeAnswers(needsYou: needsYou, intent: 'request'),
          vector: vectorOf(input),
        ),
      );

  Future<void> thread(
    String key, {
    String state = 'needs_reply',
    String lastMessageAt = '2026-09-30T10:00:00Z',
    String? lastOutboundAt,
  }) =>
      store.upsertConversation({
        'source': 'email',
        'conversation_key': key,
        'subject': key,
        'state': state,
        'last_message_at': lastMessageAt,
        'last_outbound_at': lastOutboundAt,
      });

  Future<void> message(
    String key,
    String id,
    String body, {
    String receivedAt = '2026-09-30T10:00:00Z',
    String direction = 'inbound',
    double? p = 0.9,
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'from_name': 'Portal',
      'from_address': 'portal@fabrikam.example.com',
      'to_json': '["lo@x.com"]',
      'received_at': receivedAt,
      'body_text': body,
      'triage_status': 'triaged',
    });
    if (p != null && direction == 'inbound') {
      await store.writeNeedsYouP('email', id, p: p, reason: 'Asks you.');
    }
  }

  Future<double?> pOf(String id) async =>
      ((await store.getMessageRow('email', id))!['needs_you_p'] as num?)
          ?.toDouble();

  NeedsYouEdits edits(
    FakeDecisionClient client, {
    void Function()? onSwept,
    double threshold = 0.35,
    bool Function()? enabled,
  }) =>
      NeedsYouEdits(
        store,
        client,
        exemplars,
        owner: () async => 'Lo <lo@x.com>',
        threshold: () async => threshold,
        onSwept: onSwept,
        enabled: enabled,
      );

  /// The thread's number as the rail reads it.
  Future<double?> threadP(String key) async =>
      (await store.loadConversations())
          .singleWhere((c) => c.id == key)
          .needsYouP;

  /// Three threads in Needs You — two templated receipts and one real ask —
  /// plus a receipt the owner marked Done and one sent to Later.
  Future<void> seedList() async {
    await thread('t-one', lastMessageAt: '2026-09-30T10:00:00Z');
    await message('t-one', 'a1', 'Access granted: receipt-one');
    await thread('t-two', lastMessageAt: '2026-09-30T09:00:00Z');
    await message('t-two', 'b1', 'Access granted: receipt-two');
    await thread('t-ask', lastMessageAt: '2026-09-30T08:00:00Z');
    await message('t-ask', 'c1', 'Can you approve the budget?');
    await thread('t-done', state: 'done');
    await message('t-done', 'd1', 'Access granted: receipt-two');
    await thread('t-later');
    await message('t-later', 'e1', 'Access granted: receipt-two');
    await store.setConversationBucket('email', 't-later', bucket: 'later');
  }

  group('remove', () {
    test('labels every window message with its vector and drops the thread',
        () async {
      await thread(
        't1',
        lastOutboundAt: '2026-09-30T09:00:00Z',
        lastMessageAt: '2026-09-30T11:00:00Z',
      );
      await message('t1', 'old', 'Before the reply: receipt-one',
          receivedAt: '2026-09-30T08:00:00Z', p: 0.2);
      await message('t1', 'mine', 'My reply',
          receivedAt: '2026-09-30T09:00:00Z', direction: 'outbound');
      await message('t1', 'w1', 'Access granted: receipt-one',
          receivedAt: '2026-09-30T10:00:00Z');
      await message('t1', 'w2', 'Access granted: receipt-two',
          receivedAt: '2026-09-30T11:00:00Z', p: 0.6);
      final swept = Completer<void>();

      await edits(model(), onSwept: swept.complete).remove('email', 't1');
      await swept.future;

      final labels = await store.needsYouLabels();
      expect(labels.map((l) => l.sourceMessageId), ['w1', 'w2']);
      expect(labels.every((l) => l.answer == 'no'), isTrue);
      expect(labels.every((l) => l.origin == 'remove'), isTrue);
      expect(labels.first.vector, vectors['receipt-one']);
      // float32 in the BLOB.
      expect(labels.last.vector![1], closeTo(0.1425, 1e-6));
      expect(labels.first.vectorModel, 'bond-decide-fake');
      expect(await pOf('w1'), 0.0);
      expect(await pOf('w2'), 0.0);
      // Outside the window: neither labelled nor decided.
      expect(await pOf('old'), closeTo(0.2, 1e-9));
      final conversations = await store.loadConversations();
      expect(
        conversations.singleWhere((c) => c.id == 't1').needsYouP,
        0.0,
      );
    });

    test('a decision error propagates and no sweep starts', () async {
      await thread('t1');
      await message('t1', 'w1', 'Access granted: receipt-one');
      var swept = 0;
      final failing = FakeDecisionClient(
        (_) => throw const DecisionUnavailableException('down'),
      );

      await expectLater(
        edits(failing, onSwept: () => swept++).remove('email', 't1'),
        throwsA(isA<DecisionUnavailableException>()),
      );

      expect(await store.needsYouLabels(), isEmpty);
      await pumpEventQueue();
      expect(swept, 0);
    });

    test('a decision error part-way writes nothing at all',
        () async {
      await thread('t1');
      await message('t1', 'w1', 'Access granted: receipt-one',
          receivedAt: '2026-09-30T09:00:00Z');
      await message('t1', 'w2', 'Access granted: receipt-two',
          receivedAt: '2026-09-30T10:00:00Z');
      var swept = 0;
      final client = FakeDecisionClient((input) {
        if ((input.bodyText ?? '').contains('receipt-two')) {
          throw const DecisionUnavailableException('down');
        }
        return fakeDecision(fakeAnswers(needsYou: 0.9),
            vector: vectorOf(input));
      });

      await expectLater(
        edits(client, onSwept: () => swept++).remove('email', 't1'),
        throwsA(isA<DecisionUnavailableException>()),
      );

      expect(await store.needsYouLabels(), isEmpty);
      expect(await pOf('w1'), closeTo(0.9, 1e-9));
      // Decided, but never written: no decision row cites anything.
      expect(await store.decisionFor('email', 'w1'), isNull);
      expect(await threadP('t1'), closeTo(0.9, 1e-9));
      await pumpEventQueue();
      expect(swept, 0);
    });

    test('processing off refuses the press and writes nothing', () async {
      await seedList();
      final client = model();

      await expectLater(
        edits(client, enabled: () => false).remove('email', 't-one'),
        throwsStateError,
      );

      expect(client.calls, isEmpty);
      expect(await store.needsYouLabels(), isEmpty);
      expect(await pOf('a1'), closeTo(0.9, 1e-9));
    });
  });

  group('add', () {
    test('labels the newest window message yes and raises it to 1.0',
        () async {
      await thread('t1');
      await message('t1', 'w1', 'First note',
          receivedAt: '2026-09-30T09:00:00Z', p: 0.1);
      await message('t1', 'w2', 'Second note',
          receivedAt: '2026-09-30T10:00:00Z', p: 0.1);
      var swept = 0;

      await edits(model(needsYou: 0.1), onSwept: () => swept++)
          .add('email', 't1');

      final labels = await store.needsYouLabels();
      expect(labels.single.sourceMessageId, 'w2');
      expect(labels.single.answer, 'yes');
      expect(labels.single.origin, 'add');
      expect(await pOf('w2'), 1.0);
      expect(await pOf('w1'), closeTo(0.1, 1e-9));
      expect(
        (await store.getMessageRow('email', 'w2'))!['needs_you_reason'],
        'You added this message to Needs You.',
      );
      await pumpEventQueue();
      expect(swept, 0, reason: 'an addition sweeps nothing');
    });

    test('processing off refuses the press and writes nothing', () async {
      await thread('t1');
      await message('t1', 'w1', 'First note', p: 0.1);
      final client = model(needsYou: 0.1);

      await expectLater(
        edits(client, enabled: () => false).add('email', 't1'),
        throwsStateError,
      );

      expect(client.calls, isEmpty);
      expect(await store.needsYouLabels(), isEmpty);
      expect(await pOf('w1'), closeTo(0.1, 1e-9));
    });

    test('a thread the owner wrote last has nothing to add', () async {
      await thread('t1', lastOutboundAt: '2026-09-30T11:00:00Z');
      await message('t1', 'w1', 'First note');
      final client = model();

      expect((await edits(client).add('email', 't1')).isEmpty, isTrue);

      expect(client.calls, isEmpty);
      expect(await store.needsYouLabels(), isEmpty);
    });
  });

  group('sweep', () {
    test('removes the near-duplicates of a removed thread and nothing else',
        () async {
      await seedList();
      final client = model();
      var swept = 0;
      final done = Completer<void>();

      await edits(client, onSwept: () {
        swept++;
        done.complete();
      }).remove('email', 't-one');
      await done.future;

      expect(await pOf('a1'), 0.0);
      expect(await pOf('b1'), 0.0);
      expect(
        (await store.getMessageRow('email', 'b1'))!['needs_you_reason'],
        'You removed a message like this from Needs You.',
      );
      expect(await pOf('c1'), closeTo(0.9, 1e-9));
      expect(swept, 1);
      // Done and Later are not in Needs You, so the sweep never reads them.
      expect(await store.decisionFor('email', 'd1'), isNull);
      expect(await store.decisionFor('email', 'e1'), isNull);
      expect(await pOf('d1'), closeTo(0.9, 1e-9));
      expect(await pOf('e1'), closeTo(0.9, 1e-9));
      // a1 at the press, then the two threads still listed: b1 and c1.
      expect(client.calls, hasLength(3));
    });

    test('returns how many threads left, re-deciding only the listed ones',
        () async {
      await seedList();
      await store.writeNeedsYouLabel(
        source: 'email',
        conversationKey: 't-one',
        sourceMessageId: 'a1',
        answer: 'no',
        origin: 'remove',
        vector: vectors['receipt-one'],
        vectorModel: 'bond-decide-fake',
      );
      final client = model();

      final changed = await edits(client).sweep();

      // t-one, t-two and t-ask were listed; the two receipts left.
      expect(changed, 2);
      expect(client.calls, hasLength(3));
      expect(await pOf('a1'), 0.0);
      expect(await pOf('b1'), 0.0);
      expect(await pOf('c1'), closeTo(0.9, 1e-9));
    });

    test('stops when the decision model is unavailable', () async {
      await seedList();
      var swept = 0;
      final client = FakeDecisionClient(
        (_) => throw const DecisionUnavailableException('down'),
      );

      final changed = await edits(client, onSwept: () => swept++).sweep();

      expect(changed, 0);
      expect(client.calls, hasLength(1));
      expect(swept, 1);
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
    });

    test('a per-message fault keeps that message\'s decision and moves on',
        () async {
      await seedList();
      // a1 already holds a current decision, as every listed message does.
      await store.writeDecision(
        'email',
        'a1',
        fakeDecision(fakeAnswers(needsYou: 0.9)),
        qhash: decisionQhash,
        ownerKnown: true,
      );
      final client = FakeDecisionClient((input) {
        if ((input.bodyText ?? '').contains('receipt-one')) {
          throw const LlmFormatException('bad request');
        }
        return fakeDecision(fakeAnswers(needsYou: 0.9),
            vector: vectorOf(input));
      });

      await edits(client).sweep();

      expect(client.calls, hasLength(3));
      // Not settled as failed: the current decision still reads.
      final kept = (await store.decisionFor('email', 'a1'))!;
      expect(kept.needsYouP, closeTo(0.9, 1e-9));
      expect(await store.decisionFor('email', 'b1'), isNotNull);
    });

    test('a listed thread of several near-duplicates leaves whole', () async {
      await seedList();
      // A second receipt in t-two, the newer and the higher: it would become
      // the driver if only the driver were decided again.
      await message('t-two', 'b2', 'Access granted again: receipt-two',
          receivedAt: '2026-09-30T10:30:00Z', p: 1.0);
      final done = Completer<void>();

      await edits(model(), onSwept: done.complete).remove('email', 't-one');
      await done.future;

      expect(await pOf('b1'), 0.0);
      expect(await pOf('b2'), 0.0);
      expect(await threadP('t-two'), 0.0);
      expect(await threadP('t-ask'), closeTo(0.9, 1e-9));
    });

    test('processing turned off stops the sweep between messages', () async {
      await seedList();
      var on = true;
      final client = FakeDecisionClient(
        (input) => fakeDecision(fakeAnswers(needsYou: 0.9),
            vector: vectorOf(input)),
        onDecide: () => on = false,
      );
      var swept = 0;

      await edits(client, enabled: () => on, onSwept: () => swept++).sweep();

      expect(client.calls, hasLength(1));
      expect(swept, 1);
    });

    test('a second press during a sweep queues exactly one more pass',
        () async {
      await seedList();
      final client = model();
      var swept = 0;
      final e = edits(client, onSwept: () => swept++);

      final first = e.sweep();
      final second = await e.sweep();
      final third = await e.sweep();
      await first;

      expect(second, 0);
      expect(third, 0);
      // Two passes over the three listed threads.
      expect(client.calls, hasLength(6));
      expect(swept, 1);
    });
  });

  group('remove on a backend with no vector', () {
    test('labels by id and starts no sweep', () async {
      await seedList();
      var swept = 0;
      final kev = FakeDecisionClient(
        (_) => fakeDecision(fakeAnswers(needsYou: 0.9), model: 'kev'),
      );

      final press =
          await edits(kev, onSwept: () => swept++).remove('email', 't-one');
      await pumpEventQueue();

      expect(press.ids, hasLength(1));
      expect(await pOf('a1'), 0.0);
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
      expect(kev.calls, hasLength(1));
      expect(swept, 0);
    });
  });

  group('retract', () {
    test('an undo brings back the pressed thread and every swept one',
        () async {
      await seedList();
      final client = model();
      final done = Completer<void>();
      final e = edits(client, onSwept: done.complete);

      final press = await e.remove('email', 't-one');
      await done.future;
      expect(await pOf('a1'), 0.0);
      expect(await pOf('b1'), 0.0);

      final redecided = await e.retract(press);

      expect(redecided, 2);
      expect(await store.needsYouLabels(), isEmpty);
      expect(await pOf('a1'), closeTo(0.9, 1e-9));
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
      expect(
        (await store.getMessageRow('email', 'b1'))!['needs_you_reason'],
        'Asks you to do something.',
      );
      expect((await store.decisionFor('email', 'b1'))!.ownerAnswer, isNull);
      expect(await threadP('t-one'), closeTo(0.9, 1e-9));
      expect(await threadP('t-two'), closeTo(0.9, 1e-9));
    });

    test('an undo of an add brings back the model number', () async {
      await thread('t1');
      await message('t1', 'w1', 'First note', p: 0.1);
      final e = edits(model(needsYou: 0.1));

      final press = await e.add('email', 't1');
      expect(await pOf('w1'), 1.0);
      expect(await e.retract(press), 1);

      expect(await pOf('w1'), closeTo(0.1, 1e-9));
    });

    test('an unknown id is a no-op', () async {
      await seedList();
      final client = model();

      expect(
        await edits(client).retract(
          NeedsYouPress([4242], '2026-09-30T10:00:00.000000Z'),
        ),
        0,
      );
      expect(await edits(client).retract(const NeedsYouPress.none()), 0);

      expect(client.calls, isEmpty);
      expect(await pOf('a1'), closeTo(0.9, 1e-9));
    });

    test('a label another press wrote keeps answering', () async {
      await seedList();
      final client = model();
      var swept = 0;
      Future<void> sweeps(int n) async {
        while (swept < n) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      final e = edits(client, onSwept: () => swept++);
      // Two removals of the same template; undoing the second leaves the
      // first in force, so the near-duplicate stays out.
      final first = await e.remove('email', 't-one');
      await sweeps(1);
      final second = await e.remove('email', 't-two');
      await sweeps(2);
      expect(first.ids, isNotEmpty);

      await e.retract(second);

      expect(await pOf('b1'), 0.0);
      expect(
        (await store.getMessageRow('email', 'b1'))!['needs_you_reason'],
        'You removed a message like this from Needs You.',
      );
    });

    test('processing off refuses the undo before it deletes anything',
        () async {
      await thread('t1');
      await message('t1', 'w1', 'First note', p: 0.1);
      var on = true;
      final e = edits(model(needsYou: 0.1), enabled: () => on);
      final press = await e.add('email', 't1');
      on = false;

      await expectLater(e.retract(press), throwsStateError);

      expect((await store.needsYouLabels()).single.id, press.ids.single);
      expect(await pOf('w1'), 1.0);
      expect((await store.decisionFor('email', 'w1'))!.ownerAnswer, 'yes');
    });

    test('a decision server down at the undo changes nothing', () async {
      await thread('t1');
      await message('t1', 'w1', 'First note', p: 0.1);
      var down = false;
      final client = FakeDecisionClient((input) {
        if (down) throw const DecisionUnavailableException('down');
        return fakeDecision(fakeAnswers(needsYou: 0.1),
            vector: vectorOf(input));
      });
      final e = edits(client);
      final press = await e.add('email', 't1');
      down = true;

      await expectLater(
        e.retract(press),
        throwsA(isA<DecisionUnavailableException>()),
      );

      expect(await store.needsYouLabels(), hasLength(1));
      expect(await pOf('w1'), 1.0);
      // So the same press can be undone once the server is back.
      down = false;
      expect(await e.retract(press), 1);
      expect(await pOf('w1'), closeTo(0.1, 1e-9));
    });

    test('every label of one press shares one stamp', () async {
      await thread('t1');
      await message('t1', 'w1', 'Access granted: receipt-one',
          receivedAt: '2026-09-30T09:00:00Z');
      await message('t1', 'w2', 'Access granted: receipt-two',
          receivedAt: '2026-09-30T10:00:00Z');
      final done = Completer<void>();

      final press =
          await edits(model(), onSwept: done.complete).remove('email', 't1');
      await done.future;

      final labels = await store.needsYouLabels();
      expect(press.ids, labels.map((l) => l.id));
      expect(labels.map((l) => l.createdAt).toSet(), {press.createdAt});
    });

    test('an undo retried after its id went to a newer press deletes nothing '
        'of that press', () async {
      await thread('t1');
      await message('t1', 'w1', 'First note', p: 0.1);
      await thread('t2');
      await message('t2', 'x1', 'Second note', p: 0.1);
      final e = edits(model(needsYou: 0.1));

      final stale = await e.add('email', 't1');
      await e.retract(stale);
      // The highest id is handed out again, to a later press.
      final newer = NeedsYouPress(
        [
          await store.writeNeedsYouLabel(
            source: 'email',
            conversationKey: 't2',
            sourceMessageId: 'x1',
            answer: 'yes',
            origin: 'add',
            createdAt: '2099-01-01T00:00:00.000000Z',
          ),
        ],
        '2099-01-01T00:00:00.000000Z',
      );
      expect(newer.ids, stale.ids);
      exemplars.invalidate();

      expect(await e.retract(stale), 0);

      expect((await store.needsYouLabels()).single.sourceMessageId, 'x1');
    });

    test('an undo during the sweep leaves no decision citing its labels',
        () async {
      await seedList();
      final gate = Completer<void>();
      final matched = Completer<void>();
      // The sweep's b1 has matched the press's label and is held before it
      // writes — the window between the read and the delete.
      final held = _HeldExemplars(store, 'b1', matched, gate.future);
      final done = Completer<void>();
      final e = NeedsYouEdits(
        store,
        model(),
        held,
        owner: () async => 'Lo <lo@x.com>',
        threshold: () async => 0.35,
        onSwept: done.complete,
      );

      final press = await e.remove('email', 't-one');
      await matched.future;
      final undo = e.retract(press);
      await pumpEventQueue();
      gate.complete();
      await undo;
      await done.future;

      final citing = await db.customSelect(
        'SELECT source_message_id FROM message_decisions '
        "WHERE json_extract(answers_json, '\$.owner_label_id') IN "
        '(${press.ids.join(',')})',
      ).get();
      expect(citing, isEmpty);
      expect(await pOf('a1'), closeTo(0.9, 1e-9));
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
    });
  });
}

/// Exemplars that hold one message's answer, once, after the match is made
/// and before `applyDecision` writes it.
class _HeldExemplars extends NeedsYouExemplars {
  final String messageId;
  final Completer<void> matched;
  final Future<void> release;
  bool _held = false;

  _HeldExemplars(super.store, this.messageId, this.matched, this.release);

  @override
  Future<OwnerAnswer?> answerFor({
    required String source,
    required String sourceMessageId,
    List<double>? vector,
    required String model,
  }) async {
    final answer = await super.answerFor(
      source: source,
      sourceMessageId: sourceMessageId,
      vector: vector,
      model: model,
    );
    if (sourceMessageId == messageId && answer != null && !_held) {
      _held = true;
      matched.complete();
      await release;
    }
    return answer;
  }
}
