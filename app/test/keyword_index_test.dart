// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/keyword_index.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The FTS5 tables' lifecycle: when they come into existence, what keeps them
/// in step with the rows they are derived from, and what happens to them when
/// the mailbox goes away.
///
/// Nothing here is about ranking — `keyword_search_store_test.dart` owns that.
/// This file owns the promise that the index is never stale and never a fact
/// about the schema.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<bool> tableExists(String name) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '$name'",
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<int> rowCount(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .data['n'] as int;

  Future<void> seed(
    String id, {
    String subject = 'Weekly roundup',
    String body = 'nothing much happened',
  }) =>
      store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': 'c-$id',
        'direction': 'inbound',
        'subject': subject,
        'body_text': body,
        'from_name': 'Dana Whitfield',
        'from_address': 'dana@example.com',
        'received_at': '2026-09-01T10:00:00Z',
      });

  Future<List<String>> find(String query) async => [
        for (final hit in (await store.keywordSearchMessages(query))!)
          hit.row.sourceMessageId,
      ];

  test('the table does not exist until something searches', () async {
    await seed('m1', subject: 'Invoice 4471 is overdue');

    // A migration that created it would fail every pair in the schema suite:
    // drift's verifier diffs the whole of `sqlite_master`.
    expect(await tableExists(MessageKeywordIndex.table), isFalse);

    expect(await find('invoice'), ['m1']);

    expect(await tableExists(MessageKeywordIndex.table), isTrue);
  });

  test('a message written after the first search is found by the second',
      () async {
    await seed('first', subject: 'Invoice 4471 is overdue');
    expect(await find('invoice'), ['first']);

    await seed('second', subject: 'Invoice 4472 is overdue');

    // The watermark pass runs before every read, so nothing has to remember to
    // file a message when it arrives.
    expect((await find('invoice')).toSet(), {'first', 'second'});
  });

  test('a summary written by triage makes the row findable by its words',
      () async {
    await seed('m1', subject: 'Weekly roundup', body: 'nothing much happened');
    expect(await find('escalator'), isEmpty);

    await store.writeTriage(
      'email',
      'm1',
      status: 'triaged',
      result: TriageResult(
        urgency: 'normal',
        category: 'work',
        summary: 'The lease escalator changes in March.',
        needsAction: false,
        actionItems: const [],
      ),
    );

    // `writeTriage` stamps `updated_at`, which is the whole reason the
    // watermark is honest: the model's summary is text a person will search
    // for and it arrives long after the message did.
    expect(await find('escalator'), ['m1']);
  });

  test('a message deleted from under the index leaves no ghost', () async {
    await seed('m1', subject: 'Invoice 4471 is overdue');
    expect(await find('invoice'), ['m1']);

    await db.customStatement(
      "DELETE FROM messages WHERE source_message_id = 'm1'",
    );

    expect(await find('invoice'), isEmpty);
    expect(await rowCount(MessageKeywordIndex.table), 0);
  });

  test('a wipe empties the index — the old mailbox is not still searchable',
      () async {
    await seed('m1', subject: 'Invoice 4471 is overdue');
    expect(await find('invoice'), ['m1']);

    await store.wipeAll();

    // `DELETE FROM messages` cannot reach inside a virtual table; the rebuild
    // at the end of the wipe is what makes this empty.
    expect(await rowCount(MessageKeywordIndex.table), 0);
    expect(await find('invoice'), isEmpty);
  });

  test('a store built without the word index answers null, not empty',
      () async {
    final plain = MessageStore(db, keywordSearch: false);
    await plain.upsertMessage({
      'source': 'email',
      'source_message_id': 'm1',
      'conversation_key': 'c-m1',
      'direction': 'inbound',
      'subject': 'Invoice 4471 is overdue',
      'received_at': '2026-09-01T10:00:00Z',
    });

    // "There is nothing to search with" and "nothing matched" are different
    // sentences, and only a nullable return can hold both.
    expect(await plain.keywordSearchMessages('invoice'), isNull);
    expect(await plain.keywordSearchChunks('invoice'), isNull);
    expect(await tableExists(MessageKeywordIndex.table), isFalse);
  });

  group('the chunk index', () {
    Future<void> attach(
      String messageId,
      String attachmentId, {
      required String name,
      required List<String> passages,
    }) async {
      await store.upsertAttachments('email', messageId, [
        {
          'attachment_id': attachmentId,
          'ordinal': 0,
          'kind': 'file',
          'name': name,
          'content_type': 'application/pdf',
          'size': 240 * 1024,
        },
      ]);
      await store.replaceChunks('email', messageId, attachmentId, [
        for (final (index, text) in passages.indexed)
          (seq: index, locator: 'part ${index + 1}', text: text),
      ]);
    }

    test('a passage is findable by its own words', () async {
      await seed('m1');
      await attach(
        'm1',
        'a1',
        name: 'Rent Roll.xlsx',
        passages: const ['Line 14: escalator of three percent each year.'],
      );

      final hits = (await store.keywordSearchChunks('escalator'))!;

      expect(hits, hasLength(1));
      expect(hits.single.text, contains('escalator'));
      expect(hits.single.name, 'Rent Roll.xlsx');
      // The word pass never asks for an embedding, so a passage nobody has
      // paid to embed is still findable.
      expect(hits.single.distance, isNull);
      expect(hits.single.bm25, isNotNull);
      expect(hits.single.coverage, 1.0);
    });

    test('the file name is searchable, not only the words inside', () async {
      await seed('m1');
      await attach(
        'm1',
        'a1',
        name: 'Rent Roll.xlsx',
        passages: const ['Line 14: three percent each year.'],
      );

      expect((await store.keywordSearchChunks('rent roll'))!, hasLength(1));
    });

    test('re-chunking a document leaves no orphan behind', () async {
      await seed('m1');
      await attach(
        'm1',
        'a1',
        name: 'Rent Roll.xlsx',
        passages: const ['Line 14: escalator of three percent each year.'],
      );
      expect((await store.keywordSearchChunks('escalator'))!, hasLength(1));

      // `replaceChunks` deletes the old passages and inserts new ones with new
      // ids, so the index's own rows are the only copy of the old text left.
      await attach(
        'm1',
        'a1',
        name: 'Rent Roll.xlsx',
        passages: const ['Line 14: a flat rent for the whole term.'],
      );

      expect(await store.keywordSearchChunks('escalator'), isEmpty);
      expect(
        await rowCount(ChunkKeywordIndex.table),
        await rowCount('attachment_chunks'),
      );
    });
  });
}
