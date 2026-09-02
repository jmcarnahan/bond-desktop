import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'backend/backend_types.dart';
import 'backend/mail_backend.dart';
import 'graph_auth.dart';

/// The Microsoft Graph mail reads this app makes: a delta drain per folder,
/// and a per-message body fetch. Nothing here touches sqlite — [SyncService]
/// owns the writes.
///
/// Auth failures pass through UNWRAPPED. [NotSignedIn] and [ReconsentRequired]
/// mean the session is over and the UI must route to sign-in; a plain
/// [AuthException] is transient. Wrapping any of them in a
/// [GraphMailException] here would erase that distinction.

/// Any other failed Graph mail call. [message] is safe to show a user.
class GraphMailException implements Exception {
  final String message;
  final int? statusCode;

  const GraphMailException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

class GraphMail implements MailBackend {
  static const String _base = 'https://graph.microsoft.com/v1.0';

  /// Tier one of the two-tier fetch: enough to list, sort, and thread a
  /// message, and no body. Delta pages carry hundreds of messages, so the
  /// bodies stay behind [getMessageDetail] and are fetched only for threads
  /// the user actually opens.
  static const String _deltaSelect = 'id,internetMessageId,conversationId,'
      'subject,from,toRecipients,receivedDateTime,isRead,isDraft,bodyPreview';

  /// Tier two. `uniqueBody` is the part of the message that is NOT quoted
  /// thread — Graph computes it server-side, and with the Prefer header
  /// below it arrives as plain text already converted from HTML. That is the
  /// entire reason this app never parses mail HTML itself.
  static const String _detailSelect =
      'id,uniqueBody,internetMessageHeaders,hasAttachments';

  static const Map<String, String> _plainTextBody = {
    'Prefer': 'outlook.body-content-type="text"',
  };

  /// A 429 with no parseable Retry-After waits this long; anything Graph
  /// asks for above [_maxBackoff] is clamped, since a sync that sleeps for
  /// minutes is indistinguishable from a hung app.
  static const Duration _defaultBackoff = Duration(seconds: 5);
  static const Duration _maxBackoff = Duration(seconds: 60);

  final GraphAuth _auth;
  final http.Client _http;

  GraphMail(this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// One page of `/messages/delta` for [folder] ('inbox', 'sentitems').
  ///
  /// [link] is an opaque `@odata.nextLink` or `@odata.deltaLink` from a
  /// previous page and is fetched VERBATIM — it already carries the select
  /// and filter the drain started with, and rebuilding it would silently
  /// change the query mid-drain. [minReceivedIso] applies only to a drain
  /// starting from scratch.
  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) async {
    final uri = link != null
        ? Uri.parse(link)
        : _deltaUri(folder, minReceivedIso);

    final response = await _send(uri);

    if (response.statusCode == 410) throw const DeltaResyncRequired();
    if (response.statusCode != 200) {
      throw _describe(response, 'Could not read mail from Microsoft Graph');
    }

    final json = _decodeObject(response);
    final value = json['value'];
    return DeltaPage(
      messages: [
        for (final item in value is List ? value : const [])
          if (item is Map<String, dynamic>) item,
      ],
      nextLink: json['@odata.nextLink'] as String?,
      deltaLink: json['@odata.deltaLink'] as String?,
    );
  }

  /// The full body and headers for one message.
  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) async {
    final uri = Uri.parse('$_base/me/messages/${Uri.encodeComponent(id)}')
        .replace(query: '\$select=${Uri.encodeComponent(_detailSelect)}');

    final response = await _send(uri, headers: _plainTextBody);
    if (response.statusCode != 200) {
      throw _describe(response, 'Could not read a message from Microsoft Graph');
    }
    return _decodeObject(response);
  }

  // ── Drafts and sending ───────────────────────────────────────────────
  //
  // Three calls, in the order the send flow makes them: create the reply
  // shell, fill in its body, send it. Graph builds the reply itself, which is
  // the whole reason it is done this way — the recipients, the subject, the
  // In-Reply-To and References headers and the quoted thread all come from the
  // message being replied to, and none of them are this app's to reconstruct.

