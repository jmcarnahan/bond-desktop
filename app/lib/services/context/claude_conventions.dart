/// Reading the conventions a Claude Code project already keeps.
///
/// Frontmatter, skill folders, rule `paths`, `@path` imports — none of it is
/// this app's invention and none of it costs a model call. A project the
/// owner already maintains for Claude Code arrives with its own description
/// of itself, and the whole job here is to read that description rather than
/// ask a model to guess at it.
///
/// Pure: no `dart:io`, no store, no clock. Imports are resolved through a
/// callback the caller supplies, because the only reader that matters is the
/// INDEX — the brief runs long after the walk, off `context_text` rows,
/// against a directory the sandbox may no longer be inside.
library;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'context_walk.dart' show contextKindFor;

/// The ceiling on a resolved `CLAUDE.md`. Standing notes plus two hops of
/// imports; past this a project is handing its whole documentation tree to a
/// prompt that has eight thousand characters for it anyway.
const int _resolvedCap = 20000;

/// How long a `description` may be after cleaning.
const int _descriptionCap = 500;

/// How long the fallback first line of a skill body may be. Shorter than
/// [_descriptionCap] because it is a guess at a description rather than one
/// the author wrote.
const int _fallbackDescriptionCap = 300;

/// The YAML header of [text], and the body under it.
///
/// Frontmatter is a leading `---` line, YAML, and a closing `---` line —
/// Claude Code's own shape, and Jekyll's before it. No fence at all, and a
/// header that will not parse, are all body: the second is an author midway
/// through writing one, and the lines are still the file.
///
/// A header that DOES parse but is not a map — a list, a bare scalar —
/// declares nothing, and answers no keys and the text BELOW the closing
/// fence. Those two fence lines were real frontmatter whatever sits between
/// them, and a body that still carries them hands `---` to the caller that
/// falls back to the first line of the body for a description.
///
/// Unknown keys are KEPT. The callers each read the two or three they know
/// about, and a project that puts `model:` or `allowed-tools:` in a skill
/// header is not a project this app should be losing information from.
({Map<String, Object?> yaml, String body}) parseFrontmatter(String text) {
  final none = (yaml: const <String, Object?>{}, body: text);
  if (text.isEmpty) return none;

  // CRLF is stripped per line rather than from the whole file, so a file
  // written on Windows keeps its own body bytes and only the fence lines are
  // compared normalised.
  final lines = text.split('\n');
  if (lines.isEmpty || lines.first.trimRight() != '---') return none;

  var close = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trimRight() == '---') {
      close = i;
      break;
    }
  }
  if (close < 0) return none;

  final header = lines.sublist(1, close).join('\n');
  final body = lines.sublist(close + 1).join('\n');
  try {
    final document = loadYaml(header);
    if (document is! YamlMap) {
      return (yaml: const <String, Object?>{}, body: body);
    }
    return (yaml: _plainMap(document), body: body);
  } on YamlException {
    // A header the author is midway through writing. The body is still the
    // body, and a file that cannot declare anything simply declares nothing.
    return none;
  }
}

/// A [YamlMap] as a plain map, recursively.
///
/// The yaml package's own types are views over a source span; carrying them
/// out of here would leak the parser into every caller and, worse, into
/// `jsonEncode` — a `YamlList` encodes, but only by accident of it being an
/// `Iterable`.
Map<String, Object?> _plainMap(YamlMap map) {
  final plain = <String, Object?>{};
  map.nodes.forEach((key, value) {
    final name = key is YamlScalar ? key.value : key;
    if (name is! String) return;
    plain[name] = _plainValue(value);
  });
  return plain;
}

Object? _plainValue(Object? value) {
  if (value is YamlMap) return _plainMap(value);
  if (value is YamlList) return [for (final entry in value) _plainValue(entry)];
  if (value is YamlScalar) return _plainValue(value.value);
  return value;
}

