import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The once-over that takes Exchange's first-contact tip off the rows stored
/// before the ingest learned to strip it.

const String _tip = "You don't often get email from dana@example.com. Learn "
    'why this is important<https://aka.ms/LearnAboutSenderIdentification>';

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seed(String id, {String? body, String? preview}) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'c-$id',
      'direction': 'inbound',
      'subject': 'Lease',
      'received_at': '2026-09-01T10:00:00Z',
      'body_text': body,
      'body_preview': preview,
    });
  }

  test('rows that open with the tip are rewritten, and counted', () async {
    await seed('m1', body: '$_tip\nThe lease.', preview: '$_tip\nThe lease.');
    await seed('m2', body: 'Plain.', preview: 'Plain.');
    // The words later in a body are the writer's own and stay.
    await seed('m3', body: 'Outlook said "You don\'t often get email from x".');

    expect(await store.stripSenderIdentificationTips(), 1);

    final m1 = (await store.getMessageRow('email', 'm1'))!;
    expect(m1['body_text'], 'The lease.');
    expect(m1['body_preview'], 'The lease.');
    final m3 = (await store.getMessageRow('email', 'm3'))!;
    expect(m3['body_text'], 'Outlook said "You don\'t often get email from x".');
  });

  test('a second pass finds nothing to do', () async {
    await seed('m1', body: '$_tip\nThe lease.');
    await store.stripSenderIdentificationTips();

    expect(await store.stripSenderIdentificationTips(), 0);
  });

  test('the rewrite moves the watermark, so the index refiles the row',
      () async {
    await seed('m1', body: '$_tip\nThe lease.');
    final before =
        (await store.getMessageRow('email', 'm1'))!['updated_at'] as String;

    await store.stripSenderIdentificationTips();

    final after =
        (await store.getMessageRow('email', 'm1'))!['updated_at'] as String;
    expect(after.compareTo(before), greaterThanOrEqualTo(0));
    expect(after, isNot(before));
  });
}
