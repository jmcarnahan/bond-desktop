import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;

import '../models/attachment_models.dart';
import 'attachments/attachment_policy.dart' show maxAttachmentBytes;
import 'backend/attachment_backend.dart';
import 'graph_auth.dart';
import 'graph_mail.dart';
import 'graph_teams.dart';

/// Attachment bytes straight from Microsoft Graph, for the SDK backend.
///
/// The half of the seam with no extractor behind it. Bytes, inline images and
/// OneDrive thumbnails come back exactly as they do through the MCP server;
/// [extractText] reads only what a text codec can read and answers
/// `no_extractor` for everything else. That is a REFUSAL, not a failure — the
/// SDK path simply has no docx or pdf corpus, and pretending otherwise would
/// mark documents permanently broken on one backend and fine on the other.
///
/// The request plumbing is a deliberate narrow copy of `graph_mail.dart`'s: a
/// GET with the bearer attached, one retry for a throttle and one for a 401.
/// Copied rather than shared because widening `GraphMail` to serve a second
/// caller would put the attachment routes inside the class the mail sync
/// depends on, and the two travel to different banners.

/// A UTF-8 decode that survives a file lying about its encoding.
///
/// Top-level so it can cross an isolate port: `compute`'s callback must be a
/// top-level or static function, and an `utf8.decode` tear-off is neither.
String decodeUtf8Lenient(Uint8List bytes) =>
    utf8.decode(bytes, allowMalformed: true);

/// Content types this backend can turn into words with nothing but a codec.
const Set<String> _textLikeTypes = {
  'text/plain',
  'text/csv',
  'text/markdown',
  'text/html',
  'text/xml',
  'application/json',
  'application/xml',
};

/// The fallback when Graph reports `application/octet-stream`, which it does
/// for a great many real files.
const Set<String> _textLikeExtensions = {
  'txt',
  'csv',
  'json',
  'md',
  'log',
  'xml',
  'html',
  'htm',
};

/// The most this backend will pull down to decode as text. The MCP server's own
/// download ceiling, so the two paths refuse the same files.
const int _maxTextBytes = 2 * 1024 * 1024;

class GraphAttachmentBackend implements AttachmentBackend {
  static const String _base = 'https://graph.microsoft.com/v1.0';

  static const Duration _defaultBackoff = Duration(seconds: 5);
  static const Duration _maxBackoff = Duration(seconds: 60);

  final GraphAuth _auth;
  final http.Client _http;

