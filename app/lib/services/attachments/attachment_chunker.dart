/// Splitting a document into the passages a search can answer with.
///
/// Pure and import-light on purpose: everything here is a decision about text,
/// it is asked once per document by one handler, and every rule below is
/// testable without a database, a server or a file.
///
/// **The shape is read off the TEXT, never off the mime type.** The extractor
/// on the other side of the seam writes the same flat text whatever the file
/// was, and marks structure with delimiters — `--- Sheet: Q3 ---` before each
/// worksheet, `--- Slide 4 ---` before each slide. Those are what a chunk can
/// be located by. A content type says a file is `.xlsx`; it does not say the
/// extractor found any sheets in it, and a spreadsheet that came back as a
/// paragraph of prose has to chunk as the paragraph it is.
library;

import 'package:flutter/foundation.dart' show immutable;

/// One passage, and where a person would look to find it.
@immutable
class AttachmentChunk {
  final String text;

  /// `Sheet Q3 rows 2–41`, `slide 4`, `part 2`, or empty for a document that
  /// is one passage. Rendered beside the file name wherever a passage is
  /// quoted, so a reader can check it.
  final String locator;

  const AttachmentChunk(this.text, this.locator);
}

/// The ceiling on one document's passages.
///
/// A two-hundred-page contract is not sixty times more useful than its first
/// sixty passages, and each one costs a POST at embed time and a row forever.
/// Where a document is cut is where the extractor stopped mattering.
const int maxChunksPerAttachment = 60;

/// Roughly a screen of prose. Small enough that a hit is a passage a person
/// can read, large enough that a paragraph is rarely split.
const int _proseChunkChars = 1000;

/// Carried from the end of the previous passage into the start of the next, so
/// a sentence straddling a boundary is embedded whole at least once.
const int _proseOverlapChars = 150;

/// Rows per spreadsheet passage, header excluded. Forty rows of a table is
/// about as much as means anything as one vector.
const int _sheetRowsPerChunk = 40;

final RegExp _sheetHeader = RegExp(r'^--- Sheet: (.*) ---$');
final RegExp _slideHeader = RegExp(r'^--- Slide (\d+) ---$');

/// The line the extractor adds when it stopped early on a sheet. It is a
/// statement about the extraction, not a row of the table, and embedding it
/// would make every truncated spreadsheet near every other one.
final RegExp _sheetTrailer = RegExp(r'^\[\.\.\. showing first .* rows\]$');

/// Splits [text] into the passages that get embedded.
///
/// [contentType] and [name] are taken for the record and for a future shape
/// this cannot read off the text; nothing below branches on either. They stay
/// in the signature because the caller has them and a chunker that later needs
/// one should not change every call site to get it.
List<AttachmentChunk> chunkAttachmentText(
  String text, {
  required String contentType,
  required String? name,
}) {
  final lines = text.split('\n');
  final chunks = _sheetChunks(lines) ?? _slideChunks(lines) ?? _proseChunks(text);
  return [
    for (final chunk in chunks)
      if (chunk.text.trim().isNotEmpty) chunk,
  ].take(maxChunksPerAttachment).toList();
}

/// A workbook, if the text reads as one.
///
/// Null — meaning "not a workbook, chunk it some other way" — for text with no
/// sheet header, and for a workbook whose sheets are all empty. That second
/// case is the one worth naming: an extractor that found the headers and no
/// rows has produced something that is prose as far as this is concerned, and
/// returning a list of nothing here would silently lose the document.
List<AttachmentChunk>? _sheetChunks(List<String> lines) {
  final starts = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (_sheetHeader.hasMatch(lines[i].trimRight())) starts.add(i);
  }
  if (starts.isEmpty) return null;

  final chunks = <AttachmentChunk>[];
  for (var s = 0; s < starts.length; s++) {
    final start = starts[s];
    final end = s + 1 < starts.length ? starts[s + 1] : lines.length;
    final header = lines[start].trimRight();
    final title = _sheetHeader.firstMatch(header)!.group(1)!.trim();

    final body = [
      for (var i = start + 1; i < end; i++)
        if (lines[i].trim().isNotEmpty &&
            !_sheetTrailer.hasMatch(lines[i].trim()))
          lines[i],
    ];
    if (body.isEmpty) continue;

    // A sheet of one line is a header and nothing under it — there is no row
    // range to name, so the locator is the sheet.
    if (body.length <= 1) {
      chunks.add(AttachmentChunk('$header\n${body.first}', 'Sheet $title'));
      continue;
    }

    final columns = body.first;
    // Row numbers are what a person reads in the spreadsheet, so the header is
    // row 1 and the first data row is row 2.
    for (var i = 1; i < body.length; i += _sheetRowsPerChunk) {
      final last = i + _sheetRowsPerChunk < body.length
          ? i + _sheetRowsPerChunk
          : body.length;
      chunks.add(
        AttachmentChunk(
          '$header\n$columns\n${body.sublist(i, last).join('\n')}',
          // En dash: it is a range, and the extractor's own headers are typed
          // text a person reads rather than a machine parses.
          'Sheet $title rows ${i + 1}–$last',
        ),
      );
    }
  }
  return chunks.isEmpty ? null : chunks;
}

