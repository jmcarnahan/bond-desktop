/// How an attachment says its size, its kind and its identity on screen.
///
/// A sibling of `time_format.dart` and for the same reason: three questions
/// every attachment widget asks, answered once so a chip, a thumbnail and a
/// preview header never disagree about what a file is called or how big it is.
/// Nothing here imports Flutter's material layer — these are string and key
/// functions, testable without pumping a widget. The one Flutter import is
/// narrowed to the two names it needs: [ValueKey], and the grapheme-cluster
/// extension a name is cut on.
library;

import 'package:flutter/widgets.dart' show StringCharacters, ValueKey;

import '../models/attachment_models.dart';

const int _kib = 1024;
const int _mib = 1024 * 1024;
const int _gib = 1024 * 1024 * 1024;

/// A size in ONE unit, never two — the `relativeTime` rule applied to bytes.
///
/// Null, negative and **zero** all render as `''`: `AttachmentRef.size` uses 0
/// for "the connector did not say", which every Teams attachment does, and a
/// chip reading `0 B` would state a fact nobody knows. Callers therefore test
/// the string rather than the number.
///
/// Below a mebibyte the number is whole — nobody reads `1.4 KB` — and megabytes
/// carry one decimal only while that decimal still means something, which is
/// under ten. Each step re-checks the rounded value so a file 0.4 KB shy of the
/// next unit is not shown as `1024 KB`.
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes < _kib) return '$bytes B';
  final kb = (bytes / _kib).round();
  if (kb < _kib) return '$kb KB';
  final mb = bytes / _mib;
  if (mb < 10) return '${mb.toStringAsFixed(1)} MB';
  final wholeMb = mb.round();
  if (wholeMb < _kib) return '$wholeMb MB';
  return '${(bytes / _gib).toStringAsFixed(1)} GB';
}

/// A text glyph for a file, not an icon — the same reasoning `source_glyph.dart`
/// records: one character reads at caption size, costs no asset, and never
/// arrives late.
///
/// The **name is read before the content type** on purpose. Graph reports
/// `application/octet-stream` for a great many real documents, and a chip that
/// called every one of them a generic paperclip would lose the one signal the
/// reader actually scans for. The kind is the last resort, because it is the
/// coarsest thing the connector says.
String attachmentGlyph(String kind, String? contentType, {String? name}) {
  final byExtension = _glyphForExtension(extensionOf(name));
  if (byExtension != null) return byExtension;
  final byType = _glyphForContentType(contentType);
  if (byType != null) return byType;
  return switch (kind) {
    'item' => '✉',
    'image' => '🖼',
    'reference' || 'message_reference' || 'card' => '🔗',
    _ => '📎',
  };
}

/// Whether this is something the row can draw rather than name.
///
/// Three answers in order of trust: the connector's own kind, the content type,
/// and last the file name. Deliberately narrower than the glyph table — `heic`
/// and `tiff` get the picture glyph because that is what they are, but Flutter
/// cannot decode either, so they are not treated as drawable.
bool isImageAttachment(AttachmentRef attachment) {
  if (attachment.kind == 'image') return true;
  final type = attachment.contentType?.toLowerCase() ?? '';
  if (type.startsWith('image/')) return true;
  return const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}
      .contains(extensionOf(attachment.name));
}

/// Whether two refs are the same file.
///
/// [AttachmentRef] has no value equality, deliberately — a digest landing
/// between two frames would otherwise make a selected preview "a different
/// attachment" and drop it. The pair of ids is what identifies a file, so every
/// comparison in the UI goes through here. Two nulls are NOT the same
/// attachment: "nothing is selected" must never match a row.
bool sameAttachment(AttachmentRef? a, AttachmentRef? b) =>
    a != null &&
    b != null &&
    a.messageId == b.messageId &&
    a.attachmentId == b.attachmentId;

/// A widget key that survives a re-list.
///
/// Never the ordinal and never the list index: both move when the connector
/// lists a message's attachments again, and a moving key throws away the state
/// of the widget that was holding the file the user was looking at.
ValueKey<String> attachmentKey(String prefix, AttachmentRef attachment) =>
    ValueKey('$prefix-${attachment.messageId}-${attachment.attachmentId}');

