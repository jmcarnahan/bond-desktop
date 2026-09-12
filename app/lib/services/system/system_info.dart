import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter/services.dart';

/// What this machine is, as far as choosing and running models goes.
///
/// Only the facts a decision hangs on. [memoryBytes] is what says whether a
/// twenty-seven-billion-parameter model fits at all; [appleSilicon] is what
/// says whether there is a Metal backend to use; [rosetta] is the one that
/// looks redundant and is not — an arm64 Mac running an x86_64 build of this
/// app gets no Metal acceleration and would otherwise look like a fast
/// machine that is mysteriously slow.
///
/// [appleSilicon] and [rosetta] are the macOS shape of "can this machine run
/// the models"; the Windows shape of the same question is x64 plus a Vulkan
/// device, and it is described in `dist/windows/README.md` → Setup wizard on
/// Windows.
@immutable
class HardwareInfo {
  final String chip;
  final int memoryBytes;
  final bool appleSilicon;
  final bool rosetta;
  final String osVersion;

  const HardwareInfo({
    required this.chip,
    required this.memoryBytes,
    required this.appleSilicon,
    required this.rosetta,
    required this.osVersion,
  });

  /// The answer when there is no platform to ask — a `flutter test` binary,
  /// or a channel that is not registered.
  ///
  /// `appleSilicon: true` and `memoryBytes: 0` are chosen so a caller that
  /// gates on them degrades the useful way: nothing is refused for being on
  /// the wrong architecture, and a size check against zero bytes fails loudly
  /// rather than passing silently.
  static const HardwareInfo unknown = HardwareInfo(
    chip: 'unknown',
    memoryBytes: 0,
    appleSilicon: true,
    rosetta: false,
    osVersion: '',
  );

  @override
  bool operator ==(Object other) =>
      other is HardwareInfo &&
      other.chip == chip &&
      other.memoryBytes == memoryBytes &&
      other.appleSilicon == appleSilicon &&
      other.rosetta == rosetta &&
      other.osVersion == osVersion;

  @override
  int get hashCode =>
      Object.hash(chip, memoryBytes, appleSilicon, rosetta, osVersion);

  @override
  String toString() => 'HardwareInfo($chip, ${memoryBytes}B, '
      'appleSilicon: $appleSilicon, rosetta: $rosetta, os: $osVersion)';
}

/// The handful of things only the platform can answer.
///
/// One interface rather than four, because everything on it is the same kind
/// of question — asked of the operating system, answered by Swift in the
/// Runner, and needed by the first-run flow. Splitting them would mean four
/// channels and four fakes for six methods.
abstract interface class SystemInfo {
  Future<HardwareInfo> hardware();

  /// Free space on the volume holding [path], or null when it cannot be
  /// asked. Used before a download that is measured in gigabytes.
  Future<int?> freeBytes(String path);

  /// The sha256 of a file, hex — Phase 3 checks downloaded weights with it.
  ///
  /// On the platform side rather than in Dart because the files are several
  /// gigabytes: streaming them through the isolate that draws the UI would
  /// stall it for the length of the hash.
  Future<String?> sha256(String path);

  /// Tells the system this app is doing something the user asked for, so App
  /// Nap does not suspend it mid-download or mid-model-load. Null when no
  /// activity could be started; pair a non-null token with [endActivity].
  Future<int?> beginActivity(String reason);

  Future<void> endActivity(int token);

  /// Opens the Notifications pane of System Settings.
  Future<bool> openNotificationSettings();
}

/// The real one: a method channel onto the Swift in the Runner.
///
/// NOTHING HERE THROWS, for `ChannelDirectoryAccess`'s reason: the callers
/// are a first-run screen and a supervisor, and every failure has a sensible
/// null answer they already handle. A `MissingPluginException` in particular
/// is just what a `flutter test` binary raises, and it must not turn a
/// hardware readout into a crash.
class ChannelSystemInfo implements SystemInfo {
  const ChannelSystemInfo();

  /// Named for the bundle id, as every channel in this app is. Must match
  /// `SystemChannel.channelName` in the Runner exactly.
  static const MethodChannel channel = MethodChannel('com.bondinbox.app/system');

  @override
  Future<HardwareInfo> hardware() async {
    try {
      final map = await channel.invokeMapMethod<String, Object?>('hardware');
      if (map == null) return HardwareInfo.unknown;
      return HardwareInfo(
        chip: map['chip'] as String? ?? 'unknown',
        memoryBytes: (map['memoryBytes'] as num?)?.toInt() ?? 0,
        appleSilicon: map['appleSilicon'] as bool? ?? true,
        rosetta: map['rosetta'] as bool? ?? false,
        osVersion: map['osVersion'] as String? ?? '',
      );
    } on MissingPluginException {
      return HardwareInfo.unknown;
    } on PlatformException catch (e) {
      debugPrint('system: hardware failed: ${e.code} ${e.message}');
      return HardwareInfo.unknown;
    }
  }

  @override
  Future<int?> freeBytes(String path) async {
    try {
      final value = await channel.invokeMethod<int>('freeBytes', {'path': path});
      return value;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('system: freeBytes failed for $path: ${e.code} ${e.message}');
      return null;
    }
  }

  @override
  Future<String?> sha256(String path) async {
    try {
      return await channel.invokeMethod<String>('sha256', {'path': path});
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('system: sha256 failed for $path: ${e.code} ${e.message}');
      return null;
    }
  }

  @override
  Future<int?> beginActivity(String reason) async {
    try {
      return await channel
          .invokeMethod<int>('beginActivity', {'reason': reason});
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('system: beginActivity failed: ${e.code} ${e.message}');
      return null;
    }
  }

  @override
  Future<void> endActivity(int token) async {
    try {
      await channel.invokeMethod<void>('endActivity', {'token': token});
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      // Worth a line: an activity that is never ended keeps the machine from
      // idling, which is a battery complaint nobody would trace back here.
      debugPrint('system: endActivity failed: ${e.code} ${e.message}');
    }
  }

  @override
  Future<bool> openNotificationSettings() async {
    try {
      return await channel.invokeMethod<bool>('openNotificationSettings') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint(
          'system: openNotificationSettings failed: ${e.code} ${e.message}');
      return false;
    }
  }
}

/// The seam with nothing behind it — what tests and any headless build take.
///
/// Every answer is the "could not ask" answer rather than a thrown
/// "unsupported", because a caller's next step is identical either way.
class NullSystemInfo implements SystemInfo {
  const NullSystemInfo();

  @override
  Future<HardwareInfo> hardware() async => HardwareInfo.unknown;

  @override
  Future<int?> freeBytes(String path) async => null;

  @override
  Future<String?> sha256(String path) async => null;

  @override
  Future<int?> beginActivity(String reason) async => null;

  @override
  Future<void> endActivity(int token) async {}

  @override
  Future<bool> openNotificationSettings() async => false;
}
