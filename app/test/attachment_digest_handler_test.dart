import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_digest_handler.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// A model that answers from a script and counts what it was asked.
///
/// The count is what most of this file asserts: "no text means no model call"
/// and "an already digested file is skipped" are both statements about a
/// request that was never sent.
class FakeLlm extends LlmClient {
  final List<Object> script;
  final List<String> userMessages = [];
  final List<double> temperatures = [];

  FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  int get calls => userMessages.length;

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    userMessages.add(user);
    temperatures.add(temperature);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    if (step is Exception) throw step;
    return Map<String, dynamic>.from(step as Map);
  }
}

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
      final llm = FakeLlm([answer()]);
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
        FakeLlm([answer()]),
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
      final llm = FakeLlm([answer()]);

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
        FakeLlm([answer(facts: const [])..['summary'] = '']),
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
      final llm = FakeLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls, 0);
    });

    test('a status that claims words the table does not have closes the digest',
        () async {
      if (!available) return;
      await seed(text: null);
      // `done` with nothing behind it. Closing the digest is what stops the
      // pair being re-examined on every drain.
      final llm = FakeLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls, 0);
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
      final llm = FakeLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls, 0);
    });

    test('a message gated after the words landed keeps them and pays nothing',
        () async {
      if (!available) return;
      await seed(triageStatus: 'skipped');
      final llm = FakeLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('m1', 'a1'));

      expect(llm.calls, 0);
      // The words stay. What is refused is spending a model call on them.
      expect(
        await store.attachmentTextOf('email', 'm1', 'a1'),
        isNotNull,
      );
    });

    test('an attachment that vanished is done, not failed', () async {
      if (!available) return;
      final llm = FakeLlm([answer()]);

      await AttachmentDigestHandler(store, llm, FakeEmbedServer().client)
          .run(item('gone', 'a1'));

      expect(llm.calls, 0);
    });
  });

  group('the two servers', () {
    test('a model server that is down parks the kind', () async {
      if (!available) return;
      await seed();

      await expectLater(
        AttachmentDigestHandler(
          store,
          FakeLlm([const LlmUnavailableException('not running')]),
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
        FakeLlm([answer()]),
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

  group('the needs-you re-verdict', () {
    /// The work row for one message's re-judgement, or null when none was
    /// written.
    Future<Map<String, Object?>?> needsYouItem(String messageId) async {
      final rows = await db.customSelect(
        "SELECT * FROM work_items WHERE task_kind = 'needs_you' "
        'AND entity_id = ?',
        variables: [Variable(messageId)],
      ).get();
      return rows.isEmpty ? null : rows.first.data;
    }

    test('the first digest carrying an ask requeues needs-you', () async {
      if (!available) return;
      await seed();

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const ['Sign page four'])]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));

      expect((await needsYouItem('m1'))!['status'], 'pending');
    });

    test('the requeue wakes the worker for one more pass', () async {
      if (!available) return;
      await seed();
      var woken = 0;

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const ['Sign page four'])]),
        FakeEmbedServer().client,
        onRequeue: () => woken++,
      ).run(item('m1', 'a1'));

      // Once, and only when something was actually queued — the guard below
      // this one is what keeps a second document from waking it again.
      expect(woken, 1);
    });

    test('a digest that queues nothing wakes nothing', () async {
      if (!available) return;
      await seed();
      var woken = 0;

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const [])]),
        FakeEmbedServer().client,
        onRequeue: () => woken++,
      ).run(item('m1', 'a1'));

      expect(woken, 0);
    });

    test('the second on the same message does not', () async {
      if (!available) return;
      await seed();
      await store.upsertAttachments('email', 'm1', const [
        {
          'attachment_id': 'a2',
          'ordinal': 1,
          'kind': 'file',
          'name': 'Form W-9.pdf',
          'content_type': 'application/pdf',
          'size': 40960,
        },
      ]);
      await store.setAttachmentText(
        'email',
        'm1',
        'a2',
        status: 'done',
        text: 'Complete parts one and two and return signed.',
      );

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const ['Sign page four'])]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));
      // The first requeue is drained and finished, exactly as the worker would
      // leave it. A second requeue would revive it — which is the waste the
      // `== 1` guard exists to prevent.
      await store.writeWork('needs_you', 'email', 'm1', status: 'done');

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const ['Return the W-9'])]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a2'));

      expect((await needsYouItem('m1'))!['status'], 'done');
    });

    test('an already-judged message is not requeued', () async {
      if (!available) return;
      await seed();
      // The verdict is already at the top of the ladder: nothing a document
      // asks for can raise it further.
      await store.writeNeedsYouVerdict(
        'email',
        'm1',
        verdict: true,
        reason: 'Dana asked directly.',
      );

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const ['Sign page four'])]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));

      expect(await needsYouItem('m1'), isNull);
    });

    test('an outbound ask requeues nothing', () async {
      if (!available) return;
      await seed();
      // Straight onto the row: `upsertMessage` merges, and direction is one of
      // the fields a partial upsert leaves standing.
      await db.customUpdate(
        "UPDATE messages SET direction = 'outbound' "
        "WHERE source = 'email' AND source_message_id = ?",
        variables: [Variable('m1')],
      );

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const ['Sign page four'])]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));

      // The owner's own message is never judged, so a document on it has
      // nothing to change.
      expect(await needsYouItem('m1'), isNull);
    });

    test('a digest with no asks requeues nothing', () async {
      if (!available) return;
      await seed();

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer()]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));

      expect(await needsYouItem('m1'), isNull);
    });
  });

  group('what the needs-you re-verdict counts', () {
    test('a digest with an ask counts, and one without does not', () async {
      if (!available) return;
      await seed();
      await seed(messageId: 'm2', attachmentId: 'b1');

      await AttachmentDigestHandler(
        store,
        FakeLlm([answer(asks: const ['Sign page four'])]),
        FakeEmbedServer().client,
      ).run(item('m1', 'a1'));
      await AttachmentDigestHandler(
        store,
        FakeLlm([answer()]),
        FakeEmbedServer().client,
      ).run(item('m2', 'b1'));

      // The LIKE over the encoded JSON, which is why `toJson` writes all five
      // keys and `jsonEncode` spacing is pinned by a test of its own.
      expect(await store.attachmentsWithAsks('email', 'm1'), 1);
      expect(await store.attachmentsWithAsks('email', 'm2'), 0);
    });

    test('two documents asking on one message both count', () async {
      if (!available) return;
      await seed();
      await store.upsertAttachments('email', 'm1', const [
        {
          'attachment_id': 'a2',
          'ordinal': 1,
          'kind': 'file',
          'name': 'Form W-9.pdf',
          'content_type': 'application/pdf',
          'size': 40960,
        },
      ]);
      await store.setAttachmentText(
        'email',
        'm1',
        'a2',
        status: 'done',
        text: 'Complete parts one and two and return signed.',
      );

      for (final id in ['a1', 'a2']) {
        await AttachmentDigestHandler(
          store,
          FakeLlm([answer(asks: const ['Sign page four'])]),
          FakeEmbedServer().client,
        ).run(item('m1', id));
      }

      // The guard the next phase reads is `== 1`, so the count has to keep
      // climbing rather than saturating.
      expect(await store.attachmentsWithAsks('email', 'm1'), 2);
    });
  });
}
