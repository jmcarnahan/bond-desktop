import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // After the generated registrant, on the same engine's messenger: the
    // bookmark channel is this app's own Swift rather than a plugin, so
    // nothing registers it for us. It has to be up before the first frame —
    // the settings pane can ask to resolve a stored bookmark as soon as it
    // renders — and `awakeFromNib` is the earliest point at which a
    // messenger exists.
    BookmarkChannel.register(with: flutterViewController.engine.binaryMessenger)

    // Same messenger, same reason. The first-run flow asks what this machine
    // is before it draws its first choice, and the supervisor asks for an App
    // Nap assertion the moment it spawns the server — both of which can
    // happen before any user interaction.
    SystemChannel.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
