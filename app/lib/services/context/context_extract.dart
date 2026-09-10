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

/// The blocks whose contents are not prose and must go BEFORE anything else
/// looks at a tag.
///
/// A Plotly export is the case this exists for: megabytes of embedded
/// JavaScript wrapped around one page of findings. Strip the script first and
/// what is left is the page; strip tags first and the index fills with
/// minified JS that happens to contain English words.
///
/// The `(?<!/)` is what keeps a SELF-CLOSING tag out of this: `<svg …/>` opens
/// nothing, so pairing it with the next `</svg>` on the page would delete
/// everything between two unrelated charts.
final RegExp _htmlDropped = RegExp(
  r'<(script|style|svg|noscript|head)\b[^>]*(?<!/)>[\s\S]*?</\1\s*>',
  caseSensitive: false,
);

/// The same blocks, UNCLOSED, running to the end of the file.
///
/// [_htmlDropped] only catches matched pairs, and a file that is truncated —
/// a download interrupted, a page still being written when the walk reached
/// it — routinely ends inside its `<script>`. Without this the tag is
/// stripped by [_htmlAnyTag] and its whole body survives as prose, which is
/// exactly the failure [_htmlDropped] exists to prevent.
///
/// Two exclusions, and both are about not deleting the document. A
/// self-closing tag (`(?<!/)` again) never opened a block, and every
/// matplotlib and Plotly export writes its inline `<svg …/>` that way — a
/// sweep to end of file from one of those loses every finding below the
/// chart. `head` is absent from the list entirely, because an omitted
/// `</head>` is legal HTML rather than a truncation, and what follows it is
/// the whole page; [_htmlOpenHead] handles that one properly.
final RegExp _htmlUnclosed = RegExp(
  r'<(script|style|svg|noscript)\b[^>]*(?<!/)>[\s\S]*$',
  caseSensitive: false,
);

/// A `<head>` whose end tag was omitted, ending where the body begins.
///
/// Only ever reached when there is no `</head>` — a closed head is already
/// gone with [_htmlDropped], leaving no `<head` for this to match. With no
/// `<body` on the page the lookahead fails and nothing is dropped, which is
/// the honest answer: there is no way to tell where such a head ends, and
/// keeping a title and some meta is cheaper than losing the document.
final RegExp _htmlOpenHead = RegExp(
  r'<head\b[^>]*(?<!/)>[\s\S]*?(?=<body\b)',
  caseSensitive: false,
);

final RegExp _htmlComment = RegExp(r'<!--[\s\S]*?-->');

final RegExp _htmlHeadingOpen = RegExp(r'<h([1-6])\b[^>]*>', caseSensitive: false);
final RegExp _htmlHeadingClose = RegExp(r'</h[1-6]\s*>', caseSensitive: false);
final RegExp _htmlBlock = RegExp(
  r'</?(p|div|section|article|li|tr|table|br|hr|blockquote|pre)\b[^>]*>',
  caseSensitive: false,
);
final RegExp _htmlCell = RegExp(r'</(td|th)\s*>', caseSensitive: false);
final RegExp _htmlAnyTag = RegExp(r'<[^>]*>');

/// The attributes that carry the only words a picture has.
///
/// A chart in an analysis is an `<img>` or an inline `<svg>`, and its `alt`
/// or `aria-label` is the one sentence saying what it shows — routinely the
/// most retrievable line on the page.
///
/// `svg` earns its place here only for the SELF-CLOSING spelling: a matched
/// `<svg>…</svg>` is gone with [_htmlDropped] before labels are lifted, and
/// its label with it. That is the right trade — the alternative is lifting
/// labels out of a block that may hold a megabyte of path data — and
/// `<svg …/>`, which is what a chart export writes, keeps its sentence.
final RegExp _htmlLabelled = RegExp(
  r'<(img|svg|figure|div)\b[^>]*?\b(alt|aria-label|title)\s*=\s*'
  '''(?:"([^"]*)"|'([^']*)')''',
  caseSensitive: false,
);

/// A tag stripper, deliberately, and not a DOM.
///
/// There is no HTML parser in this app's dependencies (`xml` is XML-only and
/// throws on the first unclosed `<br>`), and adding one to read a file the
/// user already has is a dependency for a page of regexes. What this gives up
/// is nesting-aware structure; what it keeps is every heading, every table
/// cell, every paragraph and every picture's label, which is the whole of
/// what a rendered analysis says.
ExtractedText _fromHtml(String raw) {
  // Order matters. Comments first (one can contain a `</script>` that would
  // otherwise close a block early), then every matched block, then an
  // unclosed head, and only then the unclosed tail — asking for the tail
  // first would eat the rest of the page from the first `<script>` in a file
  // that closes it perfectly well, and an unclosed script inside an unclosed
  // head is a script the head sweep has already taken.
  var text = raw
      .replaceAll(_htmlComment, '')
      .replaceAll(_htmlDropped, '')
      .replaceAll(_htmlOpenHead, '')
      .replaceAll(_htmlUnclosed, '');

  // The picture labels are lifted out BEFORE the tags go, each onto its own
  // line, because a stripper that only deletes tags deletes them with it.
  final labels = <String>[];
  for (final match in _htmlLabelled.allMatches(text)) {
    final value = (match.group(3) ?? match.group(4) ?? '').trim();
    if (value.isNotEmpty) labels.add(value);
  }

  text = text
      .replaceAllMapped(
        _htmlHeadingOpen,
        (m) => '\n${'#' * int.parse(m.group(1)!)} ',
      )
      .replaceAll(_htmlHeadingClose, '\n')
      .replaceAll(_htmlCell, '\t')
      .replaceAll(_htmlBlock, '\n')
      .replaceAll(_htmlAnyTag, '');

  text = _decodeEntities(text);

  // Runs of spaces collapse; tabs survive, because they are what separates
  // one table cell from the next and a row read as one word is a row nobody
  // can search.
  text = text
      .replaceAll(RegExp(r'[  ]+'), ' ')
      .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  if (labels.isNotEmpty) text = '$text\n\n${labels.join('\n')}';
  return ExtractedText(text.trim());
}

const Map<String, String> _namedEntities = {
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&apos;': "'",
  '&nbsp;': ' ',
};

final RegExp _numericEntity = RegExp(r'&#(x?)([0-9a-fA-F]+);');

/// `&amp;` LAST, so a double-escaped `&amp;lt;` becomes `&lt;` and not `<`.
String _decodeEntities(String text) {
  var out = text;
  for (final entry in _namedEntities.entries) {
    if (entry.key == '&amp;') continue;
    out = out.replaceAll(entry.key, entry.value);
  }
  out = out.replaceAllMapped(_numericEntity, (m) {
    final code = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
    // Out of range, a surrogate half, or unparseable: left as it was typed
    // rather than turned into a replacement character. The surrogate range is
    // named explicitly and it is the one that matters: half a pair is a
    // string Dart will hold and UTF-8 cannot encode, so it would travel this
    // far and then throw at the database write or the embedding POST.
    if (code == null ||
        code < 32 ||
        code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)) {
      return m.group(0)!;
    }
    return String.fromCharCode(code);
  });
  return out.replaceAll('&amp;', '&');
}

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
