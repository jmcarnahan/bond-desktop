import 'dart:typed_data';

import 'package:bond_inbox/widgets/preview/pdf_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_pdf_renderer.dart';

/// The page view is whatever the renderer answers — and NO test in this file,
/// or any other, constructs `PdfrxRenderer`. Importing this library is safe;
/// building the real renderer would load pdfium, which a test process has no
/// bundle to load it from.
Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(height: 400, child: child)));

void main() {
  testWidgets('the page view is what the renderer answers', (tester) async {
    await tester.pumpWidget(_host(PdfPreview(
      bytes: Uint8List.fromList([1, 2, 3]),
      sourceName: 'Terms.pdf',
      renderer: FakePdfRenderer(),
    )));

    expect(find.byKey(PdfPreview.viewerKey), findsOneWidget);
    expect(find.byKey(FakePdfRenderer.viewerKey), findsOneWidget);
  });

  testWidgets('the bytes and the name go through untouched', (tester) async {
    final renderer = FakePdfRenderer();
    final bytes = Uint8List.fromList([1, 2, 3]);
    await tester.pumpWidget(_host(PdfPreview(
      bytes: bytes,
      sourceName: 'Terms.pdf',
      renderer: renderer,
    )));

    expect(renderer.lastViewerSourceName, 'Terms.pdf');
    // The same instance, not a copy: `PdfViewer` keys its cache on the bytes it
    // was handed, and a copy per rebuild would re-parse the document.
    expect(identical(renderer.lastViewerBytes, bytes), isTrue);
  });

  testWidgets('a document with no page view still keeps its key',
      (tester) async {
    await tester.pumpWidget(_host(PdfPreview(
      bytes: Uint8List.fromList([1]),
      sourceName: 'Empty.pdf',
      renderer: FakePdfRenderer(view: const SizedBox()),
    )));

    expect(find.byKey(PdfPreview.viewerKey), findsOneWidget);
  });
}
