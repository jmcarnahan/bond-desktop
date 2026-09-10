import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/context_models.dart';
// The same licence `message_store.dart` takes on this import, and for the
// same reason: `search_fusion.dart` is pure arithmetic and string work over
// the models with no I/O of its own, so reaching down for [FtsQuery] and
// [quoteTerm] costs the data layer no dependency on a service.
import '../services/search_fusion.dart';
import 'context_chunk_index.dart';
import 'database.dart' show BondDatabase;
import 'keyword_index.dart';
import 'message_store.dart' show MessageStore;

/// Everything the app stores about the owner's own local directories.
///
/// A SECOND store over the same [BondDatabase] rather than more methods on
/// the 8,000-line [MessageStore], and the split is along the only line that
/// matters: nothing here is mailbox data. A registered directory is the
/// user's own folder, it survives a sign-out, it is keyed by a path hash
/// rather than by a connector's ids, and not one read below joins a message.
/// The two stores share a connection and share nothing else.
///
/// Raw SQL through `customSelect` / `customUpdate`, exactly as [MessageStore]
/// writes it: the generated table classes are used by the migration and by
/// nothing that reads.
class ContextStore {
  ContextStore(this.db);

  final BondDatabase db;

  /// The vector half of retrieval. Lazy for [ContextChunkIndex]'s reasons —
  /// the virtual table is built at first use and never by a migration.
  late final ContextChunkIndex _chunkIndex = ContextChunkIndex(db);

  /// The word half. Same lifecycle, same promises.
  late final ContextKeywordIndex _keywordIndex = ContextKeywordIndex(db);

  static String _nowIso() => MessageStore.isoStamp(DateTime.now());

  static List<Variable> _args(List<Object?> values) => [
        for (final value in values) Variable(value),
      ];

  static String _placeholders(int n) => List.filled(n, '?').join(', ');

  /// The id a directory at [path] has, whoever asks.
  ///
  /// Derived rather than surrogate so registering the same folder twice is
  /// the same row without a lookup, and so a caller holding only a path can
  /// name the row it wants. Sixteen hex characters of sha256 is 64 bits —
  /// far past collision for a list a person curates by hand, and short enough
  /// to read in a log line.
  static String idForPath(String path) =>
      sha256.convert(utf8.encode(path)).toString().substring(0, 16);

  // ── directories ──────────────────────────────────────────────────────

  /// Records a directory, or updates the one already there, and returns its
  /// id.
  ///
  /// `INSERT OR IGNORE` then a conditional UPDATE rather than an upsert of
  /// everything, because the columns this call does NOT own are the ones a
  /// re-register would destroy: the walk stamp, the counts, the brief and the
  /// two switches all belong to passes that have already run. Re-picking the
  /// same folder in the open panel is meant to refresh the bookmark and the
  /// name, not to throw the index away.
  ///
  /// [bookmark] is written only when one was actually made. A build that
  /// keeps none hands over null, and null must not erase a bookmark an
  /// earlier sandboxed run stored.
  Future<String> registerDirectory({
    required String path,
    required String displayName,
    Uint8List? bookmark,
  }) async {
    final id = idForPath(path);
    final now = _nowIso();
    await db.customUpdate(
      'INSERT OR IGNORE INTO context_dirs '
      '(id, path, display_name, bookmark, status, error, walked_at, '
      ' root_hash, files_count, text_bytes, brief_json, brief_hash, '
      ' digests, honor_gitignore, created_at, updated_at) '
      "VALUES (?, ?, ?, ?, 'pending', NULL, NULL, NULL, 0, 0, NULL, NULL, "
      ' 1, 0, ?, ?)',
      variables: _args([id, path, displayName, bookmark, now, now]),
    );
    if (bookmark != null) {
      await db.customUpdate(
        'UPDATE context_dirs SET display_name = ?, bookmark = ?, '
        '  updated_at = ? WHERE id = ?',
        variables: _args([displayName, bookmark, now, id]),
      );
    } else {
      await db.customUpdate(
        'UPDATE context_dirs SET display_name = ?, updated_at = ? '
        'WHERE id = ?',
        variables: _args([displayName, now, id]),
      );
    }
    return id;
  }

  /// Every registered directory, by display name — the order the library
  /// section and the link panel both draw in.
  Future<List<ContextDir>> directories() async {
    final rows = await db
        .customSelect('SELECT * FROM context_dirs ORDER BY display_name, id')
        .get();
    return [for (final row in rows) ContextDir.fromRow(row.data)];
  }

