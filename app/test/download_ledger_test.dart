import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

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
