import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/widgets/home_feed_row.dart';
import 'package:bond_inbox/widgets/source_glyph.dart';
import 'package:bond_inbox/widgets/stage_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One feed row: what it shows, and what it opens.
///
/// The result cell is where the judgements live — a dropped row says why and
/// nothing else, a needed one says so, a filed one links where it went — so
/// most of this file is about which of those a row is allowed to claim at once.

final DateTime _now = DateTime.utc(2026, 9, 3, 12);

HomeFeedRow _row({
  String source = 'email',
  String id = 'm1',
  String conversationKey = 'c1',
  String triage = 'done',
  String extract = 'done',
  String storyline = 'done',
  String draft = 'done',
  String settle = 'done',
  String outcome = 'pending',
  bool dropped = false,
  String? dropReason,
  String? storylineId,
  String? storylineTitle,
  bool needsYou = false,
  String? urgency,
  String? subject = 'Launch date',
  String? fromName = 'Sarah Chen',
  String? fromAddress,
}) =>
    HomeFeedRow(
      source: source,
      sourceMessageId: id,
      conversationKey: conversationKey,
      receivedAt: '2026-09-03T09:00:00Z',
      triageState: triage,
      extractState: extract,
      storylineState: storyline,
      draftState: draft,
      settleState: settle,
      outcome: outcome,
      dropped: dropped,
      dropReason: dropReason,
      storylineId: storylineId,
      storylineTitle: storylineTitle,
      needsYou: needsYou,
      urgency: urgency,
      subject: subject,
      fromName: fromName,
      fromAddress: fromAddress,
    );

/// Loose width, like the pane gives it — a Scaffold body's tight constraints
/// would hide a regression in the row's own column grid.
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Row(children: [SizedBox(width: 1100, child: child)]),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  HomeFeedRow row, {
  void Function(String, String)? onOpenThread,
  void Function(String)? onOpenStoryline,
  bool animateIn = false,
}) async {
  // A desktop pane's width. The row is a fixed grid with two flexible cells,
  // and the default 800px surface is narrower than the grid it is drawn for.
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_host(HomeFeedRowTile(
    row: row,
    now: _now,
    animateIn: animateIn,
    onOpenThread: onOpenThread ?? (_, _) {},
    onOpenStoryline: onOpenStoryline ?? (_) {},
  )));
}

