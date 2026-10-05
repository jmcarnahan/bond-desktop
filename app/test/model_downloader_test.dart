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

  String draftDestOf(ModelFile file) =>
      p.join(folder(), file.sidecarRelativePath!);

  /// The hub URL for a sidecar — the same shape as [FakeHubServer.resolveUriFor]
  /// with the head's own name and revision, which is the whole reason the
  /// downloader takes a second seam.
  Uri draftUri(ModelFile file, ModelSidecar sidecar) => Uri.parse(
        'http://127.0.0.1:${hub.port}/${file.repo}/resolve/'
        '${sidecar.revision}/${sidecar.file}',
      );

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

  /// [publish], plus an MTP head for the prose entry served from the same
  /// repo. Its bytes differ from every checkpoint's, so a leg that fetched
  /// the wrong file would fail its digest rather than pass by accident.
  ModelManifest publishWithSidecar({int head = 3072}) {
    final base = publish();
    final parent = base.byId(routerProseId);
    final data = fakeWeights(head, seed: 9);
    hub.contents['${parent.repo}/mtp-Qwen3.8-27B-Q4_0.gguf'] = data;
    return testManifest(
      sizes: {for (final m in base.models) m.id: m.sizeBytes},
      sha256s: {for (final m in base.models) m.id: m.sha256},
      proseSidecar:
          testSidecar(sizeBytes: data.length, sha256: sha256Hex(data)),
    );
  }

  ModelDownloader build({
    ModelManifest? which,
    Duration progressInterval = const Duration(milliseconds: 1),
    Duration ledgerInterval = Duration.zero,
    int maxAttempts = 10,
    String Function()? at,
    OpenPart? openPart,
    Uri Function(ModelFile)? resolveUri,
    ResolveSidecarUri? resolveSidecarUri,
    String Function()? registryBase,
    String? Function(String base)? registryToken,
  }) {
    final downloader = ModelDownloader(
      manifest: which ?? manifest,
      modelsFolder: at ?? folder,
      registryBase: registryBase,
      registryToken: registryToken,
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
      resolveSidecarUri: resolveSidecarUri ?? draftUri,
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

  test('idle is complete with no run, and completes only when a run ends',
      () async {
    manifest = publish(embed: 512 * 1024);
    final downloader = build();
    var idle = false;
    await downloader.idle.then((_) => idle = true);
    expect(idle, isTrue, reason: 'no run in flight');

    hub.chunkDelay = const Duration(milliseconds: 5);
    final events = downloader.run().toList();
    var ended = false;
    unawaited(downloader.idle.then((_) => ended = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(downloader.running, isTrue);
    expect(ended, isFalse);

    hub.chunkDelay = null;
    await downloader.idle;
    expect(downloader.running, isFalse);
    expect(ended, isTrue);
    expect((await events).last.status, DownloadStatus.done);
  });

  test('a cancelled run completes idle too', () async {
    manifest = publish(embed: 512 * 1024);
    hub.chunkDelay = const Duration(milliseconds: 5);
    final downloader = build();
    final events = downloader.run().toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await downloader.cancel();
    await downloader.idle;

    expect(downloader.running, isFalse);
    await events;
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

  test('a hand-installed entry is never fetched, listed or recorded',
      () async {
    // A `source: local` decision model has no URL to fetch: it is copied in
    // by hand. Handed to a run, whether by the caller or through the whole
    // manifest, it must cost no request and no ledger row — even with a
    // registry configured.
    final embed = manifest.byId(routerEmbedId);
    final decide = testLocalDecideFile();

    final events = await build(
      registryBase: () => hub.registryBase,
      registryToken: (_) => _fakeToken,
    ).run([decide, embed]).toList();

    expect(events.where((e) => e.id == routerDecideId), isEmpty);
    expect(statusesFor(events, routerEmbedId).last, DownloadStatus.done);
    expect(ledger[routerDecideId], isNull);
    expect(ledger[DownloadLedger.headsId(routerDecideId)], isNull);
    expect(hub.resolveRanges, [null]);
    expect(hub.registryCount, 0);
    expect(File(destOf(decide)).existsSync(), isFalse);
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

  group('the sidecar', () {
    test('lands after its parent, verified, under its finished name',
        () async {
      manifest = publishWithSidecar();
      final prose = manifest.byId(routerProseId);
      final head = prose.sidecar!;

      await build().run([prose]).toList();

      // Both files, both renamed, no parts left behind.
      expect(File(destOf(prose)).readAsBytesSync(),
          hub.contents['${prose.repo}/${prose.file}']);
      expect(File(draftDestOf(prose)).readAsBytesSync(),
          hub.contents['${prose.repo}/${head.file}']);
      expect(File(partOf(prose)).existsSync(), isFalse);
      expect(
        File('${draftDestOf(prose)}${ModelDownloader.partSuffix}').existsSync(),
        isFalse,
      );

      // The PARENT first. A head with no model to draft for is worth nothing,
      // so a run that stops between them keeps the file that is worth more.
      final asked = [for (final u in hub.requests) p.basename(u.path)];
      expect(asked.indexOf(prose.file), lessThan(asked.indexOf(head.file)));

      // Two rows, each at its own digest, the head under `<id>.draft`.
      expect(ledger[prose.id]?.status, DownloadStatus.done);
      expect(ledger[prose.id]?.sha256, prose.sha256);
      expect(ledger[prose.id]?.totalBytes, prose.sizeBytes);
      final draft = ledger[DownloadLedger.draftId(prose.id)]!;
      expect(draft.status, DownloadStatus.done);
      expect(draft.sha256, head.sha256);
      expect(draft.totalBytes, head.sizeBytes);
      expect(ledger.isCurrent(prose), isTrue);
    });

    test('is ONE bar: one done, counted over both files', () async {
      manifest = publishWithSidecar();
      final prose = manifest.byId(routerProseId);

      final events = await build().run([prose]).toList();

      // Every event is the entry's, never the draft row's — a second id here
      // would be a second row on the wizard's screen.
      expect({for (final e in events) e.id}, {routerProseId});
      // And exactly one terminal event, at the end. A `done` when the weights
      // landed would finish the bar with the head still to come.
      expect(
        statusesFor(events, routerProseId)
            .where((s) => s == DownloadStatus.done)
            .length,
        1,
      );
      expect(events.last.status, DownloadStatus.done);
      expect(events.last.totalBytes, prose.downloadBytes);
      expect(events.last.receivedBytes, prose.downloadBytes);
      expect(events.last.fraction, 1);
      // The bar never goes backwards across the seam: the sidecar's bytes are
      // counted on top of the weights', not from zero again.
      var high = 0;
      for (final e in events) {
        expect(e.receivedBytes, greaterThanOrEqualTo(high));
        expect(e.totalBytes, prose.downloadBytes);
        high = e.receivedBytes;
      }
    });

    test('a head whose bytes are wrong is taken again, then failed', () async {
      manifest = publishWithSidecar();
      final good = manifest.byId(routerProseId);
      // The manifest asks for a digest the repo's head does not have, which
      // is what a bumped sidecar looks like from here.
      manifest = testManifest(
        sizes: {for (final m in manifest.models) m.id: m.sizeBytes},
        sha256s: {for (final m in manifest.models) m.id: m.sha256},
        proseSidecar: testSidecar(
          sizeBytes: good.sidecar!.sizeBytes,
          sha256: 'b' * 64,
        ),
      );
      final prose = manifest.byId(routerProseId);
      // The hub answers an etag that is not a sha at all, which is what the
      // real one does for a non-LFS object — so the redirect check abstains
      // and the failure is the VERIFY's, which is the path under test.
      hub.linkedEtagOverride = 'not-a-sha';

      final events = await build().run([prose]).toList();

      // Twice is not a flipped bit in flight, it is the wrong file.
      final headAsks = [
        for (final u in hub.requests)
          if (p.basename(u.path) == prose.sidecar!.file) u,
      ];
      expect(headAsks, hasLength(greaterThanOrEqualTo(4)));
      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.checksum);
      // Nothing is left behind for the next run to resume into, and the
      // PARENT survives: its own bytes were never in question.
      expect(
        File('${draftDestOf(prose)}${ModelDownloader.partSuffix}').existsSync(),
        isFalse,
      );
      expect(File(draftDestOf(prose)).existsSync(), isFalse);
      expect(File(destOf(prose)).existsSync(), isTrue);
      expect(ledger[prose.id]?.status, DownloadStatus.done);
      expect(
        ledger[DownloadLedger.draftId(prose.id)]?.status,
        DownloadStatus.failed,
      );
    });

    test('an unexpected throw on the head fails the head, not the weights',
        () async {
      manifest = publishWithSidecar();
      final prose = manifest.byId(routerProseId);

      // A bug, not a network fault: something the run has no word for, thrown
      // while the SIDECAR is being written. Failing the entry's first leg
      // here would write `failed` at zero bytes over a `done` row describing
      // eighteen gigabytes that are on the disk and correct.
      final events = await build(
        openPart: (path, {required append}) async {
          if (path.contains('mtp-')) throw StateError('a bug in the sink');
          return File(path)
              .openWrite(mode: append ? FileMode.append : FileMode.writeOnly);
        },
      ).run([prose]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.network);

      // The weights kept their row and their file.
      expect(ledger[prose.id]?.status, DownloadStatus.done);
      expect(ledger[prose.id]?.sha256, prose.sha256);
      expect(ledger[prose.id]?.receivedBytes, prose.sizeBytes);
      expect(File(destOf(prose)).existsSync(), isTrue);

      // The head is the one that failed, under its own row.
      final draft = ledger[DownloadLedger.draftId(prose.id)]!;
      expect(draft.status, DownloadStatus.failed);
      expect(draft.error, DownloadError.network);
      // And the entry is not current, so the next launch fetches the head.
      expect(ledger.isCurrent(prose), isFalse);
    });

    test('verify wants both files, not just the weights', () async {
      manifest = publishWithSidecar();
      final prose = manifest.byId(routerProseId);
      final downloader = build();

      await downloader.run([prose]).toList();
      expect(await downloader.verify(prose), isTrue);

      // A head from the previous build, under the right name. The weights
      // still hash correctly, and a verify that stopped there would call this
      // checkpoint servable when the preset's `model-draft` is wrong.
      await File(draftDestOf(prose)).writeAsBytes(fakeWeights(64, seed: 77));
      expect(await downloader.verify(prose), isFalse);
    });

    test('a parent done with no head is not current, and the run fetches it',
        () async {
      manifest = publishWithSidecar();
      final prose = manifest.byId(routerProseId);

      // The ledger a build BEFORE the sidecar would have left: the weights
      // done, nothing about a head. A launch that trusted it would start a
      // server whose preset names a file that is not there.
      ledger = DownloadLedger.empty.record(FileDownloadState(
        id: prose.id,
        status: DownloadStatus.done,
        receivedBytes: prose.sizeBytes,
        totalBytes: prose.sizeBytes,
        sha256: prose.sha256,
      ));
      expect(ledger.isCurrent(prose), isFalse);
      expect(ledger.matches(manifest), isFalse);

      await File(destOf(prose)).create(recursive: true);
      await File(destOf(prose))
          .writeAsBytes(hub.contents['${prose.repo}/${prose.file}']!);

      final events = await build().run([prose]).toList();

      expect(events.last.status, DownloadStatus.done);
      expect(File(draftDestOf(prose)).existsSync(), isTrue);
      expect(ledger.isCurrent(prose), isTrue);

      // The skipped leg SAYS where the entry already is. Without that, the
      // bar would read zero from the `pending` event until the head's first
      // bytes landed, which on a real 1.6 GB head looks stuck.
      final afterPending = events.skip(1).toList();
      expect(afterPending.first.status, DownloadStatus.downloading);
      expect(afterPending.first.receivedBytes, prose.sizeBytes);
      for (final e in afterPending) {
        expect(e.receivedBytes, greaterThanOrEqualTo(prose.sizeBytes));
      }
      // The weights were not fetched again: the row and the file agreed.
      expect(
        [for (final u in hub.requests) p.basename(u.path)],
        isNot(contains(prose.file)),
      );
    });
  });

  group('the registry', () {
    const bundle = 'bond-decide-mbl-v3swap';

    String headsDestOf(ModelFile file) =>
        p.join(folder(), file.headsRelativePath!);

    /// Serves the decision model's two files from the fake registry and
    /// returns a registry entry whose sizes and digests describe them.
    /// [headsSha] lies about the heads file, for the checksum case.
    ModelFile publishDecide({
      int gguf = 6144,
      int heads = 1536,
      String? headsSha,
    }) {
      final weights = fakeWeights(gguf, seed: 21);
      final head = fakeWeights(heads, seed: 22);
      hub.registryContents['$bundle/model-f16.gguf'] = weights;
      hub.registryContents['$bundle/heads.json'] = head;
      return testDecideFile(
        sizeBytes: weights.length,
        sha256: sha256Hex(weights),
        headsSizeBytes: head.length,
        headsSha256: headsSha ?? sha256Hex(head),
      );
    }

    ModelDownloader buildRegistry({String? Function(String base)? token}) =>
        build(
          registryBase: () => hub.registryBase,
          registryToken: token ?? (_) => _fakeToken,
        );

    test('weights and heads land under the app names with the bearer',
        () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;

      final events = await buildRegistry().run([decide]).toList();

      expect(File(destOf(decide)).readAsBytesSync(),
          hub.registryContents['$bundle/model-f16.gguf']);
      expect(File(headsDestOf(decide)).readAsBytesSync(),
          hub.registryContents['$bundle/heads.json']);
      expect(headsDestOf(decide),
          endsWith('artifactory_bond-decide-mbl-v3swap/decide-heads.json'));
      expect(File(partOf(decide)).existsSync(), isFalse);
      expect(File('${headsDestOf(decide)}${ModelDownloader.partSuffix}')
          .existsSync(), isFalse);

      expect(ledger[routerDecideId]?.status, DownloadStatus.done);
      expect(ledger[routerDecideId]?.sha256, decide.sha256);
      final headsRow = ledger[DownloadLedger.headsId(routerDecideId)];
      expect(headsRow?.status, DownloadStatus.done);
      expect(headsRow?.sha256, decide.heads!.sha256);
      expect(ledger.isCurrent(decide), isTrue);

      // Two requests, both to the bundle's own names, both with the bearer.
      expect(hub.registryCount, 2);
      expect(hub.registryAuth, ['Bearer $_fakeToken', 'Bearer $_fakeToken']);
      expect(
        [for (final u in hub.requests) u.path],
        [
          '/artifactory/bond-models/bundles/$bundle/model-f16.gguf',
          '/artifactory/bond-models/bundles/$bundle/heads.json',
        ],
      );
      expect(hub.resolveCount, 0);

      // ONE bar: every event speaks for the whole entry, and only the heads
      // leg, the last, says done.
      final mine = [for (final e in events) if (e.id == routerDecideId) e];
      expect(decide.downloadBytes, decide.sizeBytes + decide.heads!.sizeBytes);
      for (final e in mine) {
        expect(e.totalBytes, decide.downloadBytes);
      }
      expect(mine.where((e) => e.status == DownloadStatus.done), hasLength(1));
      expect(mine.last.status, DownloadStatus.done);
      expect(mine.last.receivedBytes, decide.downloadBytes);
      // Nothing the run wrote names the token.
      for (final written in ledgerWrites) {
        expect(written.contains(_fakeToken), isFalse);
      }
      for (final e in events) {
        expect('$e'.contains(_fakeToken), isFalse);
      }
    });

    test('a resumed registry leg sends the bearer AND the Range', () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;
      final path = partOf(decide);
      await Directory(p.dirname(path)).create(recursive: true);
      await File(path).writeAsBytes(
          hub.registryContents['$bundle/model-f16.gguf']!.sublist(0, 700));
      ledger = ledger.record(FileDownloadState(
        id: decide.id,
        status: DownloadStatus.paused,
        receivedBytes: 700,
        totalBytes: decide.sizeBytes,
        sha256: decide.sha256,
      ));

      await buildRegistry().run([decide]).toList();

      expect(hub.registryRanges.first, 'bytes=700-');
      expect(hub.registryAuth.first, 'Bearer $_fakeToken');
      expect(File(destOf(decide)).readAsBytesSync(),
          hub.registryContents['$bundle/model-f16.gguf']);
      expect(ledger.isCurrent(decide), isTrue);
    });

    test('a cross-origin redirect target never receives the token', () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;
      await hub.startStorage();
      hub.registryRedirect = true;

      // A trailing slash on the base, as a pasted address often has.
      final events = await build(
        registryBase: () => '${hub.registryBase}/',
        registryToken: (_) => _fakeToken,
      ).run([decide]).toList();

      expect(events.last.status, DownloadStatus.done);
      expect(hub.registryAuth, ['Bearer $_fakeToken', 'Bearer $_fakeToken']);
      expect(hub.storageCount, 2);
      expect(hub.storageAuth, [null, null]);
      expect(File(destOf(decide)).readAsBytesSync(),
          hub.registryContents['$bundle/model-f16.gguf']);
      expect(File(headsDestOf(decide)).readAsBytesSync(),
          hub.registryContents['$bundle/heads.json']);
      expect(ledger.isCurrent(decide), isTrue);
    });

    test('no registry address fails the entry before any request, and the '
        'rest of the set still downloads', () async {
      final decide = publishDecide();
      final embed = manifest.byId(routerEmbedId);

      for (final base in <String Function()?>[() => '  ', null]) {
        ledger = DownloadLedger.empty;
        final events = await build(
          registryBase: base,
          registryToken: (_) => _fakeToken,
        ).run([decide, embed]).toList();

        final failed = events.lastWhere((e) => e.id == routerDecideId);
        expect(failed.status, DownloadStatus.failed);
        expect(failed.error, DownloadError.registryNotConfigured);
        expect(failed.totalBytes, decide.downloadBytes);
        expect(ledger[routerDecideId]?.status, DownloadStatus.failed);
        expect(ledger[routerDecideId]?.error,
            DownloadError.registryNotConfigured);
        expect(statusesFor(events, routerEmbedId).last, DownloadStatus.done);
        expect(hub.registryCount, 0);
        await File(destOf(embed)).delete();
      }
    });

    test('no registry address leaves an entry already here alone', () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;
      await buildRegistry().run([decide]).toList();
      final landed = ledger;
      final requests = hub.registryCount;

      final events =
          await build(registryBase: () => '').run([decide]).toList();

      expect(events.last.status, DownloadStatus.done);
      expect(hub.registryCount, requests);
      expect(ledger, landed);
    });

    test('a refused token fails as unauthorized with no retry storm',
        () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;

      final events = await build(
        registryBase: () => hub.registryBase,
        registryToken: (_) => 'not-the-test-token',
      ).run([decide]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.unauthorized);
      expect(hub.registryCount, 1);
      expect(sleeps, isEmpty);
      expect(ledger[routerDecideId]?.error, DownloadError.unauthorized);
      expect(ledger[DownloadLedger.headsId(routerDecideId)], isNull);
    });

    test('a 403 from the registry itself is unauthorized too', () async {
      final decide = publishDecide();
      hub.registryStatusOverride = HttpStatus.forbidden;

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.error, DownloadError.unauthorized);
      expect(hub.registryCount, 1);
      expect(sleeps, isEmpty);
    });

    test('no token sends no authorization header at all', () async {
      final decide = publishDecide();

      for (final token in <String? Function(String)>[(_) => null, (_) => '']) {
        ledger = DownloadLedger.empty;
        hub.registryAuth.clear();
        final folderNow = Directory(folder());
        if (folderNow.existsSync()) folderNow.deleteSync(recursive: true);

        final events = await buildRegistry(token: token).run([decide]).toList();

        expect(events.last.status, DownloadStatus.done);
        expect(hub.registryAuth, [null, null]);
      }
    });

    test('heads whose bytes are wrong fail the heads leg as checksum, and '
        'the weights stay done', () async {
      final decide = publishDecide(headsSha: '1' * 64);

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.checksum);
      expect(ledger[routerDecideId]?.status, DownloadStatus.done);
      final headsRow = ledger[DownloadLedger.headsId(routerDecideId)];
      expect(headsRow?.status, DownloadStatus.failed);
      expect(headsRow?.error, DownloadError.checksum);
      expect(File(headsDestOf(decide)).existsSync(), isFalse);
      expect(ledger.isCurrent(decide), isFalse);
      // Taken twice, the checksum retry, then given up on.
      expect(
        [for (final u in hub.requests) p.basename(u.path)]
            .where((name) => name == 'heads.json'),
        hasLength(2),
      );
    });

    test('a chain that returns to the registry origin carries the token '
        'there again, and storage still gets none', () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;
      await hub.startStorage();
      hub.registryRedirect = true;
      hub.storageBounceBack = true;

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.status, DownloadStatus.done);
      // Per file: the resolve, then the hop back. Every one with the token.
      expect(hub.registryAuth, hasLength(4));
      expect(hub.registryAuth, everyElement('Bearer $_fakeToken'));
      expect(hub.storageCount, 2);
      expect(hub.storageAuth, [null, null]);
      expect(ledger.isCurrent(decide), isTrue);
    });

    test('a relative Location on a hand-followed hop resolves against that '
        'hop', () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;
      await hub.startStorage();
      hub.registryRedirect = true;
      hub.storageRelativeHop = true;

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.status, DownloadStatus.done);
      // Resolved against the REGISTRY, `/served/...` would have been asked of
      // the registry and answered 404; it was asked of storage instead.
      expect(hub.storagePaths, [
        '/store/$bundle/model-f16.gguf',
        '/served/$bundle/model-f16.gguf',
        '/store/$bundle/heads.json',
        '/served/$bundle/heads.json',
      ]);
      expect(hub.storageAuth, everyElement(isNull));
      expect(hub.registryCount, 2);
    });

    test('a redirect loop stops after the hop limit with the redirect code, '
        'and is not retried', () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;
      await hub.startStorage();
      hub.registryRedirect = true;
      hub.storageLoop = true;

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.http(HttpStatus.found));
      expect(sleeps, isEmpty);
      expect(hub.registryCount, 1);
      // The first hop and five more, then the limit.
      expect(hub.storageCount, 6);
      expect(hub.storageAuth, everyElement(isNull));
    });

    test('a 403 from the storage origin re-resolves rather than failing as '
        'unauthorized, with a token and without one', () async {
      final decide = publishDecide();
      await hub.startStorage();
      hub.registryRedirect = true;

      for (final token in <String? Function(String)>[(_) => _fakeToken, (_) => null]) {
        ledger = DownloadLedger.empty;
        hub.registryAuth.clear();
        hub.storageAuth.clear();
        final folderNow = Directory(folder());
        if (folderNow.existsSync()) folderNow.deleteSync(recursive: true);
        hub.storageForbidden = 1;
        final before = hub.registryCount;

        final events = await buildRegistry(token: token).run([decide]).toList();

        expect(events.last.status, DownloadStatus.done,
            reason: 'token: ${token('') != null}');
        expect(events.where((e) => e.error == DownloadError.unauthorized),
            isEmpty);
        // The weights' resolve, its re-resolve after the 403, then the heads.
        expect(hub.registryCount - before, 3);
        expect(hub.storageAuth, everyElement(isNull));
      }
    });

    test('a registry 404 fails as registry_not_found after one request',
        () async {
      final decide = publishDecide();
      hub.registryContents.remove('$bundle/model-f16.gguf');

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.registryNotFound);
      expect(ledger[decide.id]!.error, DownloadError.registryNotFound);
      expect(hub.registryCount, 1);
      expect(sleeps, isEmpty);
    });

    test('a redirect from the registry to a sign-in page fails at once as '
        'registry_not_a_model, writing no part', () async {
      final decide = publishDecide();
      hub.registryBearer = _fakeToken;
      await hub.startStorage();
      hub.registryRedirect = true;
      hub.storageWebPage = true;

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.registryNotAModel);
      expect(hub.storageCount, 1);
      expect(sleeps, isEmpty);
      expect(File(partOf(decide)).existsSync(), isFalse);
    });

    test('a registry entry asked to rehash keeps a good file without a '
        'request, and replaces a wrong one', () async {
      final decide = publishDecide();
      final downloader = buildRegistry();
      await downloader.run([decide]).toList();
      final asked = hub.registryCount;

      final kept =
          await downloader.run([decide], {decide.id}).toList();
      expect(kept.last.status, DownloadStatus.done);
      expect(hub.registryCount, asked);

      await File(headsDestOf(decide)).writeAsBytes(List<int>.filled(16, 1));
      final skipped = await downloader.run([decide]).toList();
      expect(skipped.last.status, DownloadStatus.done);
      expect(hub.registryCount, asked, reason: 'the ledger fast path');

      final replaced =
          await downloader.run([decide], {decide.id}).toList();
      expect(replaced.last.status, DownloadStatus.done);
      expect(File(headsDestOf(decide)).readAsBytesSync(),
          hub.registryContents['$bundle/heads.json']);
      expect(hub.registryCount, greaterThan(asked));
    });

    test('a rehash that proves a file wrong deletes it before the fetch, so a '
        'replacement that never arrives leaves nothing to serve, and a later '
        'run fetches it', () async {
      final decide = publishDecide();
      final downloader = buildRegistry();
      await downloader.run([decide]).toList();
      await File(headsDestOf(decide)).writeAsBytes(List<int>.filled(16, 1));

      // The registry refuses the token: the replacement never arrives.
      hub.registryBearer = 'another-fake-token';
      final refused = await downloader.run([decide], {decide.id}).toList();

      expect(refused.last.status, DownloadStatus.failed);
      expect(File(headsDestOf(decide)).existsSync(), isFalse,
          reason: 'a file proven wrong must not stay');
      expect(ledger.isCurrent(decide), isFalse);

      hub.registryBearer = null;
      final fixed = await downloader.run([decide]).toList();

      expect(fixed.last.status, DownloadStatus.done);
      expect(sha256Hex(File(headsDestOf(decide)).readAsBytesSync()),
          decide.heads!.sha256);
      expect(ledger.isCurrent(decide), isTrue);
    });

    test('a rehash takes the entry out of service with its first ledger '
        'write, and a good one is current again with no byte fetched',
        () async {
      final decide = publishDecide();
      final downloader = buildRegistry();
      await downloader.run([decide]).toList();
      expect(ledger.servable(decide, folder()), isTrue);
      final asked = hub.registryCount;
      final before = ledgerWrites.length;

      await downloader.run([decide], {decide.id}).toList();

      final servable = [
        for (final written in ledgerWrites.skip(before))
          DownloadLedger.parse(written).servable(decide, folder()),
      ];
      expect(servable.first, isFalse,
          reason: 'nothing serves the entry while it is hashed again');
      expect(servable.last, isTrue);
      expect(hub.registryCount, asked);
      expect(ledger.isCurrent(decide), isTrue);
    });

    test('a registry leg proven wrong takes its row out of done before its '
        'replacement is fetched', () async {
      final decide = publishDecide();
      final downloader = buildRegistry();
      await downloader.run([decide]).toList();
      await File(headsDestOf(decide)).writeAsBytes(List<int>.filled(16, 1));
      hub.registryBearer = 'another-fake-token';
      final before = ledgerWrites.length;

      await downloader.run([decide], {decide.id}).toList();

      final headsRows = [
        for (final written in ledgerWrites.skip(before))
          DownloadLedger.parse(written)[DownloadLedger.headsId(decide.id)]
              ?.status,
      ];
      expect(headsRows, isNot(contains(DownloadStatus.done)));
      expect(ledger[DownloadLedger.headsId(decide.id)]?.status,
          DownloadStatus.failed);
      expect(ledger.servable(decide, folder()), isFalse);
    });

    group('the address and the token come from one snapshot', () {
      late FakeHubServer other;
      late ModelFile second;

      setUp(() async {
        other = await FakeHubServer.start();
        // A second registry entry, larger, so it is fetched after decide.
        const secondBundle = 'bond-second-bundle';
        final weights = fakeWeights(9000, seed: 41);
        final head = fakeWeights(700, seed: 42);
        for (final server in [hub, other]) {
          server.registryContents['$secondBundle/model-f16.gguf'] = weights;
          server.registryContents['$secondBundle/heads.json'] = head;
        }
        second = ModelFile(
          id: 'bond-second',
          role: ModelRole.decide,
          displayName: 'Test Second',
          repo: 'artifactory/$secondBundle',
          file: 'bond-second-f16.gguf',
          revision: '',
          sizeBytes: weights.length,
          sha256: sha256Hex(weights),
          minRamBytes: 0,
          license: 'Fictional-1.0',
          licenseUrl: 'https://example.invalid/licence',
          source: sourceArtifactory,
          bundle: secondBundle,
          remoteFile: 'model-f16.gguf',
          heads: ModelHeads(
            file: 'second-heads.json',
            remoteFile: 'heads.json',
            sha256: sha256Hex(head),
            sizeBytes: head.length,
          ),
        );
      });

      tearDown(() => other.close());

      /// The address moves to [other]'s origin after the first entry's
      /// read, the way a Save in Settings mid-run moves it.
      String Function() movingBase() {
        var reads = 0;
        return () => reads++ == 0 ? hub.registryBase : other.registryBase;
      }

      test('a lookup that answers only for the old origin sends the new base '
          'no token at all', () async {
        final decide = publishDecide();
        final asked = <String>[];
        final downloader = build(
          registryBase: movingBase(),
          registryToken: (base) {
            asked.add(base);
            return sameOrigin(base, hub.registryBase) ? _fakeToken : null;
          },
        );

        final events = await downloader.run([decide, second]).toList();

        expect(events.where((e) => e.status == DownloadStatus.done),
            hasLength(2));
        expect(asked, [hub.registryBase, other.registryBase],
            reason: 'each entry asks for the base its legs are sent to');
        expect(hub.registryCount, 2, reason: 'decide, at the old base');
        expect(hub.registryAuth.every((a) => a == 'Bearer $_fakeToken'),
            isTrue);
        expect(other.registryCount, 2, reason: 'the second, at the new base');
        expect(other.registryAuth, everyElement(isNull));
      });

      test('a lookup that answers for the new base sends that token there '
          'and only there', () async {
        const otherToken = 'other-fake-token-789';
        final decide = publishDecide();
        final downloader = build(
          registryBase: movingBase(),
          registryToken: (base) =>
              sameOrigin(base, other.registryBase) ? otherToken : null,
        );

        final events = await downloader.run([decide, second]).toList();

        expect(events.where((e) => e.status == DownloadStatus.done),
            hasLength(2));
        expect(hub.registryAuth, everyElement(isNull));
        expect(other.registryCount, 2);
        expect(other.registryAuth.every((a) => a == 'Bearer $otherToken'),
            isTrue);
      });
    });

    test('a registry answering with a web page fails at once as '
        'registry_not_a_model, spending no retries', () async {
      final decide = publishDecide();
      hub.registryWebPage = true;

      final events = await buildRegistry().run([decide]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.registryNotAModel);
      expect(hub.registryCount, 1);
      expect(sleeps, isEmpty);
      expect(File('${destOf(decide)}.part').existsSync(), isFalse);
    });

    test('weights done and here, heads missing: only the heads are asked for, '
        'on one bar from the weights to the whole', () async {
      final decide = publishDecide();
      await File(destOf(decide)).create(recursive: true);
      await File(destOf(decide))
          .writeAsBytes(hub.registryContents['$bundle/model-f16.gguf']!);
      ledger = DownloadLedger.empty.record(FileDownloadState(
        id: decide.id,
        status: DownloadStatus.done,
        receivedBytes: decide.sizeBytes,
        totalBytes: decide.sizeBytes,
        sha256: decide.sha256,
      ));

      final events = await buildRegistry().run([decide]).toList();

      expect(
        [for (final u in hub.requests) p.basename(u.path)],
        ['heads.json'],
      );
      final afterPending = events.skip(1).toList();
      expect(afterPending.first.receivedBytes, decide.sizeBytes);
      for (final e in afterPending) {
        expect(e.receivedBytes, greaterThanOrEqualTo(decide.sizeBytes));
        expect(e.totalBytes, decide.downloadBytes);
      }
      expect(events.where((e) => e.status == DownloadStatus.done),
          hasLength(1));
      expect(events.last.status, DownloadStatus.done);
      expect(events.last.receivedBytes, decide.downloadBytes);
      expect(ledger.isCurrent(decide), isTrue);
    });

    test('a new heads digest replaces the heads file and leaves the weights '
        'alone', () async {
      final old = publishDecide();
      hub.registryBearer = _fakeToken;
      await buildRegistry().run([old]).toList();
      expect(ledger.isCurrent(old), isTrue);
      hub.requests.clear();

      // The bundle republishes its heads; the GGUF is the same bytes.
      final newHeads = fakeWeights(1600, seed: 23);
      hub.registryContents['$bundle/heads.json'] = newHeads;
      final bumped = testDecideFile(
        sizeBytes: old.sizeBytes,
        sha256: old.sha256,
        headsSizeBytes: newHeads.length,
        headsSha256: sha256Hex(newHeads),
      );
      expect(ledger.isCurrent(bumped), isFalse);

      final events = await buildRegistry().run([bumped]).toList();

      expect(events.last.status, DownloadStatus.done);
      expect(
        [for (final u in hub.requests) p.basename(u.path)],
        ['heads.json'],
      );
      expect(File(headsDestOf(bumped)).readAsBytesSync(), newHeads);
      expect(ledger.isCurrent(bumped), isTrue);
    });

    test('no address with the weights done and the heads missing fails the '
        'heads row and leaves the weights row alone', () async {
      final decide = publishDecide();
      await File(destOf(decide)).create(recursive: true);
      await File(destOf(decide))
          .writeAsBytes(hub.registryContents['$bundle/model-f16.gguf']!);
      final weightsRow = FileDownloadState(
        id: decide.id,
        status: DownloadStatus.done,
        receivedBytes: decide.sizeBytes,
        totalBytes: decide.sizeBytes,
        sha256: decide.sha256,
      );
      ledger = DownloadLedger.empty.record(weightsRow);

      final events =
          await build(registryBase: () => '').run([decide]).toList();

      expect(events.last.status, DownloadStatus.failed);
      expect(events.last.error, DownloadError.registryNotConfigured);
      expect(events.last.receivedBytes, decide.sizeBytes);
      expect(ledger[decide.id], weightsRow);
      final headsRow = ledger[DownloadLedger.headsId(decide.id)];
      expect(headsRow?.status, DownloadStatus.failed);
      expect(headsRow?.error, DownloadError.registryNotConfigured);
      expect(hub.registryCount, 0);
    });
  });
}

/// An obviously fake registry token.
const String _fakeToken = 'test-token-123';
