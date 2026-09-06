import 'dart:typed_data';

import 'package:bond_inbox/widgets/preview/pdf_renderer.dart';
import 'package:flutter/material.dart';

/// A PDF engine that never touches pdfium.
///
/// The whole reason [PdfRenderer] exists: `flutter test` runs outside the app
/// bundle, where the native library is not loaded, so no test may construct
/// `PdfrxRenderer`. This answers with a plain `Container` and a list of
/// strings, and counts the opens so a test can pin that the document a text
/// extraction opened was also closed.
class FakePdfRenderer implements PdfRenderer {
  /// What [PdfPreviewDoc.pageTexts] answers, one entry per page.
  final List<String> pages;

  /// What [viewer] draws. Null builds the keyed placeholder below, which is
  /// what a test finds when it wants to know "the page view is on screen".
  final Widget? view;

  FakePdfRenderer({this.pages = const ['page one'], this.view});

  static const Key viewerKey = ValueKey('fake-pdf-viewer');

  int openCalls = 0;
  int disposeCalls = 0;

  /// What the last [open] was told the document is called.
  String? lastSourceName;

  /// What the last [viewer] was told, and the bytes it was handed. Both exist
  /// so a test can pin that the panel passed the file through unchanged.
  String? lastViewerSourceName;
  Uint8List? lastViewerBytes;

  @override
  Future<PdfPreviewDoc> open(
    Uint8List data, {
    required String sourceName,
  }) async {
    openCalls++;
    lastSourceName = sourceName;
    return _FakeDoc(this);
  }

  @override
  Widget viewer(Uint8List data, {required String sourceName}) {
    lastViewerSourceName = sourceName;
    lastViewerBytes = data;
    return view ?? Container(key: viewerKey);
  }
}

class _FakeDoc implements PdfPreviewDoc {
  final FakePdfRenderer _renderer;

  _FakeDoc(this._renderer);

  @override
  int get pageCount => _renderer.pages.length;

  @override
  Future<List<String>> pageTexts() async => _renderer.pages;

  @override
  Future<void> dispose() async => _renderer.disposeCalls++;
}
