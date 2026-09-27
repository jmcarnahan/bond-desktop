// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart' show ConversationState;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/select_similar.dart' show SimilarScope;
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/bulk_action_bar.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/find_field.dart';
import 'package:bond_inbox/widgets/icon_rail.dart' show IconRail;
import 'package:bond_inbox/widgets/label_picker.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Bulk triage over a real store — requirement 12c: the selection, the bar,
/// one bar and one undo per bulk act, and select-similar.
///
/// `inbox_triage_keys_test`'s harness and idiom: bare pumps (never
/// `pumpAndSettle` on the inbox), and rows read by their subjects, never by
/// position.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A store that refuses label links on the threads named in [refused], and
/// records every removal it is asked for — so a bulk Undo can be seen to
/// take back only what actually went on. [refusedRemovals] is the same for
/// the Undo's own writes: a refusal there must not stop the rest.
class _PartlyRefusingStore extends MessageStore {
  _PartlyRefusingStore(super.db, this.refused);

  final Set<String> refused;
  final Set<String> refusedRemovals = {};
  final List<String> removed = [];

  @override
  Future<void> applyLabels(
    String source,
    String conversationKey,
    List<String> labelIds, {
    String appliedBy = 'user',
  }) async {
    if (refused.contains(conversationKey)) {
      throw StateError('the disk said no');
    }
    return super.applyLabels(
      source,
      conversationKey,
      labelIds,
      appliedBy: appliedBy,
    );
  }

  @override
  Future<bool> removeLabel(
    String source,
    String conversationKey,
    String labelId,
  ) async {
    removed.add(conversationKey);
    if (refusedRemovals.contains(conversationKey)) {
      throw StateError('the disk said no');
    }
    return super.removeLabel(source, conversationKey, labelId);
  }
}

class _FakeTeamsSync implements TeamsSync {
  @override
  Future<String?> get lastSyncedAt async => null;

  @override
  Future<void> syncNow() async {}
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProviderContainer container;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// Hours rather than dates — see `app/CLAUDE.md` on fixture timestamps.
  String ago(int hours) =>
      DateTime.now().toUtc().subtract(Duration(hours: hours)).toIso8601String();

