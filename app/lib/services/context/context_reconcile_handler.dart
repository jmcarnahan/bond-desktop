import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../data/context_store.dart';
import '../../data/message_store.dart' show MessageStore;
import '../../models/context_models.dart';
import '../activity_log.dart';
import '../ai_worker.dart';
import '../llm/embeddings_client.dart';
import '../llm/llm_client.dart';
import 'context_chunker.dart';
import 'context_extract.dart';
import 'context_walk.dart';
import 'directory_access.dart';

/// Reads one registered directory and brings the index level with the disk.
///
/// **The pass that makes a directory a LIVING context rather than a
/// snapshot.** It is enqueued at the tail of every mail sync, per registered
/// directory, linked or not — so a project edited between two syncs is
/// re-read without anyone asking, and a reply drafted a minute later reads
/// what the owner actually wrote.
///
/// Being cheap is therefore a design constraint and not a nicety. The
/// ordinary pass over a project that has not changed is one `stat` per file
/// and nothing else: the diff is `(size, mtime)`, a hash is computed only for
/// a file that fails it, and words are read only for a file whose hash moved.
/// A directory walked less than [freshFor] ago is skipped before even that.
///
/// **Two servers' worth of failure, kept apart.** The file system's failures
/// are per-file and swallowed — one unreadable file is counted and stepped
/// over, because a permissions oddity three folders down must never stop a
/// project being indexed. The embedding server's failure is not: an
/// unavailable server throws [LlmUnavailableException], which parks this kind
/// alone with no attempt spent, and the walk is stamped FIRST so the text and
/// the passages already stored survive and the next pass pays only for the
/// embedding tail.
///
/// Concurrency one: two passes over the same directory would each be
/// deciding what changed against a table the other is mid-way through
/// rewriting.
class ContextReconcileHandler extends WorkHandler {
  final ContextStore _context;
  final EmbeddingsClient _embeddings;
  final DirectoryAccess _access;
  final ActivityLog _log;

