import Cocoa
import FlutterMacOS
import WebKit

/// A picture of an HTML attachment, drawn once and thrown away.
///
/// An HTML attachment is a phishing and credential-harvesting vector, so this
/// file is written as a refusal with a renderer inside it rather than as a
/// renderer with some settings. Every one of the following is load-bearing and
/// none of them is a preference:
///
/// - **No scripting.** `allowsContentJavaScript = false`, so a page cannot read
///   anything, time anything or rewrite itself between the load and the
///   snapshot.
/// - **No network.** A compiled `WKContentRuleList` blocks every URL for every
///   resource a page can ask for. A tracking pixel in a mailed page would
///   otherwise tell the sender the owner opened it, and this app is unsandboxed
///   with the network client entitlement — nothing else would stop it.
/// - **No navigation.** The delegate allows exactly one navigation action, the
///   `loadHTMLString` that starts it, and cancels every other. A meta refresh
///   or a scripted redirect has nowhere to go.
/// - **No origin.** `loadHTMLString(_, baseURL: nil)`, never `loadFileURL`. A
///   page loaded from a file URL can read sibling files; a page loaded from a
///   string has no origin to read anything from.
/// - **Nothing kept.** `.nonPersistent()` data store, so no cookie, cache entry
///   or local-storage row outlives the snapshot.
/// - **A deadline.** A page that has not finished in `timeout` resolves nil.
///   The Dart side treats nil as "no thumbnail" and the preview draws its glyph
///   card, so a slow page costs a picture and never a frame.
///
/// The Dart side is `lib/services/attachments/html_snapshot.dart`, and it turns
/// every failure below into null. Nothing here throws across the channel except
/// as a `FlutterError`, and every code it sends reads as "no thumbnail".
final class WebSnapshotChannel {
  /// Named for the bundle id, as every channel in this app is. Must match
  /// `htmlSnapshotChannel` in `html_snapshot.dart` exactly.
  private static let channelName = "com.bondinbox.app/websnapshot"

  /// How long a page gets. Generous for a self-contained report with no
  /// resources to wait on — it cannot fetch anything — and short enough that a
  /// pathological one does not sit on the only slot there is.
  private static let timeout: TimeInterval = 4

  /// The largest page worth drawing. Past this it is embedded data rather than
  /// a document, and the words of it are already in the store either way.
  private static let maxHtmlBytes = 8 * 1024 * 1024

  /// **One snapshot at a time**, and a second call is refused rather than
  /// queued. Each one owns a WKWebView and an offscreen window, a thumbnail is
  /// worth neither a queue nor several of those at once, and the caller's own
  /// fallback — a glyph card — is a perfectly good answer to "not now".
  private static var inFlight: WebSnapshot?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "snapshot":
        snapshot(call, result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func snapshot(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let html = args["html"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "snapshot needs html", details: nil))
      return
    }
    if html.utf8.count > maxHtmlBytes {
      result(FlutterError(code: "too_large", message: "page over the cap", details: nil))
      return
    }
    if inFlight != nil {
      result(FlutterError(code: "busy", message: "a snapshot is in flight", details: nil))
      return
    }

    let width = max(64, min(2048, (args["width"] as? NSNumber)?.doubleValue ?? 320))
    let height = max(64, min(2048, (args["height"] as? NSNumber)?.doubleValue ?? 240))
    let scale = max(1, min(3, (args["scale"] as? NSNumber)?.doubleValue ?? 2))

    let worker = WebSnapshot(
      html: html,
      size: CGSize(width: width, height: height),
      scale: scale,
      timeout: timeout
    )
    inFlight = worker
    worker.run { png in
      inFlight = nil
      guard let png else {
        result(FlutterError(code: "no_snapshot", message: "nothing was drawn", details: nil))
        return
      }
      result(FlutterStandardTypedData(bytes: png))
    }
  }
}

/// One page, one WKWebView, one answer, and then nothing.
///
/// A class per snapshot rather than a reused web view: a view that had already
/// loaded somebody else's page is a view with state in it, and the whole point
/// of the posture above is that a page gets to leave nothing behind.
private final class WebSnapshot: NSObject, WKNavigationDelegate {
  /// Block every URL, for every resource a page can ask for.
  ///
  /// The first rule blocks every subresource under any URL at all. The three
  /// after it cover the kinds that can carry a page somewhere or phone home —
  /// documents and frames, `fetch`, `ping`, `websocket`, `other` — and each is
  /// ANCHORED TO A SCHEME rather than matching `.*`.
  ///
  /// **Why anchored.** The main document of a `loadHTMLString` load is
  /// `about:blank`. A `.*` document rule would block the one load this class
  /// exists to draw and the snapshot would come back blank, which is a silent
  /// failure rather than a refusal. A scheme anchor matches everything a page
  /// could reach out to and nothing it was handed.
  ///
  /// **Why three rules and not one alternation.** WebKit's `url-filter` is a
  /// narrow regular expression dialect with NO DISJUNCTION: `^(https?|wss?|ftp):`
  /// is rejected with "Disjunctions are not supported yet", the whole list fails
  /// to compile, and — by the fail-closed rule below — every page would draw a
  /// glyph card and no thumbnail would ever appear again. Optional quantifiers
  /// are supported, so `https?` and `wss?` are each one filter.
  ///
  /// The navigation delegate still refuses navigation independently: a rule list
  /// is a resource filter and `decidePolicyFor` is a policy, and neither one
  /// alone covers both. If some WebKit does not know one of these resource types
  /// the compile fails, which `run` treats as no snapshot at all — the preview
  /// draws its glyph card, which is the safe direction to fail in.
  private static let blockEverything = """
  [
    {
      "trigger": {
        "url-filter": ".*",
        "resource-type": ["image", "style-sheet", "script", "font", "raw",
                          "svg-document", "media", "popup"]
      },
      "action": { "type": "block" }
    },
    {
      "trigger": {
        "url-filter": "^https?:",
        "resource-type": ["document", "fetch", "ping", "websocket", "other"]
      },
      "action": { "type": "block" }
    },
    {
      "trigger": {
        "url-filter": "^wss?:",
        "resource-type": ["document", "fetch", "ping", "websocket", "other"]
      },
      "action": { "type": "block" }
    },
    {
      "trigger": {
        "url-filter": "^ftp:",
        "resource-type": ["document", "fetch", "ping", "websocket", "other"]
      },
      "action": { "type": "block" }
    }
  ]
  """

