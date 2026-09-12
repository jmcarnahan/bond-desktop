import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle, reduced to the three questions the About pane asks.
///
/// The Dart side is `Updater` (`lib/services/system/updater.dart`); the update
/// window itself is Sparkle's own and is the one non-Flutter surface in the
/// app. That is deliberate — the no-dialogs house rule is a rule about Flutter
/// screens (`test/no_dialogs_test.dart` scans `lib/`), and reimplementing an
/// installer's progress and restart in Flutter would buy nothing but risk.
///
/// **Why the updater is started by hand.** `SPUStandardUpdaterController`'s
/// `startingUpdater: true` (and `startUpdater()`) start it and, when the app is
/// misconfigured, log an error AND put an alert in front of the user a few
/// seconds later telling them to contact the developer. A `flutter run` build
/// is misconfigured by construction: the four `SU*` keys below are written into
/// `Info.plist` by `dist/bundle.sh` at package time and exist in no development
/// build. So the controller is created with `startingUpdater: false`, started
/// with the throwing call, and a failure is KEPT as a sentence rather than
/// shown — the About pane says updates are not configured in this build, which
/// is the true and unalarming version of the same fact.
///
/// The keys `dist/bundle.sh` writes, none of which live in the Xcode project:
/// `SUFeedURL` (the appcast), `SUPublicEDKey` (the EdDSA key every update is
/// verified against), `SUEnableAutomaticChecks` and `SUScheduledCheckInterval`.
final class UpdaterChannel {
  /// Named for the bundle id, as every channel in this app is. Must match
  /// `ChannelUpdater.channel` in Dart exactly.
  private static let channelName = "com.bondinbox.app/updater"

  /// Held for the process's lifetime: the controller owns the scheduler and
  /// the user driver, and letting it deallocate would cancel both.
  private static var controller: SPUStandardUpdaterController?

  /// Why the updater could not start, or nil when it did. A dev build has no
  /// SUFeedURL/SUPublicEDKey (dist/bundle.sh writes them) and lands here.
  private static var startError: String?

  static func register(with messenger: FlutterBinaryMessenger) {
    let controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    do {
      try controller.updater.start()
    } catch {
      startError = error.localizedDescription
    }
    self.controller = controller

    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        status(result)
      case "checkForUpdates":
        checkForUpdates(result)
      case "setAutomaticChecks":
        setAutomaticChecks(call, result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - status

  /// Everything the About pane draws from, in one round trip. The optional
  /// keys are OMITTED rather than sent as null: the Dart side reads a missing
  /// `lastCheck` as "never checked", and a null would have to mean the same
  /// thing twice.
  private static func status(_ result: FlutterResult) {
    guard let updater = controller?.updater, startError == nil else {
      result([
        "available": false,
        "automatic": false,
        // The only failure worth a sentence, and it is Sparkle's own.
        "error": startError ?? "The updater did not start.",
      ] as [String: Any])
      return
    }

    var payload: [String: Any] = [
      "available": true,
      // Sparkle owns this preference — it is stored in the app's user
      // defaults by the updater, not by this app — so it is always READ from
      // the updater rather than mirrored anywhere.
      "automatic": updater.automaticallyChecksForUpdates,
    ]
    if let last = updater.lastUpdateCheckDate {
      // Seconds since the epoch: the one representation a Dart `DateTime` and
      // an ObjC `NSDate` both read the same way with no formatter in between.
      payload["lastCheck"] = last.timeIntervalSince1970
    }
    result(payload)
  }

  // MARK: - commands

  /// Opens Sparkle's own check. Everything after this — "you're up to date",
  /// the release notes, the download, the relaunch — is Sparkle's window.
  private static func checkForUpdates(_ result: FlutterResult) {
    guard let updater = controller?.updater, startError == nil else {
      result(FlutterError(code: "unavailable", message: startError, details: nil))
      return
    }
    // A second check while one is already in progress is a no-op inside
    // Sparkle (`checkForUpdates` "does not do anything if there is a
    // sessionInProgress"), so the button needs no greying of its own.
    updater.checkForUpdates()
    result(nil)
  }

  private static func setAutomaticChecks(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard let on = call.arguments as? Bool else {
      result(FlutterError(
        code: "bad_args",
        message: "setAutomaticChecks takes a bool",
        details: nil
      ))
      return
    }
    guard let updater = controller?.updater, startError == nil else {
      result(FlutterError(code: "unavailable", message: startError, details: nil))
      return
    }
    updater.automaticallyChecksForUpdates = on
    result(nil)
  }
}
