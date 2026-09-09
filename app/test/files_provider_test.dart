import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/files_models.dart';
import 'package:bond_inbox/providers/files_provider.dart';
import 'package:bond_inbox/services/message_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';
import 'fixtures/test_db.dart';

/// The Files stop's notifier: a paged shelf, a kind that narrows it in SQL, and
/// a search that never takes the shelf away.
///
/// The rule worth pinning hardest is the sequence guard — a slow first answer
/// landing after a fast second one must write nothing, because the reader has
/// already changed the question.

/// A store whose reads the test drives by hand.
class _SlowStore extends MessageStore {
  final List<Completer<List<FileRow>>> pending = [];
  final List<({FilesKind kind, int offset, List<String> sources})> asked = [];

  /// When set, every read throws instead of waiting on a completer.
  bool fail = false;

  _SlowStore(super.db);

  @override
  Future<List<FileRow>> recentAttachments({
    List<String> sources = const ['email', 'teams'],
    FilesKind kind = FilesKind.all,
    int limit = 100,
    int offset = 0,
  }) {
    asked.add((kind: kind, offset: offset, sources: sources));
    if (fail) return Future.error(StateError('no'));
    final completer = Completer<List<FileRow>>();
    pending.add(completer);
    return completer.future;
  }
}

FileRow _row(String id) => FileRow(
      ref: ref(attachmentId: id, name: '$id.pdf'),
      receivedAt: '2026-09-04T10:00:00.000Z',
      subject: 'The lease',
    );