  GraphAttachmentBackend(this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Graph streams the response, so there is no JSON envelope to outgrow and
  /// no ceiling of its own worth naming. The limit that applies is the app's
  /// own judgement about what a document IS — [maxAttachmentBytes], the same
  /// number the text policy refuses above — rather than a second literal that
  /// could drift away from it.
  @override
  int get maxPreviewBytes => maxAttachmentBytes;

  /// A sharing url as the token Graph's `/shares` endpoint takes.
  ///
  /// Base64url of the utf-8 bytes, padding stripped, `u!` in front. **A plain
  /// `Uri.encodeComponent` of the url is a Graph 400** — `/shares` does not
  /// take a url, it takes this encoding of one, and the error names no
  /// parameter, so it reads as a broken request rather than as a wrong value.
  ///
  /// Public and static because it is the one piece of this file worth pinning
  /// in a test without a socket.
  static String shareToken(String url) =>
      'u!${base64Url.encode(utf8.encode(url)).replaceAll('=', '')}';

  @override
  Future<AttachmentText> extractText(AttachmentRef ref) async {
    if (ref.source != 'email' &&
        const {'image', 'card', 'message_reference', 'other'}
            .contains(ref.kind)) {
      return const AttachmentText.skipped('binary');
    }

    // A url-shaped attachment with no url is the known hole this round ships
    // with: neither backend can select `sourceUrl` today.
    final bool byUrl =
        ref.kind == 'reference' || (ref.source != 'email' && ref.kind == 'file');
    if (byUrl && (ref.contentUrl == null || ref.contentUrl!.isEmpty)) {
      return const AttachmentText.skipped('no_url');
    }

    // The refusal that defines this backend. There is no Office or PDF
    // extractor on this path, and there is not going to be one — the MCP
    // server is where that corpus lives. Refused WITHOUT a fetch, because
    // downloading a 20 MB deck to discover it is a deck helps nobody.
    if (!_isTextLike(ref)) {
      return const AttachmentText.skipped('no_extractor');
    }

    // The size the connector claims, checked before the request rather than
    // after it. A text file past two megabytes is a log, not a document.
    if (ref.size > _maxTextBytes) {
      return const AttachmentText.skipped('too_large');
    }

    final AttachmentBytesResult result;
    try {
      result = await fetchBytes(ref);
    } on AttachmentUnavailable catch (e) {
      // A permanent refusal reached while fetching IS the reason there are no
      // words; it travels on as the skip it amounts to rather than as a throw
      // the handler would retry twice.
      return AttachmentText.skipped(e.reason);
    }

    final text = await compute(decodeUtf8Lenient, result.bytes);
    if (text.isEmpty) return const AttachmentText.skipped('empty');
    return AttachmentText.ok(text, fetchedBytes: result.bytes.length);
  }

  @override
  Future<AttachmentBytesResult> fetchBytes(
    AttachmentRef ref, {
    String thumbnail = '',
  }) async {
    final uri = _uriFor(ref, thumbnail);
    final response = await _send(uri, isMail: ref.source == 'email');

    // Gone is gone. A message deleted between the sync and the click, a file
    // removed from the drive — both answer 404/410 forever, and both are
    // refusals rather than failures worth two retries.
    final status = response.statusCode;
    if (status == 404 || status == 410) {
      throw const AttachmentUnavailable('gone');
    }
    if (status == 403) throw const AttachmentUnavailable('access_denied');
    if (status < 200 || status >= 300) {
      throw _describe(ref, response, 'Could not read an attachment from '
          'Microsoft Graph');
    }

    return AttachmentBytesResult(
      response.bodyBytes,
      contentType: _firstToken(response.headers['content-type']),
      name: ref.name,
    );
  }

  /// Which of the four routes this ref is fetched by.
  ///
  /// Deliberately a switch over `(source, kind)` and nothing else: the routes
  /// are not interchangeable, and a fallback that guessed would send a hosted
  /// image id to the mail endpoint and read the 404 as a deleted file.
  Uri _uriFor(AttachmentRef ref, String thumbnail) {
    if (ref.source == 'email') {
      if (ref.kind == 'reference') return _shareUri(ref, thumbnail: '');
      if (!const {'file', 'item', 'unknown'}.contains(ref.kind)) {
        throw AttachmentUnavailable('kind_${ref.kind}');
      }
      // An `item` attachment comes back as `message/rfc822`, which is the
      // whole message as a file — the same route, no special casing.
      return Uri.parse(
        '$_base/me/messages/${Uri.encodeComponent(ref.messageId)}'
        '/attachments/${Uri.encodeComponent(ref.attachmentId)}/\$value',
      );
    }

    if (ref.kind == 'image') {
      final chatId = ref.conversationKey;
      if (chatId == null || chatId.isEmpty) {
        throw const AttachmentUnavailable('no_chat');
      }
      // For a Teams image the attachment id IS the hosted-content id — the
      // ingest names it that way precisely so this route can be built from a
      // row without a second lookup.
      return Uri.parse(
        '$_base/chats/${Uri.encodeComponent(chatId)}'
        '/messages/${Uri.encodeComponent(ref.messageId)}'
        '/hostedContents/${Uri.encodeComponent(ref.attachmentId)}/\$value',
      );
    }

    if (ref.kind == 'file') return _shareUri(ref, thumbnail: thumbnail);
    throw AttachmentUnavailable('kind_${ref.kind}');
  }

  /// A OneDrive or SharePoint sharing url, as a drive item.
  ///
  /// [thumbnail] non-empty asks the drive for its own rendering at that size
  /// instead of the file — which is what makes a chat's shared PDF show a
  /// picture without this app ever downloading the PDF.
  Uri _shareUri(AttachmentRef ref, {required String thumbnail}) {
    final url = ref.contentUrl;
    if (url == null || url.isEmpty) {
      throw const AttachmentUnavailable('no_url');
    }
    final token = shareToken(url);
    return Uri.parse(
      thumbnail.isEmpty
          ? '$_base/shares/$token/driveItem/content'
          : '$_base/shares/$token/driveItem/thumbnails/0/$thumbnail/content',
    );
  }

  bool _isTextLike(AttachmentRef ref) {
    final type = _firstToken(ref.contentType)?.toLowerCase();
    if (type != null && _textLikeTypes.contains(type)) return true;
    return _textLikeExtensions.contains(_extensionOf(ref.name));
  }

  /// A GET with the bearer attached, retrying at most once for a throttle and
  /// once for a 401 — `graph_mail.dart`'s `_request`, narrowed to the one
  /// method this file makes.
  Future<http.Response> _send(Uri uri, {required bool isMail}) async {
    var retriedThrottle = false;
    var retriedAuth = false;

    while (true) {
      // Outside the try: an AuthException from here is not a transport failure
      // and must reach the caller as itself.
      final token = await _auth.getValidAccessToken();

      final http.Response response;
      try {
        response = await _http.get(uri, headers: {
          'Authorization': 'Bearer $token',
        });
      } on http.ClientException catch (e) {
        throw _unreachable(isMail, e.message);
      } on SocketException catch (e) {
        throw _unreachable(isMail, e.message);
      }

      if (response.statusCode == 429 && !retriedThrottle) {
        retriedThrottle = true;
        await Future.delayed(_retryAfter(response));
        continue;
      }
      // A token valid when it was minted can still be rejected. One more pass
      // gives the refresh a chance to have happened; a second 401 is an
      // answer, not a race.
      if (response.statusCode == 401 && !retriedAuth) {
        retriedAuth = true;
        continue;
      }
      return response;
    }
  }

  /// The worker routes on the exception's TYPE, and a chat attachment that
  /// could not be reached must arrive as the chat kind, not the mail one.
  static Exception _unreachable(bool isMail, String detail) {
    final message = 'Could not reach Microsoft Graph: $detail';
    return isMail ? GraphMailException(message) : GraphTeamsException(message);
  }

  static Duration _retryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return _defaultBackoff;
    final asked = Duration(seconds: seconds);
    return asked > _maxBackoff ? _maxBackoff : asked;
  }

