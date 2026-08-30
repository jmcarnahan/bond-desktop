import 'dart:convert';

import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The chat endpoints, with only the socket faked.
///
/// Most of this file is about the URL. Three of Graph's chat rules fail
/// SILENTLY when they are broken — an unsupported `$orderby` property, a
/// `$filter` on a property the order does not name, a space encoded as `+` —
/// and every one of them comes back HTTP 200 with the wrong messages in it. A
/// test that only checked "did we get a list" would pass against all three, so
/// what is pinned here is the query string itself.

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

const String _grantedScopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Chat.Read';

http.Response _jsonOk(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

/// One request as it was seen: the URL, and when it left.
class _Sent {
  final Uri url;
  final DateTime at;

  _Sent(this.url, this.at);
}

class _GraphStub {
  final List<_Sent> sent = [];
  final List<http.Response Function()> chatPages = [];
  final Map<String, List<http.Response Function()>> messagePages = {};
  http.Response Function()? members;

  List<Uri> get urls => [for (final s in sent) s.url];

  /// The gap before the [i]th request, in milliseconds.
  int gapBefore(int i) =>
      sent[i].at.difference(sent[i - 1].at).inMilliseconds;

  MockClient get client => MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          return _jsonOk({
            'access_token': 'at-1',
            'refresh_token': 'rt-2',
            'expires_in': 3600,
            'scope': _grantedScopes,
            'token_type': 'Bearer',
          });
        }

        expect(request.headers['Authorization'], startsWith('Bearer '),
            reason: 'every Graph call carries the bearer token');
        sent.add(_Sent(request.url, DateTime.now()));

        final path = request.url.path;
        if (path.endsWith('/me')) return _jsonOk({'id': 'me-1'});
        if (path.endsWith('/me/chats')) {
          if (chatPages.isEmpty) return _jsonOk({'value': const []});
          return chatPages.removeAt(0)();
        }
        if (path.endsWith('/members')) {
          return (members ?? () => _jsonOk({'value': const []}))();
        }
        if (path.endsWith('/messages')) {
          final chatId = Uri.decodeComponent(
            request.url.pathSegments[request.url.pathSegments.length - 2],
          );
          final queued = messagePages[chatId];
          if (queued == null || queued.isEmpty) {
            return _jsonOk({'value': const []});
          }
          return queued.removeAt(0)();
        }
        return http.Response('unexpected ${request.url}', 404);
      });
}

Map<String, dynamic> _chatMessage({
  required String id,
  String lastModified = '2026-08-28T10:00:00Z',
}) =>
    {
      'id': id,
      'messageType': 'message',
      'createdDateTime': lastModified,
      'lastModifiedDateTime': lastModified,
      'body': {'contentType': 'text', 'content': 'hello'},
    };

