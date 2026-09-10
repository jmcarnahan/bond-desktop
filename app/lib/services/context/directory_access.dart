import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Keeping permission to read a folder after the panel that granted it has
/// closed.
///
/// The app is sandboxed with `files.user-selected` and nothing more, so a
/// directory the user picks in the open panel is readable for THAT LAUNCH
/// and then gone. A security-scoped bookmark is the one Apple-sanctioned way
/// to hold the grant across a relaunch without asking for a
/// Documents-folder entitlement the app would then keep forever.
///
/// An interface rather than a direct channel call because both pub packages
/// that used to wrap this are dead, the real implementation is Swift in the
/// Runner, and every test above wants a folder it can read with no platform
/// at all. [PlainDirectoryAccess] is that: it keeps no bookmark and resolves
/// none, and the reconcile handler's ladder is written so that answer means
/// "use the stored path if it is still readable".
abstract interface class DirectoryAccess {
  /// A security-scoped bookmark for [path], or null when this build keeps
  /// none.
  Future<Uint8List?> bookmark(String path);

  /// Resolves [bookmark] to a readable path and starts access; null when it
  /// cannot.
  Future<String?> resolve(Uint8List bookmark);
}

/// The seam with nothing behind it: no bookmark is made and none resolves.
///
/// What tests and any unsandboxed build take. Both answers are null rather
/// than a thrown "unsupported", because a caller's next step is identical
/// either way — fall back to the stored path, and say the directory is
/// unavailable only if THAT cannot be read.
class PlainDirectoryAccess implements DirectoryAccess {
  const PlainDirectoryAccess();

  @override
  Future<Uint8List?> bookmark(String path) async => null;

  @override
  Future<String?> resolve(Uint8List bookmark) async => null;
}

/// The real one: a method channel onto the Swift in the Runner.
class ChannelDirectoryAccess implements DirectoryAccess {
  const ChannelDirectoryAccess();

  /// Named for the bundle id, as every channel in this app is.
  static const MethodChannel channel =
      MethodChannel('com.bondinbox.app/bookmarks');

  /// Every failure is null, deliberately — including
  /// [MissingPluginException], which is what a `flutter test` binary with no
  /// Runner behind it raises.
  ///
  /// The caller's next step is the same for all of them: register the
  /// directory with no bookmark, read it while this launch lasts, and let
  /// the next launch find it unavailable and say so on the row. A thrown
  /// error here would turn "the sandbox declined" into a crash in the middle
  /// of picking a folder.
  @override
  Future<Uint8List?> bookmark(String path) async {
    try {
      return await channel.invokeMethod<Uint8List>('create', {'path': path});
    } on MissingPluginException {
      // No Runner: a test, or a platform with no channel registered.
      return null;
    } on PlatformException catch (e) {
      debugPrint('bookmarks: create failed for $path: ${e.code} ${e.message}');
      return null;
    }
  }

  /// Null covers every bad ending — no channel (`MissingPluginException`), a
  /// bookmark the system would not resolve at all (`resolve_failed`, which
  /// is a folder deleted or a bookmark it refused to renew), and a resource
  /// the sandbox resolved but declined to open (`access_denied`) — for
  /// [bookmark]'s reason.
  ///
  /// `access_denied` is the one worth naming: the Swift side answers a path
  /// only when this process holds access to it, so a null here means the
  /// reconcile pass falls back to the stored path, finds it unlistable, and
  /// marks the directory `unavailable` — which is the truth, and better than
  /// walking a folder that answers an error per file.
  @override
  Future<String?> resolve(Uint8List bookmark) async {
    try {
      return await channel.invokeMethod<String>(
        'resolve',
        {'bookmark': bookmark},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('bookmarks: resolve failed: ${e.code} ${e.message}');
      return null;
    }
  }
}
