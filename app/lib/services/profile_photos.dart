import 'dart:async';

import 'package:flutter/widgets.dart' show ImageProvider, MemoryImage;

import 'backend/backend_types.dart';
import 'backend/people_backend.dart';

/// Where an avatar gets its face.
///
/// A seam rather than a call, for the reason every widget-facing service here
/// is one: an avatar is drawn in a transcript, a typeahead row and a rail, and
/// none of those may know whether this app is talking to Graph, to the Bond
/// server, or — in every widget test — to nobody at all. [NoProfilePhotos] is
/// the answer for that last case, and it is the DEFAULT everywhere a photo
/// service is optional, so a test that never asked for faces never gets a
/// network call it did not write.
///
/// Null is the ordinary answer. Most people a mailbox knows about are outside
/// the tenant and have no photo Graph will serve, so an avatar's real
/// behaviour is initials with a picture sometimes arriving after a frame —
/// never a spinner, never an error.

/// The face-supplying seam. See the library doc above.
abstract interface class ProfilePhotos {
  /// The photo already in hand for [key], so a first paint needs no frame of
  /// initials. Null when it has not been fetched yet, is still being fetched,
  /// or is known absent — all three draw the same thing.
  ImageProvider? cached(String key);

  /// The photo for [key], fetched at most once per key per session.
  ///
  /// NEVER throws: a widget calls this from `initState` with nobody to catch
  /// for it, and every failure a directory can have ends at the same initials.
  /// Null means initials.
  Future<ImageProvider?> photoFor(String key);
}

/// No faces at all: every key is null and nothing is ever asked.
///
/// The default for tests and for widgets built without a service. Const, so a
/// widget can name it in a default parameter.
class NoProfilePhotos implements ProfilePhotos {
  const NoProfilePhotos();

  @override
  ImageProvider? cached(String key) => null;

  @override
  Future<ImageProvider?> photoFor(String key) async => null;
}

/// The prefix on an id this app invented for somebody Microsoft gave none —
/// see `models/person.dart`, which mints it. There is no photo behind one.
const String _mailIdPrefix = 'mail:';

/// The prefix the stored rows spell a Teams participant with. What follows it
/// is a Graph user id, which is exactly what a photo is asked for by.
const String _teamsAddressPrefix = 'teams:';

/// The key [ProfilePhotos] holds a person under, from whatever the caller
/// knows about them.
///
/// One function rather than a rule each call site repeats, because the same
/// person reaches the avatar three ways — as a directory hit with a Graph id,
/// as a `teams:<id>` address on a stored message, and as a plain mail address
/// — and two of those spellings must land on ONE cache entry or the same face
/// is fetched twice and drawn from two providers.
///
/// A Graph id wins when there is one, since it is the only spelling the photo
/// endpoint can look a stranger up by. A `mail:` id is this app's own
/// invention and is ignored in favour of the address inside it. Null means
/// nothing usable was given, and nothing will be asked for.
String? photoKeyFor({String? address, String? id}) {
  final rawId = (id ?? '').trim();
  if (rawId.isNotEmpty && !rawId.startsWith(_mailIdPrefix)) return rawId;

  final rawAddress = (address ?? '').trim();
  if (rawAddress.isEmpty) return null;
  if (rawAddress.toLowerCase().startsWith(_teamsAddressPrefix)) {
    final graphId = rawAddress.substring(_teamsAddressPrefix.length).trim();
    return graphId.isEmpty ? null : graphId;
  }
  return rawAddress.toLowerCase();
}

