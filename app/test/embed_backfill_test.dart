import 'dart:convert';
import 'dart:typed_data';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/attachments/attachment_policy.dart'
    show attachmentEntityId;
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
// `show`: the one thing this file wants from the embedding client is the tag
// the four search corpora are being moved ONTO.
import 'package:bond_inbox/services/llm/embeddings_client.dart'
    show EmbeddingsClient;
import 'package:bond_inbox/services/sync_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/vec_test_db.dart';

/// The tag-keyed backfill of the four SEARCH corpora.
///
/// The model under the embedding server moved on 2026-09-19, and the search
/// side of that swap shipped without a catch-up: every read of the four
/// corpora filters on `documentModelTag`, so a vector written under the old
/// model is invisible rather than wrong, and the three worklists that would
/// have refilled them key on `embedding IS NULL` and never on the tag. So
/// nothing ever did. Four one-shots in `sync_service.dart` are the catch-up,
/// and this file is what each of them promises.
///
/// **The risk this file exists for is not the SQL. It is termination.** A
/// one-shot closes only on a pass that comes back short of its cap, so a slice
/// holding rows that nothing will ever re-embed stays full for the life of the
/// database and re-queues the same work on every sync — the exact failure
/// `SyncService._retireEmbedTag`'s doc comment spends twelve lines ruling out
/// for the clustering corpus. Each corpus terminates for its own reason, and
/// each reason is a case below:
///
/// | corpus | why a row leaves the stale set |
/// |---|---|
/// | messages | the handler re-embeds it, and the slice excludes the rows that handler would skip |
/// | attachment passages | the walk nulls the vector it selected on |
/// | directory passages | the walk nulls the vector it selected on |
/// | descriptions | there is no second slice: one uncapped pass takes the corpus |
///
/// The clustering corpus's own one-shot — a different walk, a different pref
/// and a different vehicle — is pinned in `sync_state_test.dart`, and the tag
/// strings themselves in `embeddings_prefix_test.dart`.

/// What an older build wrote its document vectors under. A literal rather than
/// a constant in `EmbeddingsClient`, because the production walks never name
/// it: they ask for everything that is NOT the current tag, which covers a row
/// written before there were tags at all as well as every past model.
const String _staleTag = 'embeddinggemma-300M/document';

const String _currentTag = EmbeddingsClient.documentModelTag;

/// A backend that answers every drain with nothing. Duplicated from
/// `sync_context_enqueue_test.dart` rather than shared, on the rule those
/// files state: neither test can break the other by editing it.
class FakeMail implements MailBackend {
  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) async =>
      DeltaPage(messages: const [], deltaLink: 'delta-$folder');

  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) async => {};

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async => {};

  @override
  Future<Map<String, dynamic>> createDraft({
    required List<String> to,
    List<String> cc = const [],
    required String subject,
    required String body,
  }) async =>
      {};

  @override
  Future<void> updateDraftBody(String draftId, String text) async {}

  @override
  Future<SentDraft> sendDraft(String draftId) async =>
      SentDraft(draftId: draftId);

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async =>
      const [];
}

/// An exact stamp, derived from now rather than written as a date: the sync
/// floor is a rolling window and a literal would walk outside it at midnight.
String isoAgo(Duration ago) => DateTime.now()
    .toUtc()
    .subtract(ago)
    .toIso8601String()
    .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