void main() {
  testWidgets('renders the sender, the subject and the age', (tester) async {
    await _pump(tester, _row());

    expect(find.text('Sarah Chen'), findsOneWidget);
    expect(find.text('Launch date'), findsOneWidget);
    expect(find.text('3h ago'), findsOneWidget);
  });

  testWidgets('falls back through the sender fields to a sentence',
      (tester) async {
    await _pump(tester, _row(fromName: null, fromAddress: 'a@b.com'));
    expect(find.text('a@b.com'), findsOneWidget);

    await _pump(tester, _row(fromName: null, fromAddress: null));
    expect(find.text('(no sender)'), findsOneWidget);
  });

  testWidgets('a long subject is capped at two lines', (tester) async {
    await _pump(tester, _row(subject: 'A subject long enough to wrap ' * 12));

    final subject = tester.widget<Text>(
      find.textContaining('A subject long enough to wrap'),
    );
    expect(subject.maxLines, 2);
    expect(subject.overflow, TextOverflow.ellipsis);
  });

  testWidgets('both connectors are labelled', (tester) async {
    await _pump(tester, _row(source: 'teams'));
    expect(find.text(sourceChipPrefix('teams')), findsOneWidget);

    await _pump(tester, _row());
    expect(find.text(sourceChipPrefix('email')), findsOneWidget);
  });

  testWidgets('every stage state renders a segment', (tester) async {
    await _pump(
      tester,
      _row(
        triage: 'done',
        extract: 'running',
        storyline: 'skipped',
        draft: 'pending',
        settle: 'error',
      ),
    );

    for (final stage in HomeStageBar.stages) {
      expect(find.byKey(HomeStageBar.segmentKey(stage)), findsOneWidget);
    }
  });

  testWidgets('a finished row mutes its bar; a moving one does not',
      (tester) async {
    await _pump(tester, _row(outcome: 'done'));
    expect(
      tester.widget<HomeStageBar>(find.byType(HomeStageBar)).muted,
      isTrue,
    );

    await _pump(tester, _row(outcome: 'pending'));
    expect(
      tester.widget<HomeStageBar>(find.byType(HomeStageBar)).muted,
      isFalse,
    );
  });

  group('the result cell', () {
    testWidgets('a dropped row shows its reason and nothing else',
        (tester) async {
      await _pump(
        tester,
        _row(
          dropped: true,
          dropReason: 'newsletter',
          outcome: 'dropped',
          // Both of these would render on a row that was not dropped. Neither
          // may argue with the drop.
          needsYou: true,
          storylineId: 's1',
          storylineTitle: 'Website redesign',
        ),
      );

      expect(find.text('Newsletter'), findsOneWidget);
      expect(find.text('Needs You'), findsNothing);
      expect(find.text('Website redesign'), findsNothing);
    });

    testWidgets('an unmapped reason reads as itself, opened up',
        (tester) async {
      await _pump(
        tester,
        _row(dropped: true, dropReason: 'vendor_spam', outcome: 'dropped'),
      );

      expect(find.text('vendor spam'), findsOneWidget);
    });

    test('the drop labels are pure', () {
      expect(HomeFeedRowTile.dropLabel('fyi'), 'FYI');
      expect(HomeFeedRowTile.dropLabel('no_reply'), 'No reply needed');
      expect(HomeFeedRowTile.dropLabel('gated'), 'Filtered');
      expect(HomeFeedRowTile.dropLabel('brand_new_reason'), 'brand new reason');
      expect(HomeFeedRowTile.dropLabel(null), 'Dropped');
    });

    testWidgets('needs-you and a storyline can both be true', (tester) async {
      await _pump(
        tester,
        _row(
          needsYou: true,
          storylineId: 's1',
          storylineTitle: 'Website redesign',
        ),
      );

      expect(find.text('Needs You'), findsOneWidget);
      expect(find.text('Website redesign'), findsOneWidget);
    });

    testWidgets('a row with nothing decided shows a dash', (tester) async {
      await _pump(tester, _row(triage: 'running', settle: 'pending'));

      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('a title with no storyline behind it is not a link',
        (tester) async {
      await _pump(tester, _row(storylineTitle: 'Website redesign'));

      expect(find.text('Website redesign'), findsNothing);
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('taps', () {
    testWidgets('the row opens the thread, with its source', (tester) async {
      final opened = <(String, String)>[];
      await _pump(
        tester,
        _row(source: 'teams', conversationKey: 'chat-9'),
        onOpenThread: (source, key) => opened.add((source, key)),
      );

      await tester.tap(find.text('Launch date'));
      expect(opened, [('teams', 'chat-9')]);
    });

    testWidgets('the storyline name opens the storyline, NOT the thread',
        (tester) async {
      final threads = <String>[];
      final storylines = <String>[];
      await _pump(
        tester,
        _row(storylineId: 's1', storylineTitle: 'Website redesign'),
        onOpenThread: (_, key) => threads.add(key),
        onOpenStoryline: storylines.add,
      );

      await tester.tap(find.text('Website redesign'));
      expect(storylines, ['s1']);
      expect(
        threads,
        isEmpty,
        reason: 'the inner InkWell wins the arena over the row it sits in',
      );
    });
  });

  testWidgets('a row that did not opt in renders whole on its first frame',
      (tester) async {
    await _pump(tester, _row());

    // No pump past the first: a row read off a page has nothing to animate,
    // and a scroll back through history must not replay an entrance.
    final opacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity).first,
    );
    final slide = tester.widget<AnimatedSlide>(find.byType(AnimatedSlide).first);
    expect(opacity.opacity, 1);
    expect(slide.offset, Offset.zero);
  });
}
