import 'dart:convert';
import 'dart:typed_data';

import '../../models/person.dart';
import '../backend/backend_types.dart';
import '../backend/people_backend.dart';
import 'bond_mcp_client.dart';

/// The organization's directory, searched by asking the Bond MCP server rather
/// than Microsoft.
///
/// The server speaks snake_case; [Person.fromDirectoryJson] is where that is
/// read, so the Graph twin and this one hand their caller the same objects and
/// a switch between backends cannot change who the field offers.
///
/// Every failure this file can raise is a [DirectoryUnavailable] except the
/// auth ones, which pass through UNWRAPPED as they do from every other backend
/// here. That is the whole point of the type: the recipients field degrades to
/// recents and typed addresses on any of them, and the only thing it needs
/// back is whether asking again could ever work.

/// There is deliberately no status parse here, unlike its two sibling files. A
/// [DirectoryUnavailable] carries one bit — could this ever work again — and a
/// throttle, a 500 and a dropped socket all answer it the same way, so a
/// status code would be a number nothing reads.
class McpPeopleBackend implements PeopleBackend {
  /// What the server will accept for `top`. Clamping here rather than letting
  /// the server refuse keeps a caller's arithmetic from costing a round trip.
  static const int _minTop = 1;
  static const int _maxTop = 50;

  final BondMcpClient _mcp;

  McpPeopleBackend(this._mcp);

  /// People in the organization matching [query].
  ///
  /// The blank-query shortcut is here as well as on the server: the field asks
  /// on every keystroke, and the one that empties it must not cost a round
  /// trip to be told there is nothing to search for.
  ///
  /// `directory_scope_missing` is the answer this whole method exists to
  /// distinguish. The tenant has not granted `User.ReadBasic.All`, no retry
  /// will change that, and the caller stops asking for the session — while any
  /// OTHER error is a throttle or a server and is worth the next keystroke.
  /// Both are thrown rather than returned empty, because "nobody matched" and
  /// "the directory could not be reached" put different words on the screen.
  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final result = await _call('search_people', {
      'query': trimmed,
      'top': top.clamp(_minTop, _maxTop),
    });

    final error = result['error'];
    if (error != null) {
      throw DirectoryUnavailable(
        scopeMissing: error == 'directory_scope_missing',
        message: error == 'directory_scope_missing'
            ? 'Directory search is not enabled for this account.'
            : 'The directory could not be searched: $error',
      );
    }

    final people = result['people'];
    return [
      for (final entry in people is List ? people : const [])
        if (entry is Map)
          Person.fromDirectoryJson(Map<String, dynamic>.from(entry)),
    ].where(_showable).toList();
  }

  /// [user]'s profile photo, or null when there is nothing to draw.
  ///
  /// The tool is `get_profile` — the SAME published name the account header
  /// already reads, given its photo arguments. No new tool name enters this
  /// app for a picture.
  ///
  /// The split between null and a throw is the whole method. Everything that
  /// is a fact ABOUT THIS PERSON — no photo, not in the directory, an id Graph
  /// could not parse, an image too big or malformed — is null, because an
  /// avatar's fallback is initials and none of those is worth a second ask.
  /// `directory_scope_missing` is the one permanent failure, and every other
  /// error is a bad moment: both are thrown, so [ProfilePhotos] can stop
  /// asking for the session in the first case and retry in the second.
  @override
  Future<ProfilePhoto?> profilePhoto(String user, {String size = '96x96'}) async {
    final result = await _call('get_profile', {
      // Self sends no `user` key at all: that path needs only User.Read, and
      // naming yourself would put it behind the directory grant for nothing.
      if (user.trim().isNotEmpty) 'user': user,
      'photo': 'bytes',
      'photo_size': size,
    });

    final error = result['error'];
    if (error == 'directory_scope_missing') {
      throw const DirectoryUnavailable(
        scopeMissing: true,
        message: 'Profile photos are not enabled for this account.',
      );
    }
    if (error != null) {
      if (_aboutThisPerson.contains(error)) return null;
      throw DirectoryUnavailable(
        scopeMissing: false,
        message: 'The profile photo could not be read: $error',
      );
    }

    if (result['has_photo'] != true) return null;
    final encoded = result['content_base64'];
    if (encoded is! String || encoded.isEmpty) return null;

    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      // The server said there was a picture and sent something that is not
      // one. Initials, not an exception: nothing a retry would fix.
      return null;
    }

    final type = result['content_type'];
    return ProfilePhoto(
      bytes: bytes,
      contentType: type is String && type.isNotEmpty ? type : 'image/jpeg',
    );
  }

  /// The `get_profile` errors that describe the PERSON rather than the
  /// connection, and therefore answer null. Asking again returns the same
  /// thing for every one of them.
  static const Set<String> _aboutThisPerson = {
    'user_not_found',
    'invalid_arguments',
    'invalid_photo',
    'invalid_photo_size',
    'too_large',
  };

  /// Whether an entry names somebody the field could actually put on a
  /// message. An id-less entry cannot be stored or chatted with, and one with
  /// neither a name nor an address renders as an empty chip — both are noise
  /// from a directory this app does not control.
  static bool _showable(Person person) =>
      person.id.isNotEmpty &&
      (person.displayName.isNotEmpty || person.address.isNotEmpty);

  /// One tool call, with this file's whole error policy in it.
  ///
  /// `not_connected` arrives as a NORMAL result and means the one thing an
  /// interactive step can fix, so it becomes [ReconsentRequired]. Only the two
  /// MCP types are caught: an [AuthException] raised while the client fetches
  /// its bearer is not a directory failure and must reach the caller as
  /// itself.
  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, Object?> args,
  ) async {
    final Map<String, dynamic> result;
    try {
      result = await _mcp.callTool(tool, args);
    } on McpToolException catch (e) {
      throw DirectoryUnavailable(scopeMissing: false, message: e.message);
    } on McpTransportException catch (e) {
      throw DirectoryUnavailable(scopeMissing: false, message: e.message);
    }
    if (result['error'] == 'not_connected') throw const ReconsentRequired();
    return result;
  }
}
