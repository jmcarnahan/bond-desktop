import 'package:flutter/foundation.dart' show debugPrint;

import '../backend/backend_types.dart';
import '../backend/teams_backend.dart';
import '../graph_teams.dart';
import 'bond_mcp_client.dart';

/// The Teams chat reads, made by asking the Bond MCP server rather than
/// Microsoft. Nothing here touches sqlite — [TeamsSync] owns the writes.
///
/// **Nothing here may be called from a timer.** Microsoft's terms for the Teams
/// messaging endpoints forbid background polling, and moving the request to a
/// server changes nothing about that: the calls are still made with the user's
/// delegated consent. [TeamsSync] is the only caller and it enforces it.
///
/// The throttle floors are kept here too, for the same reason — the ToU
/// discipline is ours whichever transport carries the request — and they are
/// [GraphTeams]'s own constants rather than a second pair that could drift.
///
/// The server speaks snake_case and a FLAT message shape; `teams_sync.dart`
/// reads Graph's nested one. Every method therefore RESHAPES, and the reshape
/// is the contract: the two backends must be indistinguishable to their
/// caller, or a switch between them silently changes what gets stored.

/// The HTTP status inside a tool's failure text, when it names one. A private
/// copy of the one in `mcp_mail_backend.dart` — see the note there.
final RegExp _graphStatus = RegExp(r'Graph API error\s+(\d{3})');

int? _statusFromToolError(String message) {
  final match = _graphStatus.firstMatch(message);
  return match == null ? null : int.tryParse(match.group(1)!);
}

class McpTeamsBackend implements TeamsBackend {
  /// Chats per page. The messages page size is the server's to choose.
  static const int _pageSize = 50;

  final BondMcpClient _mcp;

  /// The two throttle floors, injectable so a throttle test does not have to
  /// spend a real second per chat. Production never passes either.
  final Duration _chatListGap;
  final Duration _sameChatGap;

  /// When the last chat-list page was requested, and when each chat was last
  /// touched. Per instance, because the throttle is about this client's own
  /// traffic — and the provider makes sure there is one instance per session.
  DateTime? _lastChatListAt;
  final Map<String, DateTime> _lastChatAt = {};

  /// The signed-in user's id, held for this instance's life.
  ///
  /// [GraphTeams] re-fetches it per sync because a Graph `/me` is one cheap
  /// call; here it is a round trip through the platform, and the id cannot
  /// change without the session being rebuilt.
  String? _myUserId;

  McpTeamsBackend(
    this._mcp, {
    Duration chatListGap = GraphTeams.defaultChatListGap,
    Duration sameChatGap = GraphTeams.defaultSameChatGap,
  })  : _chatListGap = chatListGap,
        _sameChatGap = sameChatGap;

