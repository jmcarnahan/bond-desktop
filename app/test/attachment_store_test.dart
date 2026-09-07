import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The rule the `attachments` table exists to hold: **a re-sync updates what
/// the connector says and touches nothing anybody else wrote.**
///
/// Everything below is one half of that. The metadata columns follow the
/// connector, so a renamed file renames; the text, digest, blob and pin columns
/// belong to the handlers and to the owner, and a delta page coming round for
/// the third time must not cost a document its extracted words or a person
/// their pin.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedMessage(
    String id, {
    String source = 'email',
    String key = 'conv-1',
    String? receivedAt = '2026-09-04T10:00:00.000Z',
    String direction = 'inbound',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'subject': 'Subject of $id',
      'received_at': receivedAt,
      'is_read': 0,
      'triage_status': 'triaged',
    });
  }

  Map<String, Object?> row(
    String id, {
    int ordinal = 0,
    String kind = 'file',
    String? name,
    String? contentType = 'application/pdf',
    int size = 1024,
    Object? isInline = false,
    String? sourceUrl,
  }) =>
      {
        'attachment_id': id,
        'ordinal': ordinal,
        'kind': kind,
        'name': name ?? '$id.pdf',
        'content_type': contentType,
        'size': size,
        'is_inline': isInline,
        'source_url': sourceUrl,
      };

  group('what came with a message', () {
    test('writes one message\'s attachments and reads them back in order',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('att-b', ordinal: 1, name: 'floor-plan.pdf'),
        row('att-a', name: 'lease-addendum.pdf'),
      ]);

      final stored = await store.attachmentsForMessage('email', 'm1');

      expect(stored.map((r) => r['attachment_id']), ['att-a', 'att-b']);
      expect(stored.first['name'], 'lease-addendum.pdf');
      expect(stored.first['size'], 1024);
      expect(stored.first['text_status'], 'pending');
      expect(stored.first['digest_status'], 'pending');
    });

    test('a second sync overwrites the name and leaves the text alone',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'done',
        text: 'The tenant pays the first month on the fourth.',
      );

      await store.upsertAttachments('email', 'm1', [
        row('att-a', name: 'lease-addendum-final.pdf'),
      ]);

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['name'], 'lease-addendum-final.pdf');
      expect(stored['text_status'], 'done');
      expect(
        await store.attachmentTextOf('email', 'm1', 'att-a'),
        'The tenant pays the first month on the fourth.',
      );
    });

    test('a re-sync never unpins a document the user pinned', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentPinned('email', 'm1', 'att-a', 'story-7');

      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['pinned_storyline_id'], 'story-7');
    });

    test('a re-sync leaves the digest and the cached bytes where they are',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentDigest(
        'email',
        'm1',
        'att-a',
        status: 'done',
        digestJson: '{"evidence":"a lease addendum","asks":[]}',
      );
      await store.setAttachmentBlob(
        'email',
        'm1',
        'att-a',
        blobPath: '/cache/ab/abcdef',
        blobSha256: 'abcdef',
      );

      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['digest_status'], 'done');
      expect(stored['digest_json'], contains('a lease addendum'));
      expect(stored['blob_path'], '/cache/ab/abcdef');
      expect(stored['blob_fetched_at'], isNotNull);
    });

    test('a Teams entry whose size is unknown does not zero a size already '
        'learned', () async {
      await seedMessage('c1', source: 'teams', key: 'chat-1');
      await store.upsertAttachments('teams', 'c1', [
        row('hosted-1', size: 240000, contentType: 'image/png'),
      ]);

      await store.upsertAttachments('teams', 'c1', [
        row('hosted-1', size: 0, contentType: 'image/png'),
      ]);

      final stored = (await store.attachmentsForMessage('teams', 'c1')).single;
      expect(stored['size'], 240000);
    });

    test('a listing that omits a name cannot blank the one already stored',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('att-a', name: 'quote.pdf'),
      ]);

      await store.upsertAttachments('email', 'm1', [
        {'attachment_id': 'att-a', 'ordinal': 0, 'kind': 'file'},
      ]);

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['name'], 'quote.pdf');
    });

    test('an entry with no id is skipped rather than stored under an empty key',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        {'attachment_id': '', 'ordinal': 0, 'kind': 'file'},
        row('att-a', ordinal: 1),
      ]);

      final stored = await store.attachmentsForMessage('email', 'm1');
      expect(stored.map((r) => r['attachment_id']), ['att-a']);
    });
  });

  group('reading many at once', () {
    test('attachments for a set of messages come back keyed by message',
        () async {
      await seedMessage('m1');
      await seedMessage('m2');
      await seedMessage('m3');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.upsertAttachments('email', 'm2', [
        row('att-b'),
        row('att-c', ordinal: 1),
      ]);

      final byMessage =
          await store.attachmentsForMessages('email', ['m1', 'm2', 'm3']);

      expect(byMessage.keys, unorderedEquals(['m1', 'm2']));
      expect(byMessage['m2']!.map((r) => r['attachment_id']),
          ['att-b', 'att-c']);
    });

    test('only the digested ones when that is what was asked for', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('att-a'),
        row('att-b', ordinal: 1),
      ]);
      await store.setAttachmentDigest(
        'email',
        'm1',
        'att-b',
        status: 'done',
        digestJson: '{"evidence":"a quote","asks":[]}',
      );

      final digested = await store.digestsForMessages('email', ['m1']);

      expect(digested['m1']!.single['attachment_id'], 'att-b');
    });

    test('a digest status with no json behind it is not a digest', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentDigest('email', 'm1', 'att-a', status: 'done');

      expect(await store.digestsForMessages('email', ['m1']), isEmpty);
    });

    test('asking about no messages costs no query', () async {
      expect(await store.attachmentsForMessages('email', const []), isEmpty);
    });
  });

  group('a thread and a storyline', () {
    Future<void> joinStoryline(String key, {String id = 'story-7'}) =>
        store.addStorylineMember(id, 'email', key, addedBy: 'auto');

    test('a storyline\'s documents are every file on its threads, pinned '
        'first, newest first', () async {
      await seedMessage('m1', receivedAt: '2026-09-04T09:00:00.000Z');
      await seedMessage('m2', receivedAt: '2026-09-04T11:00:00.000Z');
      await joinStoryline('conv-1');
      await store.upsertAttachments('email', 'm1', [row('att-early')]);
      await store.upsertAttachments('email', 'm2', [row('att-late')]);
      // Pinned, and on the OLDER message: the pin has to beat the clock or the
      // ordering is just a timeline with an extra column.
      await store.setAttachmentPinned('email', 'm1', 'att-early', 'story-7');

      final documents = await store.attachmentsForStoryline('story-7');

      expect(
        documents.map((r) => r['attachment_id']),
        ['att-early', 'att-late'],
      );
      expect(documents.first['conversation_key'], 'conv-1');
      expect(documents.last['message_received_at'], '2026-09-04T11:00:00.000Z');
    });

    test('a file pinned to another storyline keeps its place in the timeline',
        () async {
      await seedMessage('m1', receivedAt: '2026-09-04T09:00:00.000Z');
      await seedMessage('m2', receivedAt: '2026-09-04T11:00:00.000Z');
      await joinStoryline('conv-1');
      await store.upsertAttachments('email', 'm1', [row('att-early')]);
      await store.upsertAttachments('email', 'm2', [row('att-late')]);
      // Pinned, but to a DIFFERENT storyline. Here that is an ordinary thread
      // attachment, and an ordinary one on the older message sorts after the
      // newer one — a `NULL = ?` in the ORDER BY would have put it first.
      await store.setAttachmentPinned('email', 'm1', 'att-early', 'story-8');

      final documents = await store.attachmentsForStoryline('story-7');

      expect(
        documents.map((r) => r['attachment_id']),
        ['att-late', 'att-early'],
      );
    });

    test('a pin whose thread left the storyline still shows', () async {
      await seedMessage('m1', key: 'conv-other');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentPinned('email', 'm1', 'att-a', 'story-7');

      // Nothing joins `conv-other` to the storyline. A pin is a person's own
      // decision and it outlives the membership that may never have existed.
      final documents = await store.attachmentsForStoryline('story-7');

      expect(documents.single['attachment_id'], 'att-a');
    });

    test('inline images are not documents', () async {
      await seedMessage('m1');
      await joinStoryline('conv-1');
      await store.upsertAttachments('email', 'm1', [
        row('att-signature', isInline: true, contentType: 'image/png'),
        row('att-real', ordinal: 1),
      ]);

      final documents = await store.attachmentsForStoryline('story-7');

      expect(documents.single['attachment_id'], 'att-real');
    });

    test('a thread outside the storyline contributes nothing', () async {
      await seedMessage('m1', key: 'conv-1');
      await seedMessage('m2', key: 'conv-2');
      await joinStoryline('conv-1');
      await store.upsertAttachments('email', 'm1', [row('att-mine')]);
      await store.upsertAttachments('email', 'm2', [row('att-theirs')]);

      final documents = await store.attachmentsForStoryline('story-7');

      expect(documents.single['attachment_id'], 'att-mine');
    });

    test('a document counts once however many storylines its thread is in',
        () async {
      await seedMessage('m1');
      await joinStoryline('conv-1');
      await joinStoryline('conv-1', id: 'story-8');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentPinned('email', 'm1', 'att-a', 'story-7');

      // Both halves of the OR are true for this row. An EXISTS rather than a
      // join is what keeps it one row rather than one per membership.
      expect(await store.attachmentsForStoryline('story-7'), hasLength(1));
    });

    test('pinned documents come back newest message first', () async {
      await seedMessage('m1', receivedAt: '2026-09-04T09:00:00.000Z');
      await seedMessage('m2', receivedAt: '2026-09-04T11:00:00.000Z');
      await store.upsertAttachments('email', 'm1', [row('att-early')]);
      await store.upsertAttachments('email', 'm2', [row('att-late')]);
      await store.setAttachmentPinned('email', 'm1', 'att-early', 'story-7');
      await store.setAttachmentPinned('email', 'm2', 'att-late', 'story-7');

      final pinned = await store.pinnedAttachmentsForStoryline('story-7');

      expect(pinned.map((r) => r['attachment_id']), ['att-late', 'att-early']);
    });

    test('unpinning takes a document off the storyline', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentPinned('email', 'm1', 'att-a', 'story-7');

      await store.setAttachmentPinned('email', 'm1', 'att-a', null);

      expect(await store.pinnedAttachmentsForStoryline('story-7'), isEmpty);
    });

    test('a thread hydrates its messages with what came with them', () async {
      await seedMessage('m1');
      await seedMessage('m2');
      await store.upsertAttachments('email', 'm1', [
        row('att-a', name: 'lease-addendum.pdf'),
      ]);

      final thread = await store.loadThread('conv-1');

      expect(thread.first.attachments.single.name, 'lease-addendum.pdf');
      expect(thread.first.attachments.single.conversationKey, 'conv-1');
      expect(thread.last.attachments, isEmpty);
    });
  });

  group('what a status write means', () {
    test('a skip records its reason and stores no words', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'skipped',
        reason: 'no_extractor',
      );

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['text_status'], 'skipped');
      expect(stored['text_reason'], 'no_extractor');
      expect(await store.attachmentTextOf('email', 'm1', 'att-a'), isNull);
    });

    test('an empty reason is stored as nothing, not as an empty reason',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'done',
        reason: '',
        text: 'Two pages of terms.',
      );

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['text_reason'], isNull);
      expect(stored['text_chars'], 'Two pages of terms.'.length);
    });

    test('a truncated extraction says so', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'done',
        text: 'The first page only.',
        truncated: true,
      );

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['text_truncated'], 1);
    });

    test('a thumbnail write does not blank the blob path', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentBlob(
        'email',
        'm1',
        'att-a',
        blobPath: '/cache/ab/abcdef',
        blobSha256: 'abcdef',
      );

      await store.setAttachmentBlob(
        'email',
        'm1',
        'att-a',
        thumbPath: '/cache/ab/abcdef.thumb.png',
      );

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['blob_path'], '/cache/ab/abcdef');
      expect(stored['thumb_path'], '/cache/ab/abcdef.thumb.png');
    });

    test('one attachment row reads back on its own', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      expect(
        (await store.attachmentRow('email', 'm1', 'att-a'))!['name'],
        'att-a.pdf',
      );
      expect(await store.attachmentRow('email', 'm1', 'nope'), isNull);
    });

    test('a refusal is recorded once and only on a pending row', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      final born = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(born['text_status'], 'pending');

      await store.recordAttachmentRefusal('email', 'm1', 'att-a', 'gated');

      final refused = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(refused['text_status'], 'skipped');
      expect(refused['text_reason'], 'gated');
      // Left `pending`, the panel's AI segment would say it is still reading.
      expect(refused['digest_status'], 'skipped');
      expect(refused['updated_at'], isNot(born['updated_at']));

      // A later sighting has nothing to add: the row is no longer pending.
      await store.recordAttachmentRefusal('email', 'm1', 'att-a', 'too_large');
      expect(
        (await store.attachmentsForMessage('email', 'm1')).single['text_reason'],
        'gated',
      );
    });

    test('a refusal never downgrades a file already read', () async {
      await seedMessage('m2');
      await store.upsertAttachments('email', 'm2', [row('att-b')]);
      await store.setAttachmentText(
        'email',
        'm2',
        'att-b',
        status: 'done',
        text: 'words',
      );

      await store.recordAttachmentRefusal('email', 'm2', 'att-b', 'gated');

      final stored = (await store.attachmentsForMessage('email', 'm2')).single;
      expect(stored['text_status'], 'done');
      expect(stored['text_reason'], isNull);
    });

    test('reopening lifts only a gate', () async {
      await seedMessage('m3');
      await store.upsertAttachments('email', 'm3', [
        row('att-big'),
        row('att-gated', ordinal: 1),
      ]);
      await store.recordAttachmentRefusal('email', 'm3', 'att-big', 'too_large');
      await store.recordAttachmentRefusal('email', 'm3', 'att-gated', 'gated');

      await store.reopenGatedAttachment('email', 'm3', 'att-big');
      await store.reopenGatedAttachment('email', 'm3', 'att-gated');

      final rows = {
        for (final r in await store.attachmentsForMessage('email', 'm3'))
          r['attachment_id'] as String: r,
      };
      // Still true with the gate open: a 40 MB file is 40 MB either way.
      expect(rows['att-big']!['text_status'], 'skipped');
      expect(rows['att-big']!['text_reason'], 'too_large');
      expect(rows['att-gated']!['text_status'], 'pending');
      expect(rows['att-gated']!['text_reason'], isNull);
      expect(rows['att-gated']!['digest_status'], 'pending');
    });
  });

  group('the list card and the wipe', () {
    Future<void> seedThread() => store.upsertConversation({
          'conversation_key': 'conv-1',
          'subject': 'Lease addendum',
          'state': 'waiting',
          'last_message_at': '2026-09-04T11:00:00.000Z',
        });

    test('a thread\'s list card counts non-inline attachments', () async {
      await seedThread();
      await seedMessage('m1');
      await seedMessage('m2');
      await store.upsertAttachments('email', 'm1', [
        row('att-a'),
        row('att-logo', ordinal: 1, isInline: true, contentType: 'image/png'),
      ]);
      await store.upsertAttachments('email', 'm2', [row('att-b')]);

      final conversations = await store.loadConversations();

      expect(conversations.single.attachmentCount, 2);
    });

    test('a thread with nothing attached carries no paperclip', () async {
      await seedThread();
      await seedMessage('m1');

      expect((await store.loadConversations()).single.attachmentCount, 0);
    });

    test('clearing the blobs forgets the paths and keeps the metadata',
        () async {
      // What Settings' "Clear attachment cache" costs: the files, and nothing
      // else. The name, the words and the pin all outlive the bytes, because
      // none of them is a copy of the file.
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a', name: 'Q.pdf')]);
      await store.setAttachmentBlob(
        'email',
        'm1',
        'att-a',
        blobPath: '/tmp/cache/ab/abcd.pdf',
        blobSha256: 'abcd',
        thumbPath: '/tmp/cache/ab/abcd.thumb',
      );
      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'done',
        text: 'Two pages of terms.',
      );
      await store.setAttachmentPinned('email', 'm1', 'att-a', 'story-1');

      await store.clearAttachmentBlobs();

      final after = (await store.attachmentRow('email', 'm1', 'att-a'))!;
      expect(after['blob_path'], isNull);
      expect(after['blob_sha256'], isNull);
      expect(after['blob_fetched_at'], isNull);
      expect(after['thumb_path'], isNull);
      expect(after['name'], 'Q.pdf');
      expect(after['text_status'], 'done');
      expect(after['pinned_storyline_id'], 'story-1');
      expect(await store.attachmentTextOf('email', 'm1', 'att-a'),
          'Two pages of terms.');
    });

    test('wiping the mailbox empties all three attachment tables', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'done',
        text: 'Two pages of terms.',
      );
      await db.customUpdate(
        'INSERT INTO attachment_chunks '
        '(source, source_message_id, attachment_id, seq, locator, chunk_text, '
        ' chars, created_at) '
        "VALUES ('email', 'm1', 'att-a', 0, 'part 1', 'Two pages.', 10, "
        "'2026-09-04T10:00:00.000Z')",
      );

      await store.wipeAll();

      for (final table in const [
        'attachments',
        'attachment_text',
        'attachment_chunks',
      ]) {
        final rows = await db.customSelect('SELECT * FROM $table').get();
        expect(rows, isEmpty, reason: table);
      }
    });
  });

  group('the passages a document becomes', () {
    Future<List<Map<String, Object?>>> chunks() async {
      final rows = await db
          .customSelect('SELECT * FROM attachment_chunks ORDER BY seq')
          .get();
      return [for (final row in rows) row.data];
    }

    test('replacing them hands back the ids in the order they were given',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      final ids = await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: 'part 1', text: 'The tenant pays on the fourth.'),
        (seq: 1, locator: 'part 2', text: 'The term runs eighteen months.'),
      ]);

      // The embedder zips these against the chunks it split, so an id out of
      // order would file one passage's vector under another's row.
      expect(ids, hasLength(2));
      final stored = await chunks();
      expect(stored.map((c) => c['id']), ids);
      expect(stored.map((c) => c['locator']), ['part 1', 'part 2']);
      expect(stored.first['chars'], 'The tenant pays on the fourth.'.length);
      // Written un-embedded: the vectors arrive one POST later, and the
      // index's backfill deliberately cannot see a row until they do.
      expect(stored.first['embedding'], isNull);
      expect(stored.first['dims'], 0);
      expect(stored.first['indexed_at'], isNull);
    });

    test('replacing them again is a replacement, not a second copy', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: 'part 1', text: 'The tenant pays on the fourth.'),
        (seq: 1, locator: 'part 2', text: 'The term runs eighteen months.'),
      ]);

      // The chunker is deterministic, so a retry after a park re-derives
      // exactly these passages — and they replace themselves.
      final ids = await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: 'part 1', text: 'The tenant pays on the fourth.'),
        (seq: 1, locator: 'part 2', text: 'The term runs eighteen months.'),
      ]);

      expect(await chunks(), hasLength(2));
      expect((await chunks()).map((c) => c['id']), ids);
    });

    test('one document\'s passages are not another\'s', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('att-a'),
        row('att-b', ordinal: 1),
      ]);
      await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: '', text: 'The lease.'),
      ]);

      await store.replaceChunks('email', 'm1', 'att-b', const [
        (seq: 0, locator: '', text: 'The floor plan.'),
      ]);

      expect(await chunks(), hasLength(2));
    });

    test('an appended passage continues the sequence', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: 'part 1', text: 'The tenant pays on the fourth.'),
        (seq: 1, locator: 'part 2', text: 'The term runs eighteen months.'),
      ]);

      final id = await store.appendChunk(
        'email',
        'm1',
        'att-a',
        locator: 'digest',
        text: 'A lease addendum. The rent rises in January.',
      );

      final stored = await chunks();
      expect(stored.map((c) => c['seq']), [0, 1, 2]);
      expect(stored.last['id'], id);
      expect(stored.last['locator'], 'digest');
    });

    test('the first appended passage starts at zero', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      await store.appendChunk(
        'email',
        'm1',
        'att-a',
        locator: 'digest',
        text: 'A lease addendum.',
      );

      expect((await chunks()).single['seq'], 0);
    });

    test('an embedding lands and puts the row back on the index worklist',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      final ids = await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: '', text: 'The tenant pays on the fourth.'),
      ]);

      await store.setChunkEmbedding(
        ids.single,
        embedding: encodeEmbedding(List.filled(768, 0.1)),
        dims: 768,
        embedModel: EmbeddingsClient.documentModelTag,
      );

      final stored = (await chunks()).single;
      expect(stored['embedding'], isNotNull);
      expect(stored['dims'], 768);
      expect(stored['embed_model'], EmbeddingsClient.documentModelTag);
      expect(stored['embedded_at'], isNotNull);
      // Cleared, not stamped: stamping here would write the float into the
      // table and never into the index.
      expect(stored['indexed_at'], isNull);
    });

    test('the unembedded ones come back in document order', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      final ids = await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: 'part 1', text: 'One.'),
        (seq: 1, locator: 'part 2', text: 'Two.'),
        (seq: 2, locator: 'part 3', text: 'Three.'),
      ]);
      await store.setChunkEmbedding(
        ids.first,
        embedding: encodeEmbedding(List.filled(768, 0.1)),
        dims: 768,
        embedModel: EmbeddingsClient.documentModelTag,
      );

      // The resume path's worklist: what a park on the embedding server left
      // behind, and nothing else.
      final pending = await store.unembeddedChunks('email', 'm1', 'att-a');
      expect(pending.map((c) => c.text), ['Two.', 'Three.']);
    });

    test('a scope with no passages says so', () async {
      await seedMessage('m1');
      await seedMessage('m2');
      await store.upsertAttachments('email', 'm2', [row('att-a')]);
      await store.replaceChunks('email', 'm2', 'att-a', const [
        (seq: 0, locator: '', text: 'The term runs eighteen months.'),
      ]);

      // The guard the retriever runs before it spends a vector: another
      // message's passages are not this thread's.
      expect(
        await store.hasAttachmentChunks('email', messageIds: const ['m1']),
        isFalse,
      );
    });

    test('a scope with one says so', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: '', text: 'The tenant pays on the fourth.'),
      ]);

      expect(
        await store.hasAttachmentChunks('email', messageIds: const ['m1']),
        isTrue,
      );
      // The pinned half of the scope answers on its own, for a document from
      // another thread that somebody named.
      expect(
        await store.hasAttachmentChunks('email',
            attachmentIds: const ['att-a']),
        isTrue,
      );
    });

    test('asking about nothing is not asking about everything', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.replaceChunks('email', 'm1', 'att-a', const [
        (seq: 0, locator: '', text: 'The tenant pays on the fourth.'),
      ]);

      // An empty scope is false without a query, on `chunkKnn`'s rule: a
      // caller that cannot say which thread it is on gets nothing.
      expect(await store.hasAttachmentChunks('email'), isFalse);
    });
  });

  group('the message inside a forwarded attachment', () {
    test('the attached message\'s fields are kept when a later pass learns '
        'nothing', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a', kind: 'item')]);
      await store.setAttachmentItem(
        'email',
        'm1',
        'att-a',
        subject: 'Q3 forecast',
        from: 'dana@example.test',
        received: '2026-08-20T10:00:00Z',
      );

      // A text handler re-run answering `gone` knows no subject, and the
      // subject it does not know is not an empty subject.
      await store.setAttachmentItem('email', 'm1', 'att-a');
      await store.setAttachmentItem('email', 'm1', 'att-a', from: null);

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['item_subject'], 'Q3 forecast');
      expect(stored['item_from'], 'dana@example.test');
      expect(stored['item_received'], '2026-08-20T10:00:00Z');
    });

    test('one field learned late does not blank the two already known',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a', kind: 'item')]);
      await store.setAttachmentItem(
        'email',
        'm1',
        'att-a',
        subject: 'Q3 forecast',
        from: 'dana@example.test',
      );

      await store.setAttachmentItem(
        'email',
        'm1',
        'att-a',
        received: '2026-08-20T10:00:00Z',
      );

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['item_subject'], 'Q3 forecast');
      expect(stored['item_received'], '2026-08-20T10:00:00Z');
    });
  });

  group('what a link learns on its first read', () {
    test('resolving never shrinks a size or overwrites a known type', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('att-a', kind: 'reference', size: 5000),
      ]);

      // A listing that states less than a download already proved was
      // rounding, and a shrinking size would walk a file back under a cap it
      // had already failed. A type the connector named beats a guess made
      // while reading.
      await store.setAttachmentResolved(
        'email',
        'm1',
        'att-a',
        size: 100,
        contentType: 'text/plain',
      );

      var stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['size'], 5000);
      expect(stored['content_type'], 'application/pdf');

      await store.setAttachmentResolved('email', 'm1', 'att-a', size: 9000);

      stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['size'], 9000);
      expect(stored['content_type'], 'application/pdf');

      // Nothing learned is not a write. Nearly every attachment reaches this
      // method having taught it nothing.
      await store.setAttachmentResolved('email', 'm1', 'att-a');

      stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['size'], 9000);
      expect(stored['content_type'], 'application/pdf');
    });

    test('a link born typeless takes the type its first read stated', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row(
          'link-abc',
          kind: 'reference',
          name: 'HARBORLIGHT TALENT AGREEMENT.pdf',
          contentType: null,
          size: 0,
          sourceUrl: 'https://southbayequity2-my.sharepoint.com/:b:/g/x',
        ),
      ]);

      await store.setAttachmentResolved(
        'email',
        'm1',
        'link-abc',
        size: 2441466,
        contentType: 'application/pdf',
      );

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['size'], 2441466);
      expect(stored['content_type'], 'application/pdf');
    });
  });

  group('a text status that closes the digest', () {
    test('a skip after a successful read keeps the count and the cut',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      final words = 'a' * 40000;
      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'done',
        text: words,
        truncated: true,
      );

      // A requeue answering `gone`, or a gate applied after the fact. It has
      // no words, and having none says nothing about how many there were.
      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'skipped',
        reason: 'gone',
      );

      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['text_status'], 'skipped');
      expect(stored['text_reason'], 'gone');
      // The count and the cut would otherwise contradict the Text segment
      // still rendering forty thousand characters underneath them.
      expect(stored['text_chars'], 40000);
      expect(stored['text_truncated'], 1);
      expect(stored['digest_status'], 'skipped');
      expect(await store.attachmentTextOf('email', 'm1', 'att-a'), words);
    });

    test('a skip marks the digest skipped too', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'skipped',
        reason: 'no_extractor',
      );

      // No words means no digest, ever. Left `pending`, the chip would say
      // "reading…" for the life of the mailbox.
      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['digest_status'], 'skipped');
    });

    test('a done leaves the digest where the digest handler will find it',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'done',
        text: 'Two pages of terms.',
      );

      expect(
        (await store.attachmentsForMessage('email', 'm1')).single['digest_status'],
        'pending',
      );
    });

    test('a later text failure closes a digest that was already written',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await store.setAttachmentDigest(
        'email',
        'm1',
        'att-a',
        status: 'done',
        digestJson: '{"evidence":"","kind":"other","summary":"","facts":[],'
            '"asks":[]}',
      );

      await store.setAttachmentText(
        'email',
        'm1',
        'att-a',
        status: 'error',
        reason: 'unavailable',
      );

      // It IS overwritten, and deliberately: the words behind the digest are
      // gone, so the record of them is stale. What matters is that the chip
      // stops promising a digest that is never coming.
      final stored = (await store.attachmentsForMessage('email', 'm1')).single;
      expect(stored['digest_status'], 'skipped');
    });
  });

  group('counting the documents that ask for something', () {
    Future<void> digest(String attachmentId, {List<String> asks = const []}) =>
        store.setAttachmentDigest(
          'email',
          'm1',
          attachmentId,
          status: 'done',
          digestJson: jsonEncode(
            AttachmentDigest(
              evidence: 'A lease addendum.',
              kind: 'contract',
              summary: 'The rent rises.',
              facts: const ['2,600 from January'],
              asks: asks,
            ).toJson(),
          ),
        );

    test('a digest with asks counts and one without does not', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('att-a'),
        row('att-b', ordinal: 1),
      ]);

      await digest('att-a', asks: const ['Sign page four']);
      await digest('att-b');

      // A LIKE over the encoded JSON rather than a JSON1 extract: `toJson`
      // writes all five keys always, and `jsonEncode` emits `"asks":[` with no
      // spaces.
      expect(await store.attachmentsWithAsks('email', 'm1'), 1);
    });

    test('a digest that has not been written yet counts for nothing',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);

      expect(await store.attachmentsWithAsks('email', 'm1'), 0);
    });

    test('another message\'s asks are not this one\'s', () async {
      await seedMessage('m1');
      await seedMessage('m2', key: 'conv-2');
      await store.upsertAttachments('email', 'm1', [row('att-a')]);
      await digest('att-a', asks: const ['Sign page four']);

      expect(await store.attachmentsWithAsks('email', 'm2'), 0);
    });
  });

  group('the vector a retrieval is searched with', () {
    const tag = EmbeddingsClient.documentModelTag;

    Future<void> seedVector(String id, {String model = tag}) async {
      await store.upsertMessageVector(
        source: 'email',
        sourceMessageId: id,
        embedding: encodeEmbedding(List.filled(768, 0.1)),
        dims: 768,
        embeddedHash: 'h-$id',
        embedModel: model,
      );
    }

    test('answers the blob a message was embedded into', () async {
      await seedMessage('m1');
      await seedVector('m1');

      final blob = await store.messageVectorBlob('email', 'm1',
          embedModel: tag);

      expect(decodeEmbedding(blob!).length, 768);
    });

    test('and nothing at all under any other model tag', () async {
      await seedMessage('m1');
      await seedVector('m1', model: 'an-older-prefix');

      // Two vectors under two tags sit in different spaces, and a
      // nearest-neighbour search across both answers whatever the geometry
      // happens to say — which is worse than no answer, because it looks like
      // one. Null sends the caller to re-embed.
      expect(
        await store.messageVectorBlob('email', 'm1', embedModel: tag),
        isNull,
      );
    });

    test('a message that was never embedded has none', () async {
      await seedMessage('m1');

      expect(
        await store.messageVectorBlob('email', 'm1', embedModel: tag),
        isNull,
      );
    });
  });

  group('what a requeue carries', () {
    Future<Map<String, Object?>?> workRow(String entityId) async {
      final rows = await db.customSelect(
        "SELECT * FROM work_items WHERE task_kind = 'draft' AND entity_id = ?",
        variables: [Variable(entityId)],
      ).get();
      return rows.isEmpty ? null : rows.first.data;
    }

    test('a payload rides onto the row it queues', () async {
      await store.requeueWork(
        'draft',
        'email',
        'm1',
        payloadJson: '{"pinned_attachment_ids":["att-a"]}',
      );

      expect((await workRow('m1'))!['payload_json'],
          '{"pinned_attachment_ids":["att-a"]}');
    });

    test('and a later plain requeue clears the last one\'s', () async {
      await store.requeueWork('draft', 'email', 'm1',
          payloadJson: '{"pinned_attachment_ids":["att-a"]}');
      await store.writeWork('draft', 'email', 'm1', status: 'done');

      await store.requeueWork('draft', 'email', 'm1');

      // Asking again without naming a file has to mean the last file is no
      // longer named — a payload that survived would go on pinning it forever.
      final row = (await workRow('m1'))!;
      expect(row['payload_json'], isNull);
      expect(row['status'], 'pending');
    });

    test('a row a worker is holding keeps its payload and its claim', () async {
      await store.requeueWork('draft', 'email', 'm1',
          payloadJson: '{"pinned_attachment_ids":["att-a"]}');

      await store.requeueWork('draft', 'email', 'm1');

      // Still `pending` and never claimed, so the WHERE clause refused it —
      // and the payload it was queued with is untouched.
      expect((await workRow('m1'))!['payload_json'],
          '{"pinned_attachment_ids":["att-a"]}');
    });
  });
}
