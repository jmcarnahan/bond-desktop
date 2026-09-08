// `show BondDatabase`: drift generates a row class named Conversation from
// the table, and this file means the app's own model.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The two reads behind the Drafts & sent pane, and the two read-time columns
/// on `loadConversations` that put a count on the rail beside them.
///
/// One rule runs through all four: what counts is the thread's NEWEST INBOUND
/// message. `getDraft` resolves the composer's suggestion by that subselect, so
/// these do too — a pane that listed a suggestion the composer would not offer
/// would be sending the reader to a thread with an empty box.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedInbound({
    required String id,
    String key = 'c1',
    String source = 'email',
    String receivedAt = '2026-09-03T10:00:00Z',
    String? deadline,
    String from = 'Dana Whitfield',
    String? fromAddress = 'dana@example.com',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': from,
      'from_address': fromAddress,
      'received_at': receivedAt,
      'body_text': 'the hero paragraph',
    });
    if (deadline != null) {
      // The one path that writes a deadline: triage reads it out of the
      // message in the sender's own words.
      await store.writeTriage(
        source,
        id,
        status: 'triaged',
        result: TriageResult(
          urgency: 'normal',
          category: 'work',
          summary: 'the hero paragraph',
          needsAction: true,
          actionItems: const [],
          deadline: deadline,
        ),
      );
    }
  }

  Future<void> seedConversation({
    String key = 'c1',
    String source = 'email',
    String subject = 'Homepage copy',
    String state = 'needs_reply',
  }) =>
      store.upsertConversation({
        'source': source,
        'conversation_key': key,
        'subject': subject,
        'state': state,
        'last_message_at': '2026-09-03T10:00:00Z',
      });

  group('the two read-time columns on loadConversations', () {
    test('latest_deadline is the NEWEST inbound message\'s, and only that one',
        () async {
      await seedConversation();
      await seedInbound(
        id: 'm1',
        receivedAt: '2026-09-01T10:00:00Z',
        deadline: 'by Wednesday',
      );
      await seedInbound(id: 'm2', receivedAt: '2026-09-03T10:00:00Z');

      final rows = await store.loadConversations();

      // The older message named a date; the newest did not. A deadline stated
      // three replies ago has already been answered or overtaken.
      expect(rows.single.latestDeadline, isNull);
    });

    test('and it is there when the newest inbound named one', () async {
      await seedConversation();
      await seedInbound(id: 'm1', receivedAt: '2026-09-01T10:00:00Z');
      await seedInbound(
        id: 'm2',
        receivedAt: '2026-09-03T10:00:00Z',
        deadline: 'by Friday',
      );

      final rows = await store.loadConversations();

      expect(rows.single.latestDeadline, 'by Friday');
    });

    test('pending_draft_count counts a suggestion on the newest inbound',
        () async {
      await seedConversation();
      await seedInbound(id: 'm1');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'Friday works.',
      );

      expect((await store.loadConversations()).single.pendingDraftCount, 1);
    });

    test('and not one written against an older message', () async {
      await seedConversation();
      await seedInbound(id: 'm1', receivedAt: '2026-09-01T10:00:00Z');
      await seedInbound(id: 'm2', receivedAt: '2026-09-03T10:00:00Z');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'an answer to what was said then',
      );

      // The row is still stored and still readable in the thread. It is simply
      // not what the composer would offer, so it is not work.
      expect((await store.loadConversations()).single.pendingDraftCount, 0);
    });

    test('a dismissed or sent suggestion stops counting', () async {
      await seedConversation();
      await seedInbound(id: 'm1');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'Friday works.',
      );

      await store.updateDraftStatus('email', 'm1', status: 'dismissed');
      expect((await store.loadConversations()).single.pendingDraftCount, 0);

      await store.updateDraftStatus('email', 'm1', status: 'sent');
      expect((await store.loadConversations()).single.pendingDraftCount, 0);
    });

    test('both are absent from a read that does not run the subqueries', () {
      // `fromRow` is what every other read reaches the model through, and a
      // row with neither column must read as "no date named" and "nothing
      // suggested" rather than inventing either.
      final bare = Conversation.fromRow({
        'conversation_key': 'c1',
        'source': 'email',
      });

      expect(bare.latestDeadline, isNull);
      expect(bare.pendingDraftCount, 0);
    });
  });

  group('pendingDrafts', () {
    test('lists the suggestion on the newest inbound, with who and subject',
        () async {
      await seedConversation();
      await seedInbound(id: 'm1');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'Friday works.',
      );

      final drafts = await store.pendingDrafts();

      expect(drafts, hasLength(1));
      expect(drafts.single.replyToMessageId, 'm1');
      expect(drafts.single.body, 'Friday works.');
      expect(drafts.single.who, 'Dana Whitfield');
      expect(drafts.single.subject, 'Homepage copy');
      expect(drafts.single.target, (source: 'email', conversationKey: 'c1'));
    });

    test('who falls back to the address when the message has no name',
        () async {
      await seedConversation();
      await seedInbound(id: 'm1', from: '');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'ok',
      );

      expect((await store.pendingDrafts()).single.who, 'dana@example.com');
    });

    test('a suggestion against an older message is history, not work',
        () async {
      await seedConversation();
      await seedInbound(id: 'm1', receivedAt: '2026-09-01T10:00:00Z');
      await seedInbound(id: 'm2', receivedAt: '2026-09-03T10:00:00Z');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'stale',
      );

      expect(await store.pendingDrafts(), isEmpty);
    });

    test('dismissed and sent are gone', () async {
      await seedConversation();
      await seedInbound(id: 'm1');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'ok',
      );

      await store.updateDraftStatus('email', 'm1', status: 'dismissed');
      expect(await store.pendingDrafts(), isEmpty);

      await store.updateDraftStatus('email', 'm1', status: 'sent');
      expect(await store.pendingDrafts(), isEmpty);
    });

    test('an edited suggestion is still waiting', () async {
      await seedConversation();
      await seedInbound(id: 'm1');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'ok',
        status: 'edited',
      );

      expect((await store.pendingDrafts()).single.status, 'edited');
    });

    test('a closed thread asks nothing of anybody', () async {
      await seedConversation(state: 'done');
      await seedInbound(id: 'm1');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'ok',
      );

      expect(await store.pendingDrafts(), isEmpty);
    });

    test('sources narrows it, and an empty set asks nothing at all', () async {
      await seedConversation();
      await seedInbound(id: 'm1');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'mail',
      );
      await seedConversation(key: 'chat-1', source: 'teams');
      await seedInbound(id: 't1', key: 'chat-1', source: 'teams');
      await store.upsertDraft(
        source: 'teams',
        conversationKey: 'chat-1',
        replyToMessageId: 't1',
        body: 'chat',
      );

      expect(
        [for (final d in await store.pendingDrafts(sources: const ['teams'])) d.body],
        ['chat'],
      );
      expect(await store.pendingDrafts(sources: const []), isEmpty);
    });

    test('newest-written first', () async {
      await seedConversation(key: 'c1');
      await seedInbound(id: 'm1', key: 'c1');
      await seedConversation(key: 'c2');
      await seedInbound(id: 'm2', key: 'c2');

      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'm1',
        body: 'first',
      );
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c2',
        replyToMessageId: 'm2',
        body: 'second',
      );

      final bodies = [for (final d in await store.pendingDrafts()) d.body];
      // `updated_at` is stamped by the store, so the second write is the newer
      // one however fast the two land.
      expect(bodies.first, 'second');
      expect(bodies, hasLength(2));
    });
  });

  group('recentOutbound', () {
    Future<void> seedSent({
      required String id,
      String key = 'c1',
      String source = 'email',
      String toJson = '["dana@example.com"]',
      String? receivedAt = '2026-09-03T11:00:00Z',
      String? preview,
      String? body,
    }) =>
        store.upsertMessage({
          'source': source,
          'source_message_id': id,
          'conversation_key': key,
          'direction': 'outbound',
          'subject': 'Homepage copy',
          'to_json': toJson,
          'received_at': receivedAt,
          'body_preview': preview,
          'body_text': body,
        });

    test('reads the outbound column back, newest first', () async {
      await seedSent(id: 'o1', receivedAt: '2026-09-01T11:00:00Z');
      await seedSent(id: 'o2', receivedAt: '2026-09-03T11:00:00Z');

      expect(
        [for (final row in await store.recentOutbound()) row.messageId],
        ['o2', 'o1'],
      );
    });

    test('never inbound mail', () async {
      await seedConversation();
      await seedInbound(id: 'm1');

      expect(await store.recentOutbound(), isEmpty);
    });

    test('the recipients are parsed the way a transcript parses them',
        () async {
      await seedSent(
        id: 'o1',
        toJson: '["dana@example.com","eric@example.com"]',
      );

      expect(
        (await store.recentOutbound()).single.to,
        ['dana@example.com', 'eric@example.com'],
      );
    });

    test('the preview falls back to the first line of the body', () async {
      await seedSent(id: 'o1', body: 'Friday works.\nSee you then.');

      expect((await store.recentOutbound()).single.preview, 'Friday works.');
    });

    test('and prefers a stored preview when there is one', () async {
      await seedSent(
        id: 'o1',
        preview: 'Friday works',
        body: 'something else entirely',
      );

      expect((await store.recentOutbound()).single.preview, 'Friday works');
    });

    test('an echo says so, and still shows up', () async {
      // The user watched the reply leave. A list that hid it until the Sent
      // Items copy synced would disagree with what they just did.
      await seedSent(id: 'local:abc', receivedAt: null);

      final rows = await store.recentOutbound();

      expect(rows.single.echo, isTrue);
      // `COALESCE(received_at, created_at)` — a row ordered on the null would
      // put the newest thing last.
      expect(rows.single.sentAt, isNotEmpty);
    });

    test('honours the limit', () async {
      for (var i = 0; i < 5; i++) {
        await seedSent(id: 'o$i', receivedAt: '2026-09-0${i + 1}T11:00:00Z');
      }

      expect(await store.recentOutbound(limit: 2), hasLength(2));
    });

    test('sources narrows it, and an empty set asks nothing at all', () async {
      await seedSent(id: 'o1');
      await seedSent(id: 't1', key: 'chat-1', source: 'teams');

      expect(
        [
          for (final row in await store.recentOutbound(sources: const ['teams']))
            row.messageId,
        ],
        ['t1'],
      );
      expect(await store.recentOutbound(sources: const []), isEmpty);
    });
  });
}
