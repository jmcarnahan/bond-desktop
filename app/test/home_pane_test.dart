import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/models/home_sort.dart';
import 'package:bond_inbox/providers/activity_provider.dart' show SyncStamps;
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/attachment_search_tile.dart';
import 'package:bond_inbox/widgets/home_feed_row.dart';
import 'package:bond_inbox/widgets/home_metrics.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/home_pulse.dart';
import 'package:bond_inbox/widgets/stage_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Inbox pane as a whole: the numbers over the table — which are also its
/// filter — the strips between them, and what the table does at its two ends.
///
/// Pure — every value is a prop, so nothing here needs a container or a
/// database.

final DateTime _now = DateTime.utc(2026, 9, 3, 12);

HomeFeedRow _row(int index) => HomeFeedRow(
      source: 'email',
      sourceMessageId: 'm$index',
      conversationKey: 'c$index',
      receivedAt: '2026-09-03T09:00:00Z',
      triageState: 'done',
      extractState: 'done',
      storylineState: 'done',
      draftState: 'done',
      settleState: 'done',
      outcome: 'done',
      dropped: false,
      subject: 'Subject $index',
      fromName: 'Sender $index',
    );

/// A search result over [_row], found by meaning unless told otherwise.
///
/// The pane reads nothing but the row, so the numbers here are only plausible
/// — what they pin is that ONE list of them renders as one list.
SearchHit _hit(
  int index, {
  double score = 0.9,
  double? distance = 0.1,
  double? bm25,
  MatchedBy matchedBy = MatchedBy.meaning,
}) =>
    SearchHit(
      row: _row(index),
      score: score,
      distance: distance,
      bm25: bm25,
      matchedBy: matchedBy,
    );

/// A result only the words found: no vector, which is how gate-dropped mail
/// arrives.
SearchHit _wordHit(int index) => _hit(
      index,
      score: 0.4,
      distance: null,
      bm25: 3.2,
      matchedBy: MatchedBy.words,
    );

AttachmentChunkHit _doc({
  String name = 'Q3 forecast.xlsx',
  String locator = 'Sheet Revenue rows 1-40',
  String text = 'Renewal at 4.25% fixed for sixty months.',
  String attachmentId = 'a1',
  String? conversationKey = 'c7',
}) {
  return AttachmentChunkHit(
    ref: AttachmentRef(
      source: 'email',
      messageId: 'm7',
      attachmentId: attachmentId,
      name: name,
      conversationKey: conversationKey,
    ),
    chunkId: 1,
    seq: 0,
    locator: locator,
    text: text,
    senderName: 'Dana Whitfield',
    outbound: false,
    receivedAt: '2026-09-03T09:00:00Z',
    distance: 0.2,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  List<HomeFeedRow> rows = const [],
  HomeMetrics? metrics,
  List<HotStoryline> hot = const [],
  HomeFilter filter = HomeFilter.fromOthers,
  HomeSort sort = HomeSort.newest,
  String? sourceFilter,
  ValueChanged<HomeFilter>? onFilter,
  ValueChanged<HomeSort>? onSort,
  ValueChanged<String?>? onSelectSource,
  PipelinePulse? pulse,
  bool mailSyncing = false,
  bool teamsSyncing = false,
  SyncStamps? stamps,
  /// Narrows the pane itself rather than the window: the fold is decided on
  /// the width the TABLE gets, which is what a thread beside it takes away.
  double? paneWidth,
  bool loaded = true,
  bool loadingMore = false,
  bool atEnd = false,
  String? loadError,
  int pendingNewCount = 0,
  Set<String> entering = const {},
  Set<String> fading = const {},
  Set<String> collapsing = const {},
  void Function(String, String)? onOpenThread,
  void Function(String)? onOpenStoryline,
  VoidCallback? onLoadMore,
  VoidCallback? onReleasePending,
  void Function(bool)? onAnchoredChanged,
  HomeSearch? search,
  bool searching = false,
  String? searchNotice,
  void Function(String)? onSearch,
  VoidCallback? onExitSearch,
  void Function(String, String)? onRetry,
  void Function(String, String)? onOpenHistory,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final pane = HomePane(
        rows: rows,
        metrics: metrics,
        hotStorylines: hot,
        filter: filter,
        onFilter: onFilter ?? (_) {},
        sort: sort,
        onSort: onSort ?? (_) {},
        sourceFilter: sourceFilter,
        onSelectSource: onSelectSource ?? (_) {},
        pulse: pulse,
        mailSyncing: mailSyncing,
        teamsSyncing: teamsSyncing,
        stamps: stamps,
        loaded: loaded,
        loadingMore: loadingMore,
        atEnd: atEnd,
        loadError: loadError,
        pendingNewCount: pendingNewCount,
        entering: entering,
        fading: fading,
        collapsing: collapsing,
        now: _now,
        onOpenThread: onOpenThread ?? (_, _) {},
        onOpenStoryline: onOpenStoryline ?? (_) {},
        onLoadMore: onLoadMore ?? () {},
        onReleasePending: onReleasePending,
        onAnchoredChanged: onAnchoredChanged,
        search: search,
        searching: searching,
        searchNotice: searchNotice,
        onSearch: onSearch,
        onExitSearch: onExitSearch,
        onRetry: onRetry,
        onOpenHistory: onOpenHistory,
      );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: paneWidth == null
          ? pane
          : Row(children: [SizedBox(width: paneWidth, child: pane)]),
    ),
  ));
}

