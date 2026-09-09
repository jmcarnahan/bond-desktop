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
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
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
        // This thread scores under the Needs You cut, so People is the stop
        // that carries it — and its room row and the overview both name Eric.
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

  Future<void> openThread(WidgetTester tester) async {
    // In the overview beside the column, not the room row in it: tapping the
    // rail's People row opens the ROOM, and this test wants the thread.
    await tester.tap(find.descendant(
      of: find.byType(ConversationListPane),
      matching: find.text('Eric Vance'),
    ));
    // The tap, the transcript read, then the capability the cards wait on.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
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

  testWidgets('an older card puts ITS OWN words in the box, not the newest',
      (tester) async {
    // Rewritten: a card stages rather than sends, so what this pins is which
    // of the two options the box ends up holding.
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.text('Confirm receipt'));
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Composer>(find.byType(Composer)).suggestedBody,
      'Got it, thanks.',
    );
    // And the box knows which message those words answer: a send resolves to
    // the newest inbound on its own, so an older card has to say otherwise.
    expect(find.byKey(const Key('replying-to')), findsOneWidget);
    expect(find.text('Replying to Eric Vance'), findsOneWidget);
    // Nothing went out, and neither suggestion was spent.
    expect(mail.calls, isEmpty);
    expect(
      (await store.getDraftForMessage('email', 'c1-m1'))!['status'],
      'suggested',
    );
    expect(
      (await store.getDraftForMessage('email', 'c1-m2'))!['status'],
      'suggested',
    );
  });

  testWidgets('tapping a card sends nothing and closes no other card',
      (tester) async {
    // Rewritten: this used to assert that a queued send closed every card
    // while it was undoable. A tap queues no send now, so nothing has been
    // answered and every card stays where it was.
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.text('Confirm receipt'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Confirm receipt'), findsOneWidget);
    expect(find.text('Say yes'), findsOneWidget);
    expect(find.text('Sending…'), findsNothing);
    expect(find.text('Reply sending.'), findsNothing);
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

  testWidgets('the composer is docked under the transcript', (tester) async {
    // No doorway to walk through: a thread that can be answered opens with the
    // box already under it, addressed to whoever is being answered.
    await seedThread();
    await pumpScreen(tester);

    await openThread(tester);

    expect(find.byType(Composer), findsOneWidget);
    expect(find.text('Reply…'), findsNothing);
    expect(
      tester.widget<Composer>(find.byType(Composer)).hint,
      'Reply to Eric Vance…',
    );
  });

  testWidgets('without a send grant a card does the same thing', (tester) async {
    // Rewritten: this was the honest half of a split. There is no split left —
    // a tap stages in either grant state — so what it pins now is that the
    // read-only build behaves exactly like the sending one.
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

  /// The text the reply box is actually holding, controller and all — the
  /// `suggestedBody` a `Composer` was handed says what the host offered, not
  /// what is on screen.
  String boxText(WidgetTester tester) => tester
      .widget<TextField>(find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      ))
      .controller!
      .text;

  testWidgets('the box opens EMPTY even when a suggestion is waiting',
      (tester) async {
    // The whole point of staging: a suggestion the pipeline wrote stays on its
    // card until the reader asks for it, so the box is one empty line and the
    // reply is not on screen twice.
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    expect(
      tester.widget<Composer>(find.byType(Composer)).suggestedBody,
      isNull,
    );
    expect(boxText(tester), '');
    expect(find.byKey(InboxScreen.useSuggestionKey), findsOneWidget);
    // And the suggestion is still where it was.
    expect(find.text('Confirm receipt'), findsOneWidget);
  });

  testWidgets('Use it puts the stored draft in the box', (tester) async {
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.descendant(
      of: find.byKey(InboxScreen.useSuggestionKey),
      matching: find.text('Use it'),
    ));
    await tester.pump();
    await tester.pump();

    expect(boxText(tester), 'Yes, Friday works for me.');
    // The hint is the offer, and the offer has been taken.
    expect(find.byKey(InboxScreen.useSuggestionKey), findsNothing);
    // The provenance caption is what says these words are the model's.
    expect(
      find.text('✨ Suggested reply — drafted from this thread and your past '
          'mail'),
      findsOneWidget,
    );
  });

  testWidgets('the box\'s ✕ empties the box and keeps the suggestion',
      (tester) async {
    // The ✕ used to mark the stored draft dismissed, so closing a box the
    // reader never asked for deleted the suggestion. It un-stages now.
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.descendant(
      of: find.byKey(InboxScreen.useSuggestionKey),
      matching: find.text('Use it'),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Clear the box'));
    await tester.pump();
    await tester.pump();

    expect(boxText(tester), '');
    expect(find.byKey(InboxScreen.useSuggestionKey), findsOneWidget);
    // The row the words came from is untouched, and so is the card.
    expect(
      (await store.getDraftForMessage('email', 'c1-m2'))!['status'],
      'suggested',
    );
    expect(find.text('Say yes'), findsOneWidget);
  });

  testWidgets('a card tap stages that option and queues no send',
      (tester) async {
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.text('Push back'));
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Composer>(find.byType(Composer)).suggestedBody,
      'Friday is tight — could we say Tuesday?',
    );
    expect(boxText(tester), 'Friday is tight — could we say Tuesday?');
    expect(find.text('Reply sending.'), findsNothing);
    expect(find.text('Sending…'), findsNothing);
    expect(mail.calls, isEmpty);
    // The newest message's card names nothing: the send already resolves to
    // that message, and a caption saying so would be saying nothing.
    expect(find.byKey(const Key('replying-to')), findsNothing);
  });

  testWidgets('a send leaves the next box empty rather than re-staging',
      (tester) async {
    // The staging map outliving its send would hand the NEXT suggestion to a
    // box nobody had asked to fill.
    await seedThread();
    await pumpScreen(tester);
    await openThread(tester);

    await tester.tap(find.text('Confirm receipt'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send'));
    for (var i = 0; i < 12; i++) {
      await tester.pump();
    }

    expect(mail.bodies, ['Got it, thanks.']);
    expect(
      tester.widget<Composer>(find.byType(Composer)).suggestedBody,
      isNull,
    );
    expect(boxText(tester), '');
  });
}
