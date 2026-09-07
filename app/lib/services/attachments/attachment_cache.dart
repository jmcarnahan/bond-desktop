import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:path/path.dart' as p;

/// Where an attachment's bytes live once they have been fetched, so that
/// opening the same file twice costs one download.
///
/// **Content-addressed**, by the sha-256 of the bytes: the path is
/// `<root>/<sha[0:2]>/<sha>.<ext>`. A quote forwarded down a thread three times
/// is three attachment rows with three connector ids and ONE file on disk, which
/// is the ordinary case rather than a clever one — mail duplicates attachments
/// every time somebody replies-all with them. It also makes a re-fetch free to
/// verify: the same bytes land on the same path, so a second write is a no-op
/// rather than a rewrite.
///
/// **The file keeps the name's extension**, and that is not cosmetic. Opening a
/// document means handing macOS a path, and both Preview and `open` decide what
/// an unknown file is by its extension — a bare hash opens in a text editor
/// showing a PDF's binary. The two-character prefix directory is the git
/// convention and for the git reason: a flat directory of ten thousand files is
/// slow to list on every sweep.
///
/// **The sweep is the whole eviction policy**: oldest by modification time,
/// down to [maxBytes], run after every write. Nothing else expires — an
/// attachment is small, a mailbox is finite, and a scheduled cleaner would be a
/// timer doing IO nobody asked for.
class AttachmentCache {
  /// Two gigabytes, a constant rather than a setting (round decision 8). It is
  /// a number nobody has a reason to have an opinion about, and offering the
  /// opinion is how a settings screen fills up with dials.
  static const int defaultMaxBytes = 2 * 1024 * 1024 * 1024;

  /// Resolved ONCE, lazily, on first use. Passed as a closure rather than a
  /// path because `getApplicationSupportDirectory` is a platform channel: a
  /// provider that awaited it eagerly would make building the cache an async
  /// step, and a widget test that never touches a file would pay for a plugin
  /// nobody answers.
  final Future<Directory> Function() _root;

  final int maxBytes;

  AttachmentCache(this._root, {this.maxBytes = defaultMaxBytes});

  Future<Directory>? _resolving;

  /// The root, created if it is not there. Memoised on the FUTURE, not on the
  /// directory, so two concurrent first calls resolve one channel round trip
  /// between them.
  Future<Directory> _dir() =>
      _resolving ??= _root().then((dir) => dir.create(recursive: true));

  /// Stores [bytes] and says where they went.
  ///
  /// Returns the path and the hex digest, because the caller writes both onto
  /// the attachment row: the path is how the file is found again, and the digest
  /// is how a thumbnail is named beside it.
  ///
  /// A write that lands on an existing file only touches its modification
  /// time. Same bytes, same path — rewriting them would cost a disk write to
  /// produce a byte-identical file, and the touch is what keeps a file the user
  /// keeps opening from being the oldest thing the sweep finds.
  Future<({String path, String sha256})> put(
    Uint8List bytes, {
    String? name,
  }) async {
    // Off the UI isolate: hashing ten megabytes is tens of milliseconds of
    // pure CPU, and a frame is sixteen. Top-level worker, sendable argument.
    final digest = await compute(attachmentSha256Hex, bytes);
    final root = await _dir();
    final folder = Directory(p.join(root.path, digest.substring(0, 2)));
    await folder.create(recursive: true);

    final extension = _extensionOf(name);
    final path = p.join(
      folder.path,
      extension.isEmpty ? digest : '$digest.$extension',
    );
    final file = File(path);

    if (await file.exists()) {
      await _touch(file);
    } else {
      await _writeAtomic(file, bytes);
    }

    // The file just written is never the file evicted, however full the cache
    // is: the caller is about to render it.
    await sweep(keep: path);
    return (path: path, sha256: digest);
  }

