// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart'
    show Conversation, ConversationState;
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/providers/compose_provider.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/graph_mail.dart' show GraphMailException;
import 'package:bond_inbox/services/graph_teams.dart' show GraphTeamsException;
import 'package:bond_inbox/widgets/composer.dart' show SendCapability;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Composing a message to somebody this app has no thread with.
///
/// The thing worth pinning here that no other test can: compose CREATES the
/// conversation row. A reply folds into a row the sync wrote; this writes one
/// from nothing — participants, state, stamps and all — and if it wrote it
/// after the echo, or left a field out, the message would land in a thread the
/// rail cannot order or the transcript cannot read.

const String _myId = 'me-1';

class _FakeMail implements MailBackend {
  final List<
      ({
        List<String> to,
        List<String> cc,
        String subject,
        String body,
      })> drafts = [];
  final List<String> sends = [];

  /// What `createDraft` answers. A copy is handed back per call so a test can
  /// null a key out without the next call seeing it.
  Map<String, dynamic> draftResult = const {
    'id': 'draft-1',
    'webLink': 'https://outlook.example/draft-1',
    'conversationId': 'conv-1',
    'internetMessageId': '<imid-1>',
  };

  Object? draftError;
  Object? sendError;

  SentDraft sentResult = const SentDraft(
    draftId: 'draft-1',
    conversationId: 'conv-1',
    internetMessageId: '<imid-1>',
    subject: 'Kickoff',
    to: [Recipient(name: 'Sarah Whitfield', address: 'sarah@corp.example')],
    sentAt: '2026-09-06T10:00:00Z',
  );

  @override
  Future<Map<String, dynamic>> createDraft({
    required List<String> to,
    List<String> cc = const [],
    required String subject,
    required String body,
  }) async {
    drafts.add((to: to, cc: cc, subject: subject, body: body));
    final thrown = draftError;
    if (thrown != null) throw thrown;
    return Map<String, dynamic>.from(draftResult);
  }

