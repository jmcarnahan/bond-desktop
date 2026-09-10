/// Reading what is IN a registered directory — the one part of this feature
/// that touches the file system, and nothing else here does.
///
/// Everything below is a decision about paths and stat results. It runs on
/// every sync against every registered directory, so it is a stat walk and
/// never a read: the only bytes it opens are the first 8 KB of a text
/// candidate, to tell words from a binary that happens to end in `.txt`.
///
/// The rules it enforces are the ones a person would state out loud about
/// their own project: skip the machinery (`.git`, `node_modules`, a build
/// directory), skip anything that looks like a secret, read the notes and the
/// code and the analyses, and stop before the folder is large enough to be a
/// problem.
library;

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Directory names skipped wherever they appear in the tree.
///
/// Machinery and caches, not content. Every one of them is either generated
/// from something else in the same folder or belongs to a tool — indexing any
/// of them would bury the project's own words under a dependency tree.
const List<String> contextDenylist = [
  '.git',
  'node_modules',
  '.dart_tool',
  'build',
  'dist',
  '.venv',
  '__pycache__',
];

/// File shapes skipped wherever they appear.
///
/// Two different reasons in one list. A lock file is machine-written noise
/// hundreds of lines long; the other three are how secrets are spelled, and
/// a public repo's worth of caution says an app that reads a person's folders
/// must not be the thing that copies their private key into a database.
const List<String> contextFileDenylist = [
  '*.lock',
  '.env*',
  '*.pem',
  '*.key',
];

/// The most files one directory contributes.
const int defaultMaxFiles = 5000;

/// The most on-disk bytes of TEXT one directory contributes.
const int defaultMaxTextBytes = 50 * 1024 * 1024;

/// A text candidate larger than this is listed and not read. Four megabytes
/// of one file is a log or a dump, not a document, and it would be most of
/// the whole-directory budget on its own.
const int maxContextFileBytes = 4 * 1024 * 1024;

/// How much of a file is sniffed for a NUL byte. A binary that got a text
/// extension announces itself in its header; reading further to be sure
/// would be reading the file, which is what the sniff exists to avoid.
const int _sniffBytes = 8 * 1024;

/// Extensions whose contents are words. Lowercase, without the dot.
///
/// An allowlist rather than a denylist, because the failure modes are not
/// symmetric: an unlisted text file is a file the user can still open in the
/// app, while an unlisted BINARY read as text is a megabyte of mojibake in
/// the index and one wasted embedding per passage of it.
const Set<String> contextTextExtensions = {
  'md', 'markdown', 'txt', 'rst', 'html', 'htm', 'ipynb', //
  'csv', 'tsv', 'json', 'yaml', 'yml', 'toml', 'xml', 'sql', //
  'sh', 'py', 'js', 'ts', 'tsx', 'jsx', 'dart', 'go', 'rs', //
  'java', 'kt', 'swift', 'rb', 'r', 'c', 'h', 'cpp', 'hpp', //
  'cs', 'php', 'css', 'scss', 'log', 'ini', 'cfg', 'conf', //
};

/// Files that are text and have no extension to say so. The four names a
/// project puts its instructions in.
const Set<String> contextTextNames = {
  'CLAUDE.md',
  'README',
  'Makefile',
  'Dockerfile',
  'env.example',
};

/// Extensions whose text is source code — chunked by line window rather than
/// by heading, because code has no headings and a 60-line window is a
/// function.
const Set<String> contextCodeExtensions = {
  'dart', 'py', 'js', 'ts', 'tsx', 'jsx', 'sql', 'sh', 'go', //
  'rs', 'java', 'kt', 'swift', 'rb', 'r', 'c', 'h', 'cpp', //
  'hpp', 'cs', 'php', //
};

/// Extensions that are tabular or structured records rather than prose.
const Set<String> contextDataExtensions = {
  'csv',
  'tsv',
  'json',
  'parquet',
  'xlsx',
};

/// Extensions that are prose a person wrote or a tool rendered.
const Set<String> contextDocExtensions = {
  'md', 'markdown', 'txt', 'rst', 'html', 'htm', 'ipynb', //
  'yaml', 'yml', 'toml', 'xml', //
};

/// One file the walk found, and whether its words are worth reading.
class WalkedFile {
  /// Relative to the root, always with `/` separators whatever the platform
  /// uses — the path is stored, cited in a reply, and compared against
  /// patterns, and all three want one spelling.
  final String relPath;

  final int size;

  /// The modification time, ISO-8601 UTC. Half of the cheap diff, and text
  /// rather than a `DateTime` because that is what the column holds and a
  /// comparison across the two representations is a bug waiting for a
  /// timezone.
  final String mtime;

