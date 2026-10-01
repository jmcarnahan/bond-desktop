import 'dart:math' as math;

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/needs_you_exemplars.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

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

  /// A unit vector at cosine [c] from `[1, 0]`, padded to four wide.
  List<double> at(double c) => [c, math.sqrt(1 - c * c), 0, 0];

  const base = [1.0, 0.0, 0.0, 0.0];

  Future<int> label(
    String id, {
    String answer = 'no',
    List<double>? vector = base,
    String? model = 'm-v3',
  }) =>
      store.writeNeedsYouLabel(
        source: 'email',
        conversationKey: 'c-$id',
        sourceMessageId: id,
        answer: answer,
        origin: answer == 'yes' ? 'add' : 'remove',
        vector: vector,
        vectorModel: model,
      );

  Future<OwnerAnswer?> ask(
    String id, {
    List<double>? vector,
    String model = 'm-v3',
  }) =>
      exemplars.answerFor(
        source: 'email',
        sourceMessageId: id,
        vector: vector,
        model: model,
      );

  test('the label on the message itself wins over a nearer vector', () async {
    await label('near', answer: 'no', vector: base);
    final own = await label('m1', answer: 'yes', vector: at(0.5));

    final answer = (await ask('m1', vector: base))!;

    expect(answer.answer, 'yes');
    expect(answer.labelId, own);
    expect(answer.exact, isTrue);
    expect(answer.cosine, 1.0);
  });

  test('the nearest label at or above 0.97 matches; 0.96 does not', () async {
    final id = await label('m0');

    final hit = (await ask('m1', vector: at(0.975)))!;
    expect(hit.answer, 'no');
    expect(hit.labelId, id);
    expect(hit.exact, isFalse);
    expect(hit.cosine, closeTo(0.975, 1e-6));

    expect(await ask('m2', vector: at(0.96)), isNull);
    expect(NeedsYouExemplarTuning.matchCosine, 0.97);
  });

  test('the nearer of two labels answers', () async {
    await label('far', answer: 'yes', vector: at(0.98));
    final near = await label('near', answer: 'no', vector: at(0.995));

    final answer = (await ask('m1', vector: base))!;

    expect(answer.labelId, near);
    expect(answer.answer, 'no');
  });

  test('a label under another model is never compared', () async {
    await label('m0', model: 'm-v2');

    expect(await ask('m1', vector: base), isNull);
    expect(await ask('m1', vector: base, model: 'm-v2'), isNotNull);
  });

  test('a label with no vector matches only its own message', () async {
    await label('m0', vector: null, model: null);

    expect(await ask('m1', vector: base), isNull);
    expect((await ask('m0', vector: base))!.answer, 'no');
    expect((await ask('m0'))!.exact, isTrue);
  });

  test('the newest label on one message wins', () async {
    await label('m1', answer: 'no');
    final newer = await label('m1', answer: 'yes');

    final answer = (await ask('m1'))!;

    expect(answer.answer, 'yes');
    expect(answer.labelId, newer);
  });

  test('labels are read once while the table is unchanged', () async {
    final counting = _FlakyStore(db, fails: 0);
    final own = NeedsYouExemplars(counting);
    Future<OwnerAnswer?> askOwn(String id) => own.answerFor(
        source: 'email', sourceMessageId: id, vector: base, model: 'm-v3');
    final id = await label('m1', vector: at(0.5));

    expect((await askOwn('m1'))!.answer, 'no');
    expect(await askOwn('m2'), isNull);
    expect(counting.reads, 1);

    // A new row moves the signature: read again with no invalidate.
    await label('m3');
    expect((await askOwn('m2'))!.labelId, isNot(id));
    expect(counting.reads, 2);

    // A vector refresh leaves the signature where it was, which is why its
    // writer invalidates.
    await counting.updateNeedsYouLabelVector(id, base, 'm-v3');
    expect(counting.reads, 2);
    own.invalidate();
    await askOwn('m2');
    expect(counting.reads, 3);
  });

  test('a wipe is seen without an invalidate', () async {
    await label('m1');
    expect((await ask('m1'))!.answer, 'no');

    // Sign-out, Forget everything and the identity guard all wipe the rows
    // behind the cache's back; the next account's mail must not match them.
    await store.wipeAll();

    expect(await ask('m1'), isNull);
    expect(await ask('m2', vector: base), isNull);
  });

  test('a failed read is not cached', () async {
    final flaky = _FlakyStore(db);
    final own = NeedsYouExemplars(flaky);
    await flaky.writeNeedsYouLabel(
      source: 'email',
      conversationKey: 'c-m1',
      sourceMessageId: 'm1',
      answer: 'no',
      origin: 'remove',
    );

    await expectLater(
      own.answerFor(source: 'email', sourceMessageId: 'm1', model: 'm-v3'),
      throwsA(isA<StateError>()),
    );
    final answer = await own.answerFor(
      source: 'email',
      sourceMessageId: 'm1',
      model: 'm-v3',
    );

    expect(answer!.answer, 'no');
  });

  test('the labels read back with their vectors and model tags', () async {
    final id = await label('m1', vector: [0.25, -0.5, 0.75, 1.0]);

    final labels = await store.needsYouLabels();

    expect(labels.single.id, id);
    expect(labels.single.source, 'email');
    expect(labels.single.conversationKey, 'c-m1');
    expect(labels.single.sourceMessageId, 'm1');
    expect(labels.single.origin, 'remove');
    expect(labels.single.vector, [0.25, -0.5, 0.75, 1.0]);
    expect(labels.single.vectorModel, 'm-v3');
    expect(labels.single.createdAt, isNotEmpty);
  });

  test('withNeedsYou makes the owner answer certain and keeps the rest', () {
    final model = fakeAnswers(needsYou: 0.8, intent: 'request');

    final no = model.withNeedsYou('no');
    expect(no.p('needs_you', 'yes'), 0.0);
    expect(no['needs_you'].choice, 'no');
    expect(no['needs_you'].confidence, 1.0);
    expect(no.ownerAnswer, 'no');
    expect(no.ownerExact, isFalse);
    expect(no['intent'].choice, 'request');

    final yes = fakeAnswers(needsYou: 0.1).withNeedsYou('yes', exact: true);
    expect(yes.p('needs_you', 'yes'), 1.0);
    expect(yes.ownerAnswer, 'yes');
    expect(yes.ownerExact, isTrue);
  });
}

/// A store whose first [fails] label reads throw, as a locked database might,
/// and which counts the reads that went through.
class _FlakyStore extends MessageStore {
  int _fails;

  /// How many label reads reached the database.
  int reads = 0;

  _FlakyStore(super.db, {this._fails = 1});

  @override
  Future<List<NeedsYouLabel>> needsYouLabels() {
    if (_fails-- > 0) throw StateError('database is locked');
    reads++;
    return super.needsYouLabels();
  }
}
