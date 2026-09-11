import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter/services.dart';

/// What the updater has to say for itself, as the About section draws it.
///
/// [available] is the one that decides whether the section shows any update
/// control at all. It is false in every `flutter run` build, because the four
/// `SU*` keys Sparkle needs are written into `Info.plist` by `dist/bundle.sh`
/// at package time and exist nowhere else —
/// so "off" here is the ordinary case for a developer and a fact about the
/// build rather than a fault.
///
/// [automatic] and [lastCheck] are SPARKLE'S answers, re-read rather than
/// mirrored: Sparkle owns the preference and the timestamp, and a local copy
/// would be the thing that goes stale when an update installs itself.
@immutable
class UpdaterStatus {
  final bool available;
  final bool automatic;
  final DateTime? lastCheck;

  /// Why updates are off in this build, when [available] is false.
  final String? unavailableReason;

  const UpdaterStatus({
    required this.available,
    required this.automatic,
    this.lastCheck,
    this.unavailableReason,
  });

  /// The answer when nobody is on the other end of the channel (a test, a
  /// build without the Sparkle keys).
  static const UpdaterStatus unavailable = UpdaterStatus(
    available: false,
    automatic: false,
    unavailableReason: 'Updates are not configured in this build.',
  );

  @override
  bool operator ==(Object other) =>
      other is UpdaterStatus &&
      other.available == available &&
      other.automatic == automatic &&
      other.lastCheck == lastCheck &&
      other.unavailableReason == unavailableReason;

  @override
  int get hashCode =>
      Object.hash(available, automatic, lastCheck, unavailableReason);

  @override
  String toString() => 'UpdaterStatus(available: $available, '
      'automatic: $automatic, lastCheck: $lastCheck, '
      'unavailableReason: $unavailableReason)';
}

/// The three things the About section can ask of the updater.
///
/// Deliberately not an interface over Sparkle: everything Sparkle does after
/// [checkForUpdates] — the release notes, the download, the relaunch — happens
/// in Sparkle's own window, and there is nothing for Dart to drive.
abstract interface class Updater {
  Future<UpdaterStatus> status();

  /// Opens Sparkle's check. Returns as soon as it is asked for; the window
  /// that follows is the platform's.
  Future<void> checkForUpdates();

  Future<void> setAutomaticChecks(bool on);
}

/// The real one: a method channel onto `UpdaterChannel` in the Runner.
///
/// NOTHING HERE THROWS, for [ChannelSystemInfo]'s reason — the caller is a
/// settings pane, and every failure has a sensible "no updates here" answer it
/// already renders. A `MissingPluginException` in particular is just what a
/// plain `flutter test` binary raises (a widget test's fake-async zone never
/// delivers the reply at all), and it must not turn opening Settings into a
/// crash.
class ChannelUpdater implements Updater {
  const ChannelUpdater();

  /// Named for the bundle id, as every channel in this app is. Must match
  /// `UpdaterChannel.channelName` in the Runner exactly.
  static const MethodChannel channel =
      MethodChannel('com.bondinbox.app/updater');

  @override
  Future<UpdaterStatus> status() async {
    try {
      final map = await channel.invokeMapMethod<String, Object?>('status');
      if (map == null) return UpdaterStatus.unavailable;
      final available = map['available'] as bool? ?? false;
      final reason = map['error'] as String?;
      // Seconds since the epoch on the wire, because that is the one number an
      // NSDate and a DateTime both read the same way. The key is ABSENT when
      // nothing has ever been checked, which is what 'never checked' reads
      // from — a null and a missing key mean the same thing here.
      final seconds = (map['lastCheck'] as num?)?.toDouble();
      return UpdaterStatus(
        available: available,
        automatic: map['automatic'] as bool? ?? false,
        lastCheck: seconds == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (seconds * 1000).round(),
                isUtc: true,
              ),
        // A platform that says "unavailable" without saying why still gets a
        // sentence: the section renders one or none, and none would leave a
        // reader with a missing button and no explanation.
        unavailableReason: available
            ? null
            : reason ?? UpdaterStatus.unavailable.unavailableReason,
      );
    } on MissingPluginException {
      return UpdaterStatus.unavailable;
    } on PlatformException catch (e) {
      debugPrint('updater: status failed: ${e.code} ${e.message}');
      return UpdaterStatus.unavailable;
    }
  }

  @override
  Future<void> checkForUpdates() async {
    try {
      await channel.invokeMethod<void>('checkForUpdates');
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      debugPrint('updater: checkForUpdates failed: ${e.code} ${e.message}');
    }
  }

  @override
  Future<void> setAutomaticChecks(bool on) async {
    try {
      await channel.invokeMethod<void>('setAutomaticChecks', on);
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      debugPrint('updater: setAutomaticChecks failed: ${e.code} ${e.message}');
    }
  }
}

/// The seam with nothing behind it — what tests and any headless build take.
class NullUpdater implements Updater {
  const NullUpdater();

  @override
  Future<UpdaterStatus> status() async => UpdaterStatus.unavailable;

  @override
  Future<void> checkForUpdates() async {}

  @override
  Future<void> setAutomaticChecks(bool on) async {}
}
