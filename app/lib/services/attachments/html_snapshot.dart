/// A picture of a web page, drawn by the Runner's own WebKit and nothing else.
///
/// The Swift behind this channel (`macos/Runner/WebSnapshotChannel.swift`) is
/// where the whole security posture lives — scripting off, a non-persistent
/// data store, a rule list that blocks every resource the page asks for, a
/// navigation delegate that cancels every navigation, and a hard timeout. This
/// side is deliberately thin: it hands over a string and takes back PNG bytes.
///
/// **Every failure is null**, including the absence of the channel itself. A
/// `flutter test` binary has no Runner behind it and neither does any host that
/// is not this macOS app, so the default answer is "no thumbnail" and the
/// preview draws its glyph card instead. That is also why nothing here logs a
/// missing plugin: under the test binary it is the ordinary case, not a fault.
///
/// The discipline `DirectoryAccess` keeps over the bookmark channel and
/// `SystemInfo` over the system one, applied to the one thing in this app that
/// renders somebody else's HTML.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// Named for the bundle id, as every channel in this app is. Must match
/// `WebSnapshotChannel.channelName` exactly.
const MethodChannel htmlSnapshotChannel =
    MethodChannel('com.bondinbox.app/websnapshot');

/// [html] rendered at [width]×[height] logical points, as PNG bytes, or null.
///
/// Shaped to `HtmlThumbnailer` in `attachment_bytes.dart` — that typedef is
/// what lets the bytes ladder ask for this while a test hands it a closure.
///
/// [scale] is the backing-store multiplier: two draws a retina-sharp picture of
/// the same viewport, which is what a 320-point-wide thumbnail wants on the
/// only display this app ships on.
Future<Uint8List?> htmlSnapshotPng(
  String html, {
  int width = 320,
  int height = 240,
  int scale = 2,
}) async {
  if (html.trim().isEmpty) return null;
  try {
    return await htmlSnapshotChannel.invokeMethod<Uint8List>('snapshot', {
      'html': html,
      'width': width,
      'height': height,
      'scale': scale,
    });
  } on MissingPluginException {
    // No Runner: a test, or a platform with no channel registered.
    return null;
  } on PlatformException catch (e) {
    // A timeout, a page WebKit would not render, a second call while one was
    // already in flight. All of them are a chip with a glyph on it.
    debugPrint('websnapshot: ${e.code} ${e.message}');
    return null;
  }
}