  /// Whether the extractor should be asked for this file's words.
  final bool isText;

  /// Why not, when [isText] is false: `binary`, `too_large`, or
  /// `not_text` for a shape with no extractor.
  final String? reason;

  const WalkedFile({
    required this.relPath,
    required this.size,
    required this.mtime,
    required this.isText,
    this.reason,
  });
}

/// What one pass over a directory found.
class WalkResult {
  final List<WalkedFile> files;

  /// True when a cap cut the list short — the row says so, because a
  /// half-indexed directory that looks complete is worse than one that
  /// admits it.
  final bool truncated;

  /// How many paths were skipped by the denylists, the dot rule, the ignore
  /// files or an unreadable stat. Diagnostic only.
  ///
  /// A pruned or unreadable DIRECTORY counts once, not once per file inside
  /// it: the walk never listed those files, which is the whole reason it
  /// prunes the folder rather than filtering its contents.
  final int skipped;

  const WalkResult({
    required this.files,
    required this.truncated,
    required this.skipped,
  });
}

/// Walks [root] and reports every file the app is allowed to index.
///
/// Symlinks are NOT followed, and that is a correctness rule rather than a
/// performance one: a project with a link to its own parent is a walk that
/// never ends, and a link out of the directory is a path the user never
/// granted access to.
///
/// [honorGitignore] is off by default because Claude Code analyses land in
/// gitignored `output/` and `reports/` folders — the very files this feature
/// exists to read. The hard denylists and `.bondignore` apply either way.
///
/// [maxFiles] and [maxTextBytes] are parameters so a test can make a cap bite
/// on five files instead of five thousand.
Future<WalkResult> walkDirectory(
  String root, {
  bool honorGitignore = false,
  int maxFiles = defaultMaxFiles,
  int maxTextBytes = defaultMaxTextBytes,
}) async {
  final directory = Directory(root);
  if (!directory.existsSync()) {
    return const WalkResult(files: [], truncated: false, skipped: 0);
  }

  // Two lists, matched against two different things. The hard denylist is
  // about a file's NAME wherever it sits — a `.env` three folders down is
  // still a secret — while an ignore-file pattern is a statement about a
  // path relative to the root, which is what gitignore syntax means.
  final denied = [for (final pattern in contextFileDenylist) Glob(pattern)];
  final ignores = <Glob>[
    ...await _readIgnoreFile(root, '.bondignore'),
    if (honorGitignore) ...await _readIgnoreFile(root, '.gitignore'),
  ];

  final found = <WalkedFile>[];
  var skipped = 0;

  // The recursion is explicit, and both reasons are about what a real
  // project folder holds. `list(recursive: true)` descends into
  // `node_modules` and `.git` and hands back every path inside them for the
  // filter to throw away — fifty thousand stats a minute to index nothing —
  // and it reports a subdirectory it cannot open by putting a
  // `FileSystemException` into the stream, which ends the walk and leaves
  // the whole project unindexed over one folder's permissions. Descending by
  // hand prunes a denied tree before it is entered and steps over an
  // unreadable one.
  //
  // A stack rather than a queue: the order out of here does not matter,
  // because the caps sort by precedence and the result is sorted by path.
  final pending = <String>[''];
  while (pending.isNotEmpty) {
    final relDir = pending.removeLast();
    final absDir =
        relDir.isEmpty ? root : p.join(root, p.joinAll(relDir.split('/')));

    try {
      await for (final entity in Directory(absDir).list(followLinks: false)) {
        final name = p.basename(entity.path);
        final relPath = relDir.isEmpty ? name : '$relDir/$name';

        if (entity is Directory) {
          if (_isDeniedDirectory(name) ||
              ignores.any((glob) => glob.matches(relPath))) {
            // ONE skip for the whole tree, not one per file inside it — the
            // files under a pruned directory are never listed, which is the
            // point of pruning it.
            skipped += 1;
            continue;
          }
          pending.add(relPath);
          continue;
        }
        // A symlink comes back as a [Link] under `followLinks: false`, which
        // is the ONE place it can be recognised — a stat follows the link and
        // describes what it points at. Counted and not followed: a project
        // with a link to its own parent is a walk that never ends, and a link
        // out of the directory is a path the user never granted access to.
        if (entity is Link) {
          skipped += 1;
          continue;
        }
        if (entity is! File) continue;

        if (denied.any((glob) => glob.matches(name)) ||
            ignores.any((glob) => glob.matches(relPath))) {
          skipped += 1;
          continue;
        }

        final FileStat stat;
        try {
          stat = entity.statSync();
        } on FileSystemException {
          // A file that vanished between the listing and the stat, or one the
          // sandbox will not describe. Counted and stepped over — one
          // unreadable file must never end a walk.
          skipped += 1;
          continue;
        }

        final mtime = stat.modified.toUtc().toIso8601String();
        final size = stat.size;

        if (!_looksLikeText(relPath)) {
          found.add(WalkedFile(
            relPath: relPath,
            size: size,
            mtime: mtime,
            isText: false,
            reason: 'not_text',
          ));
          continue;
        }
        if (size > maxContextFileBytes) {
          found.add(WalkedFile(
            relPath: relPath,
            size: size,
            mtime: mtime,
            isText: false,
            reason: 'too_large',
          ));
          continue;
        }
        if (_hasNulByte(entity)) {
          found.add(WalkedFile(
            relPath: relPath,
            size: size,
            mtime: mtime,
            isText: false,
            reason: 'binary',
          ));
          continue;
        }
        found.add(WalkedFile(
          relPath: relPath,
          size: size,
          mtime: mtime,
          isText: true,
        ));
      }
    } on FileSystemException {
      // A folder the permissions or the sandbox will not list. Counted once
      // and stepped over, for the same reason one unreadable file is: a
      // permissions oddity three folders down must never cost the project.
      skipped += 1;
    }
  }

  final capped = _applyCaps(
    found,
    maxFiles: maxFiles,
    maxTextBytes: maxTextBytes,
    skipped: skipped,
  );
  // Sorted by path on the way out: the caps needed precedence order to
  // decide what to keep, and every reader after this wants the order a
  // person would list a folder in.
  capped.files.sort((a, b) => a.relPath.compareTo(b.relPath));
  return capped;
}

