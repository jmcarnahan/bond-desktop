import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_teams_backend.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Teams backend over MCP, with only the wire faked.
///
/// Two things are pinned here that no amount of "did we get a list" would
/// catch. The first is the RESHAPE: `teams_sync.dart` reads Graph's nested
/// message, and a flat one silently ingests as a message from nobody with no
/// body. The second is the WALK — one page on a first sight, to exhaustion with
/// a cursor — because getting it wrong advances the caller's cursor over
/// messages that were never fetched, which is a permanent hole in a transcript.

/// A scripted client. Duplicated per test file on purpose.
class _FakeMcp implements BondMcpClient {
  /// Per tool: the replies to give, in order. A Map is returned, anything else
  /// is thrown. The last entry is sticky.
  final Map<String, List<Object>> scripted;

  final List<({String tool, Map<String, Object?> args, DateTime at})> calls = [];

  _FakeMcp([this.scripted = const {}]);

  List<Map<String, Object?>> argsOf(String tool) =>
      [for (final c in calls) if (c.tool == tool) c.args];

  /// The gap in milliseconds before the [i]th call.
  int gapBefore(int i) =>
      calls[i].at.difference(calls[i - 1].at).inMilliseconds;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add((tool: name, args: args, at: DateTime.now()));
    final queue = scripted[name];
    if (queue == null || queue.isEmpty) return <String, dynamic>{};
    final reply = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (reply is Map<String, dynamic>) return reply;
    throw reply;
  }

  @override
  Future<void> close() async {}
}

McpTeamsBackend _build(
  _FakeMcp mcp, {
  Duration? chatListGap,
  Duration? sameChatGap,
}) =>
    McpTeamsBackend(
      mcp,
      chatListGap: chatListGap ?? Duration.zero,
      sameChatGap: sameChatGap ?? Duration.zero,
    );

Map<String, dynamic> _wireMessage({
  required String id,
  String lastModified = '2026-08-28T10:00:00Z',
  String? fromUserId = 'u-1',
  String? fromUserDisplay = 'Sarah Whitfield',
  String? fromApplicationId,
}) =>
    {
      'id': id,
      'message_type': 'message',
      'from_user_id': fromUserId,
      'from_user_display': fromUserDisplay,
      'from_application_id': fromApplicationId,
      'body_content': 'hello',
      'body_content_type': 'text',
      'created': lastModified,
      'last_modified': lastModified,
    };

