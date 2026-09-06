import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
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
    test('attachments for a thread arrive oldest message first', () async {
      await seedMessage('m1', receivedAt: '2026-09-04T09:00:00.000Z');
      await seedMessage('m2', receivedAt: '2026-09-04T11:00:00.000Z');
      await store.upsertAttachments('email', 'm2', [row('att-late')]);
      await store.upsertAttachments('email', 'm1', [row('att-early')]);

      final thread = await store.attachmentsForThread('email', 'conv-1');

      expect(thread.map((r) => r['attachment_id']), ['att-early', 'att-late']);
      expect(thread.first['conversation_key'], 'conv-1');
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
}
