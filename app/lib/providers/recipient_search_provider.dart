import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/message_models.dart' show Conversation;
import '../models/person.dart';
import '../services/backend/auth_session.dart';
import '../services/backend/backend_types.dart';
import '../services/backend/people_backend.dart';
import 'app_providers.dart';

/// What one keystroke in the recipients field is worth showing.
///
/// The three lists stay APART rather than being concatenated: the field labels
/// them ("Recent", "Directory", "Chats") and a merged list would lose which
/// half of it can open a Teams chat. The two flags are the footer's whole
/// input — [scopeMissing] means the directory is not enabled for this account,
/// [directoryOffline] means it could not be reached this time — and neither is
/// an error the user has to do anything about.
typedef RecipientResults = ({
  List<Person> recents,
  List<Person> directory,
  List<Conversation> chats,
  bool directoryOffline,
  bool scopeMissing,
});

/// The recipients typeahead's whole read side: recents out of this database,
/// the directory out of the backend, existing chats for Teams, merged and
/// stripped of the user themselves.
///
/// **[search] never throws.** It is called from a widget's `optionsBuilder`,
/// which the SDK runs unawaited — an exception there escapes into the zone and
/// takes the frame with it, for a typeahead that could simply have shown one
/// list instead of two.
///
/// Debouncing is NOT here. The field owns the keystrokes and knows when the
/// user stopped typing; this class answers whatever it is asked.
class RecipientSearch {
  /// The bare scope that lets an account read the organization's directory.
  static const String _directoryScope = 'user.readbasic.all';

  final PeopleBackend _people;
  final MessageStore _store;
  final AuthSession _auth;
  final Future<String?> Function() _myUserId;

  /// How long the server's "scope missing" verdict is believed before the
  /// directory is asked again.
  ///
  /// Bounded rather than for the life of the instance, because the instance
  /// outlives the thing that changes the answer: a reconnect after the admin
  /// consents runs through the same session, and nothing rebuilds this
  /// provider for it. One refused request every few minutes is the price of
  /// the directory lighting up without a restart; a request per keystroke
  /// would be the price of not remembering at all.
  static const Duration scopeMissingTtl = Duration(minutes: 5);

  /// When the server last said the scope is missing; null when it has not,
  /// or when [resetScope] took the verdict back.
  DateTime? _scopeMissingAt;

  final DateTime Function() _now;

  /// The owner's own Graph id and address, learned once and kept. Both are
  /// round trips — a profile call and a keychain read — and neither can change
  /// without the session being rebuilt, which rebuilds this too.
  String? _ownerId;
  Future<String?>? _ownerIdInFlight;
  String? _ownerAddressKey;

