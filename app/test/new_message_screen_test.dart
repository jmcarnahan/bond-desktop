// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/new_message_screen.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/graph_mail.dart' show GraphMailException;
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/pane_surface.dart';
import 'package:bond_inbox/widgets/recipients_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The New message screen.
///
/// What only a widget test can hold: the channel is a MODE, not a filter. Half
/// the controls on this screen belong to mail alone and the other half to
/// Teams, and a switch that left a Subject box on a chat — or a Send button on
/// an account with no Chat.ReadWrite — would be offering something that cannot
/// happen.

const String _myId = 'me-1';

class _FakeMail implements MailBackend {
  final List<String> sends = [];
  int draftCalls = 0;
  Object? sendError;

  @override
  Future<Map<String, dynamic>> createDraft({
    required List<String> to,
    List<String> cc = const [],
    required String subject,
    required String body,
  }) async {
    draftCalls += 1;
    return const {
      'id': 'draft-1',
      'webLink': 'https://outlook.example/draft-1',
      'conversationId': 'conv-1',
      'internetMessageId': '<imid-1>',
    };
  }

  @override
  Future<SentDraft> sendDraft(String draftId) async {
    sends.add(draftId);
    final thrown = sendError;
    if (thrown != null) throw thrown;
    return const SentDraft(
      draftId: 'draft-1',
      conversationId: 'conv-1',
      internetMessageId: '<imid-1>',
      subject: 'Kickoff',
      sentAt: '2026-09-06T10:00:00Z',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeTeams implements TeamsBackend {
  @override
  Future<String> myUserId() async => _myId;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakePeople implements PeopleBackend {
  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async =>
      const [];

  @override
  Future<ProfilePhoto?> profilePhoto(String user, {String size = '96x96'}) async =>
      null;
}

class _FakeAuth implements AuthSession {
  final Set<String> scopes;

  _FakeAuth({this.scopes = const {'mail.send', 'chat.readwrite'}});

  @override
  Future<bool> hasScope(String bareScope) async => scopes.contains(bareScope);

  @override
  Future<AccountInfo?> get storedAccount async => const AccountInfo(
        displayName: 'Jordan Bond',
        mail: 'jordan@corp.example',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

const Person _sarah = Person(
  id: 'u1',
  displayName: 'Sarah Whitfield',
  mail: 'sarah@corp.example',
);

const Person _marcus = Person(
  id: 'u2',
  displayName: 'Marcus Reed',
  mail: 'marcus@corp.example',
);

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _FakeMail mail;
  late ProviderContainer container;
  late int backs;
  late int homes;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    mail = _FakeMail();
    backs = 0;
    homes = 0;
  });

  tearDown(() => db.close());

  Future<void> pumpScreen(
    WidgetTester tester, {
    Set<String> scopes = const {'mail.send', 'chat.readwrite'},
    OpenComposeIntent? prefill,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        mailBackendProvider.overrideWithValue(mail),
        teamsBackendProvider.overrideWithValue(_FakeTeams()),
        peopleBackendProvider.overrideWithValue(_FakePeople()),
        authSessionProvider.overrideWithValue(_FakeAuth(scopes: scopes)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: NewMessageScreen(
            onBack: () => backs += 1,
            onHome: () => homes += 1,
            prefill: prefill,
          ),
        ),
      ),
    ));
    // Bare pumps: the capability read and any prefill are round trips, and a
    // settle would wait on the recipients field's debounce forever.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(NewMessageScreen)),
    );
  }

