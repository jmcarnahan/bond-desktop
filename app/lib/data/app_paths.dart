import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Every folder the app owns, named once.
///
/// The folders were implicit until now — a database path here, an attachments
/// path there — and that was survivable while the app only wrote one file.
/// It stops being survivable once the app runs its own server: the preset,
/// the pid file, the server log and tens of gigabytes of model weights all
/// live under the same root, and a caller that composes its own path is a
/// caller that can disagree with the supervisor about where the pid file is.
///
/// The root is the UNSANDBOXED application support directory,
/// `~/Library/Application Support/com.bondinbox.app/`. That is a change of
/// address from the sandboxed container the app used to live in, which is
/// what [migrateSandboxContainerData] exists for.
///
/// On Windows (unimplemented; the design is `dist/windows/README.md` →
/// What ships) the root will be `%LOCALAPPDATA%\Bond Desktop\`, read from
/// the environment rather than taken from path_provider: its
/// `getApplicationSupportDirectory()` answers a ROAMING path
/// (`%APPDATA%\<CompanyName>\<ProductName>`), and a roaming profile copies
/// its whole tree at logon and logoff. This tree is a live SQLite database
/// with `-wal` and `-shm` sidecars, an attachments folder and, by default,
/// tens of gigabytes of model weights — none of which may roam.
class AppPaths {
  AppPaths(this.support);

  final Directory support;

  /// The preset, the pid file and the empty cache the child is pointed at.
  Directory get servers => Directory(p.join(support.path, 'servers'));

  /// The server's own output. Kept apart from `servers/` because it is the
  /// one folder a user is ever asked to open and send.
  Directory get logs => Directory(p.join(support.path, 'logs'));

  /// The GGUF files. Large, and the only folder here worth deleting by hand.
  Directory get models => Directory(p.join(support.path, 'models'));

  /// See `ModelServerSupervisor.emptyCacheDir` for why an empty directory is
  /// a load-bearing part of the configuration.
  Directory get emptyCache => Directory(p.join(servers.path, 'empty-cache'));

  File get routerJson => File(p.join(servers.path, 'router.json'));

  File get routerIni => File(p.join(servers.path, 'router.ini'));

  static Future<AppPaths> locate() async =>
      AppPaths(await getApplicationSupportDirectory());
}

/// What one attempt at the container migration did.
///
/// A record rather than a bool because the answer is written to
/// `setup_state` and read back by a person diagnosing a launch that came up
/// empty. [attempted] false is "there was nothing to migrate", which is the
/// normal case and must not read as a failure.
@immutable
class MigrationReport {
  final bool attempted;
  final bool migrated;

  /// The container directory the data came from, when one was found.
  final String? from;

  /// The names copied, relative to the source — for the log line and for a
  /// person asking whether the attachments came across.
  final List<String> copied;

  final String? error;

  const MigrationReport({
    required this.attempted,
    required this.migrated,
    this.from,
    required this.copied,
    this.error,
  });

  /// No container, or the new home already has a database.
  static const MigrationReport nothingToDo =
      MigrationReport(attempted: false, migrated: false, copied: []);

  Map<String, Object?> toJson() => {
        'attempted': attempted,
        'migrated': migrated,
        'from': from,
        'copied': copied,
        'error': error,
      };