void main() {
  late _GraphStub graph;

  GraphTeams build({Duration? chatListGap, Duration? sameChatGap}) {
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;
    return GraphTeams(
      GraphAuth(httpClient: graph.client, store: tokens),
      httpClient: graph.client,
      chatListGap: chatListGap ?? Duration.zero,
      sameChatGap: sameChatGap ?? Duration.zero,
    );
  }

  setUp(() => graph = _GraphStub());

  group('the chat list URL', () {
    test('orders on the expanded preview, which is the only sortable '
        'timestamp a chat has', () async {
      await build().listChats();

      final query = graph.urls.single.query;
      expect(query, contains(r'$expand=lastMessagePreview'));
      expect(query, contains(r'$top=50'));
      // Graph rejects an order on lastUpdatedDateTime outright.
      expect(query, isNot(contains('lastUpdatedDateTime')));
      expect(
        graph.urls.single.queryParameters[r'$orderby'],
        'lastMessagePreview/createdDateTime desc',
      );
    });

    test('encodes the space as %20, never as +', () async {
      await build().listChats();

      final query = graph.urls.single.query;
      expect(query, contains('%20desc'));
      // A `+` here reaches Graph's OData parser as a literal plus and the
      // order is rejected — the exact reason this URL is built by hand.
      expect(query, isNot(contains('+')));
    });

    test('follows nextLink verbatim, up to maxPages', () async {
      const next = 'https://graph.microsoft.com/v1.0/me/chats?\$skiptoken=abc';
      graph.chatPages.addAll([
        () => _jsonOk({
              'value': [
                {'id': 'chat-1'}
              ],
              '@odata.nextLink': next,
            }),
        () => _jsonOk({
              'value': [
                {'id': 'chat-2'}
              ],
              '@odata.nextLink': next,
            }),
      ]);

      final chats = await build().listChats(maxPages: 2);

      expect(chats.map((c) => c['id']).toList(), ['chat-1', 'chat-2']);
      expect(graph.urls.length, 2, reason: 'maxPages stops the walk');
      expect(graph.urls[1].toString(), next);
    });
  });

  group('the chat messages URL', () {
    test('filters and orders on the SAME property', () async {
      await build().chatMessagesSince('chat-1', '2026-08-20T00:00:00Z');

      final params = graph.urls.single.queryParameters;
      String property(String clause) => clause.split(' ').first;

      expect(property(params[r'$orderby']!), property(params[r'$filter']!));
      // Not createdDateTime: it supports only `lt`, which is the wrong
      // direction for "what is new".
      expect(property(params[r'$filter']!), 'lastModifiedDateTime');
      expect(params[r'$orderby'], 'lastModifiedDateTime desc');
      expect(params[r'$filter'], 'lastModifiedDateTime gt 2026-08-20T00:00:00Z');
      expect(graph.urls.single.query, isNot(contains('+')));
      expect(graph.urls.single.query, contains('%20'));
    });

    test('a first run sends no filter and takes exactly one page', () async {
      graph.messagePages['chat-1'] = [
        () => _jsonOk({
              'value': [_chatMessage(id: 'm1')],
              '@odata.nextLink':
                  'https://graph.microsoft.com/v1.0/chats/chat-1/messages?p=2',
            }),
      ];

      final messages = await build().chatMessagesSince('chat-1', null);

      expect(messages.length, 1);
      expect(graph.urls.single.queryParameters[r'$filter'], isNull);
      expect(graph.urls.length, 1,
          reason: 'the newest fifty are enough for a chat never seen before');
    });

    test('walks pages until one reaches back past the cursor', () async {
      const next =
          'https://graph.microsoft.com/v1.0/chats/chat-1/messages?p=2';
      graph.messagePages['chat-1'] = [
        () => _jsonOk({
              'value': [
                _chatMessage(id: 'm3', lastModified: '2026-08-28T10:00:00Z'),
                _chatMessage(id: 'm2', lastModified: '2026-08-27T10:00:00Z'),
              ],
              '@odata.nextLink': next,
            }),
        () => _jsonOk({
              'value': [
                _chatMessage(id: 'm1', lastModified: '2026-08-19T10:00:00Z'),
              ],
              '@odata.nextLink': next,
            }),
      ];

      final messages =
          await build().chatMessagesSince('chat-1', '2026-08-20T00:00:00Z');

      expect(messages.map((m) => m['id']).toList(), ['m3', 'm2', 'm1']);
      expect(graph.urls.length, 2,
          reason: "the second page's oldest predates the cursor, so the "
              'pages behind it are history the store already has');
    });

    test('an empty page ends the walk', () async {
      graph.messagePages['chat-1'] = [
        () => _jsonOk({
              'value': const [],
              '@odata.nextLink':
                  'https://graph.microsoft.com/v1.0/chats/chat-1/messages?p=2',
            }),
      ];

      final messages =
          await build().chatMessagesSince('chat-1', '2026-08-20T00:00:00Z');

      expect(messages, isEmpty);
      expect(graph.urls.length, 1);
    });

    test('an undated oldest message does NOT end the walk', () async {
      const next =
          'https://graph.microsoft.com/v1.0/chats/chat-1/messages?p=2';
      graph.messagePages['chat-1'] = [
        () => _jsonOk({
              'value': [
                {'id': 'm2', 'messageType': 'message'},
              ],
              '@odata.nextLink': next,
            }),
        () => _jsonOk({
              'value': [
                _chatMessage(id: 'm1', lastModified: '2026-08-01T10:00:00Z'),
              ],
            }),
      ];

      final messages =
          await build().chatMessagesSince('chat-1', '2026-08-20T00:00:00Z');

      expect(messages.length, 2,
          reason: 'an undated message says nothing about how far back the '
              'page reached, and stopping on one would truncate the sync');
    });
  });

  group('throttle', () {
    test('the documented floors are the defaults', () {
      expect(GraphTeams.defaultSameChatGap, const Duration(seconds: 1));
      expect(GraphTeams.defaultChatListGap, const Duration(milliseconds: 200));
    });

    test('waits between two requests to the same chat', () async {
      const gap = Duration(milliseconds: 120);
      const next =
          'https://graph.microsoft.com/v1.0/chats/chat-1/messages?p=2';
      graph.messagePages['chat-1'] = [
        () => _jsonOk({
              'value': [
                _chatMessage(id: 'm2', lastModified: '2026-08-28T10:00:00Z'),
              ],
              '@odata.nextLink': next,
            }),
        () => _jsonOk({
              'value': [
                _chatMessage(id: 'm1', lastModified: '2026-08-01T10:00:00Z'),
              ],
            }),
      ];

      final teams = build(sameChatGap: gap);
      await teams.chatMessagesSince('chat-1', '2026-08-20T00:00:00Z');

      expect(graph.urls.length, 2);
      expect(graph.gapBefore(1), greaterThanOrEqualTo(gap.inMilliseconds - 10));
    });

    test('two different chats do not wait on each other', () async {
      final teams = build(sameChatGap: const Duration(milliseconds: 400));
      await teams.chatMessagesSince('chat-1', null);
      await teams.chatMessagesSince('chat-2', null);

      expect(graph.urls.length, 2);
      expect(graph.gapBefore(1), lessThan(400),
          reason: 'the throttle is per chat, which is what Graph asks for');
    });

    test('waits between chat-list pages', () async {
      const gap = Duration(milliseconds: 80);
      const next = 'https://graph.microsoft.com/v1.0/me/chats?\$skiptoken=abc';
      graph.chatPages.addAll([
        () => _jsonOk({'value': const [], '@odata.nextLink': next}),
        () => _jsonOk({'value': const []}),
      ]);

      await build(chatListGap: gap).listChats();

      expect(graph.urls.length, 2);
      expect(graph.gapBefore(1), greaterThanOrEqualTo(gap.inMilliseconds - 10));
    });
  });

  group('failures', () {
    test('a 429 is retried once, honouring Retry-After', () async {
      var calls = 0;
      graph.chatPages.add(() {
        calls++;
        return http.Response('throttled', 429, headers: {'retry-after': '0'});
      });

      // The stub answers an empty finished list once the queued 429 is gone.
      final chats = await build().listChats();

      expect(calls, 1);
      expect(graph.urls.length, 2);
      expect(chats, isEmpty);
    });

    test('a second 429 gives up rather than looping', () async {
      graph.chatPages.addAll([
        () => http.Response('throttled', 429, headers: {'retry-after': '0'}),
        () => http.Response('throttled', 429, headers: {'retry-after': '0'}),
      ]);

      await expectLater(
        build().listChats(),
        throwsA(isA<GraphTeamsException>()
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
      expect(graph.urls.length, 2);
    });

    test('a 401 is retried once', () async {
      graph.chatPages.add(() => http.Response('nope', 401));

      final chats = await build().listChats();

      expect(graph.urls.length, 2);
      expect(chats, isEmpty);
    });

    test('a transport failure arrives as a Teams exception, not a mail one',
        () async {
      graph.chatPages.add(() => throw http.ClientException('reset'));

      await expectLater(
        build().listChats(),
        throwsA(isA<GraphTeamsException>()),
      );
    });
  });

  group('the rest', () {
    test('myUserId reads /me', () async {
      expect(await build().myUserId(), 'me-1');
      expect(graph.urls.single.path, endsWith('/me'));
    });

    test('a profile with no id is a failure, not an empty string', () async {
      // An empty id would make every message look like somebody else's, and
      // the whole chat list would arrive inbound.
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          return _jsonOk({
            'access_token': 'at-1',
            'expires_in': 3600,
            'scope': _grantedScopes,
          });
        }
        return _jsonOk(const <String, Object?>{});
      });
      final tokens = _Tokens();
      tokens.values['refresh_token'] = 'rt';
      tokens.values['granted_scopes'] = _grantedScopes;

      await expectLater(
        GraphTeams(
          GraphAuth(httpClient: client, store: tokens),
          httpClient: client,
        ).myUserId(),
        throwsA(isA<GraphTeamsException>()),
      );
    });

    test('members is one request, capped at fifty', () async {
      graph.members = () => _jsonOk({
            'value': [
              {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
            ],
            '@odata.nextLink':
                'https://graph.microsoft.com/v1.0/chats/chat-1/members?p=2',
          });

      final members = await build().chatMembers('chat-1');

      expect(members.single['displayName'], 'Sarah Whitfield');
      expect(graph.urls.length, 1,
          reason: 'a group chat larger than one page has a name of its own');
      expect(graph.urls.single.queryParameters[r'$top'], '50');
    });
  });
}
