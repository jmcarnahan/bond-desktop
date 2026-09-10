/// Splitting one local file into the passages a reply can cite.
///
/// Pure, and deterministic by contract: the same text and the same code
/// produce the same passages, in the same order, with the same locators. The
/// reconcile handler leans on that — `replaceChunks` is a delete and an
/// insert, so a pass that re-derives the same list replaces the passages with
/// themselves rather than doubling them, and a park on the embedding server
/// resumes instead of restarting.
///
/// Three shapes, chosen from the PATH rather than the text, because the path
/// is what the walk already knows and a markdown file is markdown whether or
/// not it happens to open with a heading:
///
/// | shape | cut on | locator |
/// |---|---|---|
/// | markdown | ATX headings | `Pricing > Q4 rates` |
/// | code, and structured config | 60-line windows, 10 overlapping | `lines 61–120` |
/// | everything else | packed paragraphs | `part 2` |
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;

import '../attachments/attachment_chunker.dart' show packProseChunks;
import 'context_walk.dart' show contextKindFor;

/// The ceiling on one file's passages.
///
/// [maxChunksPerAttachment]'s number and its reasoning: a file is not sixty
/// times more useful than its first sixty passages, and each one costs a POST
/// at embed time and a row forever.
const int maxChunksPerContextFile = 60;

/// Lines per code passage. About a function, or a stanza of config.
const int _codeWindowLines = 60;

/// Lines carried into the next window, so a function's signature and its
/// body are never in different passages only.
const int _codeOverlapLines = 10;

/// One passage of one file.
@immutable
class ContextChunk {
  /// 0-based, in file order — also the `seq` column, and what makes the
  /// chunker's output comparable between two passes.
  final int seq;

  /// `Pricing > Q4 rates`, `lines 61–120`, `part 2`, or empty for a file that
  /// is one passage.
  final String locator;

  /// The stored text, INCLUDING the contextual header line. See
  /// [chunkContextText].
  final String text;

  const ContextChunk({
    required this.seq,
    required this.locator,
    required this.text,
  });
}

/// A markdown ATX heading: one to six `#` and a space.
///
/// Setext headings (`====` underlines) are not recognised, deliberately: they
/// are rare in the files this reads, and telling one from a horizontal rule
/// needs a parser.
final RegExp _atxHeading = RegExp(r'^(#{1,6})\s+(.*)$');

/// A fenced code block's delimiter. Headings INSIDE one are Python comments
/// and shell prompts, not sections.
final RegExp _codeFence = RegExp(r'^\s*(```|~~~)');

/// The extensions chunked as line windows alongside code: structured config
/// that has no paragraphs and whose lines are the unit of meaning.
const Set<String> _windowedExtensions = {'yaml', 'yml', 'toml', 'json', 'xml'};

/// Splits [text] into the passages that get embedded and filed.
///
/// **Every passage opens with a contextual header** — `<rel path> · <locator>`
/// on its own first line, or just `<rel path>` when there is no locator. It
/// is deterministic (no timestamp, no counter) so a re-chunk produces the
/// same bytes, and it is stored rather than added at read time because the
/// embedding has to carry it: a passage of prose about "the Q4 number" is
/// near every other passage about a Q4 number in every project, and the path
/// is what makes it near the RIGHT one.
List<ContextChunk> chunkContextText(String relPath, String text) {
  final parts = switch (_shapeOf(relPath)) {
    _Shape.markdown => _markdownParts(text),
    _Shape.window => _windowParts(text),
    _Shape.prose => _proseParts(text),
  };

  final chunks = <ContextChunk>[];
  for (final part in parts) {
    if (part.text.trim().isEmpty) continue;
    final header =
        part.locator.isEmpty ? relPath : '$relPath · ${part.locator}';
    chunks.add(ContextChunk(
      seq: chunks.length,
      locator: part.locator,
      text: '$header\n${part.text}',
    ));
    if (chunks.length == maxChunksPerContextFile) break;
  }
  return chunks;
}

/// Which of the three shapes a path is cut into.
enum _Shape { markdown, window, prose }

/// The path rule, in one place because two callers depend on agreeing about
/// it: [chunkContextText] cuts a file up by it, and [contextSection] puts one
/// piece back together by it. A file chunked as markdown and read back as
/// prose would answer every locator with the whole file.
_Shape _shapeOf(String relPath) {
  final ext = p.posix.extension(relPath).toLowerCase();
  final suffix = ext.isEmpty ? '' : ext.substring(1);
  final name = p.posix.basename(relPath);
  if (suffix == 'md' ||
      suffix == 'markdown' ||
      name == 'CLAUDE.md' ||
      name == 'SKILL.md') {
    return _Shape.markdown;
  }
  if (contextKindFor(relPath) == 'code' ||
      _windowedExtensions.contains(suffix)) {
    return _Shape.window;
  }
  return _Shape.prose;
}