  factory MigrationReport.fromJson(Map<String, Object?> json) =>
      MigrationReport(
        attempted: json['attempted'] as bool? ?? false,
        migrated: json['migrated'] as bool? ?? false,
        from: json['from'] as String?,
        copied: [
          for (final entry in (json['copied'] as List?) ?? const []) '$entry',
        ],
        error: json['error'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is MigrationReport &&
      other.attempted == attempted &&
      other.migrated == migrated &&
      other.from == from &&
      other.error == error &&
      other.copied.length == copied.length &&
      other.copied.join(' ') == copied.join(' ');

  @override
  int get hashCode =>
      Object.hash(attempted, migrated, from, error, Object.hashAll(copied));

  @override
  String toString() => 'MigrationReport(attempted: $attempted, '
      'migrated: $migrated, from: $from, copied: $copied, error: $error)';
}

/// The database file, and the one name it has ever had.
const String _dbFileName = 'bond_inbox.db';

/// What a copy is called while it is still being made. Nothing but this
/// function ever writes or reads a name ending in it.
const String _incomingSuffix = '.incoming';

/// Brings the sandboxed app's data across to the unsandboxed home.
///
/// The app used to be sandboxed, which put its data inside
/// `~/Library/Containers/com.bondinbox.app/`. It is not sandboxed any more —
/// it has to spawn a child process and read model files the user chose — so
/// `getApplicationSupportDirectory()` now answers
/// `~/Library/Application Support/com.bondinbox.app/` and the old mailbox is
/// invisible to it. Without this, an existing user's first launch after the
/// update looks exactly like a fresh install.
///
/// TWO candidate layouts, in order, because both exist in the wild: the
/// container's Application Support carried a bundle-id subfolder in some
/// builds and not in others, and the dev machine has the nested one. The
/// first candidate holding a database wins.
///
/// NOTHING IS EVER DELETED FROM THE SOURCE. A copy that leaves the container
/// intact means a bad migration costs the user nothing — the old app, or a
/// manual copy, still finds everything where it was.
///
/// NOTHING THROWS, AND NOTHING LANDS UNDER ITS REAL NAME UNTIL ALL OF IT HAS.
/// Every file is copied to `<name>.incoming` and only renamed once the last
/// copy has returned, because the "already migrated" check above is the
/// presence of `bond_inbox.db` in the target: a copy that failed — or one the
/// user force-quit ten seconds into a three-gigabyte mailbox, which this runs
/// early enough to invite — would otherwise leave a TRUNCATED database in the
/// new home, and every launch afterwards would read it as done and show an
/// empty inbox with the real mail unreachable. The `.incoming` names carry no
/// such meaning, the catch below removes everything this call created, and a
/// stale one left by a crash is cleared at the top of the next attempt.
Future<MigrationReport> migrateSandboxContainerData({
  required Directory home,
  required Directory target,
  String bundleId = 'com.bondinbox.app',
}) async {
  final copied = <String>[];
  // Every path this call created in the target, staging names and final names
  // alike, in the order they were made. Each one is recorded BEFORE the write
  // that fills it: a name added after `copy()` returned would be the one name
  // a failure never reaches, and a half-written file is exactly what the catch
  // below exists to remove.
  final written = <String>[];
  Directory? source;
  try {
    // The presence of a database in the new home is the whole "already done"
    // check. It is more honest than a flag: a user who copied their data
    // across by hand has migrated, whatever any bookkeeping says.
    if (await File(p.join(target.path, _dbFileName)).exists()) {
      return MigrationReport.nothingToDo;
    }

    final containerSupport = p.join(
      home.path,
      'Library',
      'Containers',
      bundleId,
      'Data',
      'Library',
      'Application Support',
    );
    for (final candidate in [
      Directory(p.join(containerSupport, bundleId)),
      Directory(containerSupport),
    ]) {
      if (await File(p.join(candidate.path, _dbFileName)).exists()) {
        source = candidate;
        break;
      }
    }
    if (source == null) return MigrationReport.nothingToDo;

    await target.create(recursive: true);

    // A previous attempt that died mid-copy left its staging names behind.
    // They are this call's to replace — nothing else writes them — and a
    // rename onto one that already exists is a failure in its own right.
    await _clearStaging(target);

    // Staging name → the name it takes once every copy has finished.
    final staged = <String, String>{};

    // The database first, then its sidecars. The `-wal` is not optional
    // bookkeeping: a database closed without a checkpoint keeps its most
    // recent writes there, and copying the `.db` alone would silently lose
    // whatever the last session did.
    for (final name in [_dbFileName, '$_dbFileName-wal', '$_dbFileName-shm']) {
      final file = File(p.join(source.path, name));
      if (!await file.exists()) continue;
      final incoming = p.join(target.path, '$name$_incomingSuffix');
      written.add(incoming);
      await file.copy(incoming);
      staged[incoming] = p.join(target.path, name);
      copied.add(name);
    }

    final attachments = Directory(p.join(source.path, 'attachments'));
    if (await attachments.exists()) {
      final incoming = p.join(target.path, 'attachments$_incomingSuffix');
      written.add(incoming);
      await _copyTree(attachments, Directory(incoming));
      staged[incoming] = p.join(target.path, 'attachments');
      copied.add('attachments');
    }

    // Every byte is on disk by here, so the names can be the ones the app
    // looks for. A rename within one directory is atomic and costs nothing,
    // which is the whole reason the copies went somewhere else first.
    //
    // The DATABASE is renamed last of all the same way it is the last thing
    // written: its presence is the "already migrated" check, so a process
    // killed between two of these renames must not have left that one name
    // standing over sidecars that never arrived.
    final dbFinal = p.join(target.path, _dbFileName);
    for (final entry in [
      ...staged.entries.where((e) => e.value != dbFinal),
      ...staged.entries.where((e) => e.value == dbFinal),
    ]) {
      written.add(entry.value);
      if (FileSystemEntity.isDirectorySync(entry.key)) {
        await Directory(entry.key).rename(entry.value);
      } else {
        await File(entry.key).rename(entry.value);
      }
    }

    return MigrationReport(
      attempted: true,
      migrated: true,
      from: source.path,
      copied: copied,
    );
  } catch (e) {
    // Everything this call put in the target comes back out — the staging
    // names and any final name a failed rename run had already reached. Half a
    // mailbox in the new home would read as "already migrated" on the next
    // launch and the user would never get the rest.
    for (final path in written) {
      try {
        final FileSystemEntity entity = FileSystemEntity.isDirectorySync(path)
            ? Directory(path)
            : File(path);
        // Absent is the normal case for a name whose rename never ran.
        if (await entity.exists()) await entity.delete(recursive: true);
      } catch (cleanupError) {
        debugPrint('migration: could not clean up $path: $cleanupError');
      }
    }
    return MigrationReport(
      attempted: true,
      migrated: false,
      from: source?.path,
      copied: const [],
      error: '$e',
    );
  }
}

/// Removes what a crashed attempt left staged in the target.
///
/// It cannot throw: a stale name that will not delete is reported by the copy
/// that then fails to take it, and refusing to try at all would turn one bad
/// launch into every launch afterwards.
Future<void> _clearStaging(Directory target) async {
  try {
    await for (final entity in target.list(followLinks: false)) {
      if (!p.basename(entity.path).endsWith(_incomingSuffix)) continue;
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        debugPrint('migration: could not remove stale ${entity.path}: $e');
      }
    }
  } catch (e) {
    debugPrint('migration: could not scan ${target.path} for stale copies: $e');
  }
}

/// Recursive copy, files only — the attachments tree has no links or
/// specials in it, and a `cp -R` through the shell would be one more thing
/// that cannot be tested without a shell.
Future<void> _copyTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: from.path);
    final destination = p.join(to.path, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await Directory(p.dirname(destination)).create(recursive: true);
      await entity.copy(destination);
    }
  }
}