/// Whether a directory called [name] is denied outright, wherever it sits.
///
/// Asked before the folder is entered, so nothing inside a denied tree is
/// ever listed. The dot rule sits here rather than in the denylist because it
/// is a rule and not a list: every dot-directory is tooling, EXCEPT
/// `.claude`, which is the one place a Claude Code project keeps the
/// instructions this whole feature is about. A dot FILE is kept —
/// `.bondignore` and `.gitignore` are read by name, and a lone
/// `.something.md` in a project is a note.
bool _isDeniedDirectory(String name) {
  if (contextDenylist.contains(name)) return true;
  return name.startsWith('.') && name != '.claude';
}

/// The patterns in one ignore file at the root, or none.
///
/// A SUBSET of gitignore syntax, stated rather than implied: one glob per
/// line, `#` comments, blank lines skipped. Negation (`!`) and
/// anchored-vs-floating semantics are not implemented — a pattern here is
/// matched against the whole rel path, and a person who wants a folder gone
/// writes `output/**`.
///
/// Only the root file is read. A per-directory `.gitignore` would need the
/// full spec to be honest about it, and half of the spec is worse than none.
Future<List<Glob>> _readIgnoreFile(String root, String name) async {
  final file = File(p.join(root, name));
  if (!file.existsSync()) return const [];
  final String text;
  try {
    text = await file.readAsString();
  } on FileSystemException {
    return const [];
  }
  final globs = <Glob>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    try {
      // A trailing slash means "this directory"; the walk sees files, so it
      // becomes "everything under it".
      globs.add(Glob(line.endsWith('/') ? '$line**' : line));
    } on FormatException {
      // A pattern this glob dialect cannot parse ignores nothing rather than
      // failing the walk.
      continue;
    }
  }
  return globs;
}

/// Whether the extension or the file name says this holds words.
bool _looksLikeText(String relPath) {
  final name = p.posix.basename(relPath);
  if (contextTextNames.contains(name)) return true;
  final ext = p.posix.extension(name);
  if (ext.isEmpty) return false;
  return contextTextExtensions.contains(ext.substring(1).toLowerCase());
}

/// Whether the first [_sniffBytes] hold a NUL — the one reliable, cheap sign
/// that a file with a text extension is not text.
bool _hasNulByte(File file) {
  RandomAccessFile? handle;
  try {
    handle = file.openSync();
    final bytes = handle.readSync(_sniffBytes);
    return bytes.contains(0);
  } on FileSystemException {
    // Unreadable is not the same as binary, but the outcome is: there are no
    // words here to index.
    return true;
  } finally {
    handle?.closeSync();
  }
}

