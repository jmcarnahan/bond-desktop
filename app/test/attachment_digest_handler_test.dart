import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_digest_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/vec_test_db.dart';

/// A model that answers from a script and counts what it was asked.
///
/// The count is what most of this file asserts: "no text means no model call"
/// and "an already digested file is skipped" are both statements about a
/// request that was never sent.
ScriptedLlm digestLlm(List<Object> script) =>
    ScriptedLlm()..scriptFor('attachment_digest', script);

void main() {
  late bool available;
  late BondDatabase db;
  late MessageStore store;

  setUpAll(() {
    available = ensureSqliteVecLoaded();
  });

  setUp(() {
    db = vecTestDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Map<String, Object?> answer({
    String kind = 'contract',
    List<String> facts = const ['Rent rises to 2,600 on 1 January'],
    List<String> asks = const [],
  }) =>
      {
        'evidence': 'A lease addendum sent for the owner to sign.',
        'kind': kind,
        'summary': 'The rent rises to 2,600 in January.',
        'facts': facts,
        'asks': asks,
      };

  Future<void> seed({
    String messageId = 'm1',
    String attachmentId = 'a1',
    String source = 'email',
    String triageStatus = 'triaged',
    String? text = 'The tenant pays 2,400 on the fourth of each month.',
    String textStatus = 'done',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': messageId,
      'conversation_key': 'conv-$messageId',
      'direction': 'inbound',
      'subject': 'Renewal paperwork',
      'from_name': 'Dana Whitfield',
      'received_at': '2026-09-04T10:00:00.000Z',
      'body_text': 'The lease is attached.',
      'triage_status': triageStatus,
    });
    await store.upsertAttachments(source, messageId, [
      {
        'attachment_id': attachmentId,
        'ordinal': 0,
        'kind': 'file',
        'name': 'Lease Addendum.pdf',
        'content_type': 'application/pdf',
        'size': 240 * 1024,
      },
    ]);
    await store.setAttachmentText(
      source,
      messageId,
      attachmentId,
      status: textStatus,
      text: text,
    );
  }

  Map<String, Object?> item(
    String messageId,
    String attachmentId, {
    String source = 'email',
  }) =>
      {'source': source, 'entity_id': '$messageId|$attachmentId'};

  Future<List<Map<String, Object?>>> chunksOf(String messageId) async {
    final rows = await db.customSelect(
      'SELECT * FROM attachment_chunks WHERE source_message_id = ? ORDER BY seq',
      variables: [Variable(messageId)],
    ).get();
    return [for (final row in rows) row.data];
  }

  group('the ordinary pass', () {
    test('writes the digest and one more chunk for it', () async {
      if (!available) return;
      await seed();
      final llm = digestLlm([answer()]);
      final server = FakeEmbedServer();

      await AttachmentDigestHandler(store, llm, server.client)
          .run(item('m1', 'a1'));

      final row = (await store.attachmentRow('email', 'm1', 'a1'))!;
      expect(row['digest_status'], 'done');
      final digest = decodeAttachmentDigest(row['digest_json'] as String?)!;
      expect(digest.kind, 'contract');
      expect(digest.facts, ['Rent rises to 2,600 on 1 January']);
      // Deterministic: the same document read twice must not be two different
      // records of it.
      expect(llm.temperatures.single, 0);

      // The digest is a passage of the document like any other — the one a
      // search for "what is this file about" should land on.
      final chunk = (await chunksOf('m1')).single;
      expect(chunk['locator'], 'digest');
      expect(chunk['chunk_text'], contains('The rent rises to 2,600'));
      expect(chunk['chunk_text'], contains('Rent rises to 2,600 on 1 January'));
      expect(chunk['embedding'], isNotNull);
      expect(chunk['indexed_at'], isNotNull);
    });

    test('the digest chunk is appended after the passages, never over them',
        () async {
      if (!available) return;
      await seed();
      await store.replaceChunks('email', 'm1', 'a1', const [
        (seq: 0, locator: 'part 1', text: 'The tenant pays 2,400.'),
        (seq: 1, locator: 'part 2', text: 'The term runs eighteen months.'),
      ]);

      await AttachmentDigestHandler(
        store,
        digestLlm([answer()]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));

      final chunks = await chunksOf('m1');
      expect(chunks.map((c) => c['seq']), [0, 1, 2]);
      expect(chunks.last['locator'], 'digest');
    });

    test('the message is context and the document is what is judged',
        () async {
      if (!available) return;
      await seed();
      final llm = digestLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      final sent = llm.userMessages.single;
      expect(sent, contains('<untrusted_data source="message">'));
      expect(sent, contains('<untrusted_data source="document">'));
      expect(sent, contains('The tenant pays 2,400'));
      expect(
        sent.indexOf('source="message"'),
        lessThan(sent.indexOf('source="document"')),
      );
    });

    test('a digest with nothing to say writes no chunk', () async {
      if (!available) return;
      await seed();

      await AttachmentDigestHandler(
        store,
        digestLlm([answer(facts: const [])..['summary'] = '']),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));

      // The record is still written — a document read and found to say nothing
      // is an answer — but there is no passage to embed.
      expect(
        (await store.attachmentRow('email', 'm1', 'a1'))!['digest_status'],
        'done',
      );
      expect(await chunksOf('m1'), isEmpty);
    });
  });

  group('what it refuses to spend a call on', () {
    test('no text means no model call', () async {
      if (!available) return;
      await seed(text: null, textStatus: 'skipped');
      final llm = digestLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls.length, 0);
    });

    test('a status that claims words the table does not have closes the digest',
        () async {
      if (!available) return;
      await seed(text: null);
      // `done` with nothing behind it. Closing the digest is what stops the
      // pair being re-examined on every drain.
      final llm = digestLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls.length, 0);
      expect(
        (await store.attachmentRow('email', 'm1', 'a1'))!['digest_status'],
        'skipped',
      );
    });

    test('an already digested file is skipped', () async {
      if (!available) return;
      await seed();
      await store.setAttachmentDigest(
        'email',
        'm1',
        'a1',
        status: 'done',
        digestJson: '{"evidence":"","kind":"other","summary":"","facts":[],'
            '"asks":[]}',
      );
      final llm = digestLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls.length, 0);
    });

    test('a message gated after the words landed keeps them and pays nothing',
        () async {
      if (!available) return;
      await seed(triageStatus: 'skipped');
      final llm = digestLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls.length, 0);
      // The words stay. What is refused is spending a model call on them.
      expect(
        await store.attachmentTextOf('email', 'm1', 'a1'),
        isNotNull,
      );
    });

    test('a message gated after its words landed closes the digest', () async {
      if (!available) return;
      await seed(triageStatus: 'skipped');
      final llm = digestLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls.length, 0);
      // Left `pending` over `done` text, this is exactly the pair the chip
      // renders as `reading…`, and nothing else comes back to answer it.
      final row = (await store.attachmentRow('email', 'm1', 'a1'))!;
      expect(row['text_status'], 'done');
      expect(row['digest_status'], 'skipped');
      expect(row['digest_json'], isNull);
    });

    test('an attachment that vanished is done, not failed', () async {
      if (!available) return;
      final llm = digestLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('gone', 'a1'));

      expect(llm.calls.length, 0);
    });
  });

  group('the two servers', () {
    test('a model server that is down parks the kind', () async {
      if (!available) return;
      await seed();

      await expectLater(
        AttachmentDigestHandler(
          store,
          digestLlm([const LlmUnavailableException('not running')]),
          FakeEmbedServer().client,
        ).run(item('m1', 'a1')),
        throwsA(isA<LlmUnavailableException>()),
      );

      // Nothing written, nothing spent: the worker puts the item back to
      // `pending` and the next drain re-reads the same document.
      expect(
        (await store.attachmentRow('email', 'm1', 'a1'))!['digest_status'],
        'pending',
      );
    });

    test('an embedding server that is down does not undo the digest',
        () async {
      if (!available) return;
      await seed();

      // Unlike the text handler, this one does NOT throw: the model call is
      // already paid for, and parking here would risk spending it twice.
      await AttachmentDigestHandler(
        store,
        digestLlm([answer()]),
        FakeEmbedServer(status: null).client,
      ).run(item('m1', 'a1'));

      expect(
        (await store.attachmentRow('email', 'm1', 'a1'))!['digest_status'],
        'done',
      );
      // The passage keeps a NULL embedding, invisible to the index and to
      // every KNN until something re-reads the document.
      expect((await chunksOf('m1')).single['embedding'], isNull);
    });
  });

  group('needs-you', () {
    test('a digest carrying an ask queues no needs-you work', () async {
      // The asks stay on the file card and in the action items. Whether the
      // message needs the owner is the decision model's probability, which a
      // document read afterwards does not re-open.
      if (!available) return;
      await seed();

      await AttachmentDigestHandler(
        store,
        digestLlm([answer(asks: const ['Sign page four'])]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));

      final queued = await db.customSelect(
        "SELECT 1 FROM work_items WHERE task_kind = 'needs_you' "
        'AND entity_id = ?',
        variables: [Variable('m1')],
      ).get();
      expect(queued, isEmpty);
      final digest = await db.customSelect(
        'SELECT digest_json FROM attachments '
        "WHERE source_message_id = 'm1' AND attachment_id = 'a1'",
      ).getSingle();
      expect(digest.data['digest_json'] as String, contains('Sign page four'));
    });
  });

  group('width', () {
    test('one at a time when nothing says, as before', () {
      expect(
        AttachmentDigestHandler(store, ScriptedLlm(), FakeEmbedServer().client)
            .concurrency,
        1,
      );
    });

    test("the target's text width, read on every claim", () {
      var width = 8;
      final handler = AttachmentDigestHandler(
        store,
        ScriptedLlm(),
        FakeEmbedServer().client,
        textParallel: () => width,
      );

      expect(handler.concurrency, 8);
      width = 3;
      expect(handler.concurrency, 3);
    });
  });
}
