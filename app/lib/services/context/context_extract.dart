/// Turning one local file's bytes into the words a search can answer with.
///
/// Pure and import-light on purpose: everything here is a decision about
/// text, it is asked once per changed file by one handler, and every rule
/// below is testable without a database, a server or a file.
///
/// The counterpart of `attachment_extract`'s job on the other side of the
/// app, with one difference that shapes all of it: these files are the
/// owner's OWN, they are re-read on every sync, and the interesting ones are
/// exactly the shapes a mail attachment rarely is — a rendered HTML analysis,
/// a notebook, a CSV of results.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../html_text.dart';

/// The ceiling on one file's words.
///
/// A megabyte is about 250 pages. Past that a file is a log or a dump, and
/// the head of it says what it is; keeping the tail would cost sixty
/// embeddings to index a rotation of the same lines.
const int maxContextTextChars = 1000000;

/// The most rows of a table that become text. The header plus forty rows is
/// what a person reads to know what the columns MEAN, and a hundred thousand
/// rows of numbers embed as noise.
const int _tableRows = 40;

/// One file's words, and whether a cap cut them.
class ExtractedText {
  final String text;

  /// True when [maxContextTextChars] or the table cap bit — carried so the
  /// caller can say so rather than quietly presenting a fragment as the
  /// whole file.
  final bool truncated;

  const ExtractedText(this.text, {this.truncated = false});
}

/// The words in [bytes], read according to what [relPath] says the file is,
/// or null when this shape has no extractor.
///
/// Decodes as UTF-8 with `allowMalformed: true` rather than sniffing an
/// encoding: the walk has already established there is no NUL in the header,
/// and a Latin-1 accent arriving as a replacement character costs one wrong
/// glyph in a passage, where a thrown `FormatException` would cost the whole
/// file.
ExtractedText? extractContextText(
  String relPath,
  List<int> bytes, {
  int maxChars = maxContextTextChars,
}) {
  final ext = p.posix.extension(relPath).toLowerCase();
  final raw = utf8.decode(bytes, allowMalformed: true);

  final extracted = switch (ext) {
    '.html' || '.htm' => _fromHtml(raw),
    '.ipynb' => _fromNotebook(raw),
    '.csv' || '.tsv' => _fromTable(raw),
    _ => ExtractedText(raw),
  };

  if (extracted.text.length <= maxChars) return extracted;
  return ExtractedText(
    extracted.text.substring(0, maxChars),
    truncated: true,
  );
}

// ── HTML ───────────────────────────────────────────────────────────────

/// A rendered page as the words a search can answer with.
///
/// The conversion itself is shared with mail bodies and lives in
/// `services/html_text.dart`; what belongs to THIS caller is the profile. A
/// file the owner already has is read as a document: a chart's `alt` is the
/// one sentence saying what it shows, and lifting it is the difference
/// between an indexed finding and a picture. Mail wants the opposite of that
/// and says so with its own profile.
ExtractedText _fromHtml(String raw) =>
    ExtractedText(htmlToText(raw, profile: HtmlProfile.document));

// ── notebooks ──────────────────────────────────────────────────────────

/// A notebook, read as the document a person wrote rather than the JSON it
/// is stored as.
///
/// Markdown cells verbatim (they are the prose), code cells fenced (so the
/// chunker and the reader can both see where code starts), and only the
/// TEXT outputs — a base64 PNG of a chart is a megabyte that embeds as
/// nothing, and the `text/plain` beside it is the table it drew.
///
/// A file that is not the notebook shape falls back to its raw text, which
/// is the honest answer for a `.ipynb` a tool half-wrote.
ExtractedText _fromNotebook(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return ExtractedText(raw);
  }
  if (decoded is! Map || decoded['cells'] is! List) {
    return ExtractedText(raw);
  }

  final parts = <String>[];
  for (final cell in decoded['cells'] as List) {
    if (cell is! Map) continue;
    final source = _joinSource(cell['source']);
    final type = cell['cell_type'];
    if (type == 'markdown') {
      if (source.trim().isNotEmpty) parts.add(source.trimRight());
      continue;
    }
    if (type != 'code') continue;
    if (source.trim().isNotEmpty) {
      parts.add('```\n${source.trimRight()}\n```');
    }
    final outputs = cell['outputs'];
    if (outputs is! List) continue;
    for (final output in outputs) {
      if (output is! Map) continue;
      final stream = _joinSource(output['text']);
      if (stream.trim().isNotEmpty) parts.add(stream.trimRight());
      final data = output['data'];
      if (data is Map) {
        final plain = _joinSource(data['text/plain']);
        if (plain.trim().isNotEmpty) parts.add(plain.trimRight());
      }
    }
  }
  return ExtractedText(parts.join('\n\n'));
}

/// A notebook's `source` is a list of lines WITH their newlines, or one
/// string. Both spellings are in the format and both are in the wild.
String _joinSource(Object? source) => switch (source) {
      final String text => text,
      final List<dynamic> lines => lines.whereType<String>().join(),
      _ => '',
    };

// ── tables ─────────────────────────────────────────────────────────────

/// A delimited table, cut to its header and forty rows.
///
/// The head rather than a sample, because the header is the only part that
/// names the columns and the first rows are what say what a value looks
/// like. The trailer states what was left, so a passage quoting this cannot
/// read as the whole file.
ExtractedText _fromTable(String raw) {
  final lines = raw.split('\n');
  // A trailing newline is one empty line, not a row.
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.length <= _tableRows + 1) {
    return ExtractedText(lines.join('\n'));
  }
  final kept = lines.take(_tableRows + 1).join('\n');
  final more = lines.length - (_tableRows + 1);
  return ExtractedText('$kept\n[… $more more rows]', truncated: true);
}
