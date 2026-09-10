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
    // The attachment is copied LAST, so making it unreadable fails the
    // migration after the database and both sidecars are already in the
    // target — which is exactly the half-copied state that must not survive.
    final attachment = File(p.join(source.path, 'attachments', 'ab', 'abcdef.pdf'));
    await Process.run('chmod', ['000', attachment.path]);
    addTearDown(() => Process.run('chmod', ['644', attachment.path]));

    // Root reads anything regardless of the mode bits, so there is no failure
    // to provoke; skip rather than assert something that cannot happen.
    final readable = await attachment
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
