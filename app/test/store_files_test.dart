import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/files_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Files stop's one read: every file the mailbox holds, newest first.
///
/// What this file pins is the shape of the answer — the inner join that drops
/// a file whose message is gone, the order that makes a day grouping possible,
/// and the four kind filters, which run in SQL because a page and a
/// client-side filter cannot both be honest.
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
    String? fromName = 'Dana Whitfield',
    String? fromAddress = 'dana@example.com',
    String subject = 'The lease',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'subject': subject,
      'from_name': fromName,
      'from_address': fromAddress,
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

  group('what reaches the shelf', () {
    test('an inline logo is not a file anybody sent', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('logo', kind: 'image', contentType: 'image/png', isInline: true),
        row('terms'),
      ]);

      final files = await store.recentAttachments();

      expect(files.map((f) => f.ref.attachmentId), ['terms']);
    });

    test('a tiny picture still counts — there is no byte rule here', () async {
      // `inlineImageMinBytes` is about INLINE pictures, which are already gone
      // by the time this query runs. A 2 KB screenshot somebody attached on
      // purpose is a file.
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('shot', kind: 'image', contentType: 'image/png', size: 2048),
      ]);

      expect((await store.recentAttachments()).length, 1);
    });

    test('a file whose message is gone has no day and no thread, so it goes',
        () async {
      // No message row seeded at all: the inner join is what drops it.
      await store.upsertAttachments('email', 'orphan', [row('terms')]);

      expect(await store.recentAttachments(), isEmpty);
    });

    test('empty sources is an empty answer, not the whole mailbox', () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [row('terms')]);

      expect(await store.recentAttachments(sources: const []), isEmpty);
    });

    test('sources narrows to the connectors asked about', () async {
      await seedMessage('m1');
      await seedMessage('c1', source: 'teams', key: 'chat-1');
      await store.upsertAttachments('email', 'm1', [row('mail-file')]);
      await store.upsertAttachments('teams', 'c1', [row('chat-file')]);

      final chats = await store.recentAttachments(sources: const ['teams']);

      expect(chats.map((f) => f.ref.attachmentId), ['chat-file']);
    });
  });

  group('the order the shelf reads in', () {
    test('newest message first, then the connector order inside one', () async {
      await seedMessage('old', receivedAt: '2026-09-01T10:00:00.000Z');
      await seedMessage(
        'new',
        key: 'conv-2',
        receivedAt: '2026-09-05T10:00:00.000Z',
      );
      await store.upsertAttachments('email', 'old', [row('older')]);
      await store.upsertAttachments('email', 'new', [
        row('second', ordinal: 1),
        row('first'),
      ]);

      final files = await store.recentAttachments();

      expect(
        files.map((f) => f.ref.attachmentId),
        ['first', 'second', 'older'],
      );
    });

    test('a page is a page, and the next one carries on where it stopped',
        () async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('a', ordinal: 0),
        row('b', ordinal: 1),
        row('c', ordinal: 2),
      ]);

      final first = await store.recentAttachments(limit: 2);
      final second = await store.recentAttachments(limit: 2, offset: 2);

      expect(first.map((f) => f.ref.attachmentId), ['a', 'b']);
      expect(second.map((f) => f.ref.attachmentId), ['c']);
    });
  });

  group('the four kinds', () {
    Future<void> seedOneOfEach() async {
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('doc', name: 'Terms.pdf'),
        row('shot', ordinal: 1, kind: 'image', contentType: 'image/png'),
        // A picture the connector called a plain file, which only the content
        // type gives away.
        row(
          'photo',
          ordinal: 2,
          kind: 'file',
          name: 'Site.jpg',
          contentType: 'image/jpeg',
        ),
        row(
          'link',
          ordinal: 3,
          kind: 'reference',
          name: 'Budget.xlsx',
          contentType: null,
          sourceUrl: 'https://contoso.sharepoint.com/Budget.xlsx',
        ),
        row('card', ordinal: 4, kind: 'card', contentType: null),
      ]);
    }

    test('All is the whole shelf', () async {
      await seedOneOfEach();

      expect((await store.recentAttachments()).length, 5);
    });

    test('Images finds one by its kind and one by its content type', () async {
      await seedOneOfEach();

      final images =
          await store.recentAttachments(kind: FilesKind.images);

      expect(images.map((f) => f.ref.attachmentId), ['shot', 'photo']);
    });

    test('Links are the three kinds that point somewhere else', () async {
      await seedOneOfEach();

      final links = await store.recentAttachments(kind: FilesKind.links);

      expect(links.map((f) => f.ref.attachmentId), ['link', 'card']);
    });

    test('Documents is everything that is neither', () async {
      await seedOneOfEach();

      final documents =
          await store.recentAttachments(kind: FilesKind.documents);

      expect(documents.map((f) => f.ref.attachmentId), ['doc']);
    });

    test('a picture the connector described as nothing files under Documents',
        () async {
      // The accepted edge: Graph reports `application/octet-stream` for a great
      // many real files, and reading the NAME in SQL would cost the index. The
      // reader still finds it under All.
      await seedMessage('m1');
      await store.upsertAttachments('email', 'm1', [
        row('mystery', name: 'Site.png', contentType: 'application/octet-stream'),
      ]);

      expect(
        (await store.recentAttachments(kind: FilesKind.images)),
        isEmpty,
      );
      expect(
        (await store.recentAttachments(kind: FilesKind.documents)).length,
        1,
      );
    });
  });

  group('what a row carries out of the join', () {
    test('the thread, the sender, the direction and the subject', () async {
      await seedMessage(
        'm1',
        key: 'conv-9',
        subject: 'The lease addendum',
        fromName: 'Dana Whitfield',
        fromAddress: 'dana@example.com',
      );
      await store.upsertAttachments('email', 'm1', [row('terms')]);

      final file = (await store.recentAttachments()).single;

      expect(file.conversationKey, 'conv-9');
      expect(file.ref.conversationKey, 'conv-9');
      expect(file.fromName, 'Dana Whitfield');
      expect(file.fromAddress, 'dana@example.com');
      expect(file.outbound, isFalse);
      expect(file.subject, 'The lease addendum');
      expect(file.receivedAt, '2026-09-04T10:00:00.000Z');
      expect(file.source, 'email');
      expect(file.ref.name, 'terms.pdf');
    });

    test("the owner's own send says so", () async {
      await seedMessage('m1', direction: 'outbound');
      await store.upsertAttachments('email', 'm1', [row('terms')]);

      expect((await store.recentAttachments()).single.outbound, isTrue);
    });
  });
}
