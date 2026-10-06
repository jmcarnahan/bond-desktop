import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/services/perf/perf_log.dart';
// drift exports an `isNull` and an `isNotNull` of its own, which would shadow
// the matchers.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UiStallMonitor', () {
    // The clock is a variable the test moves by hand, and fake async drives
    // the periodic timer: a tick "arrives late" when the test moves the clock
    // further than one interval before pumping one interval.
    late int now;
    late int clockReads;
    late List<String> lines;
    late UiStallMonitor monitor;

    setUp(() {
      now = 0;
      clockReads = 0;
      lines = [];
      monitor = UiStallMonitor(
        nowMicros: () {
          clockReads += 1;
          return now;
        },
        log: lines.add,
      );
    });

    /// One heartbeat that the clock says arrived [ms] after the last one.
    Future<void> tick(WidgetTester tester, int ms) async {
      now += ms * 1000;
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('ticks that arrive on time log nothing', (tester) async {
      monitor.start();
      for (var i = 0; i < 10; i++) {
        await tick(tester, 50);
      }
      monitor.stop();
      expect(lines, isEmpty);
    });

    testWidgets('a tick 180 ms late logs exactly that', (tester) async {
      monitor.start();
      await tick(tester, 50);
      await tick(tester, 230);
      await tick(tester, 50);
      monitor.stop();
      expect(lines, ['ui-stall 180ms']);
    });

    testWidgets('a tick 99 ms late is under the threshold', (tester) async {
      monitor.start();
      await tick(tester, 149);
      monitor.stop();
      expect(lines, isEmpty);
    });

    testWidgets('the summary counts the window, and a quiet one still prints',
        (tester) async {
      monitor.start();
      await tick(tester, 230);
      // On-time ticks until the clock reaches a full minute since start.
      while (now < 60 * 1000 * 1000) {
        await tick(tester, 50);
      }
      expect(lines, [
        'ui-stall 180ms',
        'ui-stalls 60s: n=1 max=180ms total=180ms',
      ]);

      final windowStart = now;
      while (now < windowStart + 60 * 1000 * 1000) {
        await tick(tester, 50);
      }
      monitor.stop();
      expect(lines.last, 'ui-stalls 60s: n=0 max=0ms total=0ms');
      expect(lines, hasLength(3));
    });

    testWidgets('stop ends the lines', (tester) async {
      monitor.start();
      await tick(tester, 230);
      monitor.stop();
      await tick(tester, 5000);
      await tick(tester, 5000);
      expect(lines, ['ui-stall 180ms']);
    });

    testWidgets('a second start does not double the ticks', (tester) async {
      monitor.start();
      monitor.start();
      expect(clockReads, 1);
      for (var i = 0; i < 4; i++) {
        await tick(tester, 50);
      }
      monitor.stop();
      // One read at start, one per tick of ONE timer.
      expect(clockReads, 5);
    });
  });

  group('perfSqlLabel', () {
    test('collapses whitespace and newlines and trims', () {
      expect(
        perfSqlLabel('  SELECT a,\n\t  b\n   FROM t\n  WHERE x = ?1  '),
        'SELECT a, b FROM t WHERE x = ?1',
      );
    });

    test('cuts at 120 characters', () {
      final long = 'SELECT ${'c, ' * 100}d FROM t';
      final label = perfSqlLabel(long);
      expect(label, hasLength(120));
      expect(long.startsWith(label), isTrue);
    });
  });

  group('SlowStatementLog', () {
    late List<String> lines;
    late BondDatabase db;

    setUpAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    });

    setUp(() {
      lines = [];
    });

    tearDown(() => db.close());

    BondDatabase open(Duration threshold) => BondDatabase(
          NativeDatabase.memory().interceptWith(
            SlowStatementLog(threshold: threshold, log: lines.add),
          ),
        );

    test('a select logs its SQL and never its arguments', () async {
      db = open(Duration.zero);
      await db.customSelect(
        'SELECT ?1 AS v',
        variables: [Variable<String>('private-argument-value')],
      ).get();
      expect(
        lines.any((l) =>
            l.startsWith('db-slow ') && l.contains(' select SELECT ?1 AS v')),
        isTrue,
      );
      expect(lines.where((l) => l.contains('private-argument-value')), isEmpty);
    });

    test('a write logs a non-select kind', () async {
      db = open(Duration.zero);
      await db.customInsert(
        'INSERT INTO app_prefs("key", value) VALUES (?1, ?2)',
        variables: [
          Variable<String>('perf_key'),
          Variable<String>('private-argument-value'),
        ],
      );
      expect(
        lines.any((l) => RegExp(r'^db-slow \d+ms insert INSERT INTO app_prefs')
            .hasMatch(l)),
        isTrue,
      );
      expect(lines.where((l) => l.contains('private-argument-value')), isEmpty);
    });

    test('a batch logs its count and its first statement', () async {
      db = open(Duration.zero);
      await db.batch((b) {
        b.customStatement(
          'INSERT INTO app_prefs("key", value) VALUES (?1, ?2)',
          ['a', 'one'],
        );
        b.customStatement(
          'INSERT INTO app_prefs("key", value) VALUES (?1, ?2)',
          ['b', 'two'],
        );
      });
      final batch = lines.where((l) => l.contains(' batch ')).toList();
      expect(batch, hasLength(1));
      expect(
        batch.single,
        matches(RegExp(r'^db-slow \d+ms batch \d+ statements: '
            r'INSERT INTO app_prefs\("key", value\) VALUES \(\?1, \?2\)$')),
      );
      expect(lines.where((l) => l.contains('one') || l.contains('two')),
          isEmpty);
    });

    // One line per kind, inside a transaction as most of the app's writes
    // are, and no argument on any of them: a kind that logged its `args`, or
    // took another kind's name, fails here.
    test('every kind is named, in a transaction, without its arguments',
        () async {
      db = open(Duration.zero);
      const secret = 'private-argument-value';
      await db.transaction(() async {
        await db.customInsert(
          'INSERT INTO app_prefs("key", value) VALUES (?1, ?2)',
          variables: [Variable<String>('k'), Variable<String>(secret)],
        );
        await db.customUpdate(
          'UPDATE app_prefs SET value = ?1 WHERE "key" = ?2',
          variables: [Variable<String>('$secret-2'), Variable<String>('k')],
        );
        await db.customStatement(
          'UPDATE app_prefs SET value = ?1 WHERE "key" = ?2',
          ['$secret-3', 'k'],
        );
        // The typed API: drift sends every custom write as an update or an
        // insert, so this is the one way to a `delete` line.
        await (db.delete(db.appPrefs)
              ..where((t) => t.key.equals('$secret-key')))
            .go();
      });
      for (final kind in ['insert', 'update', 'custom', 'delete', 'commit']) {
        expect(
          lines.where((l) => RegExp('^db-slow \\d+ms $kind ').hasMatch(l)),
          isNotEmpty,
          reason: 'no $kind line in $lines',
        );
      }
      // The first open and the transaction's BEGIN are both `open`.
      expect(lines.where((l) => l.contains('ms open -')), isNotEmpty);
      expect(lines.where((l) => l.contains(secret)), isEmpty);
    });

    test('a transaction that throws logs its rollback', () async {
      db = open(Duration.zero);
      await expectLater(
        db.transaction(() async {
          await db.customSelect('SELECT 1 AS v').get();
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect(lines.where((l) => l.contains('ms rollback -')), isNotEmpty);
    });

    test('nothing under the threshold is logged', () async {
      db = open(const Duration(hours: 1));
      await db.customSelect('SELECT 1 AS v').get();
      await db.customStatement(
        'INSERT INTO app_prefs("key", value) VALUES (\'k\', \'v\')',
      );
      expect(lines, isEmpty);
    });
  });
}
