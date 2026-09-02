import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// End-to-end chat syncs: a scripted Graph on one side, a real sqlite database
/// on the other, and the real [GraphAuth], [GraphTeams] and [TeamsSync] in
/// between. Only the socket is fake.

/// A [TokenStore] backed by a map. Duplicated rather than shared, like the one
/// in delta_paging_test.dart, so neither file can break the other.
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

/// Everything [GraphAuth] REQUIRES, plus the one this file is about. A grant
/// missing a core scope is a re-consent, not a Teams problem.
const String _grantedScopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Chat.Read';

const String _myId = 'me-1';

http.Response _jsonOk(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

String _iso(Duration ago) {
  final t = DateTime.now().toUtc().subtract(ago);
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second)
      .toIso8601String()
      .replaceFirst('.000Z', 'Z');
}

Map<String, dynamic> _chat({
  required String id,
  String? topic,
  String? previewAt,
  String? readAt,
}) =>
    {
      'id': id,
      'chatType': topic == null ? 'oneOnOne' : 'group',
      'topic': topic,
      'lastMessagePreview': previewAt == null
          ? null
          : {'id': 'p', 'createdDateTime': previewAt},
      // Absent unless a test says otherwise — which is the case that matters
      // most, since a tenant that does not surface the viewpoint is the one the
      // fail-quiet rule exists for.
      'viewpoint':
          readAt == null ? null : {'lastMessageReadDateTime': readAt},
    };

Map<String, dynamic> _message({
  required String id,
  String chatId = 'chat-1',
  String? userId = 'u1',
  String? displayName = 'Sarah Whitfield',
  String? applicationId,
  String messageType = 'message',
  String contentType = 'text',
  String content = 'Can you send the CD?',
  String? at,
  List<String>? mentioning,
}) {
  final stamp = at ?? _iso(const Duration(hours: 1));
  return {
    'id': id,
    'chatId': chatId,
    'messageType': messageType,
    'createdDateTime': stamp,
    'lastModifiedDateTime': stamp,
    // Graph's own nested shape — what the SDK wire carries, and what
    // McpTeamsBackend rebuilds from its flat `mentioned_user_ids` field, so
    // one helper serves for both backends. Absent unless a test asks for it:
    // a message that named nobody.
    if (mentioning != null)
      'mentions': [
        for (final userId in mentioning)
          {
            'id': 0,
            'mentionText': 'Jordan Bond',
            'mentioned': {
              'user': {'id': userId, 'displayName': 'Jordan Bond'},
            },
          },
      ],
    'from': applicationId != null
        ? {
            'user': null,
            'application': {'id': applicationId, 'displayName': displayName},
          }
        : (userId == null
            ? null
            : {
                'user': {'id': userId, 'displayName': displayName},
              }),
    'body': {'contentType': contentType, 'content': content},
  };
}

class _GraphStub {
  final List<Uri> requests = [];
  final List<Map<String, dynamic>> chats = [];
  final Map<String, List<Map<String, dynamic>>> messages = {};
  final Map<String, List<Map<String, dynamic>>> members = {};
  final Set<String> failingChats = {};
  int calls = 0;

  List<Uri> get messageRequests => [
        for (final uri in requests)
          if (uri.path.endsWith('/messages')) uri,
      ];

  List<Uri> get memberRequests => [
        for (final uri in requests)
          if (uri.path.endsWith('/members')) uri,
      ];

  String chatIdOf(Uri uri) => Uri.decodeComponent(
        uri.pathSegments[uri.pathSegments.length - 2],
      );

  MockClient get client => MockClient((request) async {
        calls++;
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          return _jsonOk({
            'access_token': 'at-1',
            'refresh_token': 'rt-2',
            'expires_in': 3600,
            'scope': _grantedScopes,
            'token_type': 'Bearer',
          });
        }
        requests.add(request.url);

        final path = request.url.path;
        if (path.endsWith('/me')) return _jsonOk({'id': _myId});
        if (path.endsWith('/me/chats')) return _jsonOk({'value': chats});
        if (path.endsWith('/members')) {
          return _jsonOk({'value': members[chatIdOf(request.url)] ?? const []});
        }
        if (path.endsWith('/messages')) {
          final id = chatIdOf(request.url);
          if (failingChats.contains(id)) {
            return http.Response('{"error":"boom"}', 500);
          }
          return _jsonOk({'value': messages[id] ?? const []});
        }
        return http.Response('unexpected ${request.url}', 404);
      });
}

/// A handler that records what the worker handed it and does no work.
class _Recording extends WorkHandler {
  @override
  final String kind;

  final List<String> seen;

  _Recording(this.kind, this.seen);

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
  }
}

/// A store that refuses to write one specific message, so the per-chat
/// transaction can be caught half done.
class _BreaksOn extends MessageStore {
  final String messageId;

