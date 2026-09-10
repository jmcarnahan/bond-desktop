import Cocoa
// `proc_pidpath` and `kill` are C, and this is where they come from.
import Darwin
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The notification-center delegate must be in place before any toast can
    // route its tap back into Flutter. The plugin installs itself as that
    // delegate in its own `register(with:)`, which the generated registrant
    // runs from `MainFlutterWindow.awakeFromNib` — main-nib loading, and so
    // strictly before this method. This line therefore covers only the window
    // before that registration, and the case of an engine version whose
    // FlutterAppDelegate carries the conformance itself.
    //
    // The `if let` is load-bearing and not defensive style. `delegate` is a
    // settable weak optional, and today's FlutterAppDelegate conforms to
    // NSApplicationDelegate and FlutterAppLifecycleProvider only — so an
    // unconditional `= self as? UNUserNotificationCenterDelegate` would assign
    // nil and CLEAR the delegate the plugin just installed, silently killing
    // both tap routing and the frontmost presentation gate.
    if let delegate = self as? UNUserNotificationCenterDelegate {
      UNUserNotificationCenter.current().delegate = delegate
    }
    super.applicationDidFinishLaunching(notification)
  }

  /// Kills the model server this app started, on the way out.
  ///
  /// A child process on macOS is NOT reaped when its parent dies: quit the
  /// app with llama-server loaded and the server keeps running, keeps the
  /// port, and keeps several gigabytes of weights resident — so the next
  /// launch finds its own orphan in the way of the socket it wants.
  ///
  /// This is the SECOND of two places that kill it, and both are needed. The
  /// Dart side kills the child on its own exit path, but that path is not
  /// guaranteed to run: `flutter/flutter#134255` is an engine shutdown that
  /// skips the Dart exit hook entirely on macOS, and a force-quit skips
  /// everything above this method. The pid file is the handoff between them —
  /// whichever runs first removes it, and the other finds nothing to do.
  ///
  /// Nothing here is allowed to fail loudly. A missing or malformed pid file
  /// is the normal case (the server was never started, or Dart already
  /// cleaned up), and an app that crashed while quitting would be a far worse
  /// bug than a stray process.
  override func applicationWillTerminate(_ notification: Notification) {
    guard let bundleId = Bundle.main.bundleIdentifier,
          let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
          ).first
    else { return }
    let pidFile = support
      .appendingPathComponent(bundleId)
      .appendingPathComponent("servers")
      .appendingPathComponent("router.json")

    defer { try? FileManager.default.removeItem(at: pidFile) }

    guard let data = try? Data(contentsOf: pidFile),
          let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let pid = record["pid"] as? Int, pid > 0
    else { return }

    // The pid alone is not evidence. Numbers are reused within hours on a
    // machine that stays up, and signalling a stranger's process because the
    // kernel handed out the same integer would be unforgivable. The executable
    // path is what makes it checkable.
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(Int32(pid), &pathBuffer, UInt32(MAXPATHLEN)) > 0 else { return }
    let executable = String(cString: pathBuffer)
    guard executable.hasSuffix("llama-server") else { return }

    kill(Int32(pid), SIGTERM)
    // Up to two seconds of polling, in fiftieths. llama-server can be inside a
    // multi-gigabyte mmap when the signal lands and will not die politely; the
    // deadline is short because this is the quit path and the user is waiting.
    var waited = 0
    while waited < 40 {
      if kill(Int32(pid), 0) != 0 { return }
      usleep(50_000)
      waited += 1
    }
    kill(Int32(pid), SIGKILL)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
