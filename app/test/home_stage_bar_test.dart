import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/stage_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the five segments say, and — the load-bearing one — what they do NOT
/// do: a running stage is a static half-fill, and nothing on this screen
/// creeps or loops. A perpetual animation here is a widget suite that never
/// settles and a bar that claims to know how far through a model call it is.

HomeFeedRow _row({
  String triage = 'pending',
  String extract = 'pending',
  String storyline = 'pending',
  String draft = 'pending',
  String settle = 'pending',
  String outcome = 'pending',
}) =>
    HomeFeedRow(
      source: 'email',
      sourceMessageId: 'm1',
      conversationKey: 'c1',
      receivedAt: '2026-09-03T09:00:00Z',
      triageState: triage,
      extractState: extract,
      storylineState: storyline,
      draftState: draft,
      settleState: settle,
      outcome: outcome,
      dropped: false,
    );

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Row(children: [SizedBox(width: 300, child: child)]),
      ),
    );

void main() {
  group('fillFor', () {
    test('pending is an empty neutral segment', () {
      final look = HomeStageBar.fillFor('pending');
      expect(look.factor, 0);
      expect(look.track, bondToneColors[BondTone.neutral]!.background);
    });

    test('running is HALF, in the primary tone', () {
      final look = HomeStageBar.fillFor('running');
      expect(look.factor, HomeStageBar.runningFactor);
      expect(look.factor, 0.5);
      expect(look.track, bondToneColors[BondTone.primary]!.background);
      expect(look.fill, bondToneColors[BondTone.primary]!.foreground);
    });

    test('done fills the segment in the success tone', () {
      final look = HomeStageBar.fillFor('done');
      expect(look.factor, 1.0);
      expect(look.fill, bondToneColors[BondTone.success]!.foreground);
    });

    test('skipped is empty — an end state, not a failure', () {
      final look = HomeStageBar.fillFor('skipped');
      expect(look.factor, 0);
      expect(look.track, bondToneColors[BondTone.neutral]!.background);
      expect(HomeStageBar.isSkipped('skipped'), isTrue);
      expect(HomeStageBar.isSkipped('pending'), isFalse);
    });

    test('error fills the segment in the error tone', () {
      final look = HomeStageBar.fillFor('error');
      expect(look.factor, 1.0);
      expect(look.fill, bondToneColors[BondTone.error]!.foreground);
    });

    test('a state this build has never heard of renders as pending', () {
      final look = HomeStageBar.fillFor('quarantined');
      expect(look.factor, 0);
      expect(look.track, bondToneColors[BondTone.neutral]!.background);
    });
  });

  group('captionFor', () {
    test('names each running stage in the present tense', () {
      expect(
        HomeStageBar.captionFor(HomeStageBar.statesOf(_row(triage: 'running'))),
        'triaging…',
      );
      expect(
        HomeStageBar.captionFor(
          HomeStageBar.statesOf(_row(triage: 'done', extract: 'running')),
        ),
        'extracting…',
      );
      expect(
        HomeStageBar.captionFor(
          HomeStageBar.statesOf(
            _row(triage: 'done', extract: 'done', storyline: 'running'),
          ),
        ),
        'grouping…',
      );
      expect(
        HomeStageBar.captionFor(
          HomeStageBar.statesOf(
            _row(
              triage: 'done',
              extract: 'done',
              storyline: 'done',
              draft: 'running',
            ),
          ),
        ),
        'drafting…',
      );
      expect(
        HomeStageBar.captionFor(
          HomeStageBar.statesOf(
            _row(
              triage: 'done',
              extract: 'done',
              storyline: 'done',
              draft: 'skipped',
              settle: 'running',
            ),
          ),
        ),
        'settling…',
      );
    });

    test('is the FIRST running stage when two queues are working', () {
      expect(
        HomeStageBar.captionFor(
          HomeStageBar.statesOf(_row(triage: 'running', settle: 'running')),
        ),
        'triaging…',
      );
      // Drafting rides the same worker drain as extraction, so the two are
      // genuinely running at once on a busy pump — and extraction is the one
      // the draft is queued behind.
      expect(
        HomeStageBar.captionFor(
          HomeStageBar.statesOf(_row(extract: 'running', draft: 'running')),
        ),
        'extracting…',
      );
    });

    test('says nothing when nothing is running', () {
      expect(HomeStageBar.captionFor(HomeStageBar.statesOf(_row())), isNull);
      expect(
        HomeStageBar.captionFor(
          HomeStageBar.statesOf(
            _row(
              triage: 'done',
              extract: 'skipped',
              storyline: 'done',
              draft: 'skipped',
              settle: 'done',
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('the widget', () {
    test('the stages are the pipeline, in the order it runs them', () {
      expect(
        HomeStageBar.stages,
        ['triage', 'extract', 'storyline', 'draft', 'settle'],
      );
    });

    testWidgets('renders one segment per stage, keyed', (tester) async {
      await tester.pumpWidget(_host(HomeStageBar.forRow(_row())));

      for (final stage in HomeStageBar.stages) {
        expect(
          find.byKey(HomeStageBar.segmentKey(stage)),
          findsOneWidget,
          reason: '$stage has a segment',
        );
      }
    });

    testWidgets('forRow carries the draft stage onto the bar', (tester) async {
      await tester.pumpWidget(
        _host(HomeStageBar.forRow(_row(draft: 'running'))),
      );

      expect(
        tester.widget<HomeStageBar>(find.byType(HomeStageBar)).draftState,
        'running',
      );
      expect(find.text('drafting…'), findsOneWidget);
    });

    testWidgets('a message not worth answering outlines its draft segment',
        (tester) async {
      await tester.pumpWidget(
        _host(HomeStageBar.forRow(_row(triage: 'done', draft: 'skipped'))),
      );

      final decoration = tester
          .widget<AnimatedContainer>(
            find.byKey(HomeStageBar.segmentKey('draft')),
          )
          .decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
      // The neighbour it is decided against next to is still merely owed.
      final settle = tester
          .widget<AnimatedContainer>(
            find.byKey(HomeStageBar.segmentKey('settle')),
          )
          .decoration as BoxDecoration;
      expect(settle.border, isNull);
    });

    testWidgets('a running stage says so under the bar', (tester) async {
      await tester.pumpWidget(
        _host(HomeStageBar.forRow(_row(triage: 'done', extract: 'running'))),
      );

      expect(find.text('extracting…'), findsOneWidget);
    });

    testWidgets('a muted bar keeps its segments and drops the caption',
        (tester) async {
      await tester.pumpWidget(_host(
        HomeStageBar.forRow(_row(triage: 'running'), muted: true),
      ));

      // The segments are the diagnostic — a skipped extract is worth seeing on
      // a row the pipeline has finished with — and the narration is not.
      expect(find.byKey(HomeStageBar.segmentKey('triage')), findsOneWidget);
      expect(find.text('triaging…'), findsNothing);
      expect(
        tester
            .widget<Opacity>(find.byType(Opacity).first)
            .opacity,
        HomeStageBar.mutedOpacity,
      );
    });

    testWidgets('a running fill does not creep — it is the same half a second later',
        (tester) async {
      await tester.pumpWidget(_host(HomeStageBar.forRow(_row(triage: 'running'))));
      // Past the 240ms colour/fill animation, twice over. Anything that looped
      // would have moved between these two reads, and a suite pumping a screen
      // that owns this bar would never settle.
      await tester.pump(const Duration(milliseconds: 500));
      final first = tester
          .widget<AnimatedFractionallySizedBox>(
            find.descendant(
              of: find.byKey(HomeStageBar.segmentKey('triage')),
              matching: find.byType(AnimatedFractionallySizedBox),
            ),
          )
          .widthFactor;

      await tester.pump(const Duration(milliseconds: 500));
      final second = tester
          .widget<AnimatedFractionallySizedBox>(
            find.descendant(
              of: find.byKey(HomeStageBar.segmentKey('triage')),
              matching: find.byType(AnimatedFractionallySizedBox),
            ),
          )
          .widthFactor;

      expect(first, 0.5);
      expect(second, first);
    });
  });
}
