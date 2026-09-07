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
