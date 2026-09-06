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

/// What a mail sync does about attachments, end to end: a scripted Graph on
/// one side and a real sqlite database on the other.
///
/// Two facts are being pinned. The PAPERCLIP rides the delta page, so a list
/// card can show it before any body is fetched. The ROWS ride the detail
/// fetch, because that is the first moment a list of attachments exists — and
/// the enqueue rides with them, so an attachment that arrives is queued for
/// reading exactly once.

/// A [TokenStore] backed by a map, duplicated per-file the way the sibling
/// sync suites duplicate it: neither file can break the other by editing it.
class _MapTokenStore implements TokenStore {
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

http.Response _jsonOk(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

/// Yesterday, so a message is always inside the triage window however long
/// this file sits in the repository.
final String _fresh =
    DateTime.now().toUtc().subtract(const Duration(days: 1)).toIso8601String();

Map<String, dynamic> _deltaMessage({
  required String id,
  bool hasAttachments = false,
}) =>
    {
      'id': id,
      'internetMessageId': '<$id@example.com>',
      'conversationId': 'conv-1',
      'subject': 'Lease addendum',
      'from': {
        'emailAddress': {'name': 'Dana Kessler', 'address': 'dana@example.com'},
      },
      'toRecipients': [
        {
          'emailAddress': {'name': null, 'address': 'owner@example.com'},
        },
      ],
      'receivedDateTime': _fresh,
      'isRead': false,
      'isDraft': false,
      'bodyPreview': 'Signed copy attached.',
      'hasAttachments': hasAttachments,
    };

/// One entry as Graph's `$expand=attachments` renders it — camelCase, with the
/// subtype in `@odata.type`.
Map<String, dynamic> _graphAttachment({
  required String id,
  String name = 'lease-addendum.pdf',
  String contentType = 'application/pdf',
  int size = 184320,
  bool isInline = false,
  String odataType = '#microsoft.graph.fileAttachment',
}) =>
    {
      '@odata.type': odataType,
      'id': id,
      'name': name,
      'contentType': contentType,
      'size': size,
      'isInline': isInline,
      'contentId': isInline ? 'cid-$id' : null,
    };

/// A scripted Graph that answers one delta page and whatever details are
/// registered against it.
class _GraphStub {
  final List<Uri> requests = [];
  final Map<String, List<Map<String, dynamic>>> attachments = {};
  int detailCalls = 0;
  List<Map<String, dynamic>> deltaMessages = const [];

  MockClient get client => MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          return _jsonOk({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'expires_in': 3600,
            'scope': _grantedScopes,
            'token_type': 'Bearer',
          });
        }
        requests.add(request.url);

        if (request.url.path.endsWith('/messages/delta')) {
          final inbox = !request.url.path.contains('sentitems');
          return _jsonOk({
            'value': inbox ? deltaMessages : const [],
            '@odata.deltaLink':
                '$_graphBase/me/mailFolders/x/messages/delta?\$deltatoken=c1',
          });
        }

        if (request.url.path.contains('/me/messages/')) {
          detailCalls++;
          final id = Uri.decodeComponent(request.url.pathSegments.last);
          return _jsonOk({
            'id': id,
            'uniqueBody': {'content': 'Signed copy attached.'},
            'internetMessageHeaders': const [],
            'hasAttachments': attachments.containsKey(id),
            'attachments': attachments[id] ?? const [],
          });
        }

        return http.Response('unexpected ${request.url}', 404);
      });

  Uri get detailRequest =>
      requests.firstWhere((u) => u.path.contains('/me/messages/'));
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _GraphStub graph;
  late SyncService sync;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    graph = _GraphStub();

    final tokens = _MapTokenStore();
    tokens.values['refresh_token'] = 'rt-initial';
    tokens.values['granted_scopes'] = _grantedScopes;

    final auth = GraphAuth(httpClient: graph.client, store: tokens);
    sync = SyncService(GraphMail(auth, httpClient: graph.client), store);
  });

  tearDown(() => db.close());

  Future<List<Map<String, Object?>>> workItems() async => [
        for (final row in await db
            .customSelect(
              "SELECT * FROM work_items WHERE task_kind = 'attachment_text' "
              'ORDER BY entity_id',
            )
            .get())
          Map<String, Object?>.from(row.data),
      ];

  group('the delta page', () {
    test('carries the paperclip before the detail runs', () async {
      graph.deltaMessages = [
        _deltaMessage(id: 'm1', hasAttachments: true),
        _deltaMessage(id: 'm2'),
      ];

      await sync.syncNow();

      expect((await store.getMessageRow('email', 'm1'))!['has_attachments'], 1);
      expect((await store.getMessageRow('email', 'm2'))!['has_attachments'], 0);
      // Nothing has been fetched: the flag is a delta field.
      expect(graph.detailCalls, 0);
      expect(await store.attachmentsForMessage('email', 'm1'), isEmpty);
    });
  });

  group('the detail fetch', () {
    test('asks Graph for the attachment list in the cast form', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      await sync.syncNow();

      await sync.ensureMessageBody('m1');

      final expand = graph.detailRequest.queryParameters[r'$expand']!;
      // A bare `contentId` here is a Graph 400 — the property lives on the
      // fileAttachment subtype.
      expect(expand, contains('microsoft.graph.fileAttachment/contentId'));
      expect(expand, isNot(contains(',contentId')));
    });

    test('writes the attachment rows the message carries', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [
        _graphAttachment(id: 'att-1'),
        _graphAttachment(
          id: 'att-2',
          name: 'floor-plan.png',
          contentType: 'image/png',
          size: 512000,
        ),
      ];
      await sync.syncNow();

      await sync.ensureMessageBody('m1');

      final rows = await store.attachmentsForMessage('email', 'm1');
      expect(rows.map((r) => r['attachment_id']), ['att-1', 'att-2']);
      expect(rows.first['name'], 'lease-addendum.pdf');
      expect(rows.first['content_type'], 'application/pdf');
      expect(rows.first['size'], 184320);
      expect(rows.first['kind'], 'file');
      expect(rows.first['ordinal'], 0);
      expect(rows.last['ordinal'], 1);
    });

    test('and queues text work for exactly the eligible ones', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [
        _graphAttachment(id: 'att-doc'),
        // Inline, and under the small-image floor twice over.
        _graphAttachment(
          id: 'att-logo',
          name: 'logo.png',
          contentType: 'image/png',
          size: 4096,
          isInline: true,
        ),
        // A link with no url: the known hole, refused rather than fetched.
        _graphAttachment(
          id: 'att-link',
          name: 'quote.docx',
          odataType: '#microsoft.graph.referenceAttachment',
        ),
      ];
      await sync.syncNow();

      await sync.ensureMessageBody('m1');

      expect(
        (await workItems()).map((r) => r['entity_id']),
        ['m1|att-doc'],
      );
    });

    test('a detail with no attachments queues nothing', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1')];
      await sync.syncNow();

      await sync.ensureMessageBody('m1');

      expect(await store.attachmentsForMessage('email', 'm1'), isEmpty);
      expect(await workItems(), isEmpty);
    });

    test('the digest is not queued here — the text handler owns that',
        () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [_graphAttachment(id: 'att-1')];
      await sync.syncNow();

      await sync.ensureMessageBody('m1');

      final digests = await db
          .customSelect(
            "SELECT * FROM work_items WHERE task_kind = 'attachment_digest'",
          )
          .get();
      expect(digests, isEmpty);
    });

    test('the same detail fetched twice queues one item, not two', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [_graphAttachment(id: 'att-1')];
      await sync.syncNow();

      await sync.ensureMessageBody('m1');
      await sync.ensureMessageBody('m1');

      expect((await workItems()).length, 1);
      expect((await store.attachmentsForMessage('email', 'm1')).length, 1);
    });

    test('a gated message\'s attachments are stored and never queued',
        () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [_graphAttachment(id: 'att-1')];
      await sync.syncNow();
      await db.customUpdate(
        "UPDATE messages SET triage_status = 'skipped', "
        "gate_reason = 'bulk_sender' WHERE source_message_id = 'm1'",
      );

      await sync.ensureMessageBody('m1');

      // The rows exist — the user can still see what came with it — but no
      // model or network time is spent on a message the gates dropped.
      expect((await store.attachmentsForMessage('email', 'm1')).length, 1);
      expect(await workItems(), isEmpty);
    });
  });
}
