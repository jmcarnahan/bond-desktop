import 'dart:convert';

import 'package:bond_inbox/services/attachments/owa_links.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_mail_backend.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The two mail backends, held against each other on the one key neither of
/// them hands over in Graph's own shape.
///
/// Everything else in a message detail stays camelCase because the sync reads
/// Graph's names; `attachments` does not. The MCP server flattens Graph's
/// entries into a snake_case summary, the `attachments` columns are named
/// after that summary, and `GraphMail._attachmentSummaries` converts INTO it —
/// so the sync reads ONE shape whichever backend is answering. That claim is
/// only true while the two agree key for key, and nothing else in the suite
/// puts the same message through both paths to find out. This file does: the
/// same three raw Graph entries go in either side, and what comes out is
/// compared entry for entry.
///
/// The stubs are inlined rather than shared with the other backend tests, on
/// the same reasoning those files state: a shared fake is a file that can
/// break tests it is not in.

/// A token store that never touches the keychain.
class _InMemoryTokenStore implements TokenStore {
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

/// A scripted MCP client: one reply per tool, handed back whenever it is
/// called.
class _FakeMcp implements BondMcpClient {
  final Map<String, Map<String, dynamic>> scripted;

  _FakeMcp(this.scripted);

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      scripted[name] ?? <String, dynamic>{};

