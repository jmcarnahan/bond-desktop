import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/keyword_index.dart' show ContextKeywordIndex;
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart' show AiWorker;
import 'package:bond_inbox/services/context/context_digest_handler.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart'
    show EmbeddingsClient;
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'package:bond_inbox/services/search_fusion.dart' show buildFtsQuery;

import 'fixtures/fake_embed_server.dart';
import 'fixtures/vec_test_db.dart';

/// One fast-slot call per file, and the ladder of reasons not to make it.
///
/// The ladder is most of this file, because most of what this handler does
/// is decline: a file too short to be worth a call, a directory whose
/// summaries are switched off, a row somebody deleted between the enqueue
/// and the claim. Each rung has to close the row or deliberately leave it
/// open, and which one it does is the difference between a backlog that
/// drains and one that comes back on every pass.
class _FakeLlm extends LlmClient {
  _FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  final List<Object> script;
  final List<String> userMessages = [];
  final List<double> temperatures = [];
  final List<int> tokenBudgets = [];

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
    tokenBudgets.add(maxTokens);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final step = script.length > 1 ? script.removeAt(0) : script.first;
    // An `Error` as well as an `Exception`: a schema the model answered
    // outside of arrives here as a `StateError`, and that is the failure
    // this handler's last attempt has to close the file row for.
    if (step is! Map) throw step;
    return Map<String, dynamic>.from(step);
  }
}

/// An activity log that keeps what the handler told it. Most of the ladder
/// is only observable as a `skipped` and a reason.
class _Recorder extends ActivityLog {
  _Recorder() : super.disabled();

  final Map<String, Object?> notes = {};
  String? status;

  @override
  void note(Map<String, Object?> facts) => notes.addAll(facts);

  @override
  void noteStatus(String value) => status = value;
}

Map<String, dynamic> digestAnswer({
  String purpose = 'Works out what the Marrowfield renewal costs.',
  List<String> findings = const ['The renewal is 2,600 a month.'],
  List<String> questions = const ['What does the renewal cost?'],
  String kindHint = 'analysis',
}) =>
    {
      'purpose': purpose,
      'kind_hint': kindHint,
      'findings': findings,
      'questions_answered': questions,
      'inputs': const <String>[],
    };

