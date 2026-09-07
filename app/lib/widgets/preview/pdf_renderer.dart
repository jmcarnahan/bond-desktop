/// The seam that keeps pdfium out of `flutter test`.
///
/// `flutter test` runs outside the app bundle, where the pdfium XCFramework is
/// not loaded: a widget that reached pdfrx would take the whole suite down the
/// moment a preview test pumped it. So nothing above this line names pdfrx.
/// `pdf_preview.dart` is the one file that implements these two interfaces, the
/// screen is the one place that constructs it, and a test hands over a fake
/// that answers with a `Container` and a list of strings.
///
/// No package imports beyond `dart:` and Flutter's widget layer, deliberately —
/// this file is the boundary, and an import here would defeat it.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// One open document, for the things a preview asks that are not the page
/// itself.
abstract interface class PdfPreviewDoc {
  /// One entry per page, in page order. A scanned page has no text layer and
  /// answers `''` rather than being left out — a reader counting pages down a
  /// document must find them where they are.
  Future<List<String>> pageTexts();

  /// Asynchronous because the engine's is: the native handle is freed on the
  /// worker that owns it, and a caller that did not wait would race its own
  /// next open.
  Future<void> dispose();
}

/// What can be done with a PDF's bytes.
abstract interface class PdfRenderer {
  Future<PdfPreviewDoc> open(Uint8List data, {required String sourceName});

  /// The scrolling page view the Preview segment shows. A `Widget` and not a
  /// picture: paging, zooming and text selection all belong to the engine, and
  /// re-implementing them over rendered images would be a worse viewer.
  Widget viewer(Uint8List data, {required String sourceName});
}