  /// The failure a caller routes on: mail attachments travel to the mail
  /// banner, chat attachments to the chat one. Same body-snippet reasoning as
  /// `graph_mail.dart`'s `_describe` — an HTTP number alone has never been
  /// enough to tell a bad request from an expired consent.
  static Exception _describe(
    AttachmentRef ref,
    http.Response response,
    String prefix,
  ) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final snippet = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    final message = '$prefix (HTTP ${response.statusCode}).'
        '${snippet.isEmpty ? '' : ' $snippet'}';
    return ref.source == 'email'
        ? GraphMailException(message, response.statusCode)
        : GraphTeamsException(message, response.statusCode);
  }

  /// `text/plain; charset=utf-8` → `text/plain`. Null and empty stay null: a
  /// header that was not sent is not a content type of `''`.
  static String? _firstToken(String? raw) {
    final value = (raw ?? '').split(';').first.trim();
    return value.isEmpty ? null : value;
  }

  /// The lower-cased extension of a file name, or `''`.
  ///
  /// A four-line copy of the one in `widgets/attachment_format.dart` rather
  /// than an import: services never reach into the widget layer, and a shared
  /// home for four lines would be a file that exists to be shared.
  static String _extensionOf(String? name) {
    final trimmed = (name ?? '').trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0 || dot == trimmed.length - 1) return '';
    return trimmed.substring(dot + 1).toLowerCase();
  }
}
