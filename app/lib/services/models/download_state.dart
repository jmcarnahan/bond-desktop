import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

import 'model_manifest.dart';

/// Where one file is in its life.
///
/// [paused] and [failed] are both "not moving", and they are kept apart
/// because only one of them is the user's doing: a paused file resumes on a
/// button, a failed one needs a sentence explaining what went wrong first.
enum DownloadStatus { pending, downloading, paused, verifying, done, failed }

/// Why a file failed — a closed vocabulary Phase 4 turns into sentences.
///
/// Words rather than an enum for `attachment_format.dart`'s reason: these are
/// written into the ledger as JSON and read back by a later build, and an
/// enum index would change meaning the day a case is inserted. An unknown
/// word must stay readable rather than crash a screen.
abstract final class DownloadError {
  static const String diskFull = 'disk_full';
  static const String checksum = 'checksum';
  static const String network = 'network';
  static const String gated = 'gated';
  static const String manifestMismatch = 'manifest_mismatch';
  static const String missingFolder = 'missing_folder';

  /// A registry entry with no registry address to fetch it from. Said before
  /// any request, because there is nowhere to send one.
  static const String registryNotConfigured = 'registry_not_configured';

  /// The registry answered 401 or 403 to its own address: no token, or one
  /// it refused. Never retried, because asking again changes nothing.
  static const String unauthorized = 'unauthorized';

  /// The registry answered 404 to its own address: no such bundle or file
  /// there, which is an address pointing at the wrong repository. Never
  /// retried, because the file will not appear by asking again.
  static const String registryNotFound = 'registry_not_found';

  /// The registry's FIRST answer was a 200 or 206 carrying a web page
  /// (`text/html`): a login page or a proxy's, never a model. Never retried,
  /// because a retry budget spent on a login page is minutes of nothing.
  static const String registryNotAModel = 'registry_not_a_model';

  /// The failures whose fix is the registry's address or token: the
  /// sentence names it, and a Save of the registry form retries the download.
  static const Set<String> registryFixes = {
    registryNotConfigured,
    unauthorized,
    registryNotFound,
    registryNotAModel,
  };

  /// Everything the hub or the CDN answered that has no word of its own.
  static String http(int code) => 'http_$code';
}

DownloadStatus _statusFrom(Object? value) {
  for (final status in DownloadStatus.values) {
    if (status.name == value) return status;
  }
  // Tolerant on purpose: the ledger is read by a build that may be older or
  // newer than the one that wrote it, and a word this build does not know
  // must degrade to "not started" rather than throw on launch.
  return DownloadStatus.pending;
}

int _intOr(Object? value, int fallback) =>
    value is num ? value.toInt() : fallback;

/// One file's row in the ledger.
///
/// [sha256] is carried so a manifest bump invalidates what is on disk: a
/// `.part` written for the previous checkpoint holds the wrong bytes, and
/// resuming into it would spend gigabytes to fail a checksum at the end.
@immutable
class FileDownloadState {
  final String id;
  final DownloadStatus status;
  final int receivedBytes;
  final int totalBytes;

  /// The manifest sha this part or file belongs to.
  final String sha256;

  final String? error;

  /// `MessageStore.isoStamp`, for a screen saying when this last moved.
  final String? updatedAt;

  const FileDownloadState({
    required this.id,
    required this.status,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    required this.sha256,
    this.error,
    this.updatedAt,
  });

  FileDownloadState copyWith({
    DownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    String? sha256,
    String? error,
    bool clearError = false,
    String? updatedAt,
  }) =>
      FileDownloadState(
        id: id,
        status: status ?? this.status,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        sha256: sha256 ?? this.sha256,
        error: clearError ? null : (error ?? this.error),
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'status': status.name,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'sha256': sha256,
        'error': error,
        'updatedAt': updatedAt,
      };

  /// [fallbackId] is the ledger's map key, which is the id as well — an entry
  /// that did not repeat it inside itself is still addressable.
  factory FileDownloadState.fromJson(
    Map<String, Object?> json, {
    String fallbackId = '',
  }) {
    final id = '${json['id'] ?? ''}';
    return FileDownloadState(
        id: id.isEmpty ? fallbackId : id,
        status: _statusFrom(json['status']),
        receivedBytes: _intOr(json['receivedBytes'], 0),
        totalBytes: _intOr(json['totalBytes'], 0),
        sha256: json['sha256'] is String ? json['sha256'] as String : '',
        error: json['error'] is String ? json['error'] as String : null,
        updatedAt:
            json['updatedAt'] is String ? json['updatedAt'] as String : null);
  }

