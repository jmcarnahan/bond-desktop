import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/providers/activity_provider.dart' show SyncStamps;
import 'package:bond_inbox/widgets/home_pulse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Inbox's pulse strip: three sentences and one dot.
///
/// The sentences are pure functions and most of this file tests them without a
/// pump, for `home_result_test.dart`'s reason — a narration nobody can test the
/// awkward cases of cheaply is a narration nobody writes them for. The widget's
/// own group pins the keys and the one word an idle pipeline gets.

final DateTime _now = DateTime.utc(2026, 9, 3, 12);

String _minutesAgo(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toIso8601String();

void main() {
  group('the work line', () {
    test('walks the stages in pipeline order, skipping the empty ones', () {
      expect(
        pulseWorkLine(const PipelinePulse(
          queued: {'storyline': 1, 'triage': 2},
          running: {'files': 3},
        )),
        'triaging 2 · grouping 1 · reading files 3',
        reason: 'the order is the pipeline, never the order the map was built',
      );
    });

    test('counts waiting and working together, per stage', () {
      expect(
        pulseWorkLine(const PipelinePulse(
          queued: {'extract': 2},
          running: {'extract': 1},
        )),
        'extracting 3',
      );
    });

    test('a stage nobody has queued anything for is not mentioned', () {
      expect(
        pulseWorkLine(const PipelinePulse(queued: {'draft': 0, 'embed': 1})),
        'indexing 1',
      );
    });

    test('an idle pipeline is null, not a row of noughts', () {
      expect(pulseWorkLine(const PipelinePulse()), isNull);
      expect(
        pulseWorkLine(const PipelinePulse(queued: {'triage': 0})),
        isNull,
      );
    });
  });

  group('the recent line', () {
    test('names each count that happened, in one order', () {
      expect(
        pulseRecentLine(const PipelinePulse(
          recentSettled: 5,
          recentDropped: 2,
          recentNeedsYou: 1,
        )),
        '5 settled · 2 dropped · 1 needs you',
      );
    });

    test('leaves out the zeros', () {
      expect(
        pulseRecentLine(const PipelinePulse(recentDropped: 2)),
        '2 dropped',
        reason: '"0 settled" is a claim about an absence nobody asked for',
      );
    });

    test('nothing at all is null', () {
      expect(pulseRecentLine(const PipelinePulse()), isNull);
    });
  });

  group('the sync line', () {
    String line({
      bool mail = false,
      bool teams = false,
      SyncStamps? stamps,
    }) =>
        syncLine(
          mailSyncing: mail,
          teamsSyncing: teams,
          stamps: stamps,
          now: _now,
        );

    test('a pull that is out outranks the stamps', () {
      // "Mail 4m ago" while a sync is running is the app reporting the last
      // answer as though it were the current one.
      final stamps = SyncStamps(mailIso: _minutesAgo(4));
      expect(line(mail: true, stamps: stamps), 'Syncing mail…');
      expect(line(teams: true, stamps: stamps), 'Syncing Teams…');
      expect(
        line(mail: true, teams: true, stamps: stamps),
        'Syncing mail and Teams…',
      );
    });

    test('otherwise it is the three stamps', () {
      expect(
        line(
          stamps: SyncStamps(
            mailIso: _minutesAgo(2),
            teamsIso: _minutesAgo(4),
            sweepIso: _minutesAgo(12),
          ),
        ),
        'Mail 2m ago · Teams 4m ago · Sweep 12m ago',
      );
    });

    test('a pass that has never run says so', () {
      // An install whose sweep has not run yet is a fact worth stating; a
      // blank in that place reads as a rendering bug.
      expect(
        line(stamps: SyncStamps(mailIso: _minutesAgo(2))),
        'Mail 2m ago · Teams never · Sweep never',
      );
      expect(line(), 'Mail never · Teams never · Sweep never');
    });
  });

  group('the strip', () {
    Future<void> pump(
      WidgetTester tester, {
      PipelinePulse? pulse,
      bool mailSyncing = false,
      bool teamsSyncing = false,
      SyncStamps? stamps,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PipelinePulseStrip(
            pulse: pulse,
            mailSyncing: mailSyncing,
            teamsSyncing: teamsSyncing,
            stamps: stamps,
            now: _now,
          ),
        ),
      ));
    }

    testWidgets('every segment is keyed, and the work one is hoverable',
        (tester) async {
      await pump(
        tester,
        pulse: const PipelinePulse(
          queued: {'triage': 2},
          running: {'storyline': 1},
          recentSettled: 5,
          inFlight: 3,
        ),
        stamps: SyncStamps(mailIso: _minutesAgo(2)),
      );

      expect(find.byKey(PipelinePulseStrip.stripKey), findsOneWidget);
      expect(find.text('triaging 2 · grouping 1'), findsOneWidget);
      expect(find.text('Last 10 min: 5 settled'), findsOneWidget);
      expect(find.byKey(PipelinePulseStrip.syncKey), findsOneWidget);
      expect(find.byTooltip('1 being worked · 2 waiting'), findsOneWidget);
    });

    testWidgets('nothing moving is one word, and never a spinner',
        (tester) async {
      await pump(tester, pulse: const PipelinePulse());

      expect(find.text('Idle'), findsOneWidget);
      expect(find.byKey(PipelinePulseStrip.recentKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an unread pulse still says where the mail is coming from',
        (tester) async {
      // Null is the first frame, before any read has landed. The stamps are
      // already known by then, and a strip that rendered nothing would make
      // the header jump when it arrived.
      await pump(tester, stamps: SyncStamps(mailIso: _minutesAgo(2)));

      expect(find.text('Idle'), findsOneWidget);
      expect(find.byKey(PipelinePulseStrip.syncKey), findsOneWidget);
    });
  });
}
