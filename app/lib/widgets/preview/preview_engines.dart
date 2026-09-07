/// The two engines a preview needs, in one bag the screen fills in.
///
/// There is deliberately NO `PreviewEngines.system()` factory here: naming the
/// real PDF renderer would make this file import `pdf_preview.dart`, and every
/// widget that takes a [PreviewEngines] would then drag pdfium into
/// `flutter test`. The screen builds the real pair lazily, behind a nullable
/// prop a test overrides, and this file stays importable from anywhere.
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../services/attachments/xlsx_reader.dart';
import 'pdf_renderer.dart';

@immutable
class PreviewEngines {
  final PdfRenderer pdf;
  final WorkbookDecoder workbook;

  const PreviewEngines({required this.pdf, required this.workbook});
}
