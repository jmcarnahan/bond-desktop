import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'graph_auth.dart';

/// The Microsoft Graph chat reads this app makes: the chat list, one chat's
/// members, and a chat's messages since a cursor. Nothing here touches sqlite —
/// [TeamsSync] owns the writes.
///
/// Auth failures pass through UNWRAPPED, exactly as they do in graph_mail.dart:
/// [NotSignedIn] and [ReconsentRequired] mean the session is over and the UI
/// must route to sign-in, while a plain [AuthException] is transient. Wrapping
/// either in a [GraphTeamsException] would erase that distinction.
///
/// **Channel messages are deliberately absent.** Reading a team's channels
/// needs tenant-wide admin consent this app does not ask for; 1:1 and group
/// chats need only the delegated `Chat.Read` the sign-in already requests.
///
/// **Nothing in this file may be called from a timer.** Microsoft's terms for
/// the Teams messaging endpoints forbid background polling: every call must
/// trace back to something the user did. [TeamsSync] is the only caller and it
/// enforces that; see its class comment.

/// A failed Graph chat call. [message] is safe to show a user.
///
/// A sibling of [GraphMailException] rather than a reuse of it: the two travel
/// to different banners, and a catch that means "the mail sync broke" must not
/// silently start swallowing Teams failures too.
class GraphTeamsException implements Exception {
  final String message;
  final int? statusCode;

  const GraphTeamsException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

class GraphTeams {
  static const String _base = 'https://graph.microsoft.com/v1.0';

  /// Chats and messages per page. Fifty is Graph's comfortable page for both
  /// and keeps a first sync to one request per chat.
  static const int _pageSize = 50;

  /// Microsoft asks for no more than one request per second against a single
  /// chat, and a gentler hand on the chat list. Both are floors, not budgets:
  /// the sync makes far fewer calls than this allows.
  static const Duration defaultChatListGap = Duration(milliseconds: 200);
  static const Duration defaultSameChatGap = Duration(seconds: 1);

  /// A 429 with no parseable Retry-After waits this long; anything Graph asks
  /// for above [_maxBackoff] is clamped, since a sync that sleeps for minutes
  /// is indistinguishable from a hung app. Same numbers as graph_mail.dart.
  static const Duration _defaultBackoff = Duration(seconds: 5);
  static const Duration _maxBackoff = Duration(seconds: 60);

  final GraphAuth _auth;
  final http.Client _http;

  /// The two throttle floors, injectable so a throttle test does not have to
  /// spend a real second per chat to prove the gap is honoured. Production
  /// never passes either.
  final Duration _chatListGap;
  final Duration _sameChatGap;

  /// When the last chat-list page was requested, and when each chat was last
  /// touched. Held per instance because the throttle is about this client's
  /// own traffic — a second instance would be a second sync, which the
  /// provider makes sure does not exist.
  DateTime? _lastChatListAt;
  final Map<String, DateTime> _lastChatAt = {};

  GraphTeams(
    this._auth, {
    http.Client? httpClient,
    Duration chatListGap = defaultChatListGap,
    Duration sameChatGap = defaultSameChatGap,
  })  : _http = httpClient ?? http.Client(),
        _chatListGap = chatListGap,
        _sameChatGap = sameChatGap;

  /// The signed-in user's Graph id.
  ///
  /// Fetched per sync and held by the caller in memory rather than stored: it
  /// is the one field that decides whether a chat message is the user's own,
  /// and the account record graph_auth.dart persists is not this file's to
  /// extend.
  Future<String> myUserId() async {
    final response = await _send(Uri.parse('$_base/me'));
    if (response.statusCode != 200) {
      throw _describe(response, 'Could not read your Microsoft profile');
    }
    final id = _decodeObject(response)['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const GraphTeamsException(
        'Microsoft Graph returned a profile with no id.',
      );
    }
    return id;
  }

