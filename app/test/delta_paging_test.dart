import 'dart:convert';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

/// End-to-end drains: a scripted Graph on one side, a real sqlite database on
/// the other, and the real [GraphAuth], [GraphMail] and [SyncService] in
/// between. Only the socket is fake.

/// A [TokenStore] backed by a map. Duplicated from auth_refresh_test rather
/// than shared, so neither test file can break the other by editing it.
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

/// A delta URL the stub still routes by folder, so a scripted nextLink or
/// deltaLink behaves like the opaque one Graph returns.
String deltaUrl(String folder, String token) =>
    '$_graphBase/me/mailFolders/$folder/messages/delta?\$skiptoken=$token';

String deltaCursor(String folder, String token) =>
    '$_graphBase/me/mailFolders/$folder/messages/delta?\$deltatoken=$token';

http.Response jsonOk(Object body) => http.Response(
      body is String ? body : jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

/// One message as a delta page renders it — the tier-one fields only.
Map<String, dynamic> graphMessage({
  required String id,
  String? conversationId = 'conv-1',
  String subject = 'Closing Disclosure',
  String fromName = 'Sarah Whitfield',
  String fromAddress = 'sarah@harborline.com',
  List<String> to = const ['lo@bond.com'],
  String? receivedDateTime = '2026-08-28T10:00:00Z',
  bool isRead = false,
  bool isDraft = false,
  String preview = 'Preview text',
}) =>
    {
      'id': id,
      'internetMessageId': '<$id@harborline.com>',
      'conversationId': ?conversationId,
      'subject': subject,
      'from': {
        'emailAddress': {'name': fromName, 'address': fromAddress}
      },
      'toRecipients': [
        for (final address in to)
          {
            'emailAddress': {'name': null, 'address': address}
          },
      ],
      'receivedDateTime': receivedDateTime,
      'isRead': isRead,
      'isDraft': isDraft,
      'bodyPreview': preview,
    };

Map<String, dynamic> deltaBody(
  List<Map<String, dynamic>> messages, {
  String? nextLink,
  String? deltaLink,
}) =>
    {
      'value': messages,
      '@odata.nextLink': ?nextLink,
      '@odata.deltaLink': ?deltaLink,
    };

/// A scripted Graph. Delta responses are queued per folder and consumed in
/// order; anything unqueued answers as an empty, finished drain.
class GraphStub {
  final List<Uri> requests = [];
  final Map<String, List<http.Response Function()>> pages = {};
  final Map<String, http.Response Function()> details = {};
  int tokenPosts = 0;

  void queue(String folder, List<http.Response Function()> responses) {
    pages[folder] = [...responses];
  }

  List<Uri> requestsFor(String folder) => [
        for (final uri in requests)
          if (uri.path.contains('/mailFolders/$folder/')) uri,
      ];

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

        expect(request.headers['Authorization'], startsWith('Bearer '),
            reason: 'every Graph call carries the bearer token');
        requests.add(request.url);

        if (request.url.path.endsWith('/messages/delta')) {
          final folder =
              request.url.path.contains('sentitems') ? 'sentitems' : 'inbox';
          final queued = pages[folder];
          if (queued == null || queued.isEmpty) {
            return jsonOk(deltaBody(const [],
                deltaLink: deltaCursor(folder, 'empty')));
          }
          return queued.removeAt(0)();
        }

        if (request.url.path.contains('/me/messages/')) {
          final id = Uri.decodeComponent(request.url.pathSegments.last);
          expect(request.headers['Prefer'], 'outlook.body-content-type="text"',
              reason: 'Graph must convert HTML to text server-side');
          final responder = details[id];
          if (responder != null) return responder();
          return jsonOk({'id': id});
        }

        return http.Response('unexpected ${request.url}', 404);
      });
}

