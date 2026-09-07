import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_teams_backend.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// What a chat sync does about attachments.
///
/// Chat has no detail step, so everything happens at ingest: the row, the
/// marker in the body, the preview without it, and the enqueue. The last group
/// is the seam — both backends have to hand `TeamsSync` the SAME entries for
/// the same message, because the sync reads one shape and knows about neither.

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

/// The hosted-content URL Teams writes into a body for a pasted image.
String _hostedSrc(String hostedId) =>
    'https://graph.microsoft.com/v1.0/chats/chat-1/messages/m1/'
    'hostedContents/$hostedId/\$value';

Map<String, dynamic> _message({
  required String id,
  String contentType = 'text',
  String content = 'Thursday works for me.',
  List<Map<String, dynamic>> attachments = const [],
}) {
  final stamp = _iso(const Duration(hours: 1));
  return {
    'id': id,
    'chatId': 'chat-1',
    'messageType': 'message',
    'createdDateTime': stamp,
    'lastModifiedDateTime': stamp,
    'from': {
      'user': {'id': 'u1', 'displayName': 'Dana Kessler'},
    },
    'body': {'contentType': contentType, 'content': content},
    if (attachments.isNotEmpty) 'attachments': attachments,
  };
}

class _GraphStub {
  final List<Map<String, dynamic>> chats = [];
  final Map<String, List<Map<String, dynamic>>> messages = {};
  final Map<String, List<Map<String, dynamic>>> members = {};

  String _chatIdOf(Uri uri) => Uri.decodeComponent(
        uri.pathSegments[uri.pathSegments.length - 2],
      );

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
        final path = request.url.path;
        if (path.endsWith('/me')) return _jsonOk({'id': _myId});
        if (path.endsWith('/me/chats')) return _jsonOk({'value': chats});
        if (path.endsWith('/members')) {
          return _jsonOk({
            'value': members[_chatIdOf(request.url)] ?? const [],
          });
        }
        if (path.endsWith('/messages')) {
          return _jsonOk({
            'value': messages[_chatIdOf(request.url)] ?? const [],
          });
        }
        return http.Response('unexpected ${request.url}', 404);
      });
}

/// A scripted MCP client. Duplicated per test file on purpose, like the one in
/// mcp_teams_backend_test.dart.
class _FakeMcp implements BondMcpClient {
  final Map<String, Object> scripted;

  _FakeMcp(this.scripted);

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    final reply = scripted[name];
    return reply is Map<String, dynamic> ? reply : <String, dynamic>{};
  }

  @override
  Future<void> close() async {}
}