/// Cuts the list to the caps, keeping what a person would keep.
///
/// Precedence, in order: everything under `.claude` (the skills and rules
/// that shape a reply), every `CLAUDE.md` (the standing notes), every
/// `README*` (what the project says it is), everything under `docs/`, then
/// the rest by path. A directory too large to index whole should still index
/// the part that says what it IS.
///
/// The byte cap counts only text files, because a listed binary costs a row
/// and nothing else.
WalkResult _applyCaps(
  List<WalkedFile> files, {
  required int maxFiles,
  required int maxTextBytes,
  required int skipped,
}) {
  files.sort((a, b) {
    final rank = _precedence(a.relPath).compareTo(_precedence(b.relPath));
    return rank != 0 ? rank : a.relPath.compareTo(b.relPath);
  });

  final kept = <WalkedFile>[];
  var truncated = false;
  var textBytes = 0;
  for (final file in files) {
    if (kept.length >= maxFiles) {
      truncated = true;
      break;
    }
    if (file.isText && textBytes + file.size > maxTextBytes) {
      // The BYTE cap demotes rather than drops: the row still says the file
      // is there, which is what stops a later pass re-discovering it as new
      // on every sync.
      truncated = true;
      kept.add(WalkedFile(
        relPath: file.relPath,
        size: file.size,
        mtime: file.mtime,
        isText: false,
        reason: 'too_large',
      ));
      continue;
    }
    if (file.isText) textBytes += file.size;
    kept.add(file);
  }

  return WalkResult(files: kept, truncated: truncated, skipped: skipped);
}

int _precedence(String relPath) {
  if (relPath.startsWith('.claude/')) return 0;
  if (p.posix.basename(relPath) == 'CLAUDE.md') return 1;
  if (p.posix.basename(relPath).startsWith('README')) return 2;
  if (relPath.startsWith('docs/')) return 3;
  return 4;
}

/// What kind of thing a file is, from its path alone.
///
/// Path and not content, because the answer decides how the file is CHUNKED
/// and what the retrieval does with it, and both have to be settled before
/// anything reads a byte. The two Claude Code conventions come first: a
/// `SKILL.md` inside `.claude/skills/<name>/` is guidance the reply may
/// follow, and a `.claude/rules/*.md` applies to the paths its frontmatter
/// names.
String contextKindFor(String relPath) {
  final name = p.posix.basename(relPath);
  if (name == 'CLAUDE.md') return 'claude_md';

  final segments = relPath.split('/');
  final skillsAt = _indexOfPair(segments, '.claude', 'skills');
  if (skillsAt >= 0 &&
      name == 'SKILL.md' &&
      segments.length == skillsAt + 4) {
    return 'skill';
  }
  final rulesAt = _indexOfPair(segments, '.claude', 'rules');
  if (rulesAt >= 0 &&
      segments.length == rulesAt + 3 &&
      name.toLowerCase().endsWith('.md')) {
    return 'rule';
  }

  final ext = p.posix.extension(name);
  if (ext.isEmpty) return 'other';
  final suffix = ext.substring(1).toLowerCase();
  if (contextCodeExtensions.contains(suffix)) return 'code';
  if (contextDataExtensions.contains(suffix)) return 'data';
  if (contextDocExtensions.contains(suffix)) return 'doc';
  return 'other';
}

/// Where `<first>/<second>` starts in [segments], or -1.
int _indexOfPair(List<String> segments, String first, String second) {
  for (var i = 0; i + 1 < segments.length; i++) {
    if (segments[i] == first && segments[i + 1] == second) return i;
  }
  return -1;
}

/// Every `CLAUDE.md` that governs [relPath], root first.
///
/// Claude Code's own rule, and the reason each file row stores its own chain:
/// a passage retrieved from `analysis/pricing/model.py` should arrive with
/// the notes in `analysis/CLAUDE.md` attached, without the app having briefed
/// every nested `CLAUDE.md` in the project at reconcile time.
///
/// A file never governs itself, so the root `CLAUDE.md` has an empty chain.
List<String> claudeChainFor(String relPath, Set<String> claudeMdPaths) {
  final segments = relPath.split('/');
  final chain = <String>[];
  // Depth 0 is the root `CLAUDE.md`; the last iteration is the file's own
  // directory. `segments.length - 1` is where the file name sits, and a
  // `CLAUDE.md` beside it counts.
  for (var depth = 0; depth < segments.length; depth++) {
    final candidate = depth == 0
        ? 'CLAUDE.md'
        : '${segments.take(depth).join('/')}/CLAUDE.md';
    if (candidate == relPath) continue;
    if (claudeMdPaths.contains(candidate)) chain.add(candidate);
  }
  return chain;
}