  @override
  Future<SentDraft> sendDraft(String draftId) async {
    sends.add(draftId);
    final thrown = sendError;
    if (thrown != null) throw thrown;
    return sentResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeTeams implements TeamsBackend {
  final List<({List<String> ids, String? topic})> ensured = [];
  final List<({String chatId, String text})> sends = [];

  EnsuredChat result = const EnsuredChat(chatId: 'chat-new', isGroup: false);
  Object? ensureError;
  Object? sendError;
  Object? membersError;

  List<Map<String, dynamic>> members = const [
    {'userId': _myId, 'displayName': 'Jordan Bond'},
    {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
  ];

  int nextId = 1;

  @override
  Future<String> myUserId() async => _myId;

  @override
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) async {
    final thrown = membersError;
    if (thrown != null) throw thrown;
    return members;
  }

  @override
  Future<EnsuredChat> ensureChat(List<String> userIds, {String? topic}) async {
    ensured.add((ids: userIds, topic: topic));
    final thrown = ensureError;
    if (thrown != null) throw thrown;
    return result;
  }

  @override
  Future<Map<String, dynamic>> sendChatMessage(
    String chatId,
    String text,
  ) async {
    sends.add((chatId: chatId, text: text));
    final thrown = sendError;
    if (thrown != null) throw thrown;
    return {
      'id': 'sent-${nextId++}',
      'messageType': 'message',
      'createdDateTime': '2026-09-06T11:00:00Z',
      'lastModifiedDateTime': '2026-09-06T11:00:00Z',
      'body': {'contentType': 'text', 'content': text},
      'from': {
        'user': {'id': _myId, 'displayName': 'Jordan Bond'},
      },
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
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
  // The copy-only rung reaches the clipboard, which is a platform channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  late BondDatabase db;
  late MessageStore store;
  late _FakeMail mail;
  late _FakeTeams teams;
  late List<Uri> launched;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    mail = _FakeMail();
    teams = _FakeTeams();
    launched = [];
  });

  tearDown(() => db.close());

  ComposeNotifier build({Set<String>? scopes}) => ComposeNotifier(
        store,
        _FakeAuth(scopes: scopes ?? const {'mail.send', 'chat.readwrite'}),
        mail,
        teams,
        launch: (uri) async {
          launched.add(uri);
          return true;
        },
      );

  /// The capability read is a round trip the constructor starts and does not
  /// await; every test that sends has to let it land first.
  Future<ComposeNotifier> ready({Set<String>? scopes}) async {
    final notifier = build(scopes: scopes);
    await notifier.load();
    return notifier;
  }

  Future<List<Map<String, Object?>>> messageRows(String source) async {
    final rows = await db
        .customSelect(
          "SELECT * FROM messages WHERE source = '$source' "
          'ORDER BY source_message_id',
        )
        .get();
    return [for (final row in rows) row.data];
  }

  group('mail', () {
    test('a sent message writes its own conversation and echo row', () async {
      final notifier = await ready();
      await notifier.setTo([_sarah]);
      notifier.setCc([_marcus]);
      notifier.setSubject('Kickoff');
      notifier.setBody('Morning — can we start Tuesday?\nSecond line.');

      final outcome = await notifier.send();

      expect(mail.drafts.single.to, ['sarah@corp.example']);
      expect(mail.drafts.single.cc, ['marcus@corp.example']);
      expect(mail.drafts.single.subject, 'Kickoff');
      expect(mail.drafts.single.body, contains('start Tuesday'));
      expect(mail.sends, ['draft-1']);

      expect(outcome, isA<ComposeSent>());
      final sent = outcome as ComposeSent;
      expect(sent.source, 'email');
      expect(sent.conversationKey, 'conv-1');

      final conversations = await store.loadConversations();
      expect(conversations, hasLength(1));
      final thread = conversations.single;
      expect(thread.id, 'conv-1');
      expect(thread.state, ConversationState.waiting);
      expect(thread.subject, 'Kickoff');
      expect(thread.lastMessageAt, '2026-09-06T10:00:00Z');
      expect(thread.lastOutboundAt, '2026-09-06T10:00:00Z');
      expect(thread.lastMessagePreview, 'Morning — can we start Tuesday?');
      expect(
        thread.participants.map((p) => p.email),
        ['sarah@corp.example', 'marcus@corp.example'],
      );

      final rows = await messageRows('email');
      expect(rows, hasLength(1));
      expect(rows.single['source_message_id'], 'local:draft-1');
      expect(rows.single['direction'], 'outbound');
      expect(rows.single['internet_message_id'], '<imid-1>');
      expect(rows.single['body_text'], contains('start Tuesday'));
    });

    test('no conversation id anywhere falls back to the message key',
        () async {
      mail.draftResult = const {
        'id': 'draft-9',
        'webLink': 'https://outlook.example/draft-9',
      };
      mail.sentResult = const SentDraft(draftId: 'draft-9');

      final notifier = await ready();
      await notifier.setTo([_sarah]);
      notifier.setBody('No thread id here.');

      final outcome = await notifier.send() as ComposeSent;

      expect(outcome.conversationKey, 'msg:draft-9');
      expect((await store.loadConversations()).single.id, 'msg:draft-9');
    });

    test('a Sent Items copy that landed first is not doubled', () async {
      // A poll in flight during the send can ingest the real copy before the
      // echo is written. The conversation write is what compose owes either
      // way; the echo is the write that has to notice and stand down.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'AAMk-real',
        'internet_message_id': '<imid-1>',
        'conversation_key': 'conv-1',
        'direction': 'outbound',
        'subject': 'Kickoff',
        'received_at': '2026-09-06T10:00:00Z',
        'body_text': 'Already here.',
      });

      final notifier = await ready();
      await notifier.setTo([_sarah]);
      notifier.setBody('Already here.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeSent>());
      final rows = await messageRows('email');
      expect(rows, hasLength(1));
      expect(rows.single['source_message_id'], 'AAMk-real');
      final thread = (await store.loadConversations()).single;
      expect(thread.id, 'conv-1');
      expect(thread.messageCount, 1);
    });

    test('Mail.ReadWrite alone hands the draft to Outlook and writes nothing',
        () async {
      final notifier = await ready(scopes: const {'mail.readwrite'});
      expect(notifier.state.capability, SendCapability.draftToOutlook);
      await notifier.setTo([_sarah]);
      notifier.setBody('Finish me in Outlook.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeSavedToOutlook>());
      expect(mail.drafts, hasLength(1));
      expect(mail.sends, isEmpty);
      expect(launched.single.toString(), 'https://outlook.example/draft-1');
      expect(await store.loadConversations(), isEmpty);
      expect(await messageRows('email'), isEmpty);
    });

    test('no grant at all copies the message and touches no backend',
        () async {
      final clipboard = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final notifier = await ready(scopes: const {});
      expect(notifier.state.capability, SendCapability.copyOnly);
      await notifier.setTo([_sarah]);
      notifier.setCc([_marcus]);
      notifier.setSubject('Kickoff');
      notifier.setBody('Pasted somewhere else.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeCopied>());
      expect(mail.drafts, isEmpty);
      expect(clipboard.single, '''
To: sarah@corp.example
Cc: marcus@corp.example
Subject: Kickoff

Pasted somewhere else.''');
    });

    test('a send that fails after the draft exists names where the words are',
        () async {
      mail.sendError = const GraphMailException('Graph said no.');

      final notifier = await ready();
      await notifier.setTo([_sarah]);
      notifier.setBody('This one does not go.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeFailed>());
      expect(
        notifier.state.error,
        'Not sent. The draft is in your Outlook Drafts.',
      );
      expect(notifier.state.errorLink, 'https://outlook.example/draft-1');
      expect(notifier.state.sending, isFalse);
      expect(await store.loadConversations(), isEmpty);
      expect(await messageRows('email'), isEmpty);
    });

    test('a draft that could not be created surfaces Graph\'s own sentence',
        () async {
      mail.draftError = const GraphMailException('Mailbox is over quota.');

      final notifier = await ready();
      await notifier.setTo([_sarah]);
      notifier.setBody('Never drafted.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeFailed>());
      expect(notifier.state.error, 'Mailbox is over quota.');
      expect(notifier.state.errorLink, isNull);
      expect(mail.sends, isEmpty);
      expect(await store.loadConversations(), isEmpty);
    });

    test('nobody in To is said rather than sent', () async {
      final notifier = await ready();
      notifier.setBody('Addressed to nobody.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeFailed>());
      expect(notifier.state.error, 'Add somebody to send to.');
      expect(mail.drafts, isEmpty);
    });

    test('a recipient with no address is a sentence, not a silent drop',
        () async {
      final notifier = await ready();
      await notifier.setTo([
        const Person(id: 'u3', displayName: 'Teams Only'),
      ]);
      notifier.setBody('Nowhere to send this.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeFailed>());
      expect(notifier.state.error, 'Nobody in To has an email address.');
      expect(mail.drafts, isEmpty);
    });

    test('the send is logged without any address in it', () async {
      final notifier = ComposeNotifier(
        store,
        _FakeAuth(),
        mail,
        teams,
        log: ActivityLog(store),
        launch: (uri) async => true,
      );
      await notifier.load();
      await notifier.setTo([_sarah]);
      notifier.setCc([_marcus]);
      notifier.setBody('Logged.');

      await notifier.send();

      final events = await store.recentActivity(limit: 5);
      final compose = events.firstWhere((e) => e['kind'] == 'compose');
      expect(compose['source'], 'email');
      expect(compose['count'], 2);
      expect(compose['detail_json'], contains('"channel":"email"'));
      expect(compose['detail_json'], isNot(contains('@corp.example')));
    });
  });

  group('teams', () {
    test('one person opens a chat and posts into it', () async {
      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah]);
      notifier.setBody('Are you free at four?');

      final outcome = await notifier.send();

      expect(teams.ensured.single.ids, ['u1']);
      expect(teams.ensured.single.topic, isNull);
      expect(teams.sends.single.chatId, 'chat-new');

      expect(outcome, isA<ComposeSent>());
      expect((outcome as ComposeSent).conversationKey, 'chat-new');

      final chats = await store.loadConversations(sources: const ['teams']);
      expect(chats, hasLength(1));
      expect(chats.single.subject, 'Sarah Whitfield');
      expect(chats.single.state, ConversationState.waiting);
      expect(
        chats.single.participants.map((p) => p.email),
        ['teams:u1'],
        reason: 'the owner is never one of a chat row\'s participants',
      );

      final rows = await messageRows('teams');
      expect(rows, hasLength(1));
      expect(rows.single['source_message_id'], 'sent-1');
      expect(rows.single['direction'], 'outbound');
    });

    test('two people and a topic open a named group', () async {
      teams.result = const EnsuredChat(chatId: 'chat-group', isGroup: true);
      teams.members = const [
        {'userId': _myId, 'displayName': 'Jordan Bond'},
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
        {'userId': 'u2', 'displayName': 'Marcus Reed'},
      ];

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, _marcus]);
      notifier.setTopic('Launch week');
      notifier.setBody('Kicking this off.');

      await notifier.send();

      expect(teams.ensured.single.ids, ['u1', 'u2']);
      expect(teams.ensured.single.topic, 'Launch week');
      final chat =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(chat.id, 'chat-group');
      expect(chat.subject, 'Launch week');
      expect(
        chat.participants.map((p) => p.email),
        ['teams:u1', 'teams:u2'],
      );
    });

    test('a roster Graph would not hand back falls back to the picked people',
        () async {
      teams.result = const EnsuredChat(chatId: 'chat-group', isGroup: true);
      teams.membersError = const GraphTeamsException('Chat members refused.');

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, _marcus]);
      notifier.setBody('Still stored.');

      await notifier.send();

      final chat =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(
        chat.participants.map((p) => p.email),
        ['teams:u1', 'teams:u2'],
      );
      expect(chat.subject, 'Sarah Whitfield, Marcus Reed');
    });

    test('a retry after a failed group send reuses the chat it opened',
        () async {
      teams.result = const EnsuredChat(chatId: 'chat-group', isGroup: true);
      teams.sendError = const GraphTeamsException('Posting failed.');

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, _marcus]);
      notifier.setBody('Try me twice.');

      final first = await notifier.send();

      expect(first, isA<ComposeFailed>());
      expect(
        notifier.state.error,
        'The chat was opened but the message did not send.',
      );
      expect(notifier.state.groupChatId, 'chat-group');
      expect(await store.loadConversations(sources: const ['teams']), isEmpty);

      teams.sendError = null;
      final second = await notifier.send();

      expect(second, isA<ComposeSent>());
      expect(
        teams.ensured,
        hasLength(1),
        reason: 'a second ensureChat would leave an empty group behind',
      );
      expect(teams.sends.map((s) => s.chatId), ['chat-group', 'chat-group']);
      expect(notifier.state.groupChatId, isNull);
    });

    test('changing the picked people lets go of the held group', () async {
      teams.result = const EnsuredChat(chatId: 'chat-group', isGroup: true);
      teams.sendError = const GraphTeamsException('Posting failed.');

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, _marcus]);
      notifier.setBody('Try me twice.');
      await notifier.send();
      expect(notifier.state.groupChatId, 'chat-group');

      await notifier.setTo([_sarah]);

      expect(notifier.state.groupChatId, isNull);
    });

    test('a picked thread posts into it and never opens another', () async {
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-1-m1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Sarah Whitfield',
        'received_at': '2026-09-05T09:00:00Z',
        'body_text': 'Can you look at this?',
      });
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-1',
        'subject': 'Sarah Whitfield',
        'participants_json': '[{"name":"Sarah Whitfield","email":"teams:u1"}]',
        'state': 'needs_reply',
        'cta_text': 'Sarah is waiting on you.',
        'last_message_at': '2026-09-05T09:00:00Z',
        'last_message_preview': 'Can you look at this?',
      });

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      final chat =
          (await store.loadConversations(sources: const ['teams'])).single;
      notifier.pickExistingChat(chat);
      notifier.setBody('Looking now.');

      final outcome = await notifier.send();

      expect(teams.ensured, isEmpty);
      expect(teams.sends.single.chatId, 'chat-1');
      expect((outcome as ComposeSent).conversationKey, 'chat-1');

      final folded =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(folded.state, ConversationState.waiting);
      expect(folded.ctaText, isNull);
      expect(folded.lastMessageAt, '2026-09-06T11:00:00Z');
      expect(folded.lastMessagePreview, 'Looking now.');
      expect(await messageRows('teams'), hasLength(2));
    });

    test('a person picked by name whose chat is already stored folds into it',
        () async {
      // The 1:1 with Sarah is already in the rail, asking for a reply. Picking
      // HER rather than the thread still reaches it — `ensureChat` is
      // idempotent for a 1:1 — and must land as a reply would, not as a new
      // chat that resets everything the sync knew about this one.
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-1-m1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Sarah Whitfield',
        'received_at': '2026-09-05T09:00:00Z',
        'body_text': 'Can you look at this?',
      });
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-1',
        'subject': 'Sarah Whitfield',
        'participants_json': '[{"name":"Sarah Whitfield","email":"teams:u1"}]',
        'state': 'needs_reply',
        'category': 'ops',
        'cta_text': 'Sarah is waiting on you.',
        'last_inbound_at': '2026-09-05T09:00:00Z',
        'last_message_at': '2026-09-05T09:00:00Z',
        'last_message_preview': 'Can you look at this?',
      });
      teams.result = const EnsuredChat(chatId: 'chat-1', isGroup: false);
      // A roster read that would have replaced the stored one, had the fresh
      // path run.
      teams.members = const [
        {'userId': _myId, 'displayName': 'Jordan Bond'},
        {'userId': 'u1', 'displayName': 'S. Whitfield'},
      ];

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah]);
      notifier.setBody('Looking now.');

      final outcome = await notifier.send();

      expect(teams.ensured.single.ids, ['u1']);
      expect((outcome as ComposeSent).conversationKey, 'chat-1');

      final folded =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(folded.state, ConversationState.waiting);
      expect(folded.ctaText, isNull);
      expect(folded.category, 'ops', reason: 'the sync\'s work survives');
      expect(
        folded.participants.map((p) => p.name),
        ['Sarah Whitfield'],
        reason: 'a fold keeps the stored roster',
      );
      expect(folded.lastInboundAt, '2026-09-05T09:00:00Z');
      expect(folded.lastMessageAt, '2026-09-06T11:00:00Z');
      expect(folded.lastMessagePreview, 'Looking now.');
      expect(await messageRows('teams'), hasLength(2));
    });

    test('a roster Graph answers short keeps the topic and the picked people',
        () async {
      teams.result = const EnsuredChat(chatId: 'chat-group', isGroup: true);
      // Only the owner — a member list that lagged the creation.
      teams.members = const [
        {'userId': _myId, 'displayName': 'Jordan Bond'},
      ];

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, _marcus]);
      notifier.setTopic('Launch week');
      notifier.setBody('Kicking this off.');

      await notifier.send();

      final chat =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(chat.subject, 'Launch week');
      expect(
        chat.participants.map((p) => p.email),
        ['teams:u1', 'teams:u2'],
      );
    });

    test('a chat Graph refuses to open says why', () async {
      teams.ensureError =
          const GraphTeamsException('Some of those people cannot be chatted.');

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, _marcus]);
      notifier.setBody('Never posted.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeFailed>());
      expect(
        notifier.state.error,
        'Some of those people cannot be chatted.',
      );
      expect(teams.sends, isEmpty);
      expect(await store.loadConversations(sources: const ['teams']), isEmpty);
    });

    test('somebody with no Graph id is named rather than dropped', () async {
      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, Person.typed('nobody@corp.example')]);
      notifier.setBody('Cannot go.');

      final outcome = await notifier.send();

      expect(outcome, isA<ComposeFailed>());
      expect(
        notifier.state.error,
        'nobody@corp.example cannot be reached on Teams.',
      );
      expect(teams.ensured, isEmpty);
    });

    test('without Chat.ReadWrite there is nothing to send with', () async {
      final notifier = await ready(scopes: const {'mail.send'});
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();

      expect(notifier.state.capability, SendCapability.copyOnly);

      await notifier.setTo([_sarah]);
      notifier.setBody('Blocked.');
      final outcome = await notifier.send();

      expect(outcome, isA<ComposeFailed>());
      expect(
        notifier.state.error,
        'Teams sending is not enabled for this account.',
      );
      expect(teams.ensured, isEmpty);
      expect(teams.sends, isEmpty);
    });

    test('an existing group with exactly these people is offered', () async {
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-match',
        'subject': 'Launch week',
        'participants_json':
            '[{"name":"Sarah Whitfield","email":"teams:u1"},'
                '{"name":"Marcus Reed","email":"teams:u2"}]',
        'state': 'waiting',
        'last_message_at': '2026-09-05T09:00:00Z',
      });
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-other',
        'subject': 'Somebody else',
        'participants_json':
            '[{"name":"Priya Raman","email":"teams:u9"}]',
        'state': 'waiting',
        'last_message_at': '2026-09-04T09:00:00Z',
      });

      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();

      await notifier.setTo([_sarah, _marcus]);
      expect(
        notifier.state.candidateChats.map((c) => c.id),
        ['chat-match'],
      );

      await notifier.setTo([_sarah]);
      expect(
        notifier.state.candidateChats,
        isEmpty,
        reason: 'a 1:1 is idempotent, so there is no duplicate to warn about',
      );
    });
  });

  group('the screen\'s own state', () {
    test('the capability ladder reads the grant', () async {
      expect(
        (await ready(scopes: const {'mail.send'})).state.capability,
        SendCapability.send,
      );
      expect(
        (await ready(scopes: const {'mail.readwrite'})).state.capability,
        SendCapability.draftToOutlook,
      );
      expect((await ready(scopes: const {})).state.capability,
          SendCapability.copyOnly);

      final chat = await ready(scopes: const {'chat.readwrite'});
      chat.setChannel(RecipientChannel.teams);
      await chat.load();
      expect(chat.state.capability, SendCapability.send);
    });

    test('switching channel drops the recipients and keeps the words',
        () async {
      final notifier = await ready();
      await notifier.setTo([_sarah]);
      notifier.setCc([_marcus]);
      notifier.setSubject('Kickoff');
      notifier.setBody('Same words either way.');

      notifier.setChannel(RecipientChannel.teams);

      expect(notifier.state.to, isEmpty);
      expect(notifier.state.cc, isEmpty);
      expect(notifier.state.subject, 'Kickoff');
      expect(notifier.state.body, 'Same words either way.');
    });

    test('picking a thread clears the chips, and Change gives them back',
        () async {
      final notifier = await ready();
      notifier.setChannel(RecipientChannel.teams);
      await notifier.load();
      await notifier.setTo([_sarah, _marcus]);

      notifier.pickExistingChat(const Conversation(
        id: 'chat-1',
        source: 'teams',
        subject: 'Launch week',
      ));

      expect(notifier.state.to, isEmpty);
      expect(notifier.state.existingChat?.id, 'chat-1');
      expect(notifier.state.canSend, isFalse, reason: 'no body yet');

      notifier.setBody('Into the thread.');
      expect(notifier.state.canSend, isTrue);

      notifier.useNewGroup();
      expect(notifier.state.existingChat, isNull);
    });

    test('a prefilled chat opens straight into it', () async {
      final notifier = build();
      await notifier.prefill(
        channel: RecipientChannel.teams,
        chat: const Conversation(
          id: 'chat-1',
          source: 'teams',
          subject: 'Launch week',
        ),
      );

      expect(notifier.state.channel, RecipientChannel.teams);
      expect(notifier.state.existingChat?.id, 'chat-1');
      expect(notifier.state.to, isEmpty);
    });

    test('a prefill starts from a clean subject', () async {
      // The screen empties the Subject box when an ask lands; a subject kept
      // here behind it would go out on a message it was never shown on.
      final notifier = await ready();
      notifier.setSubject('Kickoff');
      notifier.setTopic('Launch week');

      await notifier.prefill(channel: RecipientChannel.mail, to: [_sarah]);

      expect(notifier.state.subject, '');
      expect(notifier.state.topic, '');
      expect(notifier.state.to, [_sarah]);
    });

    test('a prefilled person lands in To', () async {
      final notifier = build();
      await notifier.prefill(channel: RecipientChannel.mail, to: [_sarah]);

      expect(notifier.state.channel, RecipientChannel.mail);
      expect(notifier.state.to, [_sarah]);
    });
  });
}
