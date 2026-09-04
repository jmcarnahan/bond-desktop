import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/embed_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// A fake embedding server that counts what it was asked.
///
/// The count is the point of most of this file: the hash guard's whole job is
/// to make the second pass over a message cost nothing, and "cost nothing" is
/// only observable as a request that was never sent.
class FakeEmbedServer {
  final List<String> inputs = [];

  /// null → the socket dies (the server is not running).
  /// 500 → the server answers, badly.
  final int? status;

  FakeEmbedServer({this.status = 200});

  int get calls => inputs.length;

  EmbeddingsClient get client => EmbeddingsClient(
        baseUrl: 'http://localhost:8081/v1/embeddings',
        httpClient: MockClient((request) async {
          inputs.add(
            (jsonDecode(request.body) as Map<String, dynamic>)['input']
                as String,
          );
          final code = status;
          if (code == null) {
            // What `http` raises for a connection that went nowhere. The
            // client maps it to `unavailable`, exactly as it does a real
            // SocketException.
            throw http.ClientException('connection refused');
          }
          if (code != 200) return http.Response('nope', code);
          return http.Response(
            jsonEncode({
              'data': [
                {'embedding': List.filled(768, 0.1)}
              ]
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seedMessage({
    String id = 'm1',
    String source = 'email',
    String body = 'Can we still ship on Thursday?',
    String receivedAt = '2026-08-29T10:00:00Z',
    String? summary,
    String? gateReason,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'subject': 'Re: Launch date',
      'from_name': 'Sarah',
      'from_address': 'sarah@x.com',
      'received_at': receivedAt,
      'body_text': body,
    });
    if (gateReason != null) {
      await store.writeTriage(source, id,
          status: 'skipped', gateReason: gateReason);
    } else if (summary != null) {
      await store.writeTriage(
        source,
        id,
        status: 'triaged',
        result: TriageResult(
          urgency: 'high',
          category: 'work',
          summary: summary,
          needsAction: true,
          actionItems: const ['Ship on Thursday'],
        ),
      );
    }
  }

  Future<Map<String, Object?>?> vectorRow(String id) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM message_vectors WHERE source_message_id = ?',
          variables: [Variable<String>(id)],
        )
        .get();
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first.data);
  }

  Future<void> runOne(EmbedHandler handler, {String id = 'm1'}) => handler.run(
        {'task_kind': 'embed_message', 'source': 'email', 'entity_id': id},
      );

  group('run', () {
    test('embeds one message into the document corpus', () async {
      await seedMessage(summary: 'Sarah is asking whether Thursday holds.');
      final server = FakeEmbedServer();

      await runOne(EmbedHandler(store, server.client));

      final row = (await vectorRow('m1'))!;
      expect(row['embed_model'], EmbeddingsClient.documentModelTag);
      expect(row['dims'], 768);
      // 768 float32s, the exact width vec0 was built for. A wrong-width blob
      // is refused by the index and the refusal is swallowed, so search would
      // simply go quiet.
      expect((row['embedding'] as Uint8List).lengthInBytes, 768 * 4);
      expect(row['received_at'], '2026-08-29T10:00:00Z');
      expect(row['embedded_at'], isNotNull);
      expect(row['embedded_hash'], isNotEmpty);

      // The document prefix, not the clustering one: a message vector that
      // landed in the conversation corpus is a vector search will never see.
      expect(
        server.inputs.single,
        startsWith(EmbeddingsClient.documentPrefix),
      );
      expect(server.inputs.single, contains('Launch date'));
      expect(server.inputs.single, contains('From: Sarah <sarah@x.com>'));
      expect(
        server.inputs.single,
        contains('Sarah is asking whether Thursday holds.'),
      );
    });

    test('a second pass over an unchanged message costs no call', () async {
      await seedMessage(summary: 'Thursday?');
      final server = FakeEmbedServer();

      await runOne(EmbedHandler(store, server.client));
      await runOne(EmbedHandler(store, server.client));

      expect(server.calls, 1, reason: 'the hash guard is what makes the '
          'sync-time enqueue free in the ordinary case');
    });

    test('a changed summary re-embeds', () async {
      await seedMessage(summary: 'Thursday?');
      final server = FakeEmbedServer();
      await runOne(EmbedHandler(store, server.client));
      final firstHash = (await vectorRow('m1'))!['embedded_hash'];

      await store.writeTriage(
        'email',
        'm1',
        status: 'triaged',
        result: const TriageResult(
          urgency: 'high',
          category: 'work',
          summary: 'Sarah wants the ship date confirmed today.',
          needsAction: true,
          actionItems: [],
        ),
      );
      await runOne(EmbedHandler(store, server.client));

      expect(server.calls, 2);
      expect((await vectorRow('m1'))!['embedded_hash'], isNot(firstHash));
    });

    test('a vector under the clustering tag is not trusted — it re-embeds',
        () async {
      // The self-heal half of the guard. A prefix or model change leaves rows
      // whose hash still matches; trusting them would leave them stranded in
      // the wrong space forever.
      await seedMessage(summary: 'Thursday?');
      final server = FakeEmbedServer();
      await runOne(EmbedHandler(store, server.client));
      final hash = (await vectorRow('m1'))!['embedded_hash'] as String;
      await store.upsertMessageVector(
        source: 'email',
        sourceMessageId: 'm1',
        embedding: Uint8List(768 * 4),
        dims: 768,
        embeddedHash: hash,
        embedModel: EmbeddingsClient.modelTag,
      );

      await runOne(EmbedHandler(store, server.client));

      expect(server.calls, 2);
      expect(
        (await vectorRow('m1'))!['embed_model'],
        EmbeddingsClient.documentModelTag,
      );
    });

    test('a server that is not running parks the kind and writes nothing',
        () async {
      await seedMessage(summary: 'Thursday?');
      final server = FakeEmbedServer(status: null);

      // The one outcome that must NOT spend an attempt: the item goes back to
      // pending, and only this kind stops draining.
      await expectLater(
        runOne(EmbedHandler(store, server.client)),
        throwsA(isA<LlmUnavailableException>()),
      );
      expect(await vectorRow('m1'), isNull);
    });

    test('a server that answers badly is done, not retried forever', () async {
      await seedMessage(summary: 'Thursday?');
      final server = FakeEmbedServer(status: 500);

      // Returns normally: the next attempt reads the same refusal, so the
      // worker may as well mark it done and move on.
      await runOne(EmbedHandler(store, server.client));

      expect(await vectorRow('m1'), isNull);
      expect(server.calls, 1);
    });

    test('a message that vanished is done, not failed', () async {
      final server = FakeEmbedServer();

      await runOne(EmbedHandler(store, server.client));

      expect(server.calls, 0);
      expect(await vectorRow('m1'), isNull);
    });

    test('a gated message never reaches the corpus', () async {
      // One sender's newsletters are alike enough that a handful of them
      // would crowd out real answers in every search.
      await seedMessage(gateReason: 'newsletter');
      final server = FakeEmbedServer();

      await runOne(EmbedHandler(store, server.client));

      expect(server.calls, 0);
      expect(await vectorRow('m1'), isNull);
    });

    test('a teams row skipped by birth still embeds', () async {
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 't1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Dana',
        'from_address': 'teams:u-1',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'Legal wants a look at the DPA.',
        'triage_status': 'skipped',
        'gate_reason': 'teams_source',
      });
      final server = FakeEmbedServer();

      await EmbedHandler(store, server.client).run(
        {'task_kind': 'embed_message', 'source': 'teams', 'entity_id': 't1'},
      );

      expect(await vectorRow('t1'), isNotNull);
      // A chat sender is a name and no address — a namespaced uuid is only a
      // distraction in the vector.
      expect(server.inputs.single, contains('From: Dana |'));
      expect(server.inputs.single, isNot(contains('teams:u-1')));
    });
  });

