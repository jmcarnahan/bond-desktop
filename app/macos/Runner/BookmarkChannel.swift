import Cocoa
import FlutterMacOS

/// Remembering which folder the user picked, across relaunches.
///
/// This channel was written for a sandboxed app, where a directory picked in
/// the open panel is readable for THAT LAUNCH and then gone, and a
/// security-scoped bookmark is the one Apple-sanctioned way to hold the grant
/// across a relaunch. The app is UNSANDBOXED now (see Release.entitlements),
/// so there is no grant to hold: a path the user picked is simply readable.
///
/// The channel stays because the bookmark is still the durable, rename-proof
/// handle to a folder — it survives the user moving or renaming it, which a
/// stored path does not. What changed is `resolve`: a security scope that
/// cannot be entered is no longer an error, because there is no longer a
/// scope to enter.
///
/// The Dart side of this is `DirectoryAccess`
/// (`lib/services/context/directory_access.dart`), which turns every failure
/// below into null. Nothing here throws across the channel except as a
/// `FlutterError`, and every code it sends is one that seam already reads as
/// "no bookmark": the caller falls back to the stored path and marks the
/// directory unavailable only if that cannot be read either.
final class BookmarkChannel {
  /// Named for the bundle id, as every channel in this app is. Must match
  /// `ChannelDirectoryAccess.channel` exactly.
  private static let channelName = "com.bondinbox.app/bookmarks"

  /// The URLs whose security scope this process has entered, held for the
  /// LIFETIME of the process and deliberately never balanced with a
  /// `stopAccessingSecurityScopedResource`. Unsandboxed this map stays
  /// empty, because no scope is ever successfully entered; the reasoning
  /// below is what governs whenever one is.
  ///
  /// The access is not a single read: the reconcile walk lists the tree, the
  /// extractors open every changed file, and a later draft may read one again
  /// minutes afterwards. Scoping the access to any one of those would revoke
  /// it under the next. A handful of retained folder URLs is the whole cost,
  /// and they are dropped when the app quits.
  ///
  /// Keyed by PATH, and checked before any start: `resolve` runs on every
  /// reconcile pass — once a minute per directory — and each unbalanced
  /// `startAccessing…` on a fresh URL object leaks a kernel resource until,
  /// after enough of them, the sandbox refuses every file. One start per
  /// path for the life of the process is the whole budget.
  private static var accessed = [String: URL]()

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "create":
        create(call, result)
      case "resolve":
        resolve(call, result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// A bookmark for a path the user has just picked in the open panel.
  ///
  /// Taken immediately after the panel and never later: the sandbox's grant
  /// is on that pick, and `bookmarkData` outside it is the error below rather
  /// than a bookmark that quietly resolves to nothing.
  private static func create(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "create needs a path", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    do {
      let data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      result(FlutterStandardTypedData(bytes: data))
    } catch {
      result(FlutterError(
        code: "bookmark_failed",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  /// The path a stored bookmark points at, with this process's access to it
  /// already started.
  ///
  /// A STALE bookmark still answers with its path. Stale means the system
  /// wants the bookmark re-made — the folder was moved or renamed, or the app
  /// was re-signed — not that the resolved URL is wrong, and the resolve
  /// above has already granted access to it. The app re-creates the bookmark
  /// the next time the user adds that directory; refusing the read in the
  /// meantime would take a working folder away over bookkeeping. It is
  /// logged, because "the bookmark wants re-making" is the fact behind a
  /// folder that starts failing after an update.
  ///
  /// A security scope that will not start is NOT an error any more. Under the
  /// sandbox it meant the folder needed picking again, and refusing was the
  /// honest answer. Unsandboxed it means only that there was no scope to
  /// enter, and the resolved path is readable regardless — so the path is
  /// what comes back.
  private static func resolve(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let data = args["bookmark"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "bad_args", message: "resolve needs a bookmark", details: nil))
      return
    }
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data.data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      if stale {
        NSLog("bookmarks: the bookmark for %@ is stale and wants re-making", url.path)
      }
      if accessed[url.path] == nil {
        // A false return here is the NORMAL answer now that the app is
        // unsandboxed: there is no scope to enter, so nothing grants one.
        // The plain path is readable, and refusing it would take away a
        // working folder over a permission that no longer applies. Only a
        // successful start is recorded, so the unbalanced-access budget
        // described above is unchanged.
        if url.startAccessingSecurityScopedResource() {
          accessed[url.path] = url
        }
      }
      result(url.path)
    } catch {
      result(FlutterError(
        code: "resolve_failed",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }
}
