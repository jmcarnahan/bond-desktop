import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// What the ingest keeps off a sent message's To: line.
///
/// The NAME, which it used to drop. Every recipient of the user's own mail
/// landed as `{name: null, email}`, so an outbound-only thread showed a bare
/// address in the thread header, in the recent-people typeahead and on the
/// colleague's own row under People.
///
/// The other half of the claim is that `to_json` did NOT change shape: it is a
/// list of address STRINGS, and `recipientsFromJson` and the local-echo path
/// both read it that way.
///
/// The Graph stub is deliberately duplicated from `sync_cta_resolution_test`
/// rather than shared, so neither file can break the other by editing it.

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

/// One sent message, addressed to [to] as `(name, address)` pairs.
Map<String, dynamic> sentMessage({
  required String id,
  required String receivedDateTime,
  String conversationId = 'conv-1',
  List<(String?, String)> to = const [('Todd Alder', 'todd@example.test')],
}) =>
    {
      'id': id,
      'conversationId': conversationId,
      'subject': 'The rate sheet',
      'from': {
        'emailAddress': {'name': 'Jordan Bond', 'address': 'jordan@bond.test'}
      },
      'toRecipients': [
        for (final (name, address) in to)
          {
            'emailAddress': {'name': name, 'address': address}
          },
      ],
      'receivedDateTime': receivedDateTime,
      'isRead': true,
      'isDraft': false,
      'bodyPreview': 'Attached.',
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
    sync = SyncService(
      GraphMail(auth, httpClient: graph.client),
      store,
      progress: PipelineProgress(store),
    );
  });

  tearDown(() async => db.close());

  void queueSent(List<Map<String, dynamic>> messages, {String token = 's1'}) {
    graph.queue('sentitems', [
      () => jsonOk({
            'value': messages,
            '@odata.deltaLink': deltaCursor('sentitems', token),
          }),
    ]);
  }

  Future<List<(String?, String?)>> participants(String key) async {
    final row = await store.getConversationRow('email', key);
    final decoded = jsonDecode(row!['participants_json'] as String) as List;
    return [
      for (final p in decoded)
        ((p as Map)['name'] as String?, p['email'] as String?),
    ];
  }

  test('a recipient lands with the name the wire carried', () async {
    queueSent([
      sentMessage(id: 'sent-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);

    await sync.syncNow();

    expect(await participants('conv-1'), [
      ('Todd Alder', 'todd@example.test'),
    ]);
  });

  test('and to_json is still a list of address strings', () async {
    queueSent([
      sentMessage(
        id: 'sent-1',
        receivedDateTime: fresh(const Duration(hours: 1)),
        to: const [
          ('Todd Alder', 'todd@example.test'),
          ('Priya Raman', 'priya@example.test'),
        ],
      ),
    ]);

    await sync.syncNow();

    final row = await store.getMessageRow('email', 'sent-1');
    expect(
      jsonDecode(row!['to_json'] as String),
      ['todd@example.test', 'priya@example.test'],
    );
  });

  test('a recipient the wire did not name is still stored, nameless',
      () async {
    // Nothing is looked up at ingest — the backfill and the People layer's
    // read-time resolution are where a missing name gets filled.
    queueSent([
      sentMessage(
        id: 'sent-1',
        receivedDateTime: fresh(const Duration(hours: 1)),
        to: const [(null, 'todd@example.test')],
      ),
    ]);

    await sync.syncNow();

    expect(await participants('conv-1'), [(null, 'todd@example.test')]);
  });

  test('a later message names an address an earlier one left bare', () async {
    queueSent([
      sentMessage(
        id: 'sent-1',
        receivedDateTime: fresh(const Duration(hours: 2)),
        to: const [(null, 'todd@example.test')],
      ),
    ]);
    await sync.syncNow();
    expect(await participants('conv-1'), [(null, 'todd@example.test')]);

    queueSent([
      sentMessage(
        id: 'sent-2',
        receivedDateTime: fresh(const Duration(hours: 1)),
        to: const [('Todd Alder', 'todd@example.test')],
      ),
    ], token: 's2');
    await sync.syncNow();

    expect(await participants('conv-1'), [
      ('Todd Alder', 'todd@example.test'),
    ]);
  });

  test('a recipient with no address at all is dropped', () async {
    queueSent([
      sentMessage(
        id: 'sent-1',
        receivedDateTime: fresh(const Duration(hours: 1)),
        to: const [('Todd Alder', ''), ('Priya Raman', 'priya@example.test')],
      ),
    ]);

    await sync.syncNow();

    expect(await participants('conv-1'), [
      ('Priya Raman', 'priya@example.test'),
    ]);
  });

  test('the backfill runs once and records its pref', () async {
    queueSent([
      sentMessage(id: 'sent-1', receivedDateTime: fresh(const Duration(hours: 1))),
    ]);

    await sync.syncNow();

    expect(await store.getPref('participant_names_backfill'), '1');
  });
}
