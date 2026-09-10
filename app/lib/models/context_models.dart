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

/// What the fast model made of ONE file in a registered directory.
///
/// Written by the digest handler, read by the brief's file map, by the
/// Settings row's progress clause and — as a passage of the file like any
/// other — by retrieval. Every field is model output about the owner's own
/// work, which is why nothing here is presented as though the file said it:
/// the passage it becomes is labelled `digest`.
///
/// The keys are the schema's keys, snake_case and all of them, so
/// [toJson] round-trips through the `digest_json` column without a mapping
/// layer in between.
@immutable
class ContextFileDigest {
  /// ONE sentence: what this file is FOR, from the owner's point of view.
  final String purpose;

  /// The specific conclusions, numbers, dates and names the file states,
  /// copied exactly. Empty for code that concludes nothing, which is most
  /// code.
  final List<String> findings;

  /// Short questions a person could answer by opening this file — the half
  /// of the digest a question about findings actually matches on.
  final List<String> questionsAnswered;

  /// The files, sources and datasets this file reads or depends on, as
  /// written.
  final List<String> inputs;

  /// `analysis|code|notes|data|config|other` — what the file IS, not what
  /// its extension says.
  final String kindHint;

  const ContextFileDigest({
    this.purpose = '',
    this.findings = const [],
    this.questionsAnswered = const [],
    this.inputs = const [],
    this.kindHint = 'other',
  });

  /// Never throws and never rejects, on `AttachmentDigest.fromJson`'s
  /// reasoning: a digest is a convenience over a file the app already stored,
  /// and a malformed one must cost a line of a brief rather than the render
  /// around it.
  factory ContextFileDigest.fromJson(Map<String, Object?> json) =>
      ContextFileDigest(
        purpose: _string(json['purpose']),
        findings: _strings(json['findings']),
        questionsAnswered: _strings(json['questions_answered']),
        inputs: _strings(json['inputs']),
        kindHint: _string(json['kind_hint'], fallback: 'other'),
      );

  /// ALL FIVE keys, always, including the empty ones — the same promise
  /// `AttachmentDigest.toJson` makes, and for the same reason: a reader that
  /// has to ask whether a key is there is a reader that will one day forget.
  Map<String, Object?> toJson() => {
        'purpose': purpose,
        'findings': findings,
        'questions_answered': questionsAnswered,
        'inputs': inputs,
        'kind_hint': kindHint,
      };

  /// A `digest_json` column as a [ContextFileDigest], or null.
  ///
  /// Null for absent, empty, unparseable and anything that does not decode to
  /// a map. Every one of those means the same thing to every caller — "no
  /// digest yet" — and a throw here would take out the brief's whole file
  /// map over one bad row.
  static ContextFileDigest? decode(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      return ContextFileDigest.fromJson(Map<String, Object?>.from(decoded));
    } on FormatException {
      return null;
    }
  }

  /// A cast would throw on the number a hand-edited row can hold, and this
  /// class promises it never does.
  static String _string(Object? raw, {String fallback = ''}) =>
      raw is String ? raw : fallback;

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is String) entry,
    ];
  }
}

/// The compiled standing knowledge of ONE registered directory.
///
/// One per directory, built from the root `CLAUDE.md` (imports resolved) and
/// the map of every file digest. It is what a reply reads FIRST — before any
/// retrieved passage — so it answers the questions a passage cannot: what
/// this project is, how the owner writes about it, and which file to reach
/// for.
@immutable
class ContextBrief {
  /// Two or three sentences: what this project IS and what the owner is doing
  /// in it.
  final String about;

  /// Imperative lines a reply should follow, drawn from the standing notes —
  /// tone, conventions, what to cite, what never to promise.
  final List<String> replyGuidance;

  /// Facts stated in the notes or the file map, copied exactly.
  final List<String> keyFacts;

  /// Which file answers which kind of question. Only paths that appear in
  /// the map or the notes.
  final List<({String topic, String path})> pointers;

  /// Project terms, names and acronyms as the owner writes them.
  final List<String> vocabulary;

  const ContextBrief({
    this.about = '',
    this.replyGuidance = const [],
    this.keyFacts = const [],
    this.pointers = const [],
    this.vocabulary = const [],
  });

  factory ContextBrief.fromJson(Map<String, Object?> json) => ContextBrief(
        about: json['about'] is String ? json['about']! as String : '',
        replyGuidance: _strings(json['reply_guidance']),
        keyFacts: _strings(json['key_facts']),
        pointers: _pointers(json['pointers']),
        vocabulary: _strings(json['vocabulary']),
      );

  Map<String, Object?> toJson() => {
        'about': about,
        'reply_guidance': replyGuidance,
        'key_facts': keyFacts,
        'pointers': [
          for (final pointer in pointers)
            {'topic': pointer.topic, 'path': pointer.path},
        ],
        'vocabulary': vocabulary,
      };

  /// A `brief_json` column as a [ContextBrief], or null. [ContextFileDigest.
  /// decode]'s tolerance, for its reasons.
  static ContextBrief? decode(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      return ContextBrief.fromJson(Map<String, Object?>.from(decoded));
    } on FormatException {
      return null;
    }
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is String) entry,
    ];
  }

  /// The most pointers a decoded brief will carry.
  ///
  /// The same ten `ContextBriefTask.validate` applies on the way in, restated
  /// here rather than imported: a model is not the place to reach into a
  /// prompt task, and the reason the number has to hold in BOTH places is
  /// that a column is not only ever written by this build's validator — a
  /// row from an earlier one, or a hand-edited one, arrives through `decode`
  /// having met no ceiling at all.
  static const int maxPointers = 10;

  /// A pointer needs BOTH halves to be worth anything — a topic with no path
  /// cites nothing and a path with no topic answers nothing — so a pair
  /// missing either is dropped rather than rendered half-blank. Trimmed and
  /// capped for the same reason the validator trims and caps: what comes
  /// back out of the column is rendered into a prompt.
  static List<({String topic, String path})> _pointers(Object? raw) {
    if (raw is! List) return const [];
    final pointers = <({String topic, String path})>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final topic = entry['topic'];
      final path = entry['path'];
      if (topic is! String || path is! String) continue;
      if (topic.trim().isEmpty || path.trim().isEmpty) continue;
      pointers.add((topic: topic.trim(), path: path.trim()));
      if (pointers.length == maxPointers) break;
    }
    return pointers;
  }
}
