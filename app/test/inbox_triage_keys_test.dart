import 'dart:async' show Completer;

// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/models/message_models.dart' show ConversationState;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/backend_types.dart' show SentDraft;
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/cheat_sheet_panel.dart';
import 'package:bond_inbox/widgets/chips.dart' show BondFilterPill;
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/find_field.dart';
import 'package:bond_inbox/widgets/icon_rail.dart' show IconRail;
import 'package:bond_inbox/widgets/quick_replies.dart' show QuickReplyBox;
import 'package:bond_inbox/widgets/label_picker.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/thread_action_bar.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
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

/// A store whose label writes can be refused, for the toasts that must not
/// say "Labeled" or "Removed" over a write that never happened. The flags are
/// live, so a test can let an apply through and then refuse its undo.
class _RefusingStore extends MessageStore {
  _RefusingStore(
    super.db, {
    this.refuseApply = false,
    this.refuseRemove = false,
  });

  bool refuseApply;
  bool refuseRemove;

  /// The read [_applyPickedLabel] guards with — refused, the press must not
  /// file blind.
  bool refuseLabelRead = false;

  /// Set, an apply waits on it: the moment between a press and its toast,
  /// held open long enough for the reader to have moved on.
  Completer<void>? holdApply;

  /// Set, a label create waits on it: the picker's write held open while the
  /// reader presses Enter again, or Escape.
  Completer<void>? holdCreate;

  /// Set, a thread state write waits on it: a mark-done held between the
  /// press and its landing, for a click to arrive in the gap.
  Completer<void>? holdStateWrite;

  /// Set, a label create fails the way a disk does — not the store's own
  /// refusal, so the host falls back to its generic sentence.
  bool refuseCreate = false;

  /// Set, a write that would mark a thread done fails the way a locked
  /// database does. Every other state write lands, so a sent reply can still
  /// move its thread to waiting while its mark-done fails.
  bool refuseDoneWrite = false;

  /// Every thread state write, by key, in order: how a test tells one
  /// mark-done from the same one run twice.
  final List<String> stateWrites = [];

  @override
  Future<Label> createLabel(String name, {String? tone}) async {
    final hold = holdCreate;
    if (hold != null) await hold.future;
    if (refuseCreate) throw Exception('the disk said no');
    return super.createLabel(name, tone: tone);
  }

  @override
  Future<void> setConversationState(
    String source,
    String conversationKey,
    ConversationState state,
  ) async {
    stateWrites.add(conversationKey);
    final hold = holdStateWrite;
    if (hold != null) await hold.future;
    if (refuseDoneWrite && state == ConversationState.done) {
      throw StateError('database is locked');
    }
    return super.setConversationState(source, conversationKey, state);
  }

  @override
  Future<List<Label>> labelsForConversation(
    String source,
    String conversationKey,
  ) async {
    if (refuseLabelRead) throw StateError('the disk said no');
    return super.labelsForConversation(source, conversationKey);
  }

  @override
  Future<void> applyLabels(
    String source,
    String conversationKey,
    List<String> labelIds, {
    String appliedBy = 'user',
  }) async {
    final hold = holdApply;
    if (hold != null) await hold.future;
    if (refuseApply) throw StateError('the disk said no');
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
    if (refuseRemove) throw StateError('the disk said no');
    return super.removeLabel(source, conversationKey, labelId);
  }

  @override
  Future<bool> restoreLabel(
    String source,
    String conversationKey,
    String labelId,
  ) async {
    if (refuseApply) throw StateError('the disk said no');
    return super.restoreLabel(source, conversationKey, labelId);
  }
}

class _Tokens implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

/// A mail backend whose sends go nowhere and succeed, recording the bodies —
/// so a reply from the composer is a real `SendOutcome.sent` through the
/// whole draft path. Anything else a pane reaches for throws.
class _SendingMail implements MailBackend {
  final List<String> bodies = [];

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async =>
      const {'id': 'graph-draft-1'};

  @override
  Future<void> updateDraftBody(String draftId, String text) async {
    bodies.add(text);
  }

  @override
  Future<SentDraft> sendDraft(String draftId) async =>
      SentDraft(draftId: draftId);

  @override
  Future<void> deleteDraft(String draftId) async {}

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A backend whose reply drafts are always refused, the same way each time:
/// a send that fails with the SAME error on every press.
class _RefusingMail extends _SendingMail {
  int drafts = 0;

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async {
    drafts++;
    throw Exception('the server said no');
  }
}

/// Everything a send needs, so the composer is armed rather than offering a
/// copy.
const String _sendGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Mail.ReadWrite '
    'https://graph.microsoft.com/Mail.Send';

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

