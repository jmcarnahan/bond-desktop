import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

// `show BondDatabase`: drift generates row classes whose names collide with the
// app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_bytes.dart';
import 'package:bond_inbox/services/attachments/attachment_cache.dart';
import 'package:bond_inbox/services/backend/attachment_backend.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';
import 'fixtures/fake_attachment_backend.dart';
import 'fixtures/png_fixture.dart';
import 'fixtures/test_db.dart';

/// The ladder between a chip and a file: cache, row, connector, cache.
///
/// Every test here is about how many times the connector was asked. That is the
/// only thing this class exists to control — a thread where the same logo
/// appears in forty messages must cost one download, an evicted file must cost
/// exactly one more, and a file the policy already refuses must cost none.
///
/// The second subject is the Teams rule: every fetch traces to a user action.
/// Nothing in these tests starts a timer, and nothing in the class under test
/// offers one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BondDatabase db;
  late MessageStore store;
  late FakeAttachmentBackend backend;
  late AttachmentCache cache;
  late Directory root;
  late StoreAttachmentBytes bytes;

  Uint8List payload(String text) => Uint8List.fromList(text.codeUnits);

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    backend = FakeAttachmentBackend();
    root = await Directory.systemTemp.createTemp('bond-bytes-test');
    cache = AttachmentCache(() async => root);
    bytes = StoreAttachmentBytes(
      store: store,
      backend: backend,
      cache: cache,
    );
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> seed(AttachmentRef attachment) async {
    await store.upsertMessage({
      'source': attachment.source,
      'source_message_id': attachment.messageId,
      'conversation_key': attachment.conversationKey ?? 'conv-1',
      'direction': 'inbound',
      'subject': 'A message',
      'received_at': '2026-09-04T10:00:00.000Z',
      'is_read': 0,
      'triage_status': 'triaged',
    });
    await store.upsertAttachments(attachment.source, attachment.messageId, [
      {
        'attachment_id': attachment.attachmentId,
        'ordinal': attachment.ordinal,
        'kind': attachment.kind,
        'name': attachment.name,
        'content_type': attachment.contentType,
        'size': attachment.size,
        'is_inline': attachment.isInline,
        'source_url': attachment.sourceUrl,
      },
    ]);
  }

  group('fetching a file', () {
    test('a first read fetches and a second read costs nothing', () async {
      final attachment = ref();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('the contract');

      expect(await bytes.bytesFor(attachment), payload('the contract'));
      expect(await bytes.bytesFor(attachment), payload('the contract'));

      expect(backend.fetchCalls, 1);
    });

    test('the row remembers where the bytes went', () async {
      final attachment = ref();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('the contract');

      final path = await bytes.pathFor(attachment);

      final row = await store.attachmentRow('email', 'm1', 'a1');
      expect(row!['blob_path'], path);
      expect(row['blob_sha256'], isNotEmpty);
      expect(row['blob_fetched_at'], isNotNull);
      expect(path, endsWith('.pdf'), reason: 'macOS opens files by extension');
    });

    test('two readers asking at once fetch once', () async {
      final attachment = ref();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('one download');

      final results = await Future.wait([
        bytes.bytesFor(attachment),
        bytes.bytesFor(attachment),
        bytes.pathFor(attachment),
      ]);

      expect(backend.fetchCalls, 1);
      expect(results[0], payload('one download'));
    });

    test('an evicted file is fetched again', () async {
      final attachment = ref();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('gone from disk');

      final path = await bytes.pathFor(attachment);
      await File(path).delete();

      expect(await bytes.bytesFor(attachment), payload('gone from disk'));
      expect(backend.fetchCalls, 2);
    });

    test('an attachment past the preview cap is never fetched', () async {
      final attachment = ref(size: attachmentTooLargeBytes + 1);
      await seed(attachment);

      await expectLater(
        bytes.bytesFor(attachment),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'too_large'),
        ),
      );
      expect(backend.fetchCalls, 0);
    });

    test("the cap is the connector's, not the app's", () async {
      // Twelve megabytes: over what the MCP server will put in one JSON reply,
      // under what the streaming SDK path will hand over. One constant here
      // would either refuse a file Graph can fetch or send the server a request
      // it answers with an error.
      final attachment = ref(size: 12 * 1024 * 1024);
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('a large scan');

      backend.maxPreviewBytes = 25 * 1024 * 1024;
      expect(bytes.maxPreviewBytes, 25 * 1024 * 1024);
      expect(await bytes.bytesFor(attachment), payload('a large scan'));

      backend.maxPreviewBytes = attachmentTooLargeBytes;
      await File(await bytes.pathFor(attachment)).delete();
      await store.setAttachmentBlob(
        attachment.source,
        attachment.messageId,
        attachment.attachmentId,
      );
      await expectLater(
        bytes.bytesFor(ref(size: 12 * 1024 * 1024)),
        throwsA(
          isA<AttachmentUnavailable>()
              .having((e) => e.reason, 'reason', 'too_large'),
        ),
      );
    });

    test('a pointer at something that is not a file is refused without a fetch',
        () async {
      for (final kind in ['card', 'message_reference', 'other']) {
        final attachment = ref(
          kind: kind,
          attachmentId: 'a-$kind',
          sourceUrl: 'https://example.invalid/x',
        );
        await seed(attachment);

        await expectLater(
          bytes.bytesFor(attachment),
          throwsA(
            isA<AttachmentUnavailable>()
                .having((e) => e.reason, 'reason', 'link'),
          ),
          reason: kind,
        );
      }
      expect(backend.fetchCalls, 0);
    });

    test('a link to a file is fetched by its url and cached', () async {
      // A mail link IS a file — it just lives on a drive — so it goes down the
      // same ladder as everything else, cache included.
      final attachment = ref(
        kind: 'reference',
        name: 'HARBORLIGHT TALENT AGREEMENT.pdf',
        size: 0,
        sourceUrl: 'https://example.invalid/:b:/g/personal/x/abc',
      );
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('the agency letter');

      expect(await bytes.bytesFor(attachment), payload('the agency letter'));
      expect(backend.fetchCalls, 1);

      expect(await bytes.bytesFor(attachment), payload('the agency letter'));
      expect(backend.fetchCalls, 1, reason: 'the second read is the cache');
    });

    test('a failure is not remembered — the next click tries again', () async {
      final attachment = ref();
      await seed(attachment);
      backend.throwOnFetch = const GraphMailException('the socket dropped');

      await expectLater(bytes.bytesFor(attachment), throwsA(isA<Exception>()));
      backend.throwOnFetch = null;
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('second time');

      expect(await bytes.bytesFor(attachment), payload('second time'));
      expect(backend.fetchCalls, 2);
    });
  });

  group('thumbnails', () {
    test('a picture already small enough is its own thumbnail', () async {
      final attachment = imageRef();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          Uint8List.fromList(onePixelPng);

      final thumb = await bytes.thumbnailFor(attachment);

      expect(thumb, Uint8List.fromList(onePixelPng),
          reason: 'never upscaled, never re-encoded');
      final row = await store.attachmentRow('email', 'm1', 'i1');
      expect(row!['thumb_path'], isNotNull);
    });

    test('a wide picture comes back 320 across', () async {
      final attachment = imageRef();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          await pngOfSize(900, 300);

      final thumb = await bytes.thumbnailFor(attachment);

      expect(await _widthOf(thumb!), 320);
    });

    test('a second render of the same picture reads the cached thumbnail',
        () async {
      final attachment = imageRef();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          Uint8List.fromList(onePixelPng);

      await bytes.thumbnailFor(attachment);
      await bytes.thumbnailFor(attachment);

      expect(backend.fetchCalls, 1);
    });

    test("a chat file's picture is asked for by size word", () async {
      final attachment = ref(
        source: 'teams',
        kind: 'file',
        name: 'Rates.xlsx',
        contentType: 'application/vnd.openxmlformats-officedocument'
            '.spreadsheetml.sheet',
        conversationKey: 'chat-1',
        sourceUrl: 'https://example.invalid/Rates.xlsx',
      );
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('a rendering');

      final thumb = await bytes.thumbnailFor(attachment);

      expect(thumb, payload('a rendering'));
      expect(backend.thumbnailWords, ['small'],
          reason: 'OneDrive renders it; this app never downloads the workbook');
    });

    test("a link's thumbnail is the drive's rendering first", () async {
      final attachment = ref(
        kind: 'reference',
        name: 'HARBORLIGHT TALENT AGREEMENT.pdf',
        size: 0,
        sourceUrl: 'https://example.invalid/:b:/g/personal/x/abc',
      );
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('a rendering');
      var drawn = 0;
      final withPdf = StoreAttachmentBytes(
        store: store,
        backend: backend,
        cache: cache,
        pdfThumbnailer: (pdfBytes, {int maxWidth = 320}) async {
          drawn++;
          return payload('drawn');
        },
      );

      final thumb = await withPdf.thumbnailFor(attachment);

      expect(thumb, payload('a rendering'));
      expect(backend.thumbnailWords, ['small'],
          reason: 'the drive draws it; this app never downloads the file');
      expect(drawn, 0);
    });

    test('a chat PDF asks the drive for its picture before downloading it',
        () async {
      final attachment = ref(
        source: 'teams',
        kind: 'file',
        name: 'Terms.pdf',
        contentType: 'application/pdf',
        conversationKey: 'chat-1',
        sourceUrl: 'https://example.invalid/Terms.pdf',
      );
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('a rendering');
      var drawn = 0;
      final withPdf = StoreAttachmentBytes(
        store: store,
        backend: backend,
        cache: cache,
        pdfThumbnailer: (pdfBytes, {int maxWidth = 320}) async {
          drawn++;
          return payload('drawn');
        },
      );

      final thumb = await withPdf.thumbnailFor(attachment);

      expect(thumb, payload('a rendering'));
      expect(backend.thumbnailWords, ['small']);
      expect(drawn, 0, reason: 'OneDrive answered, so the file never came down');
    });

    test('a drive with no picture of a linked PDF still gets its first page '
        'drawn', () async {
      // "The drive has no rendering to give" arrives as a REFUSAL, not an
      // empty answer, and a refusal must not end the ladder: the PDF branch
      // is the fallback for exactly this case.
      final attachment = ref(
        kind: 'reference',
        name: 'HARBORLIGHT TALENT AGREEMENT.pdf',
        contentType: null,
        size: 0,
        sourceUrl: 'https://southbayequity2-my.sharepoint.com/:b:/g/x',
      );
      await seed(attachment);
      backend.throwOnThumbnail = const AttachmentUnavailable('no_thumbnail');
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('%PDF-1.7 pretend');
      var drawn = 0;
      final withPdf = StoreAttachmentBytes(
        store: store,
        backend: backend,
        cache: cache,
        pdfThumbnailer: (pdfBytes, {int maxWidth = 320}) async {
          drawn++;
          return payload('drawn');
        },
      );

      final thumb = await withPdf.thumbnailFor(attachment);

      expect(thumb, payload('drawn'));
      expect(backend.thumbnailWords, ['small', '']);
      expect(drawn, 1);
    });

    test("a PDF's thumbnail is what the thumbnailer draws, and is remembered",
        () async {
      var drawn = 0;
      int? askedWidth;
      final withPdf = StoreAttachmentBytes(
        store: store,
        backend: backend,
        cache: cache,
        pdfThumbnailer: (pdfBytes, {int maxWidth = 320}) async {
          drawn++;
          askedWidth = maxWidth;
          return Uint8List.fromList(onePixelPng);
        },
      );
      final attachment = ref();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('%PDF-1.7 pretend');

      final first = await withPdf.thumbnailFor(attachment);

      expect(first, Uint8List.fromList(onePixelPng));
      expect(askedWidth, 320);
      final row = await store.attachmentRow('email', 'm1', 'a1');
      expect(row!['thumb_path'], isNotNull);

      // The second render reads what the first one wrote: no second draw and,
      // more to the point, no second download.
      expect(await withPdf.thumbnailFor(attachment), isNotNull);
      expect(drawn, 1);
      expect(backend.fetchCalls, 1);
    });

    test('a PDF the engine cannot draw leaves no thumbnail behind', () async {
      final withPdf = StoreAttachmentBytes(
        store: store,
        backend: backend,
        cache: cache,
        pdfThumbnailer: (pdfBytes, {int maxWidth = 320}) async => null,
      );
      final attachment = ref();
      await seed(attachment);
      backend.bytesByKey[FakeAttachmentBackend.keyOf(attachment)] =
          payload('not really a pdf');

      expect(await withPdf.thumbnailFor(attachment), isNull);
      final row = await store.attachmentRow('email', 'm1', 'a1');
      expect(row!['thumb_path'], isNull);
    });

    test('a PDF over the connector\'s cap gets no thumbnail and no fetch',
        () async {
      var drawn = 0;
      final withPdf = StoreAttachmentBytes(
        store: store,
        backend: backend,
        cache: cache,
        pdfThumbnailer: (pdfBytes, {int maxWidth = 320}) async {
          drawn++;
          return Uint8List.fromList(onePixelPng);
        },
      );
      final attachment = ref(size: attachmentTooLargeBytes + 1);
      await seed(attachment);

      expect(await withPdf.thumbnailFor(attachment), isNull);
      expect(drawn, 0);
      expect(backend.fetchCalls, 0);
    });

    test('with no thumbnailer a PDF has no thumbnail and nothing is fetched',
        () async {
      // The default in every test and in every provider build: pdfium is not
      // reachable, so a PDF simply has no picture.
      final attachment = ref();
      await seed(attachment);

      expect(await bytes.thumbnailFor(attachment), isNull);
      expect(backend.fetchCalls, 0);
    });

    test('a document with nothing to draw answers null and asks nobody',
        () async {
      final attachment = ref(name: 'Terms.docx');
      await seed(attachment);

      expect(await bytes.thumbnailFor(attachment), isNull);
      expect(backend.fetchCalls, 0);
    });

    test('a throwing connector leaves the row drawing a placeholder', () async {
      final attachment = imageRef();
      await seed(attachment);
      backend.throwOnFetch = const GraphMailException('no network');

      // Never throws: this runs while a list is building, and a picture nobody
      // could fetch must not take out the thread around it.
      expect(await bytes.thumbnailFor(attachment), isNull);
    });
  });

  group('words', () {
    test('a text nobody has extracted yet is null', () async {
      final attachment = ref();
      await seed(attachment);

      expect(await bytes.textFor(attachment), isNull);
    });

    test('what the handler stored is what comes back', () async {
      final attachment = ref();
      await seed(attachment);
      await store.setAttachmentText(
        'email',
        'm1',
        'a1',
        status: 'done',
        text: 'Total due: 4,200.',
      );

      expect(await bytes.textFor(attachment), 'Total due: 4,200.');
    });
  });
}

/// The real, decoded width of a PNG. The downscale is the subject, so trusting
/// a byte count instead would pass on an image that was merely re-encoded.
Future<int> _widthOf(Uint8List png) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(png);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final width = descriptor.width;
  descriptor.dispose();
  buffer.dispose();
  return width;
}
