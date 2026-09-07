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

/// The most characters this backend will store for one document — the MCP
/// server's own extractor cap. The two connectors must store the same size for
/// the same file, or a mailbox re-synced through the other backend would
/// silently change how much of a document a draft can cite.
const int _maxTextChars = 200000;

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
      // The word `attachment_policy.dart` uses for the same condition. The
      // panel prints whatever was stored, so a second spelling would put two
      // chips on one fact.
      return const AttachmentText.skipped('reference_no_url');
    }

    // A message forwarded as a file arrives as `message/rfc822`, which no text
    // codec reads, so without a route of its own it would fall through to the
    // refusal below and the forwarded mail's own subject, sender and date
    // would be lost with it. Graph will expand the wrapped message onto the
    // attachment, which is all of that in one request.
    if (ref.source == 'email' && ref.kind == 'item') {
      return _expandItem(ref);
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
    // Kept as the cheap first gate and trusted no further than that: Teams
    // writes 0 for every file it syncs and Graph omits the size on plenty of
    // mail attachments, so a three-megabyte log passes this line unremarked.
    if (ref.size > _maxTextBytes) {
      return const AttachmentText.skipped('too_large');
    }

    final http.Response response;
    try {
      // Which is why the DOWNLOAD carries the cap too. Asking for a range
      // stops the transfer at two megabytes instead of buffering the whole
      // file to throw most of it away, and a server that ignores the header
      // costs nothing but the bytes it was going to send anyway.
      response = await _fetchOrRefuse(
        ref,
        _uriFor(ref, ''),
        extraHeaders: {'Range': 'bytes=0-${_maxTextBytes - 1}'},
      );
    } on AttachmentUnavailable catch (e) {
      // A permanent refusal reached while fetching IS the reason there are no
      // words; it travels on as the skip it amounts to rather than as a throw
      // the handler would retry twice.
      return AttachmentText.skipped(e.reason);
    }

    // What was actually received, which is the number the activity row wants —
    // before the character cap below, which throws away words rather than
    // bytes moved.
    final received = response.bodyBytes;

    // A 206 says the server honoured the range and a 200 says it ignored it,
    // and the cut has to be made either way: an ignored range arrives whole.
    // The header is the one thing the body cannot tell us — a file cut at
    // exactly the cap looks the same as a file that happened to be that long —
    // so a total past the cap counts as a cut on its own.
    var truncated = received.length > _maxTextBytes ||
        _rangeExceedsCap(response.headers['content-range']);
    final bytes = received.length > _maxTextBytes
        ? received.sublist(0, _maxTextBytes)
        : received;

    var text = await compute(decodeUtf8Lenient, bytes);
    // The MCP server's extractor stops at the same number of characters, and
    // the two connectors must store the same size for the same file.
    if (text.length > _maxTextChars) {
      text = text.substring(0, _maxTextChars);
      truncated = true;
    }
    if (text.isEmpty) return const AttachmentText.skipped('empty');
    return AttachmentText.ok(
      text,
      truncated: truncated,
      fetchedBytes: received.length,
    );
  }

  /// The message an `item` attachment wraps: its words, and the three fields
  /// the `.eml` preview draws its header from.
  ///
  /// **The type cast in the `$expand` is mandatory.** A bare `item` is a Graph
  /// 400 — the property is declared on the itemAttachment subtype, not on the
  /// attachment base type — which is the same rule `graph_mail.dart`'s
  /// `microsoft.graph.fileAttachment/contentId` select follows, and the error
  /// names no property, so it reads as a broken request rather than as a wrong
  /// column.
  Future<AttachmentText> _expandItem(AttachmentRef ref) async {
    const String expand = 'microsoft.graph.itemattachment/item('
        '\$select=subject,from,receivedDateTime,bodyPreview,body)';
    final uri = Uri.parse(
      '$_base/me/messages/${Uri.encodeComponent(ref.messageId)}'
      '/attachments/${Uri.encodeComponent(ref.attachmentId)}',
    ).replace(query: '\$expand=${Uri.encodeComponent(expand)}');

    final http.Response response;
    try {
      response = await _fetchOrRefuse(ref, uri);
    } on AttachmentUnavailable catch (e) {
      // Same bargain as the text path: the refusal that stopped the fetch is
      // the reason there are no words.
      return AttachmentText.skipped(e.reason);
    }

    // Every level of the walk survives the level above it being absent. Graph
    // omits a branch rather than sending a null — a message with no sender has
    // no `from` at all — and an expanded item is four levels deep.
    final item = _mapAt(_decodeObject(response), 'item');
    final body = _mapAt(item, 'body');
    final bool isText = _stringAt(body, 'contentType') == 'text';
    // `bodyPreview` IS a cut of the body — Graph's first couple of hundred
    // characters of it — so falling back to the preview is a truncation and
    // gets recorded as one rather than stored as the whole message.
    final text =
        (isText ? _stringAt(body, 'content') : _stringAt(item, 'bodyPreview')) ??
            '';

    final itemSubject = _stringAt(item, 'subject');
    // The sender's ADDRESS rather than the display name, which is what the MCP
    // server returns for the same field: the address is the half that
    // identifies a person across both connectors.
    final itemFrom = _stringAt(_mapAt(_mapAt(item, 'from'), 'emailAddress'),
        'address');
    final itemReceived = _stringAt(item, 'receivedDateTime');

    if (text.isEmpty) {
      return AttachmentText.skipped(
        'empty',
        itemSubject: itemSubject,
        itemFrom: itemFrom,
        itemReceived: itemReceived,
      );
    }
    return AttachmentText.ok(
      text,
      truncated: !isText,
      fetchedBytes: response.bodyBytes.length,
      itemSubject: itemSubject,
      itemFrom: itemFrom,
      itemReceived: itemReceived,
    );
  }

  @override
  Future<AttachmentBytesResult> fetchBytes(
    AttachmentRef ref, {
    String thumbnail = '',
  }) async {
    final response = await _fetchOrRefuse(ref, _uriFor(ref, thumbnail));
    return AttachmentBytesResult(
      response.bodyBytes,
      contentType: _firstToken(response.headers['content-type']),
      name: ref.name,
    );
  }

  /// One attachment route fetched, with this connector's permanent refusals
  /// already turned into [AttachmentUnavailable].
  ///
  /// A private method rather than a second parameter on the seam. Only this
  /// backend can ask for a range — the MCP server hands back a whole file
  /// inside one JSON reply and has no partial mode at all — so widening
  /// [AttachmentBackend.fetchBytes] would put an option on the interface that
  /// one of the two implementations could only ignore. [extraHeaders] rides
  /// along on the GET beside the bearer.
  Future<http.Response> _fetchOrRefuse(
    AttachmentRef ref,
    Uri uri, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final response = await _send(
      uri,
      isMail: ref.source == 'email',
      extraHeaders: extraHeaders,
    );

    // Gone is gone. A message deleted between the sync and the click, a file
    // removed from the drive — both answer 404/410 forever, and both are
    // refusals rather than failures worth two retries.
    final status = response.statusCode;
    if (status == 404 || status == 410) {
      throw const AttachmentUnavailable('gone');
    }
    if (status == 403) throw const AttachmentUnavailable('access_denied');
    // 206 falls inside this range, which is the point: a server that honoured
    // the range answered successfully and its short body is the answer.
    if (status < 200 || status >= 300) {
      throw _describe(ref, response, 'Could not read an attachment from '
          'Microsoft Graph');
    }
    return response;
  }

  /// Which of the four routes this ref is fetched by.
  ///
  /// Deliberately a switch over `(source, kind)` and nothing else: the routes
  /// are not interchangeable, and a fallback that guessed would send a hosted
  /// image id to the mail endpoint and read the 404 as a deleted file.
  Uri _uriFor(AttachmentRef ref, String thumbnail) {
    if (ref.source == 'email') {
      // A mail link is a drive item like any other, so it gets the drive's
      // own rendering exactly as a chat's shared file does — the size word
      // travels through rather than being dropped.
      if (ref.kind == 'reference') return _shareUri(ref, thumbnail: thumbnail);
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
      // The same word the text path and `attachment_policy.dart` use, because
      // this refusal is recorded as the text skip it amounts to and lands on
      // the same chip.
      throw const AttachmentUnavailable('reference_no_url');
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
  ///
  /// [extraHeaders] defaults to none, so the bytes path sends exactly what it
  /// always sent; the text path uses it for a `Range`. They go in after the
  /// bearer and cannot displace it.
  Future<http.Response> _send(
    Uri uri, {
    required bool isMail,
    Map<String, String> extraHeaders = const {},
  }) async {
    var retriedThrottle = false;
    var retriedAuth = false;

    while (true) {
      // Outside the try: an AuthException from here is not a transport failure
      // and must reach the caller as itself.
      final token = await _auth.getValidAccessToken();

      final http.Response response;
      try {
        response = await _http.get(uri, headers: {
          ...extraHeaders,
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

  /// Whether a `Content-Range: bytes 0-N/TOTAL` says the file is bigger than
  /// the download cap — the one thing a capped body cannot say about itself.
  ///
  /// Read leniently on purpose. The header is optional, the total is `*` when
  /// the server does not know it, and a proxy is free to rewrite it into a
  /// shape this has never seen; anything unreadable means "no evidence of a
  /// cut", which is the answer the body length gives on its own.
  static bool _rangeExceedsCap(String? header) {
    final total = int.tryParse((header ?? '').split('/').last.trim());
    return total != null && total > _maxTextBytes;
  }

  /// Graph answers `application/json` with no charset, which makes `http`'s
  /// `body` getter fall back to latin-1 and mangle non-ASCII subjects and
  /// names. Decoding the bytes is the only correct read — the same helper,
  /// and the same reasoning, as `graph_mail.dart`'s.
  static Map<String, dynamic> _decodeObject(http.Response response) {
    try {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  /// One level down a Graph object, or null when that level is not there.
  static Map<String, dynamic>? _mapAt(Object? parent, String key) {
    final value = parent is Map<String, dynamic> ? parent[key] : null;
    return value is Map<String, dynamic> ? value : null;
  }

  /// A string one level down a Graph object. Empty reads as absent, for the
  /// same reason [_firstToken] reads it that way: a subject Graph sent as `''`
  /// is not a subject.
  static String? _stringAt(Object? parent, String key) {
    final value = parent is Map<String, dynamic> ? parent[key] : null;
    return value is String && value.isNotEmpty ? value : null;
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
