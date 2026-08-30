import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart'
    show attentionThresholdKey;
import 'package:bond_inbox/services/attention_service.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

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
  late Database db;
  late MessageStore store;
  late FakeSync sync;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
    sync = FakeSync();
  });

  tearDown(() => db.close());

  void seedThread({
    required String key,
    String state = 'needs_reply',
    double score = 0.9,
    String? bucket,
  }) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': '2026-08-29T10:00:00Z',
    });
    store.writeAttentionScore('email', key, score);
    if (bucket != null) {
      store.setConversationBucket('email', key, bucket: bucket);
    }
  }

  List<String> queuedDrafts() => [
        for (final row in db.select(
          "SELECT entity_id FROM work_items WHERE task_kind = 'draft' "
          "AND status = 'pending' ORDER BY entity_id",
        ))
          row['entity_id'] as String,
      ];

  ConversationsNotifier notifierFor({AttentionService? attention}) {
    final notifier =
        ConversationsNotifier(store, sync, attention: attention);
    addTearDown(notifier.dispose);
    return notifier;
  }

  test('a load queues a draft for every thread that has earned one', () async {
    seedThread(key: 'hot');
    seedThread(key: 'cold', score: 0.1);
    seedThread(key: 'done-with', state: 'done');

    await notifierFor().load();

    expect(queuedDrafts(), ['hot']);
  });

  test('the stored threshold is what decides, not the default', () async {
    seedThread(key: 'middling', score: 0.4);
    store.setPref(attentionThresholdKey, '0.3');

    await notifierFor().load();

    expect(queuedDrafts(), ['middling']);
  });

  test('an unparseable threshold falls back rather than throwing', () async {
    seedThread(key: 'hot');
    store.setPref(attentionThresholdKey, 'not a number');

    await notifierFor().load();

    expect(queuedDrafts(), ['hot']);
  });

  test('a load that skips the sync still queues — it is a local read',
      () async {
    seedThread(key: 'hot');

    await notifierFor().load(syncFirst: false);

    expect(queuedDrafts(), ['hot']);
  });

  test('a second load queues nothing new once the draft exists', () async {
    seedThread(key: 'hot');
    final notifier = notifierFor();

    await notifier.load();
    store.writeWork('draft', 'email', 'hot', status: 'done');
    store.upsertDraft(
      source: 'email',
      conversationKey: 'hot',
      replyToMessageId: 'm1',
      body: 'already suggested',
    );
    await notifier.load();

    // The work row stays done: needsDraftKeys drops any thread that has a
    // draft, so the requeue never reaches it.
    expect(queuedDrafts(), isEmpty);
    expect(store.workCounts('draft'), {'done': 1});
  });

  test('a draft the sync invalidated is queued again', () async {
    seedThread(key: 'hot');
    final notifier = notifierFor();
    await notifier.load();
    store.writeWork('draft', 'email', 'hot', status: 'done');
    store.upsertDraft(
      source: 'email',
      conversationKey: 'hot',
      replyToMessageId: 'm1',
      body: 'stale',
    );

    // What a newer inbound message does.
    store.deleteDraft('email', 'hot');
    await notifier.load();

    expect(queuedDrafts(), ['hot']);
  });

  test('it does not revive an item a worker is holding', () async {
    seedThread(key: 'hot');
    store.enqueueWork('draft', 'email', 'hot');
    store.writeWork('draft', 'email', 'hot', status: 'processing');

    await notifierFor().load();

    // Resetting a processing row would hand the item to a second drain.
    expect(store.workCounts('draft'), {'processing': 1});
  });

  test('it runs after the scoring pass, on the scores that pass wrote',
      () async {
    // No score written by hand here: the AttentionService is what puts one on
    // the row, and the enqueue reads it in the same load.
    store.upsertMessage({
      'source_message_id': 'm1',
      'conversation_key': 'scored',
      'direction': 'inbound',
      'from_address': 'sarah@x.com',
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'body_text': 'Can you confirm?',
    });
    store.upsertConversation({
      'conversation_key': 'scored',
      'subject': 'Confirm',
      'state': 'needs_reply',
      'last_message_at': DateTime.now().toUtc().toIso8601String(),
      'last_inbound_at': DateTime.now().toUtc().toIso8601String(),
      'cta_urgency': 'urgent',
    });
    store.setPref(attentionThresholdKey, '0.0');

    await notifierFor(attention: AttentionService(store)).load();

    expect(queuedDrafts(), ['scored']);
  });
}
