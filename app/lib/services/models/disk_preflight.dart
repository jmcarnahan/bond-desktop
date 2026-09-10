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

  const DiskPreflight({
    required this.folder,
    required this.neededBytes,
    required this.headroomBytes,
    required this.freeBytes,
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
  bool get ok =>
      neededBytes <= 0 ||
      freeBytes == null ||
      freeBytes! >= neededBytes + headroomBytes;

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
      '$headroomBytes, free $freeBytes, ok: $ok)';
}

/// What the volume holding [folder] would have to give up for this download.
///
/// [DiskPreflight.neededBytes] counts only what is genuinely still to come:
/// a file the ledger calls done AND still sitting in [folder] costs nothing,
/// and a half-written `.part` costs only its remainder. Asking for the whole
/// manifest every time would refuse a resume that needs one more gigabyte.
///
/// The ledger alone is not enough to skip a file. It survives "Set up again"
/// and it survives a change of folder, so a done row can describe a file that
/// lives in the OLD one — and a preflight that trusted it would tell somebody
/// pointing Bond at an empty disk that everything was already there.
///
/// Free space is asked of the NEAREST EXISTING ANCESTOR of [folder]. The
/// models folder does not exist before the first download, and the platform
/// call wants a real path — the volume is the same either way.
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
    if (ledger.isDone(model.id) && File(dest).existsSync()) continue;
    final part = File('$dest.part');
    var already = 0;
    try {
      if (part.existsSync()) already = part.lengthSync();
    } on FileSystemException {
      already = 0;
    }
    final remaining = model.sizeBytes - already;
    if (remaining > 0) needed += remaining;
  }
  return DiskPreflight(
    folder: folder,
    neededBytes: needed,
    headroomBytes: headroomBytes,
    freeBytes: await system.freeBytes(_nearestExisting(folder)),
  );
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
