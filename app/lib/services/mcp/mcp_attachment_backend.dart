import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;

import '../../models/attachment_models.dart';
import '../backend/attachment_backend.dart';
import '../backend/backend_types.dart';
import '../graph_mail.dart';
import '../graph_teams.dart';
import 'bond_mcp_client.dart';

/// Attachment words and bytes, fetched by asking the Bond MCP server.
///
/// This is the implementation that can actually READ a document. The server
/// carries the extractors — docx, pptx, xlsx, pdf — so a Word file comes back
/// as text here and as `no_extractor` from the SDK backend. Everything else the
/// two do identically, which is the point of the seam.
///
/// Three tools, and which one gets called is decided entirely by the pair
/// `(source, kind)`:
///
/// | ref | tool |
/// |---|---|
/// | mail `file`/`item`/`unknown` | `get_mail_attachment`, `mode: text`/`bytes` |
/// | mail `reference`, teams `file` text | `inspect_file`, by url, `mode: text` |
/// | mail `reference` bytes/thumbnail | `inspect_file`, by url, `mode: bytes`/`thumbnail` |
/// | teams `file`/`image` bytes/thumbnail | `get_teams_attachment`, `mode: bytes`/`thumbnail` |
///
/// Failures follow `mcp_mail_backend.dart`'s policy exactly, including which
/// banner they travel to: a mail attachment's transport failure is a
/// [GraphMailException] because the callers above route mail failures on it,
/// and a chat attachment's is a [GraphTeamsException] for the same reason. The
/// two must not be able to break each other, which is why the status parse
/// below is a private copy rather than a shared helper.

/// The HTTP status inside a tool's failure text, when it names one. See
/// `mcp_mail_backend.dart` for why every backend keeps its own copy.
final RegExp _graphStatus = RegExp(r'Graph API error\s+(\d{3})');

