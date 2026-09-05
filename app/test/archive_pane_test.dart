import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/archive_pane.dart';
import 'package:bond_inbox/widgets/chips.dart' show BondFilterPill;
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/later_digest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation _conv({
  required String id,
  String source = 'email',
  String? who = 'Alex Rivera',
  String? email = 'alex.rivera@example.com',
  String? subject,
  String? bucket,
  ConversationState state = ConversationState.waiting,
  String lastMessageAt = '2026-01-14T10:00:00',
}) {
  return Conversation(
    id: id,
    source: source,
    subject: subject ?? 'Homepage copy',
    participants:
        who == null ? const [] : [Participant(name: who, email: email)],
    state: state,
    bucket: bucket,
    lastMessageAt: lastMessageAt,
  );
}

/// The clock the dropped rows are dated against, so "3h ago" means one thing.
final _now = DateTime.parse('2026-01-14T13:00:00Z');

HomeFeedRow _dropped({
  required String id,
  String source = 'email',
  String subject = 'Weekly roundup',
  String receivedAt = '2026-01-14T10:00:00Z',
  String dropReason = 'newsletter',
}) {
  return HomeFeedRow(
    source: source,
    sourceMessageId: id,
    conversationKey: 'c-$id',
    receivedAt: receivedAt,
    triageState: 'done',
    extractState: 'skipped',
    storylineState: 'skipped',
    draftState: 'skipped',
    settleState: 'done',
    outcome: 'dropped',
    dropped: true,
    dropReason: dropReason,
    subject: subject,
    fromName: 'Alex Rivera',
    fromAddress: 'alex.rivera@example.com',
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<Conversation> conversations,
    ArchiveTab tab = ArchiveTab.later,
    String? dayFilter,
    void Function(ArchiveTab)? onTab,
    void Function(String, String)? onOpen,
    void Function(String, String)? onReopen,
    List<HomeFeedRow> droppedRows = const [],
    bool droppedLoaded = true,
    bool droppedLoadingMore = false,
    String? droppedError,
    VoidCallback? onLoadMoreDropped,
    void Function(String)? onOpenStoryline,
    void Function(String, String)? onRestore,
    ArchiveSearch? search,
    bool searching = false,
    String? searchNotice,
    void Function(String)? onSearch,
    VoidCallback? onExitSearch,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArchivePane(
          conversations: conversations,
          sources: const ['email', 'teams'],
          tab: tab,
          onTab: onTab ?? (_) {},
          dayFilter: dayFilter,
          onOpen: onOpen ?? (_, _) {},
          onKeepSender: (_, _) {},
          onKeepThread: (_, _) {},
          onReopen: onReopen ?? (_, _) {},
          droppedRows: droppedRows,
          droppedLoaded: droppedLoaded,
          droppedLoadingMore: droppedLoadingMore,
          droppedError: droppedError,
          onLoadMoreDropped: onLoadMoreDropped ?? () {},
          onOpenStoryline: onOpenStoryline ?? (_) {},
          onRestore: onRestore ?? (_, _) {},
          search: search,
          searching: searching,
          searchNotice: searchNotice,
          onSearch: onSearch ?? (_) {},
          onExitSearch: onExitSearch ?? () {},
          now: _now,
        ),
      ),
    ));
  }

  testWidgets('the three piles are offered as pills', (tester) async {
    await pump(tester, conversations: [_conv(id: 'a', bucket: 'later')]);

    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Dropped'), findsOneWidget);
  });

  testWidgets('picking a pill asks the host to change tab', (tester) async {
    final picked = <ArchiveTab>[];
    await pump(
      tester,
      conversations: [_conv(id: 'a', bucket: 'later')],
      onTab: picked.add,
    );

    await tester.tap(find.text('Done'));
    await tester.pump();

    expect(picked, [ArchiveTab.done]);
  });

  testWidgets('the later tab shows what was deferred', (tester) async {
    await pump(
      tester,
      conversations: [_conv(id: 'a', bucket: 'later', subject: 'Launch date')],
    );

    expect(find.byType(LaterDigestPanel), findsOneWidget);
    expect(find.text('Launch date'), findsOneWidget);
  });

  testWidgets('the done tab shows what was closed', (tester) async {
    await pump(
      tester,
      tab: ArchiveTab.done,
      conversations: [
        _conv(id: 'a', subject: 'Launch date', state: ConversationState.done),
      ],
    );

    expect(find.byType(ConversationListPane), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.textContaining('Launch date'), findsOneWidget);
  });

  testWidgets(
      'a thread that was deferred and then closed is under Done only — '
      'the piles never answer the same question twice', (tester) async {
    final both = [
      _conv(
        id: 'a',
        subject: 'Launch date',
        bucket: 'later',
        state: ConversationState.done,
      ),
    ];

    await pump(tester, tab: ArchiveTab.done, conversations: both);
    expect(find.textContaining('Launch date'), findsOneWidget);

    await pump(tester, conversations: both);
    expect(find.text('Launch date'), findsNothing);
    expect(find.text('Nothing deferred.'), findsOneWidget);
  });

  testWidgets('reopening a done thread carries its source and key',
      (tester) async {
    final reopened = <(String, String)>[];
    await pump(
      tester,
      tab: ArchiveTab.done,
      conversations: [
        _conv(id: 'c1', source: 'teams', state: ConversationState.done),
      ],
      onReopen: (source, key) => reopened.add((source, key)),
    );

    await tester.tap(find.text('Reopen'));
    await tester.pump();

    expect(reopened, [('teams', 'c1')]);
  });

  testWidgets('the dropped tab lists what was filtered out, and why',
      (tester) async {
    await pump(
      tester,
      tab: ArchiveTab.dropped,
      conversations: [_conv(id: 'a', bucket: 'later')],
      droppedRows: [
        _dropped(id: 'd1', subject: 'Weekly roundup'),
        _dropped(id: 'd2', subject: 'Build finished', dropReason: 'fyi'),
      ],
    );

    expect(find.text('Weekly roundup'), findsOneWidget);
    expect(find.text('Build finished'), findsOneWidget);
    // The reason in the words a person would use, not the gate's vocabulary.
    expect(find.text('Newsletter'), findsOneWidget);
    expect(find.text('FYI'), findsOneWidget);
    // The pile is messages, so neither thread-shaped body is up.
    expect(find.byType(LaterDigestPanel), findsNothing);
    expect(find.byType(ConversationListPane), findsNothing);
  });

  testWidgets('an empty dropped pile says so once it has been read',
      (tester) async {
    await pump(
      tester,
      tab: ArchiveTab.dropped,
      conversations: [_conv(id: 'a', bucket: 'later')],
    );

    expect(find.text('Nothing filtered out yet.'), findsOneWidget);
  });

  testWidgets('before the first page lands the pile claims nothing',
      (tester) async {
    await pump(
      tester,
      tab: ArchiveTab.dropped,
      conversations: const [],
      droppedLoaded: false,
    );

    expect(find.text('Nothing filtered out yet.'), findsNothing);
  });

  testWidgets('a failed read hangs a sentence off the rows already there',
      (tester) async {
    await pump(
      tester,
      tab: ArchiveTab.dropped,
      conversations: const [],
      droppedRows: [_dropped(id: 'd1', subject: 'Weekly roundup')],
      droppedError: 'Could not read the pile.',
    );

    expect(find.text('Could not read the pile.'), findsOneWidget);
    expect(find.text('Weekly roundup'), findsOneWidget);
  });

  testWidgets('scrolling to the bottom of the pile asks for the next page',
      (tester) async {
    var asked = 0;
    await pump(
      tester,
      tab: ArchiveTab.dropped,
      conversations: const [],
      droppedRows: [
        for (var i = 0; i < 60; i++)
          _dropped(id: 'd$i', subject: 'Roundup number $i'),
      ],
      onLoadMoreDropped: () => asked++,
    );

    await tester.drag(find.text('Roundup number 0'), const Offset(0, -4000));
    await tester.pump();

    expect(asked, greaterThan(0));
  });

  testWidgets('opening a dropped row carries its source and thread key',
      (tester) async {
    final opened = <(String, String)>[];
    await pump(
      tester,
      tab: ArchiveTab.dropped,
      conversations: const [],
      droppedRows: [_dropped(id: 'd1', source: 'teams')],
      onOpen: (source, key) => opened.add((source, key)),
    );

    await tester.tap(find.text('Weekly roundup'));
    await tester.pump();

    expect(opened, [('teams', 'c-d1')]);
  });

  group('search', () {
    ArchiveSearch results(List<HomeFeedRow> rows, {String? notice}) =>
        ArchiveSearch('invoice', rows, notice);

    testWidgets('results take the place of the tabs, pills and all',
        (tester) async {
      await pump(
        tester,
        conversations: [_conv(id: 'a', bucket: 'later')],
        search: results([
          _dropped(id: 'd1', subject: 'Invoice 4471 is overdue'),
          _dropped(id: 'd2', subject: 'Invoice 4472 is paid'),
        ]),
      );

      expect(find.text('Invoice 4471 is overdue'), findsOneWidget);
      expect(find.text('Invoice 4472 is paid'), findsOneWidget);
      expect(find.text('2 results for “invoice”'), findsOneWidget);
      expect(find.text('Back to archive'), findsOneWidget);
      // A search spans all three piles, so none of them may look selected
      // under it.
      expect(find.widgetWithText(BondFilterPill, 'Later'), findsNothing);
      expect(find.widgetWithText(BondFilterPill, 'Done'), findsNothing);
      expect(find.widgetWithText(BondFilterPill, 'Dropped'), findsNothing);
      expect(find.byType(LaterDigestPanel), findsNothing);
    });

    testWidgets('one result is counted in the singular', (tester) async {
      await pump(
        tester,
        conversations: const [],
        search: results([_dropped(id: 'd1', subject: 'Invoice 4471')]),
      );

      expect(find.text('1 result for “invoice”'), findsOneWidget);
    });

    testWidgets('the way back asks the host to leave search', (tester) async {
      var left = 0;
      await pump(
        tester,
        conversations: const [],
        search: results([_dropped(id: 'd1')]),
        onExitSearch: () => left++,
      );

      await tester.tap(find.text('Back to archive'));
      await tester.pump();

      expect(left, 1);
    });

    testWidgets('a text-only answer says so over its own rows', (tester) async {
      await pump(
        tester,
        conversations: const [],
        search: results(
          [_dropped(id: 'd1', subject: 'Invoice 4471')],
          notice: 'Text matches only — the embedding server is not reachable.',
        ),
      );

      expect(
        find.text('Text matches only — the embedding server is not reachable.'),
        findsOneWidget,
      );
      expect(find.text('Invoice 4471'), findsOneWidget,
          reason: 'the notice qualifies the rows, it does not replace them');
    });

    testWidgets('a query in flight says so over the pile that is still up',
        (tester) async {
      await pump(
        tester,
        tab: ArchiveTab.dropped,
        conversations: const [],
        droppedRows: [_dropped(id: 'd1', subject: 'Weekly roundup')],
        searching: true,
      );

      expect(find.text('Searching…'), findsOneWidget);
      expect(find.text('Weekly roundup'), findsOneWidget);
    });

    testWidgets('a search that found nothing says so about the history',
        (tester) async {
      await pump(
        tester,
        conversations: [_conv(id: 'a', bucket: 'later')],
        search: results(const []),
      );

      expect(find.text('Nothing in your history matches that.'),
          findsOneWidget);
      expect(find.text('0 results for “invoice”'), findsOneWidget);
    });

    testWidgets('a search that could not run at all is a notice on the tabs',
        (tester) async {
      await pump(
        tester,
        conversations: [_conv(id: 'a', bucket: 'later', subject: 'Launch')],
        searchNotice: "Search failed — couldn't read the index.",
      );

      expect(find.text("Search failed — couldn't read the index."),
          findsOneWidget);
      expect(find.byType(LaterDigestPanel), findsOneWidget,
          reason: 'nothing answered, so the piles are still what is on screen');
    });

    testWidgets('enter submits, and only enter', (tester) async {
      final asked = <String>[];
      await pump(tester, conversations: const [], onSearch: asked.add);

      await tester.enterText(find.byType(TextField), 'invoice');
      await tester.pump();
      expect(asked, isEmpty, reason: 'every query is one embedding call');

      await tester.testTextInput.receiveAction(TextInputAction.search);

      expect(asked, ['invoice']);
    });
  });

  group('restore', () {
    testWidgets('every dropped row offers a way back', (tester) async {
      final restored = <(String, String)>[];
      await pump(
        tester,
        conversations: const [],
        tab: ArchiveTab.dropped,
        droppedRows: [
          _dropped(id: 'd1', subject: 'Weekly roundup'),
          _dropped(id: 'd2', source: 'teams', subject: 'Standup notes'),
        ],
        onRestore: (source, id) => restored.add((source, id)),
      );

      expect(find.text('Restore'), findsNWidgets(2));

      await tester.tap(find.text('Restore').first);
      await tester.pump();

      // The pair, not the thread key: a gate takes one message and a restore
      // gives back exactly that one.
      expect(restored, [('email', 'd1')]);
    });

    testWidgets('only the dropped hits in a search get one', (tester) async {
      final restored = <(String, String)>[];
      final live = _dropped(id: 'live', subject: 'Invoice 4472 is paid')
          .restored();
      await pump(
        tester,
        conversations: const [],
        search: ArchiveSearch(
          'invoice',
          [_dropped(id: 'd1', subject: 'Invoice 4471 is overdue'), live],
          null,
        ),
        onRestore: (source, id) => restored.add((source, id)),
      );

      // A search spans the piles, and a hit that was never dropped has
      // nothing to be restored from.
      expect(find.text('Restore'), findsOneWidget);

      await tester.tap(find.text('Restore'));
      await tester.pump();

      expect(restored, [('email', 'd1')]);
    });
  });

  testWidgets('a day filter narrows the later tab and nothing else',
      (tester) async {
    await pump(
      tester,
      dayFilter: '2026-01-14',
      conversations: [
        _conv(
          id: 'a',
          subject: 'Launch date',
          bucket: 'later',
          lastMessageAt: '2026-01-14T10:00:00',
        ),
        _conv(
          id: 'b',
          subject: 'Homepage copy',
          bucket: 'later',
          lastMessageAt: '2026-01-11T10:00:00',
        ),
      ],
    );

    expect(find.text('Launch date'), findsOneWidget);
    expect(find.text('Homepage copy'), findsNothing);
  });
}
