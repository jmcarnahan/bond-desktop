import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/attachments/attachment_text_handler.dart';
import 'package:bond_inbox/services/backend/attachment_backend.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_attachment_backend.dart';
import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// Reading one document, from the Graph call to the vectors.
///
/// The two failure shapes are what most of this file is about, because they
/// are the ones a handler gets wrong quietly. A REFUSAL — a binary file, a
/// gated message, a 404 — is an answer: the row records why, the item is done,
/// and no digest is queued. A server that is NOT RUNNING is not an answer: the
/// item goes back to `pending` with nothing spent, and everything already
/// written stays written so the resume pays only for the tail.
void main() {
  late bool available;
  late BondDatabase db;
  late MessageStore store;
  late FakeAttachmentBackend backend;
  late ActivityLog log;

  setUpAll(() {
    available = ensureSqliteVecLoaded();
  });

  setUp(() {
    db = vecTestDb();
    store = MessageStore(db);
    backend = FakeAttachmentBackend();
    log = ActivityLog(store);
  });

  tearDown(() async => db.close());

  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String triageStatus = 'triaged',
    String? gateReason,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': 'inbound',
      'subject': 'The lease renewal',
      'from_name': 'Dana Whitfield',
      'received_at': '2026-09-04T10:00:00.000Z',
      'body_text': 'See attached.',
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
  }

  Future<void> seedAttachment(
    String messageId,
    String attachmentId, {
    String source = 'email',
    String kind = 'file',
    String name = 'Lease.pdf',
    String contentType = 'application/pdf',
    int size = 240 * 1024,
    Object isInline = false,
  }) async {
    await store.upsertAttachments(source, messageId, [
      {
        'attachment_id': attachmentId,
        'ordinal': 0,
        'kind': kind,
        'name': name,
        'content_type': contentType,
        'size': size,
        'is_inline': isInline,
      },
    ]);
  }

  Map<String, Object?> item(
    String messageId,
    String attachmentId, {
    String source = 'email',
  }) =>
      {'source': source, 'entity_id': '$messageId|$attachmentId'};

  AttachmentTextHandler handlerWith(FakeEmbedServer server) =>
      AttachmentTextHandler(store, backend, server.client, activityLog: log);

  Future<Map<String, Object?>> attachmentOf(
    String messageId,
    String attachmentId, {
    String source = 'email',
  }) async =>
      (await store.attachmentRow(source, messageId, attachmentId))!;

  Future<List<Map<String, Object?>>> chunksOf(String messageId) async {
    final rows = await db.customSelect(
      'SELECT * FROM attachment_chunks WHERE source_message_id = ? '
      'ORDER BY seq',
      variables: [Variable(messageId)],
    ).get();
    return [for (final row in rows) row.data];
  }

  Future<String?> workStatus(String kind, String entityId) async {
    final rows = await db.customSelect(
      'SELECT status FROM work_items WHERE task_kind = ? AND entity_id = ?',
      variables: [Variable(kind), Variable(entityId)],
    ).get();
    return rows.isEmpty ? null : rows.first.data['status'] as String?;
  }

  group('the ordinary pass', () {
    test('stores the text, the chunks and a vector for each', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] = const AttachmentText.ok(
        'The tenant pays 2,400 on the fourth.\n\n'
        'The term runs eighteen months from October.',
        fetchedBytes: 4096,
      );
      final server = FakeEmbedServer();

      await handlerWith(server).run(item('m1', 'a1'));

      final row = await attachmentOf('m1', 'a1');
      expect(row['text_status'], 'done');
      expect(row['text_reason'], isNull);
      expect(
        await store.attachmentTextOf('email', 'm1', 'a1'),
        contains('2,400'),
      );

      final chunks = await chunksOf('m1');
      expect(chunks, hasLength(1));
      expect(chunks.single['embedding'], isNotNull);
      expect(chunks.single['embed_model'], EmbeddingsClient.documentModelTag);
      // Filed as well as embedded: the passage is searchable the moment it is
      // read, not at the next unrelated drain.
      expect(chunks.single['indexed_at'], isNotNull);
      // Under the DOCUMENT prefix, the same one message cards use — a query
      // embedded as a query is what these are matched against.
      expect(server.inputs.single, startsWith(EmbeddingsClient.documentPrefix));
    });

    test('queues the digest only once there are words', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.ok('The tenant pays 2,400.');

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      expect(await workStatus('attachment_digest', 'm1|a1'), 'pending');
    });

    test('the activity row carries the bytes moved and the time it took',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] = const AttachmentText.ok(
        'The tenant pays 2,400.',
        fetchedBytes: 8192,
      );

      // What the worker does around one item: the handler notes, the recorder
      // writes the row.
      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));
      await log.record('attachment_text', source: 'email', entityId: 'm1|a1');

      final detail = jsonDecode(
        (await store.recentActivity(limit: 1)).single['detail_json'] as String,
      ) as Map<String, Object?>;
      // The cost of reading a document is the one number that tells a slow
      // drain from a big mailbox.
      expect(detail['bytes'], 8192);
      expect(detail['fetch_ms'], isA<int>());
      expect(detail['chunks'], 1);
      expect(detail['embedded'], 1);
    });
  });

  group('the message inside a forwarded attachment', () {
    test('a forwarded message keeps its subject, sender and date on the row',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1', kind: 'item', name: 'FW Q3.eml');
      backend.textByKey['email|m1|a1'] = const AttachmentText.ok(
        'The forecast holds at 2.4 million.',
        itemSubject: 'Q3 forecast',
        itemFrom: 'dana@example.test',
        itemReceived: '2026-08-20T10:00:00Z',
      );

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      // The three columns nothing wrote until now. They ride on the text call
      // because that is where both connectors hand them over.
      final row = await attachmentOf('m1', 'a1');
      expect(row['item_subject'], 'Q3 forecast');
      expect(row['item_from'], 'dana@example.test');
      expect(row['item_received'], '2026-08-20T10:00:00Z');
      expect(row['text_status'], 'done');
    });

    test('a skipped attached message still records who sent it', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1', kind: 'item', name: 'FW Q3.eml');
      // A wrapped message with an empty body still has a subject, a sender and
      // a date, and the `.eml` preview draws all three.
      backend.textByKey['email|m1|a1'] = const AttachmentText.skipped(
        'empty',
        itemSubject: 'Q3 forecast',
        itemFrom: 'dana@example.test',
        itemReceived: '2026-08-20T10:00:00Z',
      );

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      final row = await attachmentOf('m1', 'a1');
      expect(row['text_status'], 'skipped');
      expect(row['item_subject'], 'Q3 forecast');
      expect(row['item_from'], 'dana@example.test');
      expect(row['item_received'], '2026-08-20T10:00:00Z');
    });

    test('an ordinary file writes none of them', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.ok('The tenant pays 2,400.');

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      final row = await attachmentOf('m1', 'a1');
      expect(row['item_subject'], isNull);
      expect(row['item_from'], isNull);
      expect(row['item_received'], isNull);
    });
  });

  group('a refusal is an answer', () {
    test('a binary attachment is skipped with its reason and queues no digest',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1', name: 'Site.zip');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.skipped('no_extractor');

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      final row = await attachmentOf('m1', 'a1');
      expect(row['text_status'], 'skipped');
      expect(row['text_reason'], 'no_extractor');
      expect(await chunksOf('m1'), isEmpty);
      // No words means nothing for a model to read, and queuing one anyway
      // would spend a fast-slot call establishing that.
      expect(await workStatus('attachment_digest', 'm1|a1'), isNull);
    });

    test('a skip marks the digest skipped too', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.skipped('access_denied');

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      // Left `pending`, the chip would say "reading…" for the life of the
      // mailbox: nothing else ever comes along to answer it.
      expect((await attachmentOf('m1', 'a1'))['digest_status'], 'skipped');
    });

    test('a message gated after the enqueue leaves the attachment alone',
        () async {
      if (!available) return;
      await seedMessage('m1', triageStatus: 'skipped');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.ok('The tenant pays 2,400.');

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      // The policy is asked again after the claim precisely for this: the user
      // filed the thread between the enqueue and the drain.
      expect(backend.textCalls, 0);
      final row = await attachmentOf('m1', 'a1');
      expect(row['text_status'], 'skipped');
      expect(row['text_reason'], 'gated');
    });

    test('an inline signature image is refused before a fetch', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment(
        'm1',
        'logo',
        kind: 'image',
        name: 'logo.png',
        contentType: 'image/png',
        size: 4096,
        isInline: true,
      );

      await handlerWith(FakeEmbedServer()).run(item('m1', 'logo'));

      expect(backend.textCalls, 0);
      expect((await attachmentOf('m1', 'logo'))['text_reason'], 'kind_image');
    });

    test('an attachment that vanished is done, not failed', () async {
      if (!available) return;
      await seedMessage('m1');

      // No row was ever written, or the message was deleted between the
      // enqueue and the claim. A normal return is what marks the item done.
      await handlerWith(FakeEmbedServer()).run(item('m1', 'gone'));

      expect(backend.textCalls, 0);
    });

    test('a Graph 404 is a skip rather than two more attempts', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.throwOnText = const GraphMailException('not found', 404);

      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      final row = await attachmentOf('m1', 'a1');
      expect(row['text_status'], 'skipped');
      expect(row['text_reason'], 'gone');
    });

    test('a Graph 503 is transport and belongs to the worker', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.throwOnText = const GraphMailException('throttled', 503);

      // Everything but 404/410 propagates: recording a retryable failure as a
      // skip costs the document permanently.
      await expectLater(
        handlerWith(FakeEmbedServer()).run(item('m1', 'a1')),
        throwsA(isA<GraphMailException>()),
      );
      expect((await attachmentOf('m1', 'a1'))['text_status'], 'pending');
    });
  });

  group('the embedding server', () {
    test('a server that is not running parks the kind and keeps the text',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.ok('The tenant pays 2,400 on the fourth.');

      await expectLater(
        handlerWith(FakeEmbedServer(status: null)).run(item('m1', 'a1')),
        throwsA(isA<LlmUnavailableException>()),
      );

      // The throw is what parks this kind and puts the item back to `pending`
      // with no attempt spent. What was already read is NOT thrown away.
      expect((await attachmentOf('m1', 'a1'))['text_status'], 'done');
      expect(await chunksOf('m1'), hasLength(1));
      expect((await chunksOf('m1')).single['embedding'], isNull);
    });

    test('the resume pays for the tail and costs no second fetch', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] = AttachmentText.ok(
        'The tenant pays 2,400 on the fourth.\n\n'
        '${'The term runs eighteen months from October. ' * 40}',
      );

      await expectLater(
        handlerWith(FakeEmbedServer(status: null)).run(item('m1', 'a1')),
        throwsA(isA<LlmUnavailableException>()),
      );
      expect(backend.textCalls, 1);

      // `make embed` is running now. The item came back `pending` and the
      // handler claims it again.
      final server = FakeEmbedServer();
      await handlerWith(server).run(item('m1', 'a1'));

      // No second Graph call: the words are already stored.
      expect(backend.textCalls, 1);
      final chunks = await chunksOf('m1');
      expect(chunks.length, greaterThan(1));
      expect(server.calls, chunks.length);
      for (final chunk in chunks) {
        expect(chunk['embedding'], isNotNull, reason: '${chunk['seq']}');
      }
      expect(await workStatus('attachment_digest', 'm1|a1'), 'pending');
    });

    test('a rejected passage keeps a null vector and does not stop the rest',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.ok('The tenant pays 2,400.');

      // The server read the request and said no; the next attempt reads the
      // same no, so the item is done and the row keeps a NULL embedding —
      // invisible to the index and to every KNN.
      await handlerWith(FakeEmbedServer(status: 500)).run(item('m1', 'a1'));

      expect((await attachmentOf('m1', 'a1'))['text_status'], 'done');
      expect((await chunksOf('m1')).single['embedding'], isNull);
      expect(await workStatus('attachment_digest', 'm1|a1'), 'pending');
    });

    test('a second pass over finished work costs no fetch and no embed',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] =
          const AttachmentText.ok('The tenant pays 2,400.');
      final server = FakeEmbedServer();
      await handlerWith(server).run(item('m1', 'a1'));

      await handlerWith(server).run(item('m1', 'a1'));

      expect(backend.textCalls, 1);
      expect(server.calls, 1);
    });

    test('a retry re-chunks without doubling', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      backend.textByKey['email|m1|a1'] = AttachmentText.ok(
        'The tenant pays 2,400.\n\n${'A clause about the term. ' * 60}',
      );
      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));
      final first = await chunksOf('m1');

      // What a restore or a re-extraction does: the text handler runs the
      // whole ladder again over the same document. The chunker is
      // deterministic, so the passages replace themselves.
      await db.customUpdate(
        "UPDATE attachments SET text_status = 'pending'",
      );
      await handlerWith(FakeEmbedServer()).run(item('m1', 'a1'));

      final second = await chunksOf('m1');
      expect(second, hasLength(first.length));
      expect(
        second.map((c) => c['chunk_text']),
        first.map((c) => c['chunk_text']),
      );
    });
  });
}