/// A frontmatter `description` as one clean line.
///
/// Angle-bracket runs are removed rather than escaped: Claude Code skill
/// descriptions routinely carry `<argument>` placeholders and inline HTML,
/// and this string ends up inside a fenced prompt and inside a Settings row
/// — neither of which wants half a tag. Anything that is not a string is an
/// author writing a list or a map where a sentence goes, and reads as no
/// description at all.
String cleanDescription(Object? raw) {
  if (raw is! String) return '';
  final stripped = raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
  final collapsed = stripped.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length > _descriptionCap
      ? collapsed.substring(0, _descriptionCap)
      : collapsed;
}

/// The name and description of a skill, or null for a file that is not one.
///
/// **The FOLDER name always wins.** `.claude/skills/<name>/SKILL.md` is
/// invoked as `<name>`, whatever the frontmatter says — Claude Code's own
/// rule — so a header whose `name` has drifted from the folder it sits in is
/// a header that would have the app matching on a word no one can type.
///
/// The description falls back to the first real line of the body when the
/// header has none. A skill with no description at all is invisible to the
/// cosine match [ContextRetriever] runs over these, and the first line of a
/// skill is very nearly always the sentence its author would have written
/// there.
({String name, String description})? skillOf(String relPath, String text) {
  if (contextKindFor(relPath) != 'skill') return null;

  final segments = relPath.split('/');
  // `contextKindFor` already established the shape, so the folder is the
  // segment above `SKILL.md`.
  final name = segments.length >= 2 ? segments[segments.length - 2] : '';

  final parsed = parseFrontmatter(text);
  var description = cleanDescription(parsed.yaml['description']);
  if (description.isEmpty) description = _firstProseLine(parsed.body);
  return (name: name, description: description);
}

/// The first line of a body that is neither blank nor a heading, clamped.
String _firstProseLine(String body) {
  for (final line in body.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('#')) continue;
    final clean = cleanDescription(trimmed);
    if (clean.isEmpty) continue;
    return clean.length > _fallbackDescriptionCap
        ? clean.substring(0, _fallbackDescriptionCap)
        : clean;
  }
  return '';
}

/// The `paths` a rule applies to, and what it says it is for.
///
/// A rule declares its scope as a YAML list, or as one string, or as one
/// string with commas in it — all three are in the wild and all three mean
/// the same thing, so all three are read. `./` is stripped because a glob
/// stored with it would never match a rel path, which never carries one.
///
/// A file that is not a rule answers empty rather than null: every caller
/// stores the result, and two shapes of "nothing" would be two branches at
/// every one of them.
({List<String> paths, String description}) ruleOf(String relPath, String text) {
  const empty = (paths: <String>[], description: '');
  if (contextKindFor(relPath) != 'rule') return empty;

  final parsed = parseFrontmatter(text);
  return (
    paths: _globs(parsed.yaml['paths']),
    description: cleanDescription(parsed.yaml['description']),
  );
}

List<String> _globs(Object? raw) {
  final candidates = <String>[];
  if (raw is List) {
    for (final entry in raw) {
      if (entry is String) candidates.add(entry);
    }
  } else if (raw is String) {
    candidates.addAll(raw.split(','));
  }
  final globs = <String>[];
  for (final candidate in candidates) {
    final glob = _glob(candidate);
    if (glob.isNotEmpty) globs.add(glob);
  }
  return globs;
}

String _glob(String raw) {
  var glob = raw.trim();
  while (glob.startsWith('./')) {
    glob = glob.substring(2);
  }
  return glob.trim();
}