/// Four floats, which is all any of these cases reads: nothing here compares
/// vectors, it only asks whether one is there.
Uint8List _blob() => Uint8List.fromList(const [1, 2, 3, 4]);

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ContextStore context;

  setUp(() {
    // The vec fixture because one case below reaches `clearDerived`, which
    // rebuilds the derived indexes on its way out.
    db = vecTestDb();
    store = MessageStore(db);
    context = ContextStore(db);
  });

  tearDown(() async => db.close());

  /// A sync with the directories wired, which is the app's shape.
  SyncService sync() => SyncService(
        FakeMail(),
        store,
        contextStore: context,
        // Wired, because the four walks report themselves on the `sync_mail`
        // row's detail and nowhere else.
        activityLog: ActivityLog(store),
      );

  /// The `detail` map off the newest `sync_mail` activity row.
  Future<Map<String, Object?>> syncMailDetail() async {
    final rows = await db
        .customSelect(
          "SELECT detail_json FROM activity_events WHERE kind = 'sync_mail' "
          'ORDER BY id DESC LIMIT 1',
        )
        .get();
    if (rows.isEmpty) return const {};
    final raw = rows.first.data['detail_json'] as String?;
    return raw == null
        ? const {}
        : Map<String, Object?>.from(jsonDecode(raw) as Map);
  }

  /// Every work row of [kind], as `source/entity_id`, with its status.
  Future<Map<String, String>> workRows(String kind) async {
    final rows = await db
        .customSelect(
          'SELECT source, entity_id, status FROM work_items '
          'WHERE task_kind = ?',
          variables: [Variable<String>(kind)],
        )
        .get();
    return {
      for (final row in rows)
        '${row.data['source']}/${row.data['entity_id']}':
            row.data['status'] as String,
    };
  }

  /// One inbound message with a search vector under [tag].
  ///
  /// Five days back, and deliberately: `enqueueEmbedBacklog` files every kept
  /// message received inside the lookback window on every sync, so a fixture
  /// inside it would have an `embed_message` row whoever put it there. Outside
  /// the window, a work row is the backfill's or nobody's.
  Future<void> seedMessage(
    String id, {
    String tag = _staleTag,
    String source = 'email',
    String triageStatus = 'triaged',
    String? gateReason,
    bool withVector = true,
    bool withMessage = true,
  }) async {
    final receivedAt = isoAgo(const Duration(days: 5));
    if (withMessage) {
      await store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': 'conv-$id',
        'direction': 'inbound',
        'subject': 'The renewal',
        'from_name': 'Wren Calloway',
        'from_address': 'wren@example.test',
        'received_at': receivedAt,
        'body_text': 'Body of $id',
        'triage_status': triageStatus,
        'gate_reason': gateReason,
      });
    }
    if (withVector) {
      await store.upsertMessageVector(
        source: source,
        sourceMessageId: id,
        embedding: _blob(),
        dims: 4,
        embeddedHash: 'h-$id',
        embedModel: tag,
        receivedAt: receivedAt,
      );
    }
  }

  /// One attachment of one message, chunked and embedded under [tag].
  ///
  /// The message row is part of the fixture because the slice joins it: the
  /// handler applies `attachmentTextPolicy` before its resume branch, so a
  /// document whose message the gate has since thrown out would be written
  /// down to `skipped` by the very pass this queues.
  Future<void> seedAttachment(
    String messageId,
    String attachmentId, {
    required String tag,
    int chunks = 2,
    String source = 'email',
    String triageStatus = 'triaged',
    String direction = 'inbound',
    String? gateReason,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': messageId,
      'conversation_key': 'conv-$messageId',
      'direction': direction,
      'subject': 'The renewal',
      'from_name': 'Wren Calloway',
      'from_address': 'wren@example.test',
      'received_at': isoAgo(const Duration(days: 5)),
      'body_text': 'Body of $messageId',
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
    final ids = await store.replaceChunks(
      source,
      messageId,
      attachmentId,
      [
        for (var seq = 0; seq < chunks; seq++)
          (seq: seq, locator: 'page $seq', text: 'passage $seq of $messageId'),
      ],
    );
    for (final id in ids) {
      await store.setChunkEmbedding(
        id,
        embedding: _blob(),
        dims: 4,
        embedModel: tag,
      );
    }
  }

  /// How many attachment passages carry a vector.
  Future<int> embeddedChunks({String? tag}) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM attachment_chunks '
          'WHERE embedding IS NOT NULL'
          '${tag == null ? '' : ' AND embed_model = ?'}',
          variables: [if (tag != null) Variable<String>(tag)],
        )
        .getSingle();
    return (row.data['n'] as num).toInt();
  }

  /// One registered directory holding one file with [chunks] passages
  /// embedded under [tag], and a skill description vector beside them.
  Future<String> seedDirectory(
    String path, {
    required String tag,
    int chunks = 2,
    bool withDescription = true,
  }) async {
    final dirId = await context.registerDirectory(
      path: path,
      displayName: path,
    );
    final fileId = await context.upsertFile(
      dirId: dirId,
      relPath: 'notes.md',
      size: 10,
      mtime: isoAgo(const Duration(days: 5)),
      sha256: 'sha-$path',
      kind: 'skill',
      claudeChain: const [],
      description: 'What this skill is for',
      textChars: 10,
    );
    final ids = await context.replaceChunks(
      fileId,
      [
        for (var seq = 0; seq < chunks; seq++)
          (seq: seq, locator: 'lines $seq', text: 'passage $seq of $path'),
      ],
    );
    for (final id in ids) {
      await context.setChunkEmbedding(
        id,
        embedding: _blob(),
        dims: 4,
        embedModel: tag,
      );
    }
    if (withDescription) {
      await context.setFileDescEmbedding(fileId, _blob());
    }
    return dirId;
  }

  /// How many directory passages carry a vector.
  Future<int> embeddedPassages({String? tag}) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM context_chunks '
          'WHERE embedding IS NOT NULL'
          '${tag == null ? '' : ' AND embed_model = ?'}',
          variables: [if (tag != null) Variable<String>(tag)],
        )
        .getSingle();
    return (row.data['n'] as num).toInt();
  }

  /// How many files carry a description vector.
  Future<int> embeddedDescriptions() async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM context_files '
          'WHERE desc_embedding IS NOT NULL',
        )
        .getSingle();
    return (row.data['n'] as num).toInt();
  }

  group('the message corpus', () {
    test('a stale vector is requeued and a current one is left alone',
        () async {
      await seedMessage('stale-1');
      await seedMessage('stale-2', source: 'teams');
      await seedMessage('current', tag: _currentTag);

      await sync().syncNow();

      // The current row is not work: it is already the vector this build
      // reads, and re-embedding it would be a call for nothing.
      expect(
        await workRows('embed_message'),
        {'email/stale-1': 'pending', 'teams/stale-2': 'pending'},
      );
      // Two is short of the cap, so this pass closed the one-shot.
      expect(await store.getPref(searchEmbedMessagesPref), '1');
      expect((await syncMailDetail())['requeued_message_embeds'], 2);
    });

    test('a gated message and a vector with no message are not in the slice',
        () async {
      // The two rows `EmbedHandler` completes WITHOUT touching the vector. In
      // the slice they would be re-queued on every sync for the life of the
      // database, and two hundred of them would hold the one-shot open
      // forever — the failure this whole design is arranged around.
      await seedMessage('gated', triageStatus: 'skipped', gateReason: 'junk');
      await seedMessage('orphan', withMessage: false);
      await seedMessage('real');

      await sync().syncNow();

      expect(await workRows('embed_message'), {'email/real': 'pending'});
      expect(await store.getPref(searchEmbedMessagesPref), '1');
    });

    test('a chat row gated only by the retired teams reason is in the slice',
        () async {
      // `EmbedHandler` tolerates `teams_source` — a chat stored before chats
      // were triaged is `skipped` for no judgement anybody made — so the slice
      // has to tolerate it too, or those rows would never be re-embedded.
      await seedMessage(
        'legacy-chat',
        source: 'teams',
        triageStatus: 'skipped',
        gateReason: 'teams_source',
      );

      await sync().syncNow();

      expect(await workRows('embed_message'), {'teams/legacy-chat': 'pending'});
    });

    test('a finished work row is revived, where the backlog enqueue skips it',
        () async {
      // The reason this needs a walk of its own rather than a wider
      // `enqueueEmbedBacklog`: that statement excludes any message which
      // already has an `embed_message` row of any status, which is every
      // message that has ever been embedded. Exactly the set this is for.
      await seedMessage('done-once');
      await store.enqueueWork('embed_message', 'email', 'done-once');
      await store.writeWork(
        'embed_message',
        'email',
        'done-once',
        status: 'done',
      );

      await sync().syncNow();

      expect(await workRows('embed_message'), {'email/done-once': 'pending'});
    });

    test('a full slice leaves the one-shot owed and the next sync walks on',
        () async {
      for (var i = 0; i < clusteringCardReembedCap + 1; i++) {
        await seedMessage('old-$i');
      }

      await sync().syncNow();

      expect(
        await workRows('embed_message'),
        hasLength(clusteringCardReembedCap),
      );
      expect(await store.getPref(searchEmbedMessagesPref), isNull);
      expect(
        (await syncMailDetail())['requeued_message_embeds'],
        clusteringCardReembedCap,
      );

      // The handler rewrites each row under the current tag as it goes, which
      // is what shrinks the next slice. All but the one that never fitted.
      for (var i = 0; i < clusteringCardReembedCap; i++) {
        await seedMessage('old-$i', tag: _currentTag);
      }

      await sync().syncNow();

      expect((await syncMailDetail())['requeued_message_embeds'], 1);
      expect(await store.getPref(searchEmbedMessagesPref), '1');
    });

    test('a closed one-shot does nothing, however many stale rows there are',
        () async {
      await store.setPref(searchEmbedMessagesPref, '1');
      await seedMessage('stale-1');

      await sync().syncNow();

      expect(await workRows('embed_message'), isEmpty);
      expect((await syncMailDetail())['requeued_message_embeds'], isNull);
    });
  });

  group('the attachment corpus', () {
    test('stale passages lose their vectors and the document is re-queued',
        () async {
      await seedAttachment('m1', 'a1', tag: _staleTag);
      await seedAttachment('m2', 'a2', tag: _currentTag);

      await sync().syncNow();

      // Nulling alone would not be enough: `unembeddedChunks` is per
      // attachment and is only read on the resume branch of a CLAIMED
      // `attachment_text` item, so the requeue is what brings the handler
      // back to these passages.
      expect(
        await workRows('attachment_text'),
        {'email/${attachmentEntityId('m1', 'a1')}': 'pending'},
      );
      expect(await embeddedChunks(tag: _staleTag), 0);
      expect(await embeddedChunks(tag: _currentTag), 2);
      expect(await store.getPref(searchEmbedAttachmentsPref), '1');
      expect((await syncMailDetail())['requeued_attachment_embeds'], 1);
    });

    test('a document half re-embedded keeps the half that is current',
        () async {
      // A pass parked mid-document leaves one tag on some passages and the
      // other on the rest. Nulling the whole attachment would pay for the
      // current ones a second time.
      await seedAttachment('m1', 'a1', tag: _currentTag, chunks: 0);
      final ids =
          await store.replaceChunks('email', 'm1', 'a1', const [
        (seq: 0, locator: 'p0', text: 'first'),
        (seq: 1, locator: 'p1', text: 'second'),
      ]);
      await store.setChunkEmbedding(ids[0],
          embedding: _blob(), dims: 4, embedModel: _currentTag);
      await store.setChunkEmbedding(ids[1],
          embedding: _blob(), dims: 4, embedModel: _staleTag);

      await sync().syncNow();

      expect(await embeddedChunks(tag: _currentTag), 1);
      expect(await embeddedChunks(tag: _staleTag), 0);
    });

    test('a document on a gated message keeps its vectors and its digest',
        () async {
      // `attachmentTextPolicy` runs BEFORE the handler's resume branch, so a
      // requeue here would not re-embed anything: it would write the document
      // down to `skipped`, digest and all, having already lost the vectors the
      // walk nulled. A fully read document turned into a refused one by a pass
      // that meant to help. The gate clause is the policy's own, character for
      // character, so the owner's Ignore is covered as well as a junk verdict.
      await seedAttachment(
        'gated',
        'a1',
        tag: _staleTag,
        triageStatus: 'skipped',
        gateReason: 'user',
      );
      await seedAttachment('kept', 'a2', tag: _staleTag);

      await sync().syncNow();

      expect(
        await workRows('attachment_text'),
        {'email/${attachmentEntityId('kept', 'a2')}': 'pending'},
      );
      expect(await embeddedChunks(tag: _staleTag), 2, reason: 'the gated one');
      // A refused row is out of every slice, not held back for a later one, so
      // the eligible set still empties and the one-shot still closes.
      expect(await store.getPref(searchEmbedAttachmentsPref), '1');
    });

    test('an outbound document is in the slice although it is skipped',
        () async {
      // Every outbound is born `skipped`/`outbound`, and the policy excuses it
      // by name: the owner's own attachments are usually the most quotable
      // thing on a thread. A clause that only excused chats would refuse all
      // of them.
      await seedAttachment(
        'mine',
        'a1',
        tag: _staleTag,
        direction: 'outbound',
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );

      await sync().syncNow();

      expect(
        await workRows('attachment_text'),
        {'email/${attachmentEntityId('mine', 'a1')}': 'pending'},
      );
      expect(await embeddedChunks(tag: _staleTag), 0);
    });

    test('a document at the server is left whole and taken by a later slice',
        () async {
      // `requeueWork` leaves a `processing` row alone, so the requeue would be
      // swallowed and the nulled passages would wait for something else to ask
      // for the document. Whole, they stay invisible under the old tag, which
      // is where the backfill found them.
      await seedAttachment('claimed', 'a1', tag: _staleTag);
      final entityId = attachmentEntityId('claimed', 'a1');
      await store.enqueueWork('attachment_text', 'email', entityId);
      await store.writeWork(
        'attachment_text',
        'email',
        entityId,
        status: 'processing',
      );

      await sync().syncNow();

      expect((await workRows('attachment_text'))['email/$entityId'],
          'processing');
      expect(await embeddedChunks(tag: _staleTag), 2);

      // And the moment the handler lets go of it, the next pass takes it —
      // this one's pref closed, so the second sync is made to walk again the
      // way a Clear AI results would.
      await store.writeWork(
        'attachment_text',
        'email',
        entityId,
        status: 'done',
      );
      await db.customUpdate(
        'DELETE FROM app_prefs WHERE "key" = ?',
        variables: [Variable<String>(searchEmbedAttachmentsPref)],
      );

      await sync().syncNow();

      expect((await workRows('attachment_text'))['email/$entityId'], 'pending');
      expect(await embeddedChunks(tag: _staleTag), 0);
    });

    test('the slice is capped at attachments, and the pref waits for a short '
        'pass', () async {
      for (var i = 0; i < clusteringCardReembedCap + 1; i++) {
        await seedAttachment('m$i', 'a$i', tag: _staleTag, chunks: 1);
      }

      await sync().syncNow();

      expect(
        await workRows('attachment_text'),
        hasLength(clusteringCardReembedCap),
      );
      expect(await embeddedChunks(), 1, reason: 'one attachment left over');
      expect(await store.getPref(searchEmbedAttachmentsPref), isNull);

      // No re-embed in between, and the next slice is still one row: the walk
      // itself is what takes a row out of the stale set, so the corpus is
      // bounded by what it holds rather than by what the handler manages.
      await sync().syncNow();

      expect((await syncMailDetail())['requeued_attachment_embeds'], 1);
      expect(await embeddedChunks(), 0);
      expect(await store.getPref(searchEmbedAttachmentsPref), '1');
    });

    test('a closed one-shot leaves a stale document where it is', () async {
      await store.setPref(searchEmbedAttachmentsPref, '1');
      await seedAttachment('m1', 'a1', tag: _staleTag);

      await sync().syncNow();

      expect(await workRows('attachment_text'), isEmpty);
      expect(await embeddedChunks(tag: _staleTag), 2);
    });
  });

  group('the directory passage corpus', () {
    test('stale passages lose their vectors and no work row is filed for them',
        () async {
      await seedDirectory('/w/atlas', tag: _staleTag);
      await seedDirectory('/w/ridge', tag: _currentTag);

      await sync().syncNow();

      expect(await embeddedPassages(tag: _staleTag), 0);
      expect(await embeddedPassages(tag: _currentTag), 2);
      expect(await store.getPref(searchEmbedPassagesPref), '1');
      expect((await syncMailDetail())['cleared_passage_embeds'], 2);

      // The reason there is no requeue of its own: every sync already files a
      // reconcile for every registered directory, and that handler's worklist
      // is directory-wide.
      expect(
        (await workRows('context_reconcile')).length,
        2,
        reason: 'one per registered directory, which is the refill',
      );
    });

    test('the slice is capped, and the pref waits for a short pass', () async {
      await seedDirectory(
        '/w/atlas',
        tag: _staleTag,
        chunks: clusteringCardReembedCap + 1,
      );

      await sync().syncNow();

      expect(await embeddedPassages(), 1);
      expect(await store.getPref(searchEmbedPassagesPref), isNull);
      expect(
        (await syncMailDetail())['cleared_passage_embeds'],
        clusteringCardReembedCap,
      );

      await sync().syncNow();

      expect(await embeddedPassages(), 0);
      expect(await store.getPref(searchEmbedPassagesPref), '1');
    });

    test('a closed one-shot leaves a stale passage where it is', () async {
      await store.setPref(searchEmbedPassagesPref, '1');
      await seedDirectory('/w/atlas', tag: _staleTag);

      await sync().syncNow();

      expect(await embeddedPassages(tag: _staleTag), 2);
    });
  });

  group('the description corpus', () {
    test('one pass nulls every description vector and closes the one-shot',
        () async {
      await seedDirectory('/w/atlas', tag: _currentTag);
      await seedDirectory('/w/ridge', tag: _currentTag);

      await sync().syncNow();

      // No tag column to key on, so the pass is unconditional: this corpus is
      // tens of rows, and `skillsNeedingDescEmbedding` is directory-wide and
      // runs on every reconcile.
      expect(await embeddedDescriptions(), 0);
      expect(await store.getPref(searchEmbedDescriptionsPref), '1');
      expect((await syncMailDetail())['cleared_description_embeds'], 2);
    });

    test('a description re-embedded afterwards survives the next sync',
        () async {
      // The termination argument said out loud. An uncapped unconditional
      // UPDATE that ran on every sync would throw away the vectors the
      // reconcile had just paid for, every sync, forever.
      await seedDirectory('/w/atlas', tag: _currentTag);

      await sync().syncNow();
      expect(await embeddedDescriptions(), 0);

      final files = await db
          .customSelect('SELECT id FROM context_files')
          .get();
      await context.setFileDescEmbedding(
        files.single.data['id'] as int,
        _blob(),
      );

      await sync().syncNow();

      expect(await embeddedDescriptions(), 1);
      expect((await syncMailDetail())['cleared_description_embeds'], isNull);
    });

    test('a closed one-shot leaves the descriptions alone', () async {
      await store.setPref(searchEmbedDescriptionsPref, '1');
      await seedDirectory('/w/atlas', tag: _currentTag);

      await sync().syncNow();

      expect(await embeddedDescriptions(), 1);
    });
  });

  group('what a build without directories does', () {
    test('the two directory one-shots stay owed, and the other two close',
        () async {
      await seedDirectory('/w/atlas', tag: _staleTag);
      await seedMessage('stale-1');

      // Every caller from before the feature, and every test that does not
      // care, passes no context store. A build that cannot do the work must
      // not consume the one-shot the app is owed — the rule the gate repair
      // follows for its own.
      await SyncService(FakeMail(), store, activityLog: ActivityLog(store))
          .syncNow();

      expect(await store.getPref(searchEmbedPassagesPref), isNull);
      expect(await store.getPref(searchEmbedDescriptionsPref), isNull);
      expect(await embeddedPassages(tag: _staleTag), 2);
      expect(await embeddedDescriptions(), 1);

      expect(await store.getPref(searchEmbedMessagesPref), '1');
      expect(await store.getPref(searchEmbedAttachmentsPref), '1');
    });
  });

  group('the four are independent', () {
    test('a corpus with a deep backlog does not hold the other three closed',
        () async {
      // Unlike the clustering walk, which takes ONE slice a sync and stops at
      // the first tag that had rows. These four are four corpora and not four
      // tags of one: a mailbox with thousands of stale messages would
      // otherwise keep its documents and directories invisible to search for
      // as many syncs as the messages take.
      for (var i = 0; i < clusteringCardReembedCap + 1; i++) {
        await seedMessage('old-$i');
      }
      await seedAttachment('m1', 'a1', tag: _staleTag);
      await seedDirectory('/w/atlas', tag: _staleTag);

      await sync().syncNow();

      expect(await store.getPref(searchEmbedMessagesPref), isNull);
      expect(await store.getPref(searchEmbedAttachmentsPref), '1');
      expect(await store.getPref(searchEmbedPassagesPref), '1');
      expect(await store.getPref(searchEmbedDescriptionsPref), '1');
    });
  });

  group('Clear AI results', () {
    test('every search one-shot is a derived one-shot', () async {
      // The keys live in `sync_service.dart` beside the walks and are spelled
      // again in the store, which imports nothing above itself. A key left out
      // here would survive the clear and tell the next sync that the catch-up
      // had already run over a corpus the clear has just emptied.
      for (final key in searchEmbedBackfillPrefs) {
        expect(
          MessageStore.derivedOneShotPrefs,
          contains(key),
          reason: '$key survives a clear and would strand the corpus',
        );
      }
      expect(searchEmbedBackfillPrefs, hasLength(4));
    });

    test('a clear drops all four, so the next sync walks the corpora again',
        () async {
      for (final key in searchEmbedBackfillPrefs) {
        await store.setPref(key, '1');
      }

      await store.clearDerived();

      for (final key in searchEmbedBackfillPrefs) {
        expect(await store.getPref(key), isNull, reason: key);
      }
    });
  });
}