  /// Creates a draft reply to [messageId] in the user's Drafts folder.
  ///
  /// The response carries the fields the caller needs: `id` to fill in and
  /// send, `webLink` to hand to Outlook when this app may only save drafts.
  ///
  /// The `Prefer: outlook.timezone` header sets the zone Graph renders the
  /// quoted thread's timestamps in. Graph accepts Windows names
  /// ("Pacific Standard Time") and IANA names ("America/Los_Angeles"); macOS's
  /// [DateTime.timeZoneName] hands back an abbreviation like `PST`, which Graph
  /// generally accepts too. When it does not, the call is retried once WITHOUT
  /// the header: a draft whose quoted timestamps are in UTC is worth far more
  /// than no draft at all.
  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async {
    final uri = Uri.parse(
      '$_base/me/messages/${Uri.encodeComponent(messageId)}/createReply',
    );

    var response = await _request('POST', uri, headers: _preferTimeZone());
    if (response.statusCode == 400) {
      response = await _request('POST', uri);
    }

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _describe(response, 'Could not start a reply in Microsoft Graph');
    }
    return _decodeObject(response);
  }

  /// Replaces a draft's body with [text].
  ///
  /// Plain text, always: the composer is a plain-text field, and sending its
  /// contents as HTML would turn every `<` a person typed into markup.
  @override
  Future<void> updateDraftBody(String draftId, String text) async {
    final response = await _request(
      'PATCH',
      Uri.parse('$_base/me/messages/${Uri.encodeComponent(draftId)}'),
      jsonBody: {
        'body': {'contentType': 'text', 'content': text},
      },
    );
    if (response.statusCode != 200) {
      throw _describe(response, 'Could not save the draft to Microsoft Graph');
    }
  }

  /// Sends an existing draft. Graph answers 202 with no body.
  ///
  /// Nothing in this app calls this except a Send button the user pressed.
  @override
  Future<void> sendDraft(String draftId) async {
    final response = await _request(
      'POST',
      Uri.parse('$_base/me/messages/${Uri.encodeComponent(draftId)}/send'),
    );
    if (response.statusCode != 202 && response.statusCode != 200) {
      throw _describe(response, 'Microsoft Graph could not send the reply');
    }
  }

  /// Marks each of [messageIds] read (or unread), one PATCH at a time, and
  /// returns the ids worth trying again.
  ///
  /// Sequential rather than a `$batch`: an ack is a handful of ids that nobody
  /// is waiting on, and one request per id keeps each id's outcome its own —
  /// which is the whole return value. Batching is a later optimization, and
  /// only if a thread with a hundred unread messages stops being rare.
  ///
  /// A 404 or a 410 is DROPPED rather than returned. The user read a message
  /// that has since been deleted somewhere else; there is no read flag left to
  /// set, and retrying forever is the only thing calling that a failure would
  /// buy.
  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async {
    final failed = <String>[];
    for (final id in messageIds) {
      final response = await _request(
        'PATCH',
        Uri.parse('$_base/me/messages/${Uri.encodeComponent(id)}'),
        jsonBody: {'isRead': isRead},
      );
      final status = response.statusCode;
      if (status >= 200 && status < 300) continue;
      if (status == 404 || status == 410) continue;
      failed.add(id);
    }
    return failed;
  }

  /// The local zone, as a `Prefer` header. Rebuilt per call rather than held
  /// as a constant: a laptop that crosses a time zone should not keep quoting
  /// timestamps in the one it left.
  static Map<String, String> _preferTimeZone() => {
        'Prefer': 'outlook.timezone="${DateTime.now().timeZoneName}"',
      };

  /// Built by hand rather than through `queryParameters`, which encodes a
  /// space as `+`. Graph's OData parser wants `%20` in a `$filter`.
  Uri _deltaUri(String folder, String? minReceivedIso) {
    final query = StringBuffer(
      '\$select=${Uri.encodeComponent(_deltaSelect)}',
    );
    if (minReceivedIso != null && minReceivedIso.isNotEmpty) {
      final filter = 'receivedDateTime ge $minReceivedIso';
      query.write('&\$filter=${Uri.encodeComponent(filter)}');
    }
    return Uri.parse('$_base/me/mailFolders/$folder/messages/delta')
        .replace(query: query.toString());
  }

  /// A GET with the bearer token attached, retrying at most once for a
  /// throttle and once for a 401.
  Future<http.Response> _send(
    Uri uri, {
    Map<String, String> headers = const {},
  }) =>
      _request('GET', uri, headers: headers);

  /// One authenticated request of any method, retrying at most once for a
  /// throttle and once for a 401.
  ///
  /// [jsonBody] is encoded and sent with the JSON content type; omitting it
  /// sends no body at all, which is what `/send` and `/createReply` want —
  /// both take their entire input from the URL.
  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? jsonBody,
  }) async {
    var retriedThrottle = false;
    var retriedAuth = false;
    final body = jsonBody == null ? null : jsonEncode(jsonBody);

    while (true) {
      // Outside the try: an AuthException from here is not a transport
      // failure and must reach the caller as itself.
      final token = await _auth.getValidAccessToken();
      final sent = {
        'Authorization': 'Bearer $token',
        if (body != null) 'Content-Type': 'application/json',
        ...headers,
      };

      final http.Response response;
      try {
        response = switch (method) {
          'POST' => await _http.post(uri, headers: sent, body: body),
          'PATCH' => await _http.patch(uri, headers: sent, body: body),
          _ => await _http.get(uri, headers: sent),
        };
      } on http.ClientException catch (e) {
        throw GraphMailException('Could not reach Microsoft Graph: ${e.message}');
      } on SocketException catch (e) {
        throw GraphMailException('Could not reach Microsoft Graph: ${e.message}');
      }

      if (response.statusCode == 429 && !retriedThrottle) {
        retriedThrottle = true;
        await Future.delayed(_retryAfter(response));
        continue;
      }
      // A token that was valid when it was minted can still be rejected —
      // a revoked session, a changed password. One more pass gives the
      // refresh a chance to have happened on another caller's behalf; a
      // second 401 is a real answer, not a race.
      if (response.statusCode == 401 && !retriedAuth) {
        retriedAuth = true;
        continue;
      }
      return response;
    }
  }

  static Duration _retryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    final seconds = raw == null ? null : int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return _defaultBackoff;
    final asked = Duration(seconds: seconds);
    return asked > _maxBackoff ? _maxBackoff : asked;
  }

  /// Graph puts the useful part of a failure in the body, so a snippet of it
  /// goes in the message — an HTTP number alone has never been enough to
  /// tell a bad filter from an expired consent.
  static GraphMailException _describe(http.Response response, String prefix) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final snippet = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    return GraphMailException(
      '$prefix (HTTP ${response.statusCode}).'
      '${snippet.isEmpty ? '' : ' $snippet'}',
      response.statusCode,
    );
  }

  /// Graph answers `application/json` with no charset, which makes `http`'s
  /// `body` getter fall back to latin-1 and mangle non-ASCII names and
  /// bodies. Decoding the bytes is the only correct read — same reason as
  /// the identical helper in graph_auth.dart.
  static Map<String, dynamic> _decodeObject(http.Response response) {
    try {
      final decoded =
          jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}
