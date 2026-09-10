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
  final ext = p.posix.extension(relPath).toLowerCase();
  final suffix = ext.isEmpty ? '' : ext.substring(1);
  final name = p.posix.basename(relPath);

  final List<({String locator, String text})> parts;
  if (suffix == 'md' || suffix == 'markdown' || name == 'CLAUDE.md' ||
      name == 'SKILL.md') {
    parts = _markdownParts(text);
  } else if (contextKindFor(relPath) == 'code' ||
      _windowedExtensions.contains(suffix)) {
    parts = _windowParts(text);
  } else {
    parts = _proseParts(text);
  }

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

/// Markdown, cut at its headings, each section packed and each passage
/// located by the breadcrumb of the headings above it.
///
/// The breadcrumb is the deepest path — `Pricing > Q4 rates` and not just
/// `Q4 rates` — because a project has four sections called "Notes" and a
/// citation that says which one is the difference between a checkable claim
/// and a shrug.
List<({String locator, String text})> _markdownParts(String text) {
  final lines = text.split('\n');
  final sections = <({String locator, List<String> lines})>[];
  // The breadcrumb so far, indexed by heading level 1..6.
  final trail = List<String?>.filled(7, null);
  var current = (locator: '', lines: <String>[]);
  var fenced = false;

  for (final line in lines) {
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
    current = (locator: crumbs.join(' > '), lines: <String>[line]);
  }
  if (current.lines.join('\n').trim().isNotEmpty) sections.add(current);
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
