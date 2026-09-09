import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/home_feed_row.dart';
import 'package:bond_inbox/widgets/source_glyph.dart';
import 'package:bond_inbox/widgets/stage_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One feed row: what it shows, and what it opens.
///
/// The Result cell is where the judgements live — a dropped row says why and
/// nothing else, a needed one says so, a filed one links where it went — and
/// the Ask · Summary cell beside it is where the WORDS live. Most of this file
/// is about which of those a row is allowed to claim at once. WHICH label and
/// which reason a row gets is `home_result_test.dart`'s question; this file is
/// about the dressing, the two extra cells, the fold, and the four nested
/// gestures.

final DateTime _now = DateTime.utc(2026, 9, 3, 12);

HomeFeedRow _row({
  String source = 'email',
  String id = 'm1',
  String conversationKey = 'c1',
  String receivedAt = '2026-09-03T09:00:00Z',
  String? summary,
  String? ctaText,
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
  String? updatedAt,
  String? needsYouReason,
  String? gateReason,
  String? bucket,
  String? bucketReason,
  String? storylineEvidence,
  String? storylineAddedBy,
  bool workOpen = false,
}) =>
    HomeFeedRow(
      source: source,
      sourceMessageId: id,
      conversationKey: conversationKey,
      receivedAt: receivedAt,
      summary: summary,
      ctaText: ctaText,
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
      // A minute ago, so the ordinary row is neither stuck nor about to be.
      updatedAt: updatedAt ?? '2026-09-03T11:59:00Z',
      needsYouReason: needsYouReason,
      gateReason: gateReason,
      bucket: bucket,
      bucketReason: bucketReason,
      storylineEvidence: storylineEvidence,
      storylineAddedBy: storylineAddedBy,
      workOpen: workOpen,
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
  void Function(String, String)? onRetry,
  void Function(String, String)? onOpenHistory,
  bool animateIn = false,
  bool compact = false,
  DateTime? now,
}) async {
  // A desktop pane's width. The row is a fixed grid with three flexible cells,
  // and the default 800px surface is narrower than the grid it is drawn for.
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_host(HomeFeedRowTile(
    row: row,
    now: now ?? _now,
    animateIn: animateIn,
    compact: compact,
    onOpenThread: onOpenThread ?? (_, _) {},
    onOpenStoryline: onOpenStoryline ?? (_) {},
    onRetry: onRetry,
    onOpenHistory: onOpenHistory,
  )));
}