/// One message back through the real MCP backend, so the reshape under test is
/// the one the app runs rather than a copy of it.
Future<Map<String, dynamic>> _throughMcp(Map<String, Object?> wire) async {
  final backend = McpTeamsBackend(
    _FakeMcp({
      'read_teams_messages': {
        'messages': [wire],
        'next_cursor': null,
      },
    }),
    chatListGap: Duration.zero,
    sameChatGap: Duration.zero,
  );
  return (await backend.chatMessagesSince('chat-1', null)).single;
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _GraphStub graph;

  TeamsSync build() {
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
      store,
    );
  }

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    graph = _GraphStub();
    graph.chats.add({
      'id': 'chat-1',
      'chatType': 'oneOnOne',
      'topic': null,
      'lastMessagePreview': {'id': 'p', 'createdDateTime': _iso(Duration.zero)},
      'viewpoint': null,
    });
    graph.members['chat-1'] = [
      {'userId': 'u1', 'displayName': 'Dana Kessler'},
      {'userId': _myId, 'displayName': 'Jordan Bond'},
    ];
  });

  tearDown(() => db.close());

  Future<Map<String, Object?>> messageRow(String id) async =>
      (await store.getMessageRow('teams', id))!;

  Future<List<String>> queuedEntities() async => [
        for (final row in await db
            .customSelect(
              "SELECT entity_id FROM work_items "
              "WHERE task_kind = 'attachment_text' ORDER BY entity_id",
            )
            .get())
          row.data['entity_id'] as String,
      ];

  group('a shared file', () {
    test('becomes an attachment row', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          contentType: 'html',
          content: '<div>Signed copy: '
              '<attachment id="file-1"></attachment></div>',
          attachments: [
            {
              'id': 'file-1',
              'contentType': 'reference',
              'name': 'lease-addendum.pdf',
              'contentUrl':
                  'https://contoso.example/sites/x/Shared/lease-addendum.pdf',
            },
          ],
        ),
      ];

      await build().syncNow();

      final stored = (await store.attachmentsForMessage('teams', 'm1')).single;
      expect(stored['attachment_id'], 'file-1');
      expect(stored['kind'], 'file');
      expect(stored['name'], 'lease-addendum.pdf');
      expect(stored['is_inline'], 0);
      expect(
        stored['source_url'],
        'https://contoso.example/sites/x/Shared/lease-addendum.pdf',
      );
      // Unknown on the wire, and 0 rather than null so a later resolve can
      // raise it with MAX().
      expect(stored['size'], 0);
    });

    test('leaves a marker in the body and a preview without it', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          contentType: 'html',
          content: '<div>Signed copy: '
              '<attachment id="file-1"></attachment></div>',
          attachments: [
            {'id': 'file-1', 'contentType': 'reference', 'name': 'x.pdf'},
          ],
        ),
      ];

      await build().syncNow();

      final row = await messageRow('m1');
      expect(row['body_text'], 'Signed copy: [[att:file-1]]');
      expect(row['body_preview'], 'Signed copy:');
      expect(row['has_attachments'], 1);
    });

    test('a file-only message is no longer empty', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          contentType: 'html',
          content: '<attachment id="file-1"></attachment>',
          attachments: [
            {
              'id': 'file-1',
              'contentType': 'reference',
              'name': 'lease-addendum.pdf',
              'contentUrl': 'https://contoso.example/x.pdf',
            },
          ],
        ),
      ];

      await build().syncNow();

      final row = await messageRow('m1');
      expect(row['body_text'], '[[att:file-1]]');
      expect(row['body_preview'], '');
      expect(row['has_attachments'], 1);
      // And the thread hydrates it, so the row can draw a chip where it sat.
      final thread = await store.loadThread('chat-1', sources: ['teams']);
      expect(thread.single.attachments.single.name, 'lease-addendum.pdf');
    });

    test('is queued for reading once it has a url', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          contentType: 'html',
          content: '<attachment id="file-1"></attachment>',
          attachments: [
            {
              'id': 'file-1',
              'contentType': 'reference',
              'name': 'lease-addendum.pdf',
              'contentUrl': 'https://contoso.example/x.pdf',
            },
          ],
        ),
      ];

      await build().syncNow();

      expect(await queuedEntities(), ['m1|file-1']);
    });
  });

  group('a pasted image', () {
    test('becomes an image row keyed by its hosted content id', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          contentType: 'html',
          content: '<div>Look: <img src="${_hostedSrc('hc-9')}"></div>',
        ),
      ];

      await build().syncNow();

      final stored = (await store.attachmentsForMessage('teams', 'm1')).single;
      expect(stored['attachment_id'], 'hc-9');
      expect(stored['kind'], 'image');
      // An image pasted into a sentence IS inline by definition.
      expect(stored['is_inline'], 1);
      expect((await messageRow('m1'))['body_text'], 'Look: [[img:hc-9]]');
    });

    test('and is never queued for text', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          contentType: 'html',
          content: '<img src="${_hostedSrc('hc-9')}">',
        ),
      ];

      await build().syncNow();

      expect(await queuedEntities(), isEmpty);
    });

    test('a card is stored and refused by kind', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          attachments: [
            {
              'id': 'card-1',
              'contentType': 'application/vnd.microsoft.card.adaptive',
              'name': null,
            },
          ],
        ),
      ];

      await build().syncNow();

      expect(
        (await store.attachmentsForMessage('teams', 'm1')).single['kind'],
        'card',
      );
      expect(await queuedEntities(), isEmpty);
    });

    test('a card records its refusal inside the ingest transaction', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          attachments: [
            {
              'id': 'card-1',
              'contentType': 'application/vnd.microsoft.card.adaptive',
              'name': null,
            },
          ],
        ),
      ];

      await build().syncNow();

      // `_ingestChat` already holds a transaction; the refusal is one guarded
      // UPDATE so it can be written from inside it.
      final row = (await store.attachmentsForMessage('teams', 'm1')).single;
      expect(row['text_status'], 'skipped');
      expect(row['text_reason'], 'kind_card');
      expect(row['digest_status'], 'skipped');
    });

    test('a second read of the chat leaves a recorded refusal alone', () async {
      graph.messages['chat-1'] = [
        _message(
          id: 'm1',
          attachments: [
            {
              'id': 'card-1',
              'contentType': 'application/vnd.microsoft.card.adaptive',
              'name': null,
            },
          ],
        ),
      ];

      await build().syncNow();
      await build().syncNow();

      final row = (await store.attachmentsForMessage('teams', 'm1')).single;
      expect(row['text_status'], 'skipped');
      expect(row['text_reason'], 'kind_card');
    });
  });

  group('an ordinary message', () {
    test('carries no paperclip and no rows', () async {
      graph.messages['chat-1'] = [_message(id: 'm1')];

      await build().syncNow();

      expect((await messageRow('m1'))['has_attachments'], 0);
      expect(await store.attachmentsForMessage('teams', 'm1'), isEmpty);
      expect(await queuedEntities(), isEmpty);
    });
  });

  group('the two backends produce the same list', () {
    test('from the same message', () async {
      const hostedId = 'hc-9';
      final graphMessage = _message(
        id: 'm1',
        contentType: 'html',
        content: '<div><attachment id="file-1"></attachment>'
            '<img src="${_hostedSrc(hostedId)}"></div>',
        attachments: [
          {
            'id': 'file-1',
            'contentType': 'reference',
            'name': 'lease-addendum.pdf',
            'contentUrl': 'https://contoso.example/x.pdf',
            'thumbnailUrl': null,
          },
        ],
      );

      // What the SDK backend normalises Graph's own shape into.
      final fromGraph = GraphTeams.attachmentEntries(graphMessage);

      // What the MCP backend passes through — the server sends this flat shape
      // already, with the inline images merged in.
      final fromMcp = (await _throughMcp({
        'id': 'm1',
        'message_type': 'message',
        'created': graphMessage['createdDateTime'],
        'last_modified': graphMessage['lastModifiedDateTime'],
        'body_content_type': 'html',
        'body_content': (graphMessage['body'] as Map)['content'],
        'from_user_id': 'u1',
        'from_user_display': 'Dana Kessler',
        'attachments': fromGraph,
      }))['attachments'];

      expect(fromMcp, fromGraph);
      expect(
        TeamsSync.attachmentRows({'attachments': fromMcp}),
        TeamsSync.attachmentRows({'attachments': fromGraph}),
      );
    });

    test('and a server that sends none leaves the key absent', () async {
      final shape = await _throughMcp({
        'id': 'm1',
        'message_type': 'message',
        'created': _iso(const Duration(hours: 1)),
        'last_modified': _iso(const Duration(hours: 1)),
        'body_content_type': 'text',
        'body_content': 'Thursday works.',
        'from_user_id': 'u1',
      });

      expect(shape.containsKey('attachments'), isFalse);
      expect(TeamsSync.attachmentRows(shape), isEmpty);
    });

    test('an unrecognised chat attachment is other, not a file', () {
      final entries = GraphTeams.attachmentEntries({
        'attachments': [
          {'id': 'x-1', 'contentType': 'application/octet-stream'},
        ],
      });

      expect(entries.single['kind'], 'other');
    });

    test('a message reference keeps its own kind', () {
      final entries = GraphTeams.attachmentEntries({
        'attachments': [
          {'id': 'q-1', 'contentType': 'messageReference'},
        ],
      });

      expect(entries.single['kind'], 'message_reference');
    });

    test('a text body cannot carry an inline image', () {
      final entries = GraphTeams.attachmentEntries({
        'body': {
          'contentType': 'text',
          'content': '<img src="${_hostedSrc('hc-9')}">',
        },
      });

      expect(entries, isEmpty);
    });
  });
}
