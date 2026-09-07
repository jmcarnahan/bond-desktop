import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_retriever.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// What a reply is allowed to quote, and — far more importantly — what it is
/// not.
///
/// The retriever's whole reason for existing is a scope. A model handed the
/// nearest passage in the mailbox would write a reply that quotes a figure
/// from a stranger's contract, in the owner's own name, and it would read
/// perfectly. So every test here is really the same test asked from a
/// different side: the answer comes from THIS thread, or from a document
/// somebody pinned to this storyline, or it does not come at all.
void main() {
  const tag = EmbeddingsClient.documentModelTag;

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

  Future<void> seedMessage(
    String id, {
    String key = 'conv-1',
    String source = 'email',
    String direction = 'inbound',
    String? receivedAt = '2026-09-04T10:00:00.000Z',
    String from = 'Dana Whitfield',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'subject': 'Renewal paperwork',
      'from_name': from,
      'received_at': receivedAt,
      'body_text': 'The paperwork is attached.',
      'triage_status': 'triaged',
    });
  }

  /// A message with a vector already stored, which is the ordinary case: the
  /// embed queue reaches inbound mail long before anyone asks for a draft.
  Future<void> seedVector(String id, int axis, {String model = tag}) async {
    await store.upsertMessageVector(
      source: 'email',
      sourceMessageId: id,
      embedding: encodeEmbedding(axes({axis: 1.0})),
      dims: 768,
      embeddedHash: 'h-$id',
      embedModel: model,
      receivedAt: '2026-09-04T10:00:00.000Z',
    );
  }

  Future<void> seedAttachment(
    String messageId,
    String attachmentId, {
    String name = 'Lease.pdf',
    String source = 'email',
  }) async {
    await store.upsertAttachments(source, messageId, [
      {
        'attachment_id': attachmentId,
        'ordinal': 0,
        'kind': 'file',
        'name': name,
        'content_type': 'application/pdf',
        'size': 4096,
      },
    ]);
  }

  /// Writes passages and embeds each one on the axis its entry names, so
  /// nearness in these tests is a fact about the fixture rather than about the
  /// English in it.
  Future<void> seedChunks(
    String messageId,
    String attachmentId,
    List<({String locator, String text, int axis})> chunks, {
    String source = 'email',
  }) async {
    final ids = await store.replaceChunks(
      source,
      messageId,
      attachmentId,
      [
        for (var i = 0; i < chunks.length; i++)
          (seq: i, locator: chunks[i].locator, text: chunks[i].text),
      ],
    );
    for (var i = 0; i < ids.length; i++) {
      await store.setChunkEmbedding(
        ids[i],
        embedding: encodeEmbedding(axes({chunks[i].axis: 1.0})),
        dims: 768,
        embedModel: tag,
      );
    }
    await store.indexPendingChunks();
  }

  AttachmentRetriever retrieverOver(FakeEmbedServer server) =>
      AttachmentRetriever(store, server.client);

  group('the scope', () {
    test('finds the passage on this thread that answers the message', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'part 1', text: 'The tenant pays 2,400 monthly.', axis: 3),
        (locator: 'part 2', text: 'Parking is a separate agreement.', axis: 9),
      ]);
      final server = FakeEmbedServer();

      final excerpts = await retrieverOver(server).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      expect(excerpts.first.text, 'The tenant pays 2,400 monthly.');
      expect(excerpts.first.name, 'Lease.pdf');
      expect(excerpts.first.locator, 'part 1');
      expect(excerpts.first.sender, 'Dana Whitfield');
      expect(excerpts.first.date, '2026-09-04');
      // The stored vector was used, so nothing was asked of the embedder.
      expect(server.calls, 0);
    });

    test('a document on another thread is never in scope', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      // A second thread whose passage is a PERFECT match for the query. The
      // only thing keeping it out of the reply is the scope.
      await seedMessage('other', key: 'conv-2');
      await seedAttachment('other', 'a9', name: 'Stranger Contract.pdf');
      await seedChunks('other', 'a9', const [
        (locator: 'part 1', text: 'The buyer pays 900,000 at closing.', axis: 3),
      ]);

      final excerpts = await retrieverOver(FakeEmbedServer()).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      expect(excerpts, isEmpty);
    });

    test('a pinned document is in scope even when its message is not',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedMessage('old', key: 'conv-2');
      await seedAttachment('old', 'a9', name: 'Survey.pdf');
      await seedChunks('old', 'a9', const [
        (locator: 'page 2', text: 'The lot is 0.42 acres.', axis: 3),
      ]);
      // No storyline row is needed: the pin is a column on the attachment,
      // and `pinnedAttachmentsForStoryline` reads it directly.
      await store.setAttachmentPinned('email', 'old', 'a9', 's1');

      final excerpts = await retrieverOver(FakeEmbedServer()).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        storylineIds: const ['s1'],
      );

      expect(excerpts.single.text, 'The lot is 0.42 acres.');
      expect(excerpts.single.name, 'Survey.pdf');
    });

    test('the thread\'s own document is found under a mailbox of nearer '
        'strangers', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'part 1', text: 'The tenant pays 2,400 monthly.', axis: 3),
      ]);
      // …and the passage is moved OFF the query's axis, so every stranger
      // below is strictly nearer to it than this thread's own document is.
      final own = await db
          .customSelect("SELECT id FROM attachment_chunks WHERE attachment_id "
              "= 'a1'")
          .getSingle();
      await store.setChunkEmbedding(
        own.data['id'] as int,
        embedding: encodeEmbedding(axes({3: 0.6, 11: 0.8})),
        dims: 768,
        embedModel: tag,
      );

      // Sixty documents on sixty other threads, all sitting exactly on the
      // query. A corpus-wide k of 48 is filled entirely by them, and the
      // thread's own contract never makes the shortlist — which is what a
      // real mailbox does to a generic "please see attached".
      for (var i = 0; i < 60; i++) {
        await seedMessage('other-$i', key: 'conv-other-$i');
        await seedAttachment('other-$i', 'b$i', name: 'Stranger $i.pdf');
        await seedChunks('other-$i', 'b$i', [
          (locator: 'part 1', text: 'A figure from somewhere else. $i', axis: 3),
        ]);
      }
      await store.indexPendingChunks();

      final excerpts = await retrieverOver(FakeEmbedServer()).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        k: 6,
      );

      // The scope is applied INSIDE the neighbour search, so the six nearest
      // are the six nearest ON THIS THREAD — of which there is one.
      expect(excerpts.single.text, 'The tenant pays 2,400 monthly.');
      expect(excerpts.single.name, 'Lease.pdf');
    });

    test('a thread with no documents asks the embedding server nothing',
        () async {
      if (!available) return;
      await seedMessage('m1');
      // A corpus that is not empty, and a thread that has nothing on it.
      await seedMessage('other', key: 'conv-2');
      await seedAttachment('other', 'a9');
      await seedChunks('other', 'a9', const [
        (locator: 'part 1', text: 'The buyer pays 900,000.', axis: 3),
      ]);
      final server = FakeEmbedServer();
      final spy = _CountingStore(db);

      final excerpts = await AttachmentRetriever(spy, server.client).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      expect(excerpts, isEmpty);
      // The cheap read stands in front of the expensive ones: no vector was
      // asked for and the index was never searched.
      expect(server.calls, 0);
      expect(spy.knnCalls, 0);
    });

    test('an empty scope asks nothing, whatever the corpus holds', () async {
      if (!available) return;
      // A message on a thread of its own, and a corpus with a passage in it.
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedMessage('other', key: 'conv-2');
      await seedAttachment('other', 'a9');
      await seedChunks('other', 'a9', const [
        (locator: 'part 1', text: 'The buyer pays 900,000.', axis: 3),
      ]);
      final server = FakeEmbedServer();

      final excerpts = await retrieverOver(server).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        // No thread, no storyline, nothing named. The one shape a bug in the
        // caller would produce, and the one that must answer nothing.
        threadMessageIds: const [],
      );

      expect(excerpts, isEmpty);
      // Not even a vector was asked for: the refusal comes before the cost.
      expect(server.calls, 0);
    });
  });

  group('the ranking', () {
    test('an explicitly named document comes first', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedAttachment('m1', 'near', name: 'Near.pdf');
      await seedChunks('m1', 'near', const [
        (locator: 'part 1', text: 'The nearest passage of all.', axis: 3),
      ]);
      await seedAttachment('m1', 'far', name: 'Far.pdf');
      await seedChunks('m1', 'far', const [
        (locator: 'part 1', text: 'A passage the user asked for.', axis: 7),
      ]);

      final excerpts = await retrieverOver(FakeEmbedServer()).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        pinnedFirst: const ['far'],
      );

      // The named file leads even though the other one is nearer — that is
      // what "Use in reply" means — and the ranking survives behind it.
      expect(excerpts.map((e) => e.name), ['Far.pdf', 'Near.pdf']);
    });

    test('at most three passages from any one document', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'part 1', text: 'One.', axis: 3),
        (locator: 'part 2', text: 'Two.', axis: 3),
        (locator: 'part 3', text: 'Three.', axis: 3),
        (locator: 'part 4', text: 'Four.', axis: 3),
        (locator: 'part 5', text: 'Five.', axis: 3),
      ]);

      final excerpts = await retrieverOver(FakeEmbedServer()).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      // A fifty-chunk contract must not be the whole answer.
      expect(excerpts.length, 3);
    });

    test('the digest passage is never quoted', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'digest', text: 'The model read this and summarised it.',
            axis: 3),
        (locator: 'part 1', text: 'The tenant pays 2,400 monthly.', axis: 4),
      ]);

      final excerpts = await retrieverOver(FakeEmbedServer()).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      // The fence above these says they are excerpts FROM the document. The
      // digest is a model's summary of it, and passing one off as the
      // document's own words is how a reply comes to quote something nobody
      // wrote.
      expect(excerpts.map((e) => e.locator), ['part 1']);
    });

    test('the budget trims the far end and keeps the nearest', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3);
      await seedAttachment('m1', 'a1', name: 'A.pdf');
      await seedChunks('m1', 'a1', [
        (locator: 'part 1', text: 'N' * 100, axis: 3),
      ]);
      await seedAttachment('m1', 'a2', name: 'B.pdf');
      await seedChunks('m1', 'a2', [
        (locator: 'part 1', text: 'F' * 100, axis: 5),
      ]);

      final excerpts = await retrieverOver(FakeEmbedServer()).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
        // Room for one passage and its bracket line, and not two.
        budgetChars: 200,
      );

      expect(excerpts.single.name, 'A.pdf');
    });
  });

  group('the query vector', () {
    test('a message with no stored vector is embedded on the spot', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'part 1', text: 'The tenant pays 2,400 monthly.', axis: 0),
      ]);
      final server = FakeEmbedServer();

      final excerpts = await retrieverOver(server).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      expect(excerpts.single.text, 'The tenant pays 2,400 monthly.');
      // The DOCUMENT prefix, not the search prefix. A query-prefixed vector
      // sits in a different corner of the space from every chunk it would be
      // compared against, and the comparison would still return something.
      expect(server.inputs.single,
          startsWith(EmbeddingsClient.documentPrefix));
      expect(server.inputs.single, contains('Renewal paperwork'));
    });

    test('a vector under another model tag is re-embedded, not trusted',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedVector('m1', 3, model: 'some-older-tag');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'part 1', text: 'The tenant pays 2,400 monthly.', axis: 0),
      ]);
      final server = FakeEmbedServer();

      await retrieverOver(server).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      expect(server.calls, 1);
    });

    test('an embedding server that is down returns no excerpts and no error',
        () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'part 1', text: 'The tenant pays 2,400 monthly.', axis: 0),
      ]);

      final excerpts = await retrieverOver(FakeEmbedServer(status: null))
          .excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'm1',
      );

      // Degraded, not thrown. The draft below this is the product; the
      // citations are what make it better.
      expect(excerpts, isEmpty);
    });

    test('a message that is gone answers nothing', () async {
      if (!available) return;
      await seedMessage('m1');
      await seedAttachment('m1', 'a1');
      await seedChunks('m1', 'a1', const [
        (locator: 'part 1', text: 'The tenant pays 2,400 monthly.', axis: 0),
      ]);
      final server = FakeEmbedServer();

      final excerpts = await retrieverOver(server).excerptsFor(
        source: 'email',
        conversationKey: 'conv-1',
        replyToId: 'gone',
        threadMessageIds: const ['m1'],
      );

      expect(excerpts, isEmpty);
      expect(server.calls, 0);
    });
  });

  group('rendering', () {
    AttachmentExcerpt excerpt({
      String name = 'Lease.pdf',
      String locator = 'part 1',
      String sender = 'Dana Whitfield',
      String date = '2026-09-04',
      String text = 'The tenant pays 2,400 monthly.',
    }) =>
        AttachmentExcerpt(
          name: name,
          locator: locator,
          sender: sender,
          date: date,
          text: text,
          ref: const AttachmentRef(
            source: 'email',
            messageId: 'm1',
            attachmentId: 'a1',
          ),
        );

    test('the file name and the locator sit inside the bracket line', () {
      final rendered = renderAttachmentExcerpts([excerpt()], 2500);

      expect(
        rendered,
        '[Lease.pdf, part 1, attached by Dana Whitfield on 2026-09-04]\n'
        'The tenant pays 2,400 monthly.',
      );
    });

    test('a nameless, placeless, dateless passage still says so', () {
      final rendered = renderAttachmentExcerpts(
        [excerpt(name: '', locator: '', sender: '', date: '')],
        2500,
      );

      // Stand-ins rather than empty commas: the model has to be able to tell
      // "no name" from a name it failed to read.
      expect(
        rendered,
        startsWith('[a file, whole document, attached by unknown on '
            'an unknown date]'),
      );
    });

    test('the cap drops whole passages from the far end before it cuts', () {
      final rendered = renderAttachmentExcerpts(
        [
          excerpt(name: 'Near.pdf', text: 'N' * 60),
          excerpt(name: 'Far.pdf', text: 'F' * 60),
        ],
        140,
      );

      expect(rendered, contains('Near.pdf'));
      expect(rendered, isNot(contains('Far.pdf')));
      expect(rendered.length, lessThanOrEqualTo(140));
    });

    test('one passage over the cap on its own is hard-cut', () {
      final rendered = renderAttachmentExcerpts([excerpt(text: 'x' * 500)], 90);

      expect(rendered.length, 90);
    });
  });
}

/// A store that counts the one read the guard is supposed to make unnecessary.
///
/// A subclass rather than a fake, because the point is that everything ELSE
/// behaves exactly as the real store does — the guard has to be what stops the
/// search, not a stubbed-out index.
class _CountingStore extends MessageStore {
  int knnCalls = 0;

  _CountingStore(super.db);

  @override
  Future<List<AttachmentChunkHit>?> chunkKnn(
    Uint8List query, {
    required String embedModel,
    required String source,
    List<String> messageIds = const [],
    List<String> attachmentIds = const [],
    int limit = 6,
  }) {
    knnCalls++;
    return super.chunkKnn(
      query,
      embedModel: embedModel,
      source: source,
      messageIds: messageIds,
      attachmentIds: attachmentIds,
      limit: limit,
    );
  }
}