  @override
  bool operator ==(Object other) =>
      other is FileDownloadState &&
      other.id == id &&
      other.status == status &&
      other.receivedBytes == receivedBytes &&
      other.totalBytes == totalBytes &&
      other.sha256 == sha256 &&
      other.error == error &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        status,
        receivedBytes,
        totalBytes,
        sha256,
        error,
        updatedAt,
      );

  @override
  String toString() => 'FileDownloadState($id, ${status.name}, '
      '$receivedBytes/$totalBytes${error == null ? '' : ', $error'})';
}

/// What the run streams — one file's position, right now.
///
/// A separate type from [FileDownloadState] because it carries the two things
/// that are true only WHILE a download is happening and must never be
/// persisted: a rate measured over the last few seconds, and an estimate
/// derived from it.
@immutable
class DownloadProgress {
  final String id;
  final DownloadStatus status;
  final int receivedBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final Duration? remaining;
  final String? error;

  const DownloadProgress({
    required this.id,
    required this.status,
    required this.receivedBytes,
    required this.totalBytes,
    this.bytesPerSecond = 0,
    this.remaining,
    this.error,
  });

  /// 0..1. A done file is 1 whatever the byte counts say — a manifest whose
  /// size was a byte out must not leave a finished bar at 99%.
  double get fraction {
    if (status == DownloadStatus.done) return 1;
    if (totalBytes <= 0) return 0;
    final value = receivedBytes / totalBytes;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  bool get isTerminal =>
      status == DownloadStatus.done || status == DownloadStatus.failed;

  @override
  bool operator ==(Object other) =>
      other is DownloadProgress &&
      other.id == id &&
      other.status == status &&
      other.receivedBytes == receivedBytes &&
      other.totalBytes == totalBytes &&
      other.bytesPerSecond == bytesPerSecond &&
      other.remaining == remaining &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
        id,
        status,
        receivedBytes,
        totalBytes,
        bytesPerSecond,
        remaining,
        error,
      );

  @override
  String toString() => 'DownloadProgress($id, ${status.name}, '
      '$receivedBytes/$totalBytes${error == null ? '' : ', $error'})';
}

/// What is on disk, as the last writer understood it.
///
/// It NEVER holds a URL. The CDN address a file came from is signed and
/// expires within the hour, so a stored one would be a resume that fails
/// mysteriously an hour later; the app re-resolves instead, every time. The
/// resume OFFSET is not stored either — the `.part` file's own length is the
/// truth, because this ledger is written at most once every couple of seconds
/// and a crash can lose the last write. [FileDownloadState.receivedBytes] is
/// here so a relaunch can draw the list before it has looked at the disk.
@immutable
class DownloadLedger {
  final Map<String, FileDownloadState> files;

  const DownloadLedger(this.files);

  static const DownloadLedger empty = DownloadLedger({});

  FileDownloadState? operator [](String id) => files[id];

  /// The row a checkpoint's sidecar is kept under.
  ///
  /// A row of its own rather than a flag on the parent's, because the two
  /// files are fetched, resumed and verified separately and a single row
  /// could not say that one of them landed. Derived from the parent's id in
  /// ONE place, so the downloader, the preflight and the ledger check cannot
  /// spell it three ways.
  static String draftId(String id) => '$id.draft';

  /// The row a registry entry's heads file is kept under, on [draftId]'s
  /// reasoning: fetched, resumed and verified apart from the weights.
  static String headsId(String id) => '$id.heads';

  DownloadLedger record(FileDownloadState state) => DownloadLedger(
        Map.unmodifiable({...files, state.id: state}),
      );

  DownloadLedger without(String id) => DownloadLedger(
        Map.unmodifiable({...files}..remove(id)),
      );

  bool isDone(String id) => files[id]?.status == DownloadStatus.done;

