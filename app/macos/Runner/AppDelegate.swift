import Cocoa
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

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