  /// Types into the To field and picks the offered person.
  Future<void> pick(WidgetTester tester, String query, String optionId) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(RecipientsField),
        matching: find.byType(TextField),
      ),
      query,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(Key('recipient-option-$optionId')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> writeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Lets the recipients field's debounce fire before the test ends, so no
  /// timer outlives the frame it was armed in.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('it is a pane with a way back and a way home', (tester) async {
    await pumpScreen(tester);

    expect(find.byType(PaneSurface), findsOneWidget);
    expect(find.text('New message'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(backs, 1);

    await tester.tap(find.byTooltip('Inbox'));
    await tester.pump();
    expect(homes, 1);

    await drain(tester);
  });

  testWidgets('the channel decides which fields exist', (tester) async {
    await pumpScreen(tester);

    expect(find.byKey(const Key('compose-subject')), findsOneWidget);
    expect(find.byKey(const Key('compose-cc-toggle')), findsOneWidget);

    await tester.tap(find.text('Teams'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('compose-subject')), findsNothing);
    expect(find.byKey(const Key('compose-cc-toggle')), findsNothing);
    expect(find.text('To (people or an existing chat)'), findsOneWidget);

    await tester.tap(find.text('Email'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('compose-subject')), findsOneWidget);
    expect(find.byKey(const Key('compose-cc-toggle')), findsOneWidget);

    await drain(tester);
  });

  testWidgets('Cc is asked for rather than always there', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const Key('compose-cc')), findsNothing);

    await tester.tap(find.byKey(const Key('compose-cc-toggle')));
    await tester.pump();

    expect(find.byKey(const Key('compose-cc')), findsOneWidget);
    expect(find.byKey(const Key('compose-cc-toggle')), findsNothing);

    await drain(tester);
  });

  testWidgets('a message addressed to nobody is said, not sent',
      (tester) async {
    await pumpScreen(tester);

    await writeAndSend(tester, 'Where is this going?');

    expect(find.text('Add somebody to send to.'), findsOneWidget);
    expect(mail.draftCalls, 0);

    await drain(tester);
  });

  testWidgets('a sent message opens its own thread', (tester) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'seed-1',
      'conversation_key': 'seed',
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      'from_address': 'sarah@corp.example',
      'received_at': '2026-09-05T09:00:00Z',
      'body_text': 'Earlier mail, so she is a recent.',
    });

    await pumpScreen(tester);
    await pick(tester, 'sar', 'mail:sarah@corp.example');
    await writeAndSend(tester, 'Morning — Tuesday works.');

    expect(mail.draftCalls, 1);
    expect(mail.sends, ['draft-1']);

    final intent = container.read(navIntentProvider);
    expect(intent, isA<OpenThreadIntent>());
    expect((intent as OpenThreadIntent).source, 'email');
    expect(intent.conversationKey, 'conv-1');
    expect(find.text('Message sent.'), findsOneWidget);

    await drain(tester);
  });

  testWidgets('a send that failed offers the draft in Outlook', (tester) async {
    mail.sendError = const GraphMailException('Graph said no.');
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'seed-1',
      'conversation_key': 'seed',
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      'from_address': 'sarah@corp.example',
      'received_at': '2026-09-05T09:00:00Z',
      'body_text': 'Earlier mail, so she is a recent.',
    });

    await pumpScreen(tester);
    await pick(tester, 'sar', 'mail:sarah@corp.example');
    await writeAndSend(tester, 'This one does not go.');

    expect(
      find.text('Not sent. The draft is in your Outlook Drafts.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('compose-error-link')), findsOneWidget);
    expect(container.read(navIntentProvider), isNull);

    await drain(tester);
  });

  testWidgets('two people on Teams offer the group they already have',
      (tester) async {
    await store.upsertConversation({
      'source': 'teams',
      'conversation_key': 'chat-match',
      'subject': 'Launch week',
      'participants_json': '[{"name":"Sarah Whitfield","email":"teams:u1"},'
          '{"name":"Marcus Reed","email":"teams:u2"}]',
      'state': 'waiting',
      'last_message_at': '2026-09-05T09:00:00Z',
    });

    await pumpScreen(
      tester,
      prefill: OpenComposeIntent(
        channel: RecipientChannel.teams,
        to: const [_sarah, _marcus],
      ),
    );

    expect(find.text('You already have a chat with these people.'),
        findsOneWidget);
    expect(find.text('Otherwise this starts a new group chat.'), findsOneWidget);
    expect(find.byKey(const Key('compose-topic')), findsOneWidget);

    await tester.tap(find.byKey(const Key('compose-candidate-chat-match')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Sending in Launch week'), findsOneWidget);
    expect(find.byType(RecipientsField), findsNothing);

    await tester.tap(find.byKey(const Key('compose-change-chat')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(RecipientsField), findsOneWidget);

    await drain(tester);
  });

  testWidgets('two people with no such group say so', (tester) async {
    await pumpScreen(
      tester,
      prefill: OpenComposeIntent(
        channel: RecipientChannel.teams,
        to: const [_sarah, _marcus],
      ),
    );

    expect(find.text('This starts a new group chat.'), findsOneWidget);
    expect(find.byKey(const Key('compose-topic')), findsOneWidget);

    await drain(tester);
  });

  testWidgets('a prefilled chat opens straight into it', (tester) async {
    await store.upsertConversation({
      'source': 'teams',
      'conversation_key': 'chat-1',
      'subject': 'Launch week',
      'participants_json': '[{"name":"Sarah Whitfield","email":"teams:u1"}]',
      'state': 'waiting',
      'last_message_at': '2026-09-05T09:00:00Z',
    });
    final chat = (await store.loadConversations(sources: const ['teams']))
        .single;

    await pumpScreen(
      tester,
      prefill: OpenComposeIntent(
        channel: RecipientChannel.teams,
        chat: chat,
      ),
    );

    expect(find.text('Sending in Launch week'), findsOneWidget);
    expect(find.byType(RecipientsField), findsNothing);

    await drain(tester);
  });

  testWidgets('an account without Chat.ReadWrite is told, not offered a button',
      (tester) async {
    await pumpScreen(tester, scopes: const {'mail.send'});

    await tester.tap(find.text('Teams'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Teams sending is not enabled for this account.'),
      findsOneWidget,
    );
    expect(find.byType(Composer), findsNothing);
    expect(find.text('Send'), findsNothing);

    await drain(tester);
  });
}
