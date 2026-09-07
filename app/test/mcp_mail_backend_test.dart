import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_mail_backend.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The mail backend over MCP, with only the wire faked.
///
/// Most of this file is about SHAPE. The server speaks snake_case and flat
/// payloads while `sync_service.dart` reads Graph's nested ones, and every one
/// of those mismatches fails silently: a body that never lands, a header map
/// that comes out empty, a `webLink` the composer cannot find. So what is
/// pinned here is the exact dict each method hands back, and the exact args it
/// sends.

/// A scripted client. Duplicated per test file on purpose — a shared fake is a
/// file that can break tests it is not in.
class _FakeMcp implements BondMcpClient {
  /// Per tool: the replies to give, in order. A Map is returned, anything else
  /// is thrown. The last entry is sticky, so a tool called repeatedly with one
  /// scripted answer keeps giving it.
  final Map<String, List<Object>> scripted;

  final List<({String tool, Map<String, Object?> args})> calls = [];
  int closes = 0;

  _FakeMcp([this.scripted = const {}]);

  Map<String, Object?> argsFor(String tool) =>
      calls.firstWhere((c) => c.tool == tool).args;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add((tool: name, args: args));
    final queue = scripted[name];
    if (queue == null || queue.isEmpty) return <String, dynamic>{};
    final reply = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (reply is Map<String, dynamic>) return reply;
    throw reply;
  }

  @override
  Future<void> close() async => closes++;
}

/// The server's answer to `send_draft`: a flat dict, `to`/`cc` as
/// `[{name, address}]`, and a `sent_at` on the SERVER's clock at seconds
/// precision — the shape the Sent Items copy will be stamped in.
const Map<String, dynamic> _sendOk = {
  'ok': true,
  'id': 'draft-1',
  'conversation_id': 'conv-1',
  'internet_message_id': '<abc@bond.local>',
  'subject': 'Re: Contract review',
  'to': [
    {'name': 'Sarah', 'address': 'sarah@x.com'},
  ],
  'cc': [
    {'name': null, 'address': 'legal@x.com'},
  ],
  'sent_at': '2026-09-06T20:37:16Z',
};

Map<String, dynamic> _delta({
  List<Object> messages = const [],
  String next = '',
  String delta = '',
  bool resync = false,
}) =>
    {
      'messages': messages,
      'next_cursor': next,
      'delta_cursor': delta,
      'resync': resync,
    };

