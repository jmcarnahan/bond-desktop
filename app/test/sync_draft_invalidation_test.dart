import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// What a newly arrived message does to a draft written before it.
///
/// A reply answers ONE message. The moment a newer inbound message lands, the
/// thread is waiting on something that has no answer yet — so the thread reads
/// as having no suggestion, and the stale one stays on disk against the
/// message it did answer. Nothing is deleted: the read scopes itself, which is
/// the only way a sync can be wrong about staleness without costing the user a
/// current suggestion.
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
  String fromAddress = 'sarah@example.com',
  required String receivedDateTime,
}) =>
    {
      'id': id,
      'conversationId': conversationId,
      'subject': 'Launch date',
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
  late BondDatabase db;
  late MessageStore store;
  late GraphStub graph;
  late SyncService sync;

  String fresh(Duration ago) =>
      DateTime.now().toUtc().subtract(ago).toIso8601String();

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    graph = GraphStub();

    final tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;

    final auth = GraphAuth(httpClient: graph.client, store: tokens);
    sync = SyncService(GraphMail(auth, httpClient: graph.client), store);
  });

  tearDown(() async => db.close());

  Future<void> seedMessage(
    String id, {
    String key = 'conv-1',
    required String receivedAt,
  }) =>
      store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'inbound',
        'received_at': receivedAt,
      });

  Future<void> seedDraft({
    String key = 'conv-1',
    String messageId = 'old-message',
  }) async {
    await store.upsertDraft(
      source: 'email',
      conversationKey: key,
      replyToMessageId: messageId,
      body: 'A reply to what was said before.',
      optionsJson: '[{"stance":"Confirm Friday","body":"Friday works."}]',
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

  test('a newer inbound message takes the old suggestion out of reach',
      () async {
    await seedMessage('old-message', receivedAt: fresh(const Duration(hours: 3)));
    await seedDraft();
    queueInbound([
      graphMessage(id: 'new-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);

    await sync.syncNow();

    // The thread is waiting on new-1, which has no answer yet — so it offers
    // none, short replies included.
    expect(await store.getDraft('email', 'conv-1'), isNull);
    // And nothing was deleted. The old answer is still filed against the
    // message it answered, which is where it belongs.
    expect(await store.getDraftForMessage('email', 'old-message'), isNotNull);
  });

  test('and leaves every other conversation\'s draft alone', () async {
    await seedMessage('old-message', receivedAt: fresh(const Duration(hours: 3)));
    await seedMessage(
      'other-message',
      key: 'conv-2',
      receivedAt: fresh(const Duration(hours: 3)),
    );
    await seedDraft(key: 'conv-1');
    await seedDraft(key: 'conv-2', messageId: 'other-message');
    queueInbound([
      graphMessage(id: 'new-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);

    await sync.syncNow();

    expect(await store.getDraft('email', 'conv-1'), isNull);
    expect(await store.getDraft('email', 'conv-2'), isNotNull);
  });

  test('a REPLAYED message leaves the draft standing', () async {
    // Delta feeds legitimately replay messages — across pages, and wholesale
    // during the 24-hour re-drain a 410 forces. A replay must not cost the LO
    // a perfectly current suggestion.
    queueInbound([
      graphMessage(id: 'm1', receivedDateTime: fresh(const Duration(hours: 2))),
    ]);
    await sync.syncNow();
    await seedDraft(messageId: 'm1');

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

    expect(await store.getDraft('email', 'conv-1'), isNotNull);
  });

  test('the LO\'s own sent mail does not invalidate the draft', () async {
    // A sent message means the thread moved on, but it does not make a draft
    // answer the wrong message — the thread is still waiting on the same
    // inbound one.
    await seedMessage('old-message', receivedAt: fresh(const Duration(hours: 3)));
    await seedDraft();
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

    expect(await store.getDraft('email', 'conv-1'), isNotNull);
  });

  test('a sync that brings nothing new keeps the draft', () async {
    await seedMessage('old-message', receivedAt: fresh(const Duration(hours: 3)));
    await seedDraft();

    await sync.syncNow();

    expect(await store.getDraft('email', 'conv-1'), isNotNull);
  });
}
