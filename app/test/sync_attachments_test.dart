import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/restore_service.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:drift/drift.dart' show Variable;
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
  String bodyPreview = 'Signed copy attached.',
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
      'bodyPreview': bodyPreview,
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

  /// The detail body per message id, for the messages that need a particular
  /// one — an Outlook "attach as link" IS its body, and there is nowhere else
  /// for the fact to live.
  final Map<String, String> bodies = {};
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
            'uniqueBody': {'content': bodies[id] ?? 'Signed copy attached.'},
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

  group('a local echo', () {
    test('is never asked of Graph', () async {
      // The id was minted by the app; the server has no such message, and
      // every body fetch in the app comes through this one method.
      await sync.ensureMessageBody('local:draft-1');

      expect(graph.detailCalls, 0);
      expect(graph.requests, isEmpty);
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

    test('a gated message\'s attachments record why they were not queued',
        () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [_graphAttachment(id: 'att-1')];
      await sync.syncNow();
      await db.customUpdate(
        "UPDATE messages SET triage_status = 'skipped', "
        "gate_reason = 'bulk_sender' WHERE source_message_id = 'm1'",
      );

      await sync.ensureMessageBody('m1');

      // Left `pending`, the panel would say "still reading this file" about a
      // document nothing will ever come back to read.
      final rows = await store.attachmentsForMessage('email', 'm1');
      expect(rows.single['text_status'], 'skipped');
      expect(rows.single['text_reason'], 'gated');
      expect(rows.single['digest_status'], 'skipped');
      expect(await workItems(), isEmpty);
    });

    test('a second sighting never downgrades a file already read', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [_graphAttachment(id: 'att-1')];
      await sync.syncNow();
      await sync.ensureMessageBody('m1');

      // As if the text handler had run and read it.
      await db.customUpdate(
        "UPDATE attachments SET text_status = 'done', text_reason = NULL, "
        "digest_status = 'done' WHERE attachment_id = 'att-1'",
      );
      await db.customUpdate(
        "UPDATE messages SET triage_status = 'skipped', "
        "gate_reason = 'bulk_sender' WHERE source_message_id = 'm1'",
      );

      await sync.ensureMessageBody('m1');

      final rows = await store.attachmentsForMessage('email', 'm1');
      expect(rows.single['text_status'], 'done');
      expect(rows.single['text_reason'], isNull);
      expect(rows.single['digest_status'], 'done');
    });
  });

  group('a file attached as a link', () {
    // Outlook's "attach as link" is not a Graph attachment: the message says
    // `hasAttachments: false`, lists nothing, and carries the file as a
    // U+200B-delimited run in the body. The detail fetch is the only place
    // that fact exists, so it is the only place it can be read.
    const zwsp = '\u200b';
    const icon = 'https://res-1.cdn.office.net/files/assets/pdf.svg';
    const linkUrl =
        'https://southbayequity2-my.sharepoint.com/:b:/g/personal/'
        'jane_southbayequity2_onmicrosoft_com/EaBcDeFgHiJkLmNoPqRsTuVwXyZ';
    const run = '$zwsp[$icon]HARBORLIGHT TALENT AGREEMENT.pdf<$linkUrl>$zwsp';
    const linkBody = 'Please review.\n\n$run\n\nThanks';

    test('a link in the body becomes a reference row, a marker and the '
        'paperclip', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1')];
      graph.bodies['m1'] = linkBody;
      await sync.syncNow();

      await sync.ensureMessageBody('m1');

      final row = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(row['kind'], 'reference');
      expect(row['name'], 'HARBORLIGHT TALENT AGREEMENT.pdf');
      expect(row['source_url'], linkUrl);
      expect(row['ordinal'], 0);

      // The connector counted no attachments; the body says otherwise, and the
      // card's paperclip follows the body.
      final message = (await store.getMessageRow('email', 'm1'))!;
      expect(message['has_attachments'], 1);
      final body = message['body_text'] as String;
      expect(body, contains('[[att:link-'));
      expect(body, isNot(contains(zwsp)));
      expect(body, contains('[[att:${row['attachment_id']}]]'));

      expect(
        (await workItems()).map((r) => r['entity_id']),
        ['m1|${row['attachment_id']}'],
      );
    });

    test('fetched twice, one row and one work item', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1')];
      graph.bodies['m1'] = linkBody;
      await sync.syncNow();

      await sync.ensureMessageBody('m1');
      await sync.ensureMessageBody('m1');

      // The id is derived from the url, so a second fetch upserts the same row
      // and the INSERT OR IGNORE queues the same item.
      expect((await store.attachmentsForMessage('email', 'm1')).length, 1);
      expect((await workItems()).length, 1);
    });

    test('a gated message stores the link and records the refusal', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1')];
      graph.bodies['m1'] = linkBody;
      await sync.syncNow();
      await db.customUpdate(
        "UPDATE messages SET triage_status = 'skipped', "
        "gate_reason = 'bulk_sender' WHERE source_message_id = 'm1'",
      );

      await sync.ensureMessageBody('m1');

      final row = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(row['text_status'], 'skipped');
      expect(row['text_reason'], 'gated');
      expect(await workItems(), isEmpty);
    });

    test('the preview loses its zero-width spaces', () async {
      graph.deltaMessages = [
        _deltaMessage(
          id: 'm1',
          bodyPreview: '${zwsp}HARBORLIGHT TALENT AGREEMENT.pdf$zwsp',
        ),
      ];

      await sync.syncNow();

      // Graph previews a link-attachment message as the file name in zero-width
      // spaces. Search and cards must never carry a character nobody can see.
      expect(
        (await store.getMessageRow('email', 'm1'))!['body_preview'],
        'HARBORLIGHT TALENT AGREEMENT.pdf',
      );
    });

    test('a link beside a real attachment is numbered after it', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1', hasAttachments: true)];
      graph.attachments['m1'] = [_graphAttachment(id: 'att-1')];
      graph.bodies['m1'] = linkBody;
      await sync.syncNow();

      await sync.ensureMessageBody('m1');

      final rows = await store.attachmentsForMessage('email', 'm1');
      expect(rows.map((r) => r['ordinal']), [0, 1]);
      expect(rows.first['attachment_id'], 'att-1');
      expect(rows.last['kind'], 'reference');
    });

    test('Restore is the backfill for a message synced before the parse '
        'existed', () async {
      graph.deltaMessages = [_deltaMessage(id: 'm1')];
      graph.bodies['m1'] = linkBody;
      await sync.syncNow();
      // What an older build left behind: the raw run in the body, no row, no
      // paperclip. Nothing re-reads a stored body on its own — the parse runs
      // on a detail fetch, and Restore's tier-two fetch is the one a person
      // can trigger.
      await db.customUpdate(
        "UPDATE messages SET body_text = ?, has_attachments = 0, "
        "triage_status = 'skipped', gate_reason = 'bulk_sender' "
        "WHERE source_message_id = 'm1'",
        variables: [Variable(linkBody)],
      );
      expect(await store.attachmentsForMessage('email', 'm1'), isEmpty);

      await RestoreService(store, ensureBody: sync.ensureMessageBody)
          .restore('email', 'm1');

      final row = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(row['kind'], 'reference');
      expect(row['text_status'], 'pending');
      final message = (await store.getMessageRow('email', 'm1'))!;
      expect(message['has_attachments'], 1);
      expect(message['body_text'], contains('[[att:${row['attachment_id']}]]'));
      expect(
        (await workItems()).map((r) => r['status']),
        ['pending'],
      );
    });
  });
}