void main() {
  late BondDatabase db;
  late ContextStore store;
  late FakeEmbedServer server;
  late _Recorder log;

  setUpAll(() => ensureSqliteVecLoaded());

  setUp(() {
    db = vecTestDb();
    store = ContextStore(db);
    server = FakeEmbedServer();
    log = _Recorder();
  });

  tearDown(() async => db.close());

  Future<String> register({bool digests = true}) async {
    final id = await store.registerDirectory(
      path: '/Users/wren/projects/atlas',
      displayName: 'atlas',
    );
    if (!digests) await store.setDirectoryOptions(id, digests: false);
    return id;
  }

  /// A file with [chars] characters of words, stored the way a walk stores
  /// them.
  Future<int> addFile(
    String dirId, {
    String relPath = 'analysis/pricing.md',
    String kind = 'doc',
    int chars = 400,
  }) async {
    final text = 'The Marrowfield renewal is 2,600 a month. '.padRight(
      chars,
      'x',
    );
    final id = await store.upsertFile(
      dirId: dirId,
      relPath: relPath,
      size: text.length,
      mtime: '2026-09-09T11:00:00Z',
      sha256: 'sha-$relPath',
      kind: kind,
      claudeChain: const [],
      textChars: text.length,
    );
    if (text.isNotEmpty) await store.setFileText(id, text);
    return id;
  }

  ContextDigestHandler handlerWith(
    List<Object> script, {
    FakeEmbedServer? embeddings,
  }) =>
      ContextDigestHandler(
        store,
        _FakeLlm(script),
        (embeddings ?? server).client,
        activityLog: log,
      );

  Future<void> runFor(
    ContextDigestHandler handler,
    String entityId,
  ) =>
      handler.run({
        'task_kind': 'context_digest',
        'source': 'local',
        'entity_id': entityId,
      });

  Future<List<Map<String, Object?>>> chunksOf(int fileId) async {
    final rows = await db
        .customSelect(
          'SELECT locator, chunk_text, embedding FROM context_chunks '
          'WHERE file_id = ? ORDER BY seq',
          variables: [Variable(fileId)],
        )
        .get();
    return [for (final row in rows) row.data];
  }

  group('the happy path', () {
    test('writes the digest, appends its passage and embeds it', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);
      final handler = handlerWith([digestAnswer()]);

      await runFor(handler, ContextDigestHandler.entityIdFor(dirId, fileId));

      final file = (await store.fileById(fileId))!;
      expect(file.digestStatus, 'done');
      final digest = ContextFileDigest.decode(file.digestJson)!;
      expect(digest.kindHint, 'analysis');
      expect(digest.findings, ['The renewal is 2,600 a month.']);

      final chunks = await chunksOf(fileId);
      expect(chunks, hasLength(1));
      expect(chunks.single['locator'], 'digest');
      // The chunker's own header convention: every stored passage opens with
      // `<relPath> · <locator>`, and the renderer strips that first line.
      expect(
        chunks.single['chunk_text'],
        startsWith('analysis/pricing.md · digest\n'),
      );
      expect(chunks.single['embedding'], isNotNull);
      expect(server.calls, 1);

      final indexed = await db
          .customSelect('SELECT COUNT(*) AS n FROM vec_context_chunks')
          .getSingle();
      expect(indexed.data['n'], 1);

      expect(log.status, isNull);
      expect(log.notes['kind_hint'], 'analysis');
      expect(log.notes['findings'], 1);
      expect(log.notes['questions'], 1);
    });

    test('the vector is of the passage that was stored', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);

      await runFor(
        handlerWith([digestAnswer()]),
        ContextDigestHandler.entityIdFor(dirId, fileId),
      );

      // The reconcile pass's tail embeds `chunk_text` verbatim when it picks
      // up a passage this handler left un-embedded, so the two paths have to
      // send the same string — or one row gets two different vectors
      // depending on which server was up the day it was written.
      final stored = (await chunksOf(fileId)).single['chunk_text'] as String;
      expect(
        server.inputs.single,
        '${EmbeddingsClient.documentPrefix}$stored',
      );
    });

    test('the call is deterministic and budgeted', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);
      final llm = _FakeLlm([digestAnswer()]);

      await ContextDigestHandler(store, llm, server.client, activityLog: log)
          .run({
        'source': 'local',
        'entity_id': ContextDigestHandler.entityIdFor(dirId, fileId),
      });

      expect(llm.temperatures, [0]);
      expect(llm.tokenBudgets, [512]);
      expect(llm.userMessages.single, contains('analysis/pricing.md (doc)'));
    });
  });

  group('the entity id', () {
    test('round-trips through its two halves', () {
      final id = ContextDigestHandler.entityIdFor('abc123', 42);
      expect(id, 'abc123|42');
      expect(ContextDigestHandler.splitEntityId(id), ('abc123', 42));
    });

    test('anything else reads as nothing', () {
      expect(ContextDigestHandler.splitEntityId(''), isNull);
      expect(ContextDigestHandler.splitEntityId('abc123'), isNull);
      expect(ContextDigestHandler.splitEntityId('abc123|'), isNull);
      expect(ContextDigestHandler.splitEntityId('|42'), isNull);
      expect(ContextDigestHandler.splitEntityId('abc123|nope'), isNull);
    });
  });

  group('the ladder', () {
    test('a queued row that names nothing is skipped as malformed', () async {
      final handler = handlerWith([digestAnswer()]);

      await runFor(handler, 'not-an-entity');

      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'malformed_entity');
    });

    test('a file that is gone is skipped', () async {
      final dirId = await register();
      final handler = handlerWith([digestAnswer()]);

      await runFor(handler, ContextDigestHandler.entityIdFor(dirId, 9999));

      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'gone');
    });

    test('a file belonging to another directory is skipped', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);
      final handler = handlerWith([digestAnswer()]);

      await runFor(handler, ContextDigestHandler.entityIdFor('other', fileId));

      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'gone');
    });

    test('summaries switched off leave the row pending, not closed', () async {
      // The switch can go back on, and when it does this file has to be
      // digested rather than skipped for the life of the row.
      final dirId = await register(digests: false);
      final fileId = await addFile(dirId);
      final handler = handlerWith([digestAnswer()]);

      await runFor(handler, ContextDigestHandler.entityIdFor(dirId, fileId));

      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'off');
      expect((await store.fileById(fileId))!.digestStatus, 'pending');
    });

    test('a digest already done costs nothing the second time', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);
      final llm = _FakeLlm([digestAnswer()]);
      final handler =
          ContextDigestHandler(store, llm, server.client, activityLog: log);
      final entity = ContextDigestHandler.entityIdFor(dirId, fileId);
      await runFor(handler, entity);

      log = _Recorder();
      await ContextDigestHandler(store, llm, server.client, activityLog: log)
          .run({'source': 'local', 'entity_id': entity});

      // The guard is what makes the reconcile pass's per-pass requeue
      // idempotent: it revives this row on every pass over a folder with a
      // backlog, and a file already digested must not cost a second call.
      expect(log.status, 'skipped');
      expect(log.notes['reason'], 'already_digested');
      expect(llm.calls, 1);
    });

    test('a file under two hundred characters is closed as too short',
        () async {
      final dirId = await register();
      final fileId = await addFile(dirId, chars: 120);
      final llm = _FakeLlm([digestAnswer()]);

      await ContextDigestHandler(store, llm, server.client, activityLog: log)
          .run({
        'source': 'local',
        'entity_id': ContextDigestHandler.entityIdFor(dirId, fileId),
      });

      // Closed on the ROW: a file this short will not grow words by being
      // asked again, and `pending` would put it back at the head of every
      // later pass.
      expect(log.notes['reason'], 'too_short');
      expect((await store.fileById(fileId))!.digestStatus, 'skipped');
      expect(llm.calls, 0);
    });

    test('a row that claims words the table does not have is closed',
        () async {
      final dirId = await register();
      final fileId = await store.upsertFile(
        dirId: dirId,
        relPath: 'analysis/empty.md',
        size: 400,
        mtime: '2026-09-09T11:00:00Z',
        sha256: 'sha-empty',
        kind: 'doc',
        claudeChain: const [],
        textChars: 400,
      );
      final llm = _FakeLlm([digestAnswer()]);

      await ContextDigestHandler(store, llm, server.client, activityLog: log)
          .run({
        'source': 'local',
        'entity_id': ContextDigestHandler.entityIdFor(dirId, fileId),
      });

      expect(log.notes['reason'], 'no_text');
      expect((await store.fileById(fileId))!.digestStatus, 'skipped');
      expect(llm.calls, 0);
    });
  });

  group('the servers', () {
    test('an embedding server that is down keeps the digest and does not '
        'throw', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);
      final dead = FakeEmbedServer(status: null);

      await runFor(
        handlerWith([digestAnswer()], embeddings: dead),
        ContextDigestHandler.entityIdFor(dirId, fileId),
      );

      // The model call is already paid for. Parking the kind here would put
      // it at risk of being spent twice.
      final file = (await store.fileById(fileId))!;
      expect(file.digestStatus, 'done');
      expect(file.digestJson, isNotNull);
      final chunks = await chunksOf(fileId);
      expect(chunks, hasLength(1));
      expect(chunks.single['embedding'], isNull);
      expect(log.status, isNull);
    });

    test('the digest passage is word-indexed with no vector at all', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);
      final dead = FakeEmbedServer(status: null);

      await runFor(
        handlerWith([digestAnswer()], embeddings: dead),
        ContextDigestHandler.entityIdFor(dirId, fileId),
      );

      // Read WITHOUT going through `keywordChunks`, which backfills on the
      // way in and would therefore pass whatever the handler did. What is
      // asserted is that the handler filed the passage itself: the word
      // index needs no vector, and the findings are the one passage of a
      // file phrased the way a question about it is.
      expect(await store.keywordIndexReady(), isTrue);
      final indexed = await db
          .customSelect('SELECT COUNT(*) AS n FROM '
              '${ContextKeywordIndex.table}')
          .getSingle();
      expect(indexed.data['n'], 1);

      final hits = await store.keywordChunks(
        buildFtsQuery('renewal')!,
        dirIds: [dirId],
        limit: 5,
      );
      expect([for (final hit in hits) hit.locator], contains('digest'));
    });

    test('a fast server that is down parks and leaves the digest pending',
        () async {
      final dirId = await register();
      final fileId = await addFile(dirId);

      await expectLater(
        runFor(
          handlerWith([const LlmUnavailableException('fast slot off')]),
          ContextDigestHandler.entityIdFor(dirId, fileId),
        ),
        throwsA(isA<LlmUnavailableException>()),
      );

      // Parked with no attempt spent: the file has to be digested by the
      // pass that finds the server back.
      expect((await store.fileById(fileId))!.digestStatus, 'pending');
      expect(await chunksOf(fileId), isEmpty);
    });
  });

  group('a model that cannot answer this file', () {
    /// The failing run, told which attempt it is — the count the work row
    /// carried BEFORE this one, which is what the worker hands a handler.
    Future<void> failOn(String dirId, int fileId, {required int attempts}) =>
        expectLater(
          handlerWith([StateError('bad answer')]).run({
            'task_kind': 'context_digest',
            'source': 'local',
            'entity_id': ContextDigestHandler.entityIdFor(dirId, fileId),
            'attempts': attempts,
          }),
          throwsA(isA<StateError>()),
        );

    test('the first failure leaves the file owed a digest', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);

      await failOn(dirId, fileId, attempts: 0);

      // There is a retry left, and the worker's own ladder owns it. Closing
      // the row here would throw away the second answer before it is asked
      // for.
      expect((await store.fileById(fileId))!.digestStatus, 'pending');
      expect(await store.filesPendingDigest(dirId), hasLength(1));
      expect(log.notes['digest_error'], isNull);
    });

    test('the last failure closes the file row and leaves the worklist',
        () async {
      final dirId = await register();
      final fileId = await addFile(dirId);

      await failOn(dirId, fileId, attempts: AiWorker.maxAttempts - 1);

      // The reconcile pass revives a `done` or `error` WORK row on every
      // sync, so the work row cannot be the memory that the model gave up.
      // The file row is, and `filesPendingDigest` reads `pending` only.
      expect((await store.fileById(fileId))!.digestStatus, 'error');
      expect(await store.filesPendingDigest(dirId), isEmpty);
      expect(log.notes['digest_error'], contains('bad answer'));
    });

    test('a rejected schema is fatal on the FIRST attempt, as it is for the '
        'worker', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);

      await expectLater(
        handlerWith([const LlmException('schema rejected', 400)]).run({
          'task_kind': 'context_digest',
          'source': 'local',
          'entity_id': ContextDigestHandler.entityIdFor(dirId, fileId),
          'attempts': 0,
        }),
        throwsA(isA<LlmException>()),
      );

      // A 400 is this app's schema being wrong, so the worker writes the
      // work row `error` on the first try. A file row still saying
      // `pending` against it is the loop this whole rung exists to close.
      expect((await store.fileById(fileId))!.digestStatus, 'error');
      expect(await store.filesPendingDigest(dirId), isEmpty);
    });

    test('an edit to the file puts it back on the worklist', () async {
      final dirId = await register();
      final fileId = await addFile(dirId);
      await failOn(dirId, fileId, attempts: AiWorker.maxAttempts - 1);

      // What the reconcile pass does to every file whose bytes moved.
      await store.resetFileDigest(fileId);

      expect(
        [for (final file in await store.filesPendingDigest(dirId)) file.id],
        [fileId],
      );
    });
  });
}
