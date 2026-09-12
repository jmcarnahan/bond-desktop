import Cocoa
import CryptoKit
import FlutterMacOS

/// The few questions only the operating system can answer.
///
/// The Dart side of this is `SystemInfo`
/// (`lib/services/system/system_info.dart`), which turns every failure below
/// into null, `false` or `HardwareInfo.unknown`. Nothing here throws across
/// the channel except as a `FlutterError`, and every code it sends is one
/// that seam already reads as "could not ask".
///
/// Everything on it is here for the first-run flow: how much memory this
/// machine has decides which models are offered, free space decides whether
/// they can be downloaded, the checksum decides whether a download is
/// trustworthy, and the activity token is what keeps App Nap from suspending
/// the app in the middle of either.
final class SystemChannel {
  /// Named for the bundle id, as every channel in this app is. Must match
  /// `ChannelSystemInfo.channel` exactly.
  private static let channelName = "com.bondinbox.app/system"

  /// Live `NSProcessInfo` activity assertions, keyed by the integer token
  /// handed back to Dart.
  ///
  /// A dictionary rather than a single optional because the download and the
  /// model load overlap: two independent reasons to stay awake, each ended by
  /// whoever began it. The counter never resets, so a token from a stale
  /// caller can never end somebody else's activity.
  private static var activities = [Int: NSObjectProtocol]()
  private static var nextActivityToken = 1

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "hardware":
        hardware(result)
      case "freeBytes":
        freeBytes(call, result)
      case "sha256":
        sha256(call, result)
      case "beginActivity":
        beginActivity(call, result)
      case "endActivity":
        endActivity(call, result)
      case "openNotificationSettings":
        openNotificationSettings(result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - hardware

  private static func hardware(_ result: FlutterResult) {
    result([
      "chip": sysctlString("machdep.cpu.brand_string") ?? "unknown",
      "memoryBytes": Int(sysctlInt("hw.memsize") ?? 0),
      "appleSilicon": (sysctlInt("hw.optional.arm64") ?? 0) == 1,
      // Not redundant with `appleSilicon`: this asks whether THIS PROCESS is
      // translated. An x86_64 build of the app on an Apple Silicon Mac gets
      // no Metal acceleration, and without this it would look like a fast
      // machine that is inexplicably slow.
      "rosetta": (sysctlInt("sysctl.proc_translated") ?? 0) == 1,
      "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
    ] as [String: Any])
  }

  /// Two calls, as `sysctlbyname` wants: one for the length, one for the
  /// bytes. A single guessed buffer would truncate a longer brand string on
  /// some machines and only there.
  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `UInt64` regardless of the key's own width: `hw.memsize` is 64-bit and
  /// the boolean-ish keys are not, and reading a 4-byte key into 8 bytes and
  /// masking is the portable way to get both without a per-key table.
  private static func sysctlInt(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    if sysctlbyname(name, &value, &size, nil, 0) == 0 {
      return size == MemoryLayout<UInt32>.size ? (value & 0xFFFF_FFFF) : value
    }
    return nil
  }

  // MARK: - freeBytes

  /// `volumeAvailableCapacityForImportantUsage`, not `volumeAvailableCapacity`.
  ///
  /// The plain capacity omits space macOS would purge to make room, so on a
  /// machine full of purgeable caches it under-reports by tens of gigabytes
  /// and would refuse a download that would in fact succeed.
  private static func freeBytes(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "freeBytes needs a path", details: nil))
      return
    }
    do {
      let values = try URL(fileURLWithPath: path)
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      if let capacity = values.volumeAvailableCapacityForImportantUsage {
        result(Int(capacity))
      } else {
        result(nil)
      }
    } catch {
      result(FlutterError(code: "free_bytes_failed", message: error.localizedDescription, details: nil))
    }
  }

  // MARK: - sha256

  /// Streamed in chunks and off the main thread, both for the same reason:
  /// the files this is asked about are model weights, several gigabytes each.
  /// Reading one into memory would double the app's footprint at exactly the
  /// moment it is tightest, and doing it on the main thread would freeze the
  /// window for the length of the hash.
  private static func sha256(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "sha256 needs a path", details: nil))
      return
    }
    DispatchQueue.global(qos: .utility).async {
      var handle: FileHandle?
      do {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        var hasher = SHA256()
        let chunk = 4 * 1024 * 1024
        while true {
          guard let data = try handle?.read(upToCount: chunk), !data.isEmpty else { break }
          hasher.update(data: data)
        }
        try handle?.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        // Every reply crosses back to the main thread: a FlutterResult called
        // from a background queue is undefined behaviour in the engine.
        DispatchQueue.main.async { result(digest) }
      } catch {
        try? handle?.close()
        DispatchQueue.main.async {
          result(FlutterError(code: "sha256_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // MARK: - activity

  /// `.idleSystemSleepDisabled` and not `.idleDisplaySleepDisabled`: the work
  /// this covers is a download or a model load, which wants the machine awake
  /// and has no reason to keep the screen lit.
  private static func beginActivity(_ call: FlutterMethodCall, _ result: FlutterResult) {
    let reason = (call.arguments as? [String: Any])?["reason"] as? String ?? "Bond Desktop"
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled],
      reason: reason
    )
    let token = nextActivityToken
    nextActivityToken += 1
    activities[token] = activity
    result(token)
  }

  private static func endActivity(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard let token = (call.arguments as? [String: Any])?["token"] as? Int,
          let activity = activities.removeValue(forKey: token)
    else {
      // An unknown token is not an error. It is a caller that already ended
      // this activity, or one holding a token from before a hot restart, and
      // there is nothing for either of them to do about it.
      result(nil)
      return
    }
    ProcessInfo.processInfo.endActivity(activity)
    result(nil)
  }

  // MARK: - notifications

  /// Two pane ids, newest first.
  ///
  /// `com.apple.Notifications-Settings.extension` is the System Settings pane
  /// of macOS 13 and later; this app's deployment target is 12.0, where that
  /// url opens nothing and `open` answers false. The second is the Monterey
  /// System Preferences pane, which is the whole reason a false answer is
  /// worth retrying rather than reporting — the caller shows a dead link
  /// otherwise.
  private static func openNotificationSettings(_ result: FlutterResult) {
    let candidates = [
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
      "x-apple.systempreferences:com.apple.preference.notifications",
    ]
    var opened = false
    for candidate in candidates {
      guard let url = URL(string: candidate) else { continue }
      opened = NSWorkspace.shared.open(url)
      if opened { break }
    }
    result(opened)
  }
}