/// The lower-cased extension of [name], or `''` — no dot, no query string, and
/// nothing for a name that is all extension (`.gitignore`) or has none.
String extensionOf(String? name) {
  final trimmed = (name ?? '').trim();
  final dot = trimmed.lastIndexOf('.');
  if (dot <= 0 || dot == trimmed.length - 1) return '';
  return trimmed.substring(dot + 1).toLowerCase();
}

String? _glyphForExtension(String extension) {
  if (extension.isEmpty) return null;
  return switch (extension) {
    'pdf' => '📕',
    'xlsx' || 'xlsm' || 'xls' || 'csv' => '📊',
    'docx' || 'doc' || 'rtf' || 'odt' => '📄',
    'pptx' || 'ppt' => '📽',
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'tiff' =>
      '🖼',
    'eml' || 'msg' => '✉',
    'zip' || '7z' || 'rar' => '🗜',
    _ => null,
  };
}

String? _glyphForContentType(String? contentType) {
  final type = contentType?.toLowerCase().trim() ?? '';
  if (type.isEmpty) return null;
  if (type.startsWith('image/')) return '🖼';
  if (type.startsWith('message/')) return '✉';
  if (type.contains('pdf')) return '📕';
  if (type.contains('spreadsheet') ||
      type.contains('excel') ||
      type == 'text/csv') {
    return '📊';
  }
  if (type.contains('presentation') || type.contains('powerpoint')) return '📽';
  if (type.contains('wordprocessing') ||
      type.contains('msword') ||
      type.contains('rtf')) {
    return '📄';
  }
  if (type.contains('zip') || type.contains('7z') || type.contains('rar')) {
    return '🗜';
  }
  return null;
}

/// The parsed [url] when — and only when — it is a web address.
///
/// A `source_url` is the SENDER's string. Teams cards and reference
/// attachments carry whatever the connector posted, verbatim, and handing that
/// to the operating system is handing a stranger the launcher: `file:///…` runs
/// a local application, `smb://…` mounts a share, and a custom scheme opens
/// whichever app registered it. A button labelled "Open in Teams" must do the
/// one thing it says, so only `http` and `https` with a real host get through.
/// Everything else answers null, which is the caller's cue to offer no button
/// at all rather than a button that would do something else.
Uri? webUriOf(String? url) {
  final trimmed = (url ?? '').trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}

/// How long a suggested file name may be before the save panel gets an
/// unusable one. Well under every filesystem's own limit, and long enough that
/// no real attachment is ever cut.
const int _suggestedNameCap = 120;

/// A name safe to hand a save panel.
///
/// The name comes off the wire, so it can carry a path (`../../.ssh/config`),
/// a Windows drive separator, a newline, or four thousand characters. The
/// panel decides where the file goes and the user confirms it, but a suggested
/// name with a separator in it is still a name that reads as a path — so every
/// separator and every control character becomes an underscore, leading dots
/// (which hide a file) come off, and the whole thing is capped with its
/// extension kept, because the extension is what the operating system opens it
/// by. A name left with nothing in it becomes `attachment`, the same fallback
/// the caller used before there was a name at all.
String safeSuggestedName(String? name) {
  final cleaned = (name ?? '')
      .replaceAll(RegExp(r'[/\\:\x00-\x1f\x7f]'), '_')
      .trim()
      .replaceAll(RegExp(r'^\.+'), '')
      .trim();
  if (cleaned.isEmpty) return 'attachment';
  if (cleaned.characters.length <= _suggestedNameCap) return cleaned;

  // By grapheme cluster, the way `AttachmentChip.nameCap` cuts: `substring`
  // splits a surrogate pair and leaves the replacement glyph in a file name.
  final extension = extensionOf(cleaned);
  if (extension.isEmpty) {
    return cleaned.characters.take(_suggestedNameCap).toString();
  }
  final suffix = '.$extension';
  final room = _suggestedNameCap - suffix.characters.length;
  // An extension longer than the whole budget is not an extension worth
  // keeping; the cut alone is the honest answer.
  if (room <= 0) return cleaned.characters.take(_suggestedNameCap).toString();
  final stem = cleaned.characters
      .take(cleaned.characters.length - suffix.characters.length)
      .take(room)
      .toString();
  return '$stem$suffix';
}
