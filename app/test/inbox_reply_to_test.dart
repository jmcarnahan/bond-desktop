// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/composer.dart' show Composer;
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/hover_actions.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/why_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The docked composer, and the message a send is addressed to.
///
/// Only the assembled screen knows both halves of this: the box is under the
/// transcript whether or not anybody asked for it, and the hover **Reply**
/// overrides which message the send answers. The failure worth a whole file is
/// a caption that outlived its send — a reply the user meant for Monday's mail
/// quietly steering the next one.

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

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// Records which message each reply was built against. Everything else throws:
/// a thread pane has no business reaching any other mail call.
class _RecordingMail implements MailBackend {
  final List<String> calls = [];
  final List<String> bodies = [];

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async {
    calls.add('createReply:$messageId');
    return const {
      'id': 'graph-draft-1',
      'webLink': 'https://outlook.example/draft-1',
    };
  }

  @override
  Future<void> updateDraftBody(String draftId, String text) async {
    calls.add('updateBody:$draftId');
    bodies.add(text);
  }

  @override
  Future<SentDraft> sendDraft(String draftId) async {
    calls.add('send:$draftId');
    return SentDraft(draftId: draftId);
  }

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Everything a send needs, so the box is armed rather than offering a copy.
const String _sendGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Mail.ReadWrite '
    'https://graph.microsoft.com/Mail.Send';

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _RecordingMail mail;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    mail = _RecordingMail();
  });

  tearDown(() => db.close());

  /// One mail thread with two inbound messages from two different people, so
  /// "which message" and "which sender" are separate questions with separate
  /// answers.
  Future<void> seedThread() async {
    await store.upsertMessage({
      'source_message_id': 'c1-m1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Eric Vance',
      'from_address': 'eric@example.com',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'The homepage copy is in.',
    });
    await store.upsertMessage({
      'source_message_id': 'c1-m2',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Sarah Whitfield',
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-28T15:00:00Z',
      'body_text': 'Also — can you make Friday?',
    });
    await store.upsertConversation({
      'conversation_key': 'c1',
      'subject': 'Homepage copy',
      'participants_json': '[{"name":"Eric Vance","email":"eric@example.com"},'
          '{"name":"Sarah Whitfield","email":"sarah@example.com"}]',
      'state': 'needs_reply',
      'cta_text': 'Confirm the Friday date',
      'last_message_at': '2026-08-28T15:00:00Z',
      'last_inbound_at': '2026-08-28T15:00:00Z',
    });
    await store.recomputeConversationCounts('email', 'c1');
  }

  /// A second thread, so selecting away from the first one is something the
  /// test can actually do.
  Future<void> seedOtherThread() async {
    await store.upsertMessage({
      'source_message_id': 'c2-m1',
      'conversation_key': 'c2',
      'direction': 'inbound',
      'subject': 'Launch date',
      'from_name': 'Dana Ruiz',
      'from_address': 'dana@example.com',
      'received_at': '2026-08-27T09:00:00Z',
      'body_text': 'Are we still on for the 14th?',
    });
    await store.upsertConversation({
      'conversation_key': 'c2',
      'subject': 'Launch date',
      'participants_json': '[{"name":"Dana Ruiz","email":"dana@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': '2026-08-27T09:00:00Z',
      'last_inbound_at': '2026-08-27T09:00:00Z',
    });
    await store.recomputeConversationCounts('email', 'c2');
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((_) async => http.Response('{}', 200));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = _sendGrant;
    final auth = GraphAuth(httpClient: client, store: tokens);
    // The app's default backend is MCP, whose session would answer the scope
    // question by asking a server that is not there.
    await store.setPref(backendModeKey, backendModeSdk);
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.people),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        mailBackendProvider.overrideWithValue(mail),
        syncServiceProvider.overrideWithValue(_FakeSync()),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Pumps rather than a settle: this screen owns a sixty-second periodic
    // timer, and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Opens one thread from the overview beside the column.
  Future<void> openThread(WidgetTester tester, String who) async {
    await tester.tap(find.descendant(
      of: find.byType(ConversationListPane),
      matching: find.text(who),
    ));
    // The tap, the transcript read, then the capability the box waits on.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Puts a MOUSE over one message's row, which is what brings its strip up.
  Future<void> hoverRow(WidgetTester tester, String id) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byKey(ValueKey(id))));
    await tester.pump();
  }

  /// Types into the docked box and presses Send, then lets the round trips
  /// land.
  Future<void> sendText(WidgetTester tester, String body) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      ),
      body,
    );
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Finder composerField() => find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      );

  testWidgets('the box is under the thread the moment it opens, addressed',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester, 'Eric Vance');

    // Docked, always: a thread that can be answered says where the answer
    // goes without being asked for it.
    expect(find.byType(Composer), findsOneWidget);
    expect(
      tester.widget<Composer>(find.byType(Composer)).hint,
      'Reply to Eric Vance…',
    );
    // And nothing has been named yet, so there is no caption over it.
    expect(find.byKey(const Key('replying-to')), findsNothing);
  });

  testWidgets('hover Reply on the older message steers the send to it',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester, 'Eric Vance');

    await hoverRow(tester, 'c1-m1');
    await tester.tap(find.byKey(HoverActions.replyKeyFor('c1-m1')));
    await tester.pump();

    // The caption names the SENDER of the message, which may have scrolled
    // away by now.
    expect(find.text('Replying to Eric Vance'), findsOneWidget);

    await sendText(tester, 'Got it, thanks.');

    // The whole point: the answer goes to the message that was named, not to
    // the newest one in the thread.
    expect(mail.calls.first, 'createReply:c1-m1');
    expect(mail.bodies, ['Got it, thanks.']);
    // The caption goes with the send: one that outlived it would steer the
    // next reply too.
    expect(find.byKey(const Key('replying-to')), findsNothing);
  });

  testWidgets('the ✕ takes the name off, and the send falls back to the newest',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester, 'Eric Vance');

    await hoverRow(tester, 'c1-m1');
    await tester.tap(find.byKey(HoverActions.replyKeyFor('c1-m1')));
    await tester.pump();
    expect(find.text('Replying to Eric Vance'), findsOneWidget);

    await tester.tap(find.byTooltip('Cancel reply'));
    await tester.pump();

    expect(find.byKey(const Key('replying-to')), findsNothing);

    await sendText(tester, 'Friday works.');

    // Unnamed is the ordinary case, and it resolves the way it always did.
    expect(mail.calls.first, 'createReply:c1-m2');
  });

  testWidgets('the name does not follow the reader to another thread',
      (tester) async {
    await seedThread();
    await seedOtherThread();
    await pumpScreen(tester);
    await openThread(tester, 'Eric Vance');

    await hoverRow(tester, 'c1-m1');
    await tester.tap(find.byKey(HoverActions.replyKeyFor('c1-m1')));
    await tester.pump();
    expect(find.text('Replying to Eric Vance'), findsOneWidget);

    // No way back to walk: a row on the People overview opens BESIDE now, so
    // the list the reader came from is still under their eyes and the next
    // thread is one tap away in it.
    await openThread(tester, 'Dana Ruiz');

    // A message named on one thread must never be the target of a send from
    // the next one.
    expect(find.byKey(const Key('replying-to')), findsNothing);
    expect(
      tester.widget<Composer>(find.byType(Composer)).hint,
      'Reply to Dana Ruiz…',
    );
  });

  testWidgets('the ask banner explains the ask rather than opening the box',
      (tester) async {
    // Rewritten in Phase 6. The box is docked and visible, so "put the cursor
    // in it" is a click nobody needed help with; where the ask came from had
    // no answer anywhere until the Why panel.
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester, 'Eric Vance');
    // ⤢ first: a row on the People overview opens BESIDE now, and one thing at
    // a time lives on that side of the seam — so a Why opened from a thread
    // still in the side panel would take the thread's place, box and all. The
    // question here is about the box, so the thread is given the main pane
    // the way a reader who wants to work in it would.
    await tester.tap(find.byKey(SidePanelHost.expandKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(tester.widget<TextField>(composerField()).focusNode?.hasFocus,
        isFalse);

    await tester.tap(find.text('Confirm the Friday date'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.byType(WhyPanelBody), findsOneWidget);
    expect(
      tester.widget<TextField>(composerField()).focusNode?.hasFocus,
      isFalse,
    );
  });

  testWidgets('an outbound row wears no strip at all', (tester) async {
    await seedThread();
    await store.upsertMessage({
      'source_message_id': 'c1-m3',
      'conversation_key': 'c1',
      'direction': 'outbound',
      'subject': 'Homepage copy',
      'received_at': '2026-08-28T16:00:00Z',
      'body_text': 'On it.',
    });
    await store.recomputeConversationCounts('email', 'c1');
    await pumpScreen(tester);
    await openThread(tester, 'Eric Vance');

    await hoverRow(tester, 'c1-m3');

    // There is nothing to reply to on the user's own message.
    expect(find.byKey(HoverActions.replyKeyFor('c1-m3')), findsNothing);
    expect(find.byKey(HoverActions.suggestKeyFor('c1-m3')), findsNothing);
  });
}
