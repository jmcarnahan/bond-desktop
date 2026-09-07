import 'dart:convert';

import 'package:bond_inbox/services/attachments/attachment_bytes.dart'
    show attachmentTooLargeBytes;
import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show maxAttachmentBytes;
import 'package:bond_inbox/services/backend/attachment_backend.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_attachment_backend.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_attachment_backend.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/attachment_refs.dart';

/// The two ways this app gets at a file, and the one rule they share.
///
/// **A refusal is an answer and a failure is transport.** Everything below is
/// that sentence checked from one side or the other: a server word the file
/// will never come back for becomes a `skipped`, and a socket that dropped
/// becomes the exception the worker already retries on. Conflating them costs a
/// document permanently or spends three requests reaching the same no.
///
/// The second subject is the URLs. Two of the Graph routes here fail in ways
/// that read as something else — a sharing url sent unencoded is a 400 that
/// names no parameter, a hosted-content id sent to the mail endpoint is a 404
/// that reads as a deleted file — so the routes are pinned as strings.

/// A scripted MCP client. Duplicated per test file on purpose, the way every
/// other backend test duplicates it: a shared fake is a file that can break
/// tests it is not in.
class _FakeMcp implements BondMcpClient {
  final Map<String, List<Object>> scripted;
  final List<({String tool, Map<String, Object?> args})> calls = [];

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
  Future<void> close() async {}
}

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

/// Every Graph request the backend made, and what to answer it with.
class _GraphStub {
  final List<Uri> urls = [];

  /// The headers each request carried, indexed alongside [urls]. The text path
  /// caps what it FETCHES rather than what it stores, and the only proof of
  /// that is the `Range` header on the wire.
  final List<Map<String, String>> requestHeaders = [];

  /// Answers in order; the last one is sticky, so a retry test scripts two and
  /// a plain test scripts one.
  final List<http.Response Function()> replies = [];

  MockClient get client => MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/v2.0/token')) {
          return http.Response(
            jsonEncode({
              'access_token': 'at-1',
              'refresh_token': 'rt-2',
              'expires_in': 3600,
              'scope': _grantedScopes,
              'token_type': 'Bearer',
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        urls.add(request.url);
        requestHeaders.add(Map.of(request.headers));
        if (replies.isEmpty) return http.Response('', 200);
        final reply = replies.length == 1 ? replies.first : replies.removeAt(0);
        return reply();
      });
}

void main() {
  group('what each connector will hand over', () {
    test('the server stops at its JSON reply and the SDK at the app\'s own '
        'judgement', () {
      // Not one constant: the server refuses above ten megabytes because the
      // payload rides back base64 inside a single reply, while Graph streams
      // and is limited only by what this app thinks a document is.
      expect(McpAttachmentBackend(_FakeMcp()).maxPreviewBytes, 10 * 1024 * 1024);

      final tokens = _Tokens();
      tokens.values['refresh_token'] = 'rt-initial';
      final sdk = GraphAttachmentBackend(
        GraphAuth(httpClient: _GraphStub().client, store: tokens),
        httpClient: _GraphStub().client,
      );
      expect(sdk.maxPreviewBytes, maxAttachmentBytes);
      expect(sdk.maxPreviewBytes, greaterThan(attachmentTooLargeBytes));
    });
  });

  group('the MCP backend reading words', () {
    test('turns every permanent server word into a skip that keeps the word',
        () async {
      // The vocabulary is what a chip renders, so an unrecognised word must not
      // reach it — a stranger's error string on screen is worse than "the file
      // is unavailable".
      const words = [
        'too_large',
        'access_denied',
        'not_found',
        'invalid_link',
        'is_folder',
        'external_sender',
      ];
      for (final word in words) {
        final mcp = _FakeMcp({
          'get_mail_attachment_json': [
            <String, dynamic>{'error': word},
          ],
        });
        final result = await McpAttachmentBackend(mcp).extractText(ref());
        expect(result.status, 'skipped');
        expect(result.reason, word);
      }

      final unknown = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{'error': 'the_server_invented_this'},
        ],
      });
      final result = await McpAttachmentBackend(unknown).extractText(ref());
      expect(result.reason, 'unavailable');
    });

