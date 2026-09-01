import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart'
    show attentionThresholdKey;
import 'package:bond_inbox/services/attention_service.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Who asks for a draft, and when.
///
/// The list load does, off the scores the same load just wrote — and only for
/// threads that have earned one. It writes work rows and nothing else: nothing
/// on this path calls a model, and nothing on it calls Graph.

/// A [MailSync] that never touches a socket.
class FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late FakeSync sync;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    sync = FakeSync();
  });

  tearDown(() => db.close());

  Future<void> seedThread({
    required String key,
    String state = 'needs_reply',
    double score = 0.9,
    String? bucket,
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': '2026-08-29T10:00:00Z',
    });
    await store.writeAttentionScore('email', key, score);
    if (bucket != null) {
      await store.setConversationBucket('email', key, bucket: bucket);
    }
  }

  Future<List<String>> queuedDrafts() async => [
        for (final row in await db
            .customSelect(
              "SELECT entity_id FROM work_items WHERE task_kind = 'draft' "
              "AND status = 'pending' ORDER BY entity_id",
            )
            .get())
          row.data['entity_id'] as String,
      ];

  ConversationsNotifier notifierFor({AttentionService? attention}) {
    final notifier =
        ConversationsNotifier(store, sync, attention: attention);
    addTearDown(notifier.dispose);
    return notifier;
  }

  test('a load queues a draft for every thread that has earned one', () async {
    await seedThread(key: 'hot');
    await seedThread(key: 'cold', score: 0.1);
    await seedThread(key: 'done-with', state: 'done');

    await notifierFor().load();

    expect(await queuedDrafts(), ['hot']);
  });

  test('the stored threshold is what decides, not the default', () async {
    await seedThread(key: 'middling', score: 0.4);
    await store.setPref(attentionThresholdKey, '0.3');

    await notifierFor().load();

    expect(await queuedDrafts(), ['middling']);
  });

  test('an unparseable threshold falls back rather than throwing', () async {
    await seedThread(key: 'hot');
    await store.setPref(attentionThresholdKey, 'not a number');

    await notifierFor().load();

    expect(await queuedDrafts(), ['hot']);
  });

  test('a load that skips the sync still queues — it is a local read',
      () async {
    await seedThread(key: 'hot');

    await notifierFor().load(syncFirst: false);

    expect(await queuedDrafts(), ['hot']);
  });

  test('a second load queues nothing new once the draft exists', () async {
    await seedThread(key: 'hot');
    final notifier = notifierFor();

    await notifier.load();
    await store.writeWork('draft', 'email', 'hot', status: 'done');
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'hot',
      replyToMessageId: 'm1',
      body: 'already suggested',
    );
    await notifier.load();

    // The work row stays done: needsDraftKeys drops any thread that has a
    // draft, so the requeue never reaches it.
    expect(await queuedDrafts(), isEmpty);
    expect(await store.workCounts('draft'), {'done': 1});
  });

  test('a draft the sync invalidated is queued again', () async {
    await seedThread(key: 'hot');
    final notifier = notifierFor();
    await notifier.load();
    await store.writeWork('draft', 'email', 'hot', status: 'done');
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'hot',
      replyToMessageId: 'm1',
      body: 'stale',
    );

    // What a newer inbound message does.
    await store.deleteDraft('email', 'hot');
    await notifier.load();

    expect(await queuedDrafts(), ['hot']);
  });

  test('it does not revive an item a worker is holding', () async {
    await seedThread(key: 'hot');
    await store.enqueueWork('draft', 'email', 'hot');
    await store.writeWork('draft', 'email', 'hot', status: 'processing');

    await notifierFor().load();

    // Resetting a processing row would hand the item to a second drain.
    expect(await store.workCounts('draft'), {'processing': 1});
  });

  test('it runs after the scoring pass, on the scores that pass wrote',
      () async {
    // No score written by hand here: the AttentionService is what puts one on
    // the row, and the enqueue reads it in the same load.
    await store.upsertMessage({
      'source_message_id': 'm1',
      'conversation_key': 'scored',
      'direction': 'inbound',
      'from_address': 'sarah@x.com',
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'body_text': 'Can you confirm?',
    });
    await store.upsertConversation({
      'conversation_key': 'scored',
      'subject': 'Confirm',
      'state': 'needs_reply',
      'last_message_at': DateTime.now().toUtc().toIso8601String(),
      'last_inbound_at': DateTime.now().toUtc().toIso8601String(),
      'cta_urgency': 'urgent',
    });
    await store.setPref(attentionThresholdKey, '0.0');

    await notifierFor(attention: AttentionService(store)).load();

    expect(await queuedDrafts(), ['scored']);
  });
}
