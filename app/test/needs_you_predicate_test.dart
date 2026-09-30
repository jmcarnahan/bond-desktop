import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/decision/decision_questions.dart'
    show decisionQhash;
import 'package:bond_inbox/services/decision/needs_you_predicate.dart';
import 'package:bond_inbox/widgets/needs_you_reason.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

void main() {
  late BondDatabase db;

  setUp(() => db = testDb());
  tearDown(() async => db.close());

  // (p, threshold, needs you). NULL p, p exactly at the cut, both ends of the
  // probability scale and both ends of the slider.
  const cases = <(double?, double, bool)>[
    (null, 0.30, false),
    (null, 0.05, false),
    (0.0, 0.05, false),
    (0.0, 0.30, false),
    (0.04, 0.05, false),
    (0.05, 0.05, true),
    (0.29, 0.30, false),
    (0.30, 0.30, true),
    (0.31, 0.30, true),
    (0.5, 0.5, true),
    (0.94, 0.95, false),
    (0.95, 0.95, true),
    (1.0, 0.95, true),
    (1.0, 0.30, true),
  ];

  test('the Dart predicate answers the table', () {
    for (final (p, t, want) in cases) {
      expect(needsYouAt(p, t), want, reason: 'p=$p threshold=$t');
    }
  });

  test('the SQL fragment agrees with the Dart predicate, bound and literal',
      () async {
    for (final (p, t, want) in cases) {
      final bound = await db
          .customSelect(
            'SELECT ${needsYouAtSql('p', '?2')} AS hit FROM (SELECT ?1 AS p)',
            variables: [Variable<double>(p), Variable<double>(t)],
          )
          .getSingle();
      expect(bound.data['hit'] == 1, needsYouAt(p, t),
          reason: 'bound p=$p threshold=$t');
      expect(bound.data['hit'] == 1, want);

      final literal = await db
          .customSelect(
            'SELECT ${needsYouAtSql('p', '$t')} AS hit FROM (SELECT ?1 AS p)',
            variables: [Variable<double>(p)],
          )
          .getSingle();
      expect(literal.data['hit'] == 1, want,
          reason: 'literal p=$p threshold=$t');
    }
  });

  test('the percentage shown agrees with the predicate on every notch', () {
    // Floored, so the number a surface prints is at or above the line's
    // exactly when the row is in Needs You.
    for (final (p, shown) in [
      (0.296, '29%'),
      (0.2999, '29%'),
      (0.30, '30%'),
      (0.3001, '30%'),
      (0.57, '57%'),
      (0.0, '0%'),
    ]) {
      expect(needsYouPercentWords(p, decidedNow: true), shown, reason: '$p');
    }
    for (var notch = 1; notch <= 19; notch++) {
      final t = normalizeNeedsYouThreshold(notch * 0.05);
      for (var i = 0; i <= 1000; i++) {
        final p = i / 1000;
        final shown = int.parse(
          needsYouPercentWords(p, decidedNow: true)!.replaceAll('%', ''),
        );
        expect(shown >= (t * 100).round(), needsYouAt(p, t),
            reason: 'p=$p threshold=$t');
      }
    }
  });

  test("an earlier model's carried verdict shows no percentage", () {
    expect(needsYouPercentWords(1.0), isNull);
    expect(needsYouPercentWords(0.0), isNull);
    expect(needsYouPercentWords(1.0, decidedNow: false), isNull);
    expect(needsYouPercentWords(1.0, decidedNow: true), '100%');
    // Strictly between the two ends, a number is a model's whoever decided.
    expect(needsYouPercentWords(0.72), '72%');
    expect(needsYouPercentWords(null), isNull);
  });

  test('the conversation read knows which model decided its probability',
      () async {
    final store = MessageStore(db);
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': '2026-09-01T10:00:00Z',
      'created_at': '2026-09-01T10:00:00Z',
      'updated_at': '2026-09-01T10:00:00Z',
      'triage_status': 'triaged',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c1',
      'subject': 'Launch date',
      'state': 'needs_reply',
    });
    // v21's carried verdict: a 1.0 with no decision row at all.
    await store.writeNeedsYouP('email', 'm1', p: 1.0);
    Future<bool?> decidedNow() async =>
        (await store.loadConversations()).single.needsYouDecidedNow;
    expect(await decidedNow(), isFalse);

    await store.writeDecision(
      'email',
      'm1',
      fakeDecision(fakeAnswers(needsYou: 0.9)),
      qhash: 'an-older-question-set',
      ownerKnown: true,
    );
    expect(await decidedNow(), isFalse);

    await store.writeDecision(
      'email',
      'm1',
      fakeDecision(fakeAnswers(needsYou: 0.9)),
      qhash: decisionQhash,
      ownerKnown: true,
    );
    expect(await decidedNow(), isTrue);

    // A failed re-decide's marker is no decision, as `decisionFor` reads it.
    await store.settleFailedDecision('email', 'm1', qhash: decisionQhash);
    expect(await decidedNow(), isFalse);
    expect(await store.decisionFor('email', 'm1'), isNull);
  });

  test('the tuning numbers', () {
    expect(NeedsYouTuning.defaultThreshold, 0.30);
    expect(NeedsYouTuning.minThreshold, 0.05);
    expect(NeedsYouTuning.maxThreshold, 0.95);
    expect(NeedsYouTuning.step, 0.05);
  });
}
