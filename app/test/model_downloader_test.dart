import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_downloader.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_hub_server.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/test_manifest.dart';

/// A sink that writes [after] bytes through to the real file and then behaves
/// like a volume with nothing left on it.
///
/// A fake rather than a small volume, because the property under test is what
/// the downloader does with ENOSPC — and a `flutter test` that filled the
/// machine's disk to find out would be a poor trade.
class _EnospcSink implements IOSink {
  _EnospcSink(this._inner, this._path, {required this.after, this.onFlush = false});

  final IOSink _inner;
  final String _path;
  final int after;

  /// Throw from [flush] rather than from [add] — both are how a full disk
  /// really reports itself, depending on where the buffer gave out.
  final bool onFlush;

  int _written = 0;

  FileSystemException get _full => FileSystemException(
        'writeFrom failed',
        _path,
        const OSError('No space left on device', 28),
      );

  @override
  void add(List<int> data) {
    final room = after - _written;
    if (room > 0) {
      final slice = data.length <= room ? data : data.sublist(0, room);
      _written += slice.length;
      _inner.add(slice);
    }
    if (_written >= after && !onFlush) throw _full;
  }

  @override
  Future<void> flush() async {
    await _inner.flush();
    if (onFlush && _written >= after) throw _full;
  }

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(add);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;

