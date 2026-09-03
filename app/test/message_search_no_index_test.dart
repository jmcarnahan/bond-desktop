import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/message_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// Search on a connection the nearest-neighbour index cannot work on.
///
/// Its own file, and that is not tidiness. Registering sqlite-vec is
/// process-global and one-way, and it reaches only connections opened AFTER
/// it, so the "no index" state is reproducible exactly once per process and
/// only while nothing has registered yet. This file therefore imports neither
/// `sqlite_vec_ffi` nor `vecTestDb`, and every test below OPENS ITS
/// CONNECTION FIRST — a connection older than the registration is precisely
/// the shape of a build where the native asset is missing, and it is the case
/// `MessageVectorIndex.ensureReady` returns false for.
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

  /// Answers every request with a real 768-wide vector, so the only thing
  /// missing below is the index.
  EmbeddingsClient workingServer() => EmbeddingsClient(
        baseUrl: 'http://localhost:8081/v1/embeddings',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {'embedding': List.filled(768, 0.1)}
              ]
            }),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      );

  // ONE test, and it has to stay one: the first probe registers sqlite-vec for
  // the rest of the process, so every connection opened after it has the
  // extension and a second test here would be asserting the opposite thing.
  test('a missing index reads as unavailable, never as "no matches"', () async {
    // The store's half first. The two answers are different sentences, and
    // only a nullable return can hold both: `const []` cannot say "there is
    // nothing to search WITH".
    expect(
      await store.semanticSearch(
        encodeEmbedding(List.filled(768, 0.1)),
        embedModel: EmbeddingsClient.documentModelTag,
      ),
      isNull,
    );

    final result = await MessageSearch(store, workingServer()).search('invoice');

    // And the sentence built on it. An empty hit list would tell the reader
    // their mail contains nothing about invoices — a statement about their
    // mailbox, made on the strength of a feature being switched off.
    expect(result, isA<MessageSearchUnavailable>());
    expect((result as MessageSearchUnavailable).reason, contains('index'));
  });
}
