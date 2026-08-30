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

/// What a sync leaves on the extraction queue. A scripted Graph on one side, a
/// real sqlite database on the other; only the socket is fake.
///
/// The stub is deliberately duplicated from delta_paging_test rather than
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
  String? conversationId = 'conv-1',
  String subject = 'Closing Disclosure',
  String fromAddress = 'sarah@harborline.com',
  required String receivedDateTime,
}) =>
    {
      'id': id,
      'conversationId': ?conversationId,
      'subject': subject,
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

Map<String, dynamic> deltaBody(
  List<Map<String, dynamic>> messages, {
  String? deltaLink,
}) =>
    {'value': messages, '@odata.deltaLink': ?deltaLink};

class GraphStub {
  final Map<String, List<http.Response Function()>> pages = {};
  int tokenPosts = 0;

  void queue(String folder, List<http.Response Function()> responses) {
    pages[folder] = [...responses];
  }

  MockClient get client => MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          tokenPosts++;
          return jsonOk({
            'access_token': 'at-$tokenPosts',
            'refresh_token': 'rt-$tokenPosts',
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
            return jsonOk(
              deltaBody(const [], deltaLink: deltaCursor(folder, 'empty')),
            );
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

  /// Inside both the sync floor and the triage window.
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

  List<String> queuedIds() => [
        for (final row in db.select(
          "SELECT entity_id FROM work_items WHERE task_kind = 'extract' "
          'ORDER BY entity_id',
        ))
          row['entity_id'] as String,
      ];

  test('a sync queues extraction for the inbound mail it kept', () async {
    graph.queue('inbox', [
      () => jsonOk(deltaBody(
            [
              graphMessage(id: 'fresh-1', receivedDateTime: fresh(const Duration(days: 1))),
              graphMessage(
                id: 'fresh-2',
                conversationId: 'conv-2',
                receivedDateTime: fresh(const Duration(days: 2)),
              ),
              // Older than the triage window: skipped on insert, and outside
              // the window the backlog enqueue reads.
              graphMessage(
                id: 'stale',
                conversationId: 'conv-3',
                receivedDateTime:
                    fresh(const Duration(days: triageWindowDays + 1)),
              ),
            ],
            deltaLink: deltaCursor('inbox', 'c1'),
          )),
    ]);
    graph.queue('sentitems', [
      () => jsonOk(deltaBody(
            [
              graphMessage(
                id: 'sent-1',
                fromAddress: 'lo@bond.com',
                receivedDateTime: fresh(const Duration(hours: 6)),
              )
            ],
            deltaLink: deltaCursor('sentitems', 'c1'),
          )),
    ]);

    await sync.syncNow();

    // Inbound and inside the window only: the LO's own sent mail and the
    // backlog cost model time and answer nothing.
    expect(queuedIds(), ['fresh-1', 'fresh-2']);
    expect(store.workCounts('extract'), {'pending': 2});
  });

  test('a second sync neither duplicates nor resurrects', () async {
    graph.queue('inbox', [
      () => jsonOk(deltaBody(
            [graphMessage(id: 'm1', receivedDateTime: fresh(const Duration(days: 1)))],
            deltaLink: deltaCursor('inbox', 'c1'),
          )),
    ]);
    await sync.syncNow();
    store.writeWork('extract', 'email', 'm1', status: 'done');

    graph.queue('inbox', [
      () => jsonOk(deltaBody(
            [
              graphMessage(
                id: 'm2',
                conversationId: 'conv-2',
                receivedDateTime: fresh(const Duration(hours: 1)),
              )
            ],
            deltaLink: deltaCursor('inbox', 'c2'),
          )),
    ]);
    await sync.syncNow();

    expect(queuedIds(), ['m1', 'm2']);
    expect(store.workCounts('extract'), {'done': 1, 'pending': 1});
  });

  test('a first run queues no more than the triage cap', () async {
    final base = DateTime.now().toUtc().subtract(const Duration(days: 1));
    graph.queue('inbox', [
      () => jsonOk(deltaBody(
            [
              for (var i = 0; i < 160; i++)
                graphMessage(
                  id: 'm${i.toString().padLeft(3, '0')}',
                  conversationId: 'conv-$i',
                  receivedDateTime: base.add(Duration(minutes: i)).toIso8601String(),
                ),
            ],
            deltaLink: deltaCursor('inbox', 'c1'),
          )),
    ]);

    await sync.syncNow();

    // The ten the triage cap demoted are the ten this skips too — extraction
    // is not worth doing on mail the app already decided not to read.
    expect(queuedIds().length, firstRunTriageCap);
    expect(queuedIds(), isNot(contains('m000')));
    expect(queuedIds(), contains('m159'));
  });

  test('an empty mailbox queues nothing', () async {
    await sync.syncNow();

    expect(queuedIds(), isEmpty);
  });
}