  /// Done, AND against the digest the manifest names today.
  ///
  /// [isDone] answers the question a RUN asks — is there anything left to
  /// fetch for this id — and it cannot answer the one a LAUNCH asks. A
  /// manifest bump that keeps the file name leaves a done row describing the
  /// previous checkpoint, and an install that trusted it would go on serving
  /// the old weights for ever: nothing else compares digests, because hashing
  /// eighteen gigabytes to open a window is not a thing this app may do.
  /// A checkpoint with a SIDECAR is current only when both rows are: the
  /// preset names the draft as well as the weights and the server is started
  /// `--offline`, so half a set is a server that does not start. A REGISTRY
  /// entry with a heads file wants its `.heads` row too: the decision
  /// model's answers come from the heads, not the GGUF alone. `isRegistry`
  /// is the one rule for "owns a heads leg", the downloader's and the
  /// preflight's as well.
  bool isCurrent(ModelFile file) {
    if (!_rowIsCurrent(files[file.id], file.sha256)) return false;
    final head = file.sidecar;
    if (head != null &&
        !_rowIsCurrent(files[draftId(file.id)], head.sha256)) {
      return false;
    }
    final heads = file.heads;
    if (heads != null &&
        file.isRegistry &&
        !_rowIsCurrent(files[headsId(file.id)], heads.sha256)) {
      return false;
    }
    return true;
  }

  static bool _rowIsCurrent(FileDownloadState? row, String sha256) =>
      row != null && row.status == DownloadStatus.done && row.sha256 == sha256;

  /// Whether [file] may be USED from [modelsFolder]: the ONE rule the
  /// router's preset, the decision heads reader and the Models page's
  /// `On disk` share.
  ///
  /// Every entry needs its files in the folder. A REGISTRY entry needs
  /// [isCurrent] as well: its GGUF and heads file are a PAIR that must belong
  /// together, and existence alone would let a new GGUF run with old heads
  /// (a quit between the two legs, a digest bump on the same file names), and
  /// the decisions written that way are never redone. A file placed by hand
  /// with no row (`make decide-fetch`) is used once a model ensurer pass, at
  /// the next launch or a Download press, has hashed it in place and recorded
  /// it, with or without a registry address. A `source: local` entry has
  /// no rows, and a Hugging Face entry is served on its files as it always
  /// was.
  bool servable(ModelFile file, String modelsFolder) {
    if (!ModelManifest.filesPresent(file, modelsFolder)) return false;
    return !file.isRegistry || isCurrent(file);
  }

  /// Every file in [manifest] is [isCurrent] — the whole set, at this build's
  /// digests. What the gate and the wizard's resume both ask.
  ///
  /// A `source: local` entry is SKIPPED: it is installed by hand and never
  /// has a row, and a decision model that is not installed must not send a
  /// finished setup back through the wizard. The wizard gate hands this the
  /// manifest's `gating` view, which leaves the decision model's registry
  /// entry out on the same reasoning (decision D7) and keeps the embedding
  /// model wherever it is downloaded from ([ModelFile.gatesSetup]).
  bool matches(ModelManifest manifest) {
    for (final file in manifest.models) {
      if (file.isLocal) continue;
      if (!isCurrent(file)) return false;
    }
    return true;
  }

  /// True when every id in [ids] is done, whatever digest its row carries.
  /// The question a run asks about the ids it was handed; [matches] is the
  /// one to ask about a manifest.
  bool allDone(Iterable<String> ids) {
    for (final id in ids) {
      if (!isDone(id)) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'files': {
          for (final entry in files.entries) entry.key: entry.value.toJson(),
        },
      };

  factory DownloadLedger.fromJson(Map<String, Object?> json) {
    final raw = json['files'];
    if (raw is! Map) return empty;
    final files = <String, FileDownloadState>{};
    raw.forEach((key, value) {
      if (value is! Map) return;
      files['$key'] = FileDownloadState.fromJson(
        value.cast<String, Object?>(),
        fallbackId: '$key',
      );
    });
    return DownloadLedger(Map.unmodifiable(files));
  }

  /// Never throws. A ledger is bookkeeping about files that are still on
  /// disk, so an unreadable one costs a re-verify at worst — refusing to
  /// launch over it would be the wrong trade by a wide margin.
  static DownloadLedger parse(String? text) {
    if (text == null || text.trim().isEmpty) return empty;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return empty;
      return DownloadLedger.fromJson(decoded.cast<String, Object?>());
    } on Object {
      return empty;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! DownloadLedger) return false;
    if (other.files.length != files.length) return false;
    for (final entry in files.entries) {
      if (other.files[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([
        for (final key in files.keys.toList()..sort()) Object.hash(key, files[key]),
      ]);

  @override
  String toString() => 'DownloadLedger(${files.values.join(', ')})';
}