    test('an empty text is a skip that names the reason the server gave',
        () async {
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{'text': '', 'reason': 'no_extractor'},
        ],
      });

      final result = await McpAttachmentBackend(mcp).extractText(ref());

      expect(result.status, 'skipped');
      expect(result.reason, 'no_extractor');
    });

    test('words come back with what they cost and whether they were cut',
        () async {
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{
            'text': 'The quote is attached.',
            'truncated': true,
            'size': 4096,
          },
        ],
      });

      final result = await McpAttachmentBackend(mcp).extractText(ref());

      expect(result.status, 'ok');
      expect(result.text, 'The quote is attached.');
      expect(result.truncated, isTrue);
      expect(result.fetchedBytes, 4096);
      expect(mcp.argsFor('get_mail_attachment_json'), {
        'message_id': 'm1',
        'attachment_id': 'a1',
        'mode': 'text',
      });
    });

    test('a chat image is never sent for text', () async {
      final mcp = _FakeMcp();

      final result = await McpAttachmentBackend(mcp).extractText(
        imageRef(source: 'teams'),
      );

      expect(result.reason, 'binary');
      expect(mcp.calls, isEmpty, reason: 'a picture has no words to ask for');
    });

    test('a link with no url is refused without a call', () async {
      final mcp = _FakeMcp();

      final result = await McpAttachmentBackend(mcp)
          .extractText(ref(kind: 'reference', sourceUrl: null));

      // The word `attachment_policy.dart` uses, not a second spelling of it:
      // the panel prints whichever token was stored, so one condition with two
      // words is one fact wearing two chips.
      expect(result.reason, 'reference_no_url');
      expect(mcp.calls, isEmpty);
    });

    test('the MCP text result carries the attached message\'s subject, sender '
        'and date', () async {
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{
            'text': 'Please see the terms below.',
            'size': 27,
            'item_subject': 'Re: Studio lease',
            'item_from': 'dana.whitfield@example.test',
            'item_received': '2026-08-14T09:12:00Z',
          },
        ],
      });

      final result =
          await McpAttachmentBackend(mcp).extractText(ref(kind: 'item'));

      expect(result.status, 'ok');
      expect(result.itemSubject, 'Re: Studio lease');
      expect(result.itemFrom, 'dana.whitfield@example.test');
      expect(result.itemReceived, '2026-08-14T09:12:00Z');
    });

    test('a skipped item still names the message it wrapped', () async {
      // A forwarded mail the extractor got nowhere with is still a forwarded
      // mail, and the preview draws its header either way.
      final empty = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{
            'text': '',
            'reason': 'empty',
            'item_subject': 'Re: Studio lease',
            'item_from': 'dana.whitfield@example.test',
            'item_received': '2026-08-14T09:12:00Z',
          },
        ],
      });

      final skipped =
          await McpAttachmentBackend(empty).extractText(ref(kind: 'item'));

      expect(skipped.status, 'skipped');
      expect(skipped.itemSubject, 'Re: Studio lease');
      expect(skipped.itemFrom, 'dana.whitfield@example.test');
      expect(skipped.itemReceived, '2026-08-14T09:12:00Z');

      final failed = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{
            'error': 'access_denied',
            'item_subject': 'Re: Studio lease',
            'item_from': 'dana.whitfield@example.test',
            'item_received': '2026-08-14T09:12:00Z',
          },
        ],
      });

      final refused =
          await McpAttachmentBackend(failed).extractText(ref(kind: 'item'));

      expect(refused.reason, 'access_denied');
      expect(refused.itemSubject, 'Re: Studio lease');
      expect(refused.itemFrom, 'dana.whitfield@example.test');
    });

    test('a chat file is read from its sharing url, not from the message',
        () async {
      final mcp = _FakeMcp({
        'inspect_file_json': [
          <String, dynamic>{'text': 'Rates for October.', 'size': 12},
        ],
      });

      final result = await McpAttachmentBackend(mcp).extractText(
        ref(
          source: 'teams',
          kind: 'file',
          sourceUrl: 'https://example.invalid/sites/deals/Rates.xlsx',
        ),
      );

      expect(result.status, 'ok');
      expect(mcp.argsFor('inspect_file_json'), {
        'url': 'https://example.invalid/sites/deals/Rates.xlsx',
        'read_content': 'true',
      });
    });
  });

  group('the MCP backend fetching bytes', () {
    test('decodes what the server sent and keeps the name it gave it',
        () async {
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{
            'content_base64': base64Encode(const [1, 2, 3, 4]),
            'content_type': 'application/pdf',
            'name': 'Quote-88.pdf',
          },
        ],
      });

      final result = await McpAttachmentBackend(mcp).fetchBytes(ref());

      expect(result.bytes, [1, 2, 3, 4]);
      expect(result.contentType, 'application/pdf');
      expect(result.name, 'Quote-88.pdf');
      expect(mcp.argsFor('get_mail_attachment_json')['mode'], 'bytes');
    });

    test('a thumbnail word reaches the chat tool verbatim', () async {
      final mcp = _FakeMcp({
        'get_chat_attachment_json': [
          <String, dynamic>{'content_base64': base64Encode(const [9])},
        ],
      });

      await McpAttachmentBackend(mcp).fetchBytes(
        ref(source: 'teams', kind: 'file', conversationKey: 'chat-7'),
        thumbnail: 'small',
      );

      expect(mcp.argsFor('get_chat_attachment_json'), {
        'chat_id': 'chat-7',
        'message_id': 'm1',
        'attachment_id': 'a1',
        'thumbnail': 'small',
      });
    });

    test('a chat attachment with no chat behind it is refused, not sent',
        () async {
      final mcp = _FakeMcp();

      await expectLater(
        McpAttachmentBackend(mcp)
            .fetchBytes(ref(source: 'teams', kind: 'file')),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'no_chat'),
        ),
      );
      expect(mcp.calls, isEmpty);
    });

    test('a kind that is a pointer rather than a payload is refused with no '
        'call', () async {
      final mcp = _FakeMcp();

      await expectLater(
        McpAttachmentBackend(mcp).fetchBytes(ref(kind: 'reference')),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'kind_reference'),
        ),
      );
      expect(mcp.calls, isEmpty);
    });

    test('an unknown server word on the bytes path becomes unavailable',
        () async {
      // The reason a failed fetch carries is recorded as the text skip it
      // amounts to and ends up on a chip, so the bytes path closes the
      // vocabulary exactly as the text path does.
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{'error': 'the_server_invented_this'},
        ],
      });

      await expectLater(
        McpAttachmentBackend(mcp).fetchBytes(ref()),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'unavailable'),
        ),
      );
    });

    test('a known one is kept', () async {
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{'error': 'too_large'},
        ],
      });

      await expectLater(
        McpAttachmentBackend(mcp).fetchBytes(ref()),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'too_large'),
        ),
      );
    });

    test('an answer with no bytes in it is a refusal', () async {
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [<String, dynamic>{'content_base64': ''}],
      });

      await expectLater(
        McpAttachmentBackend(mcp).fetchBytes(ref()),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'empty'),
        ),
      );
    });
  });

  group('the MCP backend failing', () {
    test('a mail failure is the mail exception and a chat failure the chat one',
        () async {
      final mail = _FakeMcp({
        'get_mail_attachment_json': [
          const McpToolException('Graph API error 500 (Internal): oh dear'),
        ],
      });
      await expectLater(
        McpAttachmentBackend(mail).extractText(ref()),
        throwsA(
          isA<GraphMailException>()
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );

      final chat = _FakeMcp({
        'get_chat_attachment_json': [
          const McpToolException('Graph API error 503 (Busy): later'),
        ],
      });
      await expectLater(
        McpAttachmentBackend(chat).fetchBytes(
          ref(source: 'teams', kind: 'image', conversationKey: 'chat-7'),
        ),
        throwsA(
          isA<GraphTeamsException>()
              .having((e) => e.statusCode, 'statusCode', 503),
        ),
      );
    });

    test('not_connected is the one failure a person can fix', () async {
      final mcp = _FakeMcp({
        'get_mail_attachment_json': [
          <String, dynamic>{'error': 'not_connected'},
        ],
      });

      await expectLater(
        McpAttachmentBackend(mcp).extractText(ref()),
        throwsA(isA<ReconsentRequired>()),
      );
    });
  });

  group('the Graph backend reading words', () {
    late _GraphStub graph;

    GraphAttachmentBackend build() {
      final tokens = _Tokens();
      tokens.values['refresh_token'] = 'rt-initial';
      tokens.values['granted_scopes'] = _grantedScopes;
      return GraphAttachmentBackend(
        GraphAuth(httpClient: graph.client, store: tokens),
        httpClient: graph.client,
      );
    }

    setUp(() => graph = _GraphStub());

    test('decodes a text-like type', () async {
      graph.replies.add(() => http.Response('one,two\n3,4', 200,
          headers: const {'content-type': 'text/csv'}));

      final result = await build().extractText(
        ref(name: 'Rates.csv', contentType: 'text/csv', size: 11),
      );

      expect(result.status, 'ok');
      expect(result.text, 'one,two\n3,4');
    });

    test('an octet-stream with a text name is still text', () async {
      graph.replies.add(() => http.Response('a log line', 200));

      final result = await build().extractText(
        ref(
          name: 'server.log',
          contentType: 'application/octet-stream',
          size: 10,
        ),
      );

      expect(result.status, 'ok');
    });

    test('a Word file is a skip and never a fetch', () async {
      // The defining property of this backend: it has no extractor and says so
      // rather than downloading twenty megabytes to find out.
      final result = await build().extractText(
        ref(
          name: 'Terms.docx',
          contentType: 'application/vnd.openxmlformats-officedocument'
              '.wordprocessingml.document',
        ),
      );

      expect(result.reason, 'no_extractor');
      expect(graph.urls, isEmpty);
    });

    test('a text file past the download cap is refused before the request',
        () async {
      final result = await build().extractText(
        ref(name: 'huge.log', contentType: 'text/plain', size: 8 * 1024 * 1024),
      );

      expect(result.reason, 'too_large');
      expect(graph.urls, isEmpty);
    });

    test('a file that is gone reads as a skip rather than a failure', () async {
      graph.replies.add(() => http.Response('{}', 404));

      final result = await build().extractText(
        ref(name: 'notes.txt', contentType: 'text/plain', size: 5),
      );

      expect(result.reason, 'gone');
    });

    test('a text file whose size is unknown is cut at the download cap and '
        'marked truncated', () async {
      // The claimed size is 0 for every Teams file and for plenty of mail
      // attachments, so the cheap first gate lets this through and the
      // DOWNLOAD is what has to stop.
      const cap = 2 * 1024 * 1024;
      graph.replies.add(() => http.Response('x' * (3 * 1024 * 1024), 200));

      final result = await build().extractText(
        ref(name: 'server.log', contentType: 'text/plain', size: 0),
      );

      expect(result.status, 'ok');
      expect(result.truncated, isTrue);
      expect(result.text!.length, lessThanOrEqualTo(cap));
      expect(
        graph.requestHeaders.single['Range'],
        'bytes=0-${cap - 1}',
        reason: 'the cap has to be on the wire, not only on what is stored',
      );
    });

    test('a server that honours the range answers 206 and the cut is still '
        'recorded', () async {
      const cap = 2 * 1024 * 1024;
      graph.replies.add(() => http.Response(
            'y' * cap,
            206,
            headers: const {
              'content-type': 'text/plain',
              'content-range': 'bytes 0-2097151/5000000',
            },
          ));

      final result = await build().extractText(
        ref(name: 'server.log', contentType: 'text/plain', size: 0),
      );

      expect(result.status, 'ok');
      // A body sitting exactly at the cap says nothing about itself; the
      // header is the only thing that knows the file went on.
      expect(result.truncated, isTrue);
    });

    test('a text file under the cap is stored whole and unmarked', () async {
      graph.replies.add(() => http.Response('one,two\n3,4', 200,
          headers: const {'content-type': 'text/csv'}));

      final result = await build().extractText(
        ref(name: 'Rates.csv', contentType: 'text/csv', size: 0),
      );

      expect(result.text, 'one,two\n3,4');
      expect(result.truncated, isFalse);
    });

    test('the SDK path expands an attached message and reads its fields',
        () async {
      graph.replies.add(() => http.Response(
            jsonEncode({
              'id': 'a1',
              'item': {
                'subject': 'Re: Studio lease',
                'from': {
                  'emailAddress': {
                    'name': 'Dana Whitfield',
                    'address': 'dana.whitfield@example.test',
                  },
                },
                'receivedDateTime': '2026-08-14T09:12:00Z',
                'bodyPreview': 'Please see the terms below.',
                'body': {
                  'contentType': 'text',
                  'content': 'Please see the terms below. Signed, Dana.',
                },
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          ));

      final result = await build().extractText(
        ref(kind: 'item', name: 'Forwarded.eml', contentType: 'message/rfc822'),
      );

      // A bare `item` in the expand is a Graph 400 that names no property, so
      // the cast form is pinned rather than trusted.
      final query = Uri.decodeComponent(graph.urls.single.query);
      expect(query, contains('microsoft.graph.itemattachment/item'));
      expect(query, contains('\$select='));

      expect(result.status, 'ok');
      expect(result.text, 'Please see the terms below. Signed, Dana.');
      expect(result.truncated, isFalse, reason: 'this is the body, not a cut');
      expect(result.itemSubject, 'Re: Studio lease');
      expect(result.itemFrom, 'dana.whitfield@example.test');
      expect(result.itemReceived, '2026-08-14T09:12:00Z');
    });

    test('an attached message with an empty body still keeps its fields',
        () async {
      graph.replies.add(() => http.Response(
            jsonEncode({
              'item': {
                'subject': 'Re: Studio lease',
                'from': {
                  'emailAddress': {'address': 'dana.whitfield@example.test'},
                },
                'receivedDateTime': '2026-08-14T09:12:00Z',
                'bodyPreview': '',
                'body': {'contentType': 'html', 'content': ''},
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          ));

      final result = await build().extractText(
        ref(kind: 'item', name: 'Forwarded.eml', contentType: 'message/rfc822'),
      );

      expect(result.status, 'skipped');
      expect(result.reason, 'empty');
      expect(result.itemSubject, 'Re: Studio lease');
      expect(result.itemFrom, 'dana.whitfield@example.test');
      expect(result.itemReceived, '2026-08-14T09:12:00Z');
    });
  });

  group('the Graph backend fetching bytes', () {
    late _GraphStub graph;

    GraphAttachmentBackend build() {
      final tokens = _Tokens();
      tokens.values['refresh_token'] = 'rt-initial';
      tokens.values['granted_scopes'] = _grantedScopes;
      return GraphAttachmentBackend(
        GraphAuth(httpClient: graph.client, store: tokens),
        httpClient: graph.client,
      );
    }

    setUp(() => graph = _GraphStub());

    test('a mail attachment is fetched from the message that carried it',
        () async {
      graph.replies.add(() => http.Response('pdf', 200,
          headers: const {'content-type': 'application/pdf'}));

      final result = await build().fetchBytes(ref());

      expect(
        graph.urls.single.path,
        '/v1.0/me/messages/m1/attachments/a1/\$value',
      );
      expect(result.contentType, 'application/pdf');
    });

    test('the hosted-content route names the chat, the message and the content '
        'id', () async {
      graph.replies.add(() => http.Response('png', 200));

      await build().fetchBytes(
        ref(
          source: 'teams',
          kind: 'image',
          attachmentId: 'hc-9',
          contentType: 'image/png',
          name: 'Screenshot.png',
          conversationKey: '19:chat@thread.v2',
        ),
      );

      expect(
        Uri.decodeComponent(graph.urls.single.path),
        '/v1.0/chats/19:chat@thread.v2/messages/m1/hostedContents/hc-9/\$value',
      );
    });

    test('a sharing url travels as the u! token, unpadded', () async {
      // A plain percent-encoding of the url here is a Graph 400 that names no
      // parameter, so the encoding is pinned rather than trusted.
      const url = 'https://example.invalid/sites/deals/Rates.xlsx';
      final token = GraphAttachmentBackend.shareToken(url);

      expect(token, startsWith('u!'));
      expect(token, isNot(contains('=')));
      expect(
        utf8.decode(base64Url.decode(base64Url.normalize(token.substring(2)))),
        url,
      );

      graph.replies.add(() => http.Response('xlsx', 200));
      await build().fetchBytes(
        ref(source: 'teams', kind: 'file', sourceUrl: url),
      );

      expect(graph.urls.single.path, '/v1.0/shares/$token/driveItem/content');
    });

    test('a size word asks the drive for its own rendering', () async {
      graph.replies.add(() => http.Response('png', 200));

      await build().fetchBytes(
        ref(
          source: 'teams',
          kind: 'file',
          sourceUrl: 'https://example.invalid/x.pdf',
        ),
        thumbnail: 'small',
      );

      expect(graph.urls.single.path, endsWith('/thumbnails/0/small/content'));
    });

    test('404 is gone and 403 is access denied', () async {
      graph.replies.add(() => http.Response('', 404));
      await expectLater(
        build().fetchBytes(ref()),
        throwsA(
          isA<AttachmentUnavailable>().having((e) => e.reason, 'reason', 'gone'),
        ),
      );

      graph = _GraphStub();
      graph.replies.add(() => http.Response('', 403));
      await expectLater(
        build().fetchBytes(ref()),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'access_denied'),
        ),
      );
    });

    test('one 401 is retried and a second one is an error', () async {
      graph.replies
        ..add(() => http.Response('', 401))
        ..add(() => http.Response('ok', 200));

      final first = await build().fetchBytes(ref());
      expect(first.bytes, utf8.encode('ok'));
      expect(graph.urls.length, 2, reason: 'the first 401 bought one more try');

      graph = _GraphStub();
      graph.replies.add(() => http.Response('no', 401));
      await expectLater(
        build().fetchBytes(ref()),
        throwsA(
          isA<GraphMailException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('a chat attachment fails to the chat banner', () async {
      graph.replies.add(() => http.Response('', 500));

      await expectLater(
        build().fetchBytes(
          ref(
            source: 'teams',
            kind: 'image',
            contentType: 'image/png',
            conversationKey: 'chat-1',
          ),
        ),
        throwsA(isA<GraphTeamsException>()),
      );
    });
  });
}

