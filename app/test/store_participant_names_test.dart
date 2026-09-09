import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The one-off that gives a stored participant their name back.
///
/// Every recipient of the user's own mail landed as `{name: null, email}`
/// until the ingest learned to carry the name off `toRecipients`, so an
/// outbound-only thread shows a bare address wherever `participants_json` is
/// read. This fills them in from what the store already knows, and the
/// property that matters most is that it is IDEMPOTENT: it runs behind a
/// one-shot pref, and a second run must not rewrite rows or move their
/// `updated_at`, which is the keyword index's watermark.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedConversation(
    String key,
    String participantsJson, {
    String source = 'email',
  }) =>
      store.upsertConversation({
        'source': source,
        'conversation_key': key,
        'subject': key,
        'participants_json': participantsJson,
        'state': 'waiting',
        'last_message_at': '2026-09-01T09:00:00Z',
      });

  Future<void> seedMessage(
    String key,
    String id, {
    String? fromName,
    String? fromAddress,
    String receivedAt = '2026-09-01T09:00:00Z',
    String source = 'email',
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'inbound',
        'subject': key,
        'from_name': fromName,
        'from_address': fromAddress,
        'received_at': receivedAt,
        'body_text': 'A line.',
      });

  /// The participants of one thread, as `(name, email)` pairs.
  Future<List<(String?, String?)>> participantsOf(
    String key, {
    String source = 'email',
  }) async {
    final row = await store.getConversationRow(source, key);
    final decoded = jsonDecode(row!['participants_json'] as String) as List;
    return [
      for (final p in decoded)
        ((p as Map)['name'] as String?, p['email'] as String?),
    ];
  }

  test('a name on another thread fills the nameless one', () async {
    await seedConversation(
      'named',
      '[{"name":"Todd Alder","email":"todd@example.test"}]',
    );
    await seedConversation(
      'sent',
      '[{"name":null,"email":"todd@example.test"}]',
    );

    expect(await store.fillParticipantNames(), 1);
    expect(await participantsOf('sent'), [('Todd Alder', 'todd@example.test')]);
  });

  test('and a message\'s from_name does when no participant has one',
      () async {
    await seedMessage('inbound', 'inbound-m1',
        fromName: 'Priya Raman', fromAddress: 'priya@example.test');
    await seedConversation(
      'sent',
      '[{"name":null,"email":"priya@example.test"}]',
    );

    expect(await store.fillParticipantNames(), 1);
    expect(
      await participantsOf('sent'),
      [('Priya Raman', 'priya@example.test')],
    );
  });

  test('the newest from_name wins over an older one', () async {
    await seedMessage('a', 'a-m1',
        fromName: 'P. Raman',
        fromAddress: 'priya@example.test',
        receivedAt: '2026-01-01T09:00:00Z');
    await seedMessage('a', 'a-m2',
        fromName: 'Priya Raman',
        fromAddress: 'priya@example.test',
        receivedAt: '2026-09-01T09:00:00Z');
    await seedConversation(
      'sent',
      '[{"name":null,"email":"priya@example.test"}]',
    );

    await store.fillParticipantNames();
    expect(
      await participantsOf('sent'),
      [('Priya Raman', 'priya@example.test')],
    );
  });

  test('an empty-string name is filled too', () async {
    // The other shape a nameless recipient reaches the column in.
    await seedConversation(
      'named',
      '[{"name":"Todd Alder","email":"todd@example.test"}]',
    );
    await seedConversation(
      'sent',
      '[{"name":"","email":"todd@example.test"}]',
    );

    expect(await store.fillParticipantNames(), 1);
    expect(await participantsOf('sent'), [('Todd Alder', 'todd@example.test')]);
  });

  test('a name already there is left exactly as it is', () async {
    await seedMessage('inbound', 'inbound-m1',
        fromName: 'Theodore Alder', fromAddress: 'todd@example.test');
    await seedConversation(
      'kept',
      '[{"name":"Todd","email":"todd@example.test"},'
          '{"name":null,"email":"other@example.test"}]',
    );

    await store.fillParticipantNames();
    // The nameless one is untouched too — nobody has ever named that address.
    expect(await participantsOf('kept'), [
      ('Todd', 'todd@example.test'),
      (null, 'other@example.test'),
    ]);
  });

  test('an address nobody has named stays nameless, and counts as no change',
      () async {
    await seedConversation(
      'sent',
      '[{"name":null,"email":"nobody@example.test"}]',
    );
    await seedMessage('other', 'other-m1',
        fromName: 'Todd Alder', fromAddress: 'todd@example.test');

    expect(await store.fillParticipantNames(), 0);
    expect(await participantsOf('sent'), [(null, 'nobody@example.test')]);
  });

  test('a second run changes nothing', () async {
    await seedConversation(
      'named',
      '[{"name":"Todd Alder","email":"todd@example.test"}]',
    );
    await seedConversation(
      'sent',
      '[{"name":null,"email":"todd@example.test"}]',
    );

    expect(await store.fillParticipantNames(), 1);
    final after = (await store.getConversationRow('email', 'sent'))!;
    expect(await store.fillParticipantNames(), 0);
    final again = (await store.getConversationRow('email', 'sent'))!;

    // Not merely the same count: the row itself was not rewritten, so its
    // `updated_at` — the keyword index's watermark — did not move.
    expect(again['participants_json'], after['participants_json']);
    expect(again['updated_at'], after['updated_at']);
  });

  test('a chat row is handled the same way, and is simply never nameless',
      () async {
    await seedConversation(
      'chat-1',
      '[{"name":"Todd Alder","email":"teams:19:todd"}]',
      source: 'teams',
    );
    await seedConversation(
      'sent',
      '[{"name":null,"email":"todd@example.test"}]',
    );
    await seedMessage('inbound', 'inbound-m1',
        fromName: 'Todd Alder', fromAddress: 'todd@example.test');

    expect(await store.fillParticipantNames(), 1);
    expect(
      await participantsOf('chat-1', source: 'teams'),
      [('Todd Alder', 'teams:19:todd')],
    );
  });

  test('a malformed blob is skipped rather than thrown on', () async {
    await seedConversation('broken', 'not json at all "name":null');
    await seedConversation(
      'named',
      '[{"name":"Todd Alder","email":"todd@example.test"}]',
    );
    await seedConversation(
      'sent',
      '[{"name":null,"email":"todd@example.test"}]',
    );

    // The good row is still fixed: one bad blob must not strand the rest.
    expect(await store.fillParticipantNames(), 1);
    expect(await participantsOf('sent'), [('Todd Alder', 'todd@example.test')]);
  });

  test('an empty store is a no-op', () async {
    expect(await store.fillParticipantNames(), 0);
  });
}
