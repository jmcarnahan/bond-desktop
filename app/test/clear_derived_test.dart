import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/attachment_chunk_index.dart';
import 'package:bond_inbox/data/context_chunk_index.dart';
import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/conversation_vec_index.dart';
import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/keyword_index.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/data/vec_index.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show attachmentEntityId;
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import 'fixtures/vec_test_db.dart';

/// The two resets behind Settings' Processing section.
///
/// `clearDerived` is the interesting one and most of this file: it has to
/// empty everything the pipeline wrote, keep everything it was written ABOUT,
/// and leave the mailbox in the state a first sync would have left it in —
/// pending, unjudged, and re-queued by the next poll rather than by a new
/// enqueue path. `wipeAll(keepIdentity: true)` is the bigger one, and what it
/// has to prove is that the person survives it.
///
/// The third subject is `quiesce()`: the reason a reset may delete the rows a
/// drain is holding claims on.

/// Every `?` bound positionally, the store's own `_args` in test form.
List<Variable> args(List<Object?> values) => [
      for (final value in values) Variable(value),
    ];

/// A [WorkHandler] that counts and can be held open at the server, so a
/// quiesce can land while an item is genuinely in flight.
class _Handler extends WorkHandler {
  @override
  final String kind;

  @override
  final int concurrency = 1;

  final FutureOr<void> Function(Map<String, Object?> item)? onRun;

  final List<String> seen = [];

  _Handler(this.kind, {this.onRun});

  @override
  Future<void> run(Map<String, Object?> item) async {
    seen.add(item['entity_id'] as String? ?? '');
    await onRun?.call(item);
  }
}

/// An [LlmClient] that answers one scripted verdict and can be held open.
///
/// Duplicated from `triage_queue_test.dart` rather than shared, on the house
/// rule the sync stubs follow: neither file may break the other by editing it.
class _FakeLlm extends LlmClient {
  _FakeLlm({this.hold}) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  final Future<void> Function()? hold;

  int calls = 0;

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
    calls++;
    await hold?.call();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return {
      'urgency': 'normal',
      'category': 'work',
      'summary': 'Sarah asks about the launch date.',
      'needs_action': false,
      'action_items': const <String>[],
      'reply_expected': false,
      'deadline': '',
    };
  }
}

// ── the scripted Graph, for the test that runs a whole sync ─────────
//
// Duplicated from `sync_extract_test.dart` for that file's stated reason.

class _InMemoryTokenStore implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

const String _grantedScopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

http.Response _jsonOk(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );

/// A Graph that has nothing new to say. The mail under test is already
/// stored, which is exactly the state a clear leaves behind.
MockClient _emptyGraph() => MockClient((request) async {
      if (request.url.path.endsWith('/oauth2/v2.0/token')) {
        return _jsonOk({
          'access_token': 'at-1',
          'refresh_token': 'rt-1',
          'expires_in': 3600,
          'scope': _grantedScopes,
          'token_type': 'Bearer',
        });
      }
      if (request.url.path.endsWith('/messages/delta')) {
        final folder =
            request.url.path.contains('sentitems') ? 'sentitems' : 'inbox';
        return _jsonOk({
          'value': const <Map<String, dynamic>>[],
          '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/me/mailFolders/'
              '$folder/messages/delta?\$deltatoken=empty',
        });
      }
      return http.Response('unexpected ${request.url}', 404);
    });

