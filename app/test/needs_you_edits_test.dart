import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/decision_input.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart';
import 'package:bond_inbox/services/decision/stored_decision.dart';
import 'package:bond_inbox/services/llm/llm_client.dart'
    show DecisionUnavailableException;
import 'package:bond_inbox/services/needs_you_edits.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The owner's presses: a label per message with its vector, the decision
/// written again through `applyDecision` from the STORED decision when it has
/// a vector under the current model (no model call), and the sweep — a scan
/// of the stored vectors, both ways — inside the press.
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

  const tag = 'bond-decide-fake';

  /// Four-wide stand-ins for the encoder's vector, keyed by a word in the
  /// body: two templated receipts at cosine 0.99, an unrelated ask at 0.3.
  const vectors = {
    'receipt-one': [1.0, 0.0, 0.0, 0.0],
    'receipt-two': [1.0, 0.1425, 0.0, 0.0],
    'budget': [0.3, 0.9539, 0.0, 0.0],
  };

  List<double> vectorOfBody(String body) {
    for (final MapEntry(:key, :value) in vectors.entries) {
      if (body.contains(key)) return value;
    }
    return const [0.0, 0.0, 1.0, 0.0];
  }

  List<double> vectorOf(DecisionInput input) =>
      vectorOfBody(input.bodyText ?? '');

  /// The model calls every message an ask at [needsYou], with its vector,
  /// answering under [tag] — the current model, so a stored decision under
  /// it stands in for a call.
  FakeDecisionClient model({double needsYou = 0.9}) => FakeDecisionClient(
        (input) => fakeDecision(
          fakeAnswers(needsYou: needsYou, intent: 'request'),
          vector: vectorOf(input),
        ),
      )..tag = tag;

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

  /// One message. With [stored] (the default) its decision is stored as
  /// triage leaves it — the model's [p] and the vector of its body under
  /// [model] — so a press needs no model call for it.
  Future<void> message(
    String key,
    String id,
    String body, {
    String receivedAt = '2026-09-30T10:00:00Z',
    String direction = 'inbound',
    double? p = 0.9,
    bool stored = true,
    String model = tag,
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
    if (p == null || direction != 'inbound') return;
    if (stored) {
      await store.writeDecision(
        'email',
        id,
        fakeDecision(
          fakeAnswers(needsYou: p, intent: 'request'),
          vector: vectorOfBody(body),
          model: model,
        ),
        qhash: decisionQhash,
        ownerKnown: true,
      );
    }
    await store.writeNeedsYouP('email', id, p: p, reason: 'Asks you.');
  }

  Future<double?> pOf(String id) async =>
      ((await store.getMessageRow('email', id))!['needs_you_p'] as num?)
          ?.toDouble();

  Future<String?> reasonOf(String id) async =>
      (await store.getMessageRow('email', id))!['needs_you_reason']
          as String?;

  NeedsYouEdits edits(
    FakeDecisionClient client, {
    double threshold = 0.35,
    bool Function()? enabled,
  }) =>
      NeedsYouEdits(
        store,
        client,
        exemplars,
        owner: () async => 'Lo <lo@x.com>',
        threshold: () async => threshold,
        enabled: enabled,
        modelTag: () => client.modelTag,
      );

  /// The thread's number as the rail reads it.
  Future<double?> threadP(String key) async =>
      (await store.loadConversations())
          .singleWhere((c) => c.id == key)
          .needsYouP;

  /// Three threads in Needs You — two templated receipts and one real ask —
  /// plus a receipt the owner marked Done and one sent to Later, all with
  /// stored decisions at [p].
  Future<void> seedList({double p = 0.9}) async {
    await thread('t-one', lastMessageAt: '2026-09-30T10:00:00Z');
    await message('t-one', 'a1', 'Access granted: receipt-one', p: p);
    await thread('t-two', lastMessageAt: '2026-09-30T09:00:00Z');
    await message('t-two', 'b1', 'Access granted: receipt-two', p: p);
    await thread('t-ask', lastMessageAt: '2026-09-30T08:00:00Z');
    await message('t-ask', 'c1', 'Can you approve the budget?', p: p);
    await thread('t-done', state: 'done');
    await message('t-done', 'd1', 'Access granted: receipt-two', p: p);
    await thread('t-later');
    await message('t-later', 'e1', 'Access granted: receipt-two', p: p);
    await store.setConversationBucket('email', 't-later', bucket: 'later');
  }

  group('remove', () {
    test('labels every window message with its stored vector, drops the '
        'thread, and asks the model nothing', () async {
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
      final client = model();

      final press = await edits(client).remove('email', 't1');

      expect(client.calls, isEmpty);
      expect(press.similar, isTrue);
      final labels = await store.needsYouLabels();
      expect(labels.map((l) => l.sourceMessageId), ['w1', 'w2']);
      expect(labels.every((l) => l.answer == 'no'), isTrue);
      expect(labels.every((l) => l.origin == 'remove'), isTrue);
      expect(labels.first.vector, vectors['receipt-one']);
      // float32 in the BLOB.
      expect(labels.last.vector![1], closeTo(0.1425, 1e-6));
      expect(labels.first.vectorModel, tag);
      expect(await pOf('w1'), 0.0);
      expect(await pOf('w2'), 0.0);
      // The model's own number is kept beside the override.
      final w2 = (await store.decisionFor('email', 'w2'))!;
      expect(w2.ownerAnswer, 'no');
      expect(w2.modelNeedsYouP, closeTo(0.6, 1e-9));
      expect(w2.vector![1], closeTo(0.1425, 1e-6));
      // Outside the window: neither labelled nor written.
      expect(await pOf('old'), closeTo(0.2, 1e-9));
      expect(await threadP('t1'), 0.0);
    });

    test('a message with no stored vector is decided by the model', () async {
      await thread('t1');
      await message('t1', 'w1', 'Access granted: receipt-one',
          receivedAt: '2026-09-30T09:00:00Z');
      await message('t1', 'w2', 'Access granted: receipt-two',
          receivedAt: '2026-09-30T10:00:00Z', stored: false);
      final client = model();

      await edits(client).remove('email', 't1');

      expect(client.calls.map((c) => c.bodyText),
          ['Access granted: receipt-two']);
      final labels = await store.needsYouLabels();
      expect(labels.map((l) => l.vector), [
        vectors['receipt-one'],
        vectors['receipt-two']!.map((v) => closeTo(v, 1e-6)).toList(),
      ]);
      expect(await pOf('w1'), 0.0);
      expect(await pOf('w2'), 0.0);
      // And the model's vector is stored with its decision from now on.
      expect((await store.decisionFor('email', 'w2'))!.vector, isNotNull);
    });

    test('a stored vector under another model is not used', () async {
      await thread('t1');
      await message('t1', 'w1', 'Access granted: receipt-one',
          model: 'an-older-model');
      final client = model();

      await edits(client).remove('email', 't1');

      expect(client.calls, hasLength(1));
      expect((await store.needsYouLabels()).single.vectorModel, tag);
      expect(await pOf('w1'), 0.0);
    });

    test('a decision error part-way writes nothing at all', () async {
      await thread('t1');
      await message('t1', 'w1', 'Access granted: receipt-one',
          receivedAt: '2026-09-30T09:00:00Z');
      await message('t1', 'w2', 'Access granted: receipt-two',
          receivedAt: '2026-09-30T10:00:00Z', stored: false);
      final client = FakeDecisionClient(
        (_) => throw const DecisionUnavailableException('down'),
      )..tag = tag;

      await expectLater(
        edits(client).remove('email', 't1'),
        throwsA(isA<DecisionUnavailableException>()),
      );

      expect(await store.needsYouLabels(), isEmpty);
      expect(await pOf('w1'), closeTo(0.9, 1e-9));
      expect((await store.decisionFor('email', 'w1'))!.ownerAnswer, isNull);
      expect(await threadP('t1'), closeTo(0.9, 1e-9));
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
      final client = model(needsYou: 0.1);

      await edits(client).add('email', 't1');

      expect(client.calls, isEmpty);
      final labels = await store.needsYouLabels();
      expect(labels.single.sourceMessageId, 'w2');
      expect(labels.single.answer, 'yes');
      expect(labels.single.origin, 'add');
      expect(await pOf('w2'), 1.0);
      expect(await pOf('w1'), closeTo(0.1, 1e-9));
      expect(await reasonOf('w2'), 'You added this message to Needs You.');
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

  group('the sweep inside a press', () {
    test('a removal takes every similar Needs You thread out at once, and '
        'nothing else', () async {
      await seedList();
      final client = model();

      final press = await edits(client).remove('email', 't-one');

      expect(client.calls, isEmpty, reason: 'a scan, not model calls');
      expect(press.similar, isTrue);
      expect(press.changed, 1);
      expect(await pOf('a1'), 0.0);
      expect(await pOf('b1'), 0.0);
      expect(await reasonOf('b1'),
          'You removed a message like this from Needs You.');
      expect(
        (await store.decisionFor('email', 'b1'))!.modelNeedsYouP,
        closeTo(0.9, 1e-9),
      );
      expect(await pOf('c1'), closeTo(0.9, 1e-9));
      // Done and Later are not in Needs You, so the sweep never reads them.
      expect((await store.decisionFor('email', 'd1'))!.ownerAnswer, isNull);
      expect((await store.decisionFor('email', 'e1'))!.ownerAnswer, isNull);
      expect(await pOf('d1'), closeTo(0.9, 1e-9));
      expect(await pOf('e1'), closeTo(0.9, 1e-9));
    });

    test('a listed thread of several near-duplicates leaves whole', () async {
      await seedList();
      // A second receipt in t-two, the newer and the higher: it would become
      // the driver if only the driver were written again.
      await message('t-two', 'b2', 'Access granted again: receipt-two',
          receivedAt: '2026-09-30T10:30:00Z', p: 1.0);

      final press = await edits(model()).remove('email', 't-one');

      expect(press.changed, 1);
      expect(await pOf('b1'), 0.0);
      expect(await pOf('b2'), 0.0);
      expect(await threadP('t-two'), 0.0);
      expect(await threadP('t-ask'), closeTo(0.9, 1e-9));
    });

    test('an addition pulls similar threads in, never a done or Later one',
        () async {
      await seedList(p: 0.1);
      final client = model(needsYou: 0.1);

      final press = await edits(client).add('email', 't-one');

      expect(client.calls, isEmpty, reason: 'a scan, not model calls');
      expect(press.similar, isTrue);
      expect(press.changed, 1);
      expect(await threadP('t-one'), 1.0);
      expect(await threadP('t-two'), 1.0);
      expect(await reasonOf('b1'),
          'You added a message like this to Needs You.');
      expect(await threadP('t-ask'), closeTo(0.1, 1e-9));
      expect(await pOf('d1'), closeTo(0.1, 1e-9));
      expect(await pOf('e1'), closeTo(0.1, 1e-9));
    });

    test('a thread already on the far side is not counted', () async {
      await seedList();
      // t-two is already below the slider: the removal's sweep never looks
      // at it, and the toast's count says only what moved.
      await message('t-two', 'b1', 'Access granted: receipt-two', p: 0.1);

      final press = await edits(model()).remove('email', 't-one');

      expect(press.changed, 0);
      expect(await pOf('b1'), closeTo(0.1, 1e-9));
    });

    test('processing turned off stops it between messages', () async {
      await seedList();
      // On for the press's own check, off from the sweep's first look.
      var reads = 0;

      final press = await edits(model(), enabled: () => reads++ == 0)
          .remove('email', 't-one');

      expect(await pOf('a1'), 0.0);
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
      expect(press.changed, 0);
    });

    test('on a backend with no vector the press labels by id and looks no '
        'further', () async {
      await seedList();
      for (final id in ['a1', 'b1']) {
        await store.writeDecision(
          'email',
          id,
          fakeDecision(fakeAnswers(needsYou: 0.9), model: 'kev'),
          qhash: decisionQhash,
          ownerKnown: true,
        );
      }
      // Kev's client: no tag, so every pressed message is asked.
      final kev = FakeDecisionClient(
        (_) => fakeDecision(fakeAnswers(needsYou: 0.9), model: 'kev'),
      );

      final press = await edits(kev).remove('email', 't-one');

      expect(press.ids, hasLength(1));
      expect(press.similar, isFalse);
      expect(press.changed, 0);
      expect(await pOf('a1'), 0.0);
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
      expect(kev.calls, hasLength(1));
    });
  });

  group('retract', () {
    test('an undo brings back the pressed thread and every swept one, from '
        "the model's own number, with no model call", () async {
      await seedList();
      final client = model();
      final e = edits(client);

      final press = await e.remove('email', 't-one');
      expect(await pOf('b1'), 0.0);

      final written = await e.retract(press);

      expect(written, 2);
      expect(client.calls, isEmpty);
      expect(await store.needsYouLabels(), isEmpty);
      expect(await pOf('a1'), closeTo(0.9, 1e-9));
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
      expect(await reasonOf('b1'), 'Asks you to do something.');
      final b1 = (await store.decisionFor('email', 'b1'))!;
      expect(b1.ownerAnswer, isNull);
      expect(b1.modelNeedsYouP, isNull);
      expect(b1.vector, isNotNull);
      expect(await threadP('t-one'), closeTo(0.9, 1e-9));
      expect(await threadP('t-two'), closeTo(0.9, 1e-9));
    });

    test('an undo of an add brings back the model number and the threads it '
        'pulled in', () async {
      await seedList(p: 0.1);
      final client = model(needsYou: 0.1);
      final e = edits(client);

      final press = await e.add('email', 't-one');
      expect(await threadP('t-two'), 1.0);
      expect(await e.retract(press), 2);

      expect(client.calls, isEmpty);
      expect(await pOf('a1'), closeTo(0.1, 1e-9));
      expect(await pOf('b1'), closeTo(0.1, 1e-9));
    });

    test('an override that did not keep the model number is decided by the '
        'model', () async {
      await thread('t1');
      await message('t1', 'w1', 'Access granted: receipt-one');
      // A press from before the model's number was kept beside it.
      const stamp = '2026-09-30T12:00:00.000000Z';
      final id = await store.writeNeedsYouLabel(
        source: 'email',
        conversationKey: 't1',
        sourceMessageId: 'w1',
        answer: 'no',
        origin: 'remove',
        vector: vectors['receipt-one'],
        vectorModel: tag,
        createdAt: stamp,
      );
      await store.writeDecision(
        'email',
        'w1',
        fakeDecision(
          fakeAnswers(needsYou: 0.9).withNeedsYou('no', exact: true),
          vector: vectors['receipt-one'],
        ),
        qhash: decisionQhash,
        ownerKnown: true,
        extraKeys: {
          decisionOwnerAnswerKey: 'no',
          decisionOwnerLabelIdKey: id,
          decisionOwnerExactKey: true,
        },
      );
      await store.writeNeedsYouP('email', 'w1', p: 0.0);
      final client = model(needsYou: 0.7);

      expect(await edits(client).retract(NeedsYouPress([id], stamp)), 1);

      expect(client.calls, hasLength(1));
      expect(await pOf('w1'), closeTo(0.7, 1e-9));
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
      final e = edits(model());
      // Two removals of the same template; undoing the second leaves the
      // first in force, so the near-duplicate stays out. The first already
      // took t-two, so the second press is on the ask.
      final first = await e.remove('email', 't-one');
      final second = await e.remove('email', 't-ask');
      expect(first.ids, isNotEmpty);

      await e.retract(second);

      expect(await pOf('b1'), 0.0);
      expect(await reasonOf('b1'),
          'You removed a message like this from Needs You.');
      expect(await pOf('c1'), closeTo(0.9, 1e-9));
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
      await message('t1', 'w1', 'First note', p: 0.1, stored: false);
      var down = false;
      // No tag: nothing stored can stand in, so the undo must ask.
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

      final press = await edits(model()).remove('email', 't1');

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
  });

  group('retractAll', () {
    test("forgets every press, newest first, and the model's numbers come "
        'back with no model call', () async {
      await seedList();
      await thread('t-quiet', lastMessageAt: '2026-09-30T07:00:00Z');
      await message('t-quiet', 'q1', 'A quiet note', p: 0.1);
      final client = model();
      final e = edits(client);
      final removed = await e.remove('email', 't-one');
      // A later stamp than the removal's, whatever the clock's grain.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final added = await e.add('email', 't-quiet');
      expect(await store.needsYouLabelStamps(),
          [added.createdAt, removed.createdAt]);
      expect(await store.needsYouPressCounts(), (removed: 1, added: 1));

      final written = await e.retractAll();

      expect(written, 3);
      expect(client.calls, isEmpty);
      expect(await store.needsYouLabels(), isEmpty);
      expect(await store.needsYouPressCounts(), (removed: 0, added: 0));
      expect(await pOf('a1'), closeTo(0.9, 1e-9));
      expect(await pOf('b1'), closeTo(0.9, 1e-9));
      expect(await pOf('q1'), closeTo(0.1, 1e-9));
    });

    test('with nothing pressed does nothing', () async {
      await seedList();
      final client = model();

      expect(await edits(client).retractAll(), 0);
      expect(client.calls, isEmpty);
    });

    test('processing off refuses it', () async {
      await seedList();
      final e = edits(model(), enabled: () => false);

      await expectLater(e.retractAll(), throwsStateError);
    });
  });

  group('needsYouPressCounts', () {
    test('counts presses by stamp, not labels', () async {
      Future<void> label(String id, String origin, String stamp) =>
          store.writeNeedsYouLabel(
            source: 'email',
            conversationKey: 't1',
            sourceMessageId: id,
            answer: origin == 'add' ? 'yes' : 'no',
            origin: origin,
            createdAt: stamp,
          );
      // One removal over two messages, another over one, and one addition.
      await label('m1', 'remove', '2026-09-30T10:00:00.000000Z');
      await label('m2', 'remove', '2026-09-30T10:00:00.000000Z');
      await label('m3', 'remove', '2026-09-30T11:00:00.000000Z');
      await label('m4', 'add', '2026-09-30T12:00:00.000000Z');

      expect(await store.needsYouPressCounts(), (removed: 2, added: 1));
    });
  });
}
