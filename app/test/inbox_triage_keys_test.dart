// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/find_field.dart';
import 'package:bond_inbox/widgets/label_picker.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Keyboard triage over a real store: the keys, the auto-advance, the undo.
///
/// `triage_intents_test` holds the row arithmetic on its own; this holds the
/// wiring — that the letters reach the region at all, that a destructive key
/// leaves the reader standing on the row that took the cleared one's place,
/// that one undo slot is offered and honoured, and that a letter typed into a
/// box is a letter.
///
/// Unhandled keys are recorded above the app. A key the region acted on never
/// reaches the recorder; a key it declined does, which is how `e` in the
/// composer is read as "the letter went to the text layer" rather than as
/// "nothing happened".

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
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
  late List<LogicalKeyboardKey> unhandled;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    unhandled = [];
  });

  tearDown(() => db.close());

  /// Hours rather than dates: the needs-you window and the recency decay both
  /// judge these stamps, and a literal date rots at a midnight with no code
  /// change (`app/CLAUDE.md`).
  String ago(int hours) =>
      DateTime.now().toUtc().subtract(Duration(hours: hours)).toIso8601String();

  Future<void> seedThread(String key, String subject, String cta,
      {required int hoursAgo}) async {
    final received = ago(hoursAgo);
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'received_at': received,
      'body_text': 'the hero paragraph',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json':
          '[{"name":"Dana Whitfield","email":"dana@example.com"}]',
      'state': 'needs_reply',
      'cta_text': cta,
      'cta_urgency': 'normal',
      'last_message_at': received,
      'last_inbound_at': received,
    });
  }

  /// Three rows in a known order. Newest first is a stored order the fixture
  /// can name, where By priority would rank on a score this file is not about.
  Future<void> seedPile() async {
    await store.setPref(needsYouSortKey, 'newest');
    await seedThread('c1', 'Homepage copy', 'Confirm the launch date',
        hoursAgo: 1);
    await seedThread('c2', 'Invoice 4471', 'Sign the invoice', hoursAgo: 2);
    await seedThread('c3', 'Vendor quote', 'Approve the quote', hoursAgo: 3);
  }

  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Everything eligible reaches Needs You: the scoring pass lands a few pumps
    // in, and the default slider would cut rows this file walks with.
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
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      // Above the app on purpose: a key the triage region handled stops here,
      // and one it declined arrives.
      child: Focus(
        onKeyEvent: (_, event) {
          // A modifier on its own is bound to nothing anywhere and arrives here
          // every time; only the key it modifies is the question.
          // A key that collapses into a pseudo-key IS a modifier: the eight
          // shift/meta/alt/control keys are the whole synonym table.
          final modifier = !LogicalKeyboardKey.collapseSynonyms({
            event.logicalKey,
          }).contains(event.logicalKey);
          if (event is KeyDownEvent && !modifier) {
            unhandled.add(event.logicalKey);
          }
          return KeyEventResult.ignored;
        },
        child: const MaterialApp(home: InboxScreen()),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// A key press and the three pumps an opening thread needs.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Whatever the list pane is drawing, in the order it draws it.
  List<String> rowTitles(WidgetTester tester) {
    final pane = tester.widget<ConversationListPane>(
      find.byType(ConversationListPane),
    );
    return [
      for (final (_, rows) in pane.sectionsOverride!)
        for (final c in rows) c.subject ?? '',
    ];
  }

  /// The lit row's own words. By label, because the position of a row is the
  /// thing every one of these presses is changing.
  String? litRow(WidgetTester tester) {
    for (final row in tester.widgetList<ConversationRow>(
      find.byType(ConversationRow),
    )) {
      if (row.selected) return row.conversation.subject;
    }
    return null;
  }

  /// The composer of whichever thread is open, focused the way a reader focuses
  /// it. `showKeyboard` rather than `tap`: the panel takes a pointer down for
  /// its own focus node, and the cursor is the point of the exercise.
  Future<void> focusComposer(WidgetTester tester) async {
    await tester.showKeyboard(find.descendant(
      of: find.byType(Composer),
      matching: find.byType(TextField),
    ));
    await tester.pump();
    expect(
      find.byType(EditableText).evaluate().any(
            (e) => (e.widget as EditableText).focusNode.hasFocus,
          ),
      isTrue,
      reason: 'the cursor is in the composer',
    );
  }

  testWidgets('j and k walk the pile, and the list says where the reader is',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    expect(rowTitles(tester), ['Homepage copy', 'Invoice 4471', 'Vendor quote']);
    expect(litRow(tester), isNull);

    // Standing on no row, j starts at the top rather than nowhere.
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Homepage copy');
    // And the thread it lit is open beside it, which is what the list does with
    // a row on this stop.
    expect(find.byType(SidePanelHost), findsOneWidget);

    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Invoice 4471');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(litRow(tester), 'Vendor quote');

    // The bottom is the bottom: wrapping round to the top would hand the reader
    // a thread they already dealt with and call it progress.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(litRow(tester), 'Vendor quote');

    await press(tester, LogicalKeyboardKey.keyK);
    expect(litRow(tester), 'Invoice 4471');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(litRow(tester), 'Homepage copy');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(litRow(tester), 'Homepage copy');

    // Every one of them was acted on rather than left to the app's own bindings.
    expect(unhandled, isEmpty);
    await settleQueues(tester);
  });

  testWidgets('e clears the thread and lands the reader on the next one',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Invoice 4471');

    await press(tester, LogicalKeyboardKey.keyE);

    expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
    // The row that took its place, not the top of the list and not an empty
    // pane: this is the whole reason the keys are quicker than the mouse.
    expect(litRow(tester), 'Vendor quote');
    expect(find.text('Dismissed.'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('e on the last row leaves the reader on the one above it',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyK);
    expect(litRow(tester), 'Vendor quote');

    await press(tester, LogicalKeyboardKey.keyE);

    expect(rowTitles(tester), ['Homepage copy', 'Invoice 4471']);
    expect(litRow(tester), 'Invoice 4471');
    await settleQueues(tester);
  });

  testWidgets('z takes back the thing the bar offered to take back',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyE);
    expect(rowTitles(tester), isNot(contains('Homepage copy')));

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);

    expect(rowTitles(tester), contains('Homepage copy'));
    // The bar went with it: an Undo still on screen would offer to do the same
    // thing twice, and the slot holds one.
    expect(find.text('Undo'), findsNothing);

    await press(tester, LogicalKeyboardKey.keyZ);
    expect(rowTitles(tester), contains('Homepage copy'));
    await settleQueues(tester);
  });

  testWidgets('s defers the thread, with the same one press back', (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Invoice 4471');

    await press(tester, LogicalKeyboardKey.keyS);

    expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
    expect(litRow(tester), 'Vendor quote');
    expect(find.text('Sent to Later.'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);

    expect(rowTitles(tester), contains('Invoice 4471'));
    await settleQueues(tester);
  });

  testWidgets('e typed in the composer is a letter, not a dismissal',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Homepage copy');

    await focusComposer(tester);
    unhandled.clear();
    await press(tester, LogicalKeyboardKey.keyE);

    // Nothing was cleared, and the key was DECLINED rather than swallowed: a
    // disabled action leaves the event unhandled, so the letter goes on to the
    // text layer instead of dying in a shortcut map.
    expect(rowTitles(tester), contains('Homepage copy'));
    expect(find.text('Dismissed.'), findsNothing);
    expect(unhandled, contains(LogicalKeyboardKey.keyE));

    // And so is every other single letter in the map.
    unhandled.clear();
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyS);
    expect(litRow(tester), 'Homepage copy');
    expect(rowTitles(tester), hasLength(3));
    expect(
      unhandled,
      containsAll([LogicalKeyboardKey.keyJ, LogicalKeyboardKey.keyS]),
    );
    await settleQueues(tester);
  });

  testWidgets('Escape comes back out of the box and the letters work again',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await focusComposer(tester);

    await press(tester, LogicalKeyboardKey.escape);

    // Escape is the one binding that is live while typing, and in a thread open
    // beside it means the panel: back to the list is back to the list.
    expect(find.byType(SidePanelHost), findsNothing);
    // Proof the cursor came back with it — a letter that lands nowhere is how a
    // reader loses the keyboard for the rest of the session.
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Homepage copy');
    await settleQueues(tester);
  });

  testWidgets('l and Shift+E ask for the picker and clear nothing',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Homepage copy');
    unhandled.clear();

    await press(tester, LogicalKeyboardKey.keyL);

    // The key was taken and the strip is up on the thread beside, and a label
    // is not a dismissal: the pile and the reader's place in it are untouched.
    expect(unhandled, isEmpty);
    expect(find.byKey(LabelPicker.fieldKey), findsOneWidget);
    expect(rowTitles(tester), hasLength(3));
    expect(litRow(tester), 'Homepage copy');
    expect(find.text('Dismissed.'), findsNothing);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(LabelPicker.fieldKey), findsNothing);
    await press(tester, LogicalKeyboardKey.keyE, shift: true);

    // Shift+E is the labelling one: nothing leaves the pile until a label is
    // picked, which is the difference between it and a bare `e`.
    expect(unhandled, isEmpty);
    expect(find.byKey(LabelPicker.fieldKey), findsOneWidget);
    expect(rowTitles(tester), hasLength(3));
    expect(find.text('Dismissed.'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets(
      'Shift+E, a new word, Enter: dismissed with the label, one z back',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Homepage copy');

    await press(tester, LogicalKeyboardKey.keyE, shift: true);
    expect(find.byKey(LabelPicker.fieldKey), findsOneWidget);

    // Enter on a name no chip carries mints the word and files the thread
    // under it in the same press — the whole point of the inline flow.
    await tester.enterText(
        find.byKey(LabelPicker.fieldKey), 'Vendor outreach');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleQueues(tester);
    await tester.pump();
    await tester.pump();

    // Dismissed WITH the label: gone from the pile, the reader landed on the
    // next row, the bar names both halves of what it will take back, and the
    // link is really in the store.
    expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
    expect(litRow(tester), 'Invoice 4471');
    expect(find.text('Dismissed · Vendor outreach.'), findsOneWidget);
    final linked = await store.labelsForConversation('email', 'c1');
    expect([for (final l in linked) l.name], ['Vendor outreach']);

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);

    // One z, both halves: the thread is back in the pile and the link the
    // dismiss created went with it — while the word itself stays in the
    // vocabulary, ready for the next thread.
    expect(rowTitles(tester), contains('Homepage copy'));
    expect(await store.labelsForConversation('email', 'c1'), isEmpty);
    expect([for (final l in await store.listLabels()) l.name],
        contains('Vendor outreach'));
    await settleQueues(tester);
  });

  testWidgets('l files the thread where it stands, and z takes the chip off',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Invoice 4471');

    await press(tester, LogicalKeyboardKey.keyL);
    expect(find.byKey(LabelPicker.fieldKey), findsOneWidget);

    // Enter applies the top match of what was typed — keep with a label, so
    // nothing moves and nothing is dismissed.
    await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleQueues(tester);
    await tester.pump();
    await tester.pump();

    expect(rowTitles(tester), hasLength(3));
    expect(find.text('Labeled FYI only.'), findsOneWidget);
    final linked = await store.labelsForConversation('email', 'c2');
    expect([for (final l in linked) l.name], ['FYI only']);

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);

    expect(await store.labelsForConversation('email', 'c2'), isEmpty);
    expect(rowTitles(tester), hasLength(3));
    await settleQueues(tester);
  });

  testWidgets('the keys are chrome-free: a letter over the rail is a letter',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);

    // The Find box is chrome above the region, and a reader looking for a word
    // beginning with `e` must not clear a thread by typing it.
    await tester.showKeyboard(find.byKey(FindField.fieldKey));
    await tester.pump();
    unhandled.clear();

    await press(tester, LogicalKeyboardKey.keyE);

    expect(rowTitles(tester), contains('Homepage copy'));
    expect(find.text('Dismissed.'), findsNothing);
    await settleQueues(tester);
  });
}
