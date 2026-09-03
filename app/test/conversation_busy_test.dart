import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// What "the model is still working on this thread" is counted from.
///
/// Two subqueries in `loadConversations`, summed into
/// [Conversation.aiPendingCount]: the per-message steps (triage, extract) and
/// the thread-level ones (storyline, draft). The interesting half of this file
/// is what must NOT count — a read ack shares the work table AND the
/// conversation key, and counting one would make every thread the user opens
/// claim the model is thinking about it.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedThread({
    String key = 'conv-1',
    String source = 'email',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': key,
      'last_message_at': '2026-08-29T10:00:00Z',
    });
  }

  Future<void> seedMessage(
    String id, {
    String key = 'conv-1',
    String source = 'email',
    String direction = 'inbound',
    String triageStatus = 'triaged',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-29T10:00:00Z',
      'body_text': 'body of $id',
      'triage_status': triageStatus,
    });
  }

  Future<Conversation> only() async {
    final rows = await store.loadConversations(sources: const ['email']);
    expect(rows, hasLength(1));
    return rows.single;
  }

  test('a message still waiting on triage makes its thread busy', () async {
    await seedThread();
    await seedMessage('m1', triageStatus: 'pending');

    final c = await only();
    expect(c.aiPendingCount, 1);
    expect(c.isAiBusy, isTrue);
  });

  test('a message triage is holding right now counts too', () async {
    await seedThread();
    await seedMessage('m1', triageStatus: 'processing');

    expect((await only()).aiPendingCount, 1);
  });

  test('a triaged message with no work behind it is not busy', () async {
    await seedThread();
    await seedMessage('m1');

    final c = await only();
    expect(c.aiPendingCount, 0);
    expect(c.isAiBusy, isFalse);
  });

  test('an extract row counts, keyed by the message it belongs to', () async {
    await seedThread();
    await seedMessage('m1');
    await store.enqueueWork('extract', 'email', 'm1');

    expect((await only()).aiPendingCount, 1);
  });

  test('an outbound message never makes a thread busy', () async {
    await seedThread();
    await seedMessage('sent-1', direction: 'outbound', triageStatus: 'pending');

    expect((await only()).aiPendingCount, 0);
  });

  test('a storyline row keyed by the conversation counts', () async {
    await seedThread();
    await seedMessage('m1');
    await store.enqueueWork('storyline', 'email', 'conv-1');

    expect((await only()).aiPendingCount, 1);
  });

  test('a draft row keyed by the conversation counts', () async {
    await seedThread();
    await seedMessage('m1');
    await store.enqueueWork('draft', 'email', 'conv-1');

    expect((await only()).aiPendingCount, 1);
  });

  test('a read ack on the same conversation key counts for nothing', () async {
    await seedThread();
    await seedMessage('m1');
    // Same table, same source, same entity id as the storyline row above —
    // and telling Microsoft the user opened a thread is not the model
    // thinking about it.
    await store.enqueueWork('mark_read', 'email', 'conv-1');

    expect((await only()).aiPendingCount, 0);
  });

  test("the storyline sweep counts for nothing — it is nobody's thread",
      () async {
    await seedThread();
    await seedMessage('m1');
    await store.enqueueWork('storyline_sweep', 'email', 'sweep');

    expect((await only()).aiPendingCount, 0);
  });

  test('finished and failed work rows count for nothing', () async {
    await seedThread();
    await seedMessage('m1');
    await store.enqueueWork('draft', 'email', 'conv-1');
    await store.writeWork('draft', 'email', 'conv-1', status: 'done');
    await store.enqueueWork('storyline', 'email', 'conv-1');
    await store.writeWork('storyline', 'email', 'conv-1', status: 'error');

    expect((await only()).aiPendingCount, 0);
  });

  test('every open step on one thread adds up', () async {
    await seedThread();
    await seedMessage('m1', triageStatus: 'pending');
    await seedMessage('m2');
    await store.enqueueWork('extract', 'email', 'm2');
    await store.enqueueWork('storyline', 'email', 'conv-1');
    await store.enqueueWork('draft', 'email', 'conv-1');

    expect((await only()).aiPendingCount, 4);
  });

  test("one thread's work never lands on another's", () async {
    await seedThread();
    await seedThread(key: 'conv-2');
    await seedMessage('m1');
    await seedMessage('m2', key: 'conv-2', triageStatus: 'pending');

    final rows = await store.loadConversations(sources: const ['email']);
    final byKey = {for (final c in rows) c.id: c.aiPendingCount};
    expect(byKey, {'conv-1': 0, 'conv-2': 1});
  });

  group('the count survives what the UI does to a row', () {
    final busy = const Conversation(id: 'conv-1', aiPendingCount: 3);

    test('marking a thread done keeps it', () {
      expect(
        busy.copyWith(state: ConversationState.done).aiPendingCount,
        3,
      );
    });

    test('opening a thread keeps it', () {
      expect(busy.copyWith(unreadCount: 0).aiPendingCount, 3);
    });

    test('deferring a thread keeps it', () {
      expect(busy.withBucket('later').aiPendingCount, 3);
    });
  });

  test('a row read without the columns claims nothing', () {
    final c = Conversation.fromRow(const {
      'conversation_key': 'conv-1',
      'source': 'email',
    });

    expect(c.aiPendingCount, 0);
    expect(c.isAiBusy, isFalse);
  });

  test('a payload with no busy columns claims nothing either', () {
    expect(Conversation.fromJson(const {'id': 'conv-1'}).aiPendingCount, 0);
  });
}
