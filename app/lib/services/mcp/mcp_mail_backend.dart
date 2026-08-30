import '../backend/backend_types.dart';
import '../backend/mail_backend.dart';
import '../graph_mail.dart';
import 'bond_mcp_client.dart';

/// The mail reads and draft writes, made by asking the Bond MCP server rather
/// than Microsoft. Nothing here touches sqlite — [SyncService] owns the writes.
///
/// The server speaks snake_case and flat payloads; this app's readers —
/// `sync_service.dart` and `draft_provider.dart` — read Graph's own nested
/// shapes. Every method therefore RESHAPES, and the reshape is the contract:
/// the two backends must be indistinguishable to their callers, or a switch
/// between them silently changes what gets stored.
///
/// Failures are reported as [GraphMailException] for the same reason: the
/// callers already route on it, and one of them routes on its status code.
/// Auth failures — [NotSignedIn], [ReconsentRequired], [AuthException] — pass
/// through UNWRAPPED, exactly as they do from `graph_mail.dart`.

/// The HTTP status inside a tool's failure text, when it names one.
///
/// The server reports a refused Graph call as `Graph API error 404
/// (ErrorItemNotFound): …`, and that status is LOAD BEARING: `SyncService` skips
/// a message that vanished between the delta page and the body fetch only when
/// it sees 404 or 410. Without this parse one deleted message would park the
/// triage queue behind a permanent failure.
///
/// Deliberately a private copy of the one in `mcp_teams_backend.dart`, the way
/// `graph_mail.dart` and `graph_teams.dart` each keep their own `_describe`:
/// the two backends travel to different banners and must not be able to break
/// each other.
final RegExp _graphStatus = RegExp(r'Graph API error\s+(\d{3})');

int? _statusFromToolError(String message) {
  final match = _graphStatus.firstMatch(message);
  return match == null ? null : int.tryParse(match.group(1)!);
}

class McpMailBackend implements MailBackend {
  final BondMcpClient _mcp;

  McpMailBackend(this._mcp);

  /// One page of the delta drain for [folder] ('inbox', 'sentitems').
  ///
  /// [link] is the server's opaque cursor and is sent back VERBATIM. The empty
  /// string is how the wire says "no cursor" in both directions, and the
  /// conversion at the boundary is not cosmetic: `SyncService` drives its drain
  /// loop and its cursor commit on null-versus-set, so an empty `delta_cursor`
  /// arriving as `''` would be stored as a real cursor and every later drain
  /// would ask the server to resume from nothing.
  ///
  /// The raw message dicts pass straight through, `@removed` tombstones and
  /// all: the fold in `SyncService` owns them.
  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) async {
    final result = await _call('list_mail_delta', {
      'folder': folder,
      'cursor': link ?? '',
      'min_received': minReceivedIso ?? '',
    });

    // The server's stand-in for Graph's HTTP 410: the cursor is older than the
    // change history and only a fresh drain can recover.
    if (result['resync'] == true) throw const DeltaResyncRequired();

    final messages = result['messages'];
    return DeltaPage(
      messages: [
        for (final item in messages is List ? messages : const [])
          if (item is Map<String, dynamic>)
            item
          else if (item is Map)
            Map<String, dynamic>.from(item),
      ],
      nextLink: _emptyToNull(result['next_cursor']),
      deltaLink: _emptyToNull(result['delta_cursor']),
    );
  }

  /// The full body and headers for one message, in the shape
  /// `SyncService._fetchDetailInto` reads.
  ///
  /// A header whose value is null is DROPPED rather than sent through as an
  /// empty string: the reader lowercases names into a map and a present-but-
  /// empty header is not the same claim as an absent one.
  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) async {
    final result = await _call('get_mail_detail', {'message_id': id});
    final headers = result['headers'];
    return {
      'uniqueBody': {'content': result['body_text']},
      'internetMessageHeaders': [
        if (headers is Map)
          for (final entry in headers.entries)
            if (entry.value != null)
              {'name': entry.key, 'value': entry.value},
      ],
      'hasAttachments': result['has_attachments'],
    };
  }

  /// Creates a draft reply to [messageId].
  ///
  /// The server builds the reply — recipients, subject, threading headers and
  /// the quoted thread all come from the message being replied to. `webLink` is
  /// renamed from the wire's `web_link` because the composer's hand-off to
  /// Outlook reads that key, and it is the whole capability ladder for an
  /// account that may save drafts but not send them.
  ///
  /// The time zone rides along as an argument rather than a `Prefer` header:
  /// the server owns the Graph call, and the zone it should render the quoted
  /// timestamps in is this machine's, not the server's.
  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async {
    final result = await _call('create_reply_draft_json', {
      'message_id': messageId,
      'timezone': DateTime.now().timeZoneName,
    });
    return {'id': result['id'], 'webLink': result['web_link']};
  }

  @override
  Future<void> updateDraftBody(String draftId, String text) async {
    await _call('update_draft_body', {'draft_id': draftId, 'text': text});
  }

  @override
  Future<void> sendDraft(String draftId) async {
    await _call('send_draft', {'draft_id': draftId});
  }

  /// One tool call, with this file's whole error policy in it.
  ///
  /// `not_connected` arrives as a NORMAL result rather than an error, and it
  /// means the one thing an interactive step can fix — so it becomes
  /// [ReconsentRequired], which is what routes the app to sign-in.
  ///
  /// Only the two MCP types are caught. An [AuthException] raised while the
  /// client fetches its bearer is not a mail failure and must reach the caller
  /// as itself.
  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, Object?> args,
  ) async {
    final Map<String, dynamic> result;
    try {
      result = await _mcp.callTool(tool, args);
    } on McpToolException catch (e) {
      throw GraphMailException(e.message, _statusFromToolError(e.message));
    } on McpTransportException catch (e) {
      throw GraphMailException(e.message, e.statusCode);
    }
    if (result['error'] == 'not_connected') throw const ReconsentRequired();
    return result;
  }

  static String? _emptyToNull(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;
}