void main() {
  testWidgets('renders the sender, the subject and the stamp', (tester) async {
    await _pump(tester, _row());

    expect(find.text('Sarah Chen'), findsOneWidget);
    expect(find.text('Launch date'), findsOneWidget);
    expect(find.byKey(HomeFeedRowTile.whenKey(_row())), findsOneWidget);
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
      expect(find.text('Needs you'), findsNothing);
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
          outcome: 'done',
          needsYou: true,
          storylineId: 's1',
          storylineTitle: 'Website redesign',
        ),
      );

      // ONE chip on the Result cell's first line, the reason one column over,
      // and the filing on the line UNDER the chip — still tappable, so a row
      // that is both does not have to give one of them up.
      expect(find.text('Needs you'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(HomeFeedRowTile.askKey(_row())))
            .textSpan!
            .toPlainText(),
        'the app thinks this wants you',
      );
      expect(find.text('Website redesign'), findsOneWidget);
    });

    testWidgets('a row with nothing decided says so', (tester) async {
      await _pump(tester, _row(outcome: 'done', draft: 'skipped'));

      expect(find.text('Nothing to do'), findsOneWidget);
    });

    testWidgets('a title with no storyline behind it is not a link',
        (tester) async {
      await _pump(
        tester,
        _row(
          outcome: 'done',
          draft: 'skipped',
          storylineTitle: 'Website redesign',
        ),
      );

      expect(find.text('Website redesign'), findsNothing);
      expect(find.text('Nothing to do'), findsOneWidget);
    });

    testWidgets('the sentence carries a tooltip with the full reason',
        (tester) async {
      await _pump(
        tester,
        _row(
          outcome: 'dropped',
          dropped: true,
          dropReason: 'gated',
          gateReason: 'sender_muted',
        ),
      );

      // The cell is two columns wide and most reasons are longer than that,
      // so the whole sentence has to live somewhere a hover can reach.
      expect(
        find.byTooltip('Dropped: Filtered — sender muted'),
        findsOneWidget,
      );
      expect(
        find.byKey(HomeFeedRowTile.resultTextKey(_row())),
        findsOneWidget,
      );
    });

    testWidgets('a filed row is the label and the link, and no evidence',
        (tester) async {
      final row = _row(
        outcome: 'done',
        draft: 'skipped',
        storylineId: 's1',
        storylineTitle: 'Website redesign',
        storylineEvidence: 'same launch thread',
      );
      await _pump(tester, row);

      expect(find.text('Filed in '), findsOneWidget);
      expect(find.text('Website redesign'), findsOneWidget);
      // The evidence is the reason clause, and inside a fixed 168 px it only
      // ever ellipsised the storyline's name away. It is on the tooltip and in
      // the Ask cell, which is where the row's words live.
      expect(find.text(' — same launch thread'), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(HomeFeedRowTile.askKey(row)))
            .textSpan!
            .toPlainText(),
        'same launch thread',
      );
    });
  });

  group('the ask cell', () {
    /// The cell is a `Text.rich` in both layouts — compact prefixes a tone dot
    /// — so the words come off the span rather than off `data`, which is null
    /// on every rich Text.
    String askText(WidgetTester tester, HomeFeedRow row) => tester
        .widget<Text>(find.byKey(HomeFeedRowTile.askKey(row)))
        .textSpan!
        .toPlainText();

    TextStyle askStyle(WidgetTester tester, HomeFeedRow row) => tester
        .widget<Text>(find.byKey(HomeFeedRowTile.askKey(row)))
        .style!;

    testWidgets('a needs-you row shows the thread\'s ask, drawn as one',
        (tester) async {
      final row = _row(
        outcome: 'done',
        needsYou: true,
        needsYouReason: 'asks you to confirm Thursday',
        ctaText: 'Confirm Thursday with Sarah',
        summary: 'Sarah proposes moving the launch',
      );
      await _pump(tester, row);

      expect(
        askText(tester, row),
        'Confirm Thursday with Sarah',
        reason: 'the ask is per THREAD and outranks both the reason and the '
            'summary of one message on it',
      );
      expect(askStyle(tester, row).fontWeight, FontWeight.w600);
    });

    testWidgets('a settled row shows the message summary, quietly',
        (tester) async {
      final row = _row(
        outcome: 'done',
        draft: 'skipped',
        summary: 'A receipt for the annual licence',
      );
      await _pump(tester, row);

      expect(askText(tester, row), 'A receipt for the annual licence');
      expect(askStyle(tester, row).fontWeight, isNot(FontWeight.w600));
      expect(askStyle(tester, row).color, BondColors.inkSecondary);
    });

    testWidgets('a row with neither falls back to the reason clause',
        (tester) async {
      // A gate-dropped message never reached triage, so it has no summary at
      // all — and the gate's own words are worth more here than a blank.
      final row = _row(
        outcome: 'dropped',
        dropped: true,
        dropReason: 'gated',
        gateReason: 'sender_muted',
      );
      await _pump(tester, row);

      expect(askText(tester, row), 'sender muted');
    });

    testWidgets('a dropped needs-you row is not an ask', (tester) async {
      final row = _row(
        outcome: 'dropped',
        dropped: true,
        dropReason: 'newsletter',
        needsYou: true,
        ctaText: 'Reply to the newsletter',
        summary: 'This week in widgets',
      );
      await _pump(tester, row);

      expect(askText(tester, row), 'This week in widgets');
      expect(askStyle(tester, row).fontWeight, isNot(FontWeight.w600));
    });

    testWidgets('the whole of it is on the tooltip', (tester) async {
      final row = _row(
        outcome: 'done',
        draft: 'skipped',
        summary: 'A receipt for the annual licence',
      );
      await _pump(tester, row);

      expect(
        find.byTooltip('A receipt for the annual licence'),
        findsOneWidget,
      );
    });
  });

  group('the when cell', () {
    // Local rather than UTC on purpose: the stamp is formatted in the reader's
    // own zone, and a fixture pinned in UTC would assert a different string in
    // every timezone this suite runs in.
    final noon = DateTime(2026, 9, 3, 12);

    testWidgets('today is the time alone', (tester) async {
      final row = _row(receivedAt: DateTime(2026, 9, 3, 9, 5).toIso8601String());
      await _pump(tester, row, now: noon);

      expect(
        tester.widget<Text>(find.byKey(HomeFeedRowTile.whenKey(row))).data,
        '9:05 AM',
        reason: "today's day is the one a reader can infer without being told",
      );
    });

    testWidgets('any other day carries the day with it', (tester) async {
      final row = _row(receivedAt: DateTime(2026, 9, 2, 9, 5).toIso8601String());
      await _pump(tester, row, now: noon);

      expect(
        tester.widget<Text>(find.byKey(HomeFeedRowTile.whenKey(row))).data,
        'Sep 2, 9:05 AM',
      );
    });

    testWidgets('the tooltip carries the full stamp AND the age',
        (tester) async {
      final row = _row(receivedAt: DateTime(2026, 9, 3, 9, 5).toIso8601String());
      await _pump(tester, row, now: noon);

      // The age is what "is this current?" is answered with, and the stamp is
      // what the column is scanned by. The hover is where both live.
      expect(find.byTooltip('Sep 3, 9:05 AM · 2h ago'), findsOneWidget);
    });
  });

  group('the folded row', () {
    testWidgets('is one line: who, what, the ask, and when', (tester) async {
      final row = _row(
        outcome: 'done',
        needsYou: true,
        ctaText: 'Confirm Thursday with Sarah',
        storylineId: 's1',
        storylineTitle: 'Website redesign',
      );
      await _pump(tester, row, compact: true, onOpenHistory: (_, _) {});

      expect(find.text('Sarah Chen'), findsOneWidget);
      expect(find.text('Launch date'), findsOneWidget);
      expect(find.byKey(HomeFeedRowTile.askKey(row)), findsOneWidget);
      expect(find.byKey(HomeFeedRowTile.whenKey(row)), findsOneWidget);
      // No bar and no verdict: this layout is what the pane folds to with a
      // thread open beside it, and the thread beside carries both.
      expect(find.byKey(HomeFeedRowTile.historyBarKey(row)), findsNothing);
      expect(find.byKey(HomeFeedRowTile.historyCellKey(row)), findsNothing);
      expect(find.text('Needs you'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an ask carries its tone as a dot, a summary does not',
        (tester) async {
      String askText(HomeFeedRow row) => tester
          .widget<Text>(find.byKey(HomeFeedRowTile.askKey(row)))
          .textSpan!
          .toPlainText();

      final asking = _row(
        outcome: 'done',
        needsYou: true,
        ctaText: 'Confirm Thursday with Sarah',
      );
      await _pump(tester, asking, compact: true);
      // The chip is what colours a needs-you row in the wide layout, and there
      // is no Result cell here to put one in.
      expect(askText(asking), '● Confirm Thursday with Sarah');

      final quiet = _row(
        outcome: 'done',
        draft: 'skipped',
        summary: 'A receipt for the annual licence',
      );
      await _pump(tester, quiet, compact: true);
      expect(askText(quiet), 'A receipt for the annual licence');
    });

    testWidgets('the wide row keeps the dot off — the chip carries it there',
        (tester) async {
      final row = _row(
        outcome: 'done',
        needsYou: true,
        ctaText: 'Confirm Thursday with Sarah',
      );
      await _pump(tester, row);

      expect(
        tester
            .widget<Text>(find.byKey(HomeFeedRowTile.askKey(row)))
            .textSpan!
            .toPlainText(),
        'Confirm Thursday with Sarah',
      );
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

    testWidgets('four nested gestures, and each tap fires exactly one',
        (tester) async {
      final threads = <String>[];
      final storylines = <String>[];
      final retries = <(String, String)>[];
      final histories = <(String, String)>[];
      // Stalled AND filed: every affordance the cell has, on one row.
      final row = _row(
        id: 'm9',
        outcome: 'pending',
        settle: 'pending',
        updatedAt: '2026-09-03T11:30:00Z',
        storylineId: 's1',
        storylineTitle: 'Website redesign',
      );
      await _pump(
        tester,
        row,
        onOpenThread: (_, key) => threads.add(key),
        onOpenStoryline: storylines.add,
        onRetry: (source, id) => retries.add((source, id)),
        onOpenHistory: (source, id) => histories.add((source, id)),
      );

      expect(find.text('Stalled'), findsOneWidget);

      // All four counted after every tap: the failure worth catching is a
      // gesture that fires its own callback AND the row's underneath it.
      void expectOnly(String fired) {
        expect(threads, fired == 'thread' ? ['c1'] : isEmpty);
        expect(storylines, fired == 'storyline' ? ['s1'] : isEmpty);
        expect(retries, fired == 'retry' ? [('email', 'm9')] : isEmpty);
        expect(histories, fired == 'history' ? [('email', 'm9')] : isEmpty);
        threads.clear();
        storylines.clear();
        retries.clear();
        histories.clear();
      }

      await tester.tap(find.text('Launch date'));
      expectOnly('thread');

      // The bar and the sentence are two doors onto the same story, and the
      // row underneath must not open behind either.
      await tester.tap(find.byKey(HomeFeedRowTile.historyBarKey(row)));
      expectOnly('history');

      // Near the left edge of the cell rather than its centre: the storyline
      // link and Retry live at the right of the same cell and win the arena
      // where they sit, which is the whole point of the nesting.
      final cell = find.byKey(HomeFeedRowTile.historyCellKey(row));
      await tester.tapAt(tester.getTopLeft(cell) + const Offset(4, 8));
      expectOnly('history');

      await tester.tap(find.text('Website redesign'));
      expectOnly('storyline');

      await tester.tap(find.byKey(HomeFeedRowTile.retryKey(row)));
      expectOnly('retry');
    });

    testWidgets('no history target without a handler', (tester) async {
      final row = _row(id: 'm9');
      await _pump(tester, row);

      expect(find.byKey(HomeFeedRowTile.historyBarKey(row)), findsNothing);
      expect(find.byKey(HomeFeedRowTile.historyCellKey(row)), findsNothing);
    });

    testWidgets('no Retry when there is nothing to retry', (tester) async {
      await _pump(
        tester,
        _row(outcome: 'done', draft: 'skipped'),
        onRetry: (_, _) {},
      );

      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('no Retry without a handler', (tester) async {
      // The archive pane passes none: a dropped row is Restore's business.
      await _pump(
        tester,
        _row(
          outcome: 'pending',
          settle: 'pending',
          updatedAt: '2026-09-03T11:30:00Z',
        ),
      );

      expect(find.text('Stalled'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
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