  private let html: String
  private let size: CGSize
  private let scale: Double
  private let timeout: TimeInterval

  private var webView: WKWebView?
  private var window: NSWindow?

  /// Called exactly once. Nil here is what stops a second resolution — a
  /// timeout that fires while a snapshot is already being encoded would
  /// otherwise answer the channel twice, which is a crash.
  private var finish: ((Data?) -> Void)?

  /// Whether the one allowed navigation has been allowed.
  private var admittedLoad = false

  init(html: String, size: CGSize, scale: Double, timeout: TimeInterval) {
    self.html = html
    self.size = size
    self.scale = scale
    self.timeout = timeout
    super.init()
  }

  func run(_ done: @escaping (Data?) -> Void) {
    finish = done
    // Armed BEFORE the compile, not after the load: a rule list that never
    // compiles is a call that never comes back, and this is the only thing that
    // guarantees an answer.
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.settle(nil)
    }

    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.websiteDataStore = .nonPersistent()
    // One paint of a finished page rather than several of a partial one: there
    // is nothing to stream in, since nothing can be fetched.
    configuration.suppressesIncrementalRendering = true

    guard let store = WKContentRuleListStore.default() else {
      settle(nil)
      return
    }
    store.compileContentRuleList(
      forIdentifier: "bond-websnapshot-block-all",
      encodedContentRuleList: Self.blockEverything
    ) { [weak self] list, error in
      guard let self else { return }
      // FAIL CLOSED. A page rendered without the block list is a page that can
      // reach the network, and a missing thumbnail is a better outcome than
      // that.
      guard let list, error == nil else {
        self.settle(nil)
        return
      }
      configuration.userContentController.add(list)
      self.load(configuration)
    }
  }

  private func load(_ configuration: WKWebViewConfiguration) {
    // Already answered — the deadline fired while the rule list was compiling.
    guard finish != nil else { return }

    let frame = NSRect(origin: .zero, size: size)
    let view = WKWebView(frame: frame, configuration: configuration)
    view.navigationDelegate = self
    // A page is drawn on paper. Left transparent, a snapshot of black text on
    // nothing is black text on whatever the row is painted with.
    view.underPageBackgroundColor = .white
    webView = view

    // An offscreen window, far off any display and never ordered front: a
    // WKWebView with no window behind it can snapshot empty, and hosting it is
    // the reliable way to get a painted layer without anything appearing.
    let host = NSWindow(
      contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    host.isReleasedWhenClosed = false
    host.contentView?.addSubview(view)
    host.orderBack(nil)
    window = host

    // `baseURL: nil`, never `loadFileURL`: a page with no origin has no sibling
    // files to read and no cookie jar to be sent to.
    view.loadHTMLString(html, baseURL: nil)
  }

  // ── The navigation refusal ─────────────────────────────────────────────

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    // The `loadHTMLString` above is the first action and the only one allowed.
    // Everything after it — a meta refresh, a frame, a form the page submits
    // itself — is cancelled.
    if admittedLoad {
      decisionHandler(.cancel)
      return
    }
    admittedLoad = true
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // One turn of the run loop for the finished page to lay out. Snapshotting
    // inside `didFinish` catches some pages mid-layout and draws them empty.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.draw()
    }
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    settle(nil)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    settle(nil)
  }

  // ── The picture ────────────────────────────────────────────────────────

  private func draw() {
    guard finish != nil, let view = webView else { return }
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(origin: .zero, size: size)
    // The viewport in points, the bitmap at [scale] times that: a 320-point
    // card on a retina display wants 640 pixels across.
    configuration.snapshotWidth = NSNumber(value: size.width * scale)
    configuration.afterScreenUpdates = true
    view.takeSnapshot(with: configuration) { [weak self] image, _ in
      guard let self else { return }
      guard let image, let png = Self.png(of: image) else {
        self.settle(nil)
        return
      }
      self.settle(png)
    }
  }

  private static func png(of image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }

  /// The one answer, and the teardown behind it.
  ///
  /// The view and the window are dropped on a LATER turn of the run loop,
  /// because this is reached from inside the web view's own delegate callbacks
  /// and releasing a WKWebView from one of those is a crash. The closure holds
  /// them until then.
  private func settle(_ data: Data?) {
    guard let done = finish else { return }
    finish = nil

    let view = webView
    let host = window
    webView = nil
    window = nil
    DispatchQueue.main.async {
      view?.stopLoading()
      view?.navigationDelegate = nil
      view?.removeFromSuperview()
      host?.close()
    }

    done(data)
  }
}
