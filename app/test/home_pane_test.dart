import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/home_feed_row.dart';
import 'package:bond_inbox/widgets/home_metrics.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The home pane as a whole: the numbers over the table, the strip between
/// them, and what the table does at its two ends.
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
      settleState: 'done',
      outcome: 'done',
      dropped: false,
      subject: 'Subject $index',
      fromName: 'Sender $index',
    );

Future<void> _pump(
  WidgetTester tester, {
  List<HomeFeedRow> rows = const [],
  HomeMetrics? metrics,
  List<HotStoryline> hot = const [],
  bool includeDropped = false,
  bool loaded = true,
  bool loadingMore = false,
  bool atEnd = false,
  String? loadError,
  void Function(String, String)? onOpenThread,
  void Function(String)? onOpenStoryline,
  VoidCallback? onLoadMore,
  VoidCallback? onToggleDropped,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: HomePane(
        rows: rows,
        metrics: metrics,
        hotStorylines: hot,
        includeDropped: includeDropped,
        loaded: loaded,
        loadingMore: loadingMore,
        atEnd: atEnd,
        loadError: loadError,
        now: _now,
        onOpenThread: onOpenThread ?? (_, _) {},
        onOpenStoryline: onOpenStoryline ?? (_) {},
        onLoadMore: onLoadMore ?? () {},
        onToggleDropped: onToggleDropped ?? () {},
      ),
    ),
  ));
}

void main() {
  group('the tiles', () {
    testWidgets('show all six figures, processed net of what is in flight',
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
  });

  testWidgets('the dropped toggle reports the tap and shows its state',
      (tester) async {
    var taps = 0;
    await _pump(tester, onToggleDropped: () => taps++);

    final pill = tester.widget<BondFilterPill>(
      find.widgetWithText(BondFilterPill, 'Show dropped'),
    );
    expect(pill.selected, isFalse);

    await tester.tap(find.text('Show dropped'));
    expect(taps, 1);

    await _pump(tester, includeDropped: true);
    expect(
      tester
          .widget<BondFilterPill>(
            find.widgetWithText(BondFilterPill, 'Show dropped'),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('the title says where you are', (tester) async {
    await _pump(tester);
    expect(find.text('Home'), findsOneWidget);
  });
}
