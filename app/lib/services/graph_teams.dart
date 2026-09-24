import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'backend/backend_types.dart';
import 'backend/teams_backend.dart';
import 'chat_mentions.dart';
import 'graph_auth.dart';
import 'attachments/attachment_markers.dart' show hostedContentIds;

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

class GraphTeams implements TeamsBackend {
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
    this._chatListGap = defaultChatListGap,
    this._sameChatGap = defaultSameChatGap,
  })  : _http = httpClient ?? http.Client();

  /// The signed-in user's Graph id.
  ///
  /// Fetched per sync and held by the caller in memory rather than stored: it
  /// is the one field that decides whether a chat message is the user's own,
  /// and the account record graph_auth.dart persists is not this file's to
  /// extend.
  @override
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
  @override
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
  @override
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
  /// A null [sinceIso] sends no filter and takes exactly ONE page: the newest
  /// fifty messages and nothing behind them. That is now the DEGENERATE case,
  /// not the first-sight contract — [TeamsSync] hands a chat it has never seen
  /// the sync floor, because the lookback setting says how far back this app
  /// looks and a first fetch that stopped at fifty messages would make that
  /// promise false. What is left for the null path is a caller with no window
  /// to name at all, which is answered with the cheapest useful thing rather
  /// than with the whole chat.
  ///
  /// With a cursor the walk runs until the FILTERED set is exhausted. The
  /// server-side `gt` filter means every returned message is newer than the
  /// cursor, so the caller advances its cursor to the newest one — a page cap
  /// that stopped the walk early would therefore advance that cursor over
  /// messages never fetched, a permanent hole in the transcript. [maxPages]
  /// exists only as a runaway bound (a chat would need [_pageSize]×[maxPages]
  /// new messages between two user-triggered refreshes to hit it); hitting it
  /// is logged, because it means exactly such a hole.
  @override
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
      // Normalised HERE rather than in the sync, so `TeamsSync` reads one
      // attachment shape whichever backend it is talking to. The MCP server
      // already sends this shape; Graph does not, and converting at the point
      // the sync reads would mean the sync knowing both.
      for (final message in value) {
        message['attachments'] = attachmentEntries(message);
      }
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

  /// Marks a chat read for the signed-in user, up to its newest message.
  ///
  /// Per CHAT rather than per message, because that is what Teams stores: a
  /// chat carries one `viewpoint.lastMessageReadDateTime` and Graph moves it to
  /// the newest message. The ids the queue's payload names are therefore not
  /// sent — they are covered by construction.
  ///
  /// The tenant rides along because `markChatReadForUser` takes a
  /// `teamworkUserIdentity`, and [GraphAuth.tenantId] is the only tenant this
  /// file can honestly name: the registration is single-tenant and its
  /// authorize endpoint is built from that same constant. A build compiled
  /// without it sends the id alone rather than an empty string, which Graph
  /// would read as a tenant that does not exist.
  ///
  /// **Dormant in SDK mode.** Sign-in requests no `Chat.ReadWrite` — see
  /// [GraphAuth.pendingAdminScopes] — so this exists for seam parity with the
  /// MCP backend, which is where the grant actually lives.
  @override
  Future<void> markChatRead(String chatId) async {
    final userId = await myUserId();
    await _throttleChat(chatId);
    final response = await _request(
      'POST',
      Uri.parse(
        '$_base/chats/${Uri.encodeComponent(chatId)}/markChatReadForUser',
      ),
      jsonBody: {
        'user': {
          'id': userId,
          if (GraphAuth.tenantId.isNotEmpty) 'tenantId': GraphAuth.tenantId,
        },
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _describe(response, 'Could not mark a Teams chat read');
    }
  }

  /// Posts a message to a chat, and returns it as Graph stored it.
  ///
  /// `contentType: 'text'` is stated rather than left to Graph's default: the
  /// composer holds exactly what somebody typed, and letting it be read as HTML
  /// would turn a typed `<` into markup.
  ///
  /// [mentions] are the one reason to send HTML, because Graph carries a
  /// mention only as an `<at id>` in an html body beside a `mentions` array
  /// whose ids point back at it. [chatHtmlWithMentions] escapes the rest, so a
  /// typed `<` is still a `<`. With none, the body is exactly the text one —
  /// no HTML on a send that has no reason for it.
  ///
  /// The decoded response is the whole point of returning anything — it carries
  /// the id Graph assigned, which is what the caller writes into its own
  /// outbound row so the next pull recognises the message as one it has.
  ///
  /// **Dormant in SDK mode**, for the reason [markChatRead] gives.
  @override
  Future<Map<String, dynamic>> sendChatMessage(
    String chatId,
    String text, {
    List<ChatMention> mentions = const [],
  }) async {
    await _throttleChat(chatId);
    final people = distinctMentions(mentions);
    final response = await _request(
      'POST',
      Uri.parse('$_base/chats/${Uri.encodeComponent(chatId)}/messages'),
      jsonBody: people.isEmpty
          ? {
              'body': {'contentType': 'text', 'content': text},
            }
          : {
              'body': {
                'contentType': 'html',
                'content': chatHtmlWithMentions(text, people),
              },
              // `mentionText` is the at-tag's inner text exactly: Graph
              // refuses a mention whose text the body does not contain.
              'mentions': [
                for (var i = 0; i < people.length; i++)
                  {
                    'id': i,
                    'mentionText': people[i].displayName,
                    'mentioned': {
                      'user': {
                        'id': people[i].userId,
                        'displayName': people[i].displayName,
                        'userIdentityType': 'aadUser',
                      },
                    },
                  },
              ],
            },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _describe(response, 'Could not send your Teams message');
    }
    final message = _decodeObject(response);
    if ((message['id'] as String?)?.isNotEmpty != true) {
      throw const GraphTeamsException(
        'Microsoft Graph stored the message but returned no id for it.',
      );
    }
    return message;
  }

  /// Opens the chat holding exactly [userIds] plus the signed-in user.
  ///
  /// Graph has no "get or create": POSTing a `oneOnOne` chat with the same two
  /// members returns the EXISTING one, while POSTing a `group` makes another
  /// one every time. That asymmetry is the whole contract — see
  /// [TeamsBackend.ensureChat] — and it is why the type is decided by the
  /// member count here rather than passed in: one other person is a 1:1 by
  /// definition, and calling it a group would create a second, nameless thread
  /// beside the conversation they already have.
  ///
  /// The signed-in user goes in FIRST, because a chat is created on their
  /// behalf and Graph refuses a member list without them in it. `roles:
  /// ['owner']` on everybody is what a personal chat looks like; Teams has no
  /// other role for one.
  ///
  /// **Dormant in SDK mode**, for the reason [markChatRead] gives.
  @override
  Future<EnsuredChat> ensureChat(List<String> userIds, {String? topic}) async {
    if (userIds.isEmpty) {
      throw const GraphTeamsException('Pick at least one person.');
    }
    final me = await myUserId();
    // The user is added once, by this method, whatever the caller passed:
    // a pick that included them would otherwise turn a 1:1 into a two-member
    // "group" beside the chat they already have, or list a member twice.
    final others = {for (final id in userIds) if (id != me) id};
    if (others.isEmpty) {
      throw const GraphTeamsException('Pick somebody other than yourself.');
    }
    final isGroup = others.length > 1;

    final response = await _request(
      'POST',
      Uri.parse('$_base/chats'),
      jsonBody: {
        'chatType': isGroup ? 'group' : 'oneOnOne',
        if (isGroup && topic != null && topic.isNotEmpty) 'topic': topic,
        'members': [
          for (final id in [me, ...others]) _member(id),
        ],
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _describe(response, 'Could not open a Teams chat');
    }

    final chatId = _decodeObject(response)['id'] as String?;
    if (chatId == null || chatId.isEmpty) {
      throw const GraphTeamsException(
        'Microsoft Graph opened a chat but returned no id for it.',
      );
    }
    return EnsuredChat(chatId: chatId, isGroup: isGroup);
  }

  /// One member of a chat being created. The bind URL is Graph's way of
  /// naming an existing user from inside a POST body; an id on its own is not
  /// accepted.
  static Map<String, dynamic> _member(String userId) => {
        '@odata.type': '#microsoft.graph.aadUserConversationMember',
        'roles': const ['owner'],
        'user@odata.bind':
            "https://graph.microsoft.com/v1.0/users('$userId')",
      };

  /// One Graph chat message's attachments, as the flat entries the sync reads.
  ///
  /// Two sources, in this order. Graph's own `attachments[]` carries the files
  /// and cards somebody attached; the message's HTML body carries the images
  /// somebody pasted, as `<img>` tags pointing at hosted content, and Graph
  /// lists none of those as attachments. Both are things that came with the
  /// message, so both become rows.
  ///
  /// The discriminator for the first group is `contentType`, not an
  /// `@odata.type` — chat attachments have no subtypes, and the content type is
  /// what says whether an entry is a shared file, a rendered card, or a quote
  /// of another message. An unrecognised one is `other`, which the text policy
  /// refuses by kind rather than fetching bytes it cannot read.
  ///
  /// `card_text` is always null: parsing an adaptive card's JSON into a
  /// sentence is the server's job, and the desktop reads what the server
  /// rendered rather than rendering a second, differently-wrong version.
  ///
  /// A `messageReference` is the one entry whose `content` is read here, and it
  /// is read because the entry has nothing else: Graph sends a quote-reply with
  /// no `name` and no url, and everything a reader needs to see — who was
  /// quoted and what they said — is inside that JSON string. The three keys
  /// come out flat, so the sync reads fields rather than parsing a payload.
  static List<Map<String, Object?>> attachmentEntries(
    Map<String, dynamic> message,
  ) {
    final entries = <Map<String, Object?>>[];
    final raw = message['attachments'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final id = entry['id'] as String? ?? '';
        if (id.isEmpty) continue;
        final contentType = (entry['contentType'] as String? ?? '')
            .toLowerCase();
        final quoted = contentType == 'messagereference'
            ? quoteReferenceFields(entry['content'])
            : const <String, Object?>{
                'message_id': null,
                'message_sender': null,
                'message_preview': null,
              };
        entries.add({
          'id': id,
          'kind': switch (contentType) {
            'reference' => 'file',
            'application/vnd.microsoft.card.adaptive' => 'card',
            'messagereference' => 'message_reference',
            _ => 'other',
          },
          'name': entry['name'] as String?,
          'content_type': entry['contentType'] as String?,
          'content_url': entry['contentUrl'] as String?,
          'thumbnail_url': entry['thumbnailUrl'] as String?,
          'card_text': null,
          ...quoted,
        });
      }
    }

    // Only an HTML body can carry one: a `text` body is what a person typed
    // and holds no markup at all.
    for (final id in hostedContentIds(_bodyHtml(message))) {
      entries.add({
        'id': id,
        'kind': 'image',
        'name': null,
        'content_type': null,
        'content_url': null,
        'thumbnail_url': null,
        'card_text': null,
        'message_id': null,
        'message_sender': null,
        'message_preview': null,
      });
    }
    return entries;
  }

  /// The three fields inside a `messageReference` attachment's `content` —
  /// `message_id`, `message_sender`, `message_preview`, flat, and null for
  /// whatever was not there.
  ///
  /// Public because the MCP backend reads it too: a quote-reply is the one
  /// attachment whose payload has to be unpacked, and unpacking it twice is how
  /// the two backends would come to disagree about what a quote is.
  ///
  /// NEVER throws, and that is the whole reason it exists rather than a bare
  /// `jsonDecode` at the call site: `content` is a JSON string on the wire, so
  /// a tenant sending an empty one, a truncated one, or an object with only
  /// some of the keys would take a whole chat page down over one quote-reply.
  /// Whatever parses is kept and the rest reads null, which downstream is a
  /// quote block with a sender and no snippet, or none at all.
  static Map<String, Object?> quoteReferenceFields(Object? content) {
    Object? decoded;
    if (content is String && content.isNotEmpty) {
      try {
        decoded = jsonDecode(content);
      } on FormatException {
        decoded = null;
      }
    } else if (content is Map) {
      // A server that already decoded it for us — not Graph's shape, but the
      // field costs nothing to accept and refusing it would lose the quote.
      decoded = content;
    }
    if (decoded is! Map) {
      return const {
        'message_id': null,
        'message_sender': null,
        'message_preview': null,
      };
    }
    return {
      'message_id': _asText(decoded['messageId']),
      'message_sender': _quotedSenderName(decoded['messageSender']),
      'message_preview': _asText(decoded['messagePreview']),
    };
  }

  /// Who wrote the quoted message, as a name a reader would recognise.
  ///
  /// Two shapes are accepted because two are sent. Graph writes
  /// `messageSender` as an identity SET — `{user: {id, displayName}}`, the same
  /// shape `from` uses — while a server that has already flattened it sends the
  /// display name as a plain string. A `user` with no display name (a guest, a
  /// bot posting as an application) leaves the name null rather than showing an
  /// id: `teams:<guid>` is not a person's name.
  static String? _quotedSenderName(Object? sender) {
    if (sender is String) return sender.isEmpty ? null : sender;
    if (sender is! Map) return null;
    for (final key in const ['user', 'application', 'device']) {
      final identity = sender[key];
      if (identity is Map) {
        final name = _asText(identity['displayName']);
        if (name != null) return name;
      }
    }
    return _asText(sender['displayName']);
  }

  /// One JSON field as a non-empty string, whatever type it arrived as.
  static String? _asText(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }

  /// A message's body when it is HTML, and nothing when it is not.
  static String? _bodyHtml(Map<String, dynamic> message) {
    final body = message['body'];
    if (body is! Map) return null;
    if (body['contentType'] != 'html') return null;
    return body['content'] as String?;
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
  Future<http.Response> _send(Uri uri) => _request('GET', uri);

  /// One authenticated request of any method, under the retry policy above.
  ///
  /// [jsonBody] is encoded and sent with the JSON content type; omitting it
  /// sends no body at all. Shaped after graph_mail.dart's `_request` so the two
  /// files answer a throttle and a stale token the same way.
  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, dynamic>? jsonBody,
  }) async {
    var retriedThrottle = false;
    var retriedAuth = false;
    final body = jsonBody == null ? null : jsonEncode(jsonBody);

    while (true) {
      // Outside the try: an AuthException from here is not a transport
      // failure and must reach the caller as itself.
      final token = await _auth.getValidAccessToken();
      final headers = {
        'Authorization': 'Bearer $token',
        if (body != null) 'Content-Type': 'application/json',
      };

      final http.Response response;
      try {
        response = switch (method) {
          'POST' => await _http.post(uri, headers: headers, body: body),
          _ => await _http.get(uri, headers: headers),
        };
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