int? _statusFromToolError(String message) {
  final match = _graphStatus.firstMatch(message);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// The words the server uses for "this file is not coming, and asking again
/// will not help".
///
/// Anything outside this set that still arrived as an `error` is recorded as
/// `unavailable` rather than passed through: the reason is shown on a chip, and
/// an unrecognised server word would put a stranger's vocabulary on screen.
const Set<String> _permanentServerReasons = {
  'too_large',
  'reference',
  'access_denied',
  'not_found',
  'invalid_link',
  'is_folder',
  'external_sender',
  'missing_target',
  'no_thumbnail',
  'invalid_mode',
  'invalid_thumbnail',
  'invalid_options',
  'invalid_arguments',
  'teams_unavailable',
};

class McpAttachmentBackend implements AttachmentBackend {
  final BondMcpClient _mcp;

  McpAttachmentBackend(this._mcp);

  /// The server's own bytes-mode ceiling: `get_mail_attachment` and
  /// `get_teams_attachment` both refuse above ten megabytes, because the
  /// payload comes back base64 inside one JSON reply and there is nowhere to
  /// put a larger one. A chunked bytes mode on bond-mcps would raise this,
  /// and is the only thing that would.
  @override
  int get maxPreviewBytes => 10 * 1024 * 1024;

  @override
  Future<AttachmentText> extractText(AttachmentRef ref) async {
    // An image has no words, a card is a rendering of a message already in the
    // store, and a message_reference is a quote of one. None of the three is
    // worth a round trip to establish that.
    if (ref.source != 'email' &&
        const {'image', 'card', 'message_reference', 'other'}
            .contains(ref.kind)) {
      return const AttachmentText.skipped('binary');
    }

    // A url-shaped attachment — a mail reference, a Teams shared file — is
    // fetched from OneDrive by its sharing link rather than from the message.
    if (ref.kind == 'reference' || (ref.source != 'email' && ref.kind == 'file')) {
      final url = ref.contentUrl;
      if (url == null || url.isEmpty) {
        // The word `attachment_policy.dart` uses for the same condition. The
        // panel prints whatever was stored, so a second spelling would put two
        // chips on one fact.
        return const AttachmentText.skipped('reference_no_url');
      }
      // `mode` and not `read_content`: an explicit mode wins over that older
      // flag on the server, and the bytes and thumbnail branch of [fetchBytes]
      // already speaks `mode:` — one tool, one argument style.
      final result = await _call(ref, 'inspect_file', {
        'url': url,
        'mode': 'text',
      });
      // The inspector is the only text call that describes the FILE: a row
      // reached by url was born knowing a name and an address and nothing
      // else, and this answer is where its size and type come from.
      return _textFrom(result, learnsFile: true);
    }

    final result = await _call(ref, 'get_mail_attachment', {
      'message_id': ref.messageId,
      'attachment_id': ref.attachmentId,
      'mode': 'text',
    });
    return _textFrom(result);
  }

  /// The mode pair every by-id or by-url fetch speaks: bytes, or a thumbnail
  /// whose size rides `options` as JSON. One helper for the two tools that
  /// take it (`inspect_file`, `get_teams_attachment`) so a size can never be
  /// sent as a flat parameter at one site and as JSON at the other.
  static Map<String, Object?> _modeArgs(String thumbnail) => {
        'mode': thumbnail.isEmpty ? 'bytes' : 'thumbnail',
        if (thumbnail.isNotEmpty)
          'options': jsonEncode({'thumbnail': thumbnail}),
      };

  @override
  Future<AttachmentBytesResult> fetchBytes(
    AttachmentRef ref, {
    String thumbnail = '',
  }) async {
    final Map<String, dynamic> result;

    // A mail link IS a file — it just lives in OneDrive or SharePoint rather
    // than on the message — so it is fetched by its url like a chat's shared
    // file. The same `inspect_file` the text path above calls, one mode over:
    // every mode of it answers the file's name, size and type, and only the
    // payload key differs.
    if (ref.kind == 'reference') {
      final url = ref.contentUrl;
      if (url == null || url.isEmpty) {
        throw const AttachmentUnavailable('reference_no_url');
      }
      result = await _call(ref, 'inspect_file', {
        'url': url,
        ..._modeArgs(thumbnail),
      });
    } else if (ref.source == 'email') {
      if (!const {'file', 'item', 'unknown'}.contains(ref.kind)) {
        throw AttachmentUnavailable('kind_${ref.kind}');
      }
      // `mode` is load-bearing here: the published tool defaults to text, so
      // a call that forgot it would get extracted words where it wanted
      // base64, and no error to say so.
      result = await _call(ref, 'get_mail_attachment', {
        'message_id': ref.messageId,
        'attachment_id': ref.attachmentId,
        'mode': 'bytes',
      });
    } else {
      if (!const {'file', 'image'}.contains(ref.kind)) {
        throw AttachmentUnavailable('kind_${ref.kind}');
      }
      // Every chat attachment call needs the chat it hangs off, and the
      // `attachments` row has no column for one — it rides along on the ref
      // from the join. A ref built without it cannot be fetched, and saying so
      // is better than sending the server an empty chat id.
      final chatId = ref.conversationKey;
      if (chatId == null || chatId.isEmpty) {
        throw const AttachmentUnavailable('no_chat');
      }
      result = await _call(ref, 'get_teams_attachment', {
        'message_id': ref.messageId,
        'attachment_id': ref.attachmentId,
        'chat_id': chatId,
        ..._modeArgs(thumbnail),
      });
    }

    final error = result['error'];
    if (error is String && error.isNotEmpty) {
      // Mapped exactly as the text path maps it, and for the reason
      // [_permanentServerReasons] states: this reason is recorded as the text
      // skip the failed fetch amounts to and ends up on a chip, so an
      // unrecognised server word must not survive the trip.
      throw AttachmentUnavailable(
        _permanentServerReasons.contains(error) ? error : 'unavailable',
      );
    }

    final encoded = result['content_base64'];
    if (encoded is! String || encoded.isEmpty) {
      throw const AttachmentUnavailable('empty');
    }

    // Off the UI isolate. A megabyte of base64 is milliseconds of pure CPU in
    // the middle of a frame, and `compute` is exactly the tool for it: the
    // callback is a TOP-LEVEL function (`base64Decode` from dart:convert) and
    // the argument is a String, so both are sendable across the isolate port.
    final bytes = await compute(base64Decode, encoded);

    // In thumbnail mode `content_type` still describes the FILE and
    // `thumbnail_content_type` describes the picture. The picture is what came
    // back, and its own type is what the cache names it by.
    final type = thumbnail.isEmpty
        ? result['content_type']
        : result['thumbnail_content_type'] ?? result['content_type'];

    return AttachmentBytesResult(
      bytes,
      contentType: _stringOrNull(type),
      name: _stringOrNull(result['name']),
    );
  }

  /// One tool result as an [AttachmentText].
  ///
  /// Order matters. A named error is the connector's own answer and wins over
  /// everything; then the absence of words, which the server usually explains
  /// in `reason` and which is `empty` when it does not; then the words
  /// themselves.
  ///
  /// [learnsFile] is true only for the inspector: `inspect_file`'s `size` and
  /// `content_type` describe the file itself, whereas
  /// `get_mail_attachment`'s `size` is what the server moved to answer
  /// and its type, when it states one, is the extractor's — and a mail
  /// attachment already knew both from its listing.
  static AttachmentText _textFrom(
    Map<String, dynamic> result, {
    bool learnsFile = false,
  }) {
    // What the server says about the message an `item` attachment wraps. Read
    // once and carried onto every answer below, including the two skips: a
    // forwarded mail that could not be read still has a subject, a sender and
    // a date, and the preview draws that header whether or not there were
    // words underneath it. Dropping them on the skip would make the header
    // appear and disappear according to whether the extractor got anywhere.
    final itemSubject = _stringOrNull(result['item_subject']);
    final itemFrom = _stringOrNull(result['item_from']);
    final itemReceived = _stringOrNull(result['item_received']);

    final error = result['error'];
    if (error is String && error.isNotEmpty) {
      return AttachmentText.skipped(
        _permanentServerReasons.contains(error) ? error : 'unavailable',
        itemSubject: itemSubject,
        itemFrom: itemFrom,
        itemReceived: itemReceived,
      );
    }

    final text = result['text'];
    if (text is! String || text.isEmpty) {
      return AttachmentText.skipped(
        _stringOrNull(result['reason']) ?? 'empty',
        itemSubject: itemSubject,
        itemFrom: itemFrom,
        itemReceived: itemReceived,
      );
    }

    // `size` is what the server actually moved to answer, which is the number
    // worth recording; the character count is the fallback because a text
    // fetched from a cache reports no size at all.
    final size = (result['size'] as num?)?.toInt();
    return AttachmentText.ok(
      text,
      truncated: result['truncated'] == true,
      fetchedBytes: size ?? text.length,
      itemSubject: itemSubject,
      itemFrom: itemFrom,
      itemReceived: itemReceived,
      // What `inspect_file` learned about a file the app had only a url for.
      // Carried on the same result as the words because it is the same call:
      // the server states `name, size, content_type` beside the text, and a
      // link row has nowhere else to learn either. Zero is "the server did not
      // say" rather than an empty file, so it is dropped here instead of being
      // written over a size a listing already stated.
      size: learnsFile && size != null && size > 0 ? size : null,
      contentType: learnsFile ? _stringOrNull(result['content_type']) : null,
    );
  }

  /// One tool call, with this file's whole error policy in it — the same policy
  /// `mcp_mail_backend.dart` documents, with the banner chosen per ref.
  ///
  /// `not_connected` arrives as a NORMAL result rather than an error and means
  /// the one thing an interactive step can fix, so it becomes
  /// [ReconsentRequired], which is what routes the app to sign-in.
  Future<Map<String, dynamic>> _call(
    AttachmentRef ref,
    String tool,
    Map<String, Object?> args,
  ) async {
    final bool isMail = ref.source == 'email';
    final Map<String, dynamic> result;
    try {
      result = await _mcp.callTool(tool, args);
    } on McpToolException catch (e) {
      final status = _statusFromToolError(e.message);
      throw isMail
          ? GraphMailException(e.message, status)
          : GraphTeamsException(e.message, status);
    } on McpTransportException catch (e) {
      throw isMail
          ? GraphMailException(e.message, e.statusCode)
          : GraphTeamsException(e.message, e.statusCode);
    }
    if (result['error'] == 'not_connected') throw const ReconsentRequired();
    return result;
  }

  static String? _stringOrNull(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;
}