  /// [mail], when given, arms the composer: a signed-in grant that can send,
  /// on the SDK backend, and [mail] as the backend the send reaches.
  Future<void> pumpInbox(
    WidgetTester tester, {
    MessageStore? storeAs,
    _SendingMail? mail,
    RailSection section = RailSection.needsYou,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GraphAuth? auth;
    if (mail != null) {
      final tokens = _Tokens();
      tokens.values['refresh_token'] = 'rt-1';
      tokens.values['granted_scopes'] = _sendGrant;
      auth = GraphAuth(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        store: tokens,
      );
      // The app's default backend is MCP, whose session would answer the
      // scope question by asking a server that is not there.
      await store.setPref(backendModeKey, backendModeSdk);
    }

    // Everything eligible reaches Needs You: the scoring pass lands a few pumps
    // in, and the default slider would cut rows this file walks with.
    await store.setPref(attentionThresholdKey, '0');
    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      keepingDecisionClient(),
      initialSectionProvider.overrideWithValue(section),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      teamsSyncProvider.overrideWithValue(_FakeTeamsSync()),
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
      if (storeAs != null) messageStoreProvider.overrideWithValue(storeAs),
      if (auth != null) graphAuthProvider.overrideWithValue(auth),
      if (mail != null) mailBackendProvider.overrideWithValue(mail),
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

  /// `?` as the glyph a layout produces, which is what the binding listens
  /// for — on a German keyboard it is not Shift+slash.
  Future<void> pressQuestionMark(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.minus, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
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
    expect(find.text('Marked done.'), findsOneWidget);
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

  testWidgets('the bar closes on its ✕, and z still reaches the undo',
      (tester) async {
    // An undoable bar persists by the framework's default; this one must not,
    // and it must be dismissable without undoing what it reports.
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyE);
    expect(find.text('Undo'), findsOneWidget);
    // Let the bar finish sliding in before aiming at it.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    await tester.tap(find.descendant(
      of: find.byType(SnackBar),
      matching: find.byIcon(Icons.close),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Undo'), findsNothing);
    expect(rowTitles(tester), isNot(contains('Homepage copy')));

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
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

  testWidgets('a palette pick actually runs: >later defers the standing row',
      (tester) async {
    // The whole feature in one walk, because it rests on a fragile handoff:
    // the single letters are dead while an editable has focus, so the field
    // must give the cursor BACK and defer the invoke a frame — a same-frame
    // dispatch is silently refused and this test is what notices.
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Invoice 4471');

    await tester.enterText(find.byKey(FindField.fieldKey), '>later');
    await tester.pump();
    await tester.pump();
    // A command needle never narrows the list: '>' is an order, not a search.
    expect(rowTitles(tester), hasLength(3));

    await tester.testTextInput.receiveAction(TextInputAction.search);
    // One frame to give up the cursor, one for the post-frame invoke, one
    // for what it did.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await settleQueues(tester);

    // The same LaterThreadIntent `s` fires, on the same standing row.
    expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
    expect(find.text('Sent to Later.'), findsOneWidget);
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
    expect(find.text('Marked done.'), findsNothing);
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
    expect(find.text('Marked done.'), findsNothing);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(LabelPicker.fieldKey), findsNothing);
    await press(tester, LogicalKeyboardKey.keyE, shift: true);

    // Shift+E is the labelling one: nothing leaves the pile until a label is
    // picked, which is the difference between it and a bare `e`.
    expect(unhandled, isEmpty);
    expect(find.byKey(LabelPicker.fieldKey), findsOneWidget);
    expect(rowTitles(tester), hasLength(3));
    expect(find.text('Marked done.'), findsNothing);
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
    expect(find.text('Marked done · Vendor outreach.'), findsOneWidget);
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
    expect(rowTitles(tester), ['Homepage copy', 'Invoice 4471', 'Vendor quote']);
    await settleQueues(tester);
  });

  testWidgets('a label already on the thread is not applied again, so no '
      'undo can take it off', (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    final countBefore = (await store.listLabels()).single.useCount;
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Invoice 4471');

    await press(tester, LogicalKeyboardKey.keyL);
    await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleQueues(tester);
    await tester.pump();

    expect(find.text('Already labeled FYI only.'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
    // And `z` has nothing of this press to take back: the label the owner put
    // there before stays.
    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    final linked = await store.labelsForConversation('email', 'c2');
    expect([for (final l in linked) l.name], ['FYI only']);
    expect((await store.listLabels()).single.useCount, countBefore);
    await settleQueues(tester);
  });

  testWidgets('a label chip\'s ✕ takes it off, and Undo puts it back uncounted',
      (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    final countBefore = (await store.listLabels()).single.useCount;
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await tester.pump();

    await tester.tap(find.byKey(ThreadActionBar.removeLabelKey(fyi.id)));
    await settleQueues(tester);
    await tester.pump();
    expect(find.text('Removed FYI only.'), findsOneWidget);
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    final linked = await store.labelsForConversation('email', 'c2');
    expect([for (final l in linked) l.name], ['FYI only']);
    // Putting back what was there is not a reach for the word.
    expect((await store.listLabels()).single.useCount, countBefore);
    await settleQueues(tester);
  });

  testWidgets('a label chip\'s name writes its label: facet into Find, quoted',
      (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await tester.pump();

    await tester.tap(find.descendant(
      of: find.byType(ThreadActionBar),
      matching: find.text('FYI only'),
    ));
    await tester.pump();
    await tester.pump();

    final box = tester.widget<TextField>(find.descendant(
      of: find.byType(FindField),
      matching: find.byType(TextField),
    ));
    const facet = 'label:"FYI only" ';
    expect(box.controller!.text, facet);
    // A needle written for the reader is one to add to: the cursor at its end,
    // not the whole of it selected for typing over.
    expect(
      box.controller!.selection,
      const TextSelection.collapsed(offset: facet.length),
    );
    // And the rail is narrowed by it, not just the box filled.
    await tester.pump();
    Finder railRow(String text) =>
        find.descendant(of: find.byType(AppRail), matching: find.text(text));
    expect(railRow('Sign the invoice · Dana Whitfield'), findsOneWidget);
    expect(railRow('Confirm the launch date · Dana Whitfield'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a chip\'s facet is added to a needle already in Find',
      (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await tester.enterText(find.byKey(FindField.fieldKey), 'Invoice');
    await tester.pump();

    await tester.tap(find.descendant(
      of: find.byType(ThreadActionBar),
      matching: find.text('FYI only'),
    ));
    await tester.pump();
    await tester.pump();

    final box = tester.widget<TextField>(find.byKey(FindField.fieldKey));
    expect(box.controller!.text, 'Invoice label:"FYI only" ');
    await settleQueues(tester);
  });

  testWidgets('a remove that fails says so, and offers no undo',
      (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    await pumpInbox(tester, storeAs: _RefusingStore(db, refuseRemove: true));
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await tester.pump();

    await tester.tap(find.byKey(ThreadActionBar.removeLabelKey(fyi.id)));
    await settleQueues(tester);
    await tester.pump();

    expect(find.text("Couldn't take that label off just now."), findsOneWidget);
    expect(find.text('Removed FYI only.'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    final linked = await store.labelsForConversation('email', 'c2');
    expect([for (final l in linked) l.name], ['FYI only']);
    await settleQueues(tester);
  });

  /// `l` on the second row, `fyi` typed, Enter: the label strip's apply.
  Future<void> labelSecondRow(WidgetTester tester) async {
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyL);
    await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleQueues(tester);
    await tester.pump();
  }

  testWidgets('a label that will not go on says so, with nothing to undo',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    await pumpInbox(tester, storeAs: _RefusingStore(db, refuseApply: true));

    await labelSecondRow(tester);

    expect(find.text("Couldn't file that thread just now."), findsOneWidget);
    expect(find.text('Labeled FYI only.'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);
    await settleQueues(tester);
  });

  testWidgets('an Undo that fails says so rather than nothing',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    final refusing = _RefusingStore(db);
    await pumpInbox(tester, storeAs: refusing);
    await labelSecondRow(tester);
    expect(find.text('Labeled FYI only.'), findsOneWidget);

    refusing.refuseRemove = true;
    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    await tester.pump();

    // The failure is on screen, not only in a picker that is shut.
    expect(find.text("Couldn't take that label off just now."), findsOneWidget);
    final linked = await store.labelsForConversation('email', 'c2');
    expect([for (final l in linked) l.name], ['FYI only']);
    await settleQueues(tester);
  });

  testWidgets('a thread whose labels cannot be read is not filed blind',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    final refusing = _RefusingStore(db);
    await pumpInbox(tester, storeAs: refusing);

    refusing.refuseLabelRead = true;
    await labelSecondRow(tester);

    // Unread is not "not there": applying blind could hand the toast an
    // Undo over a label this press never put on.
    expect(find.text("Couldn't file that thread just now."), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);
    await settleQueues(tester);
  });

  testWidgets('a slow label write does not pull the cursor out of Find',
      (tester) async {
    await store.createLabel('FYI only');
    await seedPile();
    final refusing = _RefusingStore(db)..holdApply = Completer<void>();
    await pumpInbox(tester, storeAs: refusing);

    // The label press, with its write held open under it…
    await labelSecondRow(tester);
    // …while the reader has already moved on into Find.
    await tester.showKeyboard(find.byKey(FindField.fieldKey));
    await tester.pump();

    refusing.holdApply!.complete();
    await settleQueues(tester);
    await tester.pump();

    // The toast lands; the cursor stays where the reader put it.
    expect(find.text('Labeled FYI only.'), findsOneWidget);
    final editable = tester.widget<EditableText>(find.descendant(
      of: find.byKey(FindField.fieldKey),
      matching: find.byType(EditableText),
    ));
    expect(editable.focusNode.hasFocus, isTrue);
    await settleQueues(tester);
  });

  testWidgets('an Undo that cannot put a chip back says so', (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    final refusing = _RefusingStore(db);
    await pumpInbox(tester, storeAs: refusing);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await tester.pump();
    await tester.tap(find.byKey(ThreadActionBar.removeLabelKey(fyi.id)));
    await settleQueues(tester);
    expect(find.text('Removed FYI only.'), findsOneWidget);

    refusing.refuseApply = true;
    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    await tester.pump();

    expect(
      find.text("Couldn't put that label back just now."),
      findsOneWidget,
    );
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);
    await settleQueues(tester);
  });

  testWidgets('a chip whose link is already gone offers no Undo',
      (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(find.byKey(ThreadActionBar.removeLabelKey(fyi.id)), findsOneWidget);

    // The link goes behind the screen's back, so the chip on screen is stale:
    // its ✕ takes nothing off, and an Undo over it would add a label the
    // thread never had.
    await store.removeLabel('email', 'c2', fyi.id);
    await tester.tap(find.byKey(ThreadActionBar.removeLabelKey(fyi.id)));
    await settleQueues(tester);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Nothing came off, so nothing is said: a bar here would be a claim, and
    // it would take the Undo of whatever bar stood before it.
    expect(find.text('Removed FYI only.'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Undo'), findsNothing);
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);
    await settleQueues(tester);
  });

  testWidgets('a double-click on a chip\'s ✕ keeps the first press\'s Undo',
      (tester) async {
    final fyi = await store.createLabel('FYI only');
    await seedPile();
    await store.applyLabels('email', 'c2', [fyi.id]);
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    await tester.pump();

    // Both presses before a frame: the second lands on the same ✕ while the
    // first removal's reload is still out, and removes nothing.
    final cross = find.byKey(ThreadActionBar.removeLabelKey(fyi.id));
    await tester.tap(cross);
    await tester.tap(cross);
    await settleQueues(tester);
    await tester.pump();
    await tester.pump();

    expect(find.text('Removed FYI only.'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(await store.labelsForConversation('email', 'c2'), isEmpty);

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    expect(
      [for (final l in await store.labelsForConversation('email', 'c2'))
        l.name],
      ['FYI only'],
    );
    await settleQueues(tester);
  });

  testWidgets('the bar\'s Later defers this thread the way s does',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Invoice 4471');

    await tester.tap(find.byKey(ThreadActionBar.laterKey));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Later, not a dismissal, with the same landing and the same way back.
    expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
    expect(litRow(tester), 'Vendor quote');
    expect(find.text('Sent to Later.'), findsOneWidget);
    expect(find.text('Marked done.'), findsNothing);

    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    expect(rowTitles(tester), contains('Invoice 4471'));
    await settleQueues(tester);
  });

  group('Mark done\'s choices and the keys', () {
    Future<void> openChoices(WidgetTester tester) async {
      await tester.tap(find.byKey(ThreadActionBar.doneKey));
      // One frame to draw them, one for the post-frame focus.
      await tester.pump();
      await tester.pump();
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsOneWidget);
    }

    testWidgets('beside the list, Escape shuts the choices and not the panel',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(find.byType(SidePanelHost), findsOneWidget);
      await openChoices(tester);

      await press(tester, LogicalKeyboardKey.escape);

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      expect(find.byType(SidePanelHost), findsOneWidget);
      expect(litRow(tester), 'Invoice 4471');
      // The keys are still live: focus went back where it came from.
      await press(tester, LogicalKeyboardKey.keyE);
      expect(find.text('Marked done.'), findsOneWidget);
      expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
      await settleQueues(tester);
    });

    testWidgets('in the pane, Escape shuts the choices and e still works',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);
      // Find's pick opens the thread in the main pane.
      await tester.enterText(find.byKey(FindField.fieldKey), 'Invoice');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SidePanelHost), findsNothing);
      expect(find.byType(ThreadDetailPanel), findsOneWidget);
      await openChoices(tester);

      await press(tester, LogicalKeyboardKey.escape);

      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      expect(find.byType(ThreadDetailPanel), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(find.text('Marked done.'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('e with the choices up closes the thread, and the keys stay '
        'live on the next one', (tester) async {
      await seedPile();
      await pumpInbox(tester);
      await press(tester, LogicalKeyboardKey.keyJ);
      await openChoices(tester);

      // The panel is keyed by thread, so this advance throws the bar that
      // held focus away.
      await press(tester, LogicalKeyboardKey.keyE);
      expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
      expect(find.byKey(ThreadActionBar.doneChoicesKey), findsNothing);
      unhandled.clear();

      await press(tester, LogicalKeyboardKey.keyE);

      expect(unhandled, isEmpty);
      expect(rowTitles(tester), ['Vendor quote']);
      await settleQueues(tester);
    });

    testWidgets('a thread Find opened answers e without a click first',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);
      await tester.enterText(find.byKey(FindField.fieldKey), 'Invoice');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      unhandled.clear();

      await press(tester, LogicalKeyboardKey.keyE);

      expect(unhandled, isEmpty);
      expect(find.text('Marked done.'), findsOneWidget);
      await settleQueues(tester);
    });
  });

  group('the toast\'s life', () {
    Future<void> pumpFor(WidgetTester tester, Duration total) async {
      const step = Duration(milliseconds: 250);
      for (var t = Duration.zero; t < total; t += step) {
        await tester.pump(step);
      }
    }

    testWidgets('an undoable bar leaves on its own, and z outlives it',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyE);
      expect(find.text('Marked done.'), findsOneWidget);

      await pumpFor(tester, const Duration(seconds: 7));

      expect(find.byType(SnackBar), findsNothing);
      await press(tester, LogicalKeyboardKey.keyZ);
      await settleQueues(tester);
      expect(rowTitles(tester), contains('Homepage copy'));
      await settleQueues(tester);
    });

    testWidgets('under a screen reader a bar with nothing to undo still leaves',
        (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final fyi = await store.createLabel('FYI only');
      await seedPile();
      await store.applyLabels('email', 'c2', [fyi.id]);
      await pumpInbox(tester);
      await labelSecondRow(tester);
      expect(find.text('Already labeled FYI only.'), findsOneWidget);

      await pumpFor(tester, const Duration(seconds: 7));

      // Staying is for walking to an Undo; with none there, it only covers
      // the rail.
      expect(find.text('Already labeled FYI only.'), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('under a screen reader an undoable bar stays until closed',
        (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await seedPile();
      await pumpInbox(tester);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyE);

      await pumpFor(tester, const Duration(seconds: 7));

      expect(find.text('Marked done.'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(SnackBar),
        matching: find.byIcon(Icons.close),
      ));
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsNothing);
      await settleQueues(tester);
    });
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
    expect(find.text('Marked done.'), findsNothing);
    await settleQueues(tester);
  });

  testWidgets(
      'r opens the in-list box on the focused row, a letter inside it is a '
      'letter, and Escape hands the keys back', (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await settleQueues(tester);

    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyR);

    // On the row `r` named — the newest, where j stood — and nowhere else.
    // The key is derived from source|id, so any row with c1's identity names
    // the same box.
    Key boxKey() {
      final pane = tester.widget<ConversationListPane>(
        find.byType(ConversationListPane),
      );
      for (final (_, rows) in pane.sectionsOverride!) {
        for (final c in rows) {
          if (c.id == 'c1') return ConversationListPane.quickReplyKeyFor(c);
        }
      }
      fail('c1 left the pile');
    }

    expect(find.byKey(boxKey()), findsOneWidget);

    // The box autofocused, so `e` is a letter in it, not a dismissal.
    await press(tester, LogicalKeyboardKey.keyE);
    expect(rowTitles(tester), hasLength(3),
        reason: 'e typed into the box must not clear the thread');

    // Escape closes the box and the keys work again: this `e` IS a dismissal.
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byKey(boxKey()), findsNothing);
    await press(tester, LogicalKeyboardKey.keyE);
    await settleQueues(tester);
    expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
  });

  testWidgets(
      'the progress line counts a cleared row and gives it back with z',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await settleQueues(tester);

    // Nothing cleared yet: no line, however big the pile is.
    expect(find.byKey(ConversationListPane.progressKey), findsNothing);

    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyE);
    await settleQueues(tester);
    expect(find.text('1 of 3 cleared'), findsOneWidget);

    // The undo is the row back AND the count back — the same bar carries both.
    await press(tester, LogicalKeyboardKey.keyZ);
    await settleQueues(tester);
    expect(rowTitles(tester), ['Homepage copy', 'Invoice 4471', 'Vendor quote']);
    expect(find.byKey(ConversationListPane.progressKey), findsNothing);
  });