void main() {
  group('the tiles', () {
    const numbers = HomeMetrics(
      emails: 41,
      teams: 7,
      urgent: 3,
      dropped: 12,
      needsYou: 5,
      inFlight: 8,
      errored: 2,
      total: 48,
    );

    testWidgets('show all eight figures, processed net of what is in flight',
        (tester) async {
      await _pump(
        tester,
        metrics: const HomeMetrics(
          emails: 41,
          teams: 7,
          urgent: 3,
          dropped: 12,
          needsYou: 5,
          inFlight: 8,
          errored: 2,
          total: 48,
        ),
      );

      expect(find.text('Emails'), findsOneWidget);
      expect(find.text('41'), findsOneWidget);
      expect(find.text('Teams'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('Processed'), findsOneWidget);
      expect(find.text('40'), findsOneWidget);
      expect(find.text('Needs You'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('Dropped'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('In flight'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text('Errors'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('the bar names the window the seven are read over',
        (tester) async {
      // Seven zeros with no stated period look like a broken pipeline; the
      // same seven with "Last 7 days" beside them look like a quiet week.
      await _pump(tester, metrics: const HomeMetrics());
      expect(find.byKey(HomeMetricsBar.windowKey), findsOneWidget);
      expect(
        find.text(homeMetricsWindowLabel(homeMetricsWindow)),
        findsOneWidget,
      );
      expect(find.text('Last 7 days'), findsOneWidget);
    });

    testWidgets('Needs You comes first, and a rule separates it from the rest',
        (tester) async {
      await _pump(tester, metrics: numbers);

      final pile = tester.getTopLeft(
        find.byKey(HomeMetricsBar.tileKey('needs-you')),
      );
      final rule = tester.getTopLeft(find.byKey(HomeMetricsBar.dividerKey));
      final firstOfSeven = tester.getTopLeft(
        find.byKey(HomeMetricsBar.tileKey('emails')),
      );

      // A pile to burn down and a readout of activity are two kinds of number,
      // and eight in a row would invite the reader to compare them.
      expect(pile.dx, lessThan(rule.dx));
      expect(rule.dx, lessThan(firstOfSeven.dx));
      // The caption belongs to the seven, so it comes after the rule too.
      expect(
        tester.getTopLeft(find.byKey(HomeMetricsBar.windowKey)).dx,
        greaterThan(rule.dx),
      );
    });

    testWidgets('the pile colours its count only when there is one',
        (tester) async {
      BondStatTile pileTile(WidgetTester tester) => tester
          .widget<BondStatTile>(find.byKey(HomeMetricsBar.tileKey('needs-you')));

      await _pump(tester, metrics: numbers);
      expect(pileTile(tester).valueColor, BondColors.attention);

      // A coloured nought is an alarm about the absence of work.
      await _pump(tester, metrics: const HomeMetrics(total: 48, inFlight: 8));
      expect(pileTile(tester).valueColor, isNull);
    });

    testWidgets('In flight carries the stalled count only when there is one',
        (tester) async {
      await _pump(
        tester,
        metrics: const HomeMetrics(inFlight: 11, stalled: 3, total: 20),
      );
      expect(find.text('3 stalled'), findsOneWidget);
      expect(
        tester
            .widgetList<BondStatTile>(find.byType(BondStatTile))
            .firstWhere((tile) => tile.label == 'In flight')
            .valueColor,
        BondColors.error,
      );

      // Eleven in flight and none of them stuck is the healthy shape, and it
      // must not read as an alarm.
      await _pump(
        tester,
        metrics: const HomeMetrics(inFlight: 11, total: 20),
      );
      expect(find.textContaining('stalled'), findsNothing);
      expect(
        tester
            .widgetList<BondStatTile>(find.byType(BondStatTile))
            .firstWhere((tile) => tile.label == 'In flight')
            .valueColor,
        isNull,
      );
    });

    testWidgets('Errors is coloured only when non-zero', (tester) async {
      await _pump(tester, metrics: const HomeMetrics(errored: 2, total: 9));
      expect(
        tester
            .widgetList<BondStatTile>(find.byType(BondStatTile))
            .firstWhere((tile) => tile.label == 'Errors')
            .valueColor,
        BondColors.error,
      );

      await _pump(tester, metrics: const HomeMetrics(total: 9));
      expect(
        tester
            .widgetList<BondStatTile>(find.byType(BondStatTile))
            .firstWhere((tile) => tile.label == 'Errors')
            .valueColor,
        isNull,
      );
    });

    testWidgets('colour Urgent only when there is something urgent',
        (tester) async {
      await _pump(tester, metrics: const HomeMetrics(urgent: 2, total: 2));
      expect(
        tester
            .widgetList<BondStatTile>(find.byType(BondStatTile))
            .firstWhere((tile) => tile.label == 'Urgent')
            .valueColor,
        BondColors.error,
      );

      await _pump(tester, metrics: const HomeMetrics(total: 2));
      expect(
        tester
            .widgetList<BondStatTile>(find.byType(BondStatTile))
            .firstWhere((tile) => tile.label == 'Urgent')
            .valueColor,
        isNull,
        reason: 'a red nought is an alarm about the absence of a problem',
      );
    });

    testWidgets('are absent until the first read lands', (tester) async {
      await _pump(tester);
      expect(find.byType(BondStatTile), findsNothing);
    });
  });

  group('the hot strip', () {
    testWidgets('is nothing at all when there is nothing hot', (tester) async {
      await _pump(tester);
      expect(find.text('HOT RIGHT NOW'), findsNothing);
    });

    testWidgets('names each storyline with its count and opens it',
        (tester) async {
      final opened = <String>[];
      await _pump(
        tester,
        hot: const [
          HotStoryline(
            id: 's1',
            title: 'Website redesign',
            messageCount: 6,
            lastAt: '2026-09-03T09:00:00Z',
          ),
        ],
        onOpenStoryline: opened.add,
      );

      expect(find.text('HOT RIGHT NOW'), findsOneWidget);
      await tester.tap(find.text('Website redesign · 6'));
      expect(opened, ['s1']);
    });
  });

  group('the table', () {
    testWidgets('sits under a header built from the same column widths',
        (tester) async {
      await _pump(tester, rows: [_row(1)]);

      expect(find.byType(HomeFeedHeaderRow), findsOneWidget);
      final header = tester.getTopLeft(find.byType(HomeFeedHeaderRow));
      final firstRow = tester.getTopLeft(find.byType(HomeFeedRowTile).first);
      expect(header.dy, lessThan(firstRow.dy));

      // The From column starts in the same place in both, which is the whole
      // claim a header makes.
      expect(
        tester.getTopLeft(find.text('From')).dx,
        tester.getTopLeft(find.text('Sender 1')).dx,
      );
    });

    testWidgets('a Retry on a row reaches the handler the pane was given',
        (tester) async {
      final retries = <(String, String)>[];
      // Pending, nothing queued, and no progress write for half an hour —
      // the one shape that earns a Retry link.
      final stalled = HomeFeedRow(
        source: 'email',
        sourceMessageId: 'm42',
        conversationKey: 'c42',
        receivedAt: '2026-09-03T09:00:00Z',
        triageState: 'done',
        extractState: 'pending',
        storylineState: 'pending',
        draftState: 'pending',
        settleState: 'pending',
        outcome: 'pending',
        dropped: false,
        subject: 'Stuck one',
        fromName: 'Sender 42',
        updatedAt: '2026-09-03T11:30:00Z',
      );
      await _pump(
        tester,
        rows: [stalled],
        onRetry: (source, id) => retries.add((source, id)),
      );

      await tester.tap(find.byKey(HomeFeedRowTile.retryKey(stalled)));
      expect(retries, [('email', 'm42')]);
    });

    testWidgets('says so when there is nothing in it yet', (tester) async {
      await _pump(tester);
      expect(
        find.text('Nothing yet — messages appear here as they arrive.'),
        findsOneWidget,
      );
    });

    testWidgets('holds the empty line back until a read has come back',
        (tester) async {
      await _pump(tester, loaded: false);
      expect(
        find.text('Nothing yet — messages appear here as they arrive.'),
        findsNothing,
      );
    });

    testWidgets('asks for another page near the bottom', (tester) async {
      var asked = 0;
      await _pump(
        tester,
        rows: [for (var i = 0; i < 40; i++) _row(i)],
        onLoadMore: () => asked++,
      );

      expect(asked, 0);
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();
      expect(asked, greaterThan(0));
    });

    testWidgets('ends in words, never a spinner', (tester) async {
      await _pump(tester, rows: [_row(1)], loadingMore: true);
      expect(find.text('Loading older messages…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await _pump(tester, rows: [_row(1)], atEnd: true);
      expect(find.text("That's everything."), findsOneWidget);

      await _pump(tester, rows: [_row(1)]);
      expect(find.text('Loading older messages…'), findsNothing);
      expect(find.text("That's everything."), findsNothing);
    });

    testWidgets('keeps its rows under a read failure', (tester) async {
      await _pump(
        tester,
        rows: [_row(1)],
        loadError: 'Could not read the feed.',
      );

      expect(find.text('Could not read the feed.'), findsOneWidget);
      expect(find.byType(HomeFeedRowTile), findsOneWidget);
    });

    testWidgets('names all seven columns when it has the width', (tester) async {
      await _pump(tester, rows: [_row(1)]);

      for (final column in const [
        'From',
        'Subject',
        'Pipeline',
        'Result',
        'Ask · Summary',
        'When',
      ]) {
        expect(find.text(column), findsOneWidget, reason: column);
      }
    });

    testWidgets('folds to one line when the table is narrow', (tester) async {
      // Under [HomePane.compactBelow], which is what a thread open beside this
      // pane leaves it.
      await _pump(tester, rows: [_row(1)], paneWidth: 700);

      // Four columns, all named: the folded row still lines up, it is just
      // shorter.
      for (final column in ['From', 'Subject', 'Ask · Summary', 'When']) {
        expect(find.text(column), findsOneWidget, reason: column);
      }
      expect(
        find.text('Result'),
        findsNothing,
        reason: 'with a thread beside there is no width for a bar and a '
            'verdict, and the thread beside carries both',
      );
      expect(find.text('Pipeline'), findsNothing);

      expect(find.byKey(HomeFeedRowTile.askKey(_row(1))), findsOneWidget);
      expect(find.byKey(HomeFeedRowTile.whenKey(_row(1))), findsOneWidget);
      // The bar and the Result cell are the two history doors, and neither is
      // drawn here — the door in compact is the thread beside.
      expect(find.byType(HomeStageBar), findsNothing);
      expect(
        find.byKey(HomeFeedRowTile.historyBarKey(_row(1))),
        findsNothing,
      );
      expect(
        find.byKey(HomeFeedRowTile.historyCellKey(_row(1))),
        findsNothing,
      );
    });
  });

  group('the tiles are the filter', () {
    const numbers = HomeMetrics(
      emails: 41,
      teams: 7,
      urgent: 3,
      dropped: 12,
      needsYou: 5,
      inFlight: 8,
      errored: 2,
      total: 48,
    );

    BondStatTile tileFor(WidgetTester tester, String slug) => tester
        .widget<BondStatTile>(find.byKey(HomeMetricsBar.tileKey(slug)));

    testWidgets('a tile turns its own filter on', (tester) async {
      final asked = <HomeFilter>[];
      await _pump(tester, metrics: numbers, onFilter: asked.add);

      await tester.tap(find.byKey(HomeMetricsBar.tileKey('needs-you')));
      expect(asked, [HomeFilter.needsYou]);
    });

    testWidgets('the same tile turns it off again', (tester) async {
      final asked = <HomeFilter>[];
      await _pump(
        tester,
        metrics: numbers,
        filter: HomeFilter.needsYou,
        onFilter: asked.add,
      );

      await tester.tap(find.byKey(HomeMetricsBar.tileKey('needs-you')));
      expect(
        asked,
        [HomeFilter.fromOthers],
        reason: 'one filter at a time, and the tile is the way out of its own',
      );
    });

    testWidgets('the tile in force looks held down', (tester) async {
      await _pump(tester, metrics: numbers, filter: HomeFilter.dropped);

      expect(tileFor(tester, 'dropped').selected, isTrue);
      expect(tileFor(tester, 'needs-you').selected, isFalse);
    });

    testWidgets('Emails and Teams move the source chips instead',
        (tester) async {
      final sources = <String?>[];
      await _pump(tester, metrics: numbers, onSelectSource: sources.add);

      await tester.tap(find.byKey(HomeMetricsBar.tileKey('emails')));
      expect(sources, ['email']);

      // Already down, so the tile widens back to both connectors — the one
      // source selection the app has, and this is one of the two controls on
      // it.
      await _pump(
        tester,
        metrics: numbers,
        sourceFilter: 'email',
        onSelectSource: sources.add,
      );
      expect(tileFor(tester, 'emails').selected, isTrue);
      await tester.tap(find.byKey(HomeMetricsBar.tileKey('emails')));
      expect(sources, ['email', null]);
    });

    testWidgets('a filter in force says so, and offers the way out',
        (tester) async {
      final asked = <HomeFilter>[];
      await _pump(
        tester,
        metrics: numbers,
        filter: HomeFilter.urgent,
        onFilter: asked.add,
      );

      expect(find.byKey(HomePane.filterNoticeKey), findsOneWidget);
      expect(
        find.textContaining('Showing Urgent'),
        findsOneWidget,
        reason: 'a narrowing with nothing saying so reads as missing mail',
      );
      // Urgent is one of the seven, so the week is named beside it.
      expect(find.text('Showing Urgent · last 7 days'), findsOneWidget);

      await tester.tap(find.byKey(HomePane.showEveryoneKey));
      expect(asked, [HomeFilter.fromOthers]);
    });

    testWidgets('the Needs You pile names no window, because it has none',
        (tester) async {
      await _pump(
        tester,
        metrics: numbers,
        filter: HomeFilter.needsYou,
        onFilter: (_) {},
      );
      expect(find.text('Showing Needs you'), findsOneWidget);
      expect(find.textContaining('last 7 days'), findsNothing);
    });

    testWidgets('and says nothing at all under the default', (tester) async {
      await _pump(tester, metrics: numbers);
      expect(find.byKey(HomePane.filterNoticeKey), findsNothing);
      expect(find.byKey(HomePane.showEveryoneKey), findsNothing);
    });

    testWidgets('under Needs You the pane tells each live row its thread is '
        'owed an answer', (tester) async {
      bool told(WidgetTester tester, Key key) =>
          tester.widget<HomeFeedRowTile>(find.byKey(key)).threadNeedsYou;

      await _pump(
        tester,
        metrics: numbers,
        rows: [_row(1)],
        filter: HomeFilter.needsYou,
        onFilter: (_) {},
      );

      expect(
        told(tester, ValueKey<String>(_row(1).feedKey)),
        isTrue,
        reason: 'every row this filter returns is the newest kept message of '
            'a thread the rail says needs the reader, by construction — and '
            'the row cannot read that off its own columns',
      );

      // Any other filter, and the row is back to speaking for itself.
      await _pump(
        tester,
        metrics: numbers,
        rows: [_row(1)],
        filter: HomeFilter.dropped,
        onFilter: (_) {},
      );
      expect(told(tester, ValueKey<String>(_row(1).feedKey)), isFalse);
    });

    testWidgets('a search result under the same filter is told nothing',
        (tester) async {
      await _pump(
        tester,
        metrics: numbers,
        filter: HomeFilter.needsYou,
        onFilter: (_) {},
        search: HomeSearch('invoice', [_hit(7)]),
      );

      expect(
        tester
            .widget<HomeFeedRowTile>(
              find.byKey(ValueKey<String>('search-${_row(7).feedKey}')),
            )
            .threadNeedsYou,
        isFalse,
        reason: 'a hit is whatever the query found, and nothing about the '
            'list it landed in says its thread owes anything',
      );
    });
  });

  group('the order menu', () {
    testWidgets('sits beside the box and names the order it is in',
        (tester) async {
      await _pump(tester, sort: HomeSort.oldest);

      expect(find.byKey(HomePane.sortKey), findsOneWidget);
      expect(find.text('Oldest first'), findsOneWidget);
    });

    testWidgets('a pick reports it', (tester) async {
      final asked = <HomeSort>[];
      await _pump(tester, onSort: asked.add);

      await tester.tap(find.byKey(HomePane.sortKey));
      // The menu is a route: one frame to push it, then its own animation.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(
        find.byKey(HomePane.sortItemKeyFor(HomeSort.oldest)).last,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(asked, [HomeSort.oldest]);
    });
  });

  group('the pulse strip', () {
    testWidgets('narrates the work, the last ten minutes, and the sync',
        (tester) async {
      await _pump(
        tester,
        pulse: const PipelinePulse(
          queued: {'triage': 2},
          running: {'storyline': 1},
          recentSettled: 5,
          recentDropped: 2,
        ),
        stamps: const SyncStamps(mailIso: '2026-09-03T11:58:00Z'),
      );

      expect(find.byKey(PipelinePulseStrip.stripKey), findsOneWidget);
      expect(find.byKey(PipelinePulseStrip.workKey), findsOneWidget);
      expect(find.byKey(PipelinePulseStrip.recentKey), findsOneWidget);
      expect(find.byKey(PipelinePulseStrip.syncKey), findsOneWidget);
      expect(find.text('triaging 2 · grouping 1'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an idle pipeline says so in one word, and still syncs',
        (tester) async {
      await _pump(tester, pulse: const PipelinePulse(), mailSyncing: true);

      expect(find.text('Idle'), findsOneWidget);
      expect(find.byKey(PipelinePulseStrip.recentKey), findsNothing);
      expect(find.text('Syncing mail…'), findsOneWidget);
    });
  });

  group('while the reader is away from the top', () {
    final pill = find.byKey(const ValueKey<String>('pending-pill'));

    testWidgets('a count appears, and only when there is one', (tester) async {
      await _pump(tester, rows: [_row(1)]);
      expect(pill, findsNothing);

      await _pump(tester, rows: [_row(1)], pendingNewCount: 3);
      await tester.pump(HomePane.pillEntry);

      expect(pill, findsOneWidget);
      expect(find.text('3 new'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('tapping the count asks for the rows', (tester) async {
      var released = 0;
      await _pump(
        tester,
        rows: [_row(1)],
        pendingNewCount: 2,
        onReleasePending: () => released++,
      );
      // Twice: the first frame is the one that starts the slide, and the pill
      // is not where a tap looks for it until the slide has finished.
      await tester.pump(HomePane.pillEntry);
      await tester.pump(HomePane.pillEntry);

      await tester.tap(find.text('2 new'));
      // The ride back to the top, run out so the test does not end mid-scroll.
      await tester.pump(HomePane.releaseScroll);

      expect(released, 1);
    });

    testWidgets('the top is reported on the way out and on the way back',
        (tester) async {
      final reported = <bool>[];
      await _pump(
        tester,
        rows: [for (var i = 0; i < 40; i++) _row(i)],
        onAnchoredChanged: reported.add,
      );
      expect(reported, isEmpty, reason: 'sitting at the top is not an event');

      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(reported, [false]);

      await tester.drag(find.byType(ListView), const Offset(0, 1200));
      await tester.pump();
      expect(reported, [false, true]);
    });
  });

  group('a row on its way out', () {
    testWidgets('is grayed where it stands', (tester) async {
      final key = _row(1).feedKey;
      await _pump(tester, rows: [_row(1)], fading: {key});
      await tester.pump(homeDropCollapse);

      final opacities = tester
          .widgetList<AnimatedOpacity>(find.descendant(
            of: find.byType(HomeFeedRowTile),
            matching: find.byType(AnimatedOpacity),
          ))
          .map((widget) => widget.opacity);
      expect(opacities, contains(HomeFeedRowTile.dropFadeOpacity));
    });

    testWidgets('gives up its height, and the feed closes over it',
        (tester) async {
      final key = _row(1).feedKey;
      await _pump(tester, rows: [_row(1)]);
      expect(
        tester.getSize(find.byType(HomeFeedRowTile)).height,
        greaterThan(0),
      );

      await _pump(tester, rows: [_row(1)], collapsing: {key});
      expect(
        find.byType(HomeFeedRowTile),
        findsOneWidget,
        reason: 'the row is still in the list while it shrinks',
      );

      await tester.pump(homeDropCollapse);

      // A row of no height is a row the viewport stops laying out at all —
      // and this is the exact duration the notifier waits before dropping it
      // from the list, which is what keeps the two from disagreeing.
      expect(find.byType(HomeFeedRowTile), findsNothing);
    });
  });

  testWidgets('the title says where you are', (tester) async {
    await _pump(tester);
    expect(find.text('Inbox'), findsOneWidget);
  });

  group('search', () {
    /// The swap is an [AnimatedSwitcher], so the incoming body is not where a
    /// finder looks for it until it has finished arriving.
    Future<void> swap(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(HomePane.searchSwap);
    }

    testWidgets('enter submits, and only enter', (tester) async {
      final asked = <String>[];
      await _pump(tester, onSearch: asked.add);

      await tester.enterText(find.byType(TextField), 'invoice');
      await tester.pump();
      expect(asked, isEmpty, reason: 'every query is one embedding call');

      await tester.testTextInput.receiveAction(TextInputAction.search);
      expect(asked, ['invoice']);
    });

    testWidgets('searching says so in words over a table that stays',
        (tester) async {
      await _pump(tester, rows: [_row(1)], searching: true);

      expect(find.text('Searching…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Subject 1'), findsOneWidget);
    });

    testWidgets(
        'results swap the body: counted, labeled, muted, and the pill stays '
        'home', (tester) async {
      await _pump(
        tester,
        rows: [_row(1)],
        pendingNewCount: 3,
        search: HomeSearch('invoice', [_hit(7), _hit(8, score: 0.7)]),
      );
      await swap(tester);

      expect(find.text('2 results for “invoice”'), findsOneWidget);
      expect(find.text('Subject 7'), findsOneWidget);
      expect(find.text('Subject 8'), findsOneWidget);
      expect(
        find.text('3 new'),
        findsNothing,
        reason: 'the pill is a promise about the live table',
      );
      expect(
        tester
            .widgetList<HomeStageBar>(find.byType(HomeStageBar))
            .every((bar) => bar.muted),
        isTrue,
        reason: 'a result is context, not progress',
      );
    });

    testWidgets('one result is singular', (tester) async {
      await _pump(
        tester,
        search: HomeSearch('invoice', [_hit(7)]),
      );
      await swap(tester);

      expect(find.text('1 result for “invoice”'), findsOneWidget);
    });

    testWidgets('nothing matching is an answer', (tester) async {
      await _pump(tester, search: const HomeSearch('x', []));
      await swap(tester);

      expect(find.text('Nothing matches that.'), findsOneWidget);
      expect(find.text('0 results for “x”'), findsOneWidget);
    });

    testWidgets('back to live leaves', (tester) async {
      var left = 0;
      await _pump(
        tester,
        search: HomeSearch('invoice', [_hit(7)]),
        onExitSearch: () => left++,
      );
      await swap(tester);

      await tester.tap(find.text('Back to live'));
      expect(left, 1);
    });

    testWidgets('the notice is an alert over an unswapped body',
        (tester) async {
      const notice =
          'Search is unavailable — the semantic index is unavailable';
      await _pump(tester, rows: [_row(1)], searchNotice: notice);

      expect(find.text(notice), findsOneWidget);
      expect(find.text('Subject 1'), findsOneWidget);
    });

    testWidgets('escape leaves from the box', (tester) async {
      var left = 0;
      await _pump(tester, onExitSearch: () => left++);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);

      expect(left, 1);
    });

    testWidgets(
        'documents come first, and the count still counts messages',
        (tester) async {
      await _pump(
        tester,
        search: HomeSearch(
          'renewal',
          [_hit(7)],
          documents: [_doc()],
        ),
      );
      await swap(tester);

      expect(find.text('In documents'), findsOneWidget);
      expect(find.byType(AttachmentSearchTile), findsOneWidget);
      expect(
        find.text('1 result for “renewal”'),
        findsOneWidget,
        reason: 'the count labels the message list under it',
      );

      // Above the messages, not below them.
      final documents = tester.getTopLeft(find.byType(AttachmentSearchTile));
      final messages = tester.getTopLeft(find.text('Subject 7'));
      expect(documents.dy, lessThan(messages.dy));
    });

    testWidgets('a document opens the thread it came with', (tester) async {
      final opened = <(String, String)>[];
      await _pump(
        tester,
        search: HomeSearch('renewal', const [], documents: [_doc()]),
        onOpenThread: (source, key) => opened.add((source, key)),
      );
      await swap(tester);

      await tester.tap(find.byType(AttachmentSearchTile));
      expect(opened, [('email', 'c7')]);
    });

    testWidgets('no documents means no documents heading', (tester) async {
      await _pump(
        tester,
        search: HomeSearch('invoice', [_hit(7)]),
      );
      await swap(tester);

      expect(find.text('In documents'), findsNothing);
      expect(find.byType(AttachmentSearchTile), findsNothing);
    });

    testWidgets(
        'a document answering where no message did narrows the empty answer '
        'to the messages', (tester) async {
      await _pump(
        tester,
        search: HomeSearch('renewal', const [], documents: [_doc()]),
      );
      await swap(tester);

      expect(find.byType(AttachmentSearchTile), findsOneWidget);
      // The count is a count of MESSAGES, so it stays 0 — but the screen must
      // not also claim nothing matches while it is naming the file that does.
      expect(find.text('No messages match that.'), findsOneWidget);
      expect(find.text('Nothing matches that.'), findsNothing);
      expect(find.text('0 results for “renewal”'), findsOneWidget);
    });

    testWidgets(
        'every result is one list under one count, with no headings inside it',
        (tester) async {
      await _pump(
        tester,
        search: HomeSearch(
          'invoice',
          [_hit(7), _wordHit(8), _hit(9, score: 0.5)],
          notice: 'Words only — the semantic index is unavailable.',
        ),
      );
      await swap(tester);

      // The count is the rows, because the rows are one ranking: a reader can
      // count what is on screen and land on the number over it.
      expect(find.text('3 results for “invoice”'), findsOneWidget);
      expect(find.text('Subject 7'), findsOneWidget);
      expect(find.text('Subject 8'), findsOneWidget);
      expect(find.text('Subject 9'), findsOneWidget);
      expect(
        find.text('Words only — the semantic index is unavailable.'),
        findsOneWidget,
      );
      expect(
        find.text('Text matches'),
        findsNothing,
        reason: 'the two lists were fused into one; nothing splits them',
      );

      // Score order, whichever half found each row.
      expect(tester.getTopLeft(find.text('Subject 7')).dy,
          lessThan(tester.getTopLeft(find.text('Subject 8')).dy));
      expect(tester.getTopLeft(find.text('Subject 8')).dy,
          lessThan(tester.getTopLeft(find.text('Subject 9')).dy));
    });

    testWidgets('words alone are still an answer', (tester) async {
      await _pump(
        tester,
        search: HomeSearch('invoice', [_wordHit(8)]),
      );
      await swap(tester);

      expect(find.text('1 result for “invoice”'), findsOneWidget);
      expect(find.text('Subject 8'), findsOneWidget);
      expect(
        find.text('Nothing matches that.'),
        findsNothing,
        reason: 'the words found something, so nothing is not the answer',
      );
    });

    testWidgets('a result row opens its history', (tester) async {
      final opened = <(String, String)>[];
      await _pump(
        tester,
        search: HomeSearch('invoice', [_wordHit(8)]),
        onOpenHistory: (source, id) => opened.add((source, id)),
      );
      await swap(tester);

      await tester.tap(find.byKey(HomeFeedRowTile.historyBarKey(_row(8))));
      expect(opened, [('email', 'm8')]);
    });

    testWidgets('the clear affordance leaves too', (tester) async {
      var left = 0;
      await _pump(
        tester,
        search: HomeSearch('invoice', [_hit(7)]),
        onExitSearch: () => left++,
      );
      await swap(tester);

      await tester.tap(find.byIcon(Icons.close));
      expect(left, 1);
    });
  });
}