/// Faces from the directory, fetched once each and kept for the session.
///
/// In MEMORY only this round. A disk cache is a follow-up: these are 96×96
/// thumbnails of a few kilobytes each and a mailbox has tens of correspondents,
/// so a session's worth costs less than one attachment — while a cache on disk
/// is a file format, an eviction rule and a staleness question that a first
/// round of avatars does not need to answer.
///
/// Negative results are cached as hard as positive ones, and that is the point:
/// most senders are outside the tenant, so "this person has no photo" is the
/// common answer and re-asking it on every rebuild would spend the session
/// making calls that can only come back null.
///
/// A scope failure is terminal for the session. `User.ReadBasic.All` is granted
/// once by an administrator, so a tenant that refuses it now refuses it until
/// somebody consents and the app reconnects — and an avatar grid asking a
/// hundred times for the same refusal is the one thing this class must not do.
/// Every other failure leaves the key unmemoised, so the next widget that needs
/// that face tries again.
class DirectoryProfilePhotos implements ProfilePhotos {
  final PeopleBackend _backend;

  /// Whether faces may be asked for at all. Awaited ONCE — a signed-out app
  /// must not put a directory call behind every avatar it draws, and the
  /// answer cannot change without the provider graph rebuilding this object.
  final Future<bool> Function() enabled;

  /// How many photo calls may be open at once. A transcript can mount thirty
  /// avatars in one frame, and thirty simultaneous Graph calls is how a
  /// session earns a 429 that costs it every later face too.
  final int maxInFlight;

  /// The Graph size the photos are asked at. One of Graph's fixed set; 96 is
  /// twice the biggest avatar drawn, so a retina screen has pixels to spare.
  final String size;

  DirectoryProfilePhotos(
    this._backend, {
    required this.enabled,
    this.maxInFlight = 4,
    this.size = '96x96',
  });

  /// Settled answers, positive and negative. A key present with a null value
  /// is a person known to have no face.
  final Map<String, ImageProvider?> _settled = {};

  /// Fetches still running, so three avatars for one sender make one call.
  /// A key leaves this map the moment its future completes: a settled answer
  /// lives in [_settled], and a failed one must be askable again.
  final Map<String, Future<ImageProvider?>> _running = {};

  /// Asks parked on the in-flight cap, oldest first.
  final List<Completer<void>> _waiting = [];
  int _open = 0;

  Future<bool>? _enabledOnce;

  /// Set by the one failure no retry can fix.
  bool _scopeRefused = false;

  @override
  ImageProvider? cached(String key) => _settled[key];

  @override
  Future<ImageProvider?> photoFor(String key) {
    if (_settled.containsKey(key)) return Future.value(_settled[key]);

    final existing = _running[key];
    if (existing != null) return existing;

    final future = _fetch(key);
    _running[key] = future;
    // Cleared on completion rather than inside [_fetch], so the entry is
    // removed strictly after it was added however early the body finishes.
    unawaited(future.whenComplete(() {
      if (identical(_running[key], future)) _running.remove(key);
    }));
    return future;
  }

  Future<ImageProvider?> _fetch(String key) async {
    try {
      if (_scopeRefused) return _remember(key, null);
      if (!await (_enabledOnce ??= enabled())) return _remember(key, null);

      await _acquire();
      final ProfilePhoto? photo;
      try {
        photo = await _backend.profilePhoto(key, size: size);
      } finally {
        _release();
      }
      return _remember(key, photo == null ? null : MemoryImage(photo.bytes));
    } on DirectoryUnavailable catch (e) {
      if (e.scopeMissing) {
        // Nothing this session can do changes the answer, for this key or any
        // other. Stop asking rather than spend a call per avatar.
        _scopeRefused = true;
        return _remember(key, null);
      }
      return null;
    } catch (_) {
      // A throttle, a dropped socket, an expired sign-in. Initials now, and
      // the key stays unmemoised so the next ask tries again.
      return null;
    }
  }

  ImageProvider? _remember(String key, ImageProvider? image) {
    _settled[key] = image;
    return image;
  }

  /// Takes one of the [maxInFlight] slots, waiting in line when they are all
  /// taken.
  Future<void> _acquire() {
    if (_open < maxInFlight) {
      _open++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  /// Hands the slot straight to whoever has waited longest, and only gives it
  /// back to the pool when nobody has.
  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _open--;
  }
}