  _BreaksOn(super.db, this.messageId);

  @override
  Future<void> upsertMessage(Map<String, Object?> row) {
    if (row['source_message_id'] == messageId) {
      throw StateError('disk is full');
    }
    return super.upsertMessage(row);
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _GraphStub graph;

  TeamsSync build({
    MessageStore? override,
    Future<bool> Function()? canSync,
  }) {
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;
    return TeamsSync(
      GraphTeams(
        GraphAuth(httpClient: graph.client, store: tokens),
        httpClient: graph.client,
        chatListGap: Duration.zero,
        sameChatGap: Duration.zero,
      ),
      override ?? store,
      canSync: canSync,
    );
  }

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    graph = _GraphStub();
  });

  tearDown(() async => db.close());

  Future<Map<String, Object?>> row(String id) async =>
      (await store.getMessageRow('teams', id))!;

  group('message mapping', () {
    setUp(() {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.members['chat-1'] = [
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
        {'userId': _myId, 'displayName': 'Jordan Bond'},
      ];
    });

    test('somebody else’s message is inbound and keyed on a pseudo-address',
        () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];
      await build().syncNow();

      final m = await row('m1');
      expect(m['direction'], 'inbound');
      expect(m['from_name'], 'Sarah Whitfield');
      expect(m['from_address'], 'teams:u1');
      expect(m['conversation_key'], 'chat-1');
      expect(m['subject'], isNull, reason: 'a chat message has no subject');
      expect(m['is_read'], 1,
          reason: 'this chat carries no viewpoint — see the read-state group');
      // The same queue mail joins, on the same terms: a person wrote this and
      // nothing at ingest knows whether it needs the reader.
      expect(m['triage_status'], 'pending');
      expect(m['gate_reason'], isNull);
    });

    test('the user’s own message is outbound, and skipped like sent mail',
        () async {
      graph.messages['chat-1'] = [
        _message(id: 'm1', userId: _myId, displayName: 'Jordan Bond'),
      ];
      await build().syncNow();

      final m = await row('m1');
      expect(m['direction'], 'outbound');
      expect(m['from_address'], 'teams:$_myId');
      // Triage answers "does this need me?", and the user's own message never
      // does — the same reason and the same wording mail's own sent items get.
      expect(m['triage_status'], 'skipped');
      expect(m['gate_reason'], 'outbound');
    });

    test('a message from an application is gated as auto-generated', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'bot',
          userId: null,
          applicationId: 'app-9',
          displayName: 'Pipeline Bot',
        ),
        _message(id: 'human'),
      ];
      await build().syncNow();

      expect((await row('bot'))['triage_status'], 'skipped');
      expect((await row('bot'))['gate_reason'], teamsBotGate);
      expect((await row('bot'))['direction'], 'inbound');
      expect((await row('bot'))['from_address'], 'teams:app-9');
      // The bot is the only inbound chat message ingest decides about: the
      // person beside it goes to the model like any mail.
      expect((await row('human'))['triage_status'], 'pending');
      expect((await row('human'))['gate_reason'], isNull);
    });

    test('system events never become rows', () async {
      graph.messages['chat-1'] = [
        _message(id: 'joined', messageType: 'systemEventMessage'),
        _message(id: 'said'),
      ];
      await build().syncNow();

      expect(
        (await db.customSelect('SELECT source_message_id FROM messages').get())
            .map((r) => r.data['source_message_id'])
            .toList(),
        ['said'],
      );
    });

    test('an html body is stripped and the preview is capped', () async {
      final long = 'x' * 400;
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          contentType: 'html',
          content: '<div>Hi <at>Jordan Bond</at></div><div>$long</div>',
        ),
      ];
      await build().syncNow();

      final m = await row('m1');
      expect(m['body_text'], 'Hi Jordan Bond\n$long');
      expect((m['body_preview'] as String).length, 160);
      expect(m['body_preview'], startsWith('Hi Jordan Bond\n'));
    });

    test('a message with no sender at all still stores', () async {
      graph.messages['chat-1'] = [_message(id: 'm1', userId: null)];
      await build().syncNow();

      expect((await row('m1'))['from_address'], isNull);
      expect((await row('m1'))['direction'], 'inbound');
    });
  });

  group('addressed_me', () {
    /// A chat with [others] people on it besides the user. One is a 1:1;
    /// anything more is a group.
    void seed(String id, int others) {
      graph.chats.add(_chat(
        id: id,
        topic: others > 1 ? 'Closing crew' : null,
        previewAt: _iso(Duration.zero),
      ));
      graph.members[id] = [
        {'userId': _myId, 'displayName': 'Jordan Bond'},
        for (var i = 1; i <= others; i++)
          {'userId': 'u$i', 'displayName': 'Person $i'},
      ];
    }

    test('a message in a 1:1 chat singled the user out', () async {
      seed('chat-1', 1);
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      expect((await row('m1'))['addressed_me'], 1);
    });

    test('a message to the whole group did not', () async {
      seed('chat-1', 2);
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      expect((await row('m1'))['addressed_me'], 0,
          reason: 'a group chat message is aimed at the room');
    });

    test('a group message that @mentions the user did', () async {
      seed('chat-1', 2);
      graph.messages['chat-1'] = [
        _message(id: 'named', mentioning: const [_myId]),
        _message(id: 'somebody-else', mentioning: const ['u2']),
      ];

      await build().syncNow();

      expect((await row('named'))['addressed_me'], 1);
      expect((await row('somebody-else'))['addressed_me'], 0,
          reason: 'a mention of a colleague is not a mention of the reader');
    });

    test('the user’s own message in a 1:1 is addressed to nobody', () async {
      seed('chat-1', 1);
      graph.messages['chat-1'] = [
        _message(id: 'mine', userId: _myId, displayName: 'Jordan Bond'),
      ];

      await build().syncNow();

      expect((await row('mine'))['addressed_me'], 0);
    });

    test('a later sync of a known 1:1 reads the answer off the stored roster',
        () async {
      // Members are fetched at first sight only — the request-budget rule the
      // 'members are read once per chat, ever' test pins. Every sync after it
      // has to reach the same answer from the participants that sync stored,
      // or the signal would arrive on a chat's first message and never again.
      seed('chat-1', 1);
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(hours: 2))),
      ];
      await build().syncNow();

      graph.requests.clear();
      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'm2', at: _iso(const Duration(hours: 1))),
      ];
      await build().syncNow();

      expect(graph.memberRequests, isEmpty);
      expect((await row('m2'))['addressed_me'], 1);
    });

    test('historical 1:1 chats are backfilled once', () async {
      /// A chat and one message in it as the pre-`addressed_me` syncs left
      /// them: the roster stored, the flag flat.
      Future<void> historical(String id, String key, String participants) async {
        await store.upsertConversation({
          'source': 'teams',
          'conversation_key': key,
          'participants_json': participants,
          'state': 'waiting',
          'cta_urgency': 'normal',
          'message_count': 1,
          'inbound_count': 1,
          'last_message_at': _iso(const Duration(days: 2)),
        });
        await store.upsertMessage({
          'source': 'teams',
          'source_message_id': id,
          'conversation_key': key,
          'direction': 'inbound',
          'received_at': _iso(const Duration(days: 2)),
        });
      }

      await historical(
          'direct', 'chat-old-1on1', '[{"name":"Sarah","email":"teams:u1"}]');
      await historical('grouped', 'chat-old-group',
          '[{"name":"Sarah","email":"teams:u1"},{"name":"Ed","email":"teams:u2"}]');

      seed('chat-1', 1);
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(hours: 2))),
      ];
      await build().syncNow();

      expect((await row('direct'))['addressed_me'], 1);
      expect((await row('grouped'))['addressed_me'], 0,
          reason: 'a mention inside a group chat was never stored, so the '
              'backfill covers the 1:1 half of the signal and no more');
      expect(await store.getPref('backfill_addressed_me_teams'), '1');

      // Once means once: a flat row written after the pref is set stays flat,
      // because the pass never runs again.
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'later',
        'conversation_key': 'chat-old-1on1',
        'direction': 'inbound',
        'received_at': _iso(const Duration(days: 2)),
      });
      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'm2', at: _iso(const Duration(hours: 1))),
      ];
      await build().syncNow();

      expect((await row('later'))['addressed_me'], 0);
    });
  });

  group('mentionedUserIds', () {
    test('reads the ids out of Graph’s nested shape', () {
      expect(
        TeamsSync.mentionedUserIds([
          {
            'mentioned': {
              'user': {'id': 'u1'},
            },
          },
          {
            'mentioned': {
              'user': {'id': 'u2'},
            },
          },
        ]),
        ['u1', 'u2'],
      );
    });

    test('anything else is no mention at all, never a throw', () {
      // The field can still arrive absent or malformed — an older server, a
      // shape Graph changes under us — so "no mentions" has to be the
      // cheapest possible answer at every level, never a throw.
      expect(TeamsSync.mentionedUserIds(null), isEmpty);
      expect(TeamsSync.mentionedUserIds(const []), isEmpty);
      expect(TeamsSync.mentionedUserIds('a mention'), isEmpty);
      expect(TeamsSync.mentionedUserIds([const {}]), isEmpty);
      expect(
        TeamsSync.mentionedUserIds([
          {'mentioned': null},
          {
            'mentioned': {'tag': 'everyone'},
          },
          {
            'mentioned': {
              'user': {'id': ''},
            },
          },
        ]),
        isEmpty,
      );
    });
  });

  group('read state comes from the chat’s viewpoint', () {
    /// One chat whose viewpoint says the user has read up to [readAt], holding
    /// the two messages [_readState] asks about.
    void seed({String? readAt}) {
      graph.chats.add(_chat(
        id: 'chat-1',
        previewAt: _iso(Duration.zero),
        readAt: readAt,
      ));
      graph.members['chat-1'] = [
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
      ];
    }

    test('a message older than the viewpoint is read, a newer one is not',
        () async {
      // Teams keeps ONE read timestamp per chat, and this is the whole feature:
      // projected back onto each message, it is what bolds a chat in the rail
      // exactly as an unread mail thread is bolded — and what un-bolds it when
      // the user reads the chat in Teams itself, since the viewpoint is server
      // truth and arrives on the next pull for free.
      seed(readAt: _iso(const Duration(hours: 2)));
      graph.messages['chat-1'] = [
        _message(id: 'seen', at: _iso(const Duration(hours: 3))),
        _message(id: 'new', at: _iso(const Duration(hours: 1))),
      ];

      await build().syncNow();

      expect((await row('seen'))['is_read'], 1);
      expect((await row('new'))['is_read'], 0);
    });

    test('a message AT the viewpoint is read, not unread', () async {
      // The viewpoint names the newest message the user has seen, so the
      // boundary belongs on the read side of it.
      final at = _iso(const Duration(hours: 2));
      seed(readAt: at);
      graph.messages['chat-1'] = [_message(id: 'm1', at: at)];

      await build().syncNow();

      expect((await row('m1'))['is_read'], 1);
    });

    test('the user’s own message is read whatever the viewpoint says',
        () async {
      seed(readAt: _iso(const Duration(hours: 5)));
      graph.messages['chat-1'] = [
        _message(
          id: 'mine',
          userId: _myId,
          displayName: 'Jordan Bond',
          at: _iso(const Duration(minutes: 1)),
        ),
      ];

      await build().syncNow();

      expect((await row('mine'))['is_read'], 1,
          reason: 'a reply the user wrote is not news to them');
    });

    test('a chat with no viewpoint stores everything read', () async {
      // The regression that matters: a tenant or a backend that does not
      // surface the viewpoint gets exactly the behaviour this app had before it
      // read viewpoints at all. The other way round — unread on a guess — is a
      // thread that bolds itself forever and cannot be cleared by opening it.
      seed();
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(minutes: 1))),
      ];

      await build().syncNow();

      expect((await row('m1'))['is_read'], 1);
    });

    test('an unparseable timestamp falls the same way', () async {
      seed(readAt: 'not a timestamp');
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(minutes: 1))),
      ];

      await build().syncNow();

      expect((await row('m1'))['is_read'], 1);
    });

    test('an unread chat reaches the list as a bold row', () async {
      // The end the whole chain is for: `loadConversations` counts unread
      // inbound messages, and that count is what the rail renders in bold.
      seed(readAt: _iso(const Duration(hours: 2)));
      graph.messages['chat-1'] = [
        _message(id: 'new', at: _iso(const Duration(hours: 1))),
      ];

      await build().syncNow();

      final conversation =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(conversation.unreadCount, 1);
      expect(conversation.hasUnread, isTrue);
    });
  });

  group('conversations', () {
    test('an unnamed chat is named after the people in it, never the user',
        () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.members['chat-1'] = [
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
        {'userId': 'u2', 'displayName': 'Eric Vance'},
        {'userId': _myId, 'displayName': 'Jordan Bond'},
      ];
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      final conversation =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(conversation.subject, 'Sarah Whitfield, Eric Vance');
      expect(
        conversation.participants.map((p) => p.email).toList(),
        ['teams:u1', 'teams:u2'],
      );
    });

    test('more names than fit are trimmed', () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.members['chat-1'] = [
        for (var i = 1; i <= 5; i++)
          {'userId': 'u$i', 'displayName': 'Person $i'},
      ];
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      expect(
        (await store.loadConversations(sources: const ['teams'])).single.subject,
        'Person 1, Person 2, Person 3…',
      );
    });

    test('a topic wins over the names', () async {
      graph.chats.add(
        _chat(id: 'chat-1', topic: 'Website redesign', previewAt: _iso(Duration.zero)),
      );
      graph.members['chat-1'] = [
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
      ];
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      expect(
        (await store.loadConversations(sources: const ['teams'])).single.subject,
        'Website redesign',
      );
    });

    test('an inbound chat message opens the thread, and the user’s reply '
        'closes it — the same fold mail uses', () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(hours: 2))),
      ];
      await build().syncNow();

      expect(
        (await store.loadConversations(sources: const ['teams'])).single.state,
        ConversationState.needsReply,
      );

      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(
          id: 'm2',
          userId: _myId,
          displayName: 'Jordan Bond',
          at: _iso(const Duration(hours: 1)),
        ),
      ];
      await build().syncNow();

      final conversation =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(conversation.state, ConversationState.waiting);
      expect(conversation.messageCount, 2);
      expect(conversation.inboundCount, 1);
    });

    test('the user’s reply clears the chat’s CTA — same promise mail makes',
        () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(hours: 2))),
      ];
      await build().syncNow();
      await store.updateConversationTriage(
        'teams',
        'chat-1',
        ctaText: 'Confirm the meeting time',
        ctaUrgency: 'high',
      );

      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(
          id: 'm2',
          userId: _myId,
          displayName: 'Jordan Bond',
          at: _iso(const Duration(hours: 1)),
        ),
      ];
      await build().syncNow();

      final conversation =
          (await store.loadConversations(sources: const ['teams'])).single;
      expect(conversation.state, ConversationState.waiting);
      expect(conversation.ctaText, isNull,
          reason: 'the reply resolved the standing ask, wherever it was sent');
    });

    test('a replayed message is stored again but folded only once', () async {
      final at = _iso(const Duration(hours: 2));
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [_message(id: 'm1', at: at)];
      await build().syncNow();

      store.setConversationState(
        'teams',
        'chat-1',
        ConversationState.done,
      );

      // The same message again, and a preview claiming something moved.
      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      await build().syncNow();

      expect(
        (await store.loadConversations(sources: const ['teams'])).single.state,
        ConversationState.done,
        reason: 'folding a replay would reopen a thread the user closed',
      );
    });

    test('a chat with only system events leaves no conversation row',
        () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'joined', messageType: 'systemEventMessage'),
      ];
      await build().syncNow();

      expect(await store.loadConversations(sources: const ['teams']), isEmpty);
    });
  });

  group('a newer message invalidates the draft', () {
    // The same promise the mail sync makes, and it has to be the same one: a
    // chat now drafts through the same queue, so a suggestion left standing
    // over a newer message would be a reply to the wrong thing in either inbox.

    Future<void> seedDraft({String key = 'chat-1'}) => store.upsertDraft(
          source: 'teams',
          conversationKey: key,
          replyToMessageId: 'm1',
          body: 'Sending it over this afternoon.',
          optionsJson: '[{"stance":"Confirm","body":"On its way."}]',
        );

    /// A second sync of the same chat, carrying [messages] this time.
    Future<void> syncAgain(List<Map<String, dynamic>> messages) async {
      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = messages;
      await build().syncNow();
    }

    setUp(() async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(hours: 3))),
      ];
      await build().syncNow();
    });

    test('a NEW inbound chat message deletes that chat\'s draft', () async {
      await seedDraft();

      await syncAgain([_message(id: 'm2', at: _iso(const Duration(hours: 1)))]);

      // The whole row goes, so the short replies go with it — they answered
      // the message that is no longer the newest one.
      expect(await store.getDraft('teams', 'chat-1'), isNull);
    });

    test('the user\'s own message does not', () async {
      // The thread moved on, but a draft still answers the same inbound
      // message it was written against — and the send path writes the status.
      await seedDraft();

      await syncAgain([
        _message(
          id: 'm2',
          userId: _myId,
          displayName: 'Jordan Bond',
          at: _iso(const Duration(hours: 1)),
        ),
      ]);

      expect(await store.getDraft('teams', 'chat-1'), isNotNull);
    });

    test('and a re-pulled message the store already has does not', () async {
      // Every sync re-reads the chat's recent messages, so a draft that went
      // on a replay would vanish on the next routine refresh.
      await seedDraft();

      await syncAgain([_message(id: 'm1', at: _iso(const Duration(hours: 3)))]);

      expect(await store.getDraft('teams', 'chat-1'), isNotNull);
    });

    test('and it leaves another chat\'s draft alone', () async {
      await seedDraft(key: 'chat-2');

      await syncAgain([_message(id: 'm2', at: _iso(const Duration(hours: 1)))]);

      expect(await store.getDraft('teams', 'chat-2'), isNotNull);
    });
  });

  group('what is fetched at all', () {
    test('a chat whose preview the store already has is never fetched',
        () async {
      final at = _iso(const Duration(hours: 2));
      graph.chats.add(_chat(id: 'chat-1', previewAt: at));
      graph.messages['chat-1'] = [_message(id: 'm1', at: at)];
      await build().syncNow();
      expect(graph.messageRequests.length, 1);

      graph.requests.clear();
      await build().syncNow();

      expect(graph.messageRequests, isEmpty,
          reason: 'the expanded preview is what makes a quiet chat free');
    });

    test('a chat quiet since before the floor and never seen is skipped',
        () async {
      graph.chats.add(
        _chat(id: 'old', previewAt: _iso(const Duration(days: 30))),
      );
      graph.chats.add(
        _chat(id: 'live', previewAt: _iso(const Duration(hours: 1))),
      );
      graph.messages['live'] = [_message(id: 'm1', chatId: 'live')];

      await build().syncNow();

      expect(
        graph.messageRequests.map(graph.chatIdOf).toList(),
        ['live'],
      );
    });

    test('a chat with no preview timestamp is always fetched', () async {
      graph.chats.add(_chat(id: 'chat-1'));
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      expect(graph.messageRequests.length, 1,
          reason: 'guessing "nothing new" from a missing fact is how a sync '
              'silently stops working');
    });

    test('members are read once per chat, ever', () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.members['chat-1'] = [
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
      ];
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(hours: 2))),
      ];
      await build().syncNow();
      expect(graph.memberRequests.length, 1);

      graph.requests.clear();
      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'm2', at: _iso(const Duration(hours: 1))),
      ];
      await build().syncNow();

      expect(graph.memberRequests, isEmpty);
      expect(
        (await store.loadConversations(sources: const ['teams']))
            .single
            .participants
            .single
            .name,
        'Sarah Whitfield',
        reason: 'the roster read on first sight survives every later sync',
      );
    });

    test('a refused consent costs zero requests', () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build(canSync: () async => false).syncNow();

      expect(graph.calls, 0,
          reason: 'not even the token POST — the check is before the first '
              'call, so a tenant that said no sees nothing at all');
      expect(await store.loadConversations(sources: const ['teams']), isEmpty);
    });
  });

  group('one chat, one transaction', () {
    test('a failure part way through leaves earlier chats committed and the '
        'failing one untouched', () async {
      graph.chats.addAll([
        _chat(id: 'chat-1', previewAt: _iso(Duration.zero)),
        _chat(id: 'chat-2', previewAt: _iso(Duration.zero)),
      ]);
      graph.messages['chat-1'] = [_message(id: 'a1')];
      graph.messages['chat-2'] = [
        _message(id: 'b1', chatId: 'chat-2'),
        _message(id: 'b2', chatId: 'chat-2'),
      ];

      final sync = build(override: _BreaksOn(db, 'b2'));
      await expectLater(sync.syncNow(), throwsA(isA<StateError>()));

      expect(
        (await db.customSelect('SELECT source_message_id FROM messages ORDER BY 1').get())
            .map((r) => r.data['source_message_id'])
            .toList(),
        ['a1'],
        reason: 'b1 was written before the throw and must roll back with it',
      );
      expect(
        (await db.customSelect('SELECT conversation_key FROM conversations ORDER BY 1').get())
            .map((r) => r.data['conversation_key'])
            .toList(),
        ['chat-1'],
      );
    });

    test('a chat that fails on the network stops the sync where it stands',
        () async {
      graph.chats.addAll([
        _chat(id: 'chat-1', previewAt: _iso(Duration.zero)),
        _chat(id: 'chat-2', previewAt: _iso(Duration.zero)),
      ]);
      graph.messages['chat-1'] = [_message(id: 'a1')];
      graph.failingChats.add('chat-2');

      await expectLater(
        build().syncNow(),
        throwsA(isA<GraphTeamsException>()),
      );

      expect((await store.loadConversations(sources: const ['teams'])).single.id,
          'chat-1');
      expect(await store.getSyncedAt('chats', source: 'teams'), isNull,
          reason: 'a sync that did not finish must not claim it did');
    });
  });

  group('after the walk', () {
    setUp(() {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
    });

    test('the finish is stamped', () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];
      final sync = build();

      expect(await sync.lastSyncedAt, isNull);
      await sync.syncNow();
      expect(await sync.lastSyncedAt, isNotNull);
      expect(
        DateTime.parse((await sync.lastSyncedAt)!)
            .difference(DateTime.now().toUtc())
            .abs(),
        lessThan(const Duration(minutes: 1)),
      );
    });

    test('extraction is queued for what a person wrote, and nothing else',
        () async {
      graph.messages['chat-1'] = [
        _message(id: 'human'),
        _message(id: 'mine', userId: _myId),
        _message(
          id: 'bot',
          userId: null,
          applicationId: 'app-9',
        ),
      ];

      await build().syncNow();

      expect(
        (await db.customSelect("SELECT entity_id FROM work_items WHERE task_kind = 'extract' "
                "AND source = 'teams' ORDER BY 1").get())
            .map((r) => r.data['entity_id'])
            .toList(),
        ['human'],
        reason: 'the bot is gated and the user’s own message is outbound',
      );
    });

    test('chat ingest requeues the storyline sweep, as mail ingest does',
        () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];
      await build().syncNow();

      final rows = await db
          .customSelect(
            "SELECT source, entity_id FROM work_items "
            "WHERE task_kind = 'storyline_sweep'",
          )
          .get();

      // One row, and its source says 'email' even though a chat sync wrote
      // it: the column is the row's historical label, not a scope, and both
      // syncs must land on the SAME row — there is one pool to sweep. A
      // 'teams' label here would mean two sweeps racing each other.
      expect(rows.map((r) => (r.data['source'], r.data['entity_id'])).toList(),
          [('email', 'sweep')]);
    });

    /// The worker drains BOTH sources — this is what feeds chat threads into
    /// extraction and, through it, storyline assignment. It began life as a
    /// tripwire asserting the opposite (the worker was email-scoped when this
    /// phase landed); the widening in `AiWorker._sources` is what flipped it.
    test('the queued teams rows drain alongside email', () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];
      await build().syncNow();
      // An email row of the same kind, as the control.
      await store.upsertMessage({
        'source_message_id': 'e1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'received_at': _iso(const Duration(days: 1)),
      });
      await store.enqueueExtractBacklog(sinceIso: _iso(const Duration(days: 7)));

      final drained = <String>[];
      await AiWorker(store, handlers: [_Recording('extract', drained)]).pump();

      expect(drained, unorderedEquals(['e1', 'm1']),
          reason: 'both sources feed one model queue; a chat message left '
              'pending here never reaches extraction or storylines');
    });

    /// Rows stored before chats joined the triage queue. Nothing looks at a
    /// message triage has finished with, so without this pass they would carry
    /// a retired verdict forever.
    test('legacy teams_source rows are put back in the queue, once', () async {
      Future<void> legacy(
        String id, {
        String direction = 'inbound',
        String gateReason = teamsSourceGate,
        Duration age = const Duration(days: 2),
      }) =>
          store.upsertMessage({
            'source': 'teams',
            'source_message_id': id,
            'conversation_key': 'chat-legacy',
            'direction': direction,
            'received_at': _iso(age),
            'triage_status': 'skipped',
            'gate_reason': gateReason,
          });

      await legacy('in-window');
      await legacy('mine', direction: 'outbound', gateReason: 'outbound');
      await legacy('bot', gateReason: teamsBotGate);
      await legacy('ancient', age: const Duration(days: 40));
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      expect((await row('in-window'))['triage_status'], 'pending');
      expect((await row('in-window'))['gate_reason'], isNull);
      // Everything else was skipped on a judgement that still stands, or is
      // older than the window this connector syncs at all.
      for (final id in ['mine', 'bot', 'ancient']) {
        expect((await row(id))['triage_status'], 'skipped', reason: id);
      }
      expect((await row('mine'))['gate_reason'], 'outbound');
      expect((await row('bot'))['gate_reason'], teamsBotGate);

      // Self-exhausting: nothing writes `teams_source` any more, so the next
      // refresh must not drag a message triage has since finished with back
      // into the queue. Finished means a result, not just a status — a row
      // carrying a status and no verdict is what the v2 re-judgement pass
      // beside this one exists to pick up.
      await store.writeTriage('teams', 'in-window',
          status: 'triaged', result: TriageResult.fallback());
      await build().syncNow();
      expect((await row('in-window'))['triage_status'], 'triaged');
    });

    test('a re-pulled chat message keeps its triage verdict', () async {
      // Chats have no delta link: a refresh re-pulls the window and re-upserts
      // rows the store already has, boundary message included. The upsert's
      // conflict clause leaves the triage columns alone (INSERT-only), and
      // this is where that contract is now load-bearing — without it every
      // refresh would put an already-judged chat back through the model.
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.messages['chat-1'] = [
        _message(id: 'm1', at: _iso(const Duration(hours: 2))),
      ];
      await build().syncNow();
      expect((await row('m1'))['triage_status'], 'pending');

      await store.writeTriage('teams', 'm1', status: 'triaged');
      graph.messages['chat-1']!.add(
        _message(id: 'm2', at: _iso(const Duration(minutes: 5))),
      );
      await build().syncNow();

      expect((await row('m1'))['triage_status'], 'triaged',
          reason: 'a re-pull must not send a judged message back to the model');
      expect((await row('m2'))['triage_status'], 'pending');
    });

    test('a chat triage v1 judged goes back for the v2 questions, once',
        () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];
      // The newest inbound message of a chat this app judged before triage
      // asked whether a reply is expected: `reply_expected` is NULL, and
      // nothing else would ever look at the row again.
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'v1-judged',
        'conversation_key': 'chat-legacy',
        'direction': 'inbound',
        'received_at': _iso(const Duration(days: 1)),
        'triage_status': 'triaged',
      });

      await build().syncNow();

      expect((await row('v1-judged'))['triage_status'], 'pending');

      // Self-exhausting, exactly like the gate re-pend above it: once v2 has
      // answered, the next refresh leaves the row alone.
      await store.writeTriage('teams', 'v1-judged',
          status: 'triaged', result: TriageResult.fallback());
      graph.chats
        ..clear()
        ..add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      await build().syncNow();

      expect((await row('v1-judged'))['triage_status'], 'triaged');
    });

    test('a chat the model failed on gets one more try', () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'errored',
        'conversation_key': 'chat-legacy',
        'direction': 'inbound',
        'received_at': _iso(const Duration(days: 1)),
        'triage_status': 'error',
        'triage_attempts': 2,
      });

      await build().syncNow();

      expect((await row('errored'))['triage_status'], 'pending',
          reason: 'the same revival mail gets on every sync');
    });
  });

  group('enqueueExtractBacklog filters', () {
    test('the email defaults are unchanged by the new parameters', () async {
      final fresh = _iso(const Duration(days: 1));
      final stale = _iso(const Duration(days: 30));
      for (final (id, status, at) in [
        ('a', 'pending', fresh),
        ('b', 'triaged', fresh),
        ('c', 'skipped', fresh),
        ('d', 'pending', stale),
      ]) {
        await store.upsertMessage({
          'source_message_id': id,
          'conversation_key': 'c1',
          'direction': 'inbound',
          'received_at': at,
          'triage_status': status,
        });
      }

      final added = await store.enqueueExtractBacklog(
        sinceIso: _iso(const Duration(days: 7)),
      );

      expect(added, 2);
      expect(
        (await db
                .customSelect(
                  "SELECT entity_id FROM work_items WHERE task_kind = 'extract' "
                  'ORDER BY 1',
                )
                .get())
            .map((r) => r.data['entity_id'])
            .toList(),
        ['a', 'b'],
      );
    });

    test('an empty status or reason list queues nothing rather than failing',
        () async {
      expect(
        await store.enqueueExtractBacklog(
          sinceIso: _iso(const Duration(days: 7)),
          triageStatuses: const [],
        ),
        0,
      );
      expect(
        await store.enqueueExtractBacklog(
          sinceIso: _iso(const Duration(days: 7)),
          gateReasons: const [],
        ),
        0,
      );
    });
  });

  group('stripChatHtml', () {
    test('a mention keeps the name and loses the tag', () async {
      expect(
        stripChatHtml('<div>Hey <at id="0">Jordan Bond</at>, any word?</div>'),
        'Hey Jordan Bond, any word?',
      );
    });

    test('each block tag is one line break', () async {
      expect(
        stripChatHtml('<div>one</div><div>two</div><div>three</div>'),
        'one\ntwo\nthree',
      );
      expect(stripChatHtml('a<br>b<br/>c'), 'a\nb\nc');
    });

    test('a run of block boundaries is one break, however many tags wrote it',
        () async {
      // The seam between two lines of a Teams message IS two tags.
      expect(stripChatHtml('<div>one</div>\n<div>two</div>'), 'one\ntwo');
      // Empty paragraphs collapse with it. Deliberate, and the one thing this
      // loses — see the regex.
      expect(
        stripChatHtml('<p>one</p><p></p><p></p><p></p><p>two</p>'),
        'one\ntwo',
      );
      expect(stripChatHtml('<div>a</div><div><br></div><div>b</div>'), 'a\nb');
    });

    test('formatting is dropped, its text is not', () async {
      expect(
        stripChatHtml('<p>The <strong>CD</strong> is <em>ready</em>.</p>'),
        'The CD is ready.',
      );
    });

    test('script and style content never becomes text', () async {
      expect(
        stripChatHtml('<style>p { color: red }</style><p>hello</p>'),
        'hello',
      );
      expect(
        stripChatHtml('<script>alert("x")</script><p>hello</p>'),
        'hello',
      );
    });

    test('entities decode, and a literal one a person typed survives', () async {
      expect(stripChatHtml('<p>Tom &amp; Jerry &lt;3</p>'), 'Tom & Jerry <3');
      expect(stripChatHtml('<p>&nbsp;spaced&nbsp;</p>'), 'spaced');
      expect(
        stripChatHtml('<p>type &amp;lt;b&amp;gt; to bold</p>'),
        'type &lt;b&gt; to bold',
        reason: 'decoding &amp; last is what keeps this from becoming markup '
            'and then being stripped',
      );
    });

    test('empty in, empty out', () async {
      expect(stripChatHtml(null), '');
      expect(stripChatHtml(''), '');
      expect(stripChatHtml('<div></div>'), '');
    });
  });
}