void main() {
  late Database db;
  late MessageStore store;
  late GraphStub graph;
  late SyncService sync;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
    graph = GraphStub();

    final tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;

    final auth = GraphAuth(httpClient: graph.client, store: tokens);
    sync = SyncService(GraphMail(auth, httpClient: graph.client), store);
  });

  tearDown(() => db.close());

  List<Map<String, Object?>> messageRows() => [
        for (final row
            in db.select('SELECT * FROM messages ORDER BY source_message_id'))
          Map<String, Object?>.from(row),
      ];

  Map<String, Object?> messageRow(String id) => Map<String, Object?>.from(
        db.select(
          'SELECT * FROM messages WHERE source_message_id = ?',
          [id],
        ).single,
      );

  group('paging', () {
    test('walks nextLinks and persists only the closing deltaLink', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [graphMessage(id: 'm1'), graphMessage(id: 'm2')],
              nextLink: deltaUrl('inbox', 'p2'),
            )),
        () => jsonOk(deltaBody(
              [graphMessage(id: 'm3')],
              nextLink: deltaUrl('inbox', 'p3'),
            )),
        () => jsonOk(deltaBody(
              [graphMessage(id: 'm4')],
              deltaLink: deltaCursor('inbox', 'final'),
            )),
      ]);

      await sync.syncNow();

      expect(
        messageRows().map((r) => r['source_message_id']).toList(),
        ['m1', 'm2', 'm3', 'm4'],
      );
      expect(store.getDeltaLink('inbox', source: 'email'),
          deltaCursor('inbox', 'final'));

      final inboxRequests = graph.requestsFor('inbox');
      expect(inboxRequests.length, 3);
      // A drain that starts from scratch asks for a floored window, and the
      // opaque links after it are fetched verbatim.
      expect(inboxRequests.first.queryParameters[r'$filter'],
          startsWith('receivedDateTime ge '));
      expect(inboxRequests[1].toString(), deltaUrl('inbox', 'p2'));
      expect(inboxRequests[2].toString(), deltaUrl('inbox', 'p3'));
    });

    test('the next sync resumes from the stored cursor with no floor',
        () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody([graphMessage(id: 'm1')],
            deltaLink: deltaCursor('inbox', 'c1'))),
      ]);
      await sync.syncNow();

      graph.requests.clear();
      graph.queue('inbox', [
        () => jsonOk(deltaBody([graphMessage(id: 'm2')],
            deltaLink: deltaCursor('inbox', 'c2'))),
      ]);
      await sync.syncNow();

      final second = graph.requestsFor('inbox').single;
      expect(second.toString(), deltaCursor('inbox', 'c1'));
      expect(second.queryParameters[r'$filter'], isNull,
          reason: 'the cursor already carries the window it was born with');
      expect(store.getDeltaLink('inbox', source: 'email'),
          deltaCursor('inbox', 'c2'));
      expect(messageRows().length, 2);
    });

    test('the delta \$select never asks for a body', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(const [],
            deltaLink: deltaCursor('inbox', 'c1'))),
      ]);
      await sync.syncNow();

      final select = graph.requestsFor('inbox').single.queryParameters[r'$select']!;
      expect(select.split(','), [
        'id',
        'internetMessageId',
        'conversationId',
        'subject',
        'from',
        'toRecipients',
        'receivedDateTime',
        'isRead',
        'isDraft',
        'bodyPreview',
      ]);
      // bodyPreview is a snippet; the body itself is tier two and never
      // rides along on a page that can carry hundreds of messages.
      expect(select, isNot(contains('uniqueBody')));
      expect(select, isNot(contains('body,')));
    });

    test('a message repeated across pages leaves one row', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [graphMessage(id: 'm1', preview: 'first delivery')],
              nextLink: deltaUrl('inbox', 'p2'),
            )),
        () => jsonOk(deltaBody(
              [graphMessage(id: 'm1', preview: 'second delivery', isRead: true)],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);

      await sync.syncNow();

      final rows = messageRows();
      expect(rows.length, 1);
      expect(rows.single['body_preview'], 'second delivery');
      expect(rows.single['is_read'], 1);
      expect(db.select('SELECT * FROM conversations').single['message_count'], 1);
    });

    test('a failure mid-drain keeps the committed pages and the old cursor',
        () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [graphMessage(id: 'm1'), graphMessage(id: 'm2')],
              nextLink: deltaUrl('inbox', 'p2'),
            )),
        () => throw http.ClientException('connection reset'),
      ]);

      await expectLater(sync.syncNow(), throwsA(isA<GraphMailException>()));

      // The whole point of committing rows before advancing the cursor: the
      // work already done survives, and the next drain replays from where
      // the cursor still points.
      expect(messageRows().map((r) => r['source_message_id']).toList(),
          ['m1', 'm2']);
      expect(store.getDeltaLink('inbox', source: 'email'), isNull);
    });

    test('drafts and removed tombstones never become rows', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [
                graphMessage(id: 'm1'),
                graphMessage(id: 'draft-1', isDraft: true),
                {'id': 'gone-1', '@removed': {'reason': 'deleted'}},
              ],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);

      await sync.syncNow();

      expect(messageRows().map((r) => r['source_message_id']).toList(), ['m1']);
    });
  });

  group('recovery', () {
    test('a 410 restarts the drain once, from a 24-hour floor', () async {
      graph.queue('inbox', [
        () => http.Response('{"error":{"code":"resyncRequired"}}', 410),
        () => jsonOk(deltaBody([graphMessage(id: 'm1')],
            deltaLink: deltaCursor('inbox', 'fresh'))),
      ]);

      await sync.syncNow();

      final inboxRequests = graph.requestsFor('inbox');
      expect(inboxRequests.length, 2);

      final filter = inboxRequests[1].queryParameters[r'$filter']!;
      final floor = DateTime.parse(
          filter.replaceFirst('receivedDateTime ge ', ''));
      final expected = DateTime.now().toUtc().subtract(const Duration(hours: 24));
      expect(
        floor.difference(expected).abs(),
        lessThan(const Duration(minutes: 5)),
        reason: 'the retry reaches back 24 hours, not the 14-day first-run '
            'floor: the mailbox behind it is already stored',
      );

      expect(messageRows().length, 1);
      expect(store.getDeltaLink('inbox', source: 'email'),
          deltaCursor('inbox', 'fresh'));
    });

    test('a second 410 in the same drain gives up', () async {
      graph.queue('inbox', [
        () => http.Response('resync', 410),
        () => http.Response('resync', 410),
      ]);

      await expectLater(
        sync.syncNow(),
        throwsA(isA<GraphMailException>()
            .having((e) => e.statusCode, 'statusCode', 410)),
      );
      expect(store.getDeltaLink('inbox', source: 'email'), isNull);
    });

    test('a 429 is retried once, honouring Retry-After', () async {
      graph.queue('inbox', [
        () => http.Response('throttled', 429, headers: {'retry-after': '0'}),
        () => jsonOk(deltaBody([graphMessage(id: 'm1')],
            deltaLink: deltaCursor('inbox', 'c1'))),
      ]);

      await sync.syncNow();

      expect(graph.requestsFor('inbox').length, 2);
      expect(messageRows().length, 1);
    });

    test('a second 429 fails the drain rather than looping', () async {
      graph.queue('inbox', [
        () => http.Response('throttled', 429, headers: {'retry-after': '0'}),
        () => http.Response('throttled', 429, headers: {'retry-after': '0'}),
      ]);

      await expectLater(
        sync.syncNow(),
        throwsA(isA<GraphMailException>()
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
      expect(graph.requestsFor('inbox').length, 2);
    });
  });

  group('direction and triage', () {
    test('sent mail lands outbound and never queues for triage', () async {
      graph.queue('sentitems', [
        () => jsonOk(deltaBody(
              [
                graphMessage(
                  id: 's1',
                  fromName: 'Bond LO',
                  fromAddress: 'lo@bond.com',
                  to: const ['sarah@harborline.com'],
                )
              ],
              deltaLink: deltaCursor('sentitems', 'c1'),
            )),
      ]);

      await sync.syncNow();

      final row = messageRow('s1');
      expect(row['direction'], 'outbound');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'outbound');
      expect(jsonDecode(row['to_json'] as String), ['sarah@harborline.com']);
    });

    test('mail older than the triage window arrives already skipped',
        () async {
      final fresh = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 1))
          .toIso8601String();
      final stale = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: triageWindowDays + 1))
          .toIso8601String();

      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [
                graphMessage(id: 'fresh', receivedDateTime: fresh),
                graphMessage(id: 'stale', receivedDateTime: stale),
              ],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);

      await sync.syncNow();

      expect(messageRow('fresh')['triage_status'], 'pending');
      expect(messageRow('fresh')['gate_reason'], isNull);
      expect(messageRow('stale')['triage_status'], 'skipped');
      expect(messageRow('stale')['gate_reason'], 'backlog');
    });

    test('a first run caps the triage queue, demoting the oldest', () async {
      // 160 messages, all inside the triage window, one minute apart.
      final base = DateTime.now().toUtc().subtract(const Duration(days: 1));
      final messages = [
        for (var i = 0; i < 160; i++)
          graphMessage(
            id: 'm${i.toString().padLeft(3, '0')}',
            conversationId: 'conv-$i',
            receivedDateTime:
                base.add(Duration(minutes: i)).toIso8601String(),
          ),
      ];
      graph.queue('inbox', [
        () => jsonOk(deltaBody(messages,
            deltaLink: deltaCursor('inbox', 'c1'))),
      ]);

      await sync.syncNow();

      expect(store.triageCounts(sources: const ['email']),
          {'pending': firstRunTriageCap, 'skipped': 160 - firstRunTriageCap});

      // The ten demoted are the ten oldest, not an arbitrary ten.
      final demoted = db
          .select("SELECT source_message_id FROM messages "
              "WHERE triage_status = 'skipped' ORDER BY source_message_id")
          .map((r) => r['source_message_id'] as String)
          .toList();
      expect(demoted, [for (var i = 0; i < 10; i++) 'm${i.toString().padLeft(3, '0')}']);
      expect(
        db.select("SELECT DISTINCT gate_reason FROM messages "
            "WHERE triage_status = 'skipped'").single['gate_reason'],
        'backlog',
      );
    });

    test('the cap runs only on a first run', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody([graphMessage(id: 'm1')],
            deltaLink: deltaCursor('inbox', 'c1'))),
      ]);
      await sync.syncNow();
      expect(messageRow('m1')['triage_status'], 'pending');

      // A later sync must not demote what the first one queued.
      graph.queue('inbox', [
        () => jsonOk(deltaBody([graphMessage(id: 'm2')],
            deltaLink: deltaCursor('inbox', 'c2'))),
      ]);
      await sync.syncNow();

      expect(messageRow('m1')['triage_status'], 'pending');
      expect(messageRow('m2')['triage_status'], 'pending');
    });
  });

  group('conversation folding', () {
    test('an inbound, a reply, then newer inbound leaves the thread open',
        () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [
                graphMessage(
                  id: 'in-1',
                  subject: 'Closing Disclosure',
                  receivedDateTime: '2026-08-27T09:00:00Z',
                  preview: 'the first ask',
                ),
                graphMessage(
                  id: 'in-2',
                  subject: 'Re: Closing Disclosure',
                  receivedDateTime: '2026-08-28T15:00:00Z',
                  preview: 'the newest word',
                ),
              ],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);
      graph.queue('sentitems', [
        () => jsonOk(deltaBody(
              [
                graphMessage(
                  id: 'out-1',
                  subject: 'Re: Closing Disclosure',
                  fromName: 'Bond LO',
                  fromAddress: 'lo@bond.com',
                  to: const ['sarah@harborline.com'],
                  receivedDateTime: '2026-08-28T09:00:00Z',
                  preview: 'my reply',
                )
              ],
              deltaLink: deltaCursor('sentitems', 'c1'),
            )),
      ]);

      await sync.syncNow();

      final conversation = store.loadConversations(sources: const ['email']).single;
      expect(conversation.id, 'conv-1');
      expect(conversation.state, ConversationState.needsReply);
      expect(conversation.messageCount, 3);
      expect(conversation.inboundCount, 2);
      expect(conversation.lastMessagePreview, 'the newest word');
      expect(conversation.lastMessageAt, '2026-08-28T15:00:00Z');
      expect(conversation.lastInboundAt, '2026-08-28T15:00:00Z');
      expect(conversation.lastOutboundAt, '2026-08-28T09:00:00Z');
      // Named by how it opened, with the reply marker stripped.
      expect(conversation.subject, 'Closing Disclosure');
      expect(
        conversation.participants.map((p) => p.email).toList(),
        ['sarah@harborline.com'],
      );
    });

    test('a reply after the newest inbound closes the ask', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [graphMessage(id: 'in-1', receivedDateTime: '2026-08-27T09:00:00Z')],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);
      graph.queue('sentitems', [
        () => jsonOk(deltaBody(
              [
                graphMessage(
                  id: 'out-1',
                  fromAddress: 'lo@bond.com',
                  receivedDateTime: '2026-08-27T11:00:00Z',
                )
              ],
              deltaLink: deltaCursor('sentitems', 'c1'),
            )),
      ]);

      await sync.syncNow();

      expect(
        store.loadConversations(sources: const ['email']).single.state,
        ConversationState.waiting,
      );
    });

    test('a sync does not undo a done a human set', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [graphMessage(id: 'in-1', receivedDateTime: '2026-08-27T09:00:00Z')],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);
      await sync.syncNow();
      store.setConversationState('email', 'conv-1', ConversationState.done);

      // The same message again, replayed by a resync.
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [graphMessage(id: 'in-1', receivedDateTime: '2026-08-27T09:00:00Z')],
              deltaLink: deltaCursor('inbox', 'c2'),
            )),
      ]);
      await sync.syncNow();

      expect(
        store.loadConversations(sources: const ['email']).single.state,
        ConversationState.done,
      );
    });

    test('a message with no conversationId becomes its own thread', () async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [graphMessage(id: 'loner', conversationId: null)],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);

      await sync.syncNow();

      expect(
        store.loadConversations(sources: const ['email']).single.id,
        'msg:loner',
      );
    });
  });

  group('ensureBodies', () {
    setUp(() async {
      graph.queue('inbox', [
        () => jsonOk(deltaBody(
              [
                graphMessage(id: 'm1', receivedDateTime: '2026-08-27T09:00:00Z'),
                graphMessage(id: 'm2', receivedDateTime: '2026-08-28T09:00:00Z'),
              ],
              deltaLink: deltaCursor('inbox', 'c1'),
            )),
      ]);
      await sync.syncNow();
      graph.requests.clear();
    });

    test('fetches the plain-text unique body and lowercased headers',
        () async {
      graph.details['m1'] = () => jsonOk({
            'id': 'm1',
            'uniqueBody': {
              'contentType': 'text',
              'content': 'Just my part of the thread.',
            },
            'internetMessageHeaders': [
              {'name': 'List-Unsubscribe', 'value': '<mailto:x@y.com>'},
              {'name': 'AUTO-SUBMITTED', 'value': 'auto-generated'},
            ],
            'hasAttachments': true,
          });
      graph.details['m2'] = () => jsonOk({
            'id': 'm2',
            'uniqueBody': {'content': 'Second body.'},
            'hasAttachments': false,
          });

      await sync.ensureBodies('conv-1');

      final m1 = messageRow('m1');
      expect(m1['body_text'], 'Just my part of the thread.');
      expect(m1['has_attachments'], 1);
      final meta = jsonDecode(m1['source_meta_json'] as String);
      expect(meta['headers'], {
        'list-unsubscribe': '<mailto:x@y.com>',
        'auto-submitted': 'auto-generated',
      });
      expect(messageRow('m2')['body_text'], 'Second body.');

      // Newest first — the message the reader lands on fills in first.
      expect(
        graph.requests.map((u) => Uri.decodeComponent(u.pathSegments.last)).toList(),
        ['m2', 'm1'],
      );
    });

    test('a second open costs no network at all', () async {
      graph.details['m1'] = () => jsonOk({
            'id': 'm1',
            'uniqueBody': {'content': 'Body one.'}
          });
      graph.details['m2'] = () => jsonOk({
            'id': 'm2',
            'uniqueBody': {'content': 'Body two.'}
          });

      await sync.ensureBodies('conv-1');
      expect(graph.requests.length, 2);

      graph.requests.clear();
      await sync.ensureBodies('conv-1');
      expect(graph.requests, isEmpty);
    });

    test('a message deleted since the delta page does not sink the thread',
        () async {
      graph.details['m2'] = () => http.Response('{"error":"gone"}', 404);
      graph.details['m1'] = () => jsonOk({
            'id': 'm1',
            'uniqueBody': {'content': 'Still here.'}
          });

      await sync.ensureBodies('conv-1');

      expect(messageRow('m1')['body_text'], 'Still here.');
      expect(messageRow('m2')['body_text'], isNull);
    });

    test('a real failure surfaces', () async {
      graph.details['m2'] = () => http.Response('boom', 500);

      await expectLater(
        sync.ensureBodies('conv-1'),
        throwsA(isA<GraphMailException>()),
      );
    });

    test('a thin detail payload cannot blank a stored body', () async {
      graph.details['m1'] = () => jsonOk({
            'id': 'm1',
            'uniqueBody': {'content': 'The body.'}
          });
      graph.details['m2'] = () => jsonOk({
            'id': 'm2',
            'uniqueBody': {'content': 'Other body.'}
          });
      await sync.ensureBodies('conv-1');

      store.updateMessageDetail('email', 'm1', bodyText: null);
      expect(messageRow('m1')['body_text'], 'The body.');
    });
  });
}