  /// A rendered preview for the blob with digest [sha256].
  ///
  /// Beside the blob and named after it, so removing one directory removes a
  /// file and its picture together. Overwritten rather than skipped when it
  /// already exists: a thumbnail is derived, and the newest derivation of the
  /// same bytes is the one worth keeping.
  Future<String> putThumbnail(String sha256, Uint8List bytes) async {
    final root = await _dir();
    final folder = Directory(p.join(root.path, sha256.substring(0, 2)));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, '$sha256.thumb'));
    await _writeAtomic(file, bytes);
    return file.path;
  }

  /// The bytes at [path], or null.
  ///
  /// Null is the ordinary answer, not an error: a path on an attachment row
  /// outlives the file at it. The sweep evicted it, the user cleared the cache,
  /// or the row synced from a database copied off another machine. Every caller
  /// treats null as "fetch it again".
  Future<Uint8List?> read(String path) async {
    if (path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on FileSystemException catch (e) {
      debugPrint('attachment cache could not read $path: $e');
      return null;
    }
  }

  /// What the tree occupies, in bytes. Walked rather than tracked: a counter
  /// would drift the first time anything outside this class touched the
  /// directory, and the walk is a stat per file.
  Future<int> sizeBytes() async {
    final files = await _files();
    var total = 0;
    for (final entry in files) {
      total += entry.size;
    }
    return total;
  }

  /// Evicts oldest-first until the tree fits in [maxBytes]. Returns how many
  /// files went.
  ///
  /// [keep] is never evicted whatever its age — it is the file the caller just
  /// wrote and is about to show. A cache smaller than its newest file would
  /// otherwise delete that file and re-fetch it forever.
  Future<int> sweep({String? keep}) async {
    final files = await _files();
    var total = 0;
    for (final entry in files) {
      total += entry.size;
    }
    if (total <= maxBytes) return 0;

    files.sort((a, b) => a.modified.compareTo(b.modified));
    var evicted = 0;
    for (final entry in files) {
      if (total <= maxBytes) break;
      if (entry.path == keep) continue;
      try {
        await File(entry.path).delete();
      } on FileSystemException catch (e) {
        debugPrint('attachment cache could not evict ${entry.path}: $e');
        continue;
      }
      total -= entry.size;
      evicted++;
    }
    return evicted;
  }

  /// Empties the cache and leaves the root standing.
  ///
  /// The root survives because everything that clears the cache is followed by
  /// something writing to it — a sign-out that then signs in, a Settings clear
  /// on a running app — and a missing root would make the next write's
  /// `create` the thing that could fail.
  Future<void> clear() async {
    final root = await _dir();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    await root.create(recursive: true);
  }

  /// The hex sha-256 of [bytes]. Synchronous and static: [put] runs it inside
  /// a `compute`, and callers that need to hash a short string (a Teams
  /// attachment's identity, say) pay nothing for an isolate.
  static String hashOf(Uint8List bytes) => attachmentSha256Hex(bytes);

  /// Every file under the root, with what the sweep sorts on.
  Future<List<({String path, int size, DateTime modified})>> _files() async {
    final root = await _dir();
    if (!await root.exists()) return const [];
    final out = <({String path, int size, DateTime modified})>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        out.add((
          path: entity.path,
          size: stat.size,
          modified: stat.modified,
        ));
      } on FileSystemException {
        // Raced with an eviction or an external delete. A file that is gone
        // occupies nothing and needs no eviction.
        continue;
      }
    }
    return out;
  }

  /// Written to a neighbouring temp file and renamed into place.
  ///
  /// A rename within one filesystem is atomic, so a crash mid-write leaves the
  /// temp file rather than a half-file at a content-addressed path — which is
  /// the one thing this cache must never have, because the path asserts what
  /// the bytes are.
  static Future<void> _writeAtomic(File file, Uint8List bytes) async {
    final temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}'
        '.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  static Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } on FileSystemException catch (e) {
      // Not every filesystem allows it, and an un-touched mtime costs an early
      // eviction rather than a wrong answer.
      debugPrint('attachment cache could not touch ${file.path}: $e');
    }
  }

  /// A short, safe extension from a file name, or `''`.
  ///
  /// Deliberately stricter than the display-side `extensionOf`: this string
  /// becomes part of a path, so anything but up to eight lower-case
  /// alphanumerics is dropped rather than sanitised. A file whose extension is
  /// refused still caches — it just opens by content type instead.
  static String _extensionOf(String? name) {
    final trimmed = (name ?? '').trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0 || dot == trimmed.length - 1) return '';
    final raw = trimmed.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(raw) ? raw : '';
  }
}

/// The hex sha-256 of [bytes].
///
/// Top-level so it can cross an isolate port — `compute`'s callback has to be a
/// top-level or static function, and a closure over the cache would not be
/// sendable.
String attachmentSha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();