  Future<ContextDir?> directory(String id) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM context_dirs WHERE id = ?',
          variables: _args([id]),
        )
        .get();
    return rows.isEmpty ? null : ContextDir.fromRow(rows.single.data);
  }

  /// Moves a directory's status, and states why when the news is bad.
  ///
  /// [error] is written unconditionally, including with null: a directory
  /// going back to `reading` has to lose the sentence explaining why the last
  /// pass could not open it, or the row keeps saying it forever.
  Future<void> setDirectoryStatus(
    String id, {
    required String status,
    String? error,
  }) async {
    await db.customUpdate(
      'UPDATE context_dirs SET status = ?, error = ?, updated_at = ? '
      'WHERE id = ?',
      variables: _args([status, error, _nowIso(), id]),
    );
  }

  /// Stamps what a completed walk found, and marks the directory `ready`.
  ///
  /// Status and error move with the counts rather than in a second call,
  /// because a row that says `ready` while carrying the previous pass's
  /// numbers is a row nobody can trust.
  Future<void> setDirectoryWalked(
    String id, {
    required String walkedAt,
    required String rootHash,
    required int filesCount,
    required int textBytes,
  }) async {
    await db.customUpdate(
      'UPDATE context_dirs SET walked_at = ?, root_hash = ?, '
      "  files_count = ?, text_bytes = ?, status = 'ready', error = NULL, "
      '  updated_at = ? WHERE id = ?',
      variables: _args([
        walkedAt,
        rootHash,
        filesCount,
        textBytes,
        _nowIso(),
        id,
      ]),
    );
  }

  /// Flips either per-directory switch. Both are nullable and only the ones
  /// given are written, so a toggle in the UI is one narrow statement rather
  /// than a read-modify-write that could lose the other one.
  Future<void> setDirectoryOptions(
    String id, {
    bool? digests,
    bool? honorGitignore,
  }) async {
    final sets = <String>[];
    final args = <Object?>[];
    if (digests != null) {
      sets.add('digests = ?');
      args.add(digests ? 1 : 0);
    }
    if (honorGitignore != null) {
      sets.add('honor_gitignore = ?');
      args.add(honorGitignore ? 1 : 0);
    }
    if (sets.isEmpty) return;
    sets.add('updated_at = ?');
    args
      ..add(_nowIso())
      ..add(id);
    await db.customUpdate(
      'UPDATE context_dirs SET ${sets.join(', ')} WHERE id = ?',
      variables: _args(args),
    );
  }

  /// Writes the compiled brief and the hash of what it was compiled FROM.
  ///
  /// Both nullable and both written: a directory that lost its `CLAUDE.md`
  /// and every digest has no brief, and leaving the old one would let a
  /// reply cite standing notes that no longer exist.
  Future<void> setDirectoryBrief(
    String id, {
    String? briefJson,
    String? briefHash,
  }) async {
    await db.customUpdate(
      'UPDATE context_dirs SET brief_json = ?, brief_hash = ?, '
      '  updated_at = ? WHERE id = ?',
      variables: _args([briefJson, briefHash, _nowIso(), id]),
    );
  }

  /// De-registers a directory and everything derived from it.
  ///
  /// One transaction, deepest first, so a failure part-way cannot leave
  /// passages pointing at files that are gone. What it does NOT reach is the
  /// two virtual tables: vec0 has no cascade and FTS5 no foreign key, so the
  /// rowids stay filed until [rebuildIndexes] runs. Both hydrate through a
  /// join that drops them, exactly as `replaceChunks` relies on, so an
  /// orphan is invisible rather than wrong.
  Future<void> removeDirectory(String id) async {
    await db.transaction(() async {
      await db.customUpdate(
        'DELETE FROM context_chunks WHERE file_id IN '
        '  (SELECT id FROM context_files WHERE dir_id = ?)',
        variables: _args([id]),
      );
      await db.customUpdate(
        'DELETE FROM context_text WHERE file_id IN '
        '  (SELECT id FROM context_files WHERE dir_id = ?)',
        variables: _args([id]),
      );
      await db.customUpdate(
        'DELETE FROM context_files WHERE dir_id = ?',
        variables: _args([id]),
      );
      await db.customUpdate(
        'DELETE FROM context_links WHERE dir_id = ?',
        variables: _args([id]),
      );
      await db.customUpdate(
        'DELETE FROM context_dirs WHERE id = ?',
        variables: _args([id]),
      );
    });
  }

  // ── links ────────────────────────────────────────────────────────────

  /// Points a room at a directory. Idempotent — linking twice is the link.
  ///
  /// [source] is the connector for a thread and `''` for a storyline; it is
  /// part of the key rather than derived because two connectors can hand out
  /// the same conversation key and the link must not leak between them.
  Future<void> link(
    String dirId,
    ContextScopeKind kind,
    String source,
    String scopeKey,
  ) async {
    await db.customUpdate(
      'INSERT OR IGNORE INTO context_links '
      '(dir_id, scope_kind, source, scope_key, added_at) VALUES (?, ?, ?, ?, ?)',
      variables: _args([dirId, kind.name, source, scopeKey, _nowIso()]),
    );
  }

  /// Drops one link. Costs no re-index, which is the whole reason the index
  /// tables hang off `dir_id` and not off a room.
  Future<void> unlink(
    String dirId,
    ContextScopeKind kind,
    String source,
    String scopeKey,
  ) async {
    await db.customUpdate(
      'DELETE FROM context_links WHERE dir_id = ? AND scope_kind = ? '
      '  AND source = ? AND scope_key = ?',
      variables: _args([dirId, kind.name, source, scopeKey]),
    );
  }

  /// Everywhere one directory is pointed at — what the two-tap Remove counts
  /// before it drops them.
  Future<List<ContextLink>> linksFor(String dirId) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM context_links WHERE dir_id = ? '
          'ORDER BY scope_kind, source, scope_key',
          variables: _args([dirId]),
        )
        .get();
    return [for (final row in rows) ContextLink.fromRow(row.data)];
  }

  Future<int> linkCount(String dirId) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM context_links WHERE dir_id = ?',
          variables: _args([dirId]),
        )
        .getSingle();
    return (row.data['n'] as num?)?.toInt() ?? 0;
  }

  /// Drops every link and keeps every directory.
  ///
  /// What sign-out calls. The links point at conversation keys and storyline
  /// ids that `wipeAll` is about to delete, so they have to go; the
  /// directories are the user's own folders and have nothing to do with
  /// whose mailbox was signed in.
  Future<void> unlinkAll() async {
    await db.customUpdate('DELETE FROM context_links');
  }

  /// Which directories a room may read: its own links, plus every link on a
  /// storyline it belongs to.
  ///
  /// The inheritance is the same one pinned documents have — a thread sees
  /// what its storyline sees — and it is a UNION rather than two calls so a
  /// directory linked both ways is named once.
  ///
  /// A caller with no conversation key and no storylines gets `const []`
  /// before any read, on `chunkKnn`'s rule: asking about nothing must not be
  /// answered with everything.
  Future<List<String>> dirIdsInScope({
    required String source,
    required String conversationKey,
    List<String> storylineIds = const [],
  }) async {
    final wantThread = conversationKey.isNotEmpty;
    if (!wantThread && storylineIds.isEmpty) return const [];

    final clauses = <String>[];
    final args = <Object?>[];
    if (wantThread) {
      clauses.add(
        "(scope_kind = 'thread' AND source = ? AND scope_key = ?)",
      );
      args
        ..add(source)
        ..add(conversationKey);
    }
    if (storylineIds.isNotEmpty) {
      clauses.add(
        "(scope_kind = 'storyline' AND scope_key IN "
        '(${_placeholders(storylineIds.length)}))',
      );
      args.addAll(storylineIds);
    }
    final rows = await db
        .customSelect(
          'SELECT DISTINCT dir_id FROM context_links '
          'WHERE ${clauses.join(' OR ')} ORDER BY dir_id',
          variables: _args(args),
        )
        .get();
    return [for (final row in rows) row.data['dir_id'] as String];
  }

  /// The directories linked to exactly one room — what the link panel's
  /// switches read.
  Future<List<String>> dirIdsLinkedTo(
    ContextScopeKind kind,
    String source,
    String scopeKey,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT dir_id FROM context_links '
          'WHERE scope_kind = ? AND source = ? AND scope_key = ? '
          'ORDER BY dir_id',
          variables: _args([kind.name, source, scopeKey]),
        )
        .get();
    return [for (final row in rows) row.data['dir_id'] as String];
  }

  // ── files ────────────────────────────────────────────────────────────

  Future<List<ContextFile>> filesFor(String dirId) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM context_files WHERE dir_id = ? ORDER BY rel_path',
          variables: _args([dirId]),
        )
        .get();
    return [for (final row in rows) ContextFile.fromRow(row.data)];
  }

  Future<ContextFile?> fileByPath(String dirId, String relPath) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM context_files WHERE dir_id = ? AND rel_path = ?',
          variables: _args([dirId, relPath]),
        )
        .get();
    return rows.isEmpty ? null : ContextFile.fromRow(rows.single.data);
  }

  Future<ContextFile?> fileById(int id) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM context_files WHERE id = ?',
          variables: _args([id]),
        )
        .get();
    return rows.isEmpty ? null : ContextFile.fromRow(rows.single.data);
  }

  /// Every row in this directory carrying [sha] — how a walk tells a MOVE
  /// from a delete-and-add.
  ///
  /// A list rather than one row because a project routinely holds the same
  /// bytes twice (a copied template, an empty `__init__.py`), and the caller
  /// is the one that knows which of them the walk no longer sees.
  Future<List<ContextFile>> filesBySha(String dirId, String sha) async {
    if (sha.isEmpty) return const [];
    final rows = await db
        .customSelect(
          'SELECT * FROM context_files WHERE dir_id = ? AND sha256 = ? '
          'ORDER BY rel_path',
          variables: _args([dirId, sha]),
        )
        .get();
    return [for (final row in rows) ContextFile.fromRow(row.data)];
  }

  /// Writes what the walk learned about one file, and returns its row id.
  ///
  /// **Never touches `digest_json`, `digest_status`, `desc_embedding` or
  /// `paths_json`/`description` beyond what it is given.** Those belong to
  /// passes that cost model calls, and a reconcile that re-read the same
  /// unchanged bytes must not make the app pay for them again. A file whose
  /// CONTENT changed has its digest reset explicitly, by [resetFileDigest],
  /// where the decision is visible.
  ///
  /// [status] is `ok` or `truncated` — the extractor's own verdict on
  /// whether it read the whole file. It is carried through every branch
  /// rather than defaulted, because a pass that only touched a file's stat
  /// must not quietly promote a fragment to a complete reading.
  Future<int> upsertFile({
    required String dirId,
    required String relPath,
    required int size,
    required String mtime,
    required String sha256,
    required String kind,
    required List<String> claudeChain,
    String? description,
    String? pathsJson,
    required int textChars,
    String status = 'ok',
  }) async {
    final now = _nowIso();
    await db.customUpdate(
      'INSERT INTO context_files '
      '(dir_id, rel_path, size, mtime, sha256, kind, claude_chain, '
      ' description, paths_json, digest_json, digest_status, desc_embedding, '
      ' text_chars, status, seen_at, updated_at) '
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'pending', NULL, ?, ?, "
      ' ?, ?) '
      'ON CONFLICT(dir_id, rel_path) DO UPDATE SET '
      '  size = excluded.size, mtime = excluded.mtime, '
      '  sha256 = excluded.sha256, kind = excluded.kind, '
      '  claude_chain = excluded.claude_chain, '
      '  description = excluded.description, '
      '  paths_json = excluded.paths_json, '
      '  text_chars = excluded.text_chars, '
      '  status = excluded.status, seen_at = excluded.seen_at, '
      '  updated_at = excluded.updated_at',
      variables: _args([
        dirId,
        relPath,
        size,
        mtime,
        sha256,
        kind,
        jsonEncode(claudeChain),
        description,
        pathsJson,
        textChars,
        status,
        now,
        now,
      ]),
    );
    final row = await db
        .customSelect(
          'SELECT id FROM context_files WHERE dir_id = ? AND rel_path = ?',
          variables: _args([dirId, relPath]),
        )
        .getSingle();
    return row.data['id'] as int;
  }

  /// Marks rows as still there without re-reading them — the cheap half of a
  /// walk, and what keeps an unchanged file out of [deleteFiles]'s worklist.
  Future<void> touchFilesSeen(
    String dirId,
    List<int> ids,
    String seenAt,
  ) async {
    if (ids.isEmpty) return;
    await db.customUpdate(
      'UPDATE context_files SET seen_at = ? '
      'WHERE dir_id = ? AND id IN (${_placeholders(ids.length)})',
      variables: _args([seenAt, dirId, ...ids]),
    );
  }

  /// Moves a file to a new path, keeping its id and therefore its passages,
  /// its vectors and its digest.
  ///
  /// The whole payoff of hashing: a renamed folder is a path change and not a
  /// re-index, so a project reorganised on a Tuesday costs nothing.
  Future<void> renameFile(int id, String relPath) async {
    await db.customUpdate(
      'UPDATE context_files SET rel_path = ?, updated_at = ? WHERE id = ?',
      variables: _args([relPath, _nowIso(), id]),
    );
  }

  /// Removes files and everything under them, in one transaction.
  Future<void> deleteFiles(List<int> ids) async {
    if (ids.isEmpty) return;
    final holes = _placeholders(ids.length);
    await db.transaction(() async {
      await db.customUpdate(
        'DELETE FROM context_chunks WHERE file_id IN ($holes)',
        variables: _args(ids),
      );
      await db.customUpdate(
        'DELETE FROM context_text WHERE file_id IN ($holes)',
        variables: _args(ids),
      );
      await db.customUpdate(
        'DELETE FROM context_files WHERE id IN ($holes)',
        variables: _args(ids),
      );
    });
  }

  /// Replaces the `claude_chain` of one file — what a walk writes when a
  /// `CLAUDE.md` appears or disappears somewhere above it.
  Future<void> setFileChain(int id, List<String> claudeChain) async {
    await db.customUpdate(
      'UPDATE context_files SET claude_chain = ?, updated_at = ? WHERE id = ?',
      variables: _args([jsonEncode(claudeChain), _nowIso(), id]),
    );
  }

  Future<void> setFileDigest(
    int id, {
    required String status,
    String? digestJson,
  }) async {
    await db.customUpdate(
      'UPDATE context_files SET digest_status = ?, digest_json = ?, '
      '  updated_at = ? WHERE id = ?',
      variables: _args([status, digestJson, _nowIso(), id]),
    );
  }

  /// Files the vector of a skill's description, or clears it.
  Future<void> setFileDescEmbedding(int id, Uint8List? embedding) async {
    await db.customUpdate(
      'UPDATE context_files SET desc_embedding = ?, updated_at = ? '
      'WHERE id = ?',
      variables: _args([embedding, _nowIso(), id]),
    );
  }

  /// Puts a changed file back on the digest queue.
  ///
  /// Separate from [upsertFile] on purpose: the reconcile pass writes
  /// metadata for every file it sees, and only the ones whose BYTES moved
  /// have a digest that is now describing text nobody has any more.
  Future<void> resetFileDigest(int id) async {
    await db.customUpdate(
      "UPDATE context_files SET digest_status = 'pending', "
      '  digest_json = NULL, updated_at = ? WHERE id = ?',
      variables: _args([_nowIso(), id]),
    );
  }

  // ── extracted text ───────────────────────────────────────────────────

  /// Stores one file's words, replacing whatever was there.
  Future<void> setFileText(int fileId, String text) async {
    await db.customUpdate(
      'INSERT OR REPLACE INTO context_text (file_id, extracted_text, chars) '
      'VALUES (?, ?, ?)',
      variables: _args([fileId, text, text.length]),
    );
  }

  /// Drops one file's words — what a file that stopped being text gets,
  /// rather than a row holding the empty string.
  Future<void> clearFileText(int fileId) async {
    await db.customUpdate(
      'DELETE FROM context_text WHERE file_id = ?',
      variables: _args([fileId]),
    );
  }

  Future<String?> fileText(int fileId) async {
    final rows = await db
        .customSelect(
          'SELECT extracted_text FROM context_text WHERE file_id = ?',
          variables: _args([fileId]),
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['extracted_text'] as String?;
  }

  // ── passages ─────────────────────────────────────────────────────────

  /// Replaces one file's passages with [chunks], and hands back their new ids
  /// in the order they were given.
  ///
  /// Delete-then-insert rather than a diff, because the chunker is
  /// deterministic: the same text and the same code produce the same
  /// passages, so a retry after a park re-derives exactly what was there and
  /// this is idempotent by construction. The vec0 rowids of the deleted rows
  /// stay filed — see [removeDirectory] — and hydrate to nothing.
  ///
  /// Every row is written un-embedded. The embedder fills them in one POST at
  /// a time, and the index's backfill deliberately cannot see a row until it
  /// has floats.
  Future<List<int>> replaceChunks(
    int fileId,
    List<({int seq, String locator, String text})> chunks,
  ) async {
    final now = _nowIso();
    final ids = <int>[];
    await db.transaction(() async {
      await db.customUpdate(
        'DELETE FROM context_chunks WHERE file_id = ?',
        variables: _args([fileId]),
      );
      for (final chunk in chunks) {
        final row = await db
            .customSelect(
              'INSERT INTO context_chunks '
              '(file_id, seq, locator, chunk_text, chars, embedding, dims, '
              ' embed_model, embedded_at, indexed_at, created_at) '
              'VALUES (?, ?, ?, ?, ?, NULL, 0, NULL, NULL, NULL, ?) '
              'RETURNING id',
              variables: _args([
                fileId,
                chunk.seq,
                chunk.locator,
                chunk.text,
                chunk.text.length,
                now,
              ]),
            )
            .getSingle();
        ids.add(row.data['id'] as int);
      }
    });
    return ids;
  }

  /// Adds one more passage after everything already stored.
  ///
  /// What the digest handler writes its summary through: the digest is a
  /// passage of the file like any other — the one a question about findings
  /// should land on — and appending it must not disturb the numbering
  /// [replaceChunks] laid down. The next `seq` is computed IN SQL inside the
  /// transaction, so two writers cannot both read the same maximum.
  Future<int> appendChunk(
    int fileId, {
    required String locator,
    required String text,
  }) async {
    final now = _nowIso();
    var id = 0;
    await db.transaction(() async {
      final row = await db
          .customSelect(
            'INSERT INTO context_chunks '
            '(file_id, seq, locator, chunk_text, chars, embedding, dims, '
            ' embed_model, embedded_at, indexed_at, created_at) '
            'SELECT ?, COALESCE(MAX(seq), -1) + 1, ?, ?, ?, NULL, 0, NULL, '
            '  NULL, NULL, ? '
            'FROM context_chunks WHERE file_id = ? '
            'RETURNING id',
            variables: _args([
              fileId,
              locator,
              text,
              text.length,
              now,
              fileId,
            ]),
          )
          .getSingle();
      id = row.data['id'] as int;
    });
    return id;
  }

  /// The passages of one file that have no vector yet, in file order.
  Future<List<({int id, String text})>> unembeddedChunks(int fileId) async {
    final rows = await db
        .customSelect(
          'SELECT id, chunk_text FROM context_chunks '
          'WHERE file_id = ? AND embedding IS NULL ORDER BY seq',
          variables: _args([fileId]),
        )
        .get();
    return [
      for (final row in rows)
        (
          id: row.data['id'] as int,
          text: row.data['chunk_text'] as String? ?? '',
        ),
    ];
  }

  /// Every un-embedded passage in one directory, oldest file first.
  ///
  /// The resume worklist, and the reason a reconcile pass that finds NOTHING
  /// changed still has work to do: the previous pass may have parked on a
  /// dead embedding server part-way through, leaving text and passages stored
  /// and a tail of them without floats. Nothing else would ever notice.
  Future<List<({int id, String text})>> unembeddedChunksForDir(
    String dirId,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT c.id AS id, c.chunk_text AS chunk_text '
          'FROM context_chunks c '
          'JOIN context_files f ON f.id = c.file_id '
          'WHERE f.dir_id = ? AND c.embedding IS NULL '
          'ORDER BY c.file_id, c.seq',
          variables: _args([dirId]),
        )
        .get();
    return [
      for (final row in rows)
        (
          id: row.data['id'] as int,
          text: row.data['chunk_text'] as String? ?? '',
        ),
    ];
  }

  /// Files one passage's vector, and puts the row back on the index's
  /// worklist.
  ///
  /// `indexed_at` is cleared rather than stamped: this method's whole job is
  /// to make a row the backfill can finally see, and stamping it here would
  /// write the float into the table and never into the index.
  Future<void> setChunkEmbedding(
    int id, {
    required Uint8List embedding,
    required int dims,
    required String embedModel,
  }) async {
    await db.customUpdate(
      'UPDATE context_chunks SET embedding = ?, dims = ?, embed_model = ?, '
      '  embedded_at = ?, indexed_at = NULL WHERE id = ?',
      variables: _args([embedding, dims, embedModel, _nowIso(), id]),
    );
  }

  /// Files every embedded passage the vector index has not seen. Returns how
  /// many were attempted.
  Future<int> indexPendingChunks() => _chunkIndex.backfill();

  /// Files every passage the word index has not seen. Returns how many were
  /// written.
  Future<int> ensureKeywordIndex() => _keywordIndex.backfill();

  /// Whether the word index could be built on this connection at all.
  Future<bool> keywordIndexReady() => _keywordIndex.ensureReady();

  /// Drops one file's rows from the word index so the next backfill re-files
  /// them.
  ///
  /// A RENAME is what this exists for. Renaming a file keeps its passages —
  /// that is the whole payoff of hashing, and it is what makes a reorganised
  /// project cost no embeddings — but the indexed `path` column still says
  /// where the file used to be, and [ContextKeywordIndex.backfill]'s fence
  /// (count, highest id, summed characters) does not move when a row is
  /// renamed, so its comparison never runs and the stale path stays
  /// searchable. Deleting the rows moves the count, which is exactly the
  /// signal the fence is watching for.
  ///
  /// Failures are swallowed for the index's own reason: a search that misses
  /// a passage is a worse answer, and a reconcile that dies over a derived
  /// table is a directory nobody can read.
  Future<void> invalidateKeywordRows(int fileId) async {
    if (!await _keywordIndex.ensureReady()) return;
    try {
      await db.customUpdate(
        'DELETE FROM ${ContextKeywordIndex.table} WHERE rowid IN '
        '  (SELECT id FROM context_chunks WHERE file_id = ?)',
        variables: _args([fileId]),
      );
    } catch (e) {
      debugPrint('context: keyword invalidation failed for $fileId: $e');
    }
  }

  /// Throws both derived indexes away and builds them again.
  ///
  /// The self-heal, and the only cleanup for the rowids [replaceChunks],
  /// [deleteFiles] and [removeDirectory] orphan.
  Future<void> rebuildIndexes() async {
    await _chunkIndex.rebuild();
    await _keywordIndex.rebuild();
    await _keywordIndex.backfill();
  }

  /// How many passages one directory has, and how many of them are embedded
  /// — the two numbers the library row draws its progress from.
  Future<({int chunks, int embedded})> chunkCounts(String dirId) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n, '
          '  SUM(CASE WHEN c.embedding IS NULL THEN 0 ELSE 1 END) AS e '
          'FROM context_chunks c JOIN context_files f ON f.id = c.file_id '
          'WHERE f.dir_id = ?',
          variables: _args([dirId]),
        )
        .getSingle();
    return (
      chunks: (row.data['n'] as num?)?.toInt() ?? 0,
      embedded: (row.data['e'] as num?)?.toInt() ?? 0,
    );
  }

  /// Whether anything in this scope has passages at all.
  ///
  /// The cheap read before the expensive one. The retriever runs on every
  /// draft and the overwhelming majority of threads have no directory linked
  /// — so one indexed `LIMIT 1` here saves that thread a vector read, an
  /// index backfill, a KNN and, on a message the embed queue has not reached
  /// yet, a POST to the embedding server.
  ///
  /// An empty scope is false WITHOUT a query, on [chunkKnn]'s rule.
  Future<bool> hasChunksInScope(List<String> dirIds) async {
    if (dirIds.isEmpty) return false;
    final rows = await db
        .customSelect(
          'SELECT 1 FROM context_chunks c '
          'JOIN context_files f ON f.id = c.file_id '
          'WHERE f.dir_id IN (${_placeholders(dirIds.length)}) LIMIT 1',
          variables: _args(dirIds),
        )
        .get();
    return rows.isNotEmpty;
  }

  /// The passages nearest [query] within a named set of directories, closest
  /// first. Null when the vector index could not be built.
  ///
  /// **An empty scope answers `const []` and never the library.** A caller
  /// that could not work out which room it is on must get nothing rather than
  /// the nearest passage in every project the user owns — a paragraph of one
  /// client's notes pasted into another's reply is the one failure this path
  /// has to be incapable of.
  Future<List<ContextChunkHit>?> chunkKnn(
    Uint8List query, {
    required String embedModel,
    required List<String> dirIds,
    int k = 12,
  }) async {
    if (dirIds.isEmpty) return const [];
    if (!await _chunkIndex.ensureReady()) return null;

    // Heal before asking: a passage whose index write never landed would
    // otherwise stay unfindable until some unrelated file happened to change.
    await _chunkIndex.backfill();

    final scope = 'file_id IN (SELECT id FROM context_files '
        'WHERE dir_id IN (${_placeholders(dirIds.length)}))';
    final hits = await _chunkIndex.knn(
      query,
      k: k,
      rowidWhere: scope,
      rowidArgs: dirIds,
    );
    if (hits.isEmpty) return const [];

    return _hydrate(
      [
        for (final hit in hits)
          (id: hit.id, distance: hit.distance, bm25: null, coverage: null),
      ],
      embedModel: embedModel,
      dirIds: dirIds,
      limit: hits.length,
    );
  }

  /// The passages within [dirIds] whose WORDS [query] matches, best first.
  ///
  /// The other half of the retrieval, and the half that finds a part number,
  /// a config key or a function name — the tokens an embedding flattens.
  /// Coverage is asked once per term over the page already in hand, which is
  /// what lets the fusion above say "this passage matched two of your three
  /// words".
  Future<List<ContextChunkHit>> keywordChunks(
    FtsQuery query, {
    required List<String> dirIds,
    int limit = SearchTuning.keywordFetch,
  }) async {
    if (dirIds.isEmpty) return const [];
    if (!await _keywordIndex.ensureReady()) return const [];

    await _keywordIndex.backfill();

    // Scoped INSIDE the ranked query, exactly as the vector half is. The
    // limit is a page of the BEST rows, so a library where another project
    // holds two hundred better matches for the same word would hand back a
    // page this room may not read a single row of — and answer nothing.
    final scope = 'rowid IN (SELECT c.id FROM context_chunks c '
        'JOIN context_files f ON f.id = c.file_id '
        'WHERE f.dir_id IN (${_placeholders(dirIds.length)}))';
    final matches = await _keywordIndex.match(
      query.match,
      limit: limit,
      rowidWhere: scope,
      rowidArgs: dirIds,
    );
    if (matches.isEmpty) return const [];
    final ids = [for (final match in matches) match.rowid];

    final matched = <int, int>{};
    for (final term in query.terms) {
      for (final id in await _keywordIndex.rowidsMatching(
        quoteTerm(term),
        among: ids,
      )) {
        matched[id] = (matched[id] ?? 0) + 1;
      }
    }

    return _hydrate(
      [
        for (final match in matches)
          (
            id: match.rowid,
            distance: null,
            bm25: match.bm25,
            // Coverage over the terms that were ASKED, so a one-word query
            // that matched is full coverage rather than a third of one.
            coverage: query.terms.isEmpty
                ? 0.0
                : (matched[match.rowid] ?? 0) / query.terms.length,
          ),
      ],
      // No model tag: a passage the words found need never have been embedded
      // at all, and filtering on the tag of an embedding it does not have
      // would hide exactly the files this pass exists to reach.
      embedModel: null,
      dirIds: dirIds,
      limit: matches.length,
    );
  }

  /// Turns ranked chunk ids into passages with their file and directory
  /// attached, back in the order they were ranked.
  ///
  /// The scope is re-applied here, belt and braces: it costs one indexed
  /// lookup and it means an orphaned vec0 or FTS5 rowid — [replaceChunks] and
  /// [removeDirectory] both leave those behind — can never hydrate into a
  /// passage from a directory this room may not read.
  ///
  /// Ids that hydrate to nothing are skipped rather than counted, which is
  /// exactly what an orphan looks like.
  Future<List<ContextChunkHit>> _hydrate(
    List<({int id, double? distance, double? bm25, double? coverage})> ranked, {
    required String? embedModel,
    required List<String> dirIds,
    required int limit,
  }) async {
    if (ranked.isEmpty) return const [];
    final ids = [for (final hit in ranked) hit.id];
    final modelWhere = embedModel == null ? '' : 'AND c.embed_model = ? ';
    final rows = await db
        .customSelect(
          'SELECT c.id AS chunk_id, c.seq AS chunk_seq, '
          '       c.locator AS chunk_locator, c.chunk_text AS chunk_text, '
          '       f.id AS file_id, f.rel_path AS rel_path, '
          '       d.id AS dir_id, d.display_name AS dir_name '
          'FROM context_chunks c '
          'JOIN context_files f ON f.id = c.file_id '
          'JOIN context_dirs d ON d.id = f.dir_id '
          'WHERE c.id IN (${_placeholders(ids.length)}) '
          '  AND f.dir_id IN (${_placeholders(dirIds.length)}) '
          '  $modelWhere',
          variables: _args([
            ...ids,
            ...dirIds,
            ?embedModel,
          ]),
        )
        .get();

    final byId = {
      for (final row in rows) row.data['chunk_id'] as int: row.data,
    };
    final hits = <ContextChunkHit>[];
    for (final hit in ranked) {
      final row = byId[hit.id];
      if (row == null) continue;
      hits.add(
        ContextChunkHit(
          fileId: (row['file_id'] as num?)?.toInt() ?? 0,
          dirId: row['dir_id'] as String? ?? '',
          dirName: row['dir_name'] as String? ?? '',
          relPath: row['rel_path'] as String? ?? '',
          chunkId: hit.id,
          seq: (row['chunk_seq'] as num?)?.toInt() ?? 0,
          locator: row['chunk_locator'] as String? ?? '',
          text: row['chunk_text'] as String? ?? '',
          distance: hit.distance,
          bm25: hit.bm25,
          coverage: hit.coverage,
        ),
      );
      if (hits.length == limit) break;
    }
    return hits;
  }
}
