import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/context_store.dart';
import '../../models/context_models.dart';
import '../activity_log.dart';
import '../ai_worker.dart';
import '../llm/context_brief_task.dart';
import '../llm/json_task.dart';
import '../llm/llm_client.dart';
import 'claude_conventions.dart';

/// Compiles one directory's standing knowledge into a brief.
///
/// One call per directory, and only when what it reads has actually moved.
/// The brief answers what no retrieved passage can — what this project IS,
/// how the owner writes about it, which file to reach for — and it is read
/// FIRST by every reply drafted on a thread the directory is linked to.
///
/// Its two inputs are the two things a project says about itself without
/// being asked: the root `CLAUDE.md` with its `@` imports resolved, and the
/// map of every file digest. Nested `CLAUDE.md` files are deliberately NOT
/// read here — each file row carries its own chain, and the nested notes
/// ride along with a retrieved passage instead. That is Claude Code's own
/// on-demand rule, and it costs zero extra calls per subtree.
///
/// Concurrency one, like every kind that writes a directory row.
class ContextBriefHandler extends WorkHandler {
  /// A brief is longer than a digest — an `about`, six guidance lines, eight
  /// facts, ten pointers and a vocabulary — and it is written once per
  /// change rather than once per file.
  static const int _maxTokens = 768;

  /// The root notes, by the only name Claude Code gives them.
  static const String _rootNotes = 'CLAUDE.md';

  /// How many digested files ride in the map. Two hundred lines is already
  /// past the task's own character ceiling for most projects, and the newest
  /// are first, so the cut falls on the files nobody has touched in months.
  static const int _maxMappedFiles = 200;

  final ContextStore _context;
  final LlmClient _client;
  final ActivityLog _log;

  ContextBriefHandler(
    this._context,
    this._client, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'context_brief';

  @override
  int get concurrency => 1;

  @override
  Future<void> run(Map<String, Object?> item) async {
    final dirId = item['entity_id'] as String? ?? '';
    final dir = await _context.directory(dirId);
    if (dir == null) {
      _skip('gone');
      return;
    }

    final claudeMd = await _resolvedNotes(dirId);
    final mapped = await _context.filesWithDigests(
      dirId,
      limit: _maxMappedFiles,
    );
    final fileMap = _fileMap(mapped);

    if (claudeMd.isEmpty && fileMap.isEmpty) {
      // Neither standing notes nor a single digest. The brief is CLEARED
      // rather than left alone: a project that lost its `CLAUDE.md` must not
      // keep handing replies the guidance it used to give.
      await _context.setDirectoryBrief(dirId, briefJson: null, briefHash: null);
      _skip('nothing_to_brief');
      return;
    }

    // The hash is over the two inputs and nothing else, separated so that
    // moving a character across the boundary changes it. It is what makes
    // the reconcile pass free to queue this kind on every pass that did
    // anything at all: an unchanged project pays a read and no call.
    final hash = sha256.convert(utf8.encode('$claudeMd $fileMap')).toString();
    if (hash == dir.briefHash) {
      _skip('unchanged');
      return;
    }

    // Exceptions propagate — the worker owns the ladder — and the hash is
    // written only WITH the brief it describes. A hash stamped before the
    // call would tell the next pass this directory was briefed with notes no
    // brief was ever compiled from.
    final brief = await runTask(
      _client,
      const ContextBriefTask(),
      ContextBriefInput(
        displayName: dir.displayName,
        claudeMd: claudeMd,
        fileMap: fileMap,
        now: DateTime.now(),
      ),
      temperature: 0,
      maxTokens: _maxTokens,
    );

    await _context.setDirectoryBrief(
      dirId,
      briefJson: jsonEncode(brief.toJson()),
      briefHash: hash,
    );

    _log.note({
      'files_mapped': mapped.length,
      'has_claude_md': claudeMd.isNotEmpty,
      'pointers': brief.pointers.length,
    });
  }

  /// The root `CLAUDE.md` with its imports resolved, or empty.
  ///
  /// Read through the INDEX rather than off the disk, which is the whole
  /// reason [resolveImports] takes a reader: this handler runs long after the
  /// walk, on a queue of its own, against a folder the sandbox may no longer
  /// be inside. Whatever the last pass stored is what the brief is compiled
  /// from, and an import pointing at a file the walk never indexed is left
  /// in the notes as the line the author wrote.
  ///
  /// Clamped HERE, to the same ceiling the task clamps to. The hash below is
  /// what decides whether this directory is briefed again, so it has to be a
  /// hash of what the prompt actually carries: an edit past character eight
  /// thousand of a long `CLAUDE.md` moves an unclamped hash and buys a call
  /// that reads the identical prompt.
  Future<String> _resolvedNotes(String dirId) async {
    final notes = await _context.fileByPath(dirId, _rootNotes);
    if (notes == null) return '';
    final text = await _context.fileText(notes.id);
    if (text == null || text.isEmpty) return '';
    final resolved = await resolveImports(
      text,
      (relPath) async {
        final file = await _context.fileByPath(dirId, relPath);
        return file == null ? null : _context.fileText(file.id);
      },
      selfPath: _rootNotes,
    );
    return resolved.length > ContextBriefTask.notesCap
        ? resolved.substring(0, ContextBriefTask.notesCap)
        : resolved;
  }

  /// One line per digested file: `path · purpose · questions`.
  ///
  /// The questions matter as much as the purpose. They are what tell the
  /// model which file answers which kind of question, which is exactly what
  /// a pointer is — so the map is shaped like the answer it is asking for.
  ///
  /// A row whose JSON will not decode is DROPPED rather than rendered as a
  /// bare path: a line saying a file exists and nothing else spends a line
  /// of the map on nothing.
  String _fileMap(List<ContextFile> files) {
    final lines = <String>[];
    for (final file in files) {
      final digest = ContextFileDigest.decode(file.digestJson);
      if (digest == null) continue;
      final questions = digest.questionsAnswered.join('; ');
      lines.add([
        file.relPath,
        if (digest.purpose.isNotEmpty) digest.purpose,
        if (questions.isNotEmpty) questions,
      ].join(' · '));
    }
    final map = lines.join('\n');
    return map.length > ContextBriefTask.fileMapCap
        ? map.substring(0, ContextBriefTask.fileMapCap)
        : map;
  }

  void _skip(String reason) => _log
    ..noteStatus('skipped')
    ..note({'reason': reason});
}