  @override
  Future<String> myUserId() async {
    final cached = _myUserId;
    if (cached != null) return cached;

    final profile = await _call('get_profile_json', const {});
    final id = profile['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const GraphTeamsException(
        'The Bond server returned a profile with no id.',
      );
    }
    return _myUserId = id;
  }

  /// Every chat the user is in, newest activity first, across at most
  /// [maxPages] pages.
  ///
  /// The preview timestamp is reshaped into the object `TeamsSync` reads,
  /// because that is what lets it skip a chat without fetching its messages at
  /// all. A chat with no preview keeps a NULL preview rather than an empty
  /// object: "nothing known" is what makes the sync fetch it, and an empty
  /// object would read as a timestamp it could compare.
  @override
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4}) async {
    final chats = <Map<String, dynamic>>[];
    String? cursor = '';

    for (var page = 0; page < maxPages && cursor != null; page++) {
      await _throttleChatList();
      final result = await _call('list_chats_page', {
        'cursor': cursor,
        'top': _pageSize,
      });
      final raw = result['chats'];
      for (final chat in raw is List ? raw : const []) {
        if (chat is Map) chats.add(_chatShape(chat));
      }
      cursor = _emptyToNull(result['next_cursor']);
    }
    return chats;
  }

  /// One chat's members — enough to name the thread and its participants.
  ///
  /// One call, no paging, exactly as the Graph backend does it: this runs once
  /// per chat the app has never seen, and a group chat large enough to page has
  /// a name of its own anyway.
  @override
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) async {
    await _throttleChat(chatId);
    final result = await _call('get_chat_members_json', {'chat_id': chatId});
    final raw = result['members'];
    return [
      for (final member in raw is List ? raw : const [])
        if (member is Map)
          {
            'displayName': member['display_name'],
            'userId': member['user_id'],
          },
    ];
  }

  /// One chat's messages, newest first, back to [sinceIso].
  ///
  /// The rules are [GraphTeams]'s, held to line for line because they are what
  /// make the sync correct rather than merely working:
  ///
  /// - a null or empty [sinceIso] takes exactly ONE page and sends no cursor. A
  ///   chat the app has never seen starts from its newest messages; reaching
  ///   further back would spend requests on history the user has already read.
  /// - with a cursor the walk runs until the filtered set is exhausted, because
  ///   the caller advances its own cursor to the newest message returned — a
  ///   page cap that stopped early would advance it over messages never
  ///   fetched, which is a permanent hole in the transcript. [maxPages] is a
  ///   runaway bound only, and hitting it is logged because it means exactly
  ///   such a hole.
  /// - a page whose OLDEST message is at or before the cursor ends the walk.
  @override
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  }) async {
    final messages = <Map<String, dynamic>>[];
    final firstRun = sinceIso == null || sinceIso.isEmpty;
    final pages = firstRun ? 1 : maxPages;
    String? cursor = '';

    for (var page = 0; page < pages && cursor != null; page++) {
      await _throttleChat(chatId);
      final result = await _call('list_chat_messages_page', {
        'chat_id': chatId,
        'since': firstRun ? '' : sinceIso,
        'cursor': cursor,
      });
      final raw = result['messages'];
      final reshaped = [
        for (final message in raw is List ? raw : const [])
          if (message is Map) _messageShape(message),
      ];
      messages.addAll(reshaped);

      // An early stop is the walk finishing, not a hole: everything newer than
      // the cursor is already in hand. Dropping the cursor here is what keeps
      // it out of the warning below.
      if (!firstRun && _reachedCursor(reshaped, sinceIso)) {
        cursor = null;
        break;
      }
      cursor = _emptyToNull(result['next_cursor']);
    }

    if (cursor != null && !firstRun) {
      debugPrint(
        'McpTeamsBackend: chat $chatId had more than $maxPages pages of new '
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

  static Map<String, dynamic> _chatShape(Map chat) {
    final previewAt = chat['last_preview_at'];
    return {
      'id': chat['id'],
      'topic': chat['topic'],
      'lastMessagePreview':
          previewAt == null ? null : {'createdDateTime': previewAt},
    };
  }

  /// One flat wire message as the nested object `TeamsSync._sender` and
  /// `_bodyText` read.
  ///
  /// `from` is rebuilt in the order the reader tests it: a user, else an
  /// application, else absent entirely — a system event arrives with neither
  /// and must not be handed a `from` object with nulls inside, which would read
  /// as a person with no name. A bot's display name is null because the wire
  /// carries no `from_application_display`; the reader tolerates that, and a
  /// bot message is gated out of extraction either way.
  static Map<String, dynamic> _messageShape(Map message) {
    final userId = message['from_user_id'];
    final applicationId = message['from_application_id'];
    return {
      'id': message['id'],
      'messageType': message['message_type'],
      'createdDateTime': message['created'],
      'lastModifiedDateTime': message['last_modified'],
      'body': {
        'contentType': message['body_content_type'],
        'content': message['body_content'],
      },
      'from': switch ((userId, applicationId)) {
        (null, null) => null,
        (null, _) => {
            'application': {'id': applicationId, 'displayName': null},
          },
        _ => {
            'user': {'id': userId, 'displayName': message['from_user_display']},
          },
      },
    };
  }

  /// Waits out whatever is left of the gap since the last chat-list page.
  Future<void> _throttleChatList() async {
    final wait = _remaining(_lastChatListAt, _chatListGap);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastChatListAt = DateTime.now();
  }

  /// Waits out whatever is left of the gap since this chat was last touched.
  /// Per chat, not global: two different chats are two different conversations
  /// as far as the throttle is concerned.
  Future<void> _throttleChat(String chatId) async {
    final wait = _remaining(_lastChatAt[chatId], _sameChatGap);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastChatAt[chatId] = DateTime.now();
  }

  static Duration _remaining(DateTime? last, Duration gap) {
    if (last == null) return Duration.zero;
    return gap - DateTime.now().difference(last);
  }

  /// One tool call, with this file's whole error policy in it.
  ///
  /// `not_connected` arrives as a NORMAL result and means the one thing an
  /// interactive step can fix, so it becomes [ReconsentRequired]. Only the two
  /// MCP types are caught: an [AuthException] raised while the client fetches
  /// its bearer is not a Teams failure and must reach the caller as itself.
  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, Object?> args,
  ) async {
    final Map<String, dynamic> result;
    try {
      result = await _mcp.callTool(tool, args);
    } on McpToolException catch (e) {
      throw GraphTeamsException(e.message, _statusFromToolError(e.message));
    } on McpTransportException catch (e) {
      throw GraphTeamsException(e.message, e.statusCode);
    }
    if (result['error'] == 'not_connected') throw const ReconsentRequired();
    return result;
  }

  static String? _emptyToNull(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;
}
