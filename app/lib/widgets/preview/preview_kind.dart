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

import 'dart:convert';
import 'dart:typed_data';

import '../../models/attachment_models.dart';
import '../attachment_format.dart';

/// The shapes a preview comes in. Not file types: `unsupported` is the honest
/// answer for a `.heic` (an image Flutter cannot decode) and for a `.xls` (a
/// spreadsheet in a binary format nothing here reads), and both of those are
/// better said than half-drawn.
///
/// `html` is a page, and it is its own kind rather than `text` because the two
/// readings are different things: markup shown as text is `<table` and inline
/// CSS, while the words in it are a report somebody wrote. The kind carries a
/// picture of the page and the way out to a browser as well, neither of which
/// a `.txt` has anywhere to put.
enum PreviewKind {
  image,
  pdf,
  sheet,
  text,
  document,
  eml,
  link,
  html,
  unsupported,
}

/// Kinds that point at something that is NOT a file — a card is a rendering of
/// a message, a `message_reference` a quote of one — and are therefore never
/// fetched: the preview offers the link out instead.
///
/// A `reference` is not one of them. A mail link is a real file kept on a
/// drive, and it previews like any other file once its name or its type says
/// what it is.
const Set<String> _linkKinds = {'card', 'message_reference'};

/// Which body the panel would build for [ref].
PreviewKind previewKindFor(AttachmentRef ref) {
  if (_linkKinds.contains(ref.kind)) return PreviewKind.link;
  // A forwarded message is a message whatever it is called — the connector
  // states this one outright, so it outranks even the name.
  if (ref.kind == 'item') return PreviewKind.eml;

  final byName = _kindForExtension(extensionOf(ref.name));
  if (byName != null) return byName;
  final byType = _kindForContentType(ref.contentType);
  if (byType != null) return byType;
  // A link nothing could name still has somewhere to go: an extensionless
  // SharePoint url with no content type is shown as the link it came as,
  // rather than as a file this app has decided it cannot draw.
  return ref.kind == 'reference' ? PreviewKind.link : PreviewKind.unsupported;
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
      'url',
      'webloc',
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
    // Before the text list below, because a page IS text by content type and
    // reading it as one would show the reader the markup instead of the report.
    'html' || 'htm' || 'xhtml' => PreviewKind.html,
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
    // An Internet shortcut is a few lines of text naming a web address — the
    // INI `URL=` of Windows, the plist `URL` key of macOS — whatever its type
    // says. Gmail labels its Drive-link shortcut `application/pdf`, and those
    // bytes handed to the PDF viewer were a red error box filling the panel.
    'url' || 'webloc' => PreviewKind.text,
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
  // BEFORE the `text/` prefix rule below, which would otherwise swallow it:
  // `text/html` is the one text type whose bytes are not the words in it.
  if (type == 'text/html' || type == 'application/xhtml+xml') {
    return PreviewKind.html;
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

/// Extensions the operating system would RUN rather than show.
///
/// Executables and installers are obvious. Scripts are the same thing with a
/// different first line — macOS "opens" a `.command` by handing it to Terminal.
/// Disk images and archives-that-mount get in because opening one puts a
/// stranger's volume on the desktop with an application inside it. Macro
/// documents run code the moment Office opens them. Web pages are here for a
/// quieter reason: a page opened from a `file:` origin is a page the user
/// believes came from their mail, and it can ask them for a password.
const Set<String> _executableExtensions = {
  'exe', 'msi', 'com', 'scr', 'bat', 'cmd', 'ps1', 'vbs', 'vbe', 'js', 'jse',
  'wsf', 'wsh', 'sh', 'bash', 'zsh', 'command', 'tool', 'terminal', 'app',
  'action', 'workflow', 'pkg', 'mpkg', 'dmg', 'iso', 'jar', 'scpt', 'scptd',
  'applescript', 'py', 'rb', 'pl', 'php', 'url', 'webloc', 'lnk', 'reg',
  'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm', 'potm', 'ppam',
  'html', 'htm', 'xhtml', 'svg',
};

/// The same answer said by content type, for the connector that names a file
/// better than its sender did.
const Set<String> _executableContentTypes = {
  'application/x-msdownload',
  'application/x-msdos-program',
  'application/x-sh',
  'application/x-shellscript',
  'application/x-apple-diskimage',
  'application/java-archive',
  'application/x-executable',
  'application/vnd.ms-word.document.macroenabled.12',
  'application/vnd.ms-excel.sheet.macroenabled.12',
  'application/vnd.ms-powerpoint.presentation.macroenabled.12',
  'text/html',
  'image/svg+xml',
};

/// Whether handing this file to the operating system would be handing it a
/// program.
///
/// "Open" means the OS decides what opening is, and for these it decides to
/// run something: a script executes, a macro document executes on load, a web
/// page from a local origin can phish for a password. None of that is what a
/// person means when they click Open on a file a stranger mailed them. Save
/// is still offered, because writing the bytes somewhere the user picked keeps
/// them in charge of what happens next.
///
/// PREVIEWS are unaffected. An `.xlsm` still renders as a sheet and an `.html`
/// still shows its words and a picture of itself — reading a file is not
/// running it, and this app's own renderers are the safe way to look inside
/// one.
///
/// A page has ONE narrower door beside this refusal and nothing else does:
/// `HtmlPreview`'s Open in browser, which hands the file to the browser the
/// owner already reads the web in rather than to whatever the OS decides
/// opening means. This function still answers true for it — the generic Open
/// stays withheld — because "the browser, deliberately, with a caution on the
/// control" and "whatever `open(2)` picks" are not the same offer.
bool openRefused(AttachmentRef ref) {
  if (_executableExtensions.contains(extensionOf(ref.name))) return true;
  final type = ref.contentType?.split(';').first.trim().toLowerCase() ?? '';
  return _executableContentTypes.contains(type);
}

/// Whether [bytes] are a PDF at all.
///
/// The content type is the sender's word and the name is too; the bytes are
/// not. pdfium looks for the `%PDF-` header anywhere in the first 1024 bytes,
/// so a file with a BOM or a little junk in front of it still opens, and this
/// asks the same question rather than a stricter one that would refuse a file
/// the viewer could have drawn.
bool looksLikePdf(Uint8List bytes) {
  final end = bytes.length < 1024 ? bytes.length : 1024;
  const magic = [0x25, 0x50, 0x44, 0x46, 0x2d]; // %PDF-
  outer:
  for (var i = 0; i + magic.length <= end; i++) {
    for (var j = 0; j < magic.length; j++) {
      if (bytes[i + j] != magic[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// [bytes] as words, or null when they are not words.
///
/// Strict UTF-8 with no control characters short of tab, newline, form feed
/// and carriage return: a file that fails either is a binary that only looked
/// like something else, and drawing it as text would be a screen of boxes.
/// A leading byte-order mark is dropped: it is not a word.
String? textOfBytes(Uint8List bytes) {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  if (text.startsWith(_bom)) text = text.substring(1);
  for (final unit in text.codeUnits) {
    if (unit < 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0c &&
        unit != 0x0d) {
      return null;
    }
  }
  return text;
}

/// The one web address an Internet shortcut names, or null.
///
/// A `.url` is INI: the first `URL=` line, the key read in any case. A
/// `.webloc` is an XML plist: the `<string>` straight after `<key>URL</key>`,
/// with the five XML entities decoded; a binary plist names nothing here.
/// Either answer must be an http(s) address with a host ([webUriOf]) — a
/// shortcut is a stranger's file, and a `file:` or `javascript:` one gets no
/// link at all. Only the first [shortcutScanCap] characters are searched,
/// after a leading byte-order mark: a shortcut is a few lines, and the file
/// may be megabytes.
String? shortcutUrlOf(String? name, String text) {
  var head = text.startsWith(_bom) ? text.substring(1) : text;
  if (head.length > shortcutScanCap) head = head.substring(0, shortcutScanCap);
  final String? raw = switch (extensionOf(name)) {
    'url' => _iniUrl.firstMatch(head)?.group(1),
    'webloc' => _plistUrl.firstMatch(head)?.group(1),
    _ => null,
  };
  if (raw == null) return null;
  final url = raw
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&')
      .trim();
  return webUriOf(url) == null ? null : url;
}

/// How much of a shortcut's text [shortcutUrlOf] searches for its address.
const int shortcutScanCap = 64 * 1024;

const String _bom = '\uFEFF';

/// The rest of the line after `URL=`, trimmed by the caller. No lazy group
/// and no trailing anchor: those backtrack over a long run of spaces.
final RegExp _iniUrl = RegExp(
  r'^[ \t]*URL[ \t]*=([^\r\n]*)',
  multiLine: true,
  caseSensitive: false,
);

final RegExp _plistUrl = RegExp(
  r'<key>\s*URL\s*</key>\s*<string>([^<]*)</string>',
);
