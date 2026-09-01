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
}) =>
    {
      'id': id,
      'chatType': topic == null ? 'oneOnOne' : 'group',
      'topic': topic,
      'lastMessagePreview': previewAt == null
          ? null
          : {'id': 'p', 'createdDateTime': previewAt},
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
}) {
  final stamp = at ?? _iso(const Duration(hours: 1));
  return {
    'id': id,
    'chatId': chatId,
    'messageType': messageType,
    'createdDateTime': stamp,
    'lastModifiedDateTime': stamp,
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
        {'userId': _myId, 'displayName': 'Bond LO'},
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
      expect(m['is_read'], 1);
      expect(m['triage_status'], 'skipped');
      expect(m['gate_reason'], teamsSourceGate);
    });

    test('the user’s own message is outbound', () async {
      graph.messages['chat-1'] = [
        _message(id: 'm1', userId: _myId, displayName: 'Bond LO'),
      ];
      await build().syncNow();

      expect((await row('m1'))['direction'], 'outbound');
      expect((await row('m1'))['from_address'], 'teams:$_myId');
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

      expect((await row('bot'))['gate_reason'], teamsBotGate);
      expect((await row('bot'))['direction'], 'inbound');
      expect((await row('bot'))['from_address'], 'teams:app-9');
      expect((await row('human'))['gate_reason'], teamsSourceGate);
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
          content: '<div>Hi <at>Bond LO</at></div><div>$long</div>',
        ),
      ];
      await build().syncNow();

      final m = await row('m1');
      expect(m['body_text'], 'Hi Bond LO\n$long');
      expect((m['body_preview'] as String).length, 160);
      expect(m['body_preview'], startsWith('Hi Bond LO\n'));
    });

    test('a message with no sender at all still stores', () async {
      graph.messages['chat-1'] = [_message(id: 'm1', userId: null)];
      await build().syncNow();

      expect((await row('m1'))['from_address'], isNull);
      expect((await row('m1'))['direction'], 'inbound');
    });
  });

  group('conversations', () {
    test('an unnamed chat is named after the people in it, never the user',
        () async {
      graph.chats.add(_chat(id: 'chat-1', previewAt: _iso(Duration.zero)));
      graph.members['chat-1'] = [
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
        {'userId': 'u2', 'displayName': 'Eric Vance'},
        {'userId': _myId, 'displayName': 'Bond LO'},
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
          displayName: 'Bond LO',
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

    test('no storyline sweep is requeued — the sweep is email-scoped',
        () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];
      await build().syncNow();

      expect(
        await db
            .customSelect(
              "SELECT 1 FROM work_items WHERE task_kind = 'storyline_sweep' "
              "AND source = 'teams'",
            )
            .get(),
        isEmpty,
      );
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
        stripChatHtml('<div>Hey <at id="0">Bond LO</at>, any word?</div>'),
        'Hey Bond LO, any word?',
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
