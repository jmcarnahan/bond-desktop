import 'dart:io';
import 'dart:typed_data';

import 'package:bond_inbox/services/attachments/attachment_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// The disk half of attachments: one file per set of bytes, oldest out first.
///
/// Two properties carry the whole design and both are easy to lose in a
/// refactor. **The path is the content**, so the same quote forwarded three
/// times is one file rather than three; and **the extension survives**, because
/// macOS decides what a file is by its name and a bare hash opens a PDF in a
/// text editor.
void main() {
  late Directory root;
  late AttachmentCache cache;

  Uint8List bytes(String text) => Uint8List.fromList(text.codeUnits);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bond-attachments-test');
    cache = AttachmentCache(() async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the same bytes land on the same path and cost one file', () async {
    final first = await cache.put(bytes('the quote'), name: 'Quote.pdf');
    final second = await cache.put(bytes('the quote'), name: 'Copy.pdf');

    expect(second.path, first.path);
    expect(second.sha256, first.sha256);

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(files.length, 1, reason: 'content-addressed means one file');
  });

  test('the file keeps the name\'s extension, and refuses a strange one',
      () async {
    final pdf = await cache.put(bytes('a'), name: 'Terms.PDF');
    expect(pdf.path, endsWith('.pdf'), reason: 'lower-cased, and kept');

    // Not an extension: a path segment built from this would be a way out of
    // the cache directory.
    final odd = await cache.put(bytes('b'), name: 'Terms.../etc');
    expect(odd.path.split(Platform.pathSeparator).last, odd.sha256);
  });

  test('a file two levels down is found by its digest', () async {
    final stored = await cache.put(bytes('hello'), name: 'note.txt');

    expect(
      stored.path,
      contains(
        '${Platform.pathSeparator}${stored.sha256.substring(0, 2)}'
        '${Platform.pathSeparator}',
      ),
    );
    expect(await cache.read(stored.path), bytes('hello'));
  });

  test('a missing file reads as null rather than throwing', () async {
    expect(await cache.read('${root.path}/00/nothing-here'), isNull);
    expect(await cache.read(''), isNull);
  });

  test('a thumbnail sits beside its blob and is overwritten, not skipped',
      () async {
    final stored = await cache.put(bytes('picture'), name: 'shot.png');

    final first = await cache.putThumbnail(stored.sha256, bytes('small-1'));
    final second = await cache.putThumbnail(stored.sha256, bytes('small-2'));

    expect(second, first);
    expect(await cache.read(second), bytes('small-2'));
  });

  test('the sweep evicts oldest first and never the file just written',
      () async {
    // A cache smaller than what is being put in it: without the `keep`, the
    // newest file would be deleted and re-fetched forever.
    final small = AttachmentCache(() async => root, maxBytes: 20);

    final oldest = await small.put(bytes('0123456789'), name: 'a.txt');
    await File(oldest.path).setLastModified(DateTime(2020));
    final middle = await small.put(bytes('abcdefghij'), name: 'b.txt');
    await File(middle.path).setLastModified(DateTime(2021));

    // Twenty bytes are already in; this third write puts it over.
    final newest = await small.put(bytes('ABCDEFGHIJ'), name: 'c.txt');

    expect(await small.read(newest.path), isNotNull,
        reason: 'the file the caller is about to show is never the one evicted');
    expect(await small.read(oldest.path), isNull);
    expect(await small.sizeBytes(), lessThanOrEqualTo(20));
  });

  test('a sweep of a cache that fits evicts nothing', () async {
    await cache.put(bytes('small'), name: 'a.txt');

    expect(await cache.sweep(), 0);
  });

  test('size is the sum of the tree, thumbnails included', () async {
    final stored = await cache.put(bytes('12345'), name: 'a.txt');
    await cache.putThumbnail(stored.sha256, bytes('123'));

    expect(await cache.sizeBytes(), 8);
  });

  test('clearing empties the tree and leaves a root to write into', () async {
    final stored = await cache.put(bytes('gone soon'), name: 'a.txt');

    await cache.clear();

    expect(await root.exists(), isTrue);
    expect(root.listSync(recursive: true), isEmpty);
    expect(await cache.read(stored.path), isNull);

    // The point of leaving the root: the very next write must not fail.
    final again = await cache.put(bytes('back'), name: 'b.txt');
    expect(await cache.read(again.path), bytes('back'));
  });

  test('the digest is the ordinary sha-256 of the bytes', () async {
    // Pinned against a known value so a swapped hash function is a failing
    // test rather than a cache that quietly stops de-duplicating.
    expect(
      AttachmentCache.hashOf(Uint8List.fromList('abc'.codeUnits)),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
}
