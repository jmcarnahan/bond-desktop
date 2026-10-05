import 'dart:async';
import 'dart:io';

import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_downloader.dart';
import 'package:bond_inbox/services/models/model_ensurer.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_hub_server.dart';
import 'fixtures/test_manifest.dart';

const String _fakeToken = 'test-token-123';
const String _bundle = 'bond-decide-mbl-v3swap';

/// The model ensurer: what the placements need and the disk lacks, fetched
/// outside the wizard, and the one ownership rule for the downloader it
/// shares with the wizard.
///
/// Plain `test`s over a loopback hub and registry, a real downloader and a
/// real models folder, for `model_downloader_test.dart`'s reason: a
/// fake-async zone would hang a run rather than fail it. Which entries the
/// ensure SET holds under each placement is the provider's question, and
/// `decision_client_provider_test.dart` answers it (decide is in the set
/// when the decision runs on Your server, D10).
void main() {
  late FakeHubServer hub;
  late Directory root;
  late DownloadLedger ledger;
  late String registryBase;
  late ModelFile embed;
  late ModelFile decide;

  String folder() => p.join(root.path, 'models');
  String destOf(ModelFile file) => p.join(folder(), file.relativePath);
  String headsOf(ModelFile file) =>
      p.join(folder(), file.headsRelativePath!);

  /// Publishes the decide bundle at [gguf] bytes and returns its entry.
  ModelFile publishDecide({int gguf = 6144}) {
    final weights = fakeWeights(gguf, seed: 21);
    final heads = fakeWeights(1536, seed: 22);
    hub.registryContents['$_bundle/model-f16.gguf'] = weights;
    hub.registryContents['$_bundle/heads.json'] = heads;
    return testDecideFile(
      sizeBytes: weights.length,
      sha256: sha256Hex(weights),
      headsSizeBytes: heads.length,
      headsSha256: sha256Hex(heads),
    );
  }

  setUp(() async {
    hub = await FakeHubServer.start();
    root = await Directory.systemTemp.createTemp('model-ensure');
    ledger = DownloadLedger.empty;
    registryBase = hub.registryBase;

    final base = testManifest();
    final embedFile = base.byId(routerEmbedId);
    final data = fakeWeights(4096, seed: 3);
    hub.contents['${embedFile.repo}/${embedFile.file}'] = data;
    embed = testManifest(
      sizes: {routerEmbedId: data.length},
      sha256s: {routerEmbedId: sha256Hex(data)},
    ).byId(routerEmbedId);
    decide = publishDecide();
  });

  tearDown(() async {
    await hub.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  ModelDownloader downloaderFor(List<ModelFile> files) {
    final downloader = ModelDownloader(
      manifest: manifestFor(files),
      modelsFolder: folder,
      registryBase: () => registryBase,
      registryToken: (_) => _fakeToken,
      readLedger: () async => ledger,
      writeLedger: (updated) async => ledger = updated,
      // Null sends every verify to the Dart digest, as under `flutter test`.
      sha256: (_) async => null,
      resolveUri: hub.resolveUriFor,
      sleep: (_) async {},
      progressInterval: const Duration(milliseconds: 1),
      ledgerInterval: Duration.zero,
    );
    addTearDown(downloader.dispose);
    return downloader;
  }

  /// What the ensurer told the supervisor after each pass: the ids landed.
  late List<Set<String>> nudges;

  ModelEnsurer ensurerFor(
    ModelDownloader downloader,
    List<ModelFile> wanted, {
    bool Function()? blocked,
    Future<void> Function()? beforeRun,
  }) {
    nudges = [];
    final ensurer = ModelEnsurer(
      downloader: () => downloader,
      wanted: () async => manifestFor(wanted),
      modelsFolder: folder,
      readLedger: () async => ledger,
      beforeRun: beforeRun ?? () async {},
      afterRun: (landed) async => nudges.add(landed),
      blocked: blocked,
    );
    addTearDown(ensurer.dispose);
    return ensurer;
  }

  /// Polls until [ready], or gives up loudly.
  Future<void> waitUntil(bool Function() ready, {String reason = ''}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  test('downloads what is missing, and tells the server which ids landed',
      () async {
    final downloader = downloaderFor([embed, decide]);
    final ensurer = ensurerFor(downloader, [embed, decide]);

    final result = await ensurer.ensure();

    expect(result.phase, EnsurePhase.done);
    expect(ensurer.state.value, result);
    expect(File(destOf(embed)).existsSync(), isTrue);
    expect(File(destOf(decide)).existsSync(), isTrue);
    expect(File(headsOf(decide)).existsSync(), isTrue);
    expect(ledger.isCurrent(embed), isTrue);
    expect(ledger.isCurrent(decide), isTrue);
    expect(result.landedIds, {routerEmbedId, routerDecideId});
    expect(nudges, [
      {routerEmbedId, routerDecideId},
    ]);
  });

  test('a pass that finds nothing missing starts no run and still nudges the '
      'server, with nothing landed', () async {
    final downloader = downloaderFor([embed, decide]);
    final ensurer = ensurerFor(downloader, [embed, decide]);
    await ensurer.ensure();
    final asked = hub.requests.length;
    final registryAsked = hub.registryCount;

    final again = await ensurer.ensure();

    expect(again.phase, EnsurePhase.done);
    expect(hub.requests.length, asked);
    expect(hub.registryCount, registryAsked);
    // The pass that found nothing is what picks up a file somebody else's
    // run landed: the supervisor is asked for the preset either way.
    expect(nudges, [
      {routerEmbedId, routerDecideId},
      <String>{},
    ]);
  });

  test('a file deleted under a current ledger row is fetched again', () async {
    final downloader = downloaderFor([embed, decide]);
    final ensurer = ensurerFor(downloader, [embed, decide]);
    await ensurer.ensure();
    await File(headsOf(decide)).delete();

    final again = await ensurer.ensure();

    expect(again.phase, EnsurePhase.done);
    expect(File(headsOf(decide)).existsSync(), isTrue);
  });

  test('starts nothing while the wizard owns the downloader', () async {
    var asked = false;
    final downloader = downloaderFor([embed]);
    final ensurer = ensurerFor(
      downloader,
      [embed],
      blocked: () => true,
      beforeRun: () async => asked = true,
    );

    final result = await ensurer.ensure();

    expect(result.phase, EnsurePhase.idle);
    expect(hub.requests, isEmpty);
    expect(asked, isFalse);
    expect(nudges, isEmpty);
  });

  test('a wizard that opens while the preferences load still stops the run',
      () async {
    var wizard = false;
    final downloader = downloaderFor([embed]);
    final ensurer = ensurerFor(
      downloader,
      [embed],
      blocked: () => wizard,
      beforeRun: () async => wizard = true,
    );

    final result = await ensurer.ensure();

    expect(result.phase, EnsurePhase.idle);
    expect(hub.requests, isEmpty);
    expect(downloader.running, isFalse);
  });

  test('another owner\'s run is waited for, said as waiting, and its file is '
      'not fetched a second time', () async {
    hub.chunkDelay = const Duration(milliseconds: 5);
    final downloader = downloaderFor([embed]);
    final ensurer = ensurerFor(downloader, [embed]);
    // The wizard's run, still going after it was left.
    final other = downloader.run([embed]).toList();
    expect(downloader.running, isTrue);

    final pass = ensurer.ensure();
    await Future<void>.delayed(Duration.zero);

    expect(ensurer.state.value.phase, EnsurePhase.downloading);
    expect(ensurer.state.value.waiting, isTrue);
    expect(ensurer.state.value.fraction, isNull);

    hub.chunkDelay = null;
    await other;
    final result = await pass;

    expect(result.phase, EnsurePhase.done);
    expect(result.waiting, isFalse);
    expect(
      hub.requests.where((u) => u.path.endsWith(embed.file)).length,
      lessThanOrEqualTo(2),
      reason: 'one resolve and one fetch, the other run\'s, and no second run',
    );
    expect(nudges, [<String>{}], reason: 'a pass, with nothing of its own');
  });

  group('single-flight, coalescing forward', () {
    /// Held at `beforeRun`, i.e. AFTER the pass has scanned: the next pass
    /// that reaches it waits until the test completes it.
    Completer<void>? hold;
    Future<void> holding() async {
      final gate = hold;
      hold = null;
      if (gate != null) await gate.future;
    }

    test('two calls during a pass give exactly two passes', () async {
      final downloader = downloaderFor([embed]);
      final ensurer = ensurerFor(downloader, [embed], beforeRun: holding);
      final gate = hold = Completer<void>();

      final first = ensurer.ensure();
      final second = ensurer.ensure();

      expect(identical(first, second), isFalse);
      gate.complete();
      expect((await first).phase, EnsurePhase.done);
      expect((await second).phase, EnsurePhase.done);
      expect(nudges, [
        {routerEmbedId},
        <String>{},
      ], reason: 'the pass, then one further pass that found nothing');
    });

    test('three calls during one pass still give exactly two', () async {
      final downloader = downloaderFor([embed]);
      final ensurer = ensurerFor(downloader, [embed], beforeRun: holding);
      final gate = hold = Completer<void>();

      final first = ensurer.ensure();
      final second = ensurer.ensure();
      final third = ensurer.ensure();

      expect(identical(second, third), isTrue,
          reason: 'every call during the pass shares the one further pass');
      gate.complete();
      await first;
      await third;
      expect(nudges, hasLength(2));
    });

    test('a reverify asked during a pass is done by the further pass',
        () async {
      final wanted = [decide];
      final downloader = downloaderFor([embed, decide]);
      final ensurer = ensurerFor(downloader, wanted, beforeRun: holding);
      await ensurer.ensure();
      expect(ledger.isCurrent(decide), isTrue);

      // A pass for the embedding model, held after its scan.
      wanted.add(embed);
      final gate = hold = Completer<void>();
      final first = ensurer.ensure();
      await File(headsOf(decide)).writeAsBytes(List<int>.filled(1536, 9));
      final again = ensurer.ensure(reverify: {routerDecideId});
      gate.complete();
      await first;
      final result = await again;

      expect(result.phase, EnsurePhase.done);
      expect(File(headsOf(decide)).readAsBytesSync(),
          hub.registryContents['$_bundle/heads.json'],
          reason: 'the further pass hashed decide again and replaced it');
    });

    test('a wanted entry added during a pass is downloaded by the further '
        'pass with no other press', () async {
      final wanted = [embed];
      final downloader = downloaderFor([embed, decide]);
      final ensurer = ensurerFor(downloader, wanted, beforeRun: holding);
      final gate = hold = Completer<void>();

      final first = ensurer.ensure();
      // A placement moved while the pass was already under way.
      wanted.add(decide);
      final again = ensurer.ensure();
      gate.complete();
      await first;
      final result = await again;

      expect(result.phase, EnsurePhase.done);
      expect(File(destOf(decide)).existsSync(), isTrue);
      expect(ledger.isCurrent(decide), isTrue);
      expect(nudges, [
        {routerEmbedId},
        {routerDecideId},
      ]);
    });

    test('standDown between passes skips the further pass, and its future '
        'still completes', () async {
      final downloader = downloaderFor([embed]);
      final ensurer = ensurerFor(downloader, [embed], beforeRun: holding);
      final gate = hold = Completer<void>();

      final first = ensurer.ensure();
      final again = ensurer.ensure();
      await ensurer.standDown();
      gate.complete();
      await first;
      await again.timeout(const Duration(seconds: 10));

      expect(nudges, hasLength(1), reason: 'no further pass ran');
    });

    test('a call while the pass still waits for another owner joins that '
        'pass', () async {
      hub.chunkDelay = const Duration(milliseconds: 5);
      final downloader = downloaderFor([embed]);
      final ensurer = ensurerFor(downloader, [embed]);
      final other = downloader.run([embed]).toList();

      final first = ensurer.ensure();
      final second = ensurer.ensure();

      expect(identical(first, second), isTrue);
      hub.chunkDelay = null;
      await other;
      await first;
      expect(nudges, hasLength(1));
    });
  });

  test('another owner\'s PAUSED run is cancelled rather than waited for, and '
      'the pass downloads the file itself', () async {
    decide = publishDecide(gguf: 512 * 1024);
    // Held after its first chunk until released, so the pause lands
    // mid-transfer whatever the machine's load.
    final held = hub.hold = Completer<void>();
    addTearDown(() => held.isCompleted ? null : held.complete());
    final downloader = downloaderFor([decide]);
    final ensurer = ensurerFor(downloader, [decide]);
    // The wizard's run, paused and then left behind.
    final other = downloader.run([decide]).toList();
    final part = '${destOf(decide)}${ModelDownloader.partSuffix}';
    await waitUntil(
      () => File(part).existsSync() && File(part).lengthSync() > 0,
      reason: 'bytes to land',
    );
    await downloader.pause();
    expect(downloader.paused, isTrue);
    held.complete();

    final result =
        await ensurer.ensure().timeout(const Duration(seconds: 10));
    await other;

    expect(result.phase, EnsurePhase.done);
    expect(result.landedIds, {routerDecideId});
    expect(ledger.isCurrent(decide), isTrue);
    expect(downloader.running, isFalse);
  });

  test('a downloader lookup that throws costs no unhandled error: ensure and '
      'standDown both complete', () async {
    final ensurer = ModelEnsurer(
      downloader: () => throw StateError('the container is gone'),
      wanted: () async => manifestFor([embed]),
      modelsFolder: folder,
      readLedger: () async => ledger,
      beforeRun: () async {},
      afterRun: (_) async {},
    );
    addTearDown(ensurer.dispose);

    final result =
        await ensurer.ensure().timeout(const Duration(seconds: 10));
    expect(result.phase, EnsurePhase.idle);
    await ensurer.standDown().timeout(const Duration(seconds: 10));
  });

  test('standDown completes when the lookup throws while its own run is in '
      'flight', () async {
    decide = publishDecide(gguf: 512 * 1024);
    hub.chunkDelay = const Duration(milliseconds: 5);
    final downloader = downloaderFor([decide]);
    var broken = false;
    final ensurer = ModelEnsurer(
      downloader: () =>
          broken ? throw StateError('the container is gone') : downloader,
      wanted: () async => manifestFor([decide]),
      modelsFolder: folder,
      readLedger: () async => ledger,
      beforeRun: () async {},
      afterRun: (_) async {},
    );
    addTearDown(ensurer.dispose);
    final pass = ensurer.ensure();
    await waitUntil(() => ensurer.state.value.phase == EnsurePhase.downloading,
        reason: 'the run to start');

    broken = true;
    await ensurer.standDown().timeout(const Duration(seconds: 10));

    broken = false;
    hub.chunkDelay = null;
    expect((await pass).phase, EnsurePhase.done,
        reason: 'nothing was cancelled, so the run finished');
  });

  test('waits for the preferences before the run asks for anything',
      () async {
    final ready = Completer<void>();
    final downloader = downloaderFor([decide]);
    final ensurer =
        ensurerFor(downloader, [decide], beforeRun: () => ready.future);

    final run = ensurer.ensure();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hub.registryCount, 0);
    expect(downloader.running, isFalse);

    ready.complete();
    expect((await run).phase, EnsurePhase.done);
    expect(hub.registryAuth, everyElement('Bearer $_fakeToken'));
  });

  test('a beforeRun that throws still runs, and an afterRun that throws '
      'never leaves the state downloading', () async {
    final downloader = downloaderFor([embed]);
    final ensurer = ModelEnsurer(
      downloader: () => downloader,
      wanted: () async => manifestFor([embed]),
      modelsFolder: folder,
      readLedger: () async => ledger,
      beforeRun: () async => throw StateError('prefs did not load'),
      afterRun: (_) async => throw StateError('no server'),
    );
    addTearDown(ensurer.dispose);

    final result = await ensurer.ensure();

    expect(result.phase, EnsurePhase.done);
    expect(ensurer.state.value.phase, EnsurePhase.done);
  });

  test('a failure says which entry and why, and a later ensure retries and '
      'succeeds', () async {
    registryBase = '';
    final downloader = downloaderFor([decide]);
    final ensurer = ensurerFor(downloader, [decide]);

    final failed = await ensurer.ensure();

    expect(failed.phase, EnsurePhase.failed);
    expect(failed.modelId, routerDecideId);
    expect(failed.error, DownloadError.registryNotConfigured);
    expect(failed.errorFor(routerDecideId),
        DownloadError.registryNotConfigured);
    expect(failed.failedIds, {routerDecideId});
    expect(nudges, [<String>{}]);

    registryBase = hub.registryBase;
    final retried = await ensurer.ensure();

    expect(retried.phase, EnsurePhase.done);
    expect(retried.failedIds, isEmpty);
    expect(File(destOf(decide)).existsSync(), isTrue);
    expect(nudges, [
      <String>{},
      {routerDecideId},
    ]);
  });

  test('each failed entry keeps its own reason', () async {
    hub.registryBearer = 'another-fake-token';
    hub.contents.clear();
    final downloader = downloaderFor([embed, decide]);
    final ensurer = ensurerFor(downloader, [embed, decide]);

    final failed = await ensurer.ensure();

    expect(failed.phase, EnsurePhase.failed);
    expect(failed.failedIds, {routerEmbedId, routerDecideId});
    expect(failed.errorFor(routerDecideId), DownloadError.unauthorized);
    expect(failed.errorFor(routerEmbedId), isNot(DownloadError.unauthorized));
  });

  test('the fraction only grows and ends at one; each entry has its own, and '
      'is said landed as soon as it is', () async {
    hub.chunkDelay = const Duration(milliseconds: 1);
    final downloader = downloaderFor([embed, decide]);
    final ensurer = ensurerFor(downloader, [embed, decide]);
    final fractions = <double>[];
    final states = <EnsureState>[];
    void listen() {
      final state = ensurer.state.value;
      states.add(state);
      if (state.phase == EnsurePhase.downloading) {
        fractions.add(state.fraction!);
      }
    }

    ensurer.state.addListener(listen);
    addTearDown(() => ensurer.state.removeListener(listen));

    final result = await ensurer.ensure();

    expect(result.phase, EnsurePhase.done);
    expect(result.fraction, 1);
    expect(fractions, isNotEmpty);
    for (var i = 1; i < fractions.length; i++) {
      expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
    }
    expect(fractions.last, 1);
    expect(fractions.first, lessThan(1));
    // The smallest entry first, the downloader's own order.
    expect(states.first.modelId, routerEmbedId);
    // While decide was still coming, embed already read as landed and whole.
    final midway = states.firstWhere((s) =>
        s.phase == EnsurePhase.downloading &&
        s.landedIds.contains(routerEmbedId) &&
        !s.landedIds.contains(routerDecideId));
    expect(midway.fractionFor(routerEmbedId), 1);
    expect(midway.fractionFor(routerDecideId), lessThan(1));
  });

  test('dispose mid-run throws nothing and leaves the state alone', () async {
    decide = publishDecide(gguf: 512 * 1024);
    hub.chunkDelay = const Duration(milliseconds: 5);
    final downloader = downloaderFor([decide]);
    nudges = [];
    final ensurer = ModelEnsurer(
      downloader: () => downloader,
      wanted: () async => manifestFor([decide]),
      modelsFolder: folder,
      readLedger: () async => ledger,
      beforeRun: () async {},
      afterRun: (landed) async => nudges.add(landed),
    );
    final pass = ensurer.ensure();
    await waitUntil(() => ensurer.state.value.phase == EnsurePhase.downloading,
        reason: 'the run to start');
    final last = ensurer.state.value;

    ensurer.dispose();
    hub.chunkDelay = null;

    final result = await pass;
    expect(result, last);
    expect(nudges, isEmpty);
  });

  test('standDown cancels its own run, keeping the part, and the next run '
      'resumes from the byte', () async {
    decide = publishDecide(gguf: 512 * 1024);
    hub.chunkDelay = const Duration(milliseconds: 5);
    final downloader = downloaderFor([decide]);
    final ensurer = ensurerFor(downloader, [decide]);
    final pass = ensurer.ensure();
    final part = '${destOf(decide)}${ModelDownloader.partSuffix}';
    await waitUntil(
      () => File(part).existsSync() && File(part).lengthSync() > 0,
      reason: 'bytes to land',
    );

    await ensurer.standDown();

    expect(downloader.running, isFalse);
    final stood = await pass;
    expect(stood.phase, EnsurePhase.idle, reason: 'neither failed nor done');
    expect(File(part).existsSync(), isTrue, reason: 'the part is kept');
    final kept = File(part).lengthSync();
    expect(kept, greaterThan(0));

    // The wizard's run, after the hand-over.
    hub.chunkDelay = null;
    final ranges = hub.registryRanges.length;
    final events = await downloader.run([decide]).toList();

    expect(events.last.status, DownloadStatus.done);
    expect(
      hub.registryRanges.skip(ranges).first,
      startsWith('bytes='),
      reason: 'resumed with a Range, not fetched from zero',
    );
    expect(hub.registryRanges.skip(ranges).first, isNot('bytes=0-'));
    expect(ledger.isCurrent(decide), isTrue);
  });

  test('standDown is nothing when the run in flight is not its own', () async {
    hub.chunkDelay = const Duration(milliseconds: 2);
    final downloader = downloaderFor([embed]);
    final ensurer = ensurerFor(downloader, [embed]);
    final other = downloader.run([embed]).toList();

    await ensurer.standDown();

    expect(downloader.running, isTrue);
    hub.chunkDelay = null;
    expect((await other).last.status, DownloadStatus.done);
  });

  group('reverify', () {
    test('a good file is hashed and kept, with no byte fetched again',
        () async {
      final downloader = downloaderFor([decide]);
      final ensurer = ensurerFor(downloader, [decide]);
      await ensurer.ensure();
      final asked = hub.registryCount;

      final again = await ensurer.ensure(reverify: {routerDecideId});

      expect(again.phase, EnsurePhase.done);
      expect(hub.registryCount, asked, reason: 'nothing downloaded');
      expect(ledger.isCurrent(decide), isTrue);
    });

    test('a damaged heads file is replaced', () async {
      final downloader = downloaderFor([decide]);
      final ensurer = ensurerFor(downloader, [decide]);
      await ensurer.ensure();
      final asked = hub.registryCount;
      await File(headsOf(decide)).writeAsBytes(List<int>.filled(1536, 9));

      // The ledger still says current: only a reverify looks.
      expect((await ensurer.ensure()).landedIds, isEmpty);
      final again = await ensurer.ensure(reverify: {routerDecideId});

      expect(again.phase, EnsurePhase.done);
      expect(File(headsOf(decide)).readAsBytesSync(),
          hub.registryContents['$_bundle/heads.json']);
      expect(hub.registryCount, greaterThan(asked));
      expect(File(destOf(decide)).readAsBytesSync(),
          hub.registryContents['$_bundle/model-f16.gguf'],
          reason: 'the good weights were kept');
    });
  });

  group('a registry entry is servable only once a pass has recorded it', () {
    Future<void> place(ModelFile file, String key, String relative) async {
      final out = File(p.join(folder(), relative));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(hub.registryContents['$_bundle/$key']!);
    }

    test('files placed by hand with the right digests and no rows (make '
        'decide-fetch) are adopted by one pass with no byte fetched', () async {
      await place(decide, 'model-f16.gguf', decide.relativePath);
      await place(decide, 'heads.json', decide.headsRelativePath!);
      expect(ledger.servable(decide, folder()), isFalse,
          reason: 'not served before a pass has hashed them');

      final downloader = downloaderFor([decide]);
      final ensurer = ensurerFor(downloader, [decide]);
      final result = await ensurer.ensure();

      expect(result.phase, EnsurePhase.done);
      expect(hub.registryCount, 0, reason: 'hashed in place');
      expect(ledger.servable(decide, folder()), isTrue);
      expect(nudges, hasLength(1),
          reason: 'afterRun asks for the preset, which now serves it');
    });

    test('a quit between the GGUF leg and the heads leg after a digest change '
        'is not served, and the next pass replaces the old heads', () async {
      // The NEW GGUF landed; the OLD heads are still on disk with their row.
      await place(decide, 'model-f16.gguf', decide.relativePath);
      final old = fakeWeights(1536, seed: 99);
      final heads = File(headsOf(decide));
      await heads.parent.create(recursive: true);
      await heads.writeAsBytes(old);
      ledger = DownloadLedger.empty
          .record(FileDownloadState(
            id: decide.id,
            status: DownloadStatus.done,
            sha256: decide.sha256,
          ))
          .record(FileDownloadState(
            id: DownloadLedger.headsId(decide.id),
            status: DownloadStatus.done,
            sha256: sha256Hex(old),
          ));
      expect(ledger.servable(decide, folder()), isFalse);

      final downloader = downloaderFor([decide]);
      final result = await ensurerFor(downloader, [decide]).ensure();

      expect(result.phase, EnsurePhase.done);
      expect(heads.readAsBytesSync(), hub.registryContents['$_bundle/heads.json']);
      expect(ledger.servable(decide, folder()), isTrue);
    });

    test('a Download again that fails leaves the entry unserved, the good '
        'GGUF kept', () async {
      final downloader = downloaderFor([decide]);
      final ensurer = ensurerFor(downloader, [decide]);
      await ensurer.ensure();
      expect(ledger.servable(decide, folder()), isTrue);
      await File(headsOf(decide)).writeAsBytes(List<int>.filled(1536, 9));

      // The registry refuses the token: the replacement never arrives.
      hub.registryBearer = 'another-fake-token';
      final failed = await ensurer.ensure(reverify: {routerDecideId});

      expect(failed.phase, EnsurePhase.failed);
      expect(ledger.servable(decide, folder()), isFalse);
      expect(ledger[decide.id]?.status, DownloadStatus.done,
          reason: 'the GGUF hashed good and is current on its own row');
      expect(File(destOf(decide)).existsSync(), isTrue);
    });
  });
}
