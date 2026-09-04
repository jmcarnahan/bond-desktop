// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/composer.dart' show Composer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// A suggestion sits with the message it answers.
///
/// Only the assembled screen knows all three things this file is about: which
/// messages a thread holds, which of them still carry a live suggestion, and
/// which message a tapped card is therefore replying TO. The transcript can
/// show several cards at once now, so the one thing that must never be true is
/// a card sending to the wrong message — an answer to what was asked on Monday
/// arriving as a reply to Thursday's mail.

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
  Future<void> sendDraft(String draftId) async => calls.add('send:$draftId');

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Everything a send needs, so a tapped card actually goes.
const String _sendGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Mail.ReadWrite '
    'https://graph.microsoft.com/Mail.Send';

/// Read-only. A card tapped under this grant opens the composer instead.
const String _readGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

const String _olderOptions =
    '[{"stance":"Confirm receipt","body":"Got it, thanks."},'
    '{"stance":"Ask for a deadline","body":"When do you need this by?"}]';

const String _newerOptions =
    '[{"stance":"Say yes","body":"Yes, Friday works."},'
    '{"stance":"Push back","body":"Friday is tight — could we say Tuesday?"}]';

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

  /// One mail thread with TWO messages the model answered — the shape the
  /// inline cards exist for. Neither has been replied to, so both suggestions
  /// are still live.
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
      'from_name': 'Eric Vance',
      'from_address': 'eric@example.com',
      'received_at': '2026-08-28T15:00:00Z',
      'body_text': 'Also — can you make Friday?',
    });
    await store.upsertConversation({
      'conversation_key': 'c1',
      'subject': 'Homepage copy',
      'participants_json': '[{"name":"Eric Vance","email":"eric@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': '2026-08-28T15:00:00Z',
      'last_inbound_at': '2026-08-28T15:00:00Z',
    });
    await store.recomputeConversationCounts('email', 'c1');
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c1',
      replyToMessageId: 'c1-m1',
      body: 'Got it, thanks — I will review it today.',
      optionsJson: _olderOptions,
    );
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'c1',
      replyToMessageId: 'c1-m2',
      body: 'Yes, Friday works for me.',
      optionsJson: _newerOptions,
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    String grantedScopes = _sendGrant,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((_) async => http.Response('{}', 200));
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = grantedScopes;
    final auth = GraphAuth(httpClient: client, store: tokens);
    // The app's default backend is MCP, whose session would answer the scope
    // question by asking a server that is not there. Said in the store because
    // that is where the app reads it, once, at construction.
    await store.setPref(backendModeKey, backendModeSdk);
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
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

  Future<void> openThread(WidgetTester tester) async {
    await tester.tap(find.text('Eric Vance').first);
    // The tap, the transcript read, then the capability the cards wait on.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Lets the undo window close and the send's own round trips land.
  Future<void> elapseUndoWindow(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  /// One message's row, by the key the transcript gives it.
  Finder rowFor(String id) => find.byKey(ValueKey(id));

  testWidgets('every message that still has one carries its own cards',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);

    await openThread(tester);

    // Two suggestions, two sets of cards — each under the message it answers.
    expect(find.text('Confirm receipt'), findsOneWidget);
    expect(find.text('Say yes'), findsOneWidget);
    expect(
      find.descendant(
        of: rowFor('c1-m1'),
        matching: find.text('Confirm receipt'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rowFor('c1-m2'), matching: find.text('Say yes')),
      findsOneWidget,
    );
  });

  testWidgets('an older card replies to its OWN message, not the newest',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.text('Confirm receipt'));
    await tester.pump();
    await tester.pump();
    await elapseUndoWindow(tester);

    // The whole point: the answer to what was asked first goes to the message
    // that asked it.
    expect(mail.calls.first, 'createReply:c1-m1');
    expect(mail.bodies, ['Got it, thanks.']);
    expect(
      (await store.getDraftForMessage('email', 'c1-m1'))!['status'],
      'sent',
    );
    // Nobody answered the newer message, so its suggestion is still on offer.
    expect(
      (await store.getDraftForMessage('email', 'c1-m2'))!['status'],
      'suggested',
    );
  });

  testWidgets('queueing a send closes every card while it is undoable',
      (tester) async {
    // The optimistic bubble is an outbound message after both of them, and a
    // card that can be tapped is a card that can send: a second reply must not
    // be one click away from a send the user can still take back.
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.text('Confirm receipt'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Confirm receipt'), findsNothing);
    expect(find.text('Say yes'), findsNothing);
    // Twice over, and both are the point: the reply is in the transcript where
    // it will land, and the undo row under it is still offering it back.
    expect(find.text('Sending…'), findsNWidgets(2));

    // Let the queued send land rather than leaving a timer running past the
    // test.
    await elapseUndoWindow(tester);
  });

  testWidgets('the × closes one message\'s cards and leaves the other\'s',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.descendant(
      of: rowFor('c1-m1'),
      matching: find.byIcon(Icons.close),
    ));
    await tester.pump();

    // The two-step stands where a confirm dialog would, on the card it is
    // about.
    expect(find.text('Dismiss these suggestions?'), findsOneWidget);
    expect(find.text('Confirm receipt'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Confirm receipt'), findsNothing);
    expect(find.text('Ask for a deadline'), findsNothing);
    // A dismissal addressed by conversation would have taken these with it.
    expect(find.text('Say yes'), findsOneWidget);
    expect(
      (await store.getDraftForMessage('email', 'c1-m2'))!['options_dismissed'],
      0,
    );
  });

  testWidgets('the bar under the transcript keeps the way into the composer',
      (tester) async {
    // The cards moved to the messages; `Reply…` is about the thread and stays
    // where it was, once, at the bottom.
    await seedThread();
    await pumpScreen(tester);

    await openThread(tester);

    expect(find.text('Reply…'), findsOneWidget);
  });

  testWidgets('without a send grant a card opens the composer instead',
      (tester) async {
    // The honest version of the gesture: nothing in this build could put that
    // mail in front of anyone, so nothing pretends to.
    await seedThread();
    await pumpScreen(tester, grantedScopes: _readGrant);
    await openThread(tester);

    await tester.tap(find.text('Confirm receipt'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(mail.calls, isEmpty);
    expect(find.widgetWithText(Composer, 'Got it, thanks.'), findsOneWidget);
  });
}
