/// THE pdfrx gatekeeper: the only file in the app allowed to import it.
///
/// Everything else — the panel, the row's thumbnails, the screen — talks to
/// [PdfRenderer] and [PdfThumbnailer] next door, which is what keeps pdfium
/// out of `flutter test`. The rule is not stylistic: the native library is
/// loaded from the app bundle, a test process has no bundle, and a single
/// import reaching this file from a widget would fail every preview test with
/// a missing symbol rather than an assertion anybody could read.
///
/// The discipline `local_desktop_notifier.dart` keeps over the notifications
/// plugin and `file_dialogs.dart` over `file_selector`, applied to the one
/// dependency in this app that ships a binary.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../theme/tokens.dart';
import 'pdf_renderer.dart';

/// Loads pdfium, once, at startup.
///
/// Called from `main.dart` immediately after `ensureInitialized()` so that the
/// first document a person opens does not pay the load on the UI thread — and
/// so that `main.dart` is not a second import site for pdfrx. The thumbnail
/// path opens a document before any pdfrx widget exists, so waiting for the
/// viewer to initialise it would be too late.
Future<void> initPdfEngine() => pdfrxFlutterInitialize();

/// The real renderer. `const` so the screen can hold one without a field.
class PdfrxRenderer implements PdfRenderer {
  const PdfrxRenderer();

  @override
  Future<PdfPreviewDoc> open(Uint8List data, {required String sourceName}) async {
    return _PdfrxDoc(await PdfDocument.openData(data, sourceName: sourceName));
  }

  @override
  Widget viewer(Uint8List data, {required String sourceName}) => PdfViewer.data(
        data,
        sourceName: sourceName,
        params: const PdfViewerParams(
          backgroundColor: BondColors.previewGround,
        ),
      );
}

class _PdfrxDoc implements PdfPreviewDoc {
  final PdfDocument _doc;

  _PdfrxDoc(this._doc);

  @override
  int get pageCount => _doc.pages.length;

  @override
  Future<List<String>> pageTexts() async {
    final texts = <String>[];
    for (final page in _doc.pages) {
      // Null is a page whose text layer has not loaded — progressive loading,
      // or a scan with no layer at all. Both are an empty page to a reader,
      // and neither is worth failing the whole document over.
      texts.add((await page.loadText())?.fullText ?? '');
    }
    return texts;
  }

  @override
  Future<void> dispose() => _doc.dispose();
}

/// The first page of a PDF as a small PNG, or null.
///
/// Shaped to [PdfThumbnailer] in `services/attachments/attachment_bytes.dart`
/// — that typedef exists precisely so the bytes ladder can ask for this
/// without importing this file. `main.dart` hands this function over at
/// startup and nothing else does, which is why a test never draws one.
///
/// **Every failure is null.** This runs off a row rendering, where a throw
/// would take out the transcript around it, and a document with no picture is
/// simply a chip with a glyph on it.
Future<Uint8List?> pdfPageOnePng(Uint8List bytes, {int maxWidth = 320}) async {
  PdfDocument? doc;
  PdfImage? rendered;
  ui.Image? image;
  try {
    doc = await PdfDocument.openData(bytes, sourceName: 'thumb');
    if (doc.pages.isEmpty) return null;
    final page = doc.pages.first;
    if (page.width <= 0 || page.height <= 0) return null;

    rendered = await page.render(
      fullWidth: maxWidth.toDouble(),
      fullHeight: maxWidth * page.height / page.width,
      // A page is drawn on paper. Left transparent, a thumbnail of black text
      // on nothing is black text on whatever the row is painted with.
      backgroundColor: 0xFFFFFFFF,
    );
    if (rendered == null) return null;

    image = await rendered.createImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } on Object catch (e) {
    debugPrint('pdf thumbnail failed: $e');
    return null;
  } finally {
    // In this order: the raster buffer, then the picture made from it, then
    // the document that owns the page both came from.
    rendered?.dispose();
    image?.dispose();
    await doc?.dispose();
  }
}

/// The Preview segment for a PDF: whatever the renderer answers, under one
/// key.
///
/// A widget of its own rather than a call at the panel's build site so that a
/// test can find the page view without knowing what the engine builds — and so
/// that the panel names [PdfRenderer] and never pdfrx.
class PdfPreview extends StatelessWidget {
  final Uint8List bytes;
  final String sourceName;
  final PdfRenderer renderer;

  const PdfPreview({
    super.key,
    required this.bytes,
    required this.sourceName,
    required this.renderer,
  });

  static const Key viewerKey = ValueKey('pdf-preview-viewer');

  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: viewerKey,
        child: renderer.viewer(bytes, sourceName: sourceName),
      );
}
