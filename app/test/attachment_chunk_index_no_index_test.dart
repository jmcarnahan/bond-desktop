import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The chunk index on a connection that cannot have one.
///
/// Its own file, for `message_search_no_index_test.dart`'s reason exactly:
/// registering sqlite-vec is process-global and one-way, and it reaches only
/// connections opened AFTER it, so the "no native extension" state is
/// reproducible once per process and only while nothing has registered yet.
/// This file therefore imports neither `sqlite_vec_ffi` nor `vecTestDb`, and
/// the test below OPENS ITS CONNECTION FIRST.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    // Forces the connection open before anything probes it. Drift opens
    // lazily, and a connection opened DURING the probe would have the
    // extension and quietly test the opposite thing.
    await store.getMessageRow('email', 'nobody');
  });

  tearDown(() async => db.close());

  // ONE test, and it has to stay one: the first probe registers sqlite-vec for
  // the rest of the process, so every connection opened after it has the
  // extension and a second test here would be asserting the opposite thing.
  test('a build with no native index answers null, never "no passages"',
      () async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm1',
      'conversation_key': 'c-1',
      'direction': 'inbound',
      'subject': 'The lease',
      'received_at': '2026-09-04T10:00:00.000Z',
    });
    await store.upsertAttachments('email', 'm1', const [
      {
        'attachment_id': 'a1',
        'ordinal': 0,
        'kind': 'file',
        'name': 'Lease.pdf',
        'content_type': 'application/pdf',
        'size': 4096,
      },
    ]);
    final ids = await store.replaceChunks('email', 'm1', 'a1', const [
      (seq: 0, locator: '', text: 'The tenant pays on the fourth.'),
    ]);
    await store.setChunkEmbedding(
      ids.single,
      embedding: encodeEmbedding(List.filled(768, 0.1)),
      dims: 768,
      embedModel: EmbeddingsClient.documentModelTag,
    );

    // Everything durable still works: the passage is stored and the embedding
    // is on it. Only the thing that RANKS is missing, and both reads have to
    // say so with a null — `const []` would tell the reader their documents
    // say nothing about this, on the strength of a feature being switched off.
    final query = encodeEmbedding(List.filled(768, 0.1));
    expect(
      await store.searchAttachmentChunks(
        query,
        embedModel: EmbeddingsClient.documentModelTag,
      ),
      isNull,
    );
    expect(
      await store.chunkKnn(
        query,
        embedModel: EmbeddingsClient.documentModelTag,
        source: 'email',
        messageIds: const ['m1'],
      ),
      isNull,
    );
    // The backfill's own answer to the same state: nothing attempted, no
    // throw, and the rows left exactly where they are for a build that has the
    // extension.
    expect(await store.indexPendingChunks(), 0);
  });
}