/// A trailing ` · part 2`, which [_markdownParts] appends when one section
/// needed more than one passage. The section it names is the whole thing.
final RegExp _partSuffix = RegExp(r'\s*·\s*part\s+\d+$');

/// A locator that is `part 2` and nothing else — no ` > ` breadcrumb in front
/// of it. See [contextSection]: it is how the preamble of a long markdown file
/// is located, and the preamble is not a section anything can look up.
final RegExp _barePart = RegExp(r'^part\s+\d+$');

/// The `lines 61–120` a code passage is located by. Either dash, because the
/// locator is written with an en dash and typed back by a model.
final RegExp _lineWindow = RegExp(r'^lines\s+(\d+)\s*[–-]\s*(\d+)$');

/// How many lines of a file [contextSection] hands back for a `lines a–b`
/// locator: two windows, not the one the passage was cut at.
///
/// Public because the drop rule depends on it. A caller deciding whether an
/// expanded window already holds a ranked one has to know how far the
/// expansion reaches, and restating 120 over there would be a second copy of
/// this number that nothing keeps in step with the first.
const int expandedSectionLines = 2 * _codeWindowLines;

/// The line range a `lines a–b` locator names, or null when it names none.
///
/// Public for the same reason [expandedSectionLines] is: the retriever's drop
/// rule compares two locators as ranges, and a second parser for the shape
/// this file WRITES is a second answer to what `lines 61-120` means. Either
/// dash is accepted, because the locator is written with an en dash and typed
/// back by a model that may reach for a hyphen.
({int first, int last})? parseLineLocator(String locator) {
  final match = _lineWindow.firstMatch(locator.trim());
  if (match == null) return null;
  final first = int.tryParse(match.group(1)!);
  final last = int.tryParse(match.group(2)!);
  if (first == null || last == null || first < 1 || last < first) return null;
  return (first: first, last: last);
}

/// The WHOLE of the piece of [text] that [locator] names — the passage's
/// section rather than the passage.
///
/// Pure and deterministic, exactly as [chunkContextText] is, and the same
/// path rule decides the shape. This is what a caller reaches for when a
/// thousand characters of the right section turned out not to be enough: the
/// passage said where the answer lives, and this hands over the place.
///
/// Three shapes and one rule each:
///
/// * **markdown** — the section whose breadcrumb is [locator], plus every
///   FOLLOWING section nested under it, so the whole of `## Pricing` carries
///   its `### Q4 rates` with it. A ` · part N` suffix is stripped first: the
///   part is one passage of a section and the section is what is wanted. An
///   empty locator is the whole file, and a breadcrumb that is not in this
///   text at all answers null rather than guessing.
/// * **`lines a–b`** — line `a` through two windows on, not one. A function
///   rarely ends where the sixty-line window it was cut at did, and the
///   caller's ceiling is the thing that decides how much of it fits.
/// * **anything else** (`part N`, `digest`, empty) — the whole text. There is
///   no smaller unit to hand back, and the caller clamps.
String? contextSection(String relPath, String text, String locator) {
  final wanted = locator.trim();
  if (_shapeOf(relPath) == _Shape.markdown) {
    final crumb = wanted.replaceFirst(_partSuffix, '').trim();
    if (crumb.isEmpty) return text;
    final sections = _markdownSections(text);
    final start = sections.indexWhere((section) => section.locator == crumb);
    if (start < 0) {
      // A BARE `part 2`, with no breadcrumb in front of it. That is what
      // [_markdownParts] writes for the preamble — the text before the first
      // heading, which has no heading to be named by — when it ran past the
      // prose packer's thousand characters and needed more than one passage.
      // The preamble is the file, so the file is the answer. Checked after
      // the breadcrumb lookup, not before, so a document that really does
      // have a `# part 2` heading still gets its own section.
      if (_barePart.hasMatch(crumb)) return text;
      return null;
    }
    final level = sections[start].level;
    final lines = <String>[...sections[start].lines];
    for (var next = start + 1; next < sections.length; next++) {
      // A heading at the same level or shallower is the next section, not
      // part of this one — the same rule the breadcrumb walk keeps.
      if (sections[next].level <= level) break;
      lines.addAll(sections[next].lines);
    }
    return lines.join('\n');
  }
  if (wanted.startsWith('lines')) {
    final range = parseLineLocator(wanted);
    // `lines` and then something that is not a range. A locator this code
    // wrote always parses; one a model typed back may not, and a guess about
    // where it meant would quote the wrong function.
    if (range == null) return null;
    final first = range.first;
    final lines = text.split('\n');
    if (first > lines.length) return null;
    final last = first - 1 + expandedSectionLines;
    return lines
        .sublist(first - 1, last < lines.length ? last : lines.length)
        .join('\n');
  }
  return text;
}

