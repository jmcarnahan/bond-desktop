import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart'
    show attentionThresholdKey;
import 'package:bond_inbox/services/attention_service.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Later with a "when" in it.
///
/// Deferring a thread by hand now names a day — the one the sender asked for,
/// or a week — and the list load is what hands the thread back when that day
/// arrives. The two rules worth pinning: a SENDER rule never gets a date, and
/// a thread that comes back comes back as the user's own decision, so the
/// scoring sweep does not immediately file it again.
class _SilentSync implements MailSync {
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
  late _SilentSync sync;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    sync = _SilentSync();
  });

  tearDown(() => db.close());

  /// One thread with one inbound message, optionally carrying a deadline in
  /// the sender's own words.
  Future<void> seed(
    String key, {
    String from = 'eric@example.test',
    String? deadline,
    String receivedAt = '2026-08-28T10:00:00Z',
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': 'waiting',
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
    await store.upsertMessage({
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_address': from,
      'received_at': receivedAt,
    });
    if (deadline != null) {
      // The one path that writes a deadline: triage reads it out of the
      // message in the sender's own words.
      await store.writeTriage(
        'email',
        '$key-m1',
        status: 'triaged',
        result: TriageResult(
          urgency: 'normal',
          category: 'work',
          summary: 'the body',
          needsAction: true,
          actionItems: const [],
          deadline: deadline,
        ),
      );
    }
  }

  ConversationsNotifier notifier() =>
      ConversationsNotifier(store, sync, attention: AttentionService(store));

  /// The Needs You snapshot on one message's progress row.
  Future<int?> chipOf(String messageId) async {
    final rows = await db
        .customSelect(
          'SELECT needs_you FROM message_progress '
          "WHERE source = 'email' AND source_message_id = ?",
          variables: [Variable(messageId)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data['needs_you'] as int?;
  }

  /// A message judged a yes that settled WHILE its thread sat in Later, and
  /// so took a chip of 0 on the strength of the bucket alone.
  Future<void> settleJudgedInLater(String key) async {
    await store.writeNeedsYouVerdict(
      'email',
      '$key-m1',
      verdict: true,
      reason: 'asks the owner to confirm',
    );
    await PipelineProgress(store).noteSettled(
      'email',
      '$key-m1',
      needsYou: false,
      reason: 'not_worthy',
      dropped: false,
    );
    expect(await chipOf('$key-m1'), 0);
  }

  Future<Map<String, Object?>?> ai(String key) =>
      store.getConversationAi('email', key);

  List<Conversation> rows(ConversationsNotifier n) =>
      (n.state as ConversationsLoaded).conversations;

  Conversation rowFor(ConversationsNotifier n, String id) =>
      rows(n).firstWhere((c) => c.id == id);

  test('a deadline the sender named becomes the day it comes back', () async {
    // Far enough out that it stays in the future whenever this suite runs.
    final target = DateTime.now().add(const Duration(days: 40));
    final iso = '${target.year}-${target.month.toString().padLeft(2, '0')}-'
        '${target.day.toString().padLeft(2, '0')}';
    await seed('c1', deadline: 'by $iso please');
    final n = notifier();
    await n.load();

    await n.sendThreadToLater('email', 'c1');

    final stored = (await ai('c1'))?['snoozed_until'] as String?;
    expect(stored, isNotNull);
    final back = DateTime.parse(stored!).toLocal();
    expect(back.year, target.year);
    expect(back.month, target.month);
    expect(back.day, target.day);
    // Nine in the morning, not midnight: a thread that resurfaces overnight is
    // one nobody reads.
    expect(back.hour, 9);
    expect(rowFor(n, 'c1').bucket, 'later');
  });

  test('a thread nobody named a day for comes back in a week', () async {
    await seed('c1');
    final n = notifier();
    await n.load();

    await n.sendThreadToLater('email', 'c1');

    final stored = (await ai('c1'))?['snoozed_until'] as String?;
    final back = DateTime.parse(stored!).toLocal();
    final expected = DateTime.now().add(const Duration(days: 7));
    expect(back.day, expected.day);
    expect(back.month, expected.month);
    expect(back.hour, 9);
  });

  test('a caller naming the day gets exactly that day', () async {
    await seed('c1', deadline: 'Friday');
    final n = notifier();
    await n.load();

    final until = DateTime(2027, 4, 2, 9);
    await n.sendThreadToLater('email', 'c1', until: until);

    final stored = (await ai('c1'))?['snoozed_until'] as String?;
    expect(DateTime.parse(stored!).toLocal(), until);
    // The row on screen already carries it — the method reloads.
    expect(rowFor(n, 'c1').snoozedUntil, stored);
  });

  test('keeping a thread in the inbox clears the date with the bucket',
      () async {
    await seed('c1');
    final n = notifier();
    await n.load();
    await n.sendThreadToLater('email', 'c1');
    expect((await ai('c1'))?['snoozed_until'], isNotNull);

    await n.keepThreadInInbox('email', 'c1');

    final row = await ai('c1');
    expect(row?['bucket'], isNull);
    expect(row?['bucket_reason'], 'user');
    expect(row?['snoozed_until'], isNull);
  });

  test('a sender rule carries no date at all', () async {
    // A standing rule about a person has no "when" in it. Giving its threads
    // dates would hand them back one by one, exempting them from the rule the
    // user had just made.
    await seed('c1');
    await seed('c2');
    final n = notifier();
    await n.load();

    await n.sendSenderToLater('eric@example.test');

    expect((await ai('c1'))?['bucket'], 'later');
    expect((await ai('c1'))?['snoozed_until'], isNull);
    expect((await ai('c2'))?['snoozed_until'], isNull);
  });

  test('a date that has passed brings the thread back on the next load',
      () async {
    await seed('c1');
    final n = notifier();
    await n.load();
    await n.sendThreadToLater('email', 'c1');
    // Move the date into the past, the way a week of waiting would.
    await store.setSnoozedUntil('email', 'c1', '2020-01-01T09:00:00.000000Z');

    await n.load(syncFirst: false);

    // Back in the inbox rows, and back as the user's own decision — anything
    // else and the scoring sweep would own the row and re-file it.
    expect(rowFor(n, 'c1').bucket, isNull);
    expect(rowFor(n, 'c1').snoozedUntil, isNull);
    expect((await ai('c1'))?['bucket_reason'], 'user');
  });

  test('a thread that comes back on its date gets its chips back too',
      () async {
    // The snapshot follows the verdict, and no verdict moves when a bucket
    // lifts: without the raise the message would be back in the inbox with a
    // judged yes one table over and no chip, for good.
    await store.setPref(attentionThresholdKey, '0');
    await seed('c1');
    final n = ConversationsNotifier(
      store,
      sync,
      attention: AttentionService(store),
      progress: PipelineProgress(store),
    );
    await n.load();
    await n.sendThreadToLater('email', 'c1');
    await settleJudgedInLater('c1');
    await store.setSnoozedUntil('email', 'c1', '2020-01-01T09:00:00.000000Z');

    await n.load(syncFirst: false);

    expect(rowFor(n, 'c1').bucket, isNull);
    expect(await chipOf('c1-m1'), 1);
  });

  test('Keep in inbox gives the chips back the same way', () async {
    await store.setPref(attentionThresholdKey, '0');
    await seed('c1');
    final n = ConversationsNotifier(
      store,
      sync,
      attention: AttentionService(store),
      progress: PipelineProgress(store),
    );
    await n.load();
    await n.sendThreadToLater('email', 'c1');
    await settleJudgedInLater('c1');

    await n.keepThreadInInbox('email', 'c1');

    expect(rowFor(n, 'c1').bucket, isNull);
    expect(await chipOf('c1-m1'), 1);
  });

  test('a deferral still ahead of its date survives a load', () async {
    await seed('c1');
    final n = notifier();
    await n.load();
    await n.sendThreadToLater('email', 'c1');

    await n.load(syncFirst: false);

    expect(rowFor(n, 'c1').bucket, 'later');
    expect(rowFor(n, 'c1').snoozedUntil, isNotNull);
  });
}
