import 'dart:convert';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

/// What a newly arrived message does to a draft written before it.
///
/// A reply answers the message that was newest when the model wrote it. The
/// moment a newer inbound message lands, that draft answers the wrong thing —
/// and the LO is one click from sending it.
///
/// The Graph stub is deliberately duplicated from sync_extract_test rather than
/// shared, so neither file can break the other by editing it.

class InMemoryTokenStore implements TokenStore {
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
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

const String _graphBase = 'https://graph.microsoft.com/v1.0';

String deltaCursor(String folder, String token) =>
    '$_graphBase/me/mailFolders/$folder/messages/delta?\$deltatoken=$token';

http.Response jsonOk(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

Map<String, dynamic> graphMessage({
  required String id,
  String conversationId = 'conv-1',
  String fromAddress = 'sarah@harborline.com',
  required String receivedDateTime,
}) =>
    {
      'id': id,
      'conversationId': conversationId,
      'subject': 'Rate lock',
      'from': {
        'emailAddress': {'name': 'Sarah', 'address': fromAddress}
      },
      'toRecipients': [
        {
          'emailAddress': {'name': null, 'address': 'lo@bond.com'}
        }
      ],
      'receivedDateTime': receivedDateTime,
      'isRead': false,
      'isDraft': false,
      'bodyPreview': 'Preview text',
    };

class GraphStub {
  final Map<String, List<http.Response Function()>> pages = {};

  void queue(String folder, List<http.Response Function()> responses) {
    pages[folder] = [...responses];
  }

  MockClient get client => MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          return jsonOk({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'expires_in': 3600,
            'scope': _grantedScopes,
            'token_type': 'Bearer',
          });
        }
        if (request.url.path.endsWith('/messages/delta')) {
          final folder =
              request.url.path.contains('sentitems') ? 'sentitems' : 'inbox';
          final queued = pages[folder];
          if (queued == null || queued.isEmpty) {
            return jsonOk({
              'value': const [],
              '@odata.deltaLink': deltaCursor(folder, 'empty'),
            });
          }
          return queued.removeAt(0)();
        }
        return http.Response('unexpected ${request.url}', 404);
      });
}

void main() {
  late Database db;
  late MessageStore store;
  late GraphStub graph;
  late SyncService sync;

  String fresh(Duration ago) =>
      DateTime.now().toUtc().subtract(ago).toIso8601String();

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
    graph = GraphStub();

    final tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;

    final auth = GraphAuth(httpClient: graph.client, store: tokens);
    sync = SyncService(GraphMail(auth, httpClient: graph.client), store);
  });

  tearDown(() => db.close());

  void seedDraft({String key = 'conv-1'}) {
    store.upsertDraft(
      source: 'email',
      conversationKey: key,
      replyToMessageId: 'old-message',
      body: 'A reply to what was said before.',
    );
  }

  void queueInbound(List<Map<String, dynamic>> messages) {
    graph.queue('inbox', [
      () => jsonOk({
            'value': messages,
            '@odata.deltaLink': deltaCursor('inbox', 'c1'),
          }),
    ]);
  }

  test('a new inbound message deletes that conversation\'s draft', () async {
    seedDraft();
    queueInbound([
      graphMessage(id: 'new-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);

    await sync.syncNow();

    expect(store.getDraft('email', 'conv-1'), isNull);
  });

  test('and leaves every other conversation\'s draft alone', () async {
    seedDraft(key: 'conv-1');
    seedDraft(key: 'conv-2');
    queueInbound([
      graphMessage(id: 'new-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);

    await sync.syncNow();

    expect(store.getDraft('email', 'conv-1'), isNull);
    expect(store.getDraft('email', 'conv-2'), isNotNull);
  });

  test('a REPLAYED message leaves the draft standing', () async {
    // Delta feeds legitimately replay messages — across pages, and wholesale
    // during the 24-hour re-drain a 410 forces. Deleting on a replay would
    // throw away a perfectly current draft, and the LO would watch their
    // suggestion vanish on a routine refresh.
    queueInbound([
      graphMessage(id: 'm1', receivedDateTime: fresh(const Duration(hours: 2))),
    ]);
    await sync.syncNow();
    seedDraft();

    graph.queue('inbox', [
      () => jsonOk({
            'value': [
              graphMessage(
                id: 'm1',
                receivedDateTime: fresh(const Duration(hours: 2)),
              ),
            ],
            '@odata.deltaLink': deltaCursor('inbox', 'c2'),
          }),
    ]);
    await sync.syncNow();

    expect(store.getDraft('email', 'conv-1'), isNotNull);
  });

  test('the LO\'s own sent mail does not invalidate the draft', () async {
    // A sent message means the thread moved on, but it does not make a draft
    // answer the wrong message — and the send path writes the status itself.
    seedDraft();
    graph.queue('sentitems', [
      () => jsonOk({
            'value': [
              graphMessage(
                id: 'sent-1',
                fromAddress: 'lo@bond.com',
                receivedDateTime: fresh(const Duration(minutes: 5)),
              ),
            ],
            '@odata.deltaLink': deltaCursor('sentitems', 'c1'),
          }),
    ]);

    await sync.syncNow();

    expect(store.getDraft('email', 'conv-1'), isNotNull);
  });

  test('a sync that brings nothing new keeps the draft', () async {
    seedDraft();

    await sync.syncNow();

    expect(store.getDraft('email', 'conv-1'), isNotNull);
  });
}