  @override
  void write(Object? object) => add(utf8.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');
}

/// What the downloader does against a socket that behaves like the hub.
///
/// Plain `test`, never `testWidgets`: every case here awaits a real server
/// and a real file, and a fake-async zone would hang the run rather than fail
/// it. The temp directory and the server are made in `setUp` for the same
/// reason.
void main() {
  late FakeHubServer hub;
  late Directory root;
  late FakeSystemInfo system;
  late ModelManifest manifest;
  late DownloadLedger ledger;
  late List<Duration> sleeps;
  late List<String> ledgerWrites;

  String folder() => p.join(root.path, 'models');

  String destOf(ModelFile file) => p.join(folder(), file.relativePath);

  String partOf(ModelFile file) =>
      '${destOf(file)}${ModelDownloader.partSuffix}';

  /// Fills the hub with deterministic bytes and returns a manifest whose
  /// sizes and digests describe exactly those bytes.
  ModelManifest publish({
    int embed = 2048,
    int bulk = 8192,
    int prose = 16384,
  }) {
    final sizes = <String, int>{};
    final digests = <String, String>{};
    final base = testManifest();
    var seed = 1;
    for (final entry in <String, int>{
      routerEmbedId: embed,
      routerBulkId: bulk,
      routerProseId: prose,
    }.entries) {
      final file = base.byId(entry.key);
      final data = fakeWeights(entry.value, seed: seed++);
      hub.contents['${file.repo}/${file.file}'] = data;
      sizes[entry.key] = data.length;
      digests[entry.key] = sha256Hex(data);
    }
    return testManifest(sizes: sizes, sha256s: digests);
  }

  ModelDownloader build({
    ModelManifest? which,
    Duration progressInterval = const Duration(milliseconds: 1),
    Duration ledgerInterval = Duration.zero,
    int maxAttempts = 10,
    String Function()? at,
    OpenPart? openPart,
    Uri Function(ModelFile)? resolveUri,
  }) {
    final downloader = ModelDownloader(
      manifest: which ?? manifest,
      modelsFolder: at ?? folder,
      openPart: openPart,
      readLedger: () async => ledger,
      writeLedger: (updated) async {
        ledger = updated;
        ledgerWrites.add(jsonEncode(updated.toJson()));
      },
      sha256: system.sha256,
      beginActivity: system.beginActivity,
      endActivity: system.endActivity,
      resolveUri: resolveUri ?? hub.resolveUriFor,
      // Recorded, never slept: a backoff schedule is the property under test
      // and nine real minutes of it is not.
      sleep: (d) async => sleeps.add(d),
      maxAttempts: maxAttempts,
      progressInterval: progressInterval,
      ledgerInterval: ledgerInterval,
    );
    addTearDown(downloader.dispose);
    return downloader;
  }

  Future<void> seedPart(ModelFile file, int length, {String? sha}) async {
    final path = partOf(file);
    await Directory(p.dirname(path)).create(recursive: true);
    final source = hub.contents['${file.repo}/${file.file}']!;
    await File(path).writeAsBytes(source.sublist(0, length));
    ledger = ledger.record(FileDownloadState(
      id: file.id,
      status: DownloadStatus.paused,
      receivedBytes: length,
      totalBytes: file.sizeBytes,
      sha256: sha ?? file.sha256,
    ));
  }

  List<DownloadStatus> statusesFor(
    List<DownloadProgress> events,
    String id,
  ) =>
      [for (final e in events) if (e.id == id) e.status];

  setUp(() async {
    hub = await FakeHubServer.start();
    root = await Directory.systemTemp.createTemp('model-download');
    system = FakeSystemInfo();
    // Null makes every verify fall through to the Dart digest, which is what
    // a `flutter test` binary really gets.
    system.digest = null;
    sleeps = [];
    ledgerWrites = [];
    ledger = DownloadLedger.empty;
    manifest = publish();
  });

  tearDown(() async {
    await hub.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('two fresh files land, smallest first, with no Range anywhere',
      () async {
    final embed = manifest.byId(routerEmbedId);
    final bulk = manifest.byId(routerBulkId);

    final events = await build().run([bulk, embed]).toList();

    final embedStatuses = statusesFor(events, routerEmbedId);
    // The COUNT of progress ticks is the throttle's business, not this
    // test's; the order is what this one pins.
    expect(
      embedStatuses.where((s) => s == DownloadStatus.downloading).length,
      greaterThanOrEqualTo(1),
    );
    expect(embedStatuses.first, DownloadStatus.pending);
    expect(embedStatuses.last, DownloadStatus.done);
    expect(embedStatuses[embedStatuses.length - 2], DownloadStatus.verifying);
    expect(embedStatuses.indexOf(DownloadStatus.downloading),
        lessThan(embedStatuses.indexOf(DownloadStatus.verifying)));
    expect(statusesFor(events, routerBulkId).last, DownloadStatus.done);

    // Smallest first regardless of the order the caller gave.
    final embedDone = events.indexWhere(
        (e) => e.id == routerEmbedId && e.status == DownloadStatus.done);
    final bulkStart = events.indexWhere(
        (e) => e.id == routerBulkId && e.status == DownloadStatus.downloading);
    expect(embedDone, lessThan(bulkStart));

    for (final file in [embed, bulk]) {
      expect(File(destOf(file)).readAsBytesSync(),
          hub.contents['${file.repo}/${file.file}']);
      expect(File(partOf(file)).existsSync(), isFalse);
      expect(ledger[file.id]?.status, DownloadStatus.done);
      expect(ledger[file.id]?.sha256, file.sha256);
      expect(ledger[file.id]?.receivedBytes, file.sizeBytes);
    }
    expect(hub.resolveRanges, [null, null]);
    expect(hub.cdnRanges, [null, null]);
  });

  test('a half-written part resumes at its own length', () async {
    final embed = manifest.byId(routerEmbedId);
    await seedPart(embed, 700);

    await build().run([embed]).toList();

    expect(hub.resolveRanges, ['bytes=700-']);
    expect(hub.cdnRanges, ['bytes=700-']);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
    expect(ledger[embed.id]?.status, DownloadStatus.done);
  });

  test('a server that ignores Range restarts the part from zero', () async {
    final embed = manifest.byId(routerEmbedId);
    await seedPart(embed, 700);
    hub.ignoreRange = true;

    final events = await build().run([embed]).toList();

    expect(events.last.status, DownloadStatus.done);
    // Keeping the old prefix under a 200 would have duplicated 700 bytes.
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('a part already the whole size is verified without a request',
      () async {
    final embed = manifest.byId(routerEmbedId);
    await seedPart(embed, embed.sizeBytes);

    final events = await build().run([embed]).toList();

    expect(events.last.status, DownloadStatus.done);
    expect(hub.resolveCount, 0);
    expect(hub.cdnCount, 0);
    expect(File(destOf(embed)).existsSync(), isTrue);
  });

  test('a CDN that answers 416 goes straight to the verify', () async {
    // The manifest claims ten bytes more than the repo holds, which is what a
    // 416 to a ranged GET means in practice.
    final data = hub.contents['ggml-org/embeddinggemma-300M-GGUF/'
        'embeddinggemma-300M-Q8_0.gguf']!;
    manifest = testManifest(
      sizes: {routerEmbedId: data.length + 10},
      sha256s: {routerEmbedId: sha256Hex(data)},
    );
    hub.linkedSizeOverride = data.length + 10;
    final embed = manifest.byId(routerEmbedId);
    await seedPart(embed, data.length);

    final events = await build().run([embed]).toList();

    expect(hub.resolveRanges, ['bytes=${data.length}-']);
    expect(hub.cdnRanges, ['bytes=${data.length}-']);
    expect(events.last.status, DownloadStatus.done);
    expect(File(destOf(embed)).readAsBytesSync(), data);
  });

  test('a rate limit is waited out for exactly as long as it asked',
      () async {
    hub.rateLimitOnce = true;
    final embed = manifest.byId(routerEmbedId);

    final events = await build().run([embed]).toList();

    expect(sleeps, [const Duration(seconds: 1)]);
    expect(events.last.status, DownloadStatus.done);
  });

  test('an expired signature is re-resolved rather than waited on', () async {
    final embed = manifest.byId(routerEmbedId);
    await seedPart(embed, 500);
    // The first token the hub hands out is refused, which is what an hour-old
    // signed URL looks like.
    hub.expireTokensBelow = 2;

    final events = await build().run([embed]).toList();

    expect(hub.resolveCount, 2);
    expect(hub.cdnRanges, ['bytes=500-', 'bytes=500-']);
    // Nothing is wrong, so nothing is waited for.
    expect(sleeps, isEmpty);
    expect(events.last.status, DownloadStatus.done);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('cancelling mid-stream keeps the part, and a new run finishes it',
      () async {
    manifest = publish(embed: 512 * 1024);
    final embed = manifest.byId(routerEmbedId);
    hub.chunkDelay = const Duration(milliseconds: 5);

    final downloader = build();
    var asked = false;
    final events = <DownloadProgress>[];
    final finished = Completer<void>();
    downloader.run([embed]).listen(
      (event) {
        events.add(event);
        if (!asked &&
            event.status == DownloadStatus.downloading &&
            event.receivedBytes > 0) {
          asked = true;
          unawaited(downloader.cancel());
        }
      },
      onDone: finished.complete,
    );
    await finished.future;

    expect(events.last.status, DownloadStatus.paused);
    expect(ledger[embed.id]?.status, DownloadStatus.paused);
    final partLength = File(partOf(embed)).lengthSync();
    expect(partLength, greaterThan(0));
    expect(partLength, lessThan(embed.sizeBytes));
    expect(ledger[embed.id]?.receivedBytes, partLength);
    expect(File(destOf(embed)).existsSync(), isFalse);

    // A different downloader over the same ledger and folder — which is what
    // a relaunch is.
    hub.chunkDelay = null;
    hub.cdnRanges.clear();
    final second = await build().run([embed]).toList();

    expect(hub.cdnRanges.single, 'bytes=$partLength-');
    expect(second.last.status, DownloadStatus.done);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('pause holds the run, and resume picks the same file up', () async {
    manifest = publish(embed: 512 * 1024);
    final embed = manifest.byId(routerEmbedId);
    hub.chunkDelay = const Duration(milliseconds: 5);

    final downloader = build();
    var asked = false;
    var resumed = false;
    final events = <DownloadProgress>[];
    final finished = Completer<void>();
    downloader.run([embed]).listen(
      (event) {
        events.add(event);
        if (!asked &&
            event.status == DownloadStatus.downloading &&
            event.receivedBytes > 0) {
          asked = true;
          hub.chunkDelay = null;
          unawaited(downloader.pause());
        } else if (!resumed && event.status == DownloadStatus.paused) {
          resumed = true;
          unawaited(downloader.resume());
        }
      },
      onDone: finished.complete,
    );
    await finished.future;

    expect(events.map((e) => e.status), contains(DownloadStatus.paused));
    expect(events.last.status, DownloadStatus.done);
    expect(hub.resolveCount, 2);
    expect(hub.resolveRanges.first, isNull);
    expect(hub.resolveRanges.last, startsWith('bytes='));
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('a dropped socket backs off once and resumes where it stopped',
      () async {
    final embed = manifest.byId(routerEmbedId);
    hub.dropAfterBytes = 1000;

    final events = await build().run([embed]).toList();

    expect(sleeps, [const Duration(seconds: 2)]);
    expect(hub.cdnRanges, [null, 'bytes=1000-']);
    expect(events.last.status, DownloadStatus.done);
  });

  test('ten fruitless attempts give up as network, and the run goes on',
      () async {
    final embed = manifest.byId(routerEmbedId);
    final bulk = manifest.byId(routerBulkId);
    hub.dropAlways = true;
    hub.dropAfterBytes = 0;
    hub.dropOnly = {'${embed.repo}/${embed.file}'};

    final events = await build().run([embed, bulk]).toList();

    expect(sleeps, const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 32),
      Duration(seconds: 60),
      Duration(seconds: 60),
      Duration(seconds: 60),
      Duration(seconds: 60),
    ]);
    final failed = events.lastWhere((e) => e.id == routerEmbedId);
    expect(failed.status, DownloadStatus.failed);
    expect(failed.error, DownloadError.network);
    // The part survives the give-up: a retry tomorrow starts where it stopped.
    expect(File(partOf(embed)).existsSync(), isTrue);

    // An eighteen-gigabyte failure must not hide a finished neighbour.
    expect(events.lastWhere((e) => e.id == routerBulkId).status,
        DownloadStatus.done);
    expect(File(destOf(bulk)).existsSync(), isTrue);
  });

  test('a second run while one is in flight is refused', () async {
    final embed = manifest.byId(routerEmbedId);
    final downloader = build();

    final stream = downloader.run([embed]);
    expect(() => downloader.run([embed]), throwsStateError);

    expect((await stream.toList()).last.status, DownloadStatus.done);
    expect(downloader.running, isFalse);
  });

  test('the App Nap activity is begun once and ended once', () async {
    await build().run([
      manifest.byId(routerEmbedId),
      manifest.byId(routerBulkId),
    ]).toList();

    expect(system.activities.map((a) => a.toString()), [
      'begin(${ModelDownloader.activityReason})',
      'end(1)',
    ]);
  });

  test('a part written under a different manifest sha is thrown away',
      () async {
    final embed = manifest.byId(routerEmbedId);
    await seedPart(embed, 700, sha: 'f' * 64);

    final events = await build().run([embed]).toList();

    // Resuming into bytes from another checkpoint would spend the whole
    // download to fail a checksum at the end.
    expect(hub.resolveRanges, [null]);
    expect(hub.cdnRanges, [null]);
    expect(events.last.status, DownloadStatus.done);
    expect(ledger[embed.id]?.sha256, embed.sha256);
  });

  test('a gated repo fails before any bytes are asked for', () async {
    hub.gated = true;

    final events = await build().run([manifest.byId(routerEmbedId)]).toList();

    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, DownloadError.gated);
    expect(hub.cdnCount, 0);
  });

  test('a linked size that disagrees with the manifest stops the download',
      () async {
    hub.linkedSizeOverride = 99;

    final events = await build().run([manifest.byId(routerEmbedId)]).toList();

    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, DownloadError.manifestMismatch);
    expect(hub.cdnCount, 0);
  });

  test('a linked etag that disagrees with the manifest stops the download',
      () async {
    hub.linkedEtagOverride = 'b' * 64;

    final events = await build().run([manifest.byId(routerEmbedId)]).toList();

    expect(events.last.error, DownloadError.manifestMismatch);
    expect(hub.cdnCount, 0);
  });

  test('nothing written to the ledger names the CDN', () async {
    await build().run([manifest.byId(routerEmbedId)]).toList();

    expect(ledgerWrites, isNotEmpty);
    for (final written in ledgerWrites) {
      expect(written, isNot(contains('127.0.0.1')));
      expect(written, isNot(contains('cdn')));
      expect(written, isNot(contains('http')));
    }
  });

  test('progress is throttled well below the chunk rate', () async {
    manifest = publish(embed: 1024 * 1024);
    final embed = manifest.byId(routerEmbedId);
    hub.chunkDelay = const Duration(milliseconds: 5);

    final events = await build(
      progressInterval: const Duration(milliseconds: 250),
      ledgerInterval: const Duration(seconds: 2),
    ).run([embed]).toList();

    final ticks = events
        .where((e) => e.status == DownloadStatus.downloading)
        .length;
    // Sixteen 64 KiB chunks go over the wire; a screen must not be asked to
    // redraw for each of them.
    expect(ticks, lessThan(8));
    expect(events.last.status, DownloadStatus.done);
  });

  test('a hub that answers the body itself is streamed directly', () async {
    hub.resolveDirect = true;
    final embed = manifest.byId(routerEmbedId);

    final events = await build().run([embed]).toList();

    expect(hub.cdnCount, 0);
    expect(events.last.status, DownloadStatus.done);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('a finished file the ledger vouches for is skipped entirely',
      () async {
    final embed = manifest.byId(routerEmbedId);
    await Directory(p.dirname(destOf(embed))).create(recursive: true);
    await File(destOf(embed))
        .writeAsBytes(hub.contents['${embed.repo}/${embed.file}']!);
    ledger = ledger.record(FileDownloadState(
      id: embed.id,
      status: DownloadStatus.done,
      receivedBytes: embed.sizeBytes,
      totalBytes: embed.sizeBytes,
      sha256: embed.sha256,
    ));

    final events = await build().run([embed]).toList();

    expect(events.map((e) => e.status),
        [DownloadStatus.pending, DownloadStatus.done]);
    expect(hub.requests, isEmpty);
    expect(system.sha256Paths, isEmpty);
  });

  test('a destination the ledger cannot vouch for is re-verified and re-taken',
      () async {
    final embed = manifest.byId(routerEmbedId);
    await Directory(p.dirname(destOf(embed))).create(recursive: true);
    await File(destOf(embed)).writeAsBytes(List.filled(embed.sizeBytes, 9));

    final events = await build().run([embed]).toList();

    expect(events.map((e) => e.status), contains(DownloadStatus.verifying));
    expect(hub.resolveCount, 1);
    expect(events.last.status, DownloadStatus.done);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('run with no argument takes the whole manifest, smallest first',
      () async {
    final events = await build().run().toList();

    expect(
      [
        for (final e in events)
          if (e.status == DownloadStatus.done) e.id,
      ],
      [routerEmbedId, routerBulkId, routerProseId],
    );
  });

  test('a 404 at the hub is reported as its own code', () async {
    hub.resolveStatusOverride = HttpStatus.notFound;

    final events = await build().run([manifest.byId(routerEmbedId)]).toList();

    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, 'http_404');
  });

  test('a 5xx at the hub is retried on the backoff schedule', () async {
    hub.resolveStatusOverride = HttpStatus.badGateway;

    final events = await build().run([manifest.byId(routerEmbedId)]).toList();

    expect(sleeps, [const Duration(seconds: 2)]);
    expect(events.last.status, DownloadStatus.done);
  });

  test(
      'a full disk fails the file with disk_full, keeps the part, and the '
      'next file still finishes', () async {
    final embed = manifest.byId(routerEmbedId);
    final bulk = manifest.byId(routerBulkId);
    const wrote = 500;

    final events = await build(
      openPart: (path, {required append}) async {
        final inner = File(path)
            .openWrite(mode: append ? FileMode.append : FileMode.writeOnly);
        if (path != partOf(embed)) return inner;
        return _EnospcSink(inner, path, after: wrote);
      },
    ).run([embed, bulk]).toList();

    final failed = events.lastWhere((e) => e.id == routerEmbedId);
    expect(failed.status, DownloadStatus.failed);
    expect(failed.error, DownloadError.diskFull);
    // The part is KEPT. A user who frees ten gigabytes and presses Retry must
    // not start the whole download over.
    final partLength = File(partOf(embed)).lengthSync();
    expect(partLength, greaterThan(0));
    expect(partLength, greaterThanOrEqualTo(wrote));
    expect(File(destOf(embed)).existsSync(), isFalse);
    expect(ledger[embed.id]?.status, DownloadStatus.failed);
    expect(ledger[embed.id]?.error, DownloadError.diskFull);

    // A full disk on one file is not a full disk on the run.
    expect(events.lastWhere((e) => e.id == routerBulkId).status,
        DownloadStatus.done);
    expect(File(destOf(bulk)).readAsBytesSync(),
        hub.contents['${bulk.repo}/${bulk.file}']);
    expect(ledger[bulk.id]?.receivedBytes, bulk.sizeBytes);
  });

  test('a disk that fills up on the flush lands on disk_full too', () async {
    final embed = manifest.byId(routerEmbedId);
    const wrote = 400;

    final events = await build(
      openPart: (path, {required append}) async {
        final inner = File(path)
            .openWrite(mode: append ? FileMode.append : FileMode.writeOnly);
        return _EnospcSink(inner, path, after: wrote, onFlush: true);
      },
    ).run([embed]).toList();

    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, DownloadError.diskFull);
    expect(File(partOf(embed)).lengthSync(), wrote);
    expect(File(destOf(embed)).existsSync(), isFalse);
  });

  test('a body that ends early keeps the budget while bytes keep landing',
      () async {
    final embed = manifest.byId(routerEmbedId);
    // Every answer is a legitimate, correctly labelled short one: 300 bytes
    // of the range that was asked for, then a clean end.
    hub.shortBodyBytes = 300;

    final events = await build(maxAttempts: 3).run([embed]).toList();

    // Seven answers of 300 bytes is well past three attempts: a stream that
    // ends early but DELIVERED must not spend a life out of the budget.
    expect(events.last.status, DownloadStatus.done);
    expect(hub.cdnRanges.length, 7);
    expect(hub.cdnRanges[1], 'bytes=300-');
    expect(sleeps, List.filled(6, const Duration(seconds: 2)));
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('a part with no ledger row at all is resumed rather than thrown away',
      () async {
    final embed = manifest.byId(routerEmbedId);
    final path = partOf(embed);
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsBytes(
        hub.contents['${embed.repo}/${embed.file}']!.sublist(0, 700));

    final events = await build().run([embed]).toList();

    // The ledger is written every couple of seconds and a crash can lose it
    // whole, so a missing row says nothing about the bytes. Being wrong here
    // costs one checksum; deleting on it costs the download.
    expect(hub.resolveRanges, ['bytes=700-']);
    expect(hub.cdnRanges, ['bytes=700-']);
    expect(events.last.status, DownloadStatus.done);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('a part longer than the manifest says is dropped and taken again',
      () async {
    final embed = manifest.byId(routerEmbedId);
    final path = partOf(embed);
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsBytes(List.filled(embed.sizeBytes + 50, 3));
    ledger = ledger.record(FileDownloadState(
      id: embed.id,
      status: DownloadStatus.paused,
      receivedBytes: embed.sizeBytes + 50,
      totalBytes: embed.sizeBytes,
      sha256: embed.sha256,
    ));

    final events = await build().run([embed]).toList();

    // The file behind the manifest changed size without changing its name;
    // resuming past the end would ask for a range nothing can answer.
    expect(hub.resolveRanges.first, isNull);
    expect(hub.cdnRanges.first, isNull);
    expect(events.last.status, DownloadStatus.done);
    expect(File(destOf(embed)).readAsBytesSync(),
        hub.contents['${embed.repo}/${embed.file}']);
  });

  test('a models folder under a regular file fails as missing_folder',
      () async {
    final blocker = p.join(root.path, 'not-a-directory');
    await File(blocker).writeAsString('a file where a folder should be');

    final events = await build(at: () => p.join(blocker, 'models'))
        .run([manifest.byId(routerEmbedId)]).toList();

    // A volume that is no longer mounted, or a path that is not a folder at
    // all, says so once rather than per byte.
    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, DownloadError.missingFolder);
    expect(hub.requests, isEmpty);
  });

  test('a cancel while the resume gate is held ends the run', () async {
    manifest = publish(embed: 512 * 1024);
    final embed = manifest.byId(routerEmbedId);
    hub.chunkDelay = const Duration(milliseconds: 5);

    final downloader = build();
    var asked = false;
    var cancelled = false;
    final events = <DownloadProgress>[];
    final finished = Completer<void>();
    downloader.run([embed]).listen(
      (event) {
        events.add(event);
        if (!asked &&
            event.status == DownloadStatus.downloading &&
            event.receivedBytes > 0) {
          asked = true;
          unawaited(downloader.pause());
        } else if (!cancelled && event.status == DownloadStatus.paused) {
          cancelled = true;
          unawaited(downloader.cancel());
        }
      },
      onDone: finished.complete,
    );
    await finished.future;

    // Nobody is ever going to complete that gate, so the cancel has to.
    expect(events.last.status, DownloadStatus.paused);
    expect(ledger[embed.id]?.status, DownloadStatus.paused);
    expect(downloader.running, isFalse);
    expect(File(partOf(embed)).lengthSync(), greaterThan(0));
    expect(File(destOf(embed)).existsSync(), isFalse);
  });

  test('a rate limit at the CDN is waited out as the CDN asked', () async {
    final embed = manifest.byId(routerEmbedId);
    hub.cdnRateLimitOnce = true;

    final events = await build().run([embed]).toList();

    expect(sleeps, [const Duration(seconds: 1)]);
    expect(hub.cdnCount, 2);
    expect(events.last.status, DownloadStatus.done);
  });

  test('a 429 whose only header is Retry-After waits exactly that long',
      () async {
    hub.rateLimitRetryAfterOnce = true;

    final events = await build().run([manifest.byId(routerEmbedId)]).toList();

    expect(sleeps, [const Duration(seconds: 3)]);
    expect(events.last.status, DownloadStatus.done);
  });

  test('a 429 with nothing to read waits the longest backoff', () async {
    hub.rateLimitBareOnce = true;

    final events = await build().run([manifest.byId(routerEmbedId)]).toList();

    // Nothing said when to come back, so the answer is the cap rather than a
    // guess that hammers a server which has already said no.
    expect(sleeps, [const Duration(seconds: 60)]);
    expect(events.last.status, DownloadStatus.done);
  });

  test('a rate limit asking for a day is still capped at the longest backoff',
      () async {
    // `t=86400` is tomorrow. A downloader that took it literally would leave
    // the wizard's download step sitting on a spinner for a day, and the
    // whole point of the cap is that nothing a server says can do that.
    final wall = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => wall.close(force: true));
    wall.listen((request) async {
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.headers.set('RateLimit', '"api";r=0;t=86400');
      await request.response.close();
    });

    final events = await build(
      maxAttempts: 2,
      resolveUri: (file) => Uri.parse(
        'http://127.0.0.1:${wall.port}/${file.repo}/resolve/'
        '${file.revision}/${file.file}',
      ),
    ).run([manifest.byId(routerEmbedId)]).toList();

    expect(sleeps, [const Duration(seconds: 60)]);
    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, DownloadError.network);
  });

  test('a second expired signature with no bytes in between waits',
      () async {
    hub.expireAll = true;

    final events =
        await build(maxAttempts: 3).run([manifest.byId(routerEmbedId)]).toList();

    // The first 403 is re-resolved at once, because nothing is wrong. The
    // second in a row is a wall, and a wall waits like any other.
    expect(sleeps, [const Duration(seconds: 2)]);
    expect(events.last.status, DownloadStatus.failed);
    expect(events.last.error, DownloadError.network);
  });
}