  /// Every chat the user is in, newest activity first, across at most
  /// [maxPages] pages.
  ///
  /// `$orderby` is on `lastMessagePreview/createdDateTime` and NOT on
  /// `lastUpdatedDateTime`: Graph rejects an order on the latter, and the
  /// expanded preview is the only per-chat timestamp that can be sorted. The
  /// preview is also what lets [TeamsSync] skip a chat without fetching its
  /// messages at all.
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4}) async {
    final chats = <Map<String, dynamic>>[];
    Uri? uri = _chatsUri();

    for (var page = 0; page < maxPages && uri != null; page++) {
      await _throttleChatList();
      final response = await _send(uri);
      if (response.statusCode != 200) {
        throw _describe(response, 'Could not read your Teams chats');
      }
      final json = _decodeObject(response);
      chats.addAll(_values(json));
      final next = json['@odata.nextLink'] as String?;
      // Fetched VERBATIM, like a delta nextLink: it already carries the
      // expand and the order the walk started with.
      uri = (next == null || next.isEmpty) ? null : Uri.parse(next);
    }
    return chats;
  }

  /// One chat's members.
  ///
  /// One request, no paging: this is called once per chat the app has never
  /// seen, purely to name the thread and its participants, and a group chat
  /// with more than [_pageSize] members has a name of its own anyway.
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) async {
    await _throttleChat(chatId);
    final response = await _send(
      Uri.parse('$_base/chats/${Uri.encodeComponent(chatId)}/members')
          .replace(query: '\$top=$_pageSize'),
    );
    if (response.statusCode != 200) {
      throw _describe(response, 'Could not read a Teams chat’s members');
    }
    return _values(_decodeObject(response));
  }

  /// One chat's messages, newest first, back to [sinceIso].
  ///
  /// Three Graph facts shape this and every one of them is load bearing:
  ///
  /// - the `$filter` property MUST be the `$orderby` property. A filter on
  ///   `lastModifiedDateTime` beside an order on anything else is SILENTLY
  ///   IGNORED — no error, just every message in the chat — so the two are
  ///   built from one constant here rather than written out twice.
  /// - `createdDateTime` supports only `lt`, which is the wrong direction for
  ///   "what is new", so the cursor rides on `lastModifiedDateTime`.
  /// - the order can only be descending.
  ///
  /// A null [sinceIso] sends no filter and takes exactly ONE page: a chat the
  /// app has never seen starts from its newest fifty messages. Reaching
  /// further back would spend a request per page on history the user has
  /// already read in Teams, and the conversation state machine only needs
  /// enough of a chat to know who spoke last.
  ///
  /// With a cursor the walk runs until the FILTERED set is exhausted. The
  /// server-side `gt` filter means every returned message is newer than the
  /// cursor, so the caller advances its cursor to the newest one — a page cap
  /// that stopped the walk early would therefore advance that cursor over
  /// messages never fetched, a permanent hole in the transcript. [maxPages]
  /// exists only as a runaway bound (a chat would need [_pageSize]×[maxPages]
  /// new messages between two user-triggered refreshes to hit it); hitting it
  /// is logged, because it means exactly such a hole.
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  }) async {
    final messages = <Map<String, dynamic>>[];
    final firstRun = sinceIso == null || sinceIso.isEmpty;
    Uri? uri = _chatMessagesUri(chatId, firstRun ? null : sinceIso);

    final pages = firstRun ? 1 : maxPages;
    for (var page = 0; page < pages && uri != null; page++) {
      await _throttleChat(chatId);
      final response = await _send(uri);
      if (response.statusCode != 200) {
        throw _describe(response, 'Could not read a Teams chat');
      }
      final json = _decodeObject(response);
      final value = _values(json);
      messages.addAll(value);

      // Descending order means the last item on a page is its oldest. Once
      // that predates the cursor the walk has covered everything new, and the
      // pages behind it are history the store already has.
      if (!firstRun && _reachedCursor(value, sinceIso)) break;

      final next = json['@odata.nextLink'] as String?;
      uri = (next == null || next.isEmpty) ? null : Uri.parse(next);
    }
    if (uri != null && !firstRun) {
      debugPrint(
        'GraphTeams: chat $chatId had more than ${_pageSize * maxPages} new '
        'messages in one pull — the walk stopped at the page bound, and the '
        'messages behind it will not be fetched.',
      );
    }
    return messages;
  }

  /// Whether this page's oldest message is at or before the cursor.
  ///
  /// An empty page ends the walk: there is nothing older to ask for. A page
  /// whose oldest message carries no timestamp does NOT end it — an undated
  /// message says nothing about how far back the page reached, and stopping on
  /// one would silently truncate the sync.
  static bool _reachedCursor(List<Map<String, dynamic>> page, String sinceIso) {
    if (page.isEmpty) return true;
    final oldest = page.last['lastModifiedDateTime'] as String?;
    if (oldest == null || oldest.isEmpty) return false;
    return oldest.compareTo(sinceIso) <= 0;
  }

  /// Built by hand rather than through `queryParameters`, which encodes a
  /// space as `+`. Graph's OData parser wants `%20` — the same reason
  /// graph_mail.dart builds its delta URL this way.
  Uri _chatsUri() {
    const order = 'lastMessagePreview/createdDateTime desc';
    final query = StringBuffer()
      ..write('\$expand=lastMessagePreview')
      ..write('&\$orderby=${Uri.encodeComponent(order)}')
      ..write('&\$top=$_pageSize');
    return Uri.parse('$_base/me/chats').replace(query: query.toString());
  }

  /// The one place the paired order and filter are written, so they cannot
  /// drift apart — see [chatMessagesSince] for why a mismatch is worse than an
  /// error.
  static const String _cursorProperty = 'lastModifiedDateTime';

  Uri _chatMessagesUri(String chatId, String? sinceIso) {
    final query = StringBuffer()
      ..write('\$top=$_pageSize')
      ..write('&\$orderby=${Uri.encodeComponent('$_cursorProperty desc')}');
    if (sinceIso != null && sinceIso.isNotEmpty) {
      query.write(
        '&\$filter=${Uri.encodeComponent('$_cursorProperty gt $sinceIso')}',
      );
    }
    return Uri.parse('$_base/chats/${Uri.encodeComponent(chatId)}/messages')
        .replace(query: query.toString());
  }

  /// Waits out whatever is left of the gap since the last chat-list page.
  Future<void> _throttleChatList() async {
    final wait = _remaining(_lastChatListAt, _chatListGap);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastChatListAt = DateTime.now();
  }

  /// Waits out whatever is left of the gap since this chat was last touched.
  /// Per chat, not global: two different chats are two different conversations
  /// as far as Graph's throttle is concerned.
  Future<void> _throttleChat(String chatId) async {
    final wait = _remaining(_lastChatAt[chatId], _sameChatGap);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastChatAt[chatId] = DateTime.now();
  }

  static Duration _remaining(DateTime? last, Duration gap) {
    if (last == null) return Duration.zero;
    return gap - DateTime.now().difference(last);
  }

  /// A GET with the bearer token attached, retrying at most once for a
  /// throttle and once for a 401. Same policy as graph_mail.dart, and for the
  /// same reasons — a token minted valid can still be rejected by a revoked
  /// session, and one more pass gives a concurrent refresh a chance to land.
  Future<http.Response> _send(Uri uri) async {
    var retriedThrottle = false;
    var retriedAuth = false;

    while (true) {
      // Outside the try: an AuthException from here is not a transport
      // failure and must reach the caller as itself.
      final token = await _auth.getValidAccessToken();

      final http.Response response;
      try {
        response = await _http.get(uri, headers: {
          'Authorization': 'Bearer $token',
        });
      } on http.ClientException catch (e) {
        throw GraphTeamsException(
          'Could not reach Microsoft Graph: ${e.message}',
        );
      } on SocketException catch (e) {
        throw GraphTeamsException(
          'Could not reach Microsoft Graph: ${e.message}',
        );
      }

      if (response.statusCode == 429 && !retriedThrottle) {
        retriedThrottle = true;
        await Future<void>.delayed(_retryAfter(response));
        continue;
      }
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

  /// A collection response's `value`, keeping only the objects.
  static List<Map<String, dynamic>> _values(Map<String, dynamic> json) {
    final value = json['value'];
    return [
      for (final item in value is List ? value : const [])
        if (item is Map<String, dynamic>) item,
    ];
  }

  static GraphTeamsException _describe(http.Response response, String prefix) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final snippet = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    return GraphTeamsException(
      '$prefix (HTTP ${response.statusCode}).'
      '${snippet.isEmpty ? '' : ' $snippet'}',
      response.statusCode,
    );
  }

  /// Graph answers `application/json` with no charset, which makes `http`'s
  /// `body` getter fall back to latin-1 and mangle non-ASCII names. Decoding
  /// the bytes is the only correct read — same helper as graph_mail.dart.
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