/// Markdown, cut at its headings, each section packed and each passage
/// located by the breadcrumb of the headings above it.
///
/// The breadcrumb is the deepest path — `Pricing > Q4 rates` and not just
/// `Q4 rates` — because a project has four sections called "Notes" and a
/// citation that says which one is the difference between a checkable claim
/// and a shrug.
List<({String locator, String text})> _markdownParts(String text) {
  final sections = _markdownSections(text);
  if (sections.isEmpty) return const [];

  final parts = <({String locator, String text})>[];
  for (final section in sections) {
    final packed = packProseChunks(section.lines.join('\n'));
    if (packed.isEmpty) continue;
    if (packed.length == 1) {
      parts.add((locator: section.locator, text: packed.single.text));
      continue;
    }
    // A section that needed more than one passage says which one this is,
    // appended rather than replacing the breadcrumb: the heading is still
    // the useful half of the citation.
    for (var i = 0; i < packed.length; i++) {
      final suffix = 'part ${i + 1}';
      parts.add((
        locator: section.locator.isEmpty
            ? suffix
            : '${section.locator} · $suffix',
        text: packed[i].text,
      ));
    }
  }
  return parts;
}

/// The headings walk itself: one entry per section, in file order, each
/// carrying its breadcrumb, the heading LEVEL that made it, and its lines.
///
/// Split out of [_markdownParts] because [contextSection] needs the same walk
/// and the trail rule is the whole difference between `Pricing > Q4 rates`
/// and `Q4 rates`. Two copies of it would be two answers to "which section is
/// this passage in".
///
/// The text before the first heading is a section too, at level 0 — every
/// heading is deeper than it, which is correct: a locator naming the preamble
/// is naming the file.
List<({String locator, int level, List<String> lines})> _markdownSections(
  String text,
) {
  final sections = <({String locator, int level, List<String> lines})>[];
  // The breadcrumb so far, indexed by heading level 1..6.
  final trail = List<String?>.filled(7, null);
  var current = (locator: '', level: 0, lines: <String>[]);
  var fenced = false;

  for (final line in text.split('\n')) {
    if (_codeFence.hasMatch(line)) fenced = !fenced;
    final heading = fenced ? null : _atxHeading.firstMatch(line);
    if (heading == null) {
      current.lines.add(line);
      continue;
    }
    if (current.lines.join('\n').trim().isNotEmpty) sections.add(current);
    final level = heading.group(1)!.length;
    trail[level] = heading.group(2)!.trim();
    // A heading closes every deeper one: `## B` after `### a` is not under it.
    for (var deeper = level + 1; deeper <= 6; deeper++) {
      trail[deeper] = null;
    }
    final crumbs = [
      for (var l = 1; l <= 6; l++)
        if (trail[l] case final crumb? when crumb.isNotEmpty) crumb,
    ];
    // The heading line stays with its section: it is the sentence that says
    // what the passage is about, and a section read without it is orphaned.
    current = (
      locator: crumbs.join(' > '),
      level: level,
      lines: <String>[line],
    );
  }
  if (current.lines.join('\n').trim().isNotEmpty) sections.add(current);
  return sections;
}

/// Code and structured config: fixed windows of lines with a fixed overlap.
///
/// Lines and not paragraphs, because code has neither headings nor blank-line
/// paragraphs that mean anything — a class is separated from the next by one
/// blank line exactly as two statements are. The locator is what an editor
/// shows in its gutter, so a citation can be opened.
List<({String locator, String text})> _windowParts(String text) {
  final lines = text.split('\n');
  if (lines.length <= _codeWindowLines) {
    return [(locator: '', text: text)];
  }
  final step = _codeWindowLines - _codeOverlapLines;
  final parts = <({String locator, String text})>[];
  for (var start = 0; start < lines.length; start += step) {
    final end = start + _codeWindowLines < lines.length
        ? start + _codeWindowLines
        : lines.length;
    parts.add((
      // 1-based and inclusive, which is what a gutter shows. En dash: it is
      // a range a person reads, not a token anything parses.
      locator: 'lines ${start + 1}–$end',
      text: lines.sublist(start, end).join('\n'),
    ));
    if (end == lines.length) break;
  }
  return parts;
}

/// Everything else, through the app's one paragraph packer.
List<({String locator, String text})> _proseParts(String text) => [
      for (final chunk in packProseChunks(text))
        (locator: chunk.locator, text: chunk.text),
    ];