void main() {
  group('the profile', () {
    test('is fetched once and held for the instance', () async {
      final mcp = _FakeMcp({
        'get_profile_json': [
          {'id': 'me-1', 'display_name': 'Jared'},
        ],
      });
      final teams = _build(mcp);

      expect(await teams.myUserId(), 'me-1');
      expect(await teams.myUserId(), 'me-1');

      // One instance per session, and the id cannot change under it — a second
      // round trip would buy nothing.
      expect(mcp.argsOf('get_profile_json'), hasLength(1));
    });

    test('a profile with no id is a failure, not an empty user', () async {
      // The id is the one fact that decides whether a message is the user's
      // own; carrying on with '' would mark every message inbound.
      final mcp = _FakeMcp({
        'get_profile_json': [
          {'display_name': 'Jared'},
        ],
      });

      await expectLater(
        _build(mcp).myUserId(),
        throwsA(isA<GraphTeamsException>()),
      );
    });
  });

  group('the chat list', () {
    test('reshapes each chat into what TeamsSync reads', () async {
      final mcp = _FakeMcp({
        'list_chats_page': [
          {
            'chats': [
              {
                'id': 'chat-1',
                'topic': 'Website redesign',
                'last_preview_at': '2026-08-28T11:00:00Z',
                'last_read_at': '2026-08-28T10:30:00Z',
              },
              {'id': 'chat-2', 'topic': null, 'last_preview_at': null},
            ],
            'next_cursor': '',
          },
        ],
      });

      final chats = await _build(mcp).listChats();

      expect(chats, [
        {
          'id': 'chat-1',
          'topic': 'Website redesign',
          'lastMessagePreview': {'createdDateTime': '2026-08-28T11:00:00Z'},
          // The read viewpoint is reshaped like the preview, because
          // `teams_sync.dart` reads Graph's nested shape and the Graph backend
          // hands it back untouched. A flat `last_read_at` reaching the sync
          // would read as no viewpoint at all, and every chat would store read.
          'viewpoint': {'lastMessageReadDateTime': '2026-08-28T10:30:00Z'},
        },
        // Null, not an empty object: "nothing known" is what makes the sync
        // fetch the chat, and an empty object would read as a timestamp. The
        // same for the viewpoint — a server that does not send one leaves the
        // chat's messages stored read, which is the fail-quiet answer.
        {
          'id': 'chat-2',
          'topic': null,
          'lastMessagePreview': null,
          'viewpoint': null,
        },
      ]);
    });

    test('walks cursors and stops at the page cap', () async {
      final mcp = _FakeMcp({
        'list_chats_page': [
          for (var i = 0; i < 6; i++)
            {
              'chats': [
                {'id': 'chat-$i', 'topic': null, 'last_preview_at': null},
              ],
              'next_cursor': 'cursor-${i + 1}',
            },
        ],
      });

      final chats = await _build(mcp).listChats();

      expect(chats, hasLength(4), reason: 'four pages is the default cap');
      expect(
        mcp.argsOf('list_chats_page').map((a) => a['cursor']).toList(),
        ['', 'cursor-1', 'cursor-2', 'cursor-3'],
      );
    });

    test('an empty next_cursor ends the walk', () async {
      final mcp = _FakeMcp({
        'list_chats_page': [
          {
            'chats': [
              {'id': 'chat-1', 'topic': null, 'last_preview_at': null},
            ],
            'next_cursor': '',
          },
          {
            'chats': [
              {'id': 'chat-2', 'topic': null, 'last_preview_at': null},
            ],
            'next_cursor': '',
          },
        ],
      });

      await _build(mcp).listChats();

      expect(mcp.argsOf('list_chats_page'), hasLength(1));
    });
  });

  group('members', () {
    test('are reshaped to the two keys TeamsSync reads', () async {
      final mcp = _FakeMcp({
        'get_chat_members_json': [
          {
            'members': [
              {'user_id': 'u-1', 'display_name': 'Sarah Whitfield'},
              {'user_id': 'me-1', 'display_name': 'Jared'},
            ],
          },
        ],
      });

      final members = await _build(mcp).chatMembers('chat-1');

      expect(members, [
        {'displayName': 'Sarah Whitfield', 'userId': 'u-1'},
        {'displayName': 'Jared', 'userId': 'me-1'},
      ]);
      expect(mcp.argsOf('get_chat_members_json').single, {
        'chat_id': 'chat-1',
      });
    });
  });

  group('a chat this app has never seen', () {
    test('takes exactly one page and asks for no history', () async {
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {
            'messages': [_wireMessage(id: 'm1')],
            'next_cursor': 'more-behind-this',
          },
        ],
      });

      final messages = await _build(mcp).chatMessagesSince('chat-1', null);

      expect(messages, hasLength(1));
      expect(mcp.argsOf('list_chat_messages_page').single, {
        'chat_id': 'chat-1',
        'since': '',
        'cursor': '',
      });
    });

    test('and an empty cursor string counts as never seen', () async {
      final mcp = _FakeMcp();

      await _build(mcp).chatMessagesSince('chat-1', '');

      expect(mcp.argsOf('list_chat_messages_page').single['since'], '');
    });
  });

  group('a cursored walk', () {
    test('runs until the pages run out', () async {
      const since = '2026-08-01T00:00:00Z';
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {
            'messages': [_wireMessage(id: 'm1')],
            'next_cursor': 'c2',
          },
          {
            'messages': [_wireMessage(id: 'm2')],
            'next_cursor': '',
          },
        ],
      });

      final messages = await _build(mcp).chatMessagesSince('chat-1', since);

      expect(messages.map((m) => m['id']).toList(), ['m1', 'm2']);
      expect(
        mcp.argsOf('list_chat_messages_page').map((a) => a['cursor']).toList(),
        ['', 'c2'],
      );
      expect(mcp.argsOf('list_chat_messages_page').first['since'], since);
    });

    test('stops as soon as a page reaches back past the cursor', () async {
      const since = '2026-08-28T10:00:00Z';
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {
            'messages': [
              _wireMessage(id: 'm1', lastModified: '2026-08-28T12:00:00Z'),
              // Descending order: the last item is the page's oldest, and it
              // is already at the cursor.
              _wireMessage(id: 'm2', lastModified: since),
            ],
            'next_cursor': 'c2',
          },
        ],
      });

      final messages = await _build(mcp).chatMessagesSince('chat-1', since);

      expect(messages, hasLength(2));
      expect(mcp.argsOf('list_chat_messages_page'), hasLength(1));
    });

    test('an undated oldest message does not stop it', () async {
      // An undated message says nothing about how far back the page reached;
      // stopping on one would silently truncate the sync.
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {
            'messages': [
              {
                'id': 'm1',
                'message_type': 'systemEventMessage',
                'from_user_id': null,
                'from_application_id': null,
                'created': null,
                'last_modified': null,
              },
            ],
            'next_cursor': 'c2',
          },
          {'messages': const [], 'next_cursor': ''},
        ],
      });

      await _build(mcp).chatMessagesSince('chat-1', '2026-08-01T00:00:00Z');

      expect(mcp.argsOf('list_chat_messages_page'), hasLength(2));
    });

    test('an empty page ends it', () async {
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {'messages': const [], 'next_cursor': 'c2'},
        ],
      });

      await _build(mcp).chatMessagesSince('chat-1', '2026-08-01T00:00:00Z');

      expect(mcp.argsOf('list_chat_messages_page'), hasLength(1));
    });

    test('hitting the runaway bound is logged, because it is a hole', () async {
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {
            'messages': [
              _wireMessage(id: 'm', lastModified: '2026-08-28T12:00:00Z'),
            ],
            'next_cursor': 'always-more',
          },
        ],
      });
      final logged = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      await _build(mcp).chatMessagesSince(
        'chat-1',
        '2026-08-01T00:00:00Z',
        maxPages: 3,
      );

      expect(mcp.argsOf('list_chat_messages_page'), hasLength(3));
      expect(logged.single, contains('chat-1'));
      expect(logged.single, contains('will not be fetched'));
    });

    test('but an early stop is the walk finishing, and says nothing', () async {
      const since = '2026-08-28T10:00:00Z';
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {
            'messages': [_wireMessage(id: 'm1', lastModified: since)],
            'next_cursor': 'c2',
          },
        ],
      });
      final logged = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
      addTearDown(() => debugPrint = previous);

      await _build(mcp).chatMessagesSince('chat-1', since);

      expect(logged, isEmpty);
    });
  });

  group('the message reshape', () {
    Future<Map<String, dynamic>> only(Map<String, dynamic> wire) async {
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          {
            'messages': [wire],
            'next_cursor': '',
          },
        ],
      });
      final messages = await _build(mcp).chatMessagesSince('chat-1', null);
      return messages.single;
    }

    test('is the nested Graph shape TeamsSync reads', () async {
      final message = await only(_wireMessage(id: 'm1'));

      expect(message, {
        'id': 'm1',
        'messageType': 'message',
        'createdDateTime': '2026-08-28T10:00:00Z',
        'lastModifiedDateTime': '2026-08-28T10:00:00Z',
        'body': {'contentType': 'text', 'content': 'hello'},
        'from': {
          'user': {'id': 'u-1', 'displayName': 'Sarah Whitfield'},
        },
      });
    });

    test('a bot becomes an application, with the name the wire has', () async {
      // There is no from_application_display on the wire, so the name is null.
      // TeamsSync tolerates that, and gates the message out of extraction on
      // the application key alone.
      final message = await only(_wireMessage(
        id: 'm1',
        fromUserId: null,
        fromUserDisplay: null,
        fromApplicationId: 'app-1',
      ));

      expect(message['from'], {
        'application': {'id': 'app-1', 'displayName': null},
      });
    });

    test('a system event has no sender at all', () async {
      // Not an object full of nulls: that would read as a person with no name.
      final message = await only(_wireMessage(
        id: 'm1',
        fromUserId: null,
        fromUserDisplay: null,
      ));

      expect(message['from'], isNull);
    });
  });

  group('marking a chat read', () {
    test('names the chat and nothing else', () async {
      // No message ids and no user: the server resolves the identity from the
      // connected account, and Teams keeps one read viewpoint per chat.
      final mcp = _FakeMcp({
        'mark_chat_read_json': [
          {'ok': true},
        ],
      });

      await _build(mcp).markChatRead('chat-1');

      expect(mcp.argsOf('mark_chat_read_json').single, {'chat_id': 'chat-1'});
    });

    test('an ok:false is a failure the queue must see, not a quiet no-op',
        () async {
      // The whole point of the ack queue is noticing a read that did not land.
      // Swallowing this would leave the server's unread badge wrong forever
      // with nothing recorded anywhere.
      final mcp = _FakeMcp({
        'mark_chat_read_json': [
          {'ok': false, 'error': 'no_identity'},
        ],
      });

      await expectLater(
        _build(mcp).markChatRead('chat-1'),
        throwsA(isA<GraphTeamsException>()
            .having((e) => e.message, 'message', contains('no_identity'))),
      );
    });

    test('an unconnected workspace is still a sign-in problem', () async {
      final mcp = _FakeMcp({
        'mark_chat_read_json': [
          {'error': 'not_connected', 'connect_url': null},
        ],
      });

      await expectLater(
        _build(mcp).markChatRead('chat-1'),
        throwsA(isA<ReconsentRequired>()),
      );
    });
  });

  group('sending a chat message', () {
    test('carries the text, and answers in the shape a synced message has',
        () async {
      // Shape-identical on purpose: the caller writes this straight into
      // `messages`, and a row built from a different shape would disagree with
      // the one the next pull builds for the very same message.
      final mcp = _FakeMcp({
        'send_chat_message_json': [
          {'message': _wireMessage(id: 'sent-1', fromUserId: 'me-1')},
        ],
      });

      final sent = await _build(mcp).sendChatMessage('chat-1', 'On it.');

      expect(mcp.argsOf('send_chat_message_json').single, {
        'chat_id': 'chat-1',
        'text': 'On it.',
      });
      expect(sent, {
        'id': 'sent-1',
        'messageType': 'message',
        'createdDateTime': '2026-08-28T10:00:00Z',
        'lastModifiedDateTime': '2026-08-28T10:00:00Z',
        'body': {'contentType': 'text', 'content': 'hello'},
        'from': {
          'user': {'id': 'me-1', 'displayName': 'Sarah Whitfield'},
        },
      });
    });

    test('a null message is a send that did not happen', () async {
      // Returning something empty here would put "sent" on screen over a chat
      // that never received anything.
      final mcp = _FakeMcp({
        'send_chat_message_json': [
          {'message': null, 'error': 'text must not be empty'},
        ],
      });

      await expectLater(
        _build(mcp).sendChatMessage('chat-1', ''),
        throwsA(isA<GraphTeamsException>()
            .having((e) => e.message, 'message', contains('must not be empty'))),
      );
    });
  });

  group('the throttle floors', () {
    test('are the Graph backend’s own, not a second pair', () {
      // The ToU discipline is ours whichever transport carries the request.
      expect(GraphTeams.defaultSameChatGap, const Duration(seconds: 1));
      expect(GraphTeams.defaultChatListGap, const Duration(milliseconds: 200));
    });

    test('two pulls on one chat are held a gap apart', () async {
      const gap = Duration(milliseconds: 120);
      final mcp = _FakeMcp();
      final teams = _build(mcp, sameChatGap: gap);

      await teams.chatMessagesSince('chat-1', null);
      await teams.chatMessagesSince('chat-1', null);

      expect(mcp.gapBefore(1), greaterThanOrEqualTo(gap.inMilliseconds - 10));
    });

    test('two different chats are not', () async {
      final mcp = _FakeMcp();
      final teams = _build(mcp, sameChatGap: const Duration(milliseconds: 400));

      await teams.chatMessagesSince('chat-1', null);
      await teams.chatMessagesSince('chat-2', null);

      expect(mcp.gapBefore(1), lessThan(400),
          reason: 'the floor is per chat, as the throttle is');
    });

    test('and the writes wait on it too, not only the reads', () async {
      const gap = Duration(milliseconds: 120);
      final mcp = _FakeMcp({
        'mark_chat_read_json': [
          {'ok': true},
        ],
        'send_chat_message_json': [
          {'message': _wireMessage(id: 'sent-1')},
        ],
      });
      final teams = _build(mcp, sameChatGap: gap);

      await teams.markChatRead('chat-1');
      await teams.sendChatMessage('chat-1', 'On it.');

      expect(mcp.gapBefore(1), greaterThanOrEqualTo(gap.inMilliseconds - 10));
    });

    test('and the chat list has a floor of its own', () async {
      const gap = Duration(milliseconds: 80);
      final mcp = _FakeMcp({
        'list_chats_page': [
          {'chats': const [], 'next_cursor': 'c2'},
          {'chats': const [], 'next_cursor': ''},
        ],
      });

      await _build(mcp, chatListGap: gap).listChats();

      expect(mcp.argsOf('list_chats_page'), hasLength(2));
      expect(mcp.gapBefore(1), greaterThanOrEqualTo(gap.inMilliseconds - 10));
    });
  });

  group('failures', () {
    test('an unconnected workspace is a sign-in problem', () async {
      final mcp = _FakeMcp({
        'list_chats_page': [
          {'error': 'not_connected', 'connect_url': null},
        ],
      });

      await expectLater(
        _build(mcp).listChats(),
        throwsA(isA<ReconsentRequired>()),
      );
    });

    test('a Graph status inside a tool error is carried through', () async {
      final mcp = _FakeMcp({
        'list_chat_messages_page': [
          const McpToolException('Graph API error 403 (Forbidden): no consent'),
        ],
      });

      await expectLater(
        _build(mcp).chatMessagesSince('chat-1', null),
        throwsA(isA<GraphTeamsException>()
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('a transport failure keeps its HTTP status', () async {
      final mcp = _FakeMcp({
        'get_chat_members_json': [
          const McpTransportException('gateway said no', statusCode: 502),
        ],
      });

      await expectLater(
        _build(mcp).chatMembers('chat-1'),
        throwsA(isA<GraphTeamsException>()
            .having((e) => e.statusCode, 'statusCode', 502)),
      );
    });

    test('an auth failure passes through unwrapped', () async {
      final mcp = _FakeMcp({
        'get_profile_json': [const NotSignedIn()],
      });

      await expectLater(_build(mcp).myUserId(), throwsA(isA<NotSignedIn>()));
    });
  });
}