/// A deck, if the text reads as one. One passage per slide, header included —
/// the slide number is part of what the passage says — and speaker notes stay
/// with the slide they belong to, because a note read apart from its slide is
/// a sentence with no subject.
List<AttachmentChunk>? _slideChunks(List<String> lines) {
  final starts = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (_slideHeader.hasMatch(lines[i].trimRight())) starts.add(i);
  }
  if (starts.isEmpty) return null;

  final chunks = <AttachmentChunk>[];
  for (var s = 0; s < starts.length; s++) {
    final start = starts[s];
    final end = s + 1 < starts.length ? starts[s + 1] : lines.length;
    final number =
        _slideHeader.firstMatch(lines[start].trimRight())!.group(1)!;
    chunks.add(
      AttachmentChunk(lines.sublist(start, end).join('\n').trimRight(),
          'slide $number'),
    );
  }
  return chunks.isEmpty ? null : chunks;
}

/// Everything else: paragraphs packed greedily, with an overlap.
///
/// The overlap is trimmed FORWARD to a word boundary rather than cut at
/// exactly 150 characters, so a passage never opens on half a word — a
/// fragment like `ract expires` embeds as noise and reads as a mistake.
List<AttachmentChunk> _proseChunks(String text) {
  final paragraphs = [
    for (final p in text.split(RegExp(r'\n\s*\n')))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  if (paragraphs.isEmpty) return const [];

  final bodies = <String>[];
  var current = StringBuffer();

  void flush() {
    if (current.isEmpty) return;
    bodies.add(current.toString());
    current = StringBuffer();
  }

  for (final paragraph in paragraphs) {
    // An over-long paragraph is hard-split rather than dropped or left whole:
    // a single 20 K-character wall of text is one legitimate shape of
    // extracted PDF, and it must still become passages.
    if (paragraph.length > _proseChunkChars) {
      flush();
      for (var at = 0; at < paragraph.length; at += _proseChunkChars) {
        final end = at + _proseChunkChars < paragraph.length
            ? at + _proseChunkChars
            : paragraph.length;
        bodies.add(paragraph.substring(at, end));
      }
      continue;
    }
    if (current.isNotEmpty &&
        current.length + 2 + paragraph.length > _proseChunkChars) {
      flush();
    }
    if (current.isNotEmpty) current.write('\n\n');
    current.write(paragraph);
  }
  flush();

  return [
    for (var i = 0; i < bodies.length; i++)
      AttachmentChunk(
        i == 0 ? bodies[i] : '${_overlap(bodies[i - 1])}${bodies[i]}',
        // A document that is one passage has nowhere to point at, and 'part 1'
        // of one part is noise on every line that quotes it.
        bodies.length == 1 ? '' : 'part ${i + 1}',
      ),
  ];
}

/// The tail of [previous], from the first word boundary inside the overlap
/// window, with a separating newline.
String _overlap(String previous) {
  if (previous.length <= _proseOverlapChars) return '$previous\n';
  final tail = previous.substring(previous.length - _proseOverlapChars);
  final space = tail.indexOf(RegExp(r'\s'));
  return space < 0 ? '' : '${tail.substring(space + 1)}\n';
}
