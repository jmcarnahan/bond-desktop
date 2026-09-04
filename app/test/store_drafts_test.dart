import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The `drafts` table — keyed on the message a suggestion answers — and the
/// reads that feed drafting.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedMessage({
    required String id,
    String key = 'conv-1',
    String direction = 'inbound',
    String? receivedAt = '2026-08-29T10:00:00Z',
    String toJson = '[]',
    String? body,
    String? preview,
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'from_address': 'sarah@x.com',
      'received_at': receivedAt,
      'to_json': toJson,
      'body_text': body,
      'body_preview': preview,
    });
  }

  group('the schema', () {
    test('drafts is STRICT, like every other table', () async {
      final sql = (await db
                  .customSelect("SELECT sql FROM sqlite_master WHERE name = 'drafts'")
                  .get())
              .single
              .data['sql'] as String;
      expect(sql, contains('STRICT'));
      // AUTOINCREMENT would drag in sqlite's own sqlite_sequence table, which
      // is not STRICT.
      expect(sql, isNot(contains('AUTOINCREMENT')));
    });
  });

  group('CRUD', () {
    test('writes a draft and reads it back by the message it answers',
        () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'Friday works.',
        evidence: 'Sarah wants the lock extended.',
      );

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['body'], 'Friday works.');
      expect(draft['evidence'], 'Sarah wants the lock extended.');
      expect(draft['status'], 'suggested');
      expect(draft['conversation_key'], 'conv-1');
      expect(draft['created_at'], isNotNull);
    });

    test('getDraftForMessage is null for a message with none', () async {
      expect(await store.getDraftForMessage('email', 'nothing'), isNull);
    });

    test('a second question gets its own answer, not the first one rewritten',
        () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'answering the first',
      );
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'answering the second',
      );

      // The key is the message, so the thread now holds two suggestions and
      // each still says what it answered.
      expect((await store.getDraftForMessage('email', 'm1'))!['body'],
          'answering the first');
      expect((await store.getDraftForMessage('email', 'm2'))!['body'],
          'answering the second');
    });

    test('a regenerate replaces the whole draft, Outlook ids included',
        () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'first',
        evidence: 'first evidence',
      );
      await store.updateDraftStatus(
        'email',
        'm1',
        status: 'suggested',
        graphDraftId: 'g1',
        webLink: 'https://outlook/g1',
      );
      final createdAt =
          (await store.getDraftForMessage('email', 'm1'))!['created_at'];

      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'second',
      );

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['body'], 'second');
      expect(draft['evidence'], isNull);
      // The stale Outlook draft holds text nobody can see any more; a Send
      // pointing at it would send the version that was replaced.
      expect(draft['graph_draft_id'], isNull);
      expect(draft['web_link'], isNull);
      expect(draft['created_at'], createdAt,
          reason: 'when this message first got a suggestion does not change');
    });

    test('updateDraftStatus writes only the fields it carries', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'original',
        evidence: 'why',
      );

      await store.updateDraftStatus('email', 'm1', status: 'edited');
      var draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['status'], 'edited');
      expect(draft['body'], 'original');
      expect(draft['evidence'], 'why');

      await store.updateDraftStatus(
        'email',
        'm1',
        status: 'sent',
        body: 'what was actually sent',
        graphDraftId: 'g9',
      );
      draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['status'], 'sent');
      expect(draft['body'], 'what was actually sent');
      expect(draft['graph_draft_id'], 'g9');
      expect(draft['web_link'], isNull);
    });

    test('and it leaves the answers to the rest of the thread alone',
        () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'answering the first',
      );
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'answering the second',
      );

      await store.updateDraftStatus('email', 'm2', status: 'sent');

      // A thread-scoped UPDATE would mark the answer to a message nobody
      // replied to as sent.
      expect((await store.getDraftForMessage('email', 'm1'))!['status'],
          'suggested');
      expect(
          (await store.getDraftForMessage('email', 'm2'))!['status'], 'sent');
    });

    test('deleteDraftForMessage removes it', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'gone soon',
      );

      await store.deleteDraftForMessage('email', 'm1');

      expect(await store.getDraftForMessage('email', 'm1'), isNull);
    });

    test('drafts are per source as well as per message', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'email draft',
      );
      await store.upsertDraft(
        source: 'teams',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'teams draft',
      );

      expect((await store.getDraftForMessage('email', 'm1'))!['body'],
          'email draft');
      expect((await store.getDraftForMessage('teams', 'm1'))!['body'],
          'teams draft');
    });
  });

  /// What a THREAD shows: the answer to the message it is waiting on, and
  /// nothing else. This is what replaced the sync deleting drafts — an answer
  /// to an older message is still stored, and simply is not what this returns.
  group('the thread read', () {
    test('is the suggestion written for the newest inbound message', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm2',
        body: 'answering the newest',
      );

      expect((await store.getDraft('email', 'conv-1'))!['body'],
          'answering the newest');
    });

    test('and a newer message that has none reads as no suggestion at all',
        () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'answering what was said before',
      );
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');

      // The stale answer is still on disk against m1; nothing had to delete it
      // for the thread to stop offering it.
      expect(await store.getDraft('email', 'conv-1'), isNull);
      expect(await store.getDraftForMessage('email', 'm1'), isNotNull);
    });

    test('the user\'s own mail never becomes the message a thread waits on',
        () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedMessage(
        id: 'o1',
        direction: 'outbound',
        receivedAt: '2026-08-30T10:00:00Z',
      );
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'still the answer',
      );

      expect((await store.getDraft('email', 'conv-1'))!['body'],
          'still the answer');
    });

    test('ties break on source_message_id DESC, like newestInboundMessage',
        () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      await seedMessage(id: 'm9', receivedAt: '2026-08-29T10:00:00Z');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm9',
        body: 'answering m9',
      );

      // Both reads have to agree on which message the thread is waiting on, or
      // the draft would be written against one and read against the other.
      expect(
          (await store.getDraft('email', 'conv-1'))!['body'], 'answering m9');
    });

    test('a thread with nothing inbound has nothing to show', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'answering a message nobody stored',
      );

      expect(await store.getDraft('email', 'conv-1'), isNull);
    });

    test('it is keyed by connector as well as by thread', () async {
      await seedMessage(id: 'm1');
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'm1',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'received_at': '2026-08-29T10:00:00Z',
      });
      await store.upsertDraft(
        source: 'teams',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'the chat answer',
      );

      expect(await store.getDraft('email', 'conv-1'), isNull);
      expect(
          (await store.getDraft('teams', 'conv-1'))!['body'], 'the chat answer');
    });
  });

  group('quick-reply options', () {
    const options =
        '[{"stance":"Confirm Friday","body":"Friday works."},'
        '{"stance":"Propose Tuesday","body":"Could we say Tuesday?"}]';

    test('round-trips the options JSON, undismissed', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'the long one',
        optionsJson: options,
      );

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['options_json'], options);
      expect(draft['options_dismissed'], 0);
    });

    test('a draft written without options reads as none', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'the long one',
      );

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['options_json'], isNull);
      expect(draft['options_dismissed'], 0);
    });

    test('dismissDraftOptions sets the flag and keeps the row', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'the long one',
        optionsJson: options,
      );

      await store.dismissDraftOptions('email', 'm1');

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(draft['options_dismissed'], 1);
      // The row survives, the same way a dismissed draft does — deleting it
      // would let the next pass write the identical options straight back.
      expect(draft['options_json'], options);
      expect(draft['body'], 'the long one');
    });

    test('a regenerate replaces the options AND clears the dismissal',
        () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'first',
        optionsJson: options,
      );
      await store.dismissDraftOptions('email', 'm1');

      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'second',
        optionsJson: '[{"stance":"Decline politely","body":"Not this week."}]',
      );

      final draft = (await store.getDraftForMessage('email', 'm1'))!;
      expect(
        draft['options_json'],
        '[{"stance":"Decline politely","body":"Not this week."}]',
      );
      // Closing the LAST set of cards must not silence a set the user has
      // never seen.
      expect(draft['options_dismissed'], 0);
    });

    test('a regenerate that offers none clears the stored options', () async {
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'first',
        optionsJson: options,
      );

      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'second',
      );

      expect((await store.getDraftForMessage('email', 'm1'))!['options_json'],
          isNull);
    });
  });

  group('newestInboundMessage', () {
    test('is the latest inbound one, outbound ignored', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      await seedMessage(
        id: 'o1',
        direction: 'outbound',
        receivedAt: '2026-08-30T10:00:00Z',
      );

      expect(
        (await store.newestInboundMessage('email', 'conv-1'))![
            'source_message_id'],
        'm2',
      );
    });

    test('ties break on source_message_id DESC', () async {
      // Two messages stamped the same second are common; without the tie-break
      // sqlite would be free to pick a different one on every read.
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      await seedMessage(id: 'm9', receivedAt: '2026-08-29T10:00:00Z');
      await seedMessage(id: 'm5', receivedAt: '2026-08-29T10:00:00Z');

      expect(
        (await store.newestInboundMessage('email', 'conv-1'))![
            'source_message_id'],
        'm9',
      );
    });

    test('is null for a thread with nothing inbound', () async {
      await seedMessage(id: 'o1', direction: 'outbound');

      expect(await store.newestInboundMessage('email', 'conv-1'), isNull);
    });
  });

  /// The two pieces of the embedding card that live on the message side. The
  /// storyline prompts read them, and they arrive in one query so a thread
  /// whose extraction has not run yet still answers with its summary.
  group('newestInboundCardData', () {
    Future<void> summarise(String id, String summary) => db.customStatement(
          'UPDATE messages SET summary = ? WHERE source_message_id = ?',
          [summary, id],
        );

    test('is the newest inbound message summary and its extraction', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-20T10:00:00Z');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T10:00:00Z');
      await summarise('m1', 'The older message.');
      await summarise('m2', 'Asks what time to come on Friday.');
      await store.writeExtraction('email', 'm1', '{"topics":["stale"]}');
      await store.writeExtraction(
          'email', 'm2', '{"topics":["dinner plans","scheduling"]}');

      final data = await store.newestInboundCardData('email', 'conv-1');

      expect(data!['summary'], 'Asks what time to come on Friday.');
      expect(data['extraction_json'], '{"topics":["dinner plans","scheduling"]}');
    });

    test('a thread whose extraction has not run still answers', () async {
      await seedMessage(id: 'm1');
      await summarise('m1', 'Asks what time to come on Friday.');

      final data = await store.newestInboundCardData('email', 'conv-1');

      // The LEFT JOIN is the whole point: an inner one would drop this thread
      // and cost it the summary it does have.
      expect(data!['summary'], 'Asks what time to come on Friday.');
      expect(data['extraction_json'], isNull);
    });

    test('is null for a thread with nothing inbound', () async {
      await seedMessage(id: 'o1', direction: 'outbound');

      expect(await store.newestInboundCardData('email', 'conv-1'), isNull);
    });
  });

  group('recentOutboundToSender', () {
    test('finds the user\'s replies to one address, newest first', () async {
      await seedMessage(
        id: 'o1',
        direction: 'outbound',
        toJson: '["sarah@x.com"]',
        receivedAt: '2026-08-20T10:00:00Z',
        body: 'older reply',
      );
      await seedMessage(
        id: 'o2',
        direction: 'outbound',
        toJson: '["sarah@x.com","cc@x.com"]',
        receivedAt: '2026-08-28T10:00:00Z',
        body: 'newer reply',
      );

      final rows = await store.recentOutboundToSender('email', 'sarah@x.com');

      expect(rows.map((r) => r['body_text']), ['newer reply', 'older reply']);
    });

    test('matches case-insensitively and respects the limit', () async {
      for (var i = 0; i < 5; i++) {
        await seedMessage(
          id: 'o$i',
          direction: 'outbound',
          toJson: '["Sarah@X.com"]',
          receivedAt: '2026-08-2${i}T10:00:00Z',
          body: 'reply $i',
        );
      }

      expect(await store.recentOutboundToSender('email', 'SARAH@x.com'),
          hasLength(2));
      expect(
        await store.recentOutboundToSender('email', 'sarah@x.com', limit: 4),
        hasLength(4),
      );
    });

    test('never returns inbound mail, and nothing for an empty address',
        () async {
      await seedMessage(id: 'm1', toJson: '["sarah@x.com"]');

      expect(
          await store.recentOutboundToSender('email', 'sarah@x.com'), isEmpty);
      expect(await store.recentOutboundToSender('email', ''), isEmpty);
    });
  });

}