void main() {
  late BondDatabase db;
  late MessageStore store;
  late bool vecAvailable;

  setUpAll(() {
    vecAvailable = ensureSqliteVecLoaded();
    if (!vecAvailable) {
      printOnFailure(
        'sqlite-vec native asset missing — vec assertions skipped',
      );
    }
  });

  setUp(() {
    db = vecTestDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// Inside the one-day sync floor. Hours, never days: the floor is truncated
  /// to UTC midnight, so a fixture a whole day back straddles it.
  String fresh([Duration ago = const Duration(hours: 2)]) =>
      DateTime.now().toUtc().subtract(ago).toIso8601String();

  Future<int> rows(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .data['n'] as int;

  Future<Map<String, Object?>> messageRow(
    String id, {
    String source = 'email',
  }) async =>
      (await db
              .customSelect(
                'SELECT * FROM messages '
                'WHERE source = ? AND source_message_id = ?',
                variables: args([source, id]),
              )
              .getSingle())
          .data;

  Future<Map<String, Object?>> conversationRow(String key) async => (await db
          .customSelect(
            'SELECT * FROM conversations WHERE conversation_key = ?',
            variables: args([key]),
          )
          .getSingle())
      .data;

  /// One inbound mail message and its thread.
  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String conversationKey = 'conv-1',
    String direction = 'inbound',
    String subject = 'Invoice 4471 is overdue',
    String? triageStatus,
    String? gateReason,
    String? receivedAt,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': subject,
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': receivedAt ?? fresh(),
      'body_text': 'Body of $id',
      'triage_status': triageStatus ?? 'pending',
      'gate_reason': gateReason,
    });
  }

  /// A row in every one of the sixteen derived tables and all seven synced
  /// ones, so "emptied" and "kept" are both assertions about rows that were
  /// actually there. The awkward five go in as raw INSERTs: their writers take
  /// a reconcile pass or a notification sweep, and what this test is about is
  /// the DELETE, not the shape of the row.
  Future<void> seedEverything() async {
    // messages, conversations, message_progress (written by upsertMessage).
    await seedMessage('m1');
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'conv-1',
      'subject': 'Invoice 4471 is overdue',
      'participants_json': '["sarah@example.com"]',
      'state': 'needs_reply',
      'category': 'work',
      'cta_text': 'Pay the invoice',
      'cta_urgency': 'high',
      'message_count': 1,
      'inbound_count': 1,
      'last_message_at': fresh(),
    });
    await store.setDeltaLink('inbox', 'cursor-1');

    // The AI output.
    await store.enqueueWork('extract', 'email', 'm1');
    await store.writeExtraction('email', 'm1', '{"facts": []}');
    await store.upsertConversationAi(
      'email',
      'conv-1',
      embedding: encodeEmbedding(List<double>.filled(
        ConversationVectorIndex.dims,
        0.1,
      )),
      embeddedHash: 'hash-1',
      embedModel: EmbeddingsClient.modelTag,
    );
    await store.insertStoryline(
      id: 'st-1',
      title: 'The Q4 invoice',
      status: 'suggested',
      createdBy: 'auto',
    );
    await store.addStorylineMember('st-1', 'email', 'conv-1', addedBy: 'auto');
    await store.removeStorylineMember(
      'st-1',
      'email',
      'conv-2',
      block: true,
      evidence: 'a different effort',
    );
    await store.recordFeedback(
      scope: 'message',
      scopeKey: 'email/m1',
      direction: 'down',
      origin: 'explicit',
    );
    await store.recordActivity(kind: 'sync_mail', status: 'ok', count: 1);
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'conv-1',
      replyToMessageId: 'm1',
      body: 'Paying it today.',
    );
    await store.upsertMessageVector(
      source: 'email',
      sourceMessageId: 'm1',
      embedding: encodeEmbedding(
        List<double>.filled(MessageVectorIndex.dims, 0.1),
      ),
      dims: MessageVectorIndex.dims,
      embeddedHash: 'hash-m1',
      embedModel: EmbeddingsClient.documentModelTag,
    );
    await db.customUpdate(
      'INSERT INTO message_notify (source, source_message_id, '
      'conversation_key, state, deadline_at, created_at, updated_at) '
      "VALUES ('email', 'm1', 'conv-1', 'pending', ?, ?, ?)",
      variables: args([fresh(), fresh(), fresh()]),
    );

    // The attachment corpus: the metadata row is synced, its words and
    // passages are derived.
    await store.upsertAttachments('email', 'm1', [
      {'attachment_id': 'att-1', 'name': 'invoice.pdf', 'size': 1024},
    ]);
    await db.customUpdate(
      'INSERT INTO attachment_text (source, source_message_id, '
      'attachment_id, extracted_text, chars, fetched_at) '
      "VALUES ('email', 'm1', 'att-1', 'Invoice 4471', 12, ?)",
      variables: args([fresh()]),
    );
    await db.customUpdate(
      'INSERT INTO attachment_chunks (source, source_message_id, '
      'attachment_id, seq, locator, chunk_text, chars, embedding, dims, '
      'embed_model, embedded_at, created_at) '
      "VALUES ('email', 'm1', 'att-1', 0, 'page 1', 'Invoice 4471', 12, ?, ?, "
      '?, ?, ?)',
      variables: args([
        encodeEmbedding(List<double>.filled(AttachmentChunkIndex.dims, 0.1)),
        AttachmentChunkIndex.dims,
        EmbeddingsClient.documentModelTag,
        fresh(),
        fresh(),
      ]),
    );

    // The library: three synced tables and two derived ones.
    await db.customUpdate(
      'INSERT INTO context_dirs (id, path, display_name, status, brief_json, '
      'brief_hash, files_count, text_bytes, created_at, updated_at) '
      "VALUES ('dir-1', '/tmp/project', 'project', 'ready', "
      "'{\"brief\": \"x\"}', 'brief-hash', 1, 12, ?, ?)",
      variables: args([fresh(), fresh()]),
    );
    await db.customUpdate(
      'INSERT INTO context_links (dir_id, scope_kind, source, scope_key, '
      "added_at) VALUES ('dir-1', 'thread', 'email', 'conv-1', ?)",
      variables: args([fresh()]),
    );
    await db.customUpdate(
      'INSERT INTO context_files (id, dir_id, rel_path, size, mtime, sha256, '
      'digest_json, digest_status, desc_embedding, text_chars, seen_at, '
      'updated_at) '
      "VALUES (1, 'dir-1', 'README.md', 120, '2026-09-18T10:00:00Z', "
      "'abc123', '{\"digest\": \"x\"}', 'done', ?, 10, ?, ?)",
      variables: args([
        encodeEmbedding(const [0.1, 0.2]),
        fresh(),
        fresh(),
      ]),
    );
    await db.customUpdate(
      'INSERT INTO context_text (file_id, extracted_text, chars) '
      "VALUES (1, 'the readme', 10)",
    );
    await db.customUpdate(
      'INSERT INTO context_chunks (file_id, seq, locator, chunk_text, chars, '
      "created_at) VALUES (1, 0, 'lines 1-10', 'the readme', 10, ?)",
      variables: args([fresh()]),
    );

    // Configuration, which neither reset may touch.
    await store.setSenderPref('eric@example.com', 'later');
    await store.setPref('backend_mode', 'sdk');
    await store.setPref(dbOwnerKey, 'ada@example.com');
    await store.setPref(aboutMeKey, 'An analyst in Denver');
    await store.setPref(needsYouRulesKey, 'Invoices always need me');
    await db.customUpdate(
      "INSERT INTO setup_state (\"key\", value, updated_at) "
      "VALUES ('setup', 'done', ?)",
      variables: args([fresh()]),
    );
  }

  group('the three table lists', () {
    test('classify every table in schema.drift exactly once', () async {
      // Tests run from `app/`, and the schema is the authority — a table
      // added without a classification fails here rather than being silently
      // kept forever by both resets.
      final sql = File('lib/data/schema.drift').readAsStringSync();
      final declared = {
        for (final match in RegExp(r'CREATE TABLE (\w+)').allMatches(sql))
          match.group(1)!,
      };
      final classified = [
        ...MessageStore.derivedTables,
        ...MessageStore.syncedTables,
        ...MessageStore.keptTables,
      ];

      expect(declared, isNotEmpty);
      expect(classified.toSet(), equals(declared));
      // Pairwise disjoint, which the set comparison above cannot see.
      expect(classified.length, classified.toSet().length);
      expect(MessageStore.derivedTables, hasLength(16));
      expect(MessageStore.syncedTables, hasLength(7));
      expect(MessageStore.keptTables, hasLength(3));
    });

    test('name every retired clustering one-shot', () {
      // The keys live beside their tags in `sync_service.dart` and are spelled
      // again in the store, which imports nothing above itself. This is what
      // keeps a third retired tag from being left set over vectors the clear
      // has just deleted.
      for (final retired in retiredClusteringTags) {
        expect(
          MessageStore.derivedOneShotPrefs,
          contains(retired.prefKey),
          reason: '${retired.prefKey} survives a clear and would tell the '
              'next sync the re-embed had already run',
        );
      }
    });
  });

  group('clearDerived', () {
    test('empties every derived table and no synced one', () async {
      await seedEverything();
      for (final table in [
        ...MessageStore.derivedTables,
        ...MessageStore.syncedTables,
      ]) {
        expect(
          await rows(table),
          greaterThan(0),
          reason: '$table was not seeded',
        );
      }

      await store.clearDerived();

      for (final table in MessageStore.derivedTables) {
        // The one exception, and it is emptied in the same transaction:
        // `message_progress` is rebuilt from `messages` on the way out,
        // because nothing downstream ever inserts into it. Its own test is
        // below.
        if (table == 'message_progress') continue;
        // The other exception, and the one enqueue this reset owes itself:
        // `work_items` is emptied and then holds the attachment text the
        // sync has no backlog call for. Its own test is below.
        if (table == 'work_items') continue;
        expect(await rows(table), 0, reason: '$table is the pipeline\'s own');
      }
      expect(await rows('message_progress'), await rows('messages'));
      expect(
        await store.workCounts('attachment_text'),
        {'pending': 1},
        reason: 'the only work a clear queues for itself',
      );
      expect(await store.workCounts('extract'), isEmpty);
      for (final table in MessageStore.syncedTables) {
        expect(
          await rows(table),
          greaterThan(0),
          reason: '$table came off a server or off this disk and cannot be '
              'recomputed',
        );
      }
      // And the cursors, which are the reason a sign-out has to delete
      // `sync_state` and a clear must not: re-fetching the mailbox is not
      // what this button promises.
      expect(await store.getDeltaLink('inbox', source: 'email'), 'cursor-1');
    });

    test('keeps the sign-in and every preference', () async {
      await seedEverything();

      await store.clearDerived();

      expect(await store.getPref(dbOwnerKey), 'ada@example.com');
      expect(await store.getPref(aboutMeKey), 'An analyst in Denver');
      expect(await store.getPref(needsYouRulesKey), 'Invoices always need me');
      expect(await store.getPref('backend_mode'), 'sdk');
      expect(await store.getSenderPref('eric@example.com'), 'later');
      expect(await rows('setup_state'), 1);
    });

    test('keeps the verdicts ingest wrote and re-pends the rest', () async {
      // The four ingest wrote, which nothing would write a second time.
      await seedMessage('out-1',
          direction: 'outbound',
          triageStatus: 'skipped',
          gateReason: 'outbound');
      await seedMessage('old-1',
          conversationKey: 'conv-old',
          triageStatus: 'skipped',
          gateReason: 'backlog');
      await seedMessage('bot-1',
          source: 'teams',
          conversationKey: 'chat-1',
          triageStatus: 'skipped',
          gateReason: 'auto_generated');
      await seedMessage('chat-1',
          source: 'teams',
          conversationKey: 'chat-1',
          triageStatus: 'skipped',
          gateReason: 'teams_source');
      // The owner's own Ignore, which nothing recomputes on a claim.
      await seedMessage('ignored-1',
          conversationKey: 'conv-ignored',
          triageStatus: 'skipped',
          gateReason: 'user');
      // The ones the triage claim re-derives every time.
      await seedMessage('news-1',
          conversationKey: 'conv-news',
          triageStatus: 'skipped',
          gateReason: 'newsletter');
      await seedMessage('auto-1',
          conversationKey: 'conv-auto',
          triageStatus: 'skipped',
          gateReason: 'auto_generated');

      await store.clearDerived();

      Future<void> expectKept(String id, String reason,
          {String source = 'email'}) async {
        final row = await messageRow(id, source: source);
        expect(row['triage_status'], 'skipped', reason: id);
        expect(row['gate_reason'], reason, reason: id);
      }

      Future<void> expectRepended(String id) async {
        final row = await messageRow(id);
        expect(row['triage_status'], 'pending', reason: id);
        expect(row['gate_reason'], isNull, reason: id);
      }

      await expectKept('out-1', 'outbound');
      await expectKept('ignored-1', 'user');
      await expectKept('old-1', 'backlog');
      await expectKept('bot-1', 'auto_generated', source: 'teams');
      await expectKept('chat-1', 'teams_source', source: 'teams');
      await expectRepended('news-1');
      // The mail header gate writes the same word the Teams bot gate does, so
      // the `source` half of the predicate is what tells them apart.
      await expectRepended('auto-1');
    });

    test('leaves a message the owner ignored ignored', () async {
      // `dropMessage` is the Ignore button, and its verdict is the owner's,
      // not the pipeline's: nothing recomputes `gate_reason = 'user'` on a
      // later claim, so clearing it would silently put mail they threw out
      // by hand back in front of them.
      await seedMessage('m1');
      expect(await store.dropMessage('email', 'm1'), isTrue);

      await store.clearDerived();

      final row = await messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'user');
      // And its progress row says the same thing the drop said.
      final progress = (await db
              .customSelect(
                'SELECT * FROM message_progress WHERE source_message_id = ?',
                variables: args(['m1']),
              )
              .getSingle())
          .data;
      expect(progress['dropped'], 1);
      expect(progress['drop_reason'], 'user');
    });

    test('queues the attachment words again, and not a refusal', () async {
      await seedEverything();
      await db.customUpdate(
        "UPDATE attachments SET text_status = 'done', text_chars = 12",
      );
      await store.upsertAttachments('email', 'm1', [
        {'attachment_id': 'att-2', 'name': 'photo.png'},
      ]);
      await db.customUpdate(
        "UPDATE attachments SET text_status = 'skipped', "
        "text_reason = 'unsupported' WHERE attachment_id = 'att-2'",
      );

      await store.clearDerived();

      // The one enqueue this reset owes itself: `attachment_text` is queued at
      // ingest, by a detail fetch and by Restore, and a stored message with a
      // body reaches none of the three — so without this the words would
      // never be read again.
      final queued = [
        for (final row in await db
            .customSelect(
              'SELECT entity_id FROM work_items '
              "WHERE task_kind = 'attachment_text' ORDER BY entity_id",
            )
            .get())
          row.data['entity_id'] as String,
      ];
      // Composed in SQL by the store, and this is what pins that spelling to
      // the one the ingest and the handler use.
      expect(queued, [attachmentEntityId('m1', 'att-1')]);
      expect(
        await store.workCounts('attachment_text'),
        {'pending': 1},
      );
    });

    test('keeps the owner\'s own restore and clears every verdict column',
        () async {
      await seedMessage('m1', triageStatus: 'triaged');
      await db.customUpdate(
        "UPDATE messages SET gate_override = 'user', triage_attempts = 3, "
        "triage_error = 'boom', urgency = 'critical', category = 'work', "
        "summary = 'An old summary', needs_action = 1, "
        "action_items_json = '[]', label = 'work', reply_expected = 1, "
        "deadline = 'Friday', needs_you_verdict = 1, "
        "needs_you_reason = 'addressed you', addressed_me = 1",
      );

      await store.clearDerived();

      final row = await messageRow('m1');
      // Durable user intent, and the one thing on this row a reset may not
      // touch.
      expect(row['gate_override'], 'user');
      // A fact about the message rather than a verdict about it: ingest wrote
      // it and ingest is what would write it again.
      expect(row['addressed_me'], 1);
      expect(row['triage_status'], 'pending');
      expect(row['triage_attempts'], 0);
      for (final column in [
        'triage_error',
        'urgency',
        'category',
        'summary',
        'needs_action',
        'action_items_json',
        'label',
        'reply_expected',
        'deadline',
        'needs_you_verdict',
        'needs_you_reason',
      ]) {
        expect(row[column], isNull, reason: column);
      }
    });

    test('resets cta_urgency to the word, never to NULL', () async {
      await seedEverything();

      await store.clearDerived();

      final row = await conversationRow('conv-1');
      // `TEXT NOT NULL DEFAULT 'normal'` under STRICT: a NULL here would have
      // thrown rather than failed this assertion.
      expect(row['cta_urgency'], 'normal');
      expect(row['cta_text'], isNull);
      expect(row['category'], isNull);
    });

    test('re-folds every thread, raising as well as lowering', () async {
      // A thread a gate wrongly settled: its only inbound message was gated,
      // so the fold lowered it to `waiting`. Clearing the gate has to be able
      // to put it back — which the one-shot repair, which walks `needs_reply`
      // rows alone, never could.
      await seedMessage('m1',
          triageStatus: 'skipped', gateReason: 'newsletter');
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'conv-1',
        'subject': 'Invoice',
        'state': 'waiting',
        'message_count': 1,
        'inbound_count': 1,
        'last_message_at': fresh(),
      });
      // And a thread the user finished, which nothing in the pipeline
      // outranks.
      await seedMessage('m2', conversationKey: 'conv-done');
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'conv-done',
        'subject': 'Settled',
        'state': 'done',
        'message_count': 1,
        'inbound_count': 1,
        'last_message_at': fresh(),
      });

      await store.clearDerived();

      expect((await conversationRow('conv-1'))['state'], 'needs_reply');
      expect((await conversationRow('conv-done'))['state'], 'done');
    });

    test('rebuilds one progress row per message, gated rows finished',
        () async {
      // The one derived table nothing downstream recreates: every stage
      // writes it with an UPDATE, and the only INSERT is the ingest's, which
      // an already-stored message never reaches again. Emptied and not
      // rebuilt, the home feed would be empty until the mailbox was re-synced
      // — which for stored mail never happens.
      await seedMessage('m1');
      await seedMessage('out-1',
          direction: 'outbound',
          triageStatus: 'skipped',
          gateReason: 'outbound');
      await db.customUpdate(
        "UPDATE message_progress SET triage_state = 'done', "
        "extract_state = 'done', outcome = 'settled'",
      );

      await store.clearDerived();

      expect(await rows('message_progress'), 2);
      final kept = (await db
              .customSelect(
                'SELECT * FROM message_progress WHERE source_message_id = ?',
                variables: args(['m1']),
              )
              .getSingle())
          .data;
      expect(kept['ingest_state'], 'done');
      expect(kept['triage_state'], 'pending');
      expect(kept['extract_state'], 'pending');
      expect(kept['outcome'], 'pending');
      expect(kept['dropped'], 0);

      final gated = (await db
              .customSelect(
                'SELECT * FROM message_progress WHERE source_message_id = ?',
                variables: args(['out-1']),
              )
              .getSingle())
          .data;
      // A row the gate threw out is finished, not waiting on four stages
      // nothing will ever run — the shape the ingest gives it.
      expect(gated['triage_state'], 'skipped');
      expect(gated['outcome'], 'dropped');
      expect(gated['dropped'], 1);
      expect(gated['drop_reason'], 'outbound');
    });

    test('re-opens the attachment passes and keeps a refusal refused',
        () async {
      await seedEverything();
      await db.customUpdate(
        "UPDATE attachments SET text_status = 'done', text_chars = 12, "
        "digest_status = 'done', digest_json = '{}'",
      );
      await store.upsertAttachments('email', 'm1', [
        {'attachment_id': 'att-2', 'name': 'photo.png'},
      ]);
      await db.customUpdate(
        "UPDATE attachments SET text_status = 'skipped', "
        "text_reason = 'unsupported' WHERE attachment_id = 'att-2'",
      );

      await store.clearDerived();

      final done = (await db
              .customSelect(
                "SELECT * FROM attachments WHERE attachment_id = 'att-1'",
              )
              .getSingle())
          .data;
      // The words are gone, so the marker that says they were read has to go
      // with them or the handler skips the file as `already_extracted` and
      // nothing is ever re-read.
      expect(done['text_status'], 'pending');
      expect(done['text_chars'], 0);
      expect(done['digest_status'], 'pending');
      expect(done['digest_json'], isNull);
      expect(done['name'], 'invoice.pdf');

      final refused = (await db
              .customSelect(
                "SELECT * FROM attachments WHERE attachment_id = 'att-2'",
              )
              .getSingle())
          .data;
      // A refusal is a standing verdict about the FILE, not about the model
      // that read it: re-attempting it spends the same call for the same no.
      expect(refused['text_status'], 'skipped');
      expect(refused['text_reason'], 'unsupported');
    });

    test('nulls the derived columns on the library and keeps the rows',
        () async {
      await seedEverything();

      await store.clearDerived();

      final dir = (await db
              .customSelect('SELECT * FROM context_dirs')
              .getSingle())
          .data;
      expect(dir['path'], '/tmp/project');
      expect(dir['brief_json'], isNull);
      expect(dir['brief_hash'], isNull);

      final file =
          (await db.customSelect('SELECT * FROM context_files').getSingle())
              .data;
      expect(file['rel_path'], 'README.md');
      expect(file['digest_json'], isNull);
      expect(file['digest_status'], 'pending');
      expect(file['desc_embedding'], isNull);
      // The reconcile's cheap diff, back at its defaults. A file whose stat
      // still matched would never be opened again, and the passages this
      // just deleted would never be written a second time.
      expect(file['size'], 0);
      expect(file['mtime'], '');
      expect(file['sha256'], '');
      // And the count of words in `context_text`, which the same clear just
      // emptied: a stale one is a row claiming a file was read.
      expect(file['text_chars'], 0);
    });

    test('clears the derived one-shots and keeps the synced ones', () async {
      for (final key in [
        ...MessageStore.derivedOneShotPrefs,
        'backfill_addressed_me_email',
        'backfill_addressed_me_teams',
        'sender_tip_strip',
        'participant_names_backfill',
        mailLastReconcileKey,
        activityLastSyncMailKey,
      ]) {
        await store.setPref(key, '1');
      }

      await store.clearDerived();

      for (final key in MessageStore.derivedOneShotPrefs) {
        expect(await store.getPref(key), isNull, reason: key);
      }
      for (final key in [
        // All four write SYNCED columns, which this reset does not touch.
        'backfill_addressed_me_email',
        'backfill_addressed_me_teams',
        'sender_tip_strip',
        'participant_names_backfill',
        // And these describe the sync, which has not been undone.
        mailLastReconcileKey,
        activityLastSyncMailKey,
      ]) {
        expect(await store.getPref(key), '1', reason: key);
      }
    });

    test('leaves the vec and the word indexes empty', () async {
      if (!vecAvailable) return;
      await seedEverything();
      // Filed rather than merely stored: the assertion is about the shadow
      // tables a DELETE cannot reach.
      expect(await store.indexPendingVectors(), 1);
      expect(
        await store.prepareConversationIndex(
          embedModel: EmbeddingsClient.modelTag,
        ),
        1,
      );
      expect(await store.indexPendingChunks(), 1);
      // The search is what builds the word index, and it also proves the
      // corpus was findable before the clear.
      expect(
        (await store.keywordSearchMessages('invoice'))?.length,
        1,
      );
      expect(await store.keywordSearchChunks('invoice'), isNotEmpty);
      expect(await rows('vec_messages'), 1);
      expect(await rows('vec_conversations'), 1);
      expect(await rows('vec_attachment_chunks'), 1);
      expect(await rows(MessageKeywordIndex.table), 1);

      await store.clearDerived();

      expect(await rows('vec_messages'), 0);
      expect(await rows('vec_conversations'), 0);
      expect(await rows('vec_attachment_chunks'), 0);
      expect(await rows(MessageKeywordIndex.table), 0);
      expect(await rows(ChunkKeywordIndex.table), 0);
      // The message half of the word index is derived from rows the clear
      // KEPT, so the next search rebuilds it and finds the mail again. That
      // is the point of keeping the mail.
      expect((await store.keywordSearchMessages('invoice'))?.length, 1);
      // The chunk half has nothing to come back from.
      expect(await store.keywordSearchChunks('invoice'), isEmpty);
    });

    test('the context chunk index is emptied by the pair the host runs',
        () async {
      if (!vecAvailable) return;
      // `clearDerived` cannot reach `vec_context_chunks`: that index belongs
      // to `ContextStore`, and the host calls `rebuildIndexes()` on it right
      // after the clear (`_resetPipeline`). This pins the pair, which is the
      // fourth vec table the test above cannot see.
      final context = ContextStore(db);
      final dirId = await context.registerDirectory(
        path: '/Users/wren/projects/atlas',
        displayName: 'atlas',
      );
      final fileId = await context.upsertFile(
        dirId: dirId,
        relPath: 'notes.md',
        size: 13,
        mtime: '2026-09-09T11:00:00Z',
        sha256: 'sha-notes',
        kind: 'doc',
        claudeChain: const [],
        textChars: 13,
      );
      await context.setFileText(fileId, 'invoice notes');
      final chunkId = await context.appendChunk(
        fileId,
        locator: 'p1',
        text: 'invoice notes',
      );
      await context.setChunkEmbedding(
        chunkId,
        embedding: encodeEmbedding(
          List<double>.filled(ContextChunkIndex.dims, 0.1),
        ),
        dims: ContextChunkIndex.dims,
        embedModel: EmbeddingsClient.documentModelTag,
      );
      expect(await context.indexPendingChunks(), 1);
      expect(await rows('vec_context_chunks'), 1);

      await store.clearDerived();
      // Still there after the clear alone: this is the half the store cannot
      // reach, and the proof that the rebuild is what empties it.
      expect(await rows('vec_context_chunks'), 1);
      await context.rebuildIndexes();

      expect(await rows('vec_context_chunks'), 0);
      // And the passage itself is gone with the rest of the derived text, so
      // nothing refills the index until the file is chunked again.
      expect(await rows('context_chunks'), 0);
    });

    test('the next sync re-enqueues every kept message', () async {
      await seedMessage('m1');
      await seedMessage('m2', conversationKey: 'conv-2');
      await store.enqueueWork('extract', 'email', 'm1');
      await store.writeWork('extract', 'email', 'm1', status: 'done');

      await store.clearDerived();
      expect(await rows('work_items'), 0);

      // No new enqueue path: the sync's own idempotent backlog calls are what
      // refill the queue, one `backlogEnqueueCap` slice a poll.
      final tokens = _InMemoryTokenStore();
      tokens.values['refresh_token'] = 'rt-initial';
      tokens.values['granted_scopes'] = _grantedScopes;
      final graph = _emptyGraph();
      final sync = SyncService(
        GraphMail(GraphAuth(httpClient: graph, store: tokens),
            httpClient: graph),
        store,
      );

      await sync.syncNow();

      expect(await store.workCounts('extract'), {'pending': 2});
      expect(await store.workCounts('needs_you'), {'pending': 2});
      expect(await store.workCounts('embed_message'), {'pending': 2});
      // And the sweep, which is the sync's durable trigger for the clustering
      // pass the clear just emptied.
      expect((await store.workCounts('storyline_sweep'))['pending'], 1);
    });
  });

  group('wipeAll', () {
    test('keepIdentity keeps the person and deletes the mailbox', () async {
      await seedEverything();
      await store.setPref(mailBootstrapFloorKey, '2026-08-23T00:00:00Z');

      await store.wipeAll(keepIdentity: true);

      // The person.
      expect(await store.getPref(dbOwnerKey), 'ada@example.com');
      expect(await store.getPref(aboutMeKey), 'An analyst in Denver');
      expect(await store.getPref(needsYouRulesKey), 'Invoices always need me');
      expect(await store.getSenderPref('eric@example.com'), 'later');
      expect(await store.getPref('backend_mode'), 'sdk');
      // The mailbox.
      expect(await rows('messages'), 0);
      expect(await rows('conversations'), 0);
      expect(await rows('attachments'), 0);
      expect(await rows('storylines'), 0);
      expect(await store.getDeltaLink('inbox', source: 'email'), isNull);
      // And the floor, so the next poll fetches the window again rather than
      // reading it as already drained.
      expect(await store.getPref(mailBootstrapFloorKey), isNull);
    });

    test('takes every one-shot marker with it, either way', () async {
      // A wipe deletes strictly more than a clear does, so a marker that
      // survived it would tell the next account's first sync that a catch-up
      // had already run over a mailbox that no longer exists.
      for (final key in [
        ...MessageStore.derivedOneShotPrefs,
        'sender_tip_strip',
      ]) {
        await store.setPref(key, '1');
      }

      await store.wipeAll(keepIdentity: true);

      for (final key in MessageStore.derivedOneShotPrefs) {
        expect(await store.getPref(key), isNull, reason: key);
      }
    });

    test('with no argument it still takes the person with it', () async {
      await seedEverything();

      await store.wipeAll();

      expect(await store.getPref(dbOwnerKey), isNull);
      expect(await store.getPref(aboutMeKey), isNull);
      expect(await store.getPref(needsYouRulesKey), isNull);
      expect(await store.getSenderPref('eric@example.com'), isNull);
      expect(await store.getPref('backend_mode'), 'sdk');
      expect(await rows('messages'), 0);
    });

    test('leaves the registered directories alone, either way', () async {
      await seedEverything();

      await store.wipeAll(keepIdentity: true);

      // Machine configuration and the user's own folders, not this mailbox's
      // data — the sign-out path unlinks them and leaves the rows standing.
      for (final table in [
        'context_dirs',
        'context_links',
        'context_files',
        'context_text',
        'context_chunks',
        'setup_state',
      ]) {
        expect(await rows(table), greaterThan(0), reason: table);
      }
    });
  });

  group('quiesce', () {
    test('finishes the work item in flight and leaves the queue drainable',
        () async {
      for (final id in ['a', 'b', 'c']) {
        await store.enqueueWork('extract', 'email', id);
      }
      final held = Completer<void>();
      final handler = _Handler('extract', onRun: (_) => held.future);
      final worker = AiWorker(store, handlers: [handler]);

      final drain = worker.pump();
      // Long enough for the first item to be claimed and at the server.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final quiet = worker.quiesce();
      held.complete();
      await quiet;
      await drain;

      // The answer already paid for is written, and nothing is left claimed:
      // a `processing` row pointing at work a reset is about to delete is the
      // whole reason this method exists.
      expect(handler.seen, hasLength(1));
      expect(await store.workCounts('extract'), {'done': 1, 'pending': 2});

      // Reusable, which is the difference from `dispose`.
      await worker.pump();
      expect(handler.seen, hasLength(3));
      expect(await store.workCounts('extract'), {'done': 3});
    });

    test('hands back a triage claim and leaves the queue drainable', () async {
      await seedMessage('m1');
      await seedMessage('m2', conversationKey: 'conv-2');
      final held = Completer<void>();
      var first = true;
      final llm = _FakeLlm(hold: () {
        if (!first) return Future<void>.value();
        first = false;
        return held.future;
      });
      final queue = TriageQueue(store, llm, concurrency: 1);
      addTearDown(queue.dispose);

      final drain = queue.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final quiet = queue.quiesce();
      held.complete();
      await quiet;
      await drain;

      final statuses = [
        for (final id in ['m1', 'm2']) (await messageRow(id))['triage_status'],
      ];
      // One verdict written, one message untouched, and nothing left
      // `processing`.
      expect(statuses.where((s) => s == 'triaged'), hasLength(1));
      expect(statuses.where((s) => s == 'pending'), hasLength(1));

      await queue.pump();
      expect(llm.calls, 2);
      for (final id in ['m1', 'm2']) {
        expect((await messageRow(id))['triage_status'], 'triaged');
      }
    });

    test('a worker pump landing mid-quiesce does not lift the stop and resume',
        () async {
      for (final id in ['a', 'b', 'c']) {
        await store.enqueueWork('extract', 'email', id);
      }
      final held = Completer<void>();
      final handler = _Handler('extract', onRun: (_) => held.future);
      final worker = AiWorker(store, handlers: [handler]);

      final drain = worker.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final quiet = worker.quiesce();
      // The race: a sync's pump (or an ON) while quiesce waits on the item in
      // flight. Before the latch it cleared `_stopped` and the drain went on
      // claiming under `_claimed.clear()`.
      final late = worker.pump();
      held.complete();
      await quiet;
      await drain;
      await late;

      expect(handler.seen, hasLength(1));
      expect(await store.workCounts('extract'), {'done': 1, 'pending': 2});

      // And the worker is still reusable once quiesce has returned.
      await worker.pump();
      expect(handler.seen, hasLength(3));
    });

    test('a triage pump landing mid-quiesce does not lift the stop and resume',
        () async {
      await seedMessage('m1');
      await seedMessage('m2', conversationKey: 'conv-2');
      final held = Completer<void>();
      var first = true;
      final llm = _FakeLlm(hold: () {
        if (!first) return Future<void>.value();
        first = false;
        return held.future;
      });
      final queue = TriageQueue(store, llm, concurrency: 1);
      addTearDown(queue.dispose);

      final drain = queue.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final quiet = queue.quiesce();
      final late = queue.pump();
      held.complete();
      await quiet;
      await drain;
      await late;

      final statuses = [
        for (final id in ['m1', 'm2']) (await messageRow(id))['triage_status'],
      ];
      expect(statuses.where((s) => s == 'triaged'), hasLength(1));
      expect(statuses.where((s) => s == 'pending'), hasLength(1));
      expect(llm.calls, 1);

      await queue.pump();
      expect(llm.calls, 2);
    });

    test('two concurrent worker quiesces are one run, and both see it out',
        () async {
      for (final id in ['a', 'b', 'c']) {
        await store.enqueueWork('extract', 'email', id);
      }
      final held = Completer<void>();
      final handler = _Handler('extract', onRun: (_) => held.future);
      final worker = AiWorker(store, handlers: [handler]);

      final drain = worker.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The reachable pair: the reset host quiescing, and a `dispose` fired by
      // an invalidation inside the reset window. Two runs would race on the
      // `finally`, and whichever finished first would drop the latch while the
      // other was still handing claims back.
      final first = worker.quiesce();
      final second = worker.quiesce();
      expect(first, same(second));

      // Still one stop for both of them: a pump landing while either caller is
      // outstanding claims nothing.
      final late = worker.pump();
      held.complete();
      await first;
      await second;
      await drain;
      await late;

      expect(handler.seen, hasLength(1));
      expect(await store.workCounts('extract'), {'done': 1, 'pending': 2});

      // The memo is released with the run, so the next reset gets a real
      // quiesce rather than a future that completed minutes ago.
      final again = worker.quiesce();
      expect(again, isNot(same(first)));
      await again;

      await worker.pump();
      expect(handler.seen, hasLength(3));
    });

    test('two concurrent triage quiesces are one run, and both see it out',
        () async {
      await seedMessage('m1');
      await seedMessage('m2', conversationKey: 'conv-2');
      final held = Completer<void>();
      var first = true;
      final llm = _FakeLlm(hold: () {
        if (!first) return Future<void>.value();
        first = false;
        return held.future;
      });
      final queue = TriageQueue(store, llm, concurrency: 1);
      addTearDown(queue.dispose);

      final drain = queue.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final quiet = queue.quiesce();
      final alsoQuiet = queue.quiesce();
      expect(quiet, same(alsoQuiet));

      final late = queue.pump();
      held.complete();
      await quiet;
      await alsoQuiet;
      await drain;
      await late;

      final statuses = [
        for (final id in ['m1', 'm2']) (await messageRow(id))['triage_status'],
      ];
      expect(statuses.where((s) => s == 'triaged'), hasLength(1));
      expect(statuses.where((s) => s == 'pending'), hasLength(1));
      expect(llm.calls, 1);

      final again = queue.quiesce();
      expect(again, isNot(same(quiet)));
      await again;

      await queue.pump();
      expect(llm.calls, 2);
    });
  });
}
