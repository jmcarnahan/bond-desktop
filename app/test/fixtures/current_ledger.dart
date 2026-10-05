import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';

/// A ledger whose rows say every leg of [files] landed at the manifest's
/// digests: the weights, a sidecar's `.draft` row and a registry entry's
/// `.heads` row. What a fixture that puts a REGISTRY entry's files on disk
/// needs beside them, since `DownloadLedger.servable` serves such an entry
/// only while its rows are current. A `source: local` entry gets no row.
DownloadLedger currentLedgerFor(
  Iterable<ModelFile> files, {
  DownloadLedger from = DownloadLedger.empty,
}) {
  var ledger = from;
  FileDownloadState done(String id, String sha256, int size) =>
      FileDownloadState(
        id: id,
        status: DownloadStatus.done,
        receivedBytes: size,
        totalBytes: size,
        sha256: sha256,
      );
  for (final file in files) {
    if (file.isLocal) continue;
    ledger = ledger.record(done(file.id, file.sha256, file.sizeBytes));
    final head = file.sidecar;
    if (head != null) {
      ledger = ledger.record(
          done(DownloadLedger.draftId(file.id), head.sha256, head.sizeBytes));
    }
    final heads = file.heads;
    if (heads != null && file.isRegistry) {
      ledger = ledger.record(
          done(DownloadLedger.headsId(file.id), heads.sha256, heads.sizeBytes));
    }
  }
  return ledger;
}
