import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;

import '../system/system_info.dart';
import 'download_state.dart';
import 'model_manifest.dart';

/// 10 GiB — what the router and the OS need on top of the weights.
///
/// Not padding for its own sake: llama-server mmaps and mlocks the models,
/// macOS wants room for its own swap and snapshots, and a volume filled to
/// the last byte by this app is one where everything else on the machine
/// starts failing. It is cheaper to refuse a download than to hand back a Mac
/// with no disk left.
const int downloadHeadroomBytes = 10 * 1024 * 1024 * 1024;

/// Whether the weights will fit, and by how much they do not.
@immutable
class DiskPreflight {
  final String folder;

  /// What is still to be downloaded — the manifest total less what is done
  /// and less the bytes already sitting in `.part` files.
  final int neededBytes;

  final int headroomBytes;

  /// Free space on the volume, or null when the platform could not be asked.
  final int? freeBytes;

  /// Bond could create [folder] and put a file in it.
  ///
  /// Free space is not permission. A folder inside another account's home, a
  /// read-only mount, a locked external disk: every one of them reports
  /// gigabytes and refuses the first byte. Defaulted true so a caller that
  /// builds one of these by hand — a screen test — says only what it means to.
  final bool writable;

  const DiskPreflight({
    required this.folder,
    required this.neededBytes,
    required this.headroomBytes,
    required this.freeBytes,
    this.writable = true,
  });

  bool get known => freeBytes != null;

  /// Nothing left to download is OK whatever the volume says. The headroom is
  /// what this download would need on TOP of the weights, so asking for it
  /// when there are no weights to fetch would refuse a set that is already
  /// entirely on disk — on a machine that is merely fuller than it was the day
  /// the download finished.
  ///
  /// Unknown free space is OK too. The download hits ENOSPC and keeps its
  /// part, which is a recoverable failure with a sentence attached; refusing
  /// on ignorance would block a machine whose volume simply cannot be asked —
  /// a network mount, or a `flutter test` binary with no channel behind it.
  /// A folder that cannot be WRITTEN is a refusal whatever the arithmetic
  /// says — including a set that is already entirely here, since the run
  /// would still want to rename a `.part` over a file in it.
  bool get ok =>
      writable &&
      (neededBytes <= 0 ||
          freeBytes == null ||
          freeBytes! >= neededBytes + headroomBytes);

  /// What the volume would have to give up. Kept as `needed + headroom` even
  /// when [ok] short-circuits, so a screen can say the number it means.
  int get requiredBytes => neededBytes + headroomBytes;

  /// How much more room is wanted, or 0 when this preflight passed.
  int get shortfallBytes {
    if (ok) return 0;
    final short = requiredBytes - freeBytes!;
    return short > 0 ? short : 0;
  }

  @override
  String toString() => 'DiskPreflight($folder, need $neededBytes + '
      '$headroomBytes, free $freeBytes, writable: $writable, ok: $ok)';
}

/// What the volume holding [folder] would have to give up for this download.
///
/// [DiskPreflight.neededBytes] counts only what is genuinely still to come:
/// a file the ledger calls done AT THIS MANIFEST'S DIGEST and still sitting in
/// [folder] costs nothing, and a half-written `.part` for that same digest
/// costs only its remainder. Asking for the whole manifest every time would
/// refuse a resume that needs one more gigabyte.
///
/// The ledger alone is not enough to skip a file. It survives "Set up again"
/// and it survives a change of folder, so a done row can describe a file that
/// lives in the OLD one — and a preflight that trusted it would tell somebody
/// pointing Bond at an empty disk that everything was already there.
///
/// Free space is asked of the NEAREST EXISTING ANCESTOR of [folder], and it
/// is asked BEFORE the write probe. The models folder does not exist before
/// the first download, and the platform call wants a real path — the volume
/// is the same either way.
///
/// [DiskPreflight.writable] is measured rather than assumed: the probe creates
/// [folder] and writes one small file in it. Creating it is the cost of
/// knowing, and it is the same folder the very next step fills.
Future<DiskPreflight> checkDisk({
  required SystemInfo system,
  required ModelManifest manifest,
  required DownloadLedger ledger,
  required String folder,
  int headroomBytes = downloadHeadroomBytes,
}) async {
  var needed = 0;
  for (final model in manifest.models) {
    final dest = p.join(folder, model.relativePath);
    if (ledger.isCurrent(model) && File(dest).existsSync()) continue;
    final part = File('$dest.part');
    var already = 0;
    try {
      // Only a part the downloader will actually RESUME saves anything, and
      // its rule is the one mirrored here: a row whose sha disagrees with the
      // manifest is a model bump, and the part full of the previous
      // checkpoint's bytes is deleted rather than resumed into. A part with no
      // row at all is kept — the ledger can be lost to a crash, and it says
      // nothing about the bytes.
      final row = ledger[model.id];
      final stale = row != null && row.sha256 != model.sha256;
      if (!stale && part.existsSync()) already = part.lengthSync();
    } on FileSystemException {
      already = 0;
    }
    final remaining = model.sizeBytes - already;
    if (remaining > 0) needed += remaining;
  }
  // Asked BEFORE the probe, so the answer still comes from the volume the
  // folder will live on rather than from a directory this call just made.
  final volume = _nearestExisting(folder);
  return DiskPreflight(
    folder: folder,
    neededBytes: needed,
    headroomBytes: headroomBytes,
    freeBytes: await system.freeBytes(volume),
    writable: _canWrite(folder),
  );
}

/// Whether Bond can really put bytes in [folder], by doing the two things the
/// download is about to do: create it, and write a file inside it.
///
/// Synchronous, on the reasoning the loop above uses for `existsSync` — one
/// create and one small write on a local path are cheaper than the futures
/// they would cost, and every widget test that walks the storage step runs in
/// a zone where a real filesystem future never completes.
bool _canWrite(String folder) {
  final probe = File(p.join(folder, '.bond-write-probe'));
  try {
    Directory(folder).createSync(recursive: true);
    probe.writeAsStringSync('bond');
    return true;
  } on FileSystemException {
    return false;
  } finally {
    try {
      if (probe.existsSync()) probe.deleteSync();
    } on FileSystemException {
      // A probe that cannot be removed is not worth failing a preflight over.
    }
  }
}

/// The deepest ancestor of [path] that exists — [path] itself when it does.
///
/// Walks up rather than creating the folder: a preflight must be safe to run
/// from a screen the user has not committed to yet.
String _nearestExisting(String path) {
  var current = p.normalize(p.absolute(path));
  while (true) {
    if (Directory(current).existsSync()) return current;
    final parent = p.dirname(current);
    if (parent == current) return current;
    current = parent;
  }
}