/// [text] with Claude Code's `@path` imports replaced by what they point at.
///
/// The one convention here that costs a read per line, and the reason the
/// reader is a callback: a `CLAUDE.md` that says `@docs/conventions.md` is
/// stating that the conventions are PART of the standing notes, and a brief
/// compiled without them is a brief that read half the instructions.
///
/// What is deliberately NOT an import:
/// - a line inside a fenced code block — a `CLAUDE.md` that documents this
///   very syntax must not import itself into its own example;
/// - an `@` that is not at the start of the trimmed line, which is an email
///   address or a decorator, and `@ ` with whitespace after it, which is
///   prose;
/// - `@~/…` and `@/…` — a home-relative or absolute path is outside the
///   directory, and this app reads through the index, which holds only what
///   is inside it;
/// - a relative path that climbs out of the root, for the same reason.
///
/// A missing file and a cycle both leave the line exactly as written. Neither
/// is an error worth a sentence: the first is a note referring to something
/// the walk did not index, and the second is what `A` importing `B` importing
/// `A` has always meant.
///
/// [selfPath] is the rel path of [text] itself, when the caller knows it. It
/// seeds the cycle stack, which is the only thing that stops `CLAUDE.md`
/// importing a file that imports `CLAUDE.md` back — the root is not on the
/// stack otherwise, and the notes would be inlined into the middle of
/// themselves.
Future<String> resolveImports(
  String text,
  Future<String?> Function(String relPath) read, {
  int hops = 2,
  String baseDir = '',
  String? selfPath,
}) =>
    _resolve(
      text,
      read,
      hops,
      baseDir,
      {if (selfPath != null && selfPath.isNotEmpty) selfPath},
    );

Future<String> _resolve(
  String text,
  Future<String?> Function(String relPath) read,
  int hops,
  String baseDir,
  Set<String> stack,
) async {
  if (hops <= 0) return _clampResolved(text);

  final out = StringBuffer();
  // Which marker opened the block, or null outside one. Remembered rather
  // than flipped, because the two markers are not interchangeable: a `~~~`
  // line inside a backtick block is CommonMark content, and treating it as
  // the close would leave the rest of the block reading as prose — where an
  // `@path` in an example gets resolved into the notes that were documenting
  // the syntax.
  String? fence;
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    final opener = trimmed.startsWith('```')
        ? '```'
        : trimmed.startsWith('~~~')
            ? '~~~'
            : null;
    if (opener != null) {
      if (fence == null) {
        fence = opener;
      } else if (fence == opener) {
        fence = null;
      }
      out.writeln(line);
      continue;
    }
    final target = fence != null ? null : _importTarget(trimmed);
    if (target == null) {
      out.writeln(line);
      continue;
    }
    final resolved = _resolvePath(baseDir, target.path);
    if (resolved == null || stack.contains(resolved)) {
      out.writeln(line);
      continue;
    }
    final contents = await read(resolved);
    if (contents == null) {
      out.writeln(line);
      continue;
    }
    final inner = await _resolve(
      contents,
      read,
      hops - 1,
      p.posix.dirname(resolved) == '.' ? '' : p.posix.dirname(resolved),
      {...stack, resolved},
    );
    // Whatever the author wrote AFTER the path stays where it was: `@docs/
    // conventions.md — the short version` is a sentence about the import,
    // and dropping it would lose the only thing saying why the file is
    // there.
    if (target.rest.isNotEmpty) out.writeln(target.rest);
    // Fenced with the path on both sides so a model reading the brief can
    // tell an imported document from the notes that imported it, and can
    // cite the file it actually came from.
    out
      ..writeln()
      ..writeln('<!-- imported: $resolved -->')
      ..writeln(inner)
      ..writeln('<!-- end $resolved -->');
  }
  return _clampResolved(out.toString());
}

/// The path an import line points at and whatever followed it, or null when
/// the line is not an import at all.
({String path, String rest})? _importTarget(String trimmed) {
  if (!trimmed.startsWith('@') || trimmed.length < 2) return null;
  final after = trimmed.substring(1);
  final space = after.indexOf(RegExp(r'\s'));
  final path = space < 0 ? after : after.substring(0, space);
  if (path.isEmpty) return null;
  // Outside the directory, and therefore outside the index.
  if (path.startsWith('~') || path.startsWith('/')) return null;
  return (
    path: path,
    rest: space < 0 ? '' : after.substring(space).trim(),
  );
}

/// [target] as a rel path from the root, or null when it climbs out of it.
String? _resolvePath(String baseDir, String target) {
  final joined = baseDir.isEmpty ? target : p.posix.join(baseDir, target);
  final normalised = p.posix.normalize(joined);
  if (normalised == '..' || normalised.startsWith('../')) return null;
  if (normalised.startsWith('/')) return null;
  return normalised;
}

String _clampResolved(String text) =>
    text.length > _resolvedCap ? text.substring(0, _resolvedCap) : text;
