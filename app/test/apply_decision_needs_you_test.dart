import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// The owner's Needs You answer inside `applyDecision`: the one place it
/// replaces the model's, so every decision path inherits it.
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

  /// Four-wide stand-ins for the encoder's vector: [templated] and [twin]
  /// sit at cosine 0.99, [unrelated] at 0.3 from both.
  const templated = [1.0, 0.0, 0.0, 0.0];
  const twin = [1.0, 0.1425, 0.0, 0.0];
  const unrelated = [0.3, 0.9539, 0.0, 0.0];

  Future<Map<String, Object?>> seed(String id, {double? p}) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c-$id',
      'subject': 'Access granted',
      'state': 'needs_reply',
      'last_message_at': '2026-09-30T10:00:00Z',
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'c-$id',
      'direction': 'inbound',
      'from_name': 'Portal',
      'from_address': 'portal@fabrikam.example.com',
      'to_json': '["lo@x.com"]',
      'received_at': '2026-09-30T10:00:00Z',
      'body_text': 'Your access to the shared workspace was granted.',
      'triage_status': 'triaged',
    });
    if (p != null) {
      await store.writeNeedsYouP('email', id, p: p, reason: 'Asks you.');
    }
    return (await store.getMessageRow('email', id))!;
  }

  Future<int> label(
    String id, {
    String answer = 'no',
    List<double>? vector = templated,
    String? model = 'bond-decide-fake',
  }) async {
    final labelId = await store.writeNeedsYouLabel(
      source: 'email',
      conversationKey: 'c-$id',
      sourceMessageId: id,
      answer: answer,
      origin: answer == 'yes' ? 'add' : 'remove',
      vector: vector,
      vectorModel: model,
    );
    exemplars.invalidate();
    return labelId;
  }

  Future<Map<String, Object?>> decisionRow(String id) async => (await db
          .customSelect(
            'SELECT needs_you_p, answers_json FROM message_decisions '
            'WHERE source = ? AND source_message_id = ?',
            variables: [Variable('email'), Variable(id)],
          )
          .getSingle())
      .data;

  Future<void> apply(
    Map<String, Object?> row, {
    double needsYou = 0.9,
    List<double>? vector,
    String model = 'bond-decide-fake',
    NeedsYouExemplars? using,
    PipelineProgress progress = const PipelineProgress.disabled(),
  }) =>
      applyDecision(
        store,
        'email',
        row,
        fakeDecision(
          fakeAnswers(needsYou: needsYou, intent: 'request'),
          vector: vector,
          model: model,
        ),
        ownerKnown: true,
        progress: progress,
        exemplars: using,
      );

  test('a near-duplicate of a removed message is written as 0.0 everywhere',
      () async {
    final labelId = await label('m0');
    final row = await seed('m1', p: 0.9);

    await apply(row, vector: twin, using: exemplars);

    final message = (await store.getMessageRow('email', 'm1'))!;
    expect(message['needs_you_p'], 0.0);
    expect(
      message['needs_you_reason'],
      'You removed a message like this from Needs You.',
    );
    final decision = await decisionRow('m1');
    expect(decision['needs_you_p'], 0.0);
    final json = jsonDecode(decision['answers_json'] as String) as Map;
    expect(json['owner_answer'], 'no');
    expect(json['owner_label_id'], labelId);
    expect(json['owner_cosine'], closeTo(0.99, 0.001));
    expect(json['owner_exact'], false);
    expect(json['owner_known'], true);
    final stored = (await store.decisionFor('email', 'm1'))!;
    expect(stored.ownerAnswer, 'no');
    expect(stored.needsYouP, 0.0);
    // The model's other answers stand.
    expect(stored.answers['intent'].choice, 'request');
  });

  test('a label on the message itself is worded "this message"', () async {
    final row = await seed('m1', p: 0.1);
    await label('m1', answer: 'yes', vector: unrelated);

    await apply(row, needsYou: 0.1, vector: unrelated, using: exemplars);

    final message = (await store.getMessageRow('email', 'm1'))!;
    expect(message['needs_you_p'], 1.0);
    expect(message['needs_you_reason'], 'You added this message to Needs You.');
    expect((await decisionRow('m1'))['needs_you_p'], 1.0);
  });

  test('without a match, or without exemplars, the model stands', () async {
    await label('m0');
    final row = await seed('m1', p: 0.9);

    await apply(row, needsYou: 0.8, vector: unrelated, using: exemplars);
    var message = (await store.getMessageRow('email', 'm1'))!;
    expect(message['needs_you_p'], closeTo(0.8, 1e-9));
    expect(message['needs_you_reason'], 'Asks you to do something.');
    final json =
        jsonDecode((await decisionRow('m1'))['answers_json'] as String) as Map;
    expect(json.containsKey('owner_answer'), isFalse);
    expect((await store.decisionFor('email', 'm1'))!.ownerAnswer, isNull);

    await apply(row, needsYou: 0.7, vector: twin);
    message = (await store.getMessageRow('email', 'm1'))!;
    expect(message['needs_you_p'], closeTo(0.7, 1e-9));
  });

  test('the chip follows the overridden probability', () async {
    final bus = ProgressBus();
    addTearDown(bus.dispose);
    final progress = PipelineProgress(store, bus: bus);
    await label('m0');
    final row = await seed('m1', p: 0.9);
    await progress.noteSettled(
      'email',
      'm1',
      needsYou: true,
      reason: 'worthy',
      dropped: false,
    );
    Future<Object?> flag() async => (await db
            .customSelect(
              "SELECT needs_you FROM message_progress "
              "WHERE source = 'email' AND source_message_id = 'm1'",
            )
            .getSingle())
        .data['needs_you'];
    expect(await flag(), 1);

    await apply(row, vector: twin, using: exemplars, progress: progress);

    expect(await flag(), 0);
  });

  test('a label under another model gets its vector refreshed', () async {
    final labelId = await label('m1', vector: unrelated, model: 'old-model');
    final row = await seed('m1', p: 0.9);

    await apply(row, vector: twin, using: exemplars);

    final labels = await store.needsYouLabels();
    expect(labels.single.id, labelId);
    expect(labels.single.vectorModel, 'bond-decide-fake');
    expect(labels.single.vector![1], closeTo(0.1425, 1e-6));
    expect((await store.getMessageRow('email', 'm1'))!['needs_you_p'], 0.0);
  });

  test('a label with no vector heals from the next decision with one',
      () async {
    await label('m1', vector: null, model: null);
    final row = await seed('m1', p: 0.9);

    await apply(row, vector: templated, using: exemplars);

    final labels = await store.needsYouLabels();
    expect(labels.single.vector, templated);
    expect(labels.single.vectorModel, 'bond-decide-fake');
  });

  test('the Kev shape (no vector) applies the exact label only', () async {
    await label('m0');
    await label('m1', vector: null, model: null);
    final exact = await seed('m1', p: 0.9);
    final other = await seed('m2', p: 0.9);

    await apply(exact, model: 'kev', using: exemplars);
    await apply(other, needsYou: 0.8, model: 'kev', using: exemplars);

    expect((await store.getMessageRow('email', 'm1'))!['needs_you_p'], 0.0);
    expect(
      (await store.getMessageRow('email', 'm2'))!['needs_you_p'],
      closeTo(0.8, 1e-9),
    );
    // Nothing to heal from: the label keeps its NULL vector.
    final labels = await store.needsYouLabels();
    expect(labels.last.vector, isNull);
  });

  test('decisionQhash rides the overridden row like any other', () async {
    await label('m0');
    final row = await seed('m1', p: 0.9);
    await apply(row, vector: twin, using: exemplars);
    final qhash = (await db
            .customSelect(
              "SELECT qhash FROM message_decisions "
              "WHERE source_message_id = 'm1'",
            )
            .getSingle())
        .data['qhash'];
    expect(qhash, decisionQhash);
  });
}
