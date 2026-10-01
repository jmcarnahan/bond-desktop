import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart';
import 'package:bond_inbox/services/decision/stored_decision.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// A stored decision as `MessageStore.decisionFor` reads it back: the
/// vector, the model's own number beside an override, and the model's
/// answers a press writes again with no model call.
void main() {
  group('modelAnswers', () {
    final model = fakeAnswers(needsYou: 0.8, intent: 'request');

    test("a decision the model alone made is the model's", () {
      final stored = StoredDecision(answers: model, model: 'm');

      expect(stored.modelAnswers!.p('needs_you', 'yes'), closeTo(0.8, 1e-9));
      expect(stored.modelAnswers!.ownerAnswer, isNull);
    });

    test("an override puts the model's number back", () {
      final stored = StoredDecision(
        answers: DecisionAnswers(
          model.withNeedsYou('no').fields,
          ownerAnswer: 'no',
        ),
        model: 'm',
        modelNeedsYouP: 0.8,
      );

      final answers = stored.modelAnswers!;
      expect(answers.p('needs_you', 'yes'), closeTo(0.8, 1e-9));
      expect(answers['needs_you'].choice, 'yes');
      expect(answers.ownerAnswer, isNull);
      expect(answers['intent'].choice, 'request');
    });

    test("an override that did not keep the model's number has none", () {
      final stored = StoredDecision(
        answers: DecisionAnswers(
          model.withNeedsYou('no').fields,
          ownerAnswer: 'no',
        ),
        model: 'm',
      );

      expect(stored.modelAnswers, isNull);
    });

    test('an unreadable row has none', () {
      expect(
        const StoredDecision(answers: DecisionAnswers({}), model: 'm')
            .modelAnswers,
        isNull,
      );
    });
  });

  group('decisionFor', () {
    late BondDatabase db;
    late MessageStore store;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
    });

    tearDown(() async => db.close());

    test('reads the vector back under the row model, and the model number',
        () async {
      await store.writeDecision(
        'email',
        'm1',
        fakeDecision(
          fakeAnswers(needsYou: 0.0),
          vector: const [0.5, -0.25, 0.0, 1.0],
          model: 'bond-decide-v3',
        ),
        qhash: decisionQhash,
        ownerKnown: true,
        extraKeys: {
          decisionOwnerAnswerKey: 'no',
          decisionModelNeedsYouKey: 0.65,
        },
      );

      final stored = (await store.decisionFor('email', 'm1'))!;
      expect(stored.vector, [0.5, -0.25, 0.0, 1.0]);
      expect(stored.vectorModel, 'bond-decide-v3');
      expect(stored.ownerAnswer, 'no');
      expect(stored.modelNeedsYouP, 0.65);
    });

    test('a decision written with no vector reads none, and a later one '
        'with a vector replaces it', () async {
      await store.writeDecision(
        'email',
        'm1',
        fakeDecision(fakeAnswers(), model: 'kev'),
        qhash: decisionQhash,
        ownerKnown: true,
      );
      expect((await store.decisionFor('email', 'm1'))!.vector, isNull);
      expect((await store.decisionFor('email', 'm1'))!.modelNeedsYouP, isNull);

      await store.writeDecision(
        'email',
        'm1',
        fakeDecision(fakeAnswers(), vector: const [1.0, 0.0]),
        qhash: decisionQhash,
        ownerKnown: true,
      );
      expect((await store.decisionFor('email', 'm1'))!.vector, [1.0, 0.0]);
    });
  });
}