  @override
  Future<void> close() async {}
}

/// The three raw entries, exactly as Graph expands them onto a detail fetch:
/// a file with an inline `contentId`, a forwarded message, and a link.
///
/// Fictional, and deliberately one of each `@odata.type` the kind mapping
/// knows — a file, an item and a reference are the three answers that are not
/// `unknown`.
const List<Map<String, Object?>> _rawGraphEntries = [
  {
    '@odata.type': '#microsoft.graph.fileAttachment',
    'id': 'att-file-1',
    'name': 'quarterly-notes.pdf',
    'contentType': 'application/pdf',
    'size': 51200,
    'isInline': true,
    'contentId': 'inline-figure-1',
  },
  {
    '@odata.type': '#microsoft.graph.itemAttachment',
    'id': 'att-item-2',
    'name': 'Fwd: the schedule we agreed',
    'contentType': 'message/rfc822',
    'size': 8192,
    'isInline': false,
  },
  {
    '@odata.type': '#microsoft.graph.referenceAttachment',
    'id': 'att-ref-3',
    'name': 'Site plan',
    'contentType': null,
    'size': 0,
    'isInline': false,
    'sourceUrl': 'https://files.example.test/site-plan',
  },
];

/// What the MCP server's `attachment_summary` makes of those same three
/// entries. Hand-written, because the point of the comparison is that the two
/// sides are built independently and still land on the same dict.
const List<Map<String, Object?>> _serverSummaries = [
  {
    'id': 'att-file-1',
    'name': 'quarterly-notes.pdf',
    'content_type': 'application/pdf',
    'size': 51200,
    'is_inline': true,
    'content_id': 'inline-figure-1',
    'kind': 'file',
    'source_url': null,
  },
  {
    'id': 'att-item-2',
    'name': 'Fwd: the schedule we agreed',
    'content_type': 'message/rfc822',
    'size': 8192,
    'is_inline': false,
    'content_id': null,
    'kind': 'item',
    'source_url': null,
  },
  {
    'id': 'att-ref-3',
    'name': 'Site plan',
    'content_type': null,
    'size': 0,
    'is_inline': false,
    'content_id': null,
    'kind': 'reference',
    // The server selects `sourceUrl`; the SDK's expand cannot. See the test.
    'source_url': 'https://files.example.test/site-plan',
  },
];

void main() {
  /// [GraphMail.getMessageDetail]'s answer for a message carrying [entries].
  ///
  /// The token POST always succeeds and no granted scopes are stored, which is
  /// what keeps the re-consent check quiet — this file is about the reshape,
  /// not about auth.
  Future<List<Map<String, Object?>>> sdkAttachments(
    List<Map<String, Object?>> entries,
  ) async {
    final tokens = _InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt';

    final client = MockClient((request) async {
      if (request.url.host == 'login.microsoftonline.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'expires_in': 3600,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'id': 'msg-1',
          'uniqueBody': {'content': 'The plans and the note are attached.'},
          'internetMessageHeaders': <Object?>[],
          'hasAttachments': true,
          'attachments': entries,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    final mail = GraphMail(
      GraphAuth(httpClient: client, store: tokens),
      httpClient: client,
    );
    final detail = await mail.getMessageDetail('msg-1');
    return (detail['attachments'] as List).cast<Map<String, Object?>>();
  }

  /// [McpMailBackend.getMessageDetail]'s answer for the same message, with the
  /// server's own summaries on the wire.
  Future<List<Map<String, Object?>>> mcpAttachments(
    List<Map<String, Object?>> summaries,
  ) async {
    final mcp = _FakeMcp({
      'get_mail_detail': {
        'body_text': 'The plans and the note are attached.',
        'headers': <String, Object?>{},
        'has_attachments': true,
        'attachments': summaries,
      },
    });
    final detail = await McpMailBackend(mcp).getMessageDetail('msg-1');
    return (detail['attachments'] as List).cast<Map<String, Object?>>();
  }

  /// The body [GraphMail.getMessageDetail] answers with, for a message whose
  /// only attachment is one the connector never lists.
  Future<String?> sdkBody(String body) async {
    final tokens = _InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt';

    final client = MockClient((request) async {
      if (request.url.host == 'login.microsoftonline.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'expires_in': 3600,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'id': 'msg-1',
          'uniqueBody': {'content': body},
          'internetMessageHeaders': <Object?>[],
          'hasAttachments': false,
          'attachments': <Object?>[],
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    final mail = GraphMail(
      GraphAuth(httpClient: client, store: tokens),
      httpClient: client,
    );
    final detail = await mail.getMessageDetail('msg-1');
    return (detail['uniqueBody'] as Map)['content'] as String?;
  }

  /// The same, through the server.
  Future<String?> mcpBody(String body) async {
    final mcp = _FakeMcp({
      'get_mail_detail': {
        'body_text': body,
        'headers': <String, Object?>{},
        'has_attachments': false,
        'attachments': <Object?>[],
      },
    });
    final detail = await McpMailBackend(mcp).getMessageDetail('msg-1');
    return (detail['uniqueBody'] as Map)['content'] as String?;
  }

  /// An entry without the one key the two paths are allowed to disagree on.
  List<Map<String, Object?>> withoutSourceUrl(
    List<Map<String, Object?>> entries,
  ) =>
      [
        for (final entry in entries)
          {
            for (final key in entry.keys)
              if (key != 'source_url') key: entry[key],
          },
      ];

  test(
      'the SDK and MCP mail backends return the same attachment entries for '
      'the same message', () async {
    final sdk = await sdkAttachments(_rawGraphEntries);
    final mcp = await mcpAttachments(_serverSummaries);

    // Seven keys, three entries, one comparison. Equality is the whole claim:
    // the sync writes the `attachments` columns from whichever dict it is
    // handed, so a key one side renames, retypes or drops is a column that
    // quietly stops being written on that backend and nowhere else.
    expect(withoutSourceUrl(sdk), withoutSourceUrl(mcp));

    // The eighth key is where they legitimately part, and it is pinned rather
    // than papered over. `sourceUrl` is declared on the referenceAttachment
    // subtype and is not selectable through the detail expand, so the SDK path
    // has no url to give and the text policy refuses the entry as
    // `reference_no_url`. The server can select it. The day the expand can ask
    // for it, this expectation is what says the hole is closed.
    expect(sdk[2]['kind'], 'reference');
    expect(sdk[2]['source_url'], isNull, reason: 'the known expand hole');
    expect(mcp[2]['source_url'], 'https://files.example.test/site-plan');

    // The value rules the flattening is responsible for, stated once rather
    // than left implied by the equality above.
    for (final entry in [...sdk, ...mcp]) {
      expect(entry['is_inline'], isA<bool>(),
          reason: 'never Graph\'s absent-means-false null');
    }
    expect(sdk[0]['content_id'], 'inline-figure-1');
    expect(sdk[1]['content_id'], isNull, reason: 'no contentId on the entry');
    expect(sdk[0]['size'], 51200);
    expect(sdk[2]['size'], 0);
  });

  test('a Graph entry with no size at all reads as zero, the way the server '
      'answers it', () async {
    // Zero for unknown, never null: it is the `attachments.size` column's own
    // convention, and it is what the server answers for the same entry. Two
    // spellings of "no size" would be one more thing every reader had to know
    // about which backend it was talking to.
    final sdk = await sdkAttachments(const [
      {
        '@odata.type': '#microsoft.graph.fileAttachment',
        'id': 'att-file-4',
        'name': 'no-size.txt',
        'contentType': 'text/plain',
        'isInline': false,
      },
    ]);
    final mcp = await mcpAttachments(const [
      {
        'id': 'att-file-4',
        'name': 'no-size.txt',
        'content_type': 'text/plain',
        'size': 0,
        'is_inline': false,
        'content_id': null,
        'kind': 'file',
        'source_url': null,
      },
    ]);

    expect(sdk.single['size'], 0);
    expect(mcp.single['size'], 0);
    expect(withoutSourceUrl(sdk).single, withoutSourceUrl(mcp).single);
  });

  test('an @odata.type the mapping does not know is unknown, not file',
      () async {
    // The kinds are the one field the SDK path computes rather than copies,
    // and guessing `file` would send the text pass after bytes nothing knows
    // how to read.
    final sdk = await sdkAttachments(const [
      {
        '@odata.type': '#microsoft.graph.somethingElseAttachment',
        'id': 'att-5',
        'name': 'mystery',
        'contentType': null,
        'size': 1,
        'isInline': false,
      },
      {
        'id': 'att-6',
        'name': 'no type at all',
        'contentType': null,
        'size': 1,
        'isInline': false,
      },
    ]);

    expect(sdk.map((e) => e['kind']), ['unknown', 'unknown']);
  });

  test('a file attached as a link reads the same on both connectors', () async {
    // The one attachment neither backend can list. Outlook's "attach as link"
    // is a U+200B-delimited run in the BODY, and both connectors deliver plain
    // text bodies — so the parse belongs to the sync, once, and the only thing
    // parity can mean here is that the two hand the sync the same string.
    const zwsp = '\u200b';
    const linkUrl =
        'https://southbayequity2-my.sharepoint.com/:b:/g/personal/'
        'jane_southbayequity2_onmicrosoft_com/EaBcDeFgHiJkLmNoPqRsTuVwXyZ';
    const body = 'Please review.\n\n'
        '$zwsp[https://res-1.cdn.office.net/files/assets/pdf.svg]'
        'HARBORLIGHT TALENT AGREEMENT.pdf<$linkUrl>$zwsp\n\nThanks';

    final sdk = await sdkBody(body);
    final mcp = await mcpBody(body);

    expect(sdk, mcp);
    expect(sdk, body);

    // And the one parse over either string says the same thing. The sync-level
    // claim — that the row and the marker are actually written — is pinned in
    // `sync_attachments_test.dart`, which drives a real store.
    for (final delivered in [sdk, mcp]) {
      final parsed = extractOwaLinks(delivered);
      expect(parsed.rows.single['kind'], 'reference');
      expect(parsed.rows.single['source_url'], linkUrl);
      expect(parsed.body, contains('[[att:link-'));
      expect(parsed.body, isNot(contains(zwsp)));
    }
  });
}