void main() {
  group('the delta drain', () {
    test('sends the empty string for "no cursor" and reads it back as null',
        () async {
      // Both directions matter, and for the same reason: SyncService drives
      // its drain loop and its cursor commit on null-versus-set. An empty
      // delta_cursor stored as a real cursor would ask the server to resume
      // from nothing on every sync after this one.
      final mcp = _FakeMcp({
        'list_mail_delta': [_delta(delta: 'd1')],
      });

      final page = await McpMailBackend(mcp).deltaPage('inbox');

      expect(mcp.argsFor('list_mail_delta'), {
        'folder': 'inbox',
        'cursor': '',
        'min_received': '',
      });
      expect(page.nextLink, isNull);
      expect(page.deltaLink, 'd1');
    });

    test('hands a cursor and a floor straight through', () async {
      final mcp = _FakeMcp({
        'list_mail_delta': [_delta(next: 'n2')],
      });

      final page = await McpMailBackend(mcp).deltaPage(
        'sentitems',
        link: 'opaque-cursor-1',
        minReceivedIso: '2026-08-16T00:00:00Z',
      );

      expect(mcp.argsFor('list_mail_delta'), {
        'folder': 'sentitems',
        'cursor': 'opaque-cursor-1',
        'min_received': '2026-08-16T00:00:00Z',
      });
      expect(page.nextLink, 'n2', reason: 'more pages to walk');
      expect(page.deltaLink, isNull);
    });

    test('a resync answer is the cursor being refused', () async {
      final mcp = _FakeMcp({
        'list_mail_delta': [_delta(resync: true, delta: 'ignored')],
      });

      expect(
        () => McpMailBackend(mcp).deltaPage('inbox'),
        throwsA(isA<DeltaResyncRequired>()),
      );
    });

    test('message dicts pass through untouched, tombstones included', () async {
      final tombstone = {
        'id': 'm-gone',
        '@removed': {'reason': 'deleted'},
      };
      final live = {'id': 'm1', 'subject': 'Homepage copy', 'isRead': false};
      final mcp = _FakeMcp({
        'list_mail_delta': [
          _delta(messages: [live, tombstone]),
        ],
      });

      final page = await McpMailBackend(mcp).deltaPage('inbox');

      // The fold in SyncService owns these — a backend that reshaped them
      // would be deciding what a deletion is.
      expect(page.messages, [live, tombstone]);
      expect(identical(page.messages.last, tombstone), isTrue);
    });

    test('an unconnected workspace is a sign-in problem, not a mail one',
        () async {
      final mcp = _FakeMcp({
        'list_mail_delta': [
          {'error': 'not_connected', 'connect_url': 'https://connect/me'},
        ],
      });

      expect(
        () => McpMailBackend(mcp).deltaPage('inbox'),
        throwsA(isA<ReconsentRequired>()),
      );
    });
  });

  group('the detail reshape', () {
    test('is exactly what SyncService reads', () async {
      final mcp = _FakeMcp({
        'get_mail_detail': [
          {
            'body_text': 'The homepage copy is in.',
            'headers': {
              'list-unsubscribe': '<mailto:x@y.z>',
              'precedence': 'bulk',
            },
            'has_attachments': true,
          },
        ],
      });

      final detail = await McpMailBackend(mcp).getMessageDetail('m1');

      expect(mcp.argsFor('get_mail_detail'), {'message_id': 'm1'});
      expect(detail, {
        'uniqueBody': {'content': 'The homepage copy is in.'},
        'internetMessageHeaders': [
          {'name': 'list-unsubscribe', 'value': '<mailto:x@y.z>'},
          {'name': 'precedence', 'value': 'bulk'},
        ],
        'hasAttachments': true,
        'attachments': <Map<String, Object?>>[],
      });
    });

    test('the attachment summaries ride through untouched', () async {
      // The server's flat summary IS the shape the `attachments` columns are
      // named after, so nothing here rebuilds it — a key this backend renamed
      // would be a key the sync silently dropped.
      final mcp = _FakeMcp({
        'get_mail_detail': [
          {
            'body_text': 'Signed copy attached.',
            'headers': <String, Object?>{},
            'has_attachments': true,
            'attachments': [
              {
                'id': 'att-1',
                'name': 'lease-addendum.pdf',
                'content_type': 'application/pdf',
                'size': 184320,
                'is_inline': false,
                'content_id': null,
                'kind': 'file',
                'source_url': null,
              },
            ],
          },
        ],
      });

      final detail = await McpMailBackend(mcp).getMessageDetail('m1');

      expect(detail['attachments'], [
        {
          'id': 'att-1',
          'name': 'lease-addendum.pdf',
          'content_type': 'application/pdf',
          'size': 184320,
          'is_inline': false,
          'content_id': null,
          'kind': 'file',
          'source_url': null,
        },
      ]);
    });

    test('a server that sends no attachments reads as none, not as null',
        () async {
      final mcp = _FakeMcp({
        'get_mail_detail': [
          {
            'body_text': 'No files here.',
            'headers': <String, Object?>{},
            'has_attachments': false,
          },
        ],
      });

      final detail = await McpMailBackend(mcp).getMessageDetail('m1');

      expect(detail['attachments'], isEmpty);
    });

    test('a null-valued header is dropped rather than emptied', () async {
      // A present-but-empty header is not the same claim as an absent one, and
      // the bulk-mail gates read exactly these keys.
      final mcp = _FakeMcp({
        'get_mail_detail': [
          {
            'body_text': null,
            'headers': {'precedence': null, 'x-mailer': 'Outlook'},
            'has_attachments': false,
          },
        ],
      });

      final detail = await McpMailBackend(mcp).getMessageDetail('m1');

      expect(detail['internetMessageHeaders'], [
        {'name': 'x-mailer', 'value': 'Outlook'},
      ]);
      expect((detail['uniqueBody'] as Map)['content'], isNull);
    });

    test('a payload with no headers at all still reads', () async {
      final mcp = _FakeMcp({
        'get_mail_detail': [
          {'body_text': 'hi', 'has_attachments': false},
        ],
      });

      final detail = await McpMailBackend(mcp).getMessageDetail('m1');

      expect(detail['internetMessageHeaders'], isEmpty);
    });

    test('and what SyncService stores from it round-trips', () async {
      // The reshape is only correct if the reader agrees, so the reader runs.
      final db = testDb();
      addTearDown(db.close);
      final store = MessageStore(db);
      await store.upsertMessage({
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'received_at': '2026-08-28T09:00:00Z',
      });
      final mcp = _FakeMcp({
        'get_mail_detail': [
          {
            'body_text': 'The homepage copy is in.',
            'headers': {'precedence': 'bulk'},
            'has_attachments': true,
          },
        ],
      });
      final sync = SyncService(McpMailBackend(mcp), store);

      await sync.ensureMessageBody('m1');

      final row = (await store.loadThread('c1', sources: const ['email'])).single;
      expect(row.bodyText, 'The homepage copy is in.');
      expect(row.sourceMetaJson, contains('precedence'),
          reason: 'the headers the bulk-mail gates read landed too');
    });
  });

  group('drafts', () {
    test('the reply draft comes back with the keys the composer reads',
        () async {
      final mcp = _FakeMcp({
        'create_reply_draft_json': [
          {
            'id': 'draft-1',
            'web_link': 'https://outlook/draft-1',
            'conversation_id': 'conv-1',
            'internet_message_id': '<abc@bond.local>',
          },
        ],
      });

      final draft = await McpMailBackend(mcp).createReplyDraft('m1');

      expect(draft['id'], 'draft-1');
      // webLink, not web_link: the hand-off to Outlook is the whole capability
      // ladder for an account that may save drafts but not send them.
      expect(draft['webLink'], 'https://outlook/draft-1');
      // Graph's own key names for the same reason. The callers read these, and
      // a snake_case key would simply be absent to them.
      expect(draft['conversationId'], 'conv-1');
      expect(draft['internetMessageId'], '<abc@bond.local>');

      final args = mcp.argsFor('create_reply_draft_json');
      expect(args['message_id'], 'm1');
      expect(args['timezone'], isA<String>());
      expect(args['timezone'], isNotEmpty,
          reason: 'the server renders the quoted thread in THIS machine’s zone');
    });

    test('filling in and sending name the draft', () async {
      final mcp = _FakeMcp({'send_draft': [_sendOk]});
      final mail = McpMailBackend(mcp);

      await mail.updateDraftBody('draft-1', 'Sounds good.');
      await mail.sendDraft('draft-1');

      expect(mcp.argsFor('update_draft_body'), {
        'draft_id': 'draft-1',
        'text': 'Sounds good.',
      });
      expect(mcp.argsFor('send_draft'), {'draft_id': 'draft-1'});
    });

    test('the send answers with what went out, recipients and all', () async {
      // These fields are the only record of the message until Sent Items
      // catches up: the draft they were read off no longer exists.
      final sent = await McpMailBackend(
        _FakeMcp({'send_draft': [_sendOk]}),
      ).sendDraft('draft-1');

      expect(sent.draftId, 'draft-1');
      expect(sent.conversationId, 'conv-1');
      expect(sent.internetMessageId, '<abc@bond.local>');
      expect(sent.subject, 'Re: Contract review');
      expect(sent.sentAt, '2026-09-06T20:37:16Z');
      expect([for (final r in sent.to) r.address], ['sarah@x.com']);
      expect(sent.to.single.name, 'Sarah');
      expect([for (final r in sent.cc) r.address], ['legal@x.com']);
      expect(sent.cc.single.name, isNull);
    });

    test('an entry naming nobody is dropped rather than stored', () async {
      final sent = await McpMailBackend(
        _FakeMcp({
          'send_draft': [
            {
              ...Map<String, dynamic>.from(_sendOk),
              'to': const [
                {'name': 'Nobody'},
                {'name': 'Sarah', 'address': 'sarah@x.com'},
                'not a map',
              ],
            },
          ],
        }),
      ).sendDraft('draft-1');

      expect([for (final r in sent.to) r.address], ['sarah@x.com']);
    });

    test('a send the server did not confirm is a failure, not an empty record',
        () async {
      // The caller writes a local row from this answer. A row built out of a
      // refusal would claim a message was sent that never left.
      await expectLater(
        McpMailBackend(
          _FakeMcp({
            'send_draft': [
              {'ok': false, 'error': 'mailbox_full'},
            ],
          }),
        ).sendDraft('draft-1'),
        throwsA(
          isA<GraphMailException>().having(
            (e) => e.message,
            'message',
            contains('mailbox_full'),
          ),
        ),
      );
    });

    test('and so is a result with no verdict in it at all', () async {
      await expectLater(
        McpMailBackend(_FakeMcp()).sendDraft('draft-1'),
        throwsA(isA<GraphMailException>()),
      );
    });
  });

  group('a new draft', () {
    test('sends each recipient line as one comma-separated string', () async {
      // The server's convention for every list-shaped argument it takes.
      final mcp = _FakeMcp({
        'create_draft_json': [
          {'id': 'draft-9'},
        ],
      });

      await McpMailBackend(mcp).createDraft(
        to: ['sarah@x.com', 'ravi@x.com'],
        cc: ['legal@x.com'],
        subject: 'Contract review',
        body: 'Friday works.',
      );

      expect(mcp.argsFor('create_draft_json'), {
        'to': 'sarah@x.com,ravi@x.com',
        'cc': 'legal@x.com',
        'subject': 'Contract review',
        'body': 'Friday works.',
      });
    });

    test('sends an empty Cc rather than leaving the argument out', () async {
      final mcp = _FakeMcp({
        'create_draft_json': [
          {'id': 'draft-9'},
        ],
      });

      await McpMailBackend(mcp)
          .createDraft(to: ['sarah@x.com'], subject: '', body: 'Hi.');

      expect(mcp.argsFor('create_draft_json')['cc'], '');
    });

    test('comes back with the same keys the reply draft does', () async {
      // The composer's capability ladder and the local echo row both read
      // these, and neither knows which of the two calls made the draft.
      final draft = await McpMailBackend(
        _FakeMcp({
          'create_draft_json': [
            {
              'id': 'draft-9',
              'web_link': 'https://outlook/draft-9',
              'conversation_id': 'conv-9',
              'internet_message_id': '<new@bond.local>',
            },
          ],
        }),
      ).createDraft(to: ['sarah@x.com'], subject: 'Hi', body: 'Hello.');

      expect(draft['id'], 'draft-9');
      expect(draft['webLink'], 'https://outlook/draft-9');
      expect(draft['conversationId'], 'conv-9');
      expect(draft['internetMessageId'], '<new@bond.local>');
    });

    test('a refusal is a failure, not a draft with a null id', () async {
      await expectLater(
        McpMailBackend(
          _FakeMcp({
            'create_draft_json': [
              {'error': 'invalid_recipients'},
            ],
          }),
        ).createDraft(to: ['nope'], subject: '', body: ''),
        throwsA(isA<GraphMailException>().having(
          (e) => e.message,
          'message',
          contains('invalid_recipients'),
        )),
      );
    });

    test('and so is a result with no id in it', () async {
      // The caller is about to fill in a body and send it. There is nothing
      // worse to hand it than a draft id that is null.
      await expectLater(
        McpMailBackend(_FakeMcp()).createDraft(
          to: ['sarah@x.com'],
          subject: '',
          body: '',
        ),
        throwsA(isA<GraphMailException>()),
      );
    });

    test('a disconnected server routes to sign-in instead', () async {
      await expectLater(
        McpMailBackend(
          _FakeMcp({
            'create_draft_json': [
              {'error': 'not_connected'},
            ],
          }),
        ).createDraft(to: ['sarah@x.com'], subject: '', body: ''),
        throwsA(isA<ReconsentRequired>()),
      );
    });
  });

  group('read acks', () {
    test('the ids travel as a JSON array and the flag as a word', () async {
      // Every argument this server takes is a string — the tools' own
      // convention, and the reason the list is encoded rather than passed.
      final mcp = _FakeMcp({
        'mark_mail_read_json': [
          {'updated': 2, 'failed': const []},
        ],
      });

      final failed = await McpMailBackend(mcp).markRead(['m1', 'm2']);

      expect(mcp.argsFor('mark_mail_read_json'), {
        'message_ids': '["m1","m2"]',
        'is_read': 'true',
      });
      expect(failed, isEmpty);
    });

    test('unread is the same call with the flag turned over', () async {
      final mcp = _FakeMcp({
        'mark_mail_read_json': [
          {'updated': 1, 'failed': const []},
        ],
      });

      await McpMailBackend(mcp).markRead(['m1'], isRead: false);

      expect(mcp.argsFor('mark_mail_read_json')['is_read'], 'false');
    });

    test('a failed id comes back to be retried', () async {
      final mcp = _FakeMcp({
        'mark_mail_read_json': [
          {
            'updated': 1,
            'failed': [
              {'id': 'm2', 'error': 'Graph API error 503 (ServiceUnavailable)'},
            ],
          },
        ],
      });

      expect(await McpMailBackend(mcp).markRead(['m1', 'm2']), ['m2']);
    });

    test('a message that has since been deleted does not', () async {
      // The same judgement SyncService makes about a vanished body, through
      // the same parse: there is no read flag left to set, so retrying forever
      // is the only thing calling this a failure would buy.
      final mcp = _FakeMcp({
        'mark_mail_read_json': [
          {
            'updated': 0,
            'failed': [
              {'id': 'm1', 'error': 'Graph API error 404 (ErrorItemNotFound)'},
              {'id': 'm2', 'error': 'Graph API error 410 (ErrorGone)'},
              {'id': 'm3', 'error': 'Graph API error 500 (InternalError)'},
            ],
          },
        ],
      });

      expect(await McpMailBackend(mcp).markRead(['m1', 'm2', 'm3']), ['m3']);
    });

    test('input the server could not read is not worth retrying', () async {
      // Its shape: a whole-call error with an empty `failed`. The same input
      // would come back the same way three times over.
      final mcp = _FakeMcp({
        'mark_mail_read_json': [
          {
            'updated': 0,
            'failed': const [],
            'error': 'message_ids must be a JSON array of strings',
          },
        ],
      });

      expect(await McpMailBackend(mcp).markRead(['m1']), isEmpty);
    });

    test('an unconnected workspace is a sign-in problem, not a mail one',
        () async {
      final mcp = _FakeMcp({
        'mark_mail_read_json': [
          {'error': 'not_connected', 'connect_url': 'https://connect'},
        ],
      });

      await expectLater(
        McpMailBackend(mcp).markRead(['m1']),
        throwsA(isA<ReconsentRequired>()),
      );
    });
  });

  group('failures', () {
    test('a Graph status inside a tool error is carried through', () async {
      final mcp = _FakeMcp({
        'get_mail_detail': [
          const McpToolException(
            'Graph API error 404 (ErrorItemNotFound): The specified object '
            'was not found in the store.',
          ),
        ],
      });

      await expectLater(
        McpMailBackend(mcp).getMessageDetail('m1'),
        throwsA(
          isA<GraphMailException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('ErrorItemNotFound')),
        ),
      );
    });

    test('a tool error that names no status carries none', () async {
      final mcp = _FakeMcp({
        'send_draft': [const McpToolException('the tool blew up')],
      });

      await expectLater(
        McpMailBackend(mcp).sendDraft('draft-1'),
        throwsA(isA<GraphMailException>()
            .having((e) => e.statusCode, 'statusCode', isNull)),
      );
    });

    test('a transport failure keeps the HTTP status it arrived with', () async {
      final mcp = _FakeMcp({
        'list_mail_delta': [
          const McpTransportException('gateway said no', statusCode: 502),
        ],
      });

      await expectLater(
        McpMailBackend(mcp).deltaPage('inbox'),
        throwsA(isA<GraphMailException>()
            .having((e) => e.statusCode, 'statusCode', 502)),
      );
    });

    test('a cold-start stall is transient, and nothing latches', () async {
      // The platform's database cold-starts for 10-30s after an idle spell, so
      // the first call of the day can time out. That must read as one failed
      // sync — a banner the next drain clears — and never as a session that has
      // gone bad: the very next call has to work with no reset in between.
      final backend = McpMailBackend(_FakeMcp({
        'list_mail_delta': [
          const McpTransportException('timed out'),
          _delta(delta: 'd1'),
        ],
      }));

      await expectLater(
        backend.deltaPage('inbox'),
        throwsA(isA<GraphMailException>()
            .having((e) => e.statusCode, 'statusCode', isNull)),
      );
      expect((await backend.deltaPage('inbox')).deltaLink, 'd1');
    });

    test('an auth failure passes through unwrapped', () async {
      // NotSignedIn is what routes the app to the sign-in screen. Wrapped in a
      // GraphMailException it would become a banner instead.
      final mcp = _FakeMcp({
        'list_mail_delta': [const NotSignedIn()],
      });

      await expectLater(
        McpMailBackend(mcp).deltaPage('inbox'),
        throwsA(isA<NotSignedIn>()),
      );
    });

    test('the client\'s own "requires a sign-in" reaches the caller intact',
        () async {
      // The one the MCP client raises when a bearer-less connection is refused
      // twice. It has to arrive as itself, message and all: it is the app's
      // only cue that this server is not the open one it was taken for.
      final mcp = _FakeMcp({
        'list_mail_delta': [const NotSignedIn('This server requires a sign-in.')],
      });

      await expectLater(
        McpMailBackend(mcp).deltaPage('inbox'),
        throwsA(isA<NotSignedIn>().having(
            (e) => e.message, 'message', 'This server requires a sign-in.')),
      );
    });

    test('a vanished message does not park the triage queue', () async {
      // The reason the status parse above is load bearing: SyncService skips a
      // 404 and rethrows everything else, so without it ONE deleted message
      // would stop every body fetch behind it.
      final db = testDb();
      addTearDown(db.close);
      final mcp = _FakeMcp({
        'get_mail_detail': [
          const McpToolException('Graph API error 404 (ErrorItemNotFound): x'),
        ],
      });
      final sync = SyncService(McpMailBackend(mcp), MessageStore(db));

      await expectLater(sync.ensureMessageBody('m-gone'), completes);
    });

    test('but a server that is failing outright still reaches the banner',
        () async {
      final db = testDb();
      addTearDown(db.close);
      final mcp = _FakeMcp({
        'get_mail_detail': [
          const McpToolException('Graph API error 503 (ServiceUnavailable): x'),
        ],
      });
      final sync = SyncService(McpMailBackend(mcp), MessageStore(db));

      await expectLater(
        sync.ensureMessageBody('m1'),
        throwsA(isA<GraphMailException>()),
      );
    });
  });
}