  ContextReconcileHandler(
    this._context,
    this._embeddings,
    this._access, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'context_reconcile';

  @override
  int get concurrency => 1;

  /// How recently a directory must have been walked to be left alone.
  ///
  /// One minute, matched to the sync poll: the enqueue happens on every sync
  /// and a user pressing Re-read now lands beside one, so without this a
  /// hurried minute would walk the same folder three times. A pass that the
  /// user asked for says `{"force": true}` and skips this rung.
  static const Duration freshFor = Duration(seconds: 60);

  @override
  Future<void> run(Map<String, Object?> item) async {
    final dirId = item['entity_id'] as String? ?? '';
    final dir = await _context.directory(dirId);
    if (dir == null) {
      // Queued, then the user de-registered the folder before the worker
      // reached it. Done, not failed.
      _skip('gone');
      return;
    }

    final forced = _forced(item['payload_json']);
    final now = DateTime.now().toUtc();
    if (!forced && _walkedWithin(dir.walkedAt, now)) {
      _skip('fresh');
      return;
    }

    final root = await _resolveRoot(dir);
    if (root == null) {
      await _context.setDirectoryStatus(
        dirId,
        status: 'unavailable',
        error: 'This folder could not be opened. It may have been moved, '
            'renamed or deleted — pick it again to restore access.',
      );
      _skip('unavailable');
      return;
    }

    await _context.setDirectoryStatus(dirId, status: 'reading');

    try {
      await _readInto(dirId, dir, root, now);
    } on LlmUnavailableException {
      // The embedding server, not the folder. The walk is already stamped
      // and everything read is already stored, so the row is `ready` and the
      // worker parks this kind with no attempt spent.
      rethrow;
    } catch (e) {
      // Everything else. `reading` is written before the walk and only a
      // completed walk clears it, so a throw in between would leave the
      // Settings row saying `reading…` for good — long after the worker had
      // spent its two attempts and given up. The rethrow is deliberate: the
      // work row must still record the failure and spend the attempt.
      await _context.setDirectoryStatus(
        dirId,
        status: 'error',
        error: 'Reading this folder failed: $e',
      );
      rethrow;
    }
  }

  /// One pass over the folder, from the walk to the stamp.
  ///
  /// Split out of [run] so that every way this can throw — a write that
  /// failed, an extractor that met a shape nobody planned for — leaves the
  /// directory row saying so rather than saying `reading`.
  Future<void> _readInto(
    String dirId,
    ContextDir dir,
    String root,
    DateTime now,
  ) async {
    final walk = await walkDirectory(root, honorGitignore: dir.honorGitignore);
    final stored = {
      for (final file in await _context.filesFor(dirId)) file.relPath: file,
    };
    final walkedPaths = {for (final file in walk.files) file.relPath};
    final claudeMdPaths = {
      for (final file in walk.files)
        if (contextKindFor(file.relPath) == 'claude_md') file.relPath,
    };

    final seenAt = MessageStore.isoStamp(now);
    final touched = <int>[];
    final changedFileIds = <int>[];
    final renamedFrom = <String>{};
    final hashes = <String, String>{};
    var changed = 0;
    var renamed = 0;
    var errors = 0;
    var chunkCount = 0;
    var textBytes = 0;

    for (final file in walk.files) {
      if (file.isText) textBytes += file.size;
      final existing = stored[file.relPath];

      // The cheap diff. A file whose stat is unchanged is not opened at all,
      // which is what makes a no-op pass over a large project a stat walk.
      if (existing != null &&
          existing.size == file.size &&
          existing.mtime == file.mtime) {
        touched.add(existing.id);
        hashes[file.relPath] = existing.sha256;
        continue;
      }

      final List<int> bytes;
      try {
        bytes = await File('$root/${file.relPath}').readAsBytes();
      } on FileSystemException catch (e) {
        // One unreadable file is a fact about that file. Counted, stepped
        // over, and the row it already has is left exactly as it was — which
        // includes staying out of the deletion sweep, because a file that
        // could not be read is not a file that is gone.
        errors += 1;
        if (existing != null) touched.add(existing.id);
        _log.note({'error_path': file.relPath, 'error': e.osError?.message});
        continue;
      }
      final sha = sha256.convert(bytes).toString();
      hashes[file.relPath] = sha;

      // A file whose bytes are unchanged under a new stat — touched by a
      // checkout, rewritten identically — costs the hash and nothing more.
      if (existing != null && existing.sha256 == sha) {
        await _context.upsertFile(
          dirId: dirId,
          relPath: file.relPath,
          size: file.size,
          mtime: file.mtime,
          sha256: sha,
          kind: contextKindFor(file.relPath),
          claudeChain: claudeChainFor(file.relPath, claudeMdPaths),
          description: existing.description,
          pathsJson: existing.pathsJson,
          textChars: existing.textChars,
          // The bytes did not move, so neither did the extractor's verdict
          // on whether it read all of them.
          status: existing.status,
        );
        touched.add(existing.id);
        continue;
      }

      // A MOVE: these bytes are already indexed under a path the walk no
      // longer sees. Renaming the row keeps its passages, its vectors and
      // its digest — the whole payoff of hashing, and the difference between
      // a reorganised project costing nothing and costing the entire index.
      if (existing == null) {
        final moved = [
          for (final candidate in await _context.filesBySha(dirId, sha))
            if (!walkedPaths.contains(candidate.relPath) &&
                !renamedFrom.contains(candidate.relPath))
              candidate,
        ];
        if (moved.isNotEmpty) {
          final from = moved.first;
          renamedFrom.add(from.relPath);
          await _context.renameFile(from.id, file.relPath);
          // The passages are kept — a rename must cost no embedding — but
          // the word index files them under the OLD path, and its backfill
          // fence (count, highest id, summed characters) does not move when
          // a row is renamed. Dropping the rows moves the count, so the
          // `ensureKeywordIndex()` at the end of this same pass re-files
          // them under the new path. What is deliberately NOT redone is the
          // chunking: the `<old path> · locator` header inside `chunk_text`
          // goes stale, and the renderer strips that first line and reads
          // `rel_path` off the file row instead.
          await _context.invalidateKeywordRows(from.id);
          await _context.upsertFile(
            dirId: dirId,
            relPath: file.relPath,
            size: file.size,
            mtime: file.mtime,
            sha256: sha,
            kind: contextKindFor(file.relPath),
            claudeChain: claudeChainFor(file.relPath, claudeMdPaths),
            description: from.description,
            pathsJson: from.pathsJson,
            textChars: from.textChars,
            status: from.status,
          );
          touched.add(from.id);
          renamed += 1;
          continue;
        }
      }

      // New, or genuinely edited. This is the only branch that reads words.
      final extracted =
          file.isText ? extractContextText(file.relPath, bytes) : null;
      final text = extracted?.text ?? '';
      final id = await _context.upsertFile(
        dirId: dirId,
        relPath: file.relPath,
        size: file.size,
        mtime: file.mtime,
        sha256: sha,
        kind: contextKindFor(file.relPath),
        claudeChain: claudeChainFor(file.relPath, claudeMdPaths),
        description: existing?.description,
        pathsJson: existing?.pathsJson,
        textChars: text.length,
        // A cap bit: the megabyte ceiling or the forty-row table cut. The
        // row has to say so, because everything downstream — a digest, a
        // passage quoted into a reply — is then about part of a file and
        // must not read as the whole of one.
        status: extracted?.truncated == true ? 'truncated' : 'ok',
      );
      touched.add(id);
      changed += 1;

      if (text.trim().isEmpty) {
        // A file with no words keeps its row — it is still in the folder and
        // the panel lists it — and loses everything derived from words.
        await _context.clearFileText(id);
        await _context.replaceChunks(id, const []);
      } else {
        await _context.setFileText(id, text);
        final chunks = chunkContextText(file.relPath, text);
        await _context.replaceChunks(
          id,
          [
            for (final chunk in chunks)
              (seq: chunk.seq, locator: chunk.locator, text: chunk.text),
          ],
        );
        chunkCount += chunks.length;
      }
      // The digest describes text nobody has any more.
      await _context.resetFileDigest(id);
      changedFileIds.add(id);
    }

    await _context.touchFilesSeen(dirId, touched, seenAt);

    // Everything the walk did not account for is gone from the folder.
    final kept = touched.toSet();
    final removedIds = [
      for (final file in stored.values)
        if (!kept.contains(file.id)) file.id,
    ];
    await _context.deleteFiles(removedIds);

    // Phase 2: enqueue context_digest / context_brief here — one digest per
    // changed text file when `dir.digests`, capped per pass, and one brief
    // for the directory when anything changed at all.

    // A `CLAUDE.md` appearing or disappearing changes the standing notes for
    // every file BELOW it, including files this pass never touched. Compared
    // rather than rewritten, so the ordinary pass writes nothing.
    var rechained = 0;
    for (final file in await _context.filesFor(dirId)) {
      final chain = claudeChainFor(file.relPath, claudeMdPaths);
      if (_sameChain(file.claudeChain, chain)) continue;
      await _context.setFileChain(file.id, chain);
      rechained += 1;
    }

    // Everything un-embedded in the directory, not only what this pass
    // changed: a previous pass may have parked on a dead embedding server
    // part-way through, and nothing else would ever notice the tail.
    final pending = await _context.unembeddedChunksForDir(dirId);
    final walkedAt = MessageStore.isoStamp(DateTime.now());
    final rootHash = _rootHash(walk.files, hashes);
    var embedded = 0;
    for (final chunk in pending) {
      final result = await _embeddings.embedResult(
        chunk.text,
        prefix: EmbeddingsClient.documentPrefix,
      );
      final vector = result.vector;
      if (vector == null) {
        if (result.outcome == EmbedOutcome.unavailable) {
          // The walk is stamped BEFORE the throw. Everything read this pass
          // — the rows, the words, the passages — is already stored, and
          // stamping says so: the next pass finds nothing changed, skips
          // every read, and pays only for the embedding tail. Throwing parks
          // this kind alone with no attempt spent.
          await _context.setDirectoryWalked(
            dirId,
            walkedAt: walkedAt,
            rootHash: rootHash,
            filesCount: walk.files.length,
            textBytes: textBytes,
          );
          await _context.indexPendingChunks();
          await _context.ensureKeywordIndex();
          _log.note({
            'files_seen': walk.files.length,
            'changed': changed,
            'embedded': embedded,
          });
          throw const LlmUnavailableException('embedding server unavailable');
        }
        // Rejected: the server read the request and said no, so the next
        // attempt reads the same no. The row keeps a NULL embedding, which
        // is invisible to both the index's backfill and every KNN.
        continue;
      }
      await _context.setChunkEmbedding(
        chunk.id,
        // The vector's own width, not the index's constant: a wrong-width
        // blob has to be visibly wrong in the table rather than quietly
        // refused.
        embedding: encodeEmbedding(vector),
        dims: vector.length,
        embedModel: EmbeddingsClient.documentModelTag,
      );
      embedded += 1;
    }

    await _context.indexPendingChunks();
    await _context.ensureKeywordIndex();

    await _context.setDirectoryWalked(
      dirId,
      walkedAt: walkedAt,
      rootHash: rootHash,
      filesCount: walk.files.length,
      textBytes: textBytes,
    );

    _log.note({
      'files_seen': walk.files.length,
      'changed': changed,
      'removed': removedIds.length,
      'renamed': renamed,
      'chunks': chunkCount,
      'embedded': embedded,
      if (rechained > 0) 'rechained': rechained,
      if (errors > 0) 'errors': errors,
      if (walk.truncated) 'truncated': true,
    });
  }

  /// Where to read the directory from, or null when it cannot be read.
  ///
  /// The ladder, in order: a stored bookmark is resolved first, because on a
  /// sandboxed build it is the only thing that grants access after a
  /// relaunch. A null answer from the seam is NOT a failure — an unsandboxed
  /// build and every test resolve nothing — so it falls through to the
  /// stored path, and only a path that is not there or not listable is
  /// `unavailable`.
  Future<String?> _resolveRoot(ContextDir dir) async {
    var path = dir.path;
    final bookmark = dir.bookmark;
    if (bookmark != null) {
      final resolved = await _access.resolve(bookmark);
      if (resolved != null && resolved.isNotEmpty) path = resolved;
    }
    final directory = Directory(path);
    if (!directory.existsSync()) return null;
    try {
      // Existing is not readable. One listing entry costs nothing and is the
      // only thing that tells a folder the sandbox will open from one it
      // will not.
      await directory.list(followLinks: false).take(1).toList();
    } on FileSystemException {
      return null;
    }
    return path;
  }

  /// Whether the caller asked for this pass by hand.
  static bool _forced(Object? payloadJson) {
    if (payloadJson is! String || payloadJson.isEmpty) return false;
    try {
      final decoded = jsonDecode(payloadJson);
      return decoded is Map && decoded['force'] == true;
    } on FormatException {
      return false;
    }
  }

  /// Whether the last walk is inside [freshFor] of [now].
  ///
  /// A directory that has never been walked is infinitely stale, which is
  /// correct: the first pass after Add directory must run.
  static bool _walkedWithin(String? walkedAt, DateTime now) {
    if (walkedAt == null || walkedAt.isEmpty) return false;
    final stamp = DateTime.tryParse(walkedAt);
    if (stamp == null) return false;
    return now.difference(stamp.toUtc()) < freshFor;
  }

  /// One hash over `relPath|sha256` for every file, sorted — what says
  /// "nothing in this folder moved" in a single comparison.
  ///
  /// Files whose bytes could not be read contribute their path and an empty
  /// hash, so a file that becomes readable later does move the number.
  static String _rootHash(
    List<WalkedFile> files,
    Map<String, String> hashes,
  ) {
    final lines = [
      for (final file in files) '${file.relPath}|${hashes[file.relPath] ?? ''}',
    ]..sort();
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }

  static bool _sameChain(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _skip(String reason) => _log
    ..noteStatus('skipped')
    ..note({'reason': reason});
}