void main() {
  late BondDatabase db;
  late _SlowStore store;

  setUp(() {
    db = testDb();
    store = _SlowStore(db);
  });

  tearDown(() => db.close());

  FilesNotifier notifier({FilesSearchRunner? searchRunner}) =>
      FilesNotifier(store, searchRunner: searchRunner);

  const sources = ['email', 'teams'];

  group('reading the shelf', () {
    test('a page lands, and a short one says the shelf has ended', () async {
      final files = notifier();
      final load = files.load(sources: sources);
      store.pending.single.complete([_row('a'), _row('b')]);
      await load;

      expect(files.state.rows.length, 2);
      expect(files.state.loaded, isTrue);
      expect(files.state.atEnd, isTrue);
      expect(files.state.error, isNull);
    });

    test('a slow first answer never overwrites a fast second one', () async {
      final files = notifier();
      final first = files.load(sources: sources);
      final second = files.load(sources: sources);

      // The SECOND question is the standing one, so its answer wins whichever
      // order the two land in.
      store.pending[1].complete([_row('new')]);
      await second;
      store.pending[0].complete([_row('old-a'), _row('old-b')]);
      await first;

      expect(files.state.rows.map((r) => r.ref.attachmentId), ['new']);
    });

    test('a failed read keeps the rows and says so', () async {
      final files = notifier();
      final load = files.load(sources: sources);
      store.pending.single.complete([_row('a')]);
      await load;

      store.fail = true;
      await files.load(sources: sources);

      expect(files.state.rows.length, 1);
      expect(
        files.state.error,
        "Couldn't read your files just now — showing what was already here.",
      );
    });
  });

  group('paging', () {
    test('a second page is appended and asked for at the right offset',
        () async {
      final files = notifier();
      final load = files.load(sources: sources);
      // A FULL page, so the shelf is not at its end.
      store.pending.single.complete(
        [for (var i = 0; i < FilesNotifier.pageSize; i++) _row('a$i')],
      );
      await load;
      expect(files.state.atEnd, isFalse);

      final more = files.loadMore(sources: sources);
      expect(store.asked.last.offset, FilesNotifier.pageSize);
      store.pending.last.complete([_row('tail')]);
      await more;

      expect(files.state.rows.length, FilesNotifier.pageSize + 1);
      expect(files.state.rows.last.ref.attachmentId, 'tail');
      // The short page is what ends it — no extra query to find that out.
      expect(files.state.atEnd, isTrue);
      expect(files.state.loadingMore, isFalse);
    });

    test('a shelf already at its end asks for nothing more', () async {
      final files = notifier();
      final load = files.load(sources: sources);
      store.pending.single.complete([_row('a')]);
      await load;

      await files.loadMore(sources: sources);

      expect(store.asked.length, 1);
    });
  });

  group('the kind', () {
    test('setting one re-reads the shelf under it', () async {
      final files = notifier();
      final load = files.load(sources: sources);
      store.pending.single.complete([_row('a')]);
      await load;

      final narrowed = files.setKind(FilesKind.images, sources: sources);
      expect(files.state.kind, FilesKind.images);
      expect(store.asked.last.kind, FilesKind.images);
      store.pending.last.complete([_row('shot')]);
      await narrowed;

      expect(files.state.rows.map((r) => r.ref.attachmentId), ['shot']);
    });
  });

  group('paging against a kind change', () {
    test('a page asked for before the kind changed is not appended to the '
        'shorter list', () async {
      final files = notifier();
      final load = files.load(sources: sources);
      store.pending[0].complete(
        List.generate(FilesNotifier.pageSize, (i) => _row('all-$i')),
      );
      await load;
      expect(files.state.atEnd, isFalse);

      // The kind changes, and before its first page lands the reader taps
      // Load more: that read shares the new sequence number, so only the
      // offset it was asked against can tell it apart.
      final narrowed = files.setKind(FilesKind.documents, sources: sources);
      final more = files.loadMore(sources: sources);
      expect(store.asked.last.offset, FilesNotifier.pageSize);

      store.pending[1].complete([_row('doc-a'), _row('doc-b'), _row('doc-c')]);
      await narrowed;
      store.pending[2].complete([_row('doc-far-1'), _row('doc-far-2')]);
      await more;

      expect(
        files.state.rows.map((r) => r.ref.attachmentId),
        ['doc-a', 'doc-b', 'doc-c'],
      );
      expect(files.state.loadingMore, isFalse);
    });
  });

  group('searching the shelf', () {
    AttachmentChunkHit hit(String id) => AttachmentChunkHit(
          ref: ref(attachmentId: id, name: '$id.pdf'),
          chunkId: 1,
          seq: 0,
          locator: 'page 2',
          text: 'The tenant pays on the fourth.',
          outbound: false,
          distance: 0.2,
        );

    test('a query of nothing but filters is not a question', () async {
      var calls = 0;
      final files = notifier(searchRunner: (query, {sources = const []}) async {
        calls++;
        return const MessageSearchHits('x', []);
      });

      await files.submitSearch('has:file in:email', sources: sources);

      expect(calls, 0);
      expect(
        files.state.searchNotice,
        'Add a word or two to search for — the filters alone are not a '
        'question.',
      );
      expect(files.state.search, isNull);
    });

    test('hits are documents, labelled by the raw query', () async {
      final asked = <String>[];
      final files = notifier(searchRunner: (query, {sources = const []}) async {
        asked.add(query);
        return MessageSearchHits('lease', const [], documents: [hit('a')]);
      });

      await files.submitSearch('lease has:file', sources: sources);

      // The facets came off before the sentence was embedded.
      expect(asked, ['lease']);
      // And the label is what the reader typed, facets and all.
      expect(files.state.searchQuery, 'lease has:file');
      expect(files.state.search!.map((h) => h.ref.attachmentId), ['a']);
      expect(files.state.searching, isFalse);
    });

    test('an in: facet beats the header chips', () async {
      final asked = <List<String>>[];
      final files = notifier(searchRunner: (query, {sources = const []}) async {
        asked.add(sources);
        return const MessageSearchHits('lease', []);
      });

      await files.submitSearch('lease in:teams', sources: sources);

      expect(asked, [
        ['teams'],
      ]);
    });

    test('an index that is down is a notice, not an empty shelf', () async {
      final files = notifier(
        searchRunner: (query, {sources = const []}) async =>
            const MessageSearchUnavailable('the embedding server is not up'),
      );
      final load = files.load(sources: sources);
      store.pending.single.complete([_row('a')]);
      await load;

      await files.submitSearch('lease', sources: sources);

      expect(
        files.state.searchNotice,
        'Search is unavailable — the embedding server is not up',
      );
      expect(files.state.search, isNull);
      expect(files.state.rows.length, 1);
    });

    test('a runner that throws leaves a sentence rather than a spinner',
        () async {
      final files = notifier(
        searchRunner: (query, {sources = const []}) async =>
            throw StateError('database gone'),
      );

      await files.submitSearch('lease', sources: sources);

      expect(files.state.searching, isFalse);
      expect(
        files.state.searchNotice,
        "Search failed — couldn't read the index.",
      );
    });

    test('leaving search drops the results and keeps the shelf', () async {
      final files = notifier(
        searchRunner: (query, {sources = const []}) async =>
            MessageSearchHits('lease', const [], documents: [hit('a')]),
      );
      final load = files.load(sources: sources);
      store.pending.single.complete([_row('a')]);
      await load;
      await files.submitSearch('lease', sources: sources);
      expect(files.state.search, isNotNull);

      files.exitSearch();

      expect(files.state.search, isNull);
      expect(files.state.searchQuery, isNull);
      expect(files.state.rows.length, 1);
    });
  });
}
