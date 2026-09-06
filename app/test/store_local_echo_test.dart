import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The three store methods a send leans on: writing the local echo of a
/// message that has left, removing it when the server's own copy lands, and
/// folding the conversation row the send just changed.
///
/// The delete is the one worth staring at. It is the only `DELETE FROM
/// messages` in this app, so every test here that widens it — a real row, a
/// row belonging to another message — is asserting on what the app CANNOT
/// destroy, not on what it can.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Map<String, Object?> row({
    required String id,
    String? internetMessageId = '<abc@bond.local>',
    String conversationKey = 'conv-1',
    String direction = 'outbound',
    String receivedAt = '2026-08-30T12:00:00Z',
  }) =>
      {
        'source': 'email',
        'source_message_id': id,
        'internet_message_id': internetMessageId,
        'conversation_key': conversationKey,
        'direction': direction,
        'received_at': receivedAt,
        'body_text': 'Friday works.',
        'is_read': 1,
        'triage_status': 'skipped',
        'gate_reason': 'outbound',
      };

  Future<List<String>> messageIds() async {
    final rows = await db
        .customSelect('SELECT source_message_id FROM messages ORDER BY 1')
        .get();
    return [for (final r in rows) r.data['source_message_id'] as String];
  }

  Future<List<String>> progressIds() async {
    final rows = await db
        .customSelect(
          'SELECT source_message_id FROM message_progress ORDER BY 1',
        )
        .get();
    return [for (final r in rows) r.data['source_message_id'] as String];
  }

  group('insertLocalEcho', () {
    test('writes the row and says so', () async {
      expect(await store.insertLocalEcho(row(id: 'local:d1')), isTrue);

      expect(await messageIds(), ['local:d1']);
      expect(await progressIds(), ['local:d1']);
    });

    test('refuses, and writes nothing, when the real copy already landed',
        () async {
      // The poll has no re-entrancy guard: a sync that started before the send
      // can ingest the Sent Items copy first. An echo written after it would
      // be a duplicate nothing is ever going to reconcile, because the delete
      // that would have removed it has already run.
      await store.upsertMessage(row(id: 'sent-1'));

      expect(await store.insertLocalEcho(row(id: 'local:d1')), isFalse);

      expect(await messageIds(), ['sent-1']);
      expect(await progressIds(), ['sent-1']);
    });

    test('is not blocked by another message that happens to be stored',
        () async {
      await store.upsertMessage(
        row(id: 'sent-other', internetMessageId: '<other@bond.local>'),
      );

      expect(await store.insertLocalEcho(row(id: 'local:d1')), isTrue);

      expect(await messageIds(), ['local:d1', 'sent-other']);
    });

    test('nor by an echo of its own, which is what a retry writes', () async {
      // Only a NON-local row means the copy landed. A second write of the same
      // echo is an upsert, not a refusal.
      await store.insertLocalEcho(row(id: 'local:d1'));

      expect(await store.insertLocalEcho(row(id: 'local:d1')), isTrue);

      expect(await messageIds(), ['local:d1']);
    });

    test('writes an echo with no internet message id, having nothing to check',
        () async {
      expect(
        await store.insertLocalEcho(row(id: 'local:d1', internetMessageId: null)),
        isTrue,
      );

      expect(await messageIds(), ['local:d1']);
    });
  });

  group('deleteLocalEcho', () {
    test('takes the echo and its progress row together', () async {
      await store.insertLocalEcho(row(id: 'local:d1'));

      expect(await store.deleteLocalEcho('email', '<abc@bond.local>'), 1);

      expect(await messageIds(), isEmpty);
      expect(await progressIds(), isEmpty,
          reason: 'a progress row with no message is a bar that never fills');
    });

    test('will not touch a real row, whatever it shares', () async {
      // The whole point of the LIKE guard: the Sent Items copy carries the
      // same internet message id, and it is the row that stays.
      await store.upsertMessage(row(id: 'sent-1'));

      expect(await store.deleteLocalEcho('email', '<abc@bond.local>'), 0);

      expect(await messageIds(), ['sent-1']);
      expect(await progressIds(), ['sent-1']);
    });

    test('leaves an echo of a different message alone', () async {
      await store.insertLocalEcho(row(id: 'local:d1'));
      await store.insertLocalEcho(
        row(id: 'local:d2', internetMessageId: '<other@bond.local>'),
      );

      expect(await store.deleteLocalEcho('email', '<abc@bond.local>'), 1);

      expect(await messageIds(), ['local:d2']);
      expect(await progressIds(), ['local:d2']);
    });

    test('and one belonging to another source', () async {
      await store.insertLocalEcho(row(id: 'local:d1'));

      expect(await store.deleteLocalEcho('teams', '<abc@bond.local>'), 0);

      expect(await messageIds(), ['local:d1']);
    });

    test('a second call removes nothing, which is what a page replay does',
        () async {
      await store.insertLocalEcho(row(id: 'local:d1'));
      await store.deleteLocalEcho('email', '<abc@bond.local>');

      expect(await store.deleteLocalEcho('email', '<abc@bond.local>'), 0);
    });
  });

  group('foldOutboundSend', () {
    Future<void> seed({
      String state = 'needs_reply',
      String lastInboundAt = '2026-08-29T10:00:00Z',
    }) async {
      await store.upsertMessage(row(
        id: 'in-1',
        direction: 'inbound',
        internetMessageId: '<in@bond.local>',
        receivedAt: lastInboundAt,
      ));
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'conv-1',
        'subject': 'Contract review',
        'participants_json': '[{"name":"Sarah","email":"sarah@x.com"}]',
        'state': state,
        'category': 'work',
        'cta_text': 'Send the redline',
        'cta_urgency': 'high',
        'last_message_at': lastInboundAt,
        'last_inbound_at': lastInboundAt,
        'last_message_preview': 'Any word on the contract?',
      });
      await store.recomputeConversationCounts('email', 'conv-1');
    }

    Future<Map<String, Object?>> conversation() async =>
        (await store.getConversationRow('email', 'conv-1'))!;

    test('moves the thread and its preview forward, and goes quiet', () async {
      await seed();

      await store.foldOutboundSend(
        'email',
        'conv-1',
        receivedAt: '2026-08-30T12:00:00Z',
        preview: 'Friday works.',
      );

      final conv = await conversation();
      expect(conv['last_message_at'], '2026-08-30T12:00:00Z');
      expect(conv['last_outbound_at'], '2026-08-30T12:00:00Z');
      expect(conv['last_message_preview'], 'Friday works.');
      expect(conv['state'], 'waiting');
    });

    test('never takes a thread off done', () async {
      // A human closed it. Only new inbound mail reopens a thread — the fold's
      // asymmetry, and this method borrows it rather than reimplementing it.
      await seed(state: 'done');

      await store.foldOutboundSend(
        'email',
        'conv-1',
        receivedAt: '2026-08-30T12:00:00Z',
        preview: 'Friday works.',
      );

      expect((await conversation())['state'], 'done');
    });

    test('leaves a thread asking when the reply predates its newest mail',
        () async {
      // A reply older than the message on the table answers nothing.
      await seed(lastInboundAt: '2026-08-31T10:00:00Z');

      await store.foldOutboundSend(
        'email',
        'conv-1',
        receivedAt: '2026-08-30T12:00:00Z',
        preview: 'Friday works.',
      );

      final conv = await conversation();
      expect(conv['state'], 'needs_reply');
      expect(conv['last_message_at'], '2026-08-31T10:00:00Z');
      expect(conv['last_message_preview'], 'Any word on the contract?');
      expect(conv['last_outbound_at'], '2026-08-30T12:00:00Z',
          reason: 'the outbound watermark still advances');
    });

    test('recomputes the counts, so the echo is one of them', () async {
      await seed();
      await store.insertLocalEcho(row(id: 'local:d1'));

      await store.foldOutboundSend(
        'email',
        'conv-1',
        receivedAt: '2026-08-30T12:00:00Z',
        preview: 'Friday works.',
      );

      final conv = await conversation();
      expect(conv['message_count'], 2);
      expect(conv['inbound_count'], 1);
    });

    test('carries the stored roster, category and CTA through untouched',
        () async {
      // `upsertConversation` overwrites participants and the CTA fields
      // unconditionally, so a field this call failed to pass back would be
      // erased by every send.
      await seed();

      await store.foldOutboundSend(
        'email',
        'conv-1',
        receivedAt: '2026-08-30T12:00:00Z',
        preview: 'Friday works.',
      );

      final conv = await conversation();
      expect(
        conv['participants_json'],
        '[{"name":"Sarah","email":"sarah@x.com"}]',
      );
      expect(conv['category'], 'work');
      expect(conv['cta_text'], 'Send the redline');
      expect(conv['cta_urgency'], 'high');
      expect(conv['subject'], 'Contract review');
    });

    test('does nothing at all for a thread with no stored row', () async {
      await store.foldOutboundSend(
        'email',
        'nothing-here',
        receivedAt: '2026-08-30T12:00:00Z',
        preview: 'Friday works.',
      );

      expect(await store.getConversationRow('email', 'nothing-here'), isNull);
    });
  });
}
