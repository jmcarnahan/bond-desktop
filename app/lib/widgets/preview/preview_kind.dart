/// What a preview would have to be, for one attachment.
///
/// One question asked in one place, because three widgets ask it and would
/// otherwise each answer it slightly differently: the panel picks which body to
/// build, the row decides whether a file could ever have a picture, and the
/// bytes ladder decides whether to fetch anything at all.
///
/// **The name is read before the content type**, the same rule
/// `attachmentGlyph` follows and for the same reason: Graph reports
/// `application/octet-stream` for a great many real documents, and a preview
/// that believed it would show a spreadsheet as a hex dump. The connector's
/// `kind` is the last resort, because it is the coarsest thing either
/// connector says.
///
/// No package imports — this is a pure function over a model, tested without
/// pumping a widget.
library;

import '../../models/attachment_models.dart';
import '../attachment_format.dart';

/// The shapes a preview comes in. Not file types: `unsupported` is the honest
/// answer for a `.heic` (an image Flutter cannot decode) and for a `.xls` (a
/// spreadsheet in a binary format nothing here reads), and both of those are
/// better said than half-drawn.
enum PreviewKind { image, pdf, sheet, text, document, eml, link, unsupported }

/// Kinds that are a POINTER to a file rather than a file, and are therefore
/// never fetched: the preview offers the link out instead.
const Set<String> _linkKinds = {'reference', 'card', 'message_reference'};

/// Which body the panel would build for [ref].
PreviewKind previewKindFor(AttachmentRef ref) {
  if (_linkKinds.contains(ref.kind)) return PreviewKind.link;
  // A forwarded message is a message whatever it is called — the connector
  // states this one outright, so it outranks even the name.
  if (ref.kind == 'item') return PreviewKind.eml;

  final byName = _kindForExtension(extensionOf(ref.name));
  if (byName != null) return byName;
  return _kindForContentType(ref.contentType) ?? PreviewKind.unsupported;
}

/// Whether this file's words should be set in the mono face.
///
/// Structured text — a csv, a log, a config — is read in columns, and a
/// proportional face throws those columns away. Prose is not.
bool monoForName(String? name) => const {
      'csv',
      'tsv',
      'json',
      'xml',
      'yaml',
      'yml',
      'log',
      'ini',
    }.contains(extensionOf(name));

PreviewKind? _kindForExtension(String extension) {
  if (extension.isEmpty) return null;
  return switch (extension) {
    'eml' || 'msg' => PreviewKind.eml,
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => PreviewKind.image,
    // Images, and not drawable ones: Flutter decodes neither, and a broken
    // picture frame says less than a line naming the file.
    'heic' || 'heif' || 'tiff' || 'tif' => PreviewKind.unsupported,
    'pdf' => PreviewKind.pdf,
    'xlsx' || 'xlsm' => PreviewKind.sheet,
    // The legacy binary workbook. `xlsx_reader.dart` reads a zip of XML and
    // this is not one.
    'xls' => PreviewKind.unsupported,
    'csv' ||
    'txt' ||
    'json' ||
    'md' ||
    'log' ||
    'yaml' ||
    'yml' ||
    'xml' ||
    'ini' ||
    'tsv' =>
      PreviewKind.text,
    // Read through the server's extracted words rather than rendered: nothing
    // in this app lays out a Word document, and the text is what a person
    // wanted from it anyway.
    'docx' || 'pptx' => PreviewKind.document,
    _ => null,
  };
}

PreviewKind? _kindForContentType(String? contentType) {
  final type = contentType?.split(';').first.trim().toLowerCase() ?? '';
  if (type.isEmpty) return null;
  if (type == 'message/rfc822') return PreviewKind.eml;
  if (const {
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/gif',
    'image/webp',
    'image/bmp',
  }.contains(type)) {
    return PreviewKind.image;
  }
  if (type == 'application/pdf') return PreviewKind.pdf;
  if (type ==
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') {
    return PreviewKind.sheet;
  }
  if (type.startsWith('text/')) return PreviewKind.text;
  if (type ==
          'application/vnd.openxmlformats-officedocument.'
              'wordprocessingml.document' ||
      type ==
          'application/vnd.openxmlformats-officedocument.'
              'presentationml.presentation') {
    return PreviewKind.document;
  }
  return null;
}
