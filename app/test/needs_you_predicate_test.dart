import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/services/decision/needs_you_predicate.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';

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

  test('the tuning numbers', () {
    expect(NeedsYouTuning.defaultThreshold, 0.30);
    expect(NeedsYouTuning.minThreshold, 0.05);
    expect(NeedsYouTuning.maxThreshold, 0.95);
    expect(NeedsYouTuning.step, 0.05);
  });
}
