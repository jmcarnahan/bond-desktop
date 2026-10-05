import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

FileDownloadState state(
  String id, {
  DownloadStatus status = DownloadStatus.done,
  int received = 100,
  int total = 100,
  String sha = 'abc',
  String? error,
}) =>
    FileDownloadState(
      id: id,
      status: status,
      receivedBytes: received,
      totalBytes: total,
      sha256: sha,
      error: error,
      updatedAt: '2026-09-10T12:00:00Z',
    );

void main() {
  late BondDatabase db;
  late SetupStore store;

  setUp(() {
    db = testDb();
    store = SetupStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('SetupStore', () {
    test('a ledger that was never written reads empty', () async {
      expect(await store.downloadLedger(), DownloadLedger.empty);
    });

    test('recordDownload and downloadLedger round-trip', () async {
      final ledger = DownloadLedger.empty
          .record(state('bond-embed'))
          .record(state('bond-bulk',
              status: DownloadStatus.paused, received: 40, total: 400));

      await store.recordDownload(ledger);

      expect(await store.downloadLedger(), ledger);
      expect(await store.get(SetupStore.downloadKey), isNotNull);
    });

    test('a value that is not JSON reads empty rather than throwing',
        () async {
      // A ledger is bookkeeping about files that are still on disk, so an
      // unreadable one must cost a re-verify and never a launch.
      await store.set(SetupStore.downloadKey, 'not json at all');

      expect(await store.downloadLedger(), DownloadLedger.empty);
    });

    test('nothing written names a host, a URL or a CDN token', () async {
      await store.recordDownload(
        DownloadLedger.empty.record(state('bond-embed')),
      );

      final written = await store.get(SetupStore.downloadKey) ?? '';
      expect(written, isNot(contains('http')));
      expect(written, isNot(contains('cdn')));
      expect(written, isNot(contains('127.0.0.1')));
    });
  });

  group('DownloadLedger', () {
    test('record adds and replaces; without removes', () {
      var ledger = DownloadLedger.empty.record(state('a'));
      expect(ledger['a']?.status, DownloadStatus.done);

      ledger = ledger.record(state('a', status: DownloadStatus.failed));
      expect(ledger.files, hasLength(1));
      expect(ledger['a']?.status, DownloadStatus.failed);

      expect(ledger.without('a').files, isEmpty);
      expect(ledger.without('nothing here'), ledger);
    });

    test('isDone and allDone read the statuses', () {
      final ledger = DownloadLedger.empty
          .record(state('a'))
          .record(state('b', status: DownloadStatus.downloading));

      expect(ledger.isDone('a'), isTrue);
      expect(ledger.isDone('b'), isFalse);
      expect(ledger.isDone('c'), isFalse);
      expect(ledger.allDone(['a']), isTrue);
      expect(ledger.allDone(['a', 'b']), isFalse);
      expect(ledger.allDone(const <String>[]), isTrue);
    });

    test('isCurrent wants the digest as well as the word done', () {
      // `isDone` answers what a RUN asks; it cannot answer what a LAUNCH
      // asks. A manifest bump that kept the file name leaves a done row
      // against the previous checkpoint, and an install that trusted it would
      // serve the old weights for ever.
      final manifest = testManifest();
      final embed = manifest.byRole(ModelRole.embed);
      final ledger = DownloadLedger.empty
          .record(state(embed.id, sha: embed.sha256))
          .record(state(
            manifest.byRole(ModelRole.bulk).id,
            sha: 'f' * 64,
          ));

      expect(ledger.isCurrent(embed), isTrue);
      expect(ledger.isCurrent(manifest.byRole(ModelRole.bulk)), isFalse);
      // Done at the right digest, in the ledger's eyes, is still not done
      // when the row says otherwise.
      expect(ledger.isCurrent(manifest.byRole(ModelRole.prose)), isFalse);
      expect(
        DownloadLedger.empty
            .record(state(embed.id,
                status: DownloadStatus.paused, sha: embed.sha256))
            .isCurrent(embed),
        isFalse,
      );
    });

    test('matches wants every file in the manifest at this build\'s digests',
        () {
      final manifest = testManifest();
      var ledger = DownloadLedger.empty;
      for (final model in manifest.models) {
        ledger = ledger.record(state(model.id, sha: model.sha256));
      }

      expect(ledger.matches(manifest), isTrue);
      // One model bumped is the whole set out of date, because the server
      // will not start with a file the preset names missing or wrong.
      final prose = manifest.byRole(ModelRole.prose);
      expect(
        ledger.record(state(prose.id, sha: 'f' * 64)).matches(manifest),
        isFalse,
      );
      expect(ledger.without(prose.id).matches(manifest), isFalse);
      expect(DownloadLedger.empty.matches(manifest), isFalse);
    });

    test('matches never asks for a hand-installed entry', () {
      // A `source: local` decision model is copied in by hand and has no
      // row: a ledger complete for the downloads is complete.
      final manifest = testManifest(decide: testLocalDecideFile());
      var ledger = DownloadLedger.empty;
      for (final model in manifest.models) {
        if (model.isLocal) continue;
        ledger = ledger.record(state(model.id, sha: model.sha256));
      }
      expect(ledger['bond-decide'], isNull);
      expect(ledger.matches(manifest), isTrue);
    });

    test('isCurrent wants the heads row too for a registry entry', () {
      final decide = testDecideFile();
      final headsId = DownloadLedger.headsId(decide.id);
      expect(headsId, 'bond-decide.heads');

      final weightsOnly =
          DownloadLedger.empty.record(state(decide.id, sha: decide.sha256));
      expect(weightsOnly.isCurrent(decide), isFalse);

      final both = weightsOnly.record(state(headsId, sha: decide.heads!.sha256));
      expect(both.isCurrent(decide), isTrue);

      // A heads row from another bundle is not this one's.
      expect(
        weightsOnly.record(state(headsId, sha: 'f' * 63 + '0')).isCurrent(decide),
        isFalse,
      );
      expect(
        weightsOnly
            .record(state(headsId,
                sha: decide.heads!.sha256, status: DownloadStatus.failed))
            .isCurrent(decide),
        isFalse,
      );
    });

    test('a heads record on a non-registry entry asks for no heads row', () {
      // `isRegistry` is the one rule for owning a heads leg: only a registry
      // entry's heads are downloaded, so only theirs can be ledgered. A hub
      // entry built in code with a heads record is current on its own row.
      const hub = ModelFile(
        id: 'bond-embed',
        role: ModelRole.embed,
        displayName: 'Hub with heads',
        repo: 'owner/name',
        file: 'x.gguf',
        revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        sizeBytes: 1,
        sha256: 'abc',
        minRamBytes: 0,
        license: 'Fictional-1.0',
        licenseUrl: 'https://example.invalid/licence',
        heads: ModelHeads(file: 'h.json', sha256: 'def', sizeBytes: 1),
      );
      final ledger = DownloadLedger.empty.record(state(hub.id, sha: 'abc'));
      expect(ledger['bond-embed.heads'], isNull);
      expect(ledger.isCurrent(hub), isTrue);
    });

    test('matches on the gating view ignores the registry entry, and on the '
        'downloadable view does not', () {
      final manifest = testManifest(withDecide: true);
      var ledger = DownloadLedger.empty;
      for (final model in manifest.models) {
        if (model.isRegistry) continue;
        ledger = ledger.record(state(model.id, sha: model.sha256));
      }
      expect(ledger['bond-decide'], isNull);
      expect(ledger.matches(manifest.gating), isTrue);
      expect(ledger.matches(manifest.downloadable), isFalse);
      // A FAILED registry row does not reopen the gate either.
      final failed = ledger.record(state('bond-decide',
          status: DownloadStatus.failed,
          error: DownloadError.unauthorized));
      expect(failed.matches(manifest.gating), isTrue);
    });

    test('the registry errors round-trip through the ledger JSON', () {
      for (final word in [
        DownloadError.registryNotConfigured,
        DownloadError.unauthorized,
      ]) {
        final ledger = DownloadLedger.empty.record(state('bond-decide.heads',
            status: DownloadStatus.failed, error: word));
        final again = DownloadLedger.parse(jsonEncode(ledger.toJson()));
        expect(again, ledger);
        expect(again['bond-decide.heads']?.error, word);
      }
      expect(DownloadError.registryNotConfigured, 'registry_not_configured');
      expect(DownloadError.unauthorized, 'unauthorized');
    });

    test('parse tolerates null, empty and rubbish', () {
      expect(DownloadLedger.parse(null), DownloadLedger.empty);
      expect(DownloadLedger.parse(''), DownloadLedger.empty);
      expect(DownloadLedger.parse('   '), DownloadLedger.empty);
      expect(DownloadLedger.parse('[]'), DownloadLedger.empty);
      expect(DownloadLedger.parse('{"files": 3}'), DownloadLedger.empty);
    });

    test('a status this build does not know reads as pending', () {
      final ledger = DownloadLedger.parse(jsonEncode({
        'version': 1,
        'files': {
          'bond-embed': {
            'id': 'bond-embed',
            'status': 'quarantined',
            'receivedBytes': 12,
            'totalBytes': 40,
            'sha256': 'abc',
          },
        },
      }));

      expect(ledger['bond-embed']?.status, DownloadStatus.pending);
      expect(ledger['bond-embed']?.receivedBytes, 12);
    });

    test('a row that does not repeat its id is keyed by the map key', () {
      final ledger = DownloadLedger.parse(jsonEncode({
        'version': 1,
        'files': {
          'bond-bulk': {
            'status': 'paused',
            'receivedBytes': 12,
            'totalBytes': 40,
            'sha256': 'abc',
          },
        },
      }));

      // The key IS the id, so a row written without one inside itself stays
      // addressable rather than coming back as a nameless state.
      expect(ledger['bond-bulk']?.id, 'bond-bulk');
      expect(ledger['bond-bulk']?.status, DownloadStatus.paused);
      expect(ledger['bond-bulk']?.receivedBytes, 12);
    });

    test('the encoded shape carries its version', () {
      final json = DownloadLedger.empty.record(state('a')).toJson();
      expect(json['version'], 1);
      expect((json['files']! as Map), contains('a'));
    });
  });

  group('FileDownloadState', () {
    test('copyWith can clear an error as well as set one', () {
      final failed = state('a',
          status: DownloadStatus.failed, error: DownloadError.network);
      expect(failed.copyWith(clearError: true).error, isNull);
      expect(failed.copyWith(error: DownloadError.checksum).error,
          DownloadError.checksum);
    });

    test('the error vocabulary spells an HTTP code', () {
      expect(DownloadError.http(404), 'http_404');
    });
  });

  group('DownloadProgress', () {
    test('a done file reads as complete whatever the counts say', () {
      const progress = DownloadProgress(
        id: 'a',
        status: DownloadStatus.done,
        receivedBytes: 99,
        totalBytes: 100,
      );
      expect(progress.fraction, 1);
      expect(progress.isTerminal, isTrue);
    });

    test('an unknown total is 0, not a division by zero', () {
      const progress = DownloadProgress(
        id: 'a',
        status: DownloadStatus.downloading,
        receivedBytes: 5,
        totalBytes: 0,
      );
      expect(progress.fraction, 0);
      expect(progress.isTerminal, isFalse);
    });
  });
}
