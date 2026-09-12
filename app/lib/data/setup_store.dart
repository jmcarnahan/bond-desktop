import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../services/models/download_state.dart';
import 'database.dart' show BondDatabase;
import 'message_store.dart' show MessageStore;

/// One row of machine-local setup state.
@immutable
class SetupRecord {
  final String key;
  final String value;
  final String updatedAt;

  const SetupRecord({
    required this.key,
    required this.value,
    required this.updatedAt,
  });

  @override
  bool operator ==(Object other) =>
      other is SetupRecord &&
      other.key == key &&
      other.value == value &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(key, value, updatedAt);

  @override
  String toString() => 'SetupRecord($key = $value, $updatedAt)';
}

/// Which step the first run reached, what has been downloaded, whether the
/// old container was migrated.
///
/// A THIRD store over the same [BondDatabase], for `ContextStore`'s reason
/// and one of its own: nothing in here is mailbox data. Every row describes
/// THIS MACHINE — a path, a checksum, a wizard step — so it survives a
/// sign-out and a `wipeAll`, and it is the one table a re-sync must not
/// touch. Nothing here ever leaves the machine.
///
/// A key-value table rather than columns because the shape is still moving:
/// Phase 3 adds a download ledger, Phase 4 adds the wizard's own bookkeeping,
/// and a schema migration per new fact would be a migration per week. The
/// values are opaque strings — JSON where a caller needs structure — and this
/// store neither parses nor validates them.
///
/// Raw SQL through `customSelect` / `customUpdate`, exactly as [MessageStore]
/// and `ContextStore` write it.
class SetupStore {
  SetupStore(this.db);

  final BondDatabase db;

  /// Where `MigrationReport.toJson` is recorded, so a launch that came up
  /// empty can be told from one that never had anything to bring across.
  static const String containerMigrationKey = 'container_migration';

  /// Which step the first-run wizard reached, as a `SetupStep.name`.
  /// `'done'` is what the gate reads as "never show the flow again"; every
  /// other value is where a relaunch picks the wizard back up.
  static const String setupKey = 'setup';

  /// Where the model download's ledger lives — one JSON value, rewritten as
  /// the download moves. See [DownloadLedger] for why it holds no URL and
  /// why the `.part` file's length, not this row, is the resume offset.
  static const String downloadKey = 'download';

  /// The `'done'` that "Set up again" took away, stashed so the wizard can
  /// give it back.
  ///
  /// Written only when the flow is restarted on a machine that HAD finished,
  /// and read by one screen: the welcome step, which offers **Back to the
  /// inbox** when it is there. Nothing else may act on it — [setupKey] is
  /// still the only word the gate reads.
  static const String previousSetupKey = 'setup_previous';

  /// What "Set up again" keeps. Starting the wizard over must not throw away
  /// what is expensive and still true: the container migration HAPPENED, and
  /// the models are still on disk. Clearing either would re-copy a mailbox
  /// that is already here, or re-download twenty-three gigabytes that are.
  /// [previousSetupKey] is the third because it is the value "Set up again"
  /// has just stashed — a clear that took it out again would close the door
  /// the same press opened.
  static const Set<String> keptOnRestart = {
    containerMigrationKey,
    downloadKey,
    previousSetupKey,
  };

  static String _nowIso() => MessageStore.isoStamp(DateTime.now());

  static List<Variable> _args(List<Object?> values) => [
        for (final value in values) Variable(value),
      ];

  Future<String?> get(String key) async {
    final rows = await db
        .customSelect(
          'SELECT value FROM setup_state WHERE key = ?',
          variables: _args([key]),
        )
        .get();
    return rows.isEmpty ? null : rows.first.read<String>('value');
  }

  /// Writes [key], whether or not it was there.
  ///
  /// An upsert rather than a delete-then-insert so a reader in another
  /// isolate never sees the key missing: the first-run flow polls this table
  /// while a download writes to it.
  Future<void> set(String key, String value) async {
    await db.customUpdate(
      'INSERT INTO setup_state (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
      '  updated_at = excluded.updated_at',
      variables: _args([key, value, _nowIso()]),
    );
  }

  Future<void> remove(String key) async {
    await db.customUpdate(
      'DELETE FROM setup_state WHERE key = ?',
      variables: _args([key]),
    );
  }

  /// Writes the whole ledger over itself. The downloader owns the value and
  /// rewrites it as a unit, so there is nothing here to merge.
  Future<void> recordDownload(DownloadLedger ledger) =>
      set(downloadKey, jsonEncode(ledger.toJson()));

  /// The ledger, or an empty one — [DownloadLedger.parse] never throws, so an
  /// unreadable row costs a re-verify rather than a launch.
  Future<DownloadLedger> downloadLedger() async =>
      DownloadLedger.parse(await get(downloadKey));

  Future<Map<String, String>> all() async {
    final rows = await db
        .customSelect('SELECT key, value FROM setup_state ORDER BY key')
        .get();
    return {
      for (final row in rows)
        row.read<String>('key'): row.read<String>('value'),
    };
  }

  /// Empties the table except for [keep] — Phase 4's "Set up again".
  ///
  /// Keys are kept rather than dropped because starting the wizard over must
  /// not throw away what is expensive and still true: the models are still on
  /// disk and the container was still migrated. An empty [keep] clears
  /// everything, which is the honest reading of "keep nothing".
  Future<void> clearExcept(Set<String> keep) async {
    if (keep.isEmpty) {
      await db.customUpdate('DELETE FROM setup_state');
      return;
    }
    final placeholders = List.filled(keep.length, '?').join(', ');
    await db.customUpdate(
      'DELETE FROM setup_state WHERE key NOT IN ($placeholders)',
      variables: _args(keep.toList()),
    );
  }
}