  Future<void> seedThread(
    String key,
    String subject, {
    required int hoursAgo,
    String name = 'Dana Whitfield',
    String from = 'dana@example.com',
  }) async {
    final received = ago(hoursAgo);
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': name,
      'from_address': from,
      'received_at': received,
      'body_text': 'the hero paragraph',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"$name","email":"$from"}]',
      'state': 'needs_reply',
      'cta_text': 'Answer $subject',
      'cta_urgency': 'normal',
      'last_message_at': received,
      'last_inbound_at': received,
    });
  }

  /// Five rows in a known order — newest first is a stored order the fixture
  /// can name.
  Future<void> seedPile() async {
    await store.setPref(needsYouSortKey, 'newest');
    await seedThread('c1', 'Homepage copy', hoursAgo: 1);
    await seedThread('c2', 'Invoice 4471', hoursAgo: 2);
    await seedThread('c3', 'Vendor quote', hoursAgo: 3);
    await seedThread('c4', 'Offsite agenda', hoursAgo: 4);
    await seedThread('c5', 'Parking passes', hoursAgo: 5);
  }

  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  /// [height] tall enough, where a test reaches for a row's box, that the
  /// lazily built list has built that row.
  Future<void> pumpInbox(
    WidgetTester tester, {
    double height = 900,
    MessageStore? storeAs,
  }) async {
    await tester.binding.setSurfaceSize(Size(1400, height));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await store.setPref(attentionThresholdKey, '0');
    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialSectionProvider.overrideWithValue(RailSection.needsYou),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      teamsSyncProvider.overrideWithValue(_FakeTeamsSync()),
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
      if (storeAs != null) messageStoreProvider.overrideWithValue(storeAs),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: InboxScreen()),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  List<String> rowTitles(WidgetTester tester) {
    final pane = tester.widget<ConversationListPane>(
      find.byType(ConversationListPane),
    );
    return [
      for (final (_, rows) in pane.sectionsOverride!)
        for (final c in rows) c.subject ?? '',
    ];
  }

  /// The ticked rows by subject, as the pane was handed them.
  List<String> tickedTitles(WidgetTester tester) {
    final pane = tester.widget<ConversationListPane>(
      find.byType(ConversationListPane),
    );
    return [
      for (final (_, rows) in pane.sectionsOverride!)
        for (final c in rows)
          if (pane.checked.contains((source: c.source, key: c.id)))
            c.subject ?? '',
    ];
  }

  Finder checkFor(String key) => find.byKey(ValueKey('row-check-email|$key'));

  /// `j` then `x`, [times] over: ticks that many rows from the top.
  Future<void> tickFromTop(WidgetTester tester, int times) async {
    for (var i = 0; i < times; i++) {
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyX);
    }
  }

  testWidgets('x ticks the row the reader is on, and Esc lets go',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    expect(find.byKey(BulkActionBar.barKey), findsNothing);

    await tickFromTop(tester, 1);
    expect(find.text('1 selected'), findsOneWidget);
    // x does not advance: the reader is still on the row they ticked.
    expect(tickedTitles(tester), ['Homepage copy']);

    await tickFromTop(tester, 1);
    expect(find.text('2 selected'), findsOneWidget);
    expect(tickedTitles(tester), ['Homepage copy', 'Invoice 4471']);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(BulkActionBar.barKey), findsNothing);
    expect(tickedTitles(tester), isEmpty);
    await settleQueues(tester);
  });

  testWidgets('a Shift-click on a box ticks the range from the anchor',
      (tester) async {
    await seedPile();
    await pumpInbox(tester, height: 1600);
    await tickFromTop(tester, 1);
    expect(find.text('1 selected'), findsOneWidget);

    // Every box draws once anything is ticked, so the fourth row's is there.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(checkFor('c4'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();

    expect(find.text('4 selected'), findsOneWidget);
    expect(tickedTitles(tester), [
      'Homepage copy',
      'Invoice 4471',
      'Vendor quote',
      'Offsite agenda',
    ]);
    await settleQueues(tester);
  });

  testWidgets('bulk Mark done is one bar, counts three, and one Undo is all '
      'three',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await settleQueues(tester);
    await tickFromTop(tester, 3);
    expect(find.text('3 selected'), findsOneWidget);

    await tester.tap(find.byKey(BulkActionBar.dismissKey));
    await settleQueues(tester);

    expect(rowTitles(tester), ['Offsite agenda', 'Parking passes']);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Marked done: 3 threads.'), findsOneWidget);
    expect(find.text('3 of 5 cleared'), findsOneWidget);
    expect(find.byKey(BulkActionBar.barKey), findsNothing);

    await tester.tap(find.text('Undo'));
    await settleQueues(tester);

    expect(rowTitles(tester), [
      'Homepage copy',
      'Invoice 4471',
      'Vendor quote',
      'Offsite agenda',
      'Parking passes',
    ]);
    expect(find.byKey(ConversationListPane.progressKey), findsNothing);
    expect(find.text('3 selected'), findsOneWidget);
    // Each row back where it stood, not a re-derived guess.
    final stored = await store.loadConversations();
    expect(
      [for (final c in stored) if (c.state == ConversationState.done) c.id],
      isEmpty,
    );
    await settleQueues(tester);
  });

  testWidgets('a row the store refuses is skipped and not counted',
      (tester) async {
    await seedPile();
    // The seam is the database itself: one row's `done` write aborts, which
    // is exactly the failure `markDone` answers with a null undo.
    await db.customStatement(
      'CREATE TRIGGER refuse_c2 BEFORE UPDATE OF state ON conversations '
      "WHEN NEW.conversation_key = 'c2' AND NEW.state = 'done' "
      "BEGIN SELECT RAISE(ABORT, 'refused'); END",
    );
    await pumpInbox(tester);
    await settleQueues(tester);
    await tickFromTop(tester, 3);

    await tester.tap(find.byKey(BulkActionBar.dismissKey));
    await settleQueues(tester);

    expect(
      find.text('Marked done: 2 threads. 1 could not be changed.'),
      findsOneWidget,
    );
    expect(find.text('2 of 5 cleared'), findsOneWidget);
    expect(
      rowTitles(tester),
      ['Invoice 4471', 'Offsite agenda', 'Parking passes'],
    );
    await settleQueues(tester);
  });

  testWidgets('bulk Later defers them all, and one Undo brings them back',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await settleQueues(tester);
    await tickFromTop(tester, 2);

    await tester.tap(find.byKey(BulkActionBar.laterKey));
    await settleQueues(tester);

    expect(find.text('Sent 2 threads to Later.'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      rowTitles(tester),
      ['Vendor quote', 'Offsite agenda', 'Parking passes'],
    );
    expect(find.text('2 of 5 cleared'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await settleQueues(tester);

    expect(rowTitles(tester), [
      'Homepage copy',
      'Invoice 4471',
      'Vendor quote',
      'Offsite agenda',
      'Parking passes',
    ]);
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byKey(ConversationListPane.progressKey), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a Shift-click on a CARD is a range, and the card does not open',
      (tester) async {
    await seedPile();
    await pumpInbox(tester, height: 1600);
    await tickFromTop(tester, 1);
    String? beside() => tester
        .widget<ConversationListPane>(find.byType(ConversationListPane))
        .selectedId;
    expect(beside(), 'c1');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.descendant(
      of: find.byType(ConversationListPane),
      matching: find.text('Vendor quote'),
    ));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();

    expect(find.text('3 selected'), findsOneWidget);
    expect(beside(), 'c1');
    await settleQueues(tester);
  });

  testWidgets(
      'e typed in Find with rows ticked is a letter, and acts on nothing',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await tickFromTop(tester, 2);

    await tester.showKeyboard(find.descendant(
      of: find.byType(FindField),
      matching: find.byType(TextField),
    ));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyE);

    expect(rowTitles(tester), hasLength(5));
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('2 selected'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('e with rows ticked dismisses them all, and z brings them back',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await tickFromTop(tester, 3);

    await press(tester, LogicalKeyboardKey.keyE);
    await settleQueues(tester);
    expect(rowTitles(tester), ['Offsite agenda', 'Parking passes']);
    expect(find.text('Marked done: 3 threads.'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    expect(rowTitles(tester), [
      'Homepage copy',
      'Invoice 4471',
      'Vendor quote',
      'Offsite agenda',
      'Parking passes',
    ]);
    expect(find.text('3 selected'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('l with rows ticked labels them all and keeps the selection',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    await pumpInbox(tester);
    await tickFromTop(tester, 2);

    await press(tester, LogicalKeyboardKey.keyL);
    expect(find.byKey(const ValueKey('bulk-label-picker')), findsOneWidget);
    expect(find.text('Label 2 threads'), findsOneWidget);

    await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleQueues(tester);

    expect(find.text('Labeled 2 threads FYI only.'), findsOneWidget);
    expect(rowTitles(tester), hasLength(5));
    expect(find.text('2 selected'), findsOneWidget);
    for (final key in ['c1', 'c2']) {
      final linked = await store.labelsForConversation('email', key);
      expect([for (final l in linked) l.name], ['FYI only'], reason: key);
    }
    // Filing is not clearing: nothing on the progress line.
    expect(find.byKey(ConversationListPane.progressKey), findsNothing);

    await tester.tap(find.text('Undo'));
    await settleQueues(tester);
    expect(await store.labelsForConversation('email', 'c1'), isEmpty);
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);
    await settleQueues(tester);
  });

  /// Two rows ticked, `l`, `fyi`, Enter: the bulk label strip's apply.
  Future<void> labelTwo(WidgetTester tester) async {
    await tickFromTop(tester, 2);
    await press(tester, LogicalKeyboardKey.keyL);
    await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleQueues(tester);
  }

  testWidgets('a bulk label that partly fails says so, and Undo takes back '
      'only what went on', (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    final refusing = _PartlyRefusingStore(db, {'c2'});
    await pumpInbox(tester, storeAs: refusing);

    await labelTwo(tester);

    expect(find.text('Labeled 1 thread FYI only. 1 could not be changed.'),
        findsOneWidget);
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);

    await tester.tap(find.text('Undo'));
    await settleQueues(tester);
    expect(refusing.removed, ['c1']);
    expect(await store.labelsForConversation('email', 'c1'), isEmpty);
    await settleQueues(tester);
  });

  testWidgets('a bulk label that wholly fails reads as the failure it is',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    await pumpInbox(tester, storeAs: _PartlyRefusingStore(db, {'c1', 'c2'}));

    await labelTwo(tester);

    expect(find.text("Couldn't label 2 threads FYI only just now."),
        findsOneWidget);
    expect(find.textContaining('Labeled'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a bulk Undo that hits a refusal still takes the rest back',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    final refusing = _PartlyRefusingStore(db, {});
    await pumpInbox(tester, storeAs: refusing);
    await labelTwo(tester);
    expect(find.text('Labeled 2 threads FYI only.'), findsOneWidget);

    refusing.refusedRemovals.add('c2');
    await tester.tap(find.text('Undo'));
    await settleQueues(tester);
    await tester.pump();

    // The refusal is said, and it does not strand the other thread's label.
    expect(
      find.text("Couldn't take that label off every thread just now."),
      findsOneWidget,
    );
    expect(await store.labelsForConversation('email', 'c1'), isEmpty);
    expect(
      [
        for (final l in await store.labelsForConversation('email', 'c2'))
          l.name,
      ],
      ['FYI only'],
    );
    await settleQueues(tester);
  });

  testWidgets('the bulk toast counts what wears the word, not what this '
      'press wrote', (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    // The first row already wears it, the second refuses, the third takes
    // it: two of three ticked rows end up wearing the word.
    await store.applyLabels('email', 'c1', [fyi.id]);
    final refusing = _PartlyRefusingStore(db, {'c2'});
    await pumpInbox(tester, storeAs: refusing);

    await tickFromTop(tester, 3);
    await press(tester, LogicalKeyboardKey.keyL);
    await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleQueues(tester);

    expect(
      find.text('Labeled 2 threads FYI only. 1 could not be changed.'),
      findsOneWidget,
    );

    // And its Undo holds only the link this press actually made.
    await tester.tap(find.text('Undo'));
    await settleQueues(tester);
    expect(
      [
        for (final l in await store.labelsForConversation('email', 'c1'))
          l.name,
      ],
      ['FYI only'],
    );
    expect(await store.labelsForConversation('email', 'c3'), isEmpty);
    await settleQueues(tester);
  });

  testWidgets('Drop senders writes each sender once and Undo restores each',
      (tester) async {
    await store.setPref(needsYouSortKey, 'newest');
    await seedThread('c1', 'Homepage copy', hoursAgo: 1);
    await seedThread('c2', 'Invoice 4471', hoursAgo: 2);
    await seedThread('c3', 'Vendor quote',
        hoursAgo: 3, name: 'Lee Park', from: 'lee@example.net');
    await seedThread('c4', 'Offsite agenda',
        hoursAgo: 4, name: 'Kim Ode', from: 'kim@example.org');
    // A rule already standing on one of the two, which Undo must put back.
    await store.setSenderPref('lee@example.net', 'keep');
    await pumpInbox(tester);
    await settleQueues(tester);
    await tickFromTop(tester, 3);
    expect(find.text('3 selected'), findsOneWidget);

    await tester.tap(find.byKey(BulkActionBar.dropKey));
    await settleQueues(tester);

    expect(
      find.text('2 senders dropped — 3 threads moved to Later.'),
      findsOneWidget,
    );
    expect(rowTitles(tester), ['Offsite agenda']);
    expect(await store.getSenderPref('dana@example.com'), 'drop');
    expect(await store.getSenderPref('lee@example.net'), 'drop');

    await tester.tap(find.text('Undo'));
    await settleQueues(tester);

    expect(await store.getSenderPref('dana@example.com'), isNull);
    expect(await store.getSenderPref('lee@example.net'), 'keep');
    expect(rowTitles(tester), [
      'Homepage copy',
      'Invoice 4471',
      'Vendor quote',
      'Offsite agenda',
    ]);
    await settleQueues(tester);
  });

  testWidgets('the subject chip selects the Accepted: rows, not the [JIRA] one',
      (tester) async {
    await store.setPref(needsYouSortKey, 'newest');
    await seedThread('c1', 'Accepted: Weekly sync', hoursAgo: 1);
    await seedThread('c2', '[JIRA] (KEY-12) Fix login', hoursAgo: 2);
    await seedThread('c3', 'Accepted: Offsite', hoursAgo: 3);
    await seedThread('c4', 'Homepage copy', hoursAgo: 4);
    await pumpInbox(tester);
    await tickFromTop(tester, 1);

    final chip = find.byKey(BulkActionBar.similarKeyFor(SimilarScope.subject));
    expect(chip, findsOneWidget);
    expect(find.text('accepted: · 2'), findsOneWidget);

    await tester.tap(chip);
    await tester.pump();

    expect(find.text('2 selected'), findsOneWidget);
    expect(
      tickedTitles(tester),
      ['Accepted: Weekly sync', 'Accepted: Offsite'],
    );
    // Every match is ticked now, so the chip has nothing left to offer.
    expect(chip, findsNothing);
    await settleQueues(tester);
  });

  testWidgets('x typed in Find is a letter, and the selection is untouched',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await tickFromTop(tester, 1);
    expect(find.text('1 selected'), findsOneWidget);

    await tester.showKeyboard(find.descendant(
      of: find.byType(FindField),
      matching: find.byType(TextField),
    ));
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyX);

    expect(find.text('1 selected'), findsOneWidget);
    expect(tickedTitles(tester), ['Homepage copy']);
    await settleQueues(tester);
  });

  group('the bulk keys act only on the pile in view', () {
    /// Which threads the store holds as done, by key.
    Future<List<String>> doneKeys() async => [
          for (final c in await store.loadConversations())
            if (c.state == ConversationState.done) c.id,
        ];

    testWidgets('a thread opened in the main pane is what e acts on, and the '
        'ticks wait for the overview', (tester) async {
      await seedPile();
      await pumpInbox(tester);
      await settleQueues(tester);
      await tickFromTop(tester, 2);
      expect(tickedTitles(tester), ['Homepage copy', 'Invoice 4471']);

      // The rail column's row opens the thread in MAIN, hiding the overview
      // and its ticked rows.
      await tester.tap(find.descendant(
        of: find.byType(AppRail),
        matching: find.textContaining('Answer Vendor quote'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<ThreadDetailPanel>(find.byType(ThreadDetailPanel))
            .conversation
            .subject,
        'Vendor quote',
      );

      await press(tester, LogicalKeyboardKey.keyE);
      await settleQueues(tester);

      // The thread in front of the reader, not the two they cannot see.
      expect(find.text('Marked done.'), findsOneWidget);
      expect(find.text('Marked done: 2 threads.'), findsNothing);
      expect(await doneKeys(), ['c3']);

      // Back on the overview, the selection they made is still made.
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(rowTitles(tester), [
        'Homepage copy',
        'Invoice 4471',
        'Offsite agenda',
        'Parking passes',
      ]);
      expect(find.text('2 selected'), findsOneWidget);
      expect(tickedTitles(tester), ['Homepage copy', 'Invoice 4471']);
      await settleQueues(tester);
    });

    testWidgets('e with Settings showing marks no ticked row done',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);
      await settleQueues(tester);
      await tickFromTop(tester, 2);
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byKey(IconRail.accountMenuKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(IconRail.settingsItemKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ConversationListPane), findsNothing);

      await press(tester, LogicalKeyboardKey.keyE);
      await settleQueues(tester);

      expect(find.text('Marked done: 2 threads.'), findsNothing);
      expect(await doneKeys(), isEmpty);

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(rowTitles(tester), [
        'Homepage copy',
        'Invoice 4471',
        'Vendor quote',
        'Offsite agenda',
        'Parking passes',
      ]);
      expect(find.text('2 selected'), findsOneWidget);
      expect(tickedTitles(tester), ['Homepage copy', 'Invoice 4471']);
      await settleQueues(tester);
    });
  });
}
