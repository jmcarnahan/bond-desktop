import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/conversation_state.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// What the user's own reply does to a thread's standing CTA.
///
/// The composer's send path clears the CTA directly; these tests cover the
/// other half of that promise — a reply written in Outlook or on a phone
/// arrives through sync, and the ask it answers must not keep haunting
/// NEEDS YOU as a dimmed row nothing will ever resolve.
///
/// The Graph stub is deliberately duplicated from sync_extract_test rather
/// than shared, so neither file can break the other by editing it.

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
      'subject': 'Contract review',
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

  void queueInbound(List<Map<String, dynamic>> messages, {String token = 'c1'}) {
    graph.queue('inbox', [
      () => jsonOk({
            'value': messages,
            '@odata.deltaLink': deltaCursor('inbox', token),
          }),
    ]);
  }

  void queueSent(List<Map<String, dynamic>> messages, {String token = 's1'}) {
    graph.queue('sentitems', [
      () => jsonOk({
            'value': messages,
            '@odata.deltaLink': deltaCursor('sentitems', token),
          }),
    ]);
  }

  Future<Map<String, Object?>?> row() =>
      store.getConversationRow('email', 'conv-1');

  test('a reply synced from the server clears the CTA and folds to waiting',
      () async {
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 2))),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the contract sent earlier',
      ctaUrgency: 'high',
    );

    queueSent([
      graphMessage(
        id: 'sent-1',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 1)),
      ),
    ]);
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateWaiting);
    expect(r?['cta_text'], isNull);
    expect(r?['cta_urgency'], 'normal');
  });

  test('an outbound OLDER than the newest inbound clears nothing', () async {
    // A sent-folder backfill of an old reply answers nothing the thread is
    // currently asking; the fold refuses to go quiet and so does the CTA.
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the contract sent earlier',
      ctaUrgency: 'high',
    );

    queueSent([
      graphMessage(
        id: 'sent-old',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 3)),
      ),
    ]);
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateNeedsReply);
    expect(r?['cta_text'], 'Review the contract sent earlier');
    expect(r?['cta_urgency'], 'high');
  });

  test('a new inbound message leaves the CTA alone', () async {
    // The extract worker owns what an inbound does to the ask — sync clearing
    // it here would race the fresher CTA that worker is about to write.
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 2))),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the contract sent earlier',
      ctaUrgency: 'high',
    );

    queueInbound([
      graphMessage(id: 'in-2', receivedDateTime: fresh(const Duration(hours: 1))),
    ], token: 'c2');
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateNeedsReply);
    expect(r?['cta_text'], 'Review the contract sent earlier');
  });

  test('a reply clears a CTA that arrived while the thread was already waiting',
      () async {
    // The extract can pin an ask on a thread the state machine already calls
    // quiet ("review the attachment"). A later reply still resolves it.
    queueInbound([
      graphMessage(id: 'in-1', receivedDateTime: fresh(const Duration(hours: 3))),
    ]);
    queueSent([
      graphMessage(
        id: 'sent-1',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 2)),
      ),
    ]);
    await sync.syncNow();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Review the attachment',
      ctaUrgency: 'normal',
    );

    queueSent([
      graphMessage(
        id: 'sent-2',
        fromAddress: 'lo@bond.com',
        receivedDateTime: fresh(const Duration(hours: 1)),
      ),
    ], token: 's2');
    await sync.syncNow();

    final r = await row();
    expect(r?['state'], stateWaiting);
    expect(r?['cta_text'], isNull);
  });
}
