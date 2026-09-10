import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

/// What a directory can be linked TO.
///
/// An open set stored as text, and the `name` of the enum IS the stored
/// value — `'thread'`, `'storyline'`. `sender` and `all` are future values
/// rather than future migrations, which is why the column is TEXT and
/// [ContextScopeKind.fromName] falls back rather than throwing: a row written
/// by a later build must not crash an earlier one.
enum ContextScopeKind {
  /// One conversation, identified by `(source, conversation_key)`.
  thread,

  /// One storyline, identified by its global id. Its threads inherit the
  /// link, exactly as they inherit a pinned document.
  storyline;

  /// The kind stored under [name], or [ContextScopeKind.thread] for a value
  /// this build does not know.
  static ContextScopeKind fromName(String? value) => switch (value) {
        'storyline' => ContextScopeKind.storyline,
        _ => ContextScopeKind.thread,
      };
}

/// One registered directory, as the last walk left it.
///
/// **No value equality**, on [AttachmentRef]'s reasoning: thirty fields of
/// `==` would say two rows differ because a walk stamped `updated_at` between
/// two frames, which is exactly when a selected row must not be dropped.
/// Identity is [id], and every comparison anything makes goes through it.
@immutable
class ContextDir {
  /// The first 16 hex characters of `sha256(path)` — derived rather than
  /// surrogate, so registering the same folder twice is the same row without
  /// a lookup.
  final String id;

  /// Where it lives on disk. Still the truth on an unsandboxed build, and the
  /// fallback whenever [bookmark] cannot be resolved.
  final String path;

  /// What the user sees. The folder's own name by default, and theirs to
  /// change.
  final String displayName;

  /// The security-scoped bookmark that keeps the folder readable after a
  /// relaunch, or null on a build that keeps none.
  final Uint8List? bookmark;

  /// `pending|reading|ready|error|unavailable`.
  final String status;

  /// A sentence for the row when [status] is `error` or `unavailable`.
  final String? error;

  /// When the last walk finished, ISO-8601 UTC. Null before the first one —
  /// which is also what makes a directory look infinitely stale to the
  /// freshness ladder, and that is correct.
  final String? walkedAt;

  /// A hash over every file's `relPath|sha256`, sorted. What says "nothing in
  /// this folder moved" in one comparison.
  final String? rootHash;

  final int filesCount;

  /// The summed on-disk size of the files whose words were read.
  final int textBytes;

  /// The compiled brief, JSON, written by the brief handler. Null until one
  /// lands, and null forever for a directory with neither a `CLAUDE.md` nor a
  /// digest.
  final String? briefJson;

  /// The hash of the brief's INPUTS, so an unchanged directory pays no call.
  final String? briefHash;

  /// Whether each changed file gets a one-call digest.
  final bool digests;

  /// Whether `.gitignore` is honoured. Off by default: Claude Code analyses
  /// land in ignored `output/` and `reports/` folders.
  final bool honorGitignore;

  final String createdAt;
  final String updatedAt;

