import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Bringing the sandboxed container's mailbox across to the unsandboxed home.
///
/// A fake HOME in a temp directory rather than the real one, obviously — but
/// also a real filesystem rather than a memory layer, because the properties
/// that matter are filesystem properties: that the WAL came across intact,
/// that the source is untouched afterwards, and that a failure leaves nothing
/// half-copied behind.
void main() {
  const bundleId = 'com.bondinbox.app';

  late Directory home;
  late Directory target;

  String containerSupport() => p.join(
        home.path,
        'Library',
        'Containers',
        bundleId,
        'Data',
        'Library',
        'Application Support',
      );

  Future<Directory> seedContainer({required bool nested}) async {
    final dir = Directory(
      nested ? p.join(containerSupport(), bundleId) : containerSupport(),
    );
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'bond_inbox.db')).writeAsString('the mailbox');
    await File(p.join(dir.path, 'bond_inbox.db-wal'))
        .writeAsString('the writes nobody checkpointed');
    await File(p.join(dir.path, 'bond_inbox.db-shm')).writeAsString('shm');
    final attachments = Directory(p.join(dir.path, 'attachments', 'ab'));
    await attachments.create(recursive: true);
    await File(p.join(attachments.path, 'abcdef.pdf')).writeAsString('%PDF-1.4');
    return dir;
  }

  /// Root reads a file whatever its mode bits say, so the failures below have
  /// nothing to provoke and the case is skipped rather than asserted.
  final bool runningAsRoot = Platform.environment['USER'] == 'root';

  /// What a half-finished copy is called. Nothing may be left under one of
  /// these names: a `.incoming` database is invisible to the app, and an
  /// `attachments.incoming` directory would make the next attempt's rename
  /// fail.
  List<String> stagingLeftIn(Directory dir) => dir
      .listSync()
      .map((entity) => p.basename(entity.path))
      .where((name) => name.endsWith('.incoming'))
      .toList();

  setUp(() async {
    home = await Directory.systemTemp.createTemp('fake_home');
    target = Directory(p.join(home.path, 'Library', 'Application Support', bundleId));
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  test('the nested container layout is found and copied whole', () async {
    final source = await seedContainer(nested: true);

    final report =
        await migrateSandboxContainerData(home: home, target: target);

    expect(report.attempted, isTrue);
    expect(report.migrated, isTrue);
    expect(report.from, source.path);
    expect(report.copied, [
      'bond_inbox.db',
      'bond_inbox.db-wal',
      'bond_inbox.db-shm',
      'attachments',
    ]);
    expect(report.error, isNull);

    expect(
      await File(p.join(target.path, 'bond_inbox.db')).readAsString(),
      'the mailbox',
    );
    // The `-wal` is not bookkeeping: a database closed without a checkpoint
    // keeps its most recent writes there.
    expect(
      await File(p.join(target.path, 'bond_inbox.db-wal')).readAsString(),
      'the writes nobody checkpointed',
    );
    expect(
      await File(p.join(target.path, 'attachments', 'ab', 'abcdef.pdf'))
          .readAsString(),
      '%PDF-1.4',
    );
    // Every copy is made under a staging name and renamed at the end, so a
    // finished migration leaves none of them behind — one left here would be
    // wasted gigabytes and a rename failure on the next attempt.
    expect(stagingLeftIn(target), isEmpty);
  });

  test('the flat container layout is the second candidate', () async {
    final source = await seedContainer(nested: false);

    final report =
        await migrateSandboxContainerData(home: home, target: target);

    expect(report.migrated, isTrue);
    expect(report.from, source.path);
    expect(
      await File(p.join(target.path, 'bond_inbox.db')).readAsString(),
      'the mailbox',
    );
  });

  test('the nested layout wins when both exist', () async {
    await seedContainer(nested: false);
    final nested = await seedContainer(nested: true);
    await File(p.join(nested.path, 'bond_inbox.db')).writeAsString('the newer one');

    final report =
        await migrateSandboxContainerData(home: home, target: target);

    expect(report.from, nested.path);
    expect(
      await File(p.join(target.path, 'bond_inbox.db')).readAsString(),
      'the newer one',
    );
  });

  test('the source is left exactly as it was', () async {
    final source = await seedContainer(nested: true);
    final before = {
      for (final entity in source.listSync(recursive: true).whereType<File>())
        entity.path: entity.readAsBytesSync(),
    };

    await migrateSandboxContainerData(home: home, target: target);

    final after = {
      for (final entity in source.listSync(recursive: true).whereType<File>())
        entity.path: entity.readAsBytesSync(),
    };
    expect(after.keys.toSet(), before.keys.toSet());
    for (final path in before.keys) {
      // A copy that leaves the container intact means a bad migration costs
      // the user nothing.
      expect(after[path], before[path], reason: path);
    }
  });

  test('a target that already has a database is left alone', () async {
    await seedContainer(nested: true);
    await target.create(recursive: true);
    await File(p.join(target.path, 'bond_inbox.db')).writeAsString('already here');

    final report =
        await migrateSandboxContainerData(home: home, target: target);

    expect(report, MigrationReport.nothingToDo);
    expect(
      await File(p.join(target.path, 'bond_inbox.db')).readAsString(),
      'already here',
    );
  });

  test('no container at all is nothing to do, not a failure', () async {
    final report =
        await migrateSandboxContainerData(home: home, target: target);

    expect(report, MigrationReport.nothingToDo);
    expect(report.attempted, isFalse);
    expect(report.error, isNull);
    expect(await target.exists(), isFalse);
  });

  test('an unreadable source reports the error and leaves no half-copy',
      () async {
    final source = await seedContainer(nested: true);
    // The attachment tree is copied LAST, so making it unreadable fails the
    // migration with the database and both sidecars already staged in the
    // target — which is exactly the half-copied state that must not survive.
    final attachment = File(p.join(source.path, 'attachments', 'ab', 'abcdef.pdf'));
    await Process.run('chmod', ['000', attachment.path]);
    addTearDown(() => Process.run('chmod', ['644', attachment.path]));

    // Root reads anything regardless of the mode bits, so there is no failure
    // to provoke; skip rather than assert something that cannot happen.
    final readable = runningAsRoot ||
        await attachment
            .readAsBytes()
            .then((_) => true)
            .catchError((_) => false);
    if (readable) {
      markTestSkipped('running as root: mode 000 is still readable');
      return;
    }

    final report =
        await migrateSandboxContainerData(home: home, target: target);

    expect(report.attempted, isTrue);
    expect(report.migrated, isFalse);
    expect(report.error, isNotNull);
    expect(report.copied, isEmpty);
    // Half a mailbox in the new home would read as "already migrated" on the
    // next launch and the user would never get the rest.
    expect(await File(p.join(target.path, 'bond_inbox.db')).exists(), isFalse);
    expect(stagingLeftIn(target), isEmpty);
  });

  /// The database is the file the "already migrated" check reads, so a failure
  /// on IT is the one that decides whether the user ever gets a second chance.
  ///
  /// This runs before `runApp`, against a mailbox that can be gigabytes: a
  /// user watching a bouncing dock icon for ten seconds force-quits, and
  /// whatever is in the target at that moment is what the next launch
  /// inherits. A truncated `bond_inbox.db` there is unreachable mail for good;
  /// a staging name is nothing at all, which is why the copy lands under one.
  test('a failed database copy leaves the target empty and retryable',
      () async {
    final source = await seedContainer(nested: true);
    final db = File(p.join(source.path, 'bond_inbox.db'));
    await Process.run('chmod', ['000', db.path]);
    addTearDown(() => Process.run('chmod', ['644', db.path]));

    final readable = runningAsRoot ||
        await db.readAsBytes().then((_) => true).catchError((_) => false);
    if (readable) {
      markTestSkipped('running as root: mode 000 is still readable');
      return;
    }

    final failed =
        await migrateSandboxContainerData(home: home, target: target);

    expect(failed.migrated, isFalse);
    expect(failed.error, isNotNull);
    expect(await File(p.join(target.path, 'bond_inbox.db')).exists(), isFalse);
    expect(stagingLeftIn(target), isEmpty);

    // And the whole point of leaving nothing behind: with the source readable
    // again, the next launch migrates rather than reading the target as done.
    await Process.run('chmod', ['644', db.path]);
    final retried =
        await migrateSandboxContainerData(home: home, target: target);

    expect(retried.migrated, isTrue);
    expect(
      await File(p.join(target.path, 'bond_inbox.db')).readAsString(),
      'the mailbox',
    );
    expect(
      await File(p.join(target.path, 'attachments', 'ab', 'abcdef.pdf'))
          .readAsString(),
      '%PDF-1.4',
    );
    expect(stagingLeftIn(target), isEmpty);
  });

  /// What the previous launch left when the user force-quit it.
  ///
  /// The staging names are this function's alone, and one of them surviving a
  /// crash is the ordinary case rather than a strange one: the copy runs
  /// before `runApp`, so the user is looking at a bouncing dock icon with
  /// nothing to read. They have to be cleared, not worked around — a rename
  /// onto a directory that already exists fails, and gigabytes of half-copied
  /// attachments would otherwise sit in the target for ever.
  test('staging left by a crashed attempt is cleared, not inherited', () async {
    await seedContainer(nested: true);
    await target.create(recursive: true);
    await File(p.join(target.path, 'bond_inbox.db.incoming'))
        .writeAsString('half a mailbox from the attempt before');
    final staleTree = Directory(p.join(target.path, 'attachments.incoming'));
    await staleTree.create(recursive: true);
    await File(p.join(staleTree.path, 'half.pdf')).writeAsString('%PDF');

    final report =
        await migrateSandboxContainerData(home: home, target: target);

    expect(report.migrated, isTrue);
    expect(
      await File(p.join(target.path, 'bond_inbox.db')).readAsString(),
      'the mailbox',
    );
    expect(
      await File(p.join(target.path, 'attachments', 'ab', 'abcdef.pdf'))
          .readAsString(),
      '%PDF-1.4',
    );
    // The crashed attempt's half.pdf is gone with the rest of its tree.
    expect(
      await File(p.join(target.path, 'attachments', 'half.pdf')).exists(),
      isFalse,
    );
    expect(stagingLeftIn(target), isEmpty);
  });

  test('a report round-trips through JSON', () {
    const report = MigrationReport(
      attempted: true,
      migrated: true,
      from: '/Users/x/Library/Containers/com.bondinbox.app/…',
      copied: ['bond_inbox.db', 'attachments'],
      error: null,
    );

    expect(MigrationReport.fromJson(report.toJson()), report);
    expect(report.toJson()['copied'], ['bond_inbox.db', 'attachments']);
    expect(
      MigrationReport.fromJson(MigrationReport.nothingToDo.toJson()),
      MigrationReport.nothingToDo,
    );
  });
}