  group('enqueueEmbedBacklog', () {
    Future<List<String>> queued() async => [
          for (final row in await db
              .customSelect(
                "SELECT entity_id FROM work_items "
                "WHERE task_kind = 'embed_message' ORDER BY entity_id",
              )
              .get())
            row.data['entity_id'] as String,
        ];

    test('queues the inbound mail triage kept', () async {
      await seedMessage(id: 'a', summary: 'one');
      await seedMessage(id: 'b'); // still pending
      await seedMessage(id: 'c', gateReason: 'newsletter');

      final added = await store.enqueueEmbedBacklog(
        sinceIso: '2026-01-01T00:00:00Z',
      );

      expect(added, 2);
      expect(await queued(), ['a', 'b']);
    });

    test('a second call adds nothing — the sync may run it every time',
        () async {
      await seedMessage(id: 'a', summary: 'one');
      await store.enqueueEmbedBacklog(sinceIso: '2026-01-01T00:00:00Z');

      final again =
          await store.enqueueEmbedBacklog(sinceIso: '2026-01-01T00:00:00Z');

      expect(again, 0);
      expect(await queued(), ['a']);
    });

    test('finished work stays finished', () async {
      await seedMessage(id: 'a', summary: 'one');
      await store.enqueueEmbedBacklog(sinceIso: '2026-01-01T00:00:00Z');
      await store.writeWork('embed_message', 'email', 'a', status: 'done');

      await store.enqueueEmbedBacklog(sinceIso: '2026-01-01T00:00:00Z');

      expect(await store.workCounts('embed_message'), {'done': 1});
    });

    test('takes the newest first, up to the cap', () async {
      await seedMessage(id: 'old', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage(id: 'new', receivedAt: '2026-08-29T10:00:00Z');

      await store.enqueueEmbedBacklog(
        cap: 1,
        sinceIso: '2026-01-01T00:00:00Z',
      );

      expect(await queued(), ['new']);
    });

    test('leaves out everything older than the window', () async {
      await seedMessage(id: 'stale', receivedAt: '2026-01-02T10:00:00Z');
      await seedMessage(id: 'fresh', receivedAt: '2026-08-29T10:00:00Z');

      await store.enqueueEmbedBacklog(sinceIso: '2026-06-01T00:00:00Z');

      expect(await queued(), ['fresh']);
    });

    test('is per connector', () async {
      await seedMessage(id: 'm1');
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 't1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_name': 'Dana',
        'received_at': '2026-08-29T10:00:00Z',
        'body_text': 'hi',
      });

      await store.enqueueEmbedBacklog(
        sinceIso: '2026-01-01T00:00:00Z',
        source: 'teams',
      );

      expect(await queued(), ['t1']);
    });
  });
}