  testWidgets('switching tabs ends the sit-down the progress line was counting',
      (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await settleQueues(tester);

    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyE);
    await settleQueues(tester);
    expect(find.text('1 of 3 cleared'), findsOneWidget);

    // The pill, not whatever else says the same word on screen.
    Finder pill(String label) => find.descendant(
          of: find.byKey(const Key('needs-you-tabs')),
          matching: find.text(label),
        );

    // A tab is a different pile: "1 of 3" held over whatever Asked of me
    // shows would be progress through a pile that is no longer on screen.
    await tester.tap(pill('Asked of me'));
    await settleQueues(tester);
    expect(find.byKey(ConversationListPane.progressKey), findsNothing);

    // And coming back starts a fresh count over the pile as it IS now — two
    // rows, not the three the first sit-down began with.
    await tester.tap(pill('All'));
    await settleQueues(tester);
    expect(find.byKey(ConversationListPane.progressKey), findsNothing);
    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyE);
    await settleQueues(tester);
    expect(find.text('1 of 2 cleared'), findsOneWidget);
  });

  testWidgets('? opens the sheet beside, and Escape closes it', (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await settleQueues(tester);

    await pressQuestionMark(tester);
    expect(find.byType(CheatSheetBody), findsOneWidget);
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    // Nothing was beside, so there is nothing to go back to.
    expect(find.byKey(SidePanelHost.backKey), findsNothing);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(CheatSheetBody), findsNothing);
    expect(find.byType(SidePanelHost), findsNothing);
    expect(unhandled, isEmpty);

    // And the letters are the list's again.
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(litRow(tester), 'Homepage copy');
    await settleQueues(tester);
  });

  testWidgets('over a thread beside, the sheet goes ON it and Escape gives it '
      'back', (tester) async {
    await seedPile();
    await pumpInbox(tester);
    await settleQueues(tester);

    await press(tester, LogicalKeyboardKey.keyJ);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);

    await pressQuestionMark(tester);
    expect(find.byType(CheatSheetBody), findsOneWidget);
    expect(find.text('Back to Homepage copy'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(CheatSheetBody), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    expect(litRow(tester), 'Homepage copy');
    await settleQueues(tester);
  });

  testWidgets('] and [ walk the mentions of the thread open BESIDE',
      (tester) async {
    await seedPile();
    // Two turns in c1 that name the owner, and one between them that does
    // not. Older than the row's own message, so the pile's order holds.
    Future<void> turn(String id, int hoursAgo, {required bool me}) =>
        store.upsertMessage({
          'source': 'email',
          'source_message_id': id,
          'conversation_key': 'c1',
          'direction': 'inbound',
          'subject': 'Homepage copy',
          'from_name': 'Dana Whitfield',
          'from_address': 'dana@example.com',
          'received_at': ago(hoursAgo),
          'body_text': 'turn $id',
          'addressed_me': me ? 1 : 0,
        });
    await turn('c1-a', 6, me: true);
    await turn('c1-b', 5, me: false);
    await turn('c1-c', 4, me: true);
    await pumpInbox(tester);
    await settleQueues(tester);

    // Needs You opens the thread beside the list, not in main.
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(ThreadDetailPanel),
      ),
      findsOneWidget,
    );

    Future<void> settleJump() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
    }

    /// Whether the side transcript has lit [id] — the jump's own flash.
    bool lit(String id) {
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byKey(ThreadDetailPanel.flashKeyFor(id)),
      ));
      return (box.decoration as BoxDecoration).color != null;
    }

    await press(tester, LogicalKeyboardKey.bracketRight);
    await settleJump();
    expect(lit('c1-a'), isTrue);

    await press(tester, LogicalKeyboardKey.bracketRight);
    await settleJump();
    expect(lit('c1-c'), isTrue);
    expect(lit('c1-a'), isFalse);

    await press(tester, LogicalKeyboardKey.bracketLeft);
    await settleJump();
    expect(lit('c1-a'), isTrue);

    expect(unhandled, isEmpty);
    await tester.pump(ThreadDetailPanel.flashDuration);
    await settleQueues(tester);
  });

  group('a sent reply takes its thread off the pile', () {
    /// Types into the open thread's composer and presses its Send, then lets
    /// the send's round trips land.
    Future<void> sendReply(WidgetTester tester, String body) async {
      final field = find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, body);
      await tester.pump();
      await tester.tap(find.descendant(
        of: find.byType(Composer),
        matching: find.text('Send'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await settleQueues(tester);
    }

    /// The thread the open panel is showing, wherever it is drawn.
    String? openThread(WidgetTester tester) {
      final panels = tester.widgetList<ThreadDetailPanel>(
        find.byType(ThreadDetailPanel),
      );
      return panels.isEmpty ? null : panels.last.conversation.subject;
    }

    /// Two rows down — Invoice 4471 open beside — with a composer that can
    /// send.
    Future<_SendingMail> openInvoice(WidgetTester tester) async {
      final mail = _SendingMail();
      await seedPile();
      await pumpInbox(tester, mail: mail);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyJ);
      // The capability read the composer waits on before it arms.
      await tester.pump();
      await tester.pump();
      expect(litRow(tester), 'Invoice 4471');
      return mail;
    }

    /// `r` on the open row, words into the in-list box, and its Send — the
    /// reply the keyboard flow makes. The box hands the cursor back to the
    /// list when it goes, which is what leaves `j` and `k` live afterwards;
    /// the docked composer keeps the cursor, where a letter is a letter.
    Future<void> quickReply(WidgetTester tester, String body) async {
      await press(tester, LogicalKeyboardKey.keyR);
      await tester.enterText(find.byKey(QuickReplyBox.fieldKey), body);
      await tester.pump();
      await tester.tap(find.byKey(QuickReplyBox.sendKey));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await settleQueues(tester);
    }

    testWidgets('the in-list box comes back after the same refusal twice',
        (tester) async {
      final mail = _RefusingMail();
      await seedPile();
      await pumpInbox(tester, mail: mail);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyJ);
      await tester.pump();
      await tester.pump();

      await press(tester, LogicalKeyboardKey.keyR);
      await tester.enterText(find.byKey(QuickReplyBox.fieldKey), 'On it.');
      await tester.pump();
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(QuickReplyBox.sendKey));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        await settleQueues(tester);
      }

      // Two presses reached the backend, and the second one's answer (word
      // for word the first's) still gave the box back: the words are there
      // for a retry, not frozen under "Sending…".
      expect(mail.drafts, 2);
      expect(find.byKey(QuickReplyBox.fieldKey), findsOneWidget);
      expect(find.text('Sending…'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(QuickReplyBox.fieldKey))
            .controller!
            .text,
        'On it.',
      );
      await settleQueues(tester);
    });

    testWidgets('j after a reply opens the row that stood under it',
        (tester) async {
      final mail = await openInvoice(tester);

      await quickReply(tester, 'Signed and sent back.');

      expect(mail.bodies, ['Signed and sent back.']);
      expect(find.text('Reply sent.'), findsOneWidget);
      // Waiting now, so off Needs You — and still open beside, because the
      // preference that would clear it is off.
      expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
      expect(openThread(tester), 'Invoice 4471');
      unhandled.clear();

      await press(tester, LogicalKeyboardKey.keyJ);

      expect(unhandled, isEmpty);
      expect(litRow(tester), 'Vendor quote');
      expect(openThread(tester), 'Vendor quote');
      await settleQueues(tester);
    });

    testWidgets('k after a reply opens the row that stood above it',
        (tester) async {
      await openInvoice(tester);

      await quickReply(tester, 'Signed and sent back.');
      expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
      expect(openThread(tester), 'Invoice 4471');

      await press(tester, LogicalKeyboardKey.keyK);

      expect(litRow(tester), 'Homepage copy');
      expect(openThread(tester), 'Homepage copy');
      await settleQueues(tester);
    });

    testWidgets('with reply-marks-done on, the reader lands on the next row '
        'and the progress line counts it', (tester) async {
      await store.setPref(replySendMarksDoneKey, 'true');
      await openInvoice(tester);

      await sendReply(tester, 'Signed and sent back.');

      expect(find.text('Reply sent · Marked done.'), findsOneWidget);
      expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);
      // Nothing pressed: the send's own mark-done took `e`'s landing.
      expect(litRow(tester), 'Vendor quote');
      expect(openThread(tester), 'Vendor quote');
      expect(find.text('1 of 3 cleared'), findsOneWidget);
      final stored = await store.loadConversations();
      expect(
        [for (final c in stored) if (c.state == ConversationState.done) c.id],
        ['c2'],
      );
      await settleQueues(tester);
    });

    testWidgets('a thread opened from Archive was never in the pile, so j '
        'goes nowhere from it', (tester) async {
      await seedPile();
      final received = ago(4);
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'c9-m1',
        'conversation_key': 'c9',
        'direction': 'inbound',
        'subject': 'Old contract',
        'from_name': 'Dana Whitfield',
        'from_address': 'dana@example.com',
        'received_at': received,
        'body_text': 'the hero paragraph',
      });
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c9',
        'subject': 'Old contract',
        'participants_json':
            '[{"name":"Dana Whitfield","email":"dana@example.com"}]',
        'state': 'done',
        'last_message_at': received,
        'last_inbound_at': received,
      });
      await pumpInbox(tester, section: RailSection.archive);
      await tester.tap(find.widgetWithText(BondFilterPill, 'Done'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Old contract').first);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(openThread(tester), 'Old contract');

      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyK);

      // Stepping "next" from here would teleport the reader to the top of a
      // pile they are not on.
      expect(openThread(tester), 'Old contract');
      await settleQueues(tester);
    });
  });

  group('a failed mark-done never reads as a success', () {
    Finder undo() => find.text('Undo');

    testWidgets('e whose write fails says so, offers no Undo, counts nothing '
        'and leaves the reader where they were', (tester) async {
      final held = _RefusingStore(db)..refuseDoneWrite = true;
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(litRow(tester), 'Invoice 4471');

      await press(tester, LogicalKeyboardKey.keyE);
      await settleQueues(tester);

      expect(find.text("Couldn't mark that thread done just now."),
          findsOneWidget);
      expect(find.text('Marked done.'), findsNothing);
      expect(undo(), findsNothing);
      expect(
        rowTitles(tester),
        ['Homepage copy', 'Invoice 4471', 'Vendor quote'],
      );
      expect(litRow(tester), 'Invoice 4471');
      expect(find.byKey(ConversationListPane.progressKey), findsNothing);
      unhandled.clear();

      // The keys still answer: the cursor came back to the list.
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(unhandled, isEmpty);
      expect(litRow(tester), 'Vendor quote');
      await settleQueues(tester);
    });

    testWidgets('Shift+E whose done write fails says so, with no Undo',
        (tester) async {
      await store.createLabel('FYI only');
      final held = _RefusingStore(db)..refuseDoneWrite = true;
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyE, shift: true);

      await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleQueues(tester);
      await tester.pump();

      expect(find.text("Couldn't mark that thread done just now."),
          findsOneWidget);
      expect(find.textContaining('Marked done'), findsNothing);
      expect(undo(), findsNothing);
      expect(litRow(tester), 'Homepage copy');
      expect(rowTitles(tester), hasLength(3));
      expect(find.byKey(ConversationListPane.progressKey), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('Shift+E whose label write fails is done without the word, '
        'and says so', (tester) async {
      await store.createLabel('FYI only');
      final held = _RefusingStore(db, refuseApply: true);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyE, shift: true);

      await tester.enterText(find.byKey(LabelPicker.fieldKey), 'fyi');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleQueues(tester);
      await tester.pump();

      expect(find.text("Marked done. Couldn't add FYI only just now."),
          findsOneWidget);
      expect(find.text('Marked done · FYI only.'), findsNothing);
      // The thread did leave, so the reader moves on and z brings it back.
      expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
      expect(litRow(tester), 'Invoice 4471');
      expect(await store.labelsForConversation('email', 'c1'), isEmpty);

      await press(tester, LogicalKeyboardKey.keyZ);
      await settleQueues(tester);
      expect(
        rowTitles(tester),
        ['Homepage copy', 'Invoice 4471', 'Vendor quote'],
      );
      await settleQueues(tester);
    });

    testWidgets('a reply whose mark-done fails says the reply went and the '
        'thread is not done', (tester) async {
      await store.setPref(replySendMarksDoneKey, 'true');
      final held = _RefusingStore(db)..refuseDoneWrite = true;
      final mail = _SendingMail();
      await seedPile();
      await pumpInbox(tester, storeAs: held, mail: mail);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyJ);
      await tester.pump();
      await tester.pump();
      expect(litRow(tester), 'Invoice 4471');

      await tester.enterText(
        find.descendant(
          of: find.byType(Composer),
          matching: find.byType(TextField),
        ),
        'Signed and sent back.',
      );
      await tester.pump();
      await tester.tap(find.descendant(
        of: find.byType(Composer),
        matching: find.text('Send'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await settleQueues(tester);

      expect(mail.bodies, ['Signed and sent back.']);
      expect(find.text("Reply sent. Couldn't mark it done."), findsOneWidget);
      expect(find.text('Reply sent · Marked done.'), findsNothing);
      expect(undo(), findsNothing);
      expect(find.byKey(ConversationListPane.progressKey), findsNothing);
      final stored = await store.loadConversations();
      expect(
        [for (final c in stored) if (c.state == ConversationState.done) c.id],
        isEmpty,
      );
      // No landing: the thread the reader answered is still the one open.
      final panels = tester.widgetList<ThreadDetailPanel>(
        find.byType(ThreadDetailPanel),
      );
      expect(panels.last.conversation.subject, 'Invoice 4471');
      await settleQueues(tester);
    });
  });

  group('Enter in Find with nothing matching', () {
    Future<void> submitFind(WidgetTester tester, String needle) async {
      final field = find.descendant(
        of: find.byType(FindField),
        matching: find.byType(TextField),
      );
      await tester.showKeyboard(field);
      await tester.enterText(field, needle);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    RailSection? stop(WidgetTester tester) =>
        tester.widget<IconRail>(find.byType(IconRail)).selected;

    testWidgets('a facet needle stays put rather than becoming a Home search',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);
      expect(stop(tester), RailSection.needsYou);

      await submitFind(tester, 'is:done');

      // Home's search reads text, so "is:done" there would be a search for
      // the literal string.
      expect(stop(tester), RailSection.needsYou);
      expect(find.byType(ConversationListPane), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('a label: needle stays put too', (tester) async {
      await seedPile();
      await pumpInbox(tester);

      await submitFind(tester, 'label:Receipts');

      expect(stop(tester), RailSection.needsYou);
      await settleQueues(tester);
    });

    testWidgets('from: is Home grammar, so a from: needle still escalates',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);

      await submitFind(tester, 'from:dana budget');

      expect(stop(tester), RailSection.home);
      await settleQueues(tester);
    });

    testWidgets('a plain word nothing on the rail answers still goes to Home',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);

      await submitFind(tester, 'zebracorn');

      expect(stop(tester), RailSection.home);
      await settleQueues(tester);
    });
  });

  group('a minted label files the thread it was minted for', () {
    testWidgets('Shift+E, a new word, Enter twice while the create is out: '
        'one label, one done, one z back', (tester) async {
      final held = _RefusingStore(db);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(litRow(tester), 'Homepage copy');
      await press(tester, LogicalKeyboardKey.keyE, shift: true);
      held.holdCreate = Completer<void>();

      await tester.enterText(
          find.byKey(LabelPicker.fieldKey), 'Vendor outreach');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      // The second Enter, on a box the first one cleared, while the write is
      // still out: with the strip live it would have been "mark done with no
      // label", a second act on the same thread.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(LabelPicker.fieldKey), findsNothing);
      expect(find.text('Marked done.'), findsNothing);

      held.holdCreate!.complete();
      await settleQueues(tester);
      await tester.pump();
      await tester.pump();

      expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
      expect(litRow(tester), 'Invoice 4471');
      expect(find.text('Marked done · Vendor outreach.'), findsOneWidget);
      expect(find.text('Marked done.'), findsNothing);
      expect([for (final l in await store.listLabels()) l.name],
          ['Vendor outreach']);
      expect(
        [for (final l in await store.labelsForConversation('email', 'c1'))
          l.name],
        ['Vendor outreach'],
      );

      await press(tester, LogicalKeyboardKey.keyZ);
      await settleQueues(tester);

      // What undoMarkDone restores: the thread back in its place and the
      // link this dismissal made taken off; the word stays in the vocabulary.
      expect(
        rowTitles(tester),
        ['Homepage copy', 'Invoice 4471', 'Vendor quote'],
      );
      expect(await store.labelsForConversation('email', 'c1'), isEmpty);
      await settleQueues(tester);
    });

    testWidgets('l, a new word, Enter, then Escape before the write lands: '
        'filed and not marked done', (tester) async {
      final held = _RefusingStore(db);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(litRow(tester), 'Invoice 4471');
      await press(tester, LogicalKeyboardKey.keyL);
      held.holdCreate = Completer<void>();

      await tester.enterText(find.byKey(LabelPicker.fieldKey), 'Receipts');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await press(tester, LogicalKeyboardKey.escape);

      held.holdCreate!.complete();
      await settleQueues(tester);
      await tester.pump();
      await tester.pump();

      expect(
        rowTitles(tester),
        ['Homepage copy', 'Invoice 4471', 'Vendor quote'],
      );
      expect(find.text('Labeled Receipts.'), findsOneWidget);
      expect(
        [for (final l in await store.labelsForConversation('email', 'c2'))
          l.name],
        ['Receipts'],
      );
      final stored = await store.loadConversations();
      expect(
        [for (final c in stored) if (c.state == ConversationState.done) c.id],
        isEmpty,
      );
      await settleQueues(tester);
    });

    testWidgets('Shift+E, a new word, Enter, then Escape mid-write: still '
        'marked done under the word', (tester) async {
      final held = _RefusingStore(db);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyE, shift: true);
      held.holdCreate = Completer<void>();

      await tester.enterText(find.byKey(LabelPicker.fieldKey), 'Receipts');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      // Escape used to close the request mid-write, and the apply then read
      // the closed request as "keep with a label".
      await press(tester, LogicalKeyboardKey.escape);

      held.holdCreate!.complete();
      await settleQueues(tester);
      await tester.pump();
      await tester.pump();

      expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
      expect(find.text('Marked done · Receipts.'), findsOneWidget);
      expect(
        [for (final l in await store.labelsForConversation('email', 'c1'))
          l.name],
        ['Receipts'],
      );
      await settleQueues(tester);
    });
  });

  group('destructive keys, one act at a time', () {
    testWidgets('e held down clears one thread, not a run of them',
        (tester) async {
      await seedPile();
      await pumpInbox(tester);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(litRow(tester), 'Homepage copy');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await settleQueues(tester);

      expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
      expect(litRow(tester), 'Invoice 4471');
      await settleQueues(tester);
    });

    testWidgets('a row clicked while e is still writing is where the reader '
        'stays', (tester) async {
      final held = _RefusingStore(db);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(litRow(tester), 'Homepage copy');
      held.holdStateWrite = Completer<void>();

      await press(tester, LogicalKeyboardKey.keyE);
      await tester.tap(find.descendant(
        of: find.byType(ConversationListPane),
        matching: find.text('Vendor quote'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(litRow(tester), 'Vendor quote');

      held.holdStateWrite!.complete();
      await settleQueues(tester);
      await tester.pump();

      // Not the computed landing (Invoice 4471): the click came after the
      // press, and it is the reader's.
      expect(litRow(tester), 'Vendor quote');
      expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
      await settleQueues(tester);
    });
  });

  group('review fixes', () {
    /// Types into the open thread's docked composer and presses its Send.
    Future<void> composerSend(WidgetTester tester, String body) async {
      await tester.enterText(
        find.descendant(
          of: find.byType(Composer),
          matching: find.byType(TextField),
        ),
        body,
      );
      await tester.pump();
      await tester.tap(find.descendant(
        of: find.byType(Composer),
        matching: find.text('Send'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await settleQueues(tester);
    }

    /// `r`, words into the in-list box, and its Send.
    Future<void> quickReply(WidgetTester tester, String body) async {
      await press(tester, LogicalKeyboardKey.keyR);
      await tester.enterText(find.byKey(QuickReplyBox.fieldKey), body);
      await tester.pump();
      await tester.tap(find.byKey(QuickReplyBox.sendKey));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await settleQueues(tester);
    }

    String? openThread(WidgetTester tester) {
      final panels = tester.widgetList<ThreadDetailPanel>(
        find.byType(ThreadDetailPanel),
      );
      return panels.isEmpty ? null : panels.last.conversation.subject;
    }

    Future<List<String>> doneKeys() async => [
          for (final c in await store.loadConversations())
            if (c.state == ConversationState.done) c.id,
        ];

    testWidgets('a create that fails says so and hands the keys back',
        (tester) async {
      final held = _RefusingStore(db)..refuseCreate = true;
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyL);

      await tester.enterText(find.byKey(LabelPicker.fieldKey), 'Receipts');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleQueues(tester);
      await tester.pump();

      expect(find.text("Couldn't save that label just now."), findsOneWidget);
      expect(find.byKey(LabelPicker.fieldKey), findsNothing);
      unhandled.clear();

      // The strip the cursor was in is gone; the list has it now.
      await press(tester, LogicalKeyboardKey.keyJ);

      expect(unhandled, isEmpty);
      expect(litRow(tester), 'Invoice 4471');
      await settleQueues(tester);
    });

    testWidgets('a second e while the first is still writing is dropped',
        (tester) async {
      final held = _RefusingStore(db);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(litRow(tester), 'Homepage copy');
      held.holdStateWrite = Completer<void>();

      await press(tester, LogicalKeyboardKey.keyE);
      // A fresh press, not a repeat: `includeRepeats` has nothing to say
      // about it, so only the one-act latch stands between it and a second
      // mark-done of the same thread.
      await press(tester, LogicalKeyboardKey.keyE);

      held.holdStateWrite!.complete();
      await settleQueues(tester);
      await tester.pump();

      expect(held.stateWrites, ['c1']);
      expect(await doneKeys(), ['c1']);
      expect(rowTitles(tester), ['Invoice 4471', 'Vendor quote']);
      expect(litRow(tester), 'Invoice 4471');
      await settleQueues(tester);
    });

    testWidgets('a picker apply that lands behind a running act waits its '
        'turn rather than vanishing', (tester) async {
      final held = _RefusingStore(db);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(litRow(tester), 'Homepage copy');
      await press(tester, LogicalKeyboardKey.keyE, shift: true);

      // Shift+E on Homepage copy, a new word, Enter — with the create held.
      held.holdCreate = Completer<void>();
      await tester.enterText(find.byKey(LabelPicker.fieldKey), 'Receipts');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();

      // Meanwhile the reader opens Invoice 4471 and presses e on it, and that
      // act's write is held too, so it owns the latch when the create lands.
      await tester.tap(find.descendant(
        of: find.byType(ConversationListPane),
        matching: find.text('Invoice 4471'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(litRow(tester), 'Invoice 4471');
      held.holdStateWrite = Completer<void>();
      await press(tester, LogicalKeyboardKey.keyE);

      held.holdCreate!.complete();
      await tester.pump();
      await tester.pump();
      held.holdStateWrite!.complete();
      await settleQueues(tester);
      await tester.pump();
      await tester.pump();

      // Both acts happened: the e on Invoice 4471, and Homepage copy done
      // UNDER the word minted for it.
      expect(held.stateWrites, ['c2', 'c1']);
      expect(await doneKeys(), unorderedEquals(['c1', 'c2']));
      expect(
        [for (final l in await store.labelsForConversation('email', 'c1'))
          l.name],
        ['Receipts'],
      );
      expect(rowTitles(tester), ['Vendor quote']);
      expect(find.text('Marked done · Receipts.'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('a reply that clears the last row of the pile is counted',
        (tester) async {
      await store.setPref(needsYouSortKey, 'newest');
      await store.setPref(replySendMarksDoneKey, 'true');
      await seedThread('c1', 'Homepage copy', 'Confirm the launch date',
          hoursAgo: 1);
      await pumpInbox(tester, mail: _SendingMail());
      await press(tester, LogicalKeyboardKey.keyJ);
      await tester.pump();
      await tester.pump();
      expect(litRow(tester), 'Homepage copy');

      await quickReply(tester, 'Confirmed for the 14th.');

      expect(find.text('Reply sent · Marked done.'), findsOneWidget);
      expect(rowTitles(tester), isEmpty);
      final pane = tester.widget<ConversationListPane>(
        find.byType(ConversationListPane),
      );
      expect(pane.progress, (cleared: 1, total: 1));
      await settleQueues(tester);
    });

    testWidgets('e on the last row after a reply took it off still counts',
        (tester) async {
      // The departed path proper: the reply (preference off) takes the only
      // row off the pile and the reader is still on it, so `e` finds it in
      // the snapshot with no neighbour either side to land on.
      await store.setPref(needsYouSortKey, 'newest');
      await seedThread('c1', 'Homepage copy', 'Confirm the launch date',
          hoursAgo: 1);
      await pumpInbox(tester, mail: _SendingMail());
      await press(tester, LogicalKeyboardKey.keyJ);
      await tester.pump();
      await tester.pump();
      await quickReply(tester, 'Confirmed for the 14th.');
      expect(rowTitles(tester), isEmpty);
      expect(openThread(tester), 'Homepage copy');

      await press(tester, LogicalKeyboardKey.keyE);
      await settleQueues(tester);

      expect(find.text('Marked done.'), findsOneWidget);
      final pane = tester.widget<ConversationListPane>(
        find.byType(ConversationListPane),
      );
      expect(pane.progress, (cleared: 1, total: 1));
      await settleQueues(tester);
    });

    testWidgets('a panel over a replied thread does not make it forget where '
        'it stood', (tester) async {
      await seedPile();
      await pumpInbox(tester, mail: _SendingMail());
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyJ);
      await tester.pump();
      await tester.pump();
      expect(litRow(tester), 'Invoice 4471');
      await quickReply(tester, 'Signed and sent back.');
      expect(rowTitles(tester), ['Homepage copy', 'Vendor quote']);

      // The sheet goes ON the thread, which hides it from the keys without
      // closing it — the cheap twin of a file opened from its attachment.
      await pressQuestionMark(tester);
      expect(find.byType(CheatSheetBody), findsOneWidget);
      await settleQueues(tester);
      await press(tester, LogicalKeyboardKey.escape);
      expect(openThread(tester), 'Invoice 4471');

      await press(tester, LogicalKeyboardKey.keyJ);

      expect(litRow(tester), 'Vendor quote');
      expect(openThread(tester), 'Vendor quote');
      await settleQueues(tester);
    });

    testWidgets('a reply on a thread from Archive is marked done where it '
        'stands, and stays open', (tester) async {
      await store.setPref(replySendMarksDoneKey, 'true');
      await seedPile();
      final received = ago(4);
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'c9-m1',
        'conversation_key': 'c9',
        'direction': 'inbound',
        'subject': 'Old contract',
        'from_name': 'Dana Whitfield',
        'from_address': 'dana@example.com',
        'received_at': received,
        'body_text': 'the hero paragraph',
      });
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c9',
        'subject': 'Old contract',
        'participants_json':
            '[{"name":"Dana Whitfield","email":"dana@example.com"}]',
        'state': 'done',
        'last_message_at': received,
        'last_inbound_at': received,
      });
      final mail = _SendingMail();
      await pumpInbox(tester, mail: mail, section: RailSection.archive);
      await tester.tap(find.widgetWithText(BondFilterPill, 'Done'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Old contract').first);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(openThread(tester), 'Old contract');

      await composerSend(tester, 'Countersigned, thanks.');

      expect(mail.bodies, ['Countersigned, thanks.']);
      expect(find.text('Reply sent · Marked done.'), findsOneWidget);
      // No pile under it: no landing on a Needs You row, and no close.
      expect(openThread(tester), 'Old contract');
      expect(await doneKeys(), ['c9']);
      await settleQueues(tester);
    });

    testWidgets('a create that lands after l on another thread leaves that '
        'picker open', (tester) async {
      final held = _RefusingStore(db);
      await seedPile();
      await pumpInbox(tester, storeAs: held);
      await press(tester, LogicalKeyboardKey.keyJ);
      await press(tester, LogicalKeyboardKey.keyL);
      held.holdCreate = Completer<void>();
      await tester.enterText(find.byKey(LabelPicker.fieldKey), 'Receipts');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();

      // The reader moves on to Invoice 4471 and asks for its picker.
      await tester.tap(find.descendant(
        of: find.byType(ConversationListPane),
        matching: find.text('Invoice 4471'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyL);
      expect(find.byKey(LabelPicker.fieldKey), findsOneWidget);

      held.holdCreate!.complete();
      await settleQueues(tester);
      await tester.pump();

      // Homepage copy got its word; Invoice 4471's picker is still up.
      expect(
        [for (final l in await store.labelsForConversation('email', 'c1'))
          l.name],
        ['Receipts'],
      );
      expect(find.byKey(LabelPicker.fieldKey), findsOneWidget);
      await settleQueues(tester);
    });
  });
}