  const ContextDir({
    required this.id,
    required this.path,
    required this.displayName,
    this.bookmark,
    required this.status,
    this.error,
    this.walkedAt,
    this.rootHash,
    required this.filesCount,
    required this.textBytes,
    this.briefJson,
    this.briefHash,
    required this.digests,
    required this.honorGitignore,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ContextDir.fromRow(Map<String, Object?> row) => ContextDir(
        id: row['id'] as String? ?? '',
        path: row['path'] as String? ?? '',
        displayName: row['display_name'] as String? ?? '',
        bookmark: row['bookmark'] as Uint8List?,
        status: row['status'] as String? ?? 'pending',
        error: row['error'] as String?,
        walkedAt: row['walked_at'] as String?,
        rootHash: row['root_hash'] as String?,
        filesCount: (row['files_count'] as num?)?.toInt() ?? 0,
        textBytes: (row['text_bytes'] as num?)?.toInt() ?? 0,
        briefJson: row['brief_json'] as String?,
        briefHash: row['brief_hash'] as String?,
        digests: ((row['digests'] as num?)?.toInt() ?? 1) != 0,
        honorGitignore: ((row['honor_gitignore'] as num?)?.toInt() ?? 0) != 0,
        createdAt: row['created_at'] as String? ?? '',
        updatedAt: row['updated_at'] as String? ?? '',
      );
}

/// One file inside a registered directory.
@immutable
class ContextFile {
  final int id;
  final String dirId;

  /// Relative to the directory root, always with `/` separators.
  final String relPath;

  final int size;

  /// The file's modification time, ISO-8601 UTC. Half of the cheap diff.
  final String mtime;

  final String sha256;

  /// `claude_md|skill|rule|doc|code|data|other`.
  final String kind;

  /// The `CLAUDE.md` rel paths above this file, root first — Claude Code's
  /// own on-demand rule, stored per row so a retrieved passage can carry the
  /// notes that govern its subtree.
  final List<String> claudeChain;

  /// A skill's or rule's `description` frontmatter, when it has one.
  final String? description;

  /// A rule's `paths` frontmatter, JSON.
  final String? pathsJson;

  /// The model's digest of this file, JSON.
  final String? digestJson;

  /// `pending|done|skipped|error`.
  final String digestStatus;

  /// Whether [description] has been embedded — the blob itself stays in the
  /// database rather than riding on every row a list reads.
  final bool hasDescEmbedding;

  final int textChars;

  /// `ok` today; the column exists so a file that could not be read has
  /// somewhere to say so without leaving the walk.
  final String status;

  final String seenAt;
  final String updatedAt;

  const ContextFile({
    required this.id,
    required this.dirId,
    required this.relPath,
    required this.size,
    required this.mtime,
    required this.sha256,
    required this.kind,
    required this.claudeChain,
    this.description,
    this.pathsJson,
    this.digestJson,
    required this.digestStatus,
    required this.hasDescEmbedding,
    required this.textChars,
    required this.status,
    required this.seenAt,
    required this.updatedAt,
  });

  factory ContextFile.fromRow(Map<String, Object?> row) => ContextFile(
        id: (row['id'] as num?)?.toInt() ?? 0,
        dirId: row['dir_id'] as String? ?? '',
        relPath: row['rel_path'] as String? ?? '',
        size: (row['size'] as num?)?.toInt() ?? 0,
        mtime: row['mtime'] as String? ?? '',
        sha256: row['sha256'] as String? ?? '',
        kind: row['kind'] as String? ?? 'other',
        claudeChain: decodeClaudeChain(row['claude_chain'] as String?),
        description: row['description'] as String?,
        pathsJson: row['paths_json'] as String?,
        digestJson: row['digest_json'] as String?,
        digestStatus: row['digest_status'] as String? ?? 'pending',
        hasDescEmbedding: row['desc_embedding'] != null,
        textChars: (row['text_chars'] as num?)?.toInt() ?? 0,
        status: row['status'] as String? ?? 'ok',
        seenAt: row['seen_at'] as String? ?? '',
        updatedAt: row['updated_at'] as String? ?? '',
      );

  /// The stored chain, or an empty list for anything that is not a JSON list
  /// of strings.
  ///
  /// Tolerant rather than strict because the column is written by this app
  /// and read on every retrieval: a row corrupted by hand is a file with no
  /// standing notes, not a crash on the draft path.
  static List<String> decodeClaudeChain(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is String) entry,
      ];
    } on FormatException {
      return const [];
    }
  }
}

/// One directory linked to one room.
@immutable
class ContextLink {
  final String dirId;
  final ContextScopeKind scopeKind;

  /// The connector for a thread; `''` for a storyline, whose ids are already
  /// global.
  final String source;

  /// `conversation_key` for a thread, the storyline id for a storyline.
  final String scopeKey;

  final String addedAt;

  const ContextLink({
    required this.dirId,
    required this.scopeKind,
    required this.source,
    required this.scopeKey,
    required this.addedAt,
  });

  factory ContextLink.fromRow(Map<String, Object?> row) => ContextLink(
        dirId: row['dir_id'] as String? ?? '',
        scopeKind: ContextScopeKind.fromName(row['scope_kind'] as String?),
        source: row['source'] as String? ?? '',
        scopeKey: row['scope_key'] as String? ?? '',
        addedAt: row['added_at'] as String? ?? '',
      );
}

/// One passage of one file, with the file and directory it came from and
/// whatever the pass that found it measured.
///
/// The three signals are nullable for the reason the attachment hit's are:
/// the vector pass has a [distance] and no words, the word pass has [bm25]
/// and [coverage] and no distance, and only the fusion above has all three. A
/// placeholder in the missing slot would be a number that still sorts.
@immutable
class ContextChunkHit {
  final int fileId;
  final String dirId;

  /// The directory's display name — what a citation says out loud.
  final String dirName;

  final String relPath;
  final int chunkId;
  final int seq;

  /// `Pricing > Q4 rates`, `lines 61–120`, `part 2`, `digest`, or empty.
  final String locator;

  final String text;

  /// Cosine distance from the vector pass; smaller is nearer.
  final double? distance;

  /// FTS5's score, already NEGATED by the index: bigger is better.
  final double? bm25;

  /// The share of the query's terms this passage matched, 0..1.
  final double? coverage;

  const ContextChunkHit({
    required this.fileId,
    required this.dirId,
    required this.dirName,
    required this.relPath,
    required this.chunkId,
    required this.seq,
    required this.locator,
    required this.text,
    this.distance,
    this.bm25,
    this.coverage,
  });

  /// The same passage carrying different numbers — what the fusion builds
  /// when it merges a vector hit and a word hit for one chunk.
  ///
  /// Named arguments with no `?? this.x` fallback on purpose: a merge that
  /// omits a signal is stating the merged row does not have it, and silently
  /// carrying the old value forward would let a distance measured in one pass
  /// score a row the other pass found.
  ContextChunkHit withSignals({
    double? distance,
    double? bm25,
    double? coverage,
  }) =>
      ContextChunkHit(
        fileId: fileId,
        dirId: dirId,
        dirName: dirName,
        relPath: relPath,
        chunkId: chunkId,
        seq: seq,
        locator: locator,
        text: text,
        distance: distance,
        bm25: bm25,
        coverage: coverage,
      );
}