  /// All four dependencies are positional, as everywhere else in this app that
  /// takes a backend and a store: a named parameter cannot be an initializing
  /// formal for a private field, and naming them anyway would trade a lint for
  /// nothing. [myUserId] is a callback rather than an id because resolving one
  /// is a round trip that most sessions never need. [clock] exists for the
  /// test that ages the scope verdict without waiting five minutes.
  RecipientSearch(
    this._people,
    this._store,
    this._auth,
    this._myUserId, {
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Whether the server's "scope missing" verdict is still being believed.
  bool get scopeMissing {
    final at = _scopeMissingAt;
    return at != null && _now().difference(at) < scopeMissingTtl;
  }

  /// Forgets that verdict, so the next search asks again. For a reconnect,
  /// which is the one event that can turn a refused scope into a granted one
  /// — sooner than [scopeMissingTtl] would on its own.
  void resetScope() => _scopeMissingAt = null;

  /// Everyone [query] could mean, on [channel].
  ///
  /// Recents come from ONE source, not both: a mail compose can only use an
  /// address and a chat can only be opened with a Graph id, so offering the
  /// other channel's people would be offering rows that cannot be sent to.
  /// The Teams half is filtered again on [Person.hasGraphId] for the same
  /// reason — a chat participant the roster stored without an id is a name
  /// with nothing behind it.
  Future<RecipientResults> search(
    String query, {
    required RecipientChannel channel,
    int limit = 8,
  }) async {
    final teams = channel == RecipientChannel.teams;

    var recents = await _recents(query, teams: teams, limit: limit);
    if (teams) {
      recents = [
        for (final person in recents)
          if (person.hasGraphId) person,
      ];
    }

    // The grant is read whether or not there is a query, so the footer says
    // the same thing on an empty field as on a full one. The SEARCH is what
    // the query gates: there is nothing to look up for a blank one.
    final granted = scopeMissing ? false : await _hasDirectoryScope();
    var directory = const <Person>[];
    var offline = false;
    if (granted && query.trim().isNotEmpty) {
      try {
        directory = await _people.searchPeople(query, top: 10);
      } on DirectoryUnavailable catch (e) {
        if (e.scopeMissing) {
          _scopeMissingAt = _now();
        } else {
          offline = true;
        }
      } catch (_) {
        // Auth failures included. They belong to whatever the user does next,
        // not to a list of names: routing to sign-in from a typeahead would
        // throw away everything they had typed.
        offline = true;
      }
    }

    final ownerId = await _resolveOwnerId();
    final ownerKey = await _resolveOwnerAddressKey();
    bool isOwner(Person person) =>
        (ownerId != null && person.id == ownerId) ||
        (ownerKey != null &&
            ownerKey.isNotEmpty &&
            person.addressKey == ownerKey);

    directory = [
      for (final person in directory)
        if (!isOwner(person)) person,
    ];

    // A directory hit REPLACES the recent naming the same person: both are
    // the same person, and only the directory one carries the job title that
    // tells two Sarahs apart. Same person means the same Graph id — how a
    // Teams recent, which has no address, is recognised — or the same address,
    // which is all a mail recent has. The recents keep their own order minus
    // what was taken.
    final claimedIds = {for (final person in directory) person.id};
    final claimedAddresses = {
      for (final person in directory)
        if (person.addressKey.isNotEmpty) person.addressKey,
    };
    recents = [
      for (final person in recents)
        if (!isOwner(person) &&
            !claimedIds.contains(person.id) &&
            !(person.addressKey.isNotEmpty &&
                claimedAddresses.contains(person.addressKey)))
          person,
    ];

    return (
      recents: recents,
      directory: directory,
      chats: teams ? await _chats(query, limit: limit) : const <Conversation>[],
      directoryOffline: offline,
      scopeMissing: scopeMissing || !granted,
    );
  }

  /// The store reads, guarded. A compose overlay that could not read its
  /// recents shows none; taking the screen down over it would be worse than
  /// the missing list.
  Future<List<Person>> _recents(
    String query, {
    required bool teams,
    required int limit,
  }) async {
    try {
      return await _store.recentPeople(
        query: query,
        limit: limit,
        source: teams ? 'teams' : 'email',
      );
    } catch (_) {
      return const [];
    }
  }

  Future<List<Conversation>> _chats(String query, {required int limit}) async {
    try {
      final chats = await _store.teamsChats(query: query);
      return chats.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _hasDirectoryScope() async {
    try {
      return await _auth.hasScope(_directoryScope);
    } catch (_) {
      // A grant that cannot be read is not a grant. Recents-only is the safe
      // side of this: the alternative is a request the server will refuse.
      return false;
    }
  }

  /// The owner's Graph id, asked for at most once at a time and remembered
  /// only when it arrives. A failed answer is NOT cached — the id matters
  /// (it is what keeps the user out of their own recipient list) and the call
  /// that failed was probably a connection that has since come back.
  Future<String?> _resolveOwnerId() async {
    final known = _ownerId;
    if (known != null) return known;

    final inFlight = _ownerIdInFlight ??= _myUserId();
    try {
      final id = await inFlight;
      if (id != null && id.isNotEmpty) _ownerId = id;
      return _ownerId;
    } catch (_) {
      return null;
    } finally {
      if (identical(_ownerIdInFlight, inFlight)) _ownerIdInFlight = null;
    }
  }

  Future<String?> _resolveOwnerAddressKey() async {
    final known = _ownerAddressKey;
    if (known != null) return known;
    try {
      final account = await _auth.storedAccount;
      final address = account?.mail ?? account?.userPrincipalName;
      if (address == null || address.isEmpty) return null;
      return _ownerAddressKey = address.trim().toLowerCase();
    } catch (_) {
      return null;
    }
  }
}

/// One search per session, rebuilt whenever the backend switch rebuilds the
/// providers under it. A reconnect within the session does NOT rebuild it —
/// the MCP session object is reused — which is why the scope verdict inside
/// expires on its own rather than lasting the instance's life.
final recipientSearchProvider = Provider<RecipientSearch>((ref) {
  final teams = ref.watch(teamsBackendProvider);
  return RecipientSearch(
    ref.watch(peopleBackendProvider),
    ref.watch(messageStoreProvider),
    ref.watch(authSessionProvider),
    // Swallowed here rather than inside the search: an account with no Teams
    // grant never answers this, and the owner filter has an address to fall
    // back on.
    () async {
      try {
        return await teams.myUserId();
      } catch (_) {
        return null;
      }
    },
  );
});
