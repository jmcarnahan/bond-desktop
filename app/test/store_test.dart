import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import 'fixtures/test_db.dart';

/// A messages row with everything the NOT NULL columns need, overridable.
Map<String, Object?> messageRow({
  String source = 'email',
  required String id,
  String conversationKey = 'conv-1',
  String direction = 'inbound',
  String? subject = 'Subject',
  String? fromName = 'Sarah',
  String? fromAddress = 'sarah@x.com',
  String toJson = '["lo@x.com"]',
  String? receivedAt = '2026-08-28T10:00:00Z',
  int isRead = 0,
  String? bodyPreview = 'Preview',
  String? bodyText = 'Body',
  int addressedMe = 0,
  String triageStatus = 'pending',
}) =>
    {
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': subject,
      'from_name': fromName,
      'from_address': fromAddress,
      'to_json': toJson,
      'received_at': receivedAt,
      'is_read': isRead,
      'body_preview': bodyPreview,
      'body_text': bodyText,
      'addressed_me': addressedMe,
      'triage_status': triageStatus,
    };

Map<String, Object?> conversationRow({
  String source = 'email',
  required String key,
  String? subject = 'Subject',
  String participantsJson = '[]',
  String state = 'waiting',
  String ctaUrgency = 'normal',
  String? ctaText,
  int messageCount = 1,
  int inboundCount = 1,
  String? lastMessageAt = '2026-08-28T10:00:00Z',
}) =>
    {
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'participants_json': participantsJson,
      'state': state,
      'cta_text': ctaText,
      'cta_urgency': ctaUrgency,
      'message_count': messageCount,
      'inbound_count': inboundCount,
      'last_message_at': lastMessageAt,
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  group('schema', () {
    test('creates every table', () async {
      final tables = (await db
              .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
              .get())
          .map((r) => r.data['name'] as String)
          .toSet();
      expect(tables, containsAll(['messages', 'conversations', 'sync_state']));
    });

    test('every table is STRICT', () async {
      final ddl = (await db
              .customSelect("SELECT sql FROM sqlite_master WHERE type = 'table'")
              .get())
          .map((r) => r.data['sql'] as String);
      for (final sql in ddl) {
        expect(sql, contains('STRICT'));
      }
    });

    test('STRICT rejects a TEXT value bound to an INTEGER column', () async {
      // What STRICT actually buys: a mistyped write fails here rather than
      // being coerced and surfacing as a wrong number somewhere downstream.
      await expectLater(
        db.customUpdate(
          'INSERT INTO messages (source, source_message_id, conversation_key, '
          'direction, needs_action, created_at, updated_at) '
          "VALUES ('email', 'm', 'c', 'inbound', ?, 'now', 'now')",
          variables: [Variable('not-an-int')],
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('a Dart bool is coerced to 0/1 by the driver, not rejected', () async {
      // Documents the behaviour MessageStore does NOT rely on: it binds
      // explicit ints so the write matches how needs_action is read back.
      await db.customUpdate(
        'INSERT INTO messages (source, source_message_id, conversation_key, '
        'direction, needs_action, created_at, updated_at) '
        "VALUES ('email', 'm', 'c', 'inbound', ?, 'now', 'now')",
        variables: [Variable(true)],
      );
      expect(
          (await db.customSelect('SELECT needs_action FROM messages').get())
              .single
              .data['needs_action'],
          1);
    });
  });

  group('upsertMessage', () {
    test('the same (source, source_message_id) twice leaves one row', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store
          .upsertMessage(messageRow(id: 'm1', subject: 'Updated', isRead: 1));

      final rows = await db.customSelect('SELECT * FROM messages').get();
      expect(rows.length, 1);
      expect(rows.single.data['subject'], 'Updated');
      expect(rows.single.data['is_read'], 1);
    });

    test('a re-sync carrying no body does not clobber the stored body',
        () async {
      await store.upsertMessage(messageRow(id: 'm1', bodyText: 'The full body'));
      await store.upsertMessage(
        messageRow(id: 'm1', bodyText: null, bodyPreview: null, isRead: 1),
      );

      final row = (await db.customSelect('SELECT * FROM messages').get()).single;
      expect(row.data['body_text'], 'The full body');
      expect(row.data['body_preview'], 'Preview');
      expect(row.data['is_read'], 1);
    });

    test('a completed triage survives a re-sync of the same message', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage(
        'email',
        'm1',
        status: 'done',
        result: const TriageResult(
          urgency: 'urgent',
          category: 'closing',
          summary: 'Sign by Thursday',
          needsAction: true,
          actionItems: ['Sign the CD'],
        ),
      );
      await store.upsertMessage(messageRow(id: 'm1', isRead: 1));

      final row = (await db.customSelect('SELECT * FROM messages').get()).single;
      expect(row.data['triage_status'], 'done');
      expect(row.data['urgency'], 'urgent');
      expect(row.data['needs_action'], 1);
    });

    test('the same id under a different source is a different row', () async {
      // Pins the composite primary key: a Teams message and an email message
      // may legitimately share an id.
      await store.upsertMessage(messageRow(id: 'shared-id', source: 'email'));
      await store.upsertMessage(messageRow(id: 'shared-id', source: 'teams'));

      expect((await db.customSelect('SELECT * FROM messages').get()).length, 2);
    });

    test('addressed_me rises with a richer ingest and survives a thinner one',
        () async {
      // The deliberate exception to the INSERT-only rule the triage columns
      // take — but a one-way one. A connector that starts carrying mentions
      // can mark a message it already stored; a re-pull that computed 0 (a
      // backend switched before the server sends mentions, a keychain that
      // failed to answer this sync) must not take a flag back that an earlier,
      // richer pass earned.
      await store.upsertMessage(messageRow(id: 'm1'));
      expect((await store.getMessageRow('email', 'm1'))!['addressed_me'], 0);

      await store.upsertMessage(messageRow(id: 'm1', addressedMe: 1));
      expect((await store.getMessageRow('email', 'm1'))!['addressed_me'], 1);

      await store.upsertMessage(messageRow(id: 'm1'));
      expect((await store.getMessageRow('email', 'm1'))!['addressed_me'], 1);
    });

    test('a re-sync leaves the triage v2 columns where triage put them',
        () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage('email', 'm1',
          status: 'triaged',
          result: const TriageResult(
            urgency: 'normal',
            category: 'work',
            summary: 'Wants the CD by Friday',
            needsAction: true,
            actionItems: [],
            replyExpected: true,
            deadline: 'Friday',
          ));

      await store.upsertMessage(messageRow(id: 'm1', isRead: 1));

      final row = (await store.getMessageRow('email', 'm1'))!;
      expect(row['reply_expected'], 1);
      expect(row['deadline'], 'Friday');
    });
  });

  group('loadThread', () {
    test('returns one conversation oldest-first', () async {
      await store.upsertMessage(messageRow(
          id: 'm2', receivedAt: '2026-08-28T12:00:00Z', bodyText: 'second'));
      await store.upsertMessage(messageRow(
          id: 'm1', receivedAt: '2026-08-28T09:00:00Z', bodyText: 'first'));
      await store.upsertMessage(messageRow(
          id: 'm3', receivedAt: '2026-08-28T15:00:00Z', bodyText: 'third'));
      await store
          .upsertMessage(messageRow(id: 'other', conversationKey: 'conv-2'));

      final thread = await store.loadThread('conv-1');
      expect(thread.map((m) => m.id).toList(), ['m1', 'm2', 'm3']);
      expect(thread.first.bodyText, 'first');
    });

    test('filters by source', () async {
      await store.upsertMessage(messageRow(id: 'm1', source: 'email'));
      await store.upsertMessage(messageRow(id: 'm2', source: 'teams'));

      expect((await store.loadThread('conv-1')).length, 1);
      expect(
          (await store.loadThread('conv-1', sources: ['email', 'teams'])).length,
          2);
      expect(await store.loadThread('conv-1', sources: const []), isEmpty);
    });
  });

  group('loadConversations', () {
    setUp(() async {
      await store.upsertConversation(conversationRow(
        key: 'c-old',
        state: 'waiting',
        lastMessageAt: '2026-08-20T10:00:00Z',
      ));
      await store.upsertConversation(conversationRow(
        key: 'c-new',
        state: 'needs_reply',
        ctaText: 'Do the thing',
        ctaUrgency: 'urgent',
        lastMessageAt: '2026-08-28T10:00:00Z',
      ));
      await store.upsertConversation(conversationRow(
        key: 'c-mid',
        state: 'done',
        lastMessageAt: '2026-08-25T10:00:00Z',
      ));
    });

    test('newest last_message_at first', () async {
      expect(
        (await store.loadConversations()).map((c) => c.id).toList(),
        ['c-new', 'c-mid', 'c-old'],
      );
    });

    test('the state filter narrows to one bucket', () async {
      final needsReply =
          await store.loadConversations(state: ConversationState.needsReply);
      expect(needsReply.length, 1);
      expect(needsReply.single.id, 'c-new');
      expect(needsReply.single.ctaText, 'Do the thing');
      expect(needsReply.single.ctaUrgency, CtaUrgency.urgent);

      expect(
        (await store.loadConversations(state: ConversationState.done)).single.id,
        'c-mid',
      );
      expect(
        (await store.loadConversations(state: ConversationState.waiting))
            .single
            .id,
        'c-old',
      );
    });

    test('an empty source list returns nothing rather than failing', () async {
      expect(await store.loadConversations(sources: const []), isEmpty);
    });

    test('unread_count counts the unread inbound mail and nothing else',
        () async {
      await store.upsertMessage(messageRow(id: 'm1', conversationKey: 'c-new'));
      await store.upsertMessage(messageRow(id: 'm2', conversationKey: 'c-new'));
      await store.upsertMessage(
        messageRow(id: 'm3', conversationKey: 'c-new', isRead: 1),
      );
      // Outbound mail is never unread — the user wrote it.
      await store.upsertMessage(messageRow(
        id: 'm4',
        conversationKey: 'c-new',
        direction: 'outbound',
      ));

      final conversations = await store.loadConversations();
      final c = conversations.firstWhere((c) => c.id == 'c-new');
      expect(c.unreadCount, 2);
      expect(c.hasUnread, isTrue);
      // A thread with no messages stored has nothing unread, not null.
      expect(
        conversations.firstWhere((c) => c.id == 'c-old').unreadCount,
        0,
      );
    });

    test('the same key under a different source is a different row', () async {
      await store
          .upsertConversation(conversationRow(key: 'c-new', source: 'teams'));
      expect(
        (await store.loadConversations(sources: ['email', 'teams'])).length,
        4,
      );
    });
  });

  group('setConversationState', () {
    test('flips the state and stamps state_changed_at', () async {
      await store
          .upsertConversation(conversationRow(key: 'c1', state: 'needs_reply'));
      expect(
        (await db
                .customSelect('SELECT state_changed_at FROM conversations')
                .get())
            .single
            .data['state_changed_at'],
        isNull,
      );

      await store.setConversationState('email', 'c1', ConversationState.done);

      final row =
          (await db.customSelect('SELECT * FROM conversations').get()).single;
      expect(row.data['state'], 'done');
      expect(row.data['state_changed_at'], isNotNull);
      expect((await store.loadConversations()).single.state,
          ConversationState.done);
    });
  });

  group('delta links', () {
    test('round-trip, overwrite, and clear', () async {
      expect(await store.getDeltaLink('inbox'), isNull);

      await store.setDeltaLink('inbox', 'https://graph/delta?token=1');
      expect(await store.getDeltaLink('inbox'), 'https://graph/delta?token=1');

      await store.setDeltaLink('inbox', 'https://graph/delta?token=2');
      expect(await store.getDeltaLink('inbox'), 'https://graph/delta?token=2');
      expect(
          (await db.customSelect('SELECT * FROM sync_state').get()).length, 1);

      // A null link is "resync from scratch", not "leave what was there".
      await store.setDeltaLink('inbox', null);
      expect(await store.getDeltaLink('inbox'), isNull);
      expect(
          (await db.customSelect('SELECT * FROM sync_state').get()).length, 1);
    });

    test('folders and sources are keyed separately', () async {
      await store.setDeltaLink('inbox', 'a');
      await store.setDeltaLink('archive', 'b');
      await store.setDeltaLink('inbox', 'c', source: 'teams');

      expect(await store.getDeltaLink('inbox'), 'a');
      expect(await store.getDeltaLink('archive'), 'b');
      expect(await store.getDeltaLink('inbox', source: 'teams'), 'c');
    });
  });

  group('triage', () {
    test('nextPendingTriage takes the newest pending inbound message', () async {
      await store.upsertMessage(
          messageRow(id: 'old-inbound', receivedAt: '2026-08-20T10:00:00Z'));
      await store.upsertMessage(
          messageRow(id: 'new-inbound', receivedAt: '2026-08-28T10:00:00Z'));
      await store.upsertMessage(messageRow(
        id: 'newest-outbound',
        direction: 'outbound',
        receivedAt: '2026-08-29T10:00:00Z',
      ));

      expect((await store.nextPendingTriage())?['source_message_id'],
          'new-inbound');
    });

    test('a triaged message drops out of the queue', () async {
      await store
          .upsertMessage(messageRow(id: 'a', receivedAt: '2026-08-28T10:00:00Z'));
      await store
          .upsertMessage(messageRow(id: 'b', receivedAt: '2026-08-27T10:00:00Z'));

      await store.writeTriage('email', 'a',
          status: 'done', result: TriageResult.fallback());
      expect((await store.nextPendingTriage())?['source_message_id'], 'b');

      await store.writeTriage('email', 'b', status: 'gated', gateReason: 'bulk');
      expect(await store.nextPendingTriage(), isNull);
    });

    test('claimPendingTriage claims exactly the row the peek shows', () async {
      await store.upsertMessage(
          messageRow(id: 'a', receivedAt: '2026-08-28T10:00:00Z'));
      await store.upsertMessage(
          messageRow(id: 'b', receivedAt: '2026-08-27T10:00:00Z'));

      // The claim's ORDER BY mirrors the peek's — the documented contract,
      // and the only thing keeping the two from silently disagreeing.
      final peeked = await store.nextPendingTriage();
      final claimed = await store.claimPendingTriage();
      expect(claimed?['source_message_id'], peeked?['source_message_id']);

      // The returned row is the POST-update state: processing, with the
      // attempt count untouched — failures are what spend attempts.
      expect(claimed?['triage_status'], 'processing');
      expect(claimed?['triage_attempts'], 0);

      expect((await store.claimPendingTriage())?['source_message_id'], 'b');
      expect(await store.claimPendingTriage(), isNull,
          reason: 'both rows are claimed; nothing is pending');
      expect(await store.claimPendingTriage(sources: []), isNull,
          reason: 'no sources means no queue, never every queue');
    });

    test('reviveErroredTriage flips errors below the ceiling back to pending',
        () async {
      await store.upsertMessage(messageRow(id: 'healable'));
      await store.upsertMessage(messageRow(id: 'done-for'));
      await store.writeTriage('email', 'healable',
          status: 'error', error: 'timeout', attempts: 2);
      await store.writeTriage('email', 'done-for',
          status: 'error', error: 'timeout', attempts: 6);

      expect(await store.reviveErroredTriage(), 1);

      final healed = (await store.db.customSelect(
              'SELECT triage_status, triage_attempts FROM messages '
              "WHERE source_message_id = 'healable'")
          .get())
          .first;
      expect(healed.data['triage_status'], 'pending');
      // Kept, not reset — one more try per revival, permanent at the ceiling.
      expect(healed.data['triage_attempts'], 2);

      final capped = (await store.db.customSelect(
              'SELECT triage_status FROM messages '
              "WHERE source_message_id = 'done-for'")
          .get())
          .first;
      expect(capped.data['triage_status'], 'error');
    });

    test('writeTriage records a result as columns, bools as 0/1', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage(
        'email',
        'm1',
        status: 'done',
        result: const TriageResult(
          urgency: 'high',
          category: 'work',
          summary: 'Approve or push the date',
          needsAction: true,
          actionItems: ['Confirm the venue', 'Send the invite'],
        ),
        attempts: 1,
      );

      final row = (await db.customSelect('SELECT * FROM messages').get()).single;
      expect(row.data['triage_status'], 'done');
      expect(row.data['urgency'], 'high');
      expect(row.data['category'], 'work');
      expect(row.data['summary'], 'Approve or push the date');
      expect(row.data['needs_action'], 1);
      expect(row.data['triage_attempts'], 1);

      final m = (await store.loadThread('conv-1')).single;
      expect(m.needsAction, isTrue);
      expect(m.actionItems, ['Confirm the venue', 'Send the invite']);
      expect(m.triageStatus, 'done');
    });

    test('writeTriage round-trips reply_expected and the deadline', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage(
        'email',
        'm1',
        status: 'triaged',
        result: const TriageResult(
          urgency: 'normal',
          category: 'work',
          summary: 'Needs the signed CD',
          needsAction: true,
          actionItems: [],
          replyExpected: true,
          deadline: 'Friday',
        ),
      );

      final message = (await store.loadThread('conv-1')).single;
      expect(message.replyExpected, isTrue);
      expect(message.deadline, 'Friday');
    });

    test('a deadline the model did not offer is stored as NULL, not empty',
        () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage('email', 'm1',
          status: 'triaged', result: TriageResult.fallback());

      final row = (await store.getMessageRow('email', 'm1'))!;
      // The same rule `label` takes: a blank column and a column nobody wrote
      // must read alike, or every reader needs two empty cases.
      expect(row['deadline'], isNull);
      // A judgement of "no" is still a judgement, and it is what takes this
      // row out of the re-judgement pass's reach.
      expect(row['reply_expected'], 0);
    });

    test('a status-only write leaves an earlier reply_expected alone', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage('email', 'm1',
          status: 'triaged',
          result: const TriageResult(
            urgency: 'normal',
            category: 'work',
            summary: '',
            needsAction: false,
            actionItems: [],
            replyExpected: true,
            deadline: 'Monday',
          ));
      await store.writeTriage('email', 'm1', status: 'stale');

      final row = (await store.getMessageRow('email', 'm1'))!;
      expect(row['reply_expected'], 1);
      expect(row['deadline'], 'Monday');
    });

    test('a message triage v2 never judged reads null, never false', () async {
      await store.upsertMessage(messageRow(id: 'legacy'));

      final message = (await store.loadThread('conv-1')).single;
      // Load-bearing: "nobody asked" and "asked, and no reply is expected" are
      // opposite facts, and the re-judgement pass is the code that acts on the
      // difference.
      expect(message.replyExpected, isNull);
      expect(message.deadline, isNull);
      expect(message.addressedMe, isFalse);
    });

    test('writeTriage records an error and a gate reason without a result',
        () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage('email', 'm1',
          status: 'failed', error: 'model timed out', attempts: 3);

      final row = (await db.customSelect('SELECT * FROM messages').get()).single;
      expect(row.data['triage_status'], 'failed');
      expect(row.data['triage_error'], 'model timed out');
      expect(row.data['triage_attempts'], 3);
      // A failure must not invent a classification.
      expect(row.data['urgency'], isNull);
      expect(row.data['needs_action'], isNull);
    });

    test('a status-only write leaves an earlier result in place', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.writeTriage('email', 'm1',
          status: 'done', result: TriageResult.fallback());
      await store.writeTriage('email', 'm1', status: 'stale');

      final row = (await db.customSelect('SELECT * FROM messages').get()).single;
      expect(row.data['triage_status'], 'stale');
      expect(row.data['urgency'], 'normal');
      expect(row.data['category'], 'other');
    });

    test('writeTriage only touches the addressed (source, id) pair', () async {
      await store.upsertMessage(messageRow(id: 'shared', source: 'email'));
      await store.upsertMessage(messageRow(id: 'shared', source: 'teams'));

      await store.writeTriage('email', 'shared', status: 'done');

      final rows = await db
          .customSelect(
              'SELECT source, triage_status FROM messages ORDER BY source')
          .get();
      expect(rows[0].data['source'], 'email');
      expect(rows[0].data['triage_status'], 'done');
      expect(rows[1].data['source'], 'teams');
      expect(rows[1].data['triage_status'], 'pending');
    });

    test('triageCounts groups by status', () async {
      await store.upsertMessage(messageRow(id: 'a'));
      await store.upsertMessage(messageRow(id: 'b'));
      await store.upsertMessage(messageRow(id: 'c'));
      await store.writeTriage('email', 'a', status: 'done');
      await store.writeTriage('email', 'b', status: 'failed');

      expect(await store.triageCounts(), {'pending': 1, 'done': 1, 'failed': 1});
    });

    test('triageCounts is scoped by source', () async {
      await store.upsertMessage(messageRow(id: 'a', source: 'email'));
      await store.upsertMessage(messageRow(id: 'b', source: 'teams'));

      expect(await store.triageCounts(), {'pending': 1});
      expect(await store.triageCounts(sources: ['email', 'teams']),
          {'pending': 2});
      expect(await store.triageCounts(sources: const []), isEmpty);
    });
  });

  group('rejudgeStaleTriage', () {
    String ago(Duration age) =>
        DateTime.now().toUtc().subtract(age).toIso8601String();

    late String window;

    setUp(() => window = ago(const Duration(days: 7)));

    Future<String?> statusOf(String id, {String source = 'email'}) async =>
        (await store.getMessageRow(source, id))?['triage_status'] as String?;

    /// A message triage v1 finished with: judged, and carrying no answer to
    /// the question v2 asks.
    Future<void> judgedByV1(
      String id, {
      String source = 'email',
      String conversationKey = 'conv-1',
      String direction = 'inbound',
      Duration age = const Duration(days: 1),
    }) =>
        store.upsertMessage(messageRow(
          id: id,
          source: source,
          conversationKey: conversationKey,
          direction: direction,
          receivedAt: ago(age),
          triageStatus: 'triaged',
        ));

    test('only the newest inbound message of a thread goes back in the queue',
        () async {
      await judgedByV1('older', age: const Duration(days: 3));
      await judgedByV1('newest', age: const Duration(hours: 2));
      await judgedByV1('other-thread', conversationKey: 'conv-2');

      expect(
        await store.rejudgeStaleTriage(source: 'email', sinceIso: window),
        2,
      );

      // The standing ask lives on the last thing the other side said; asking
      // the model about the rest of the thread is spend with no answer in it.
      expect(await statusOf('newest'), 'pending');
      expect(await statusOf('other-thread'), 'pending');
      expect(await statusOf('older'), 'triaged');
    });

    test('a message v2 has already judged is never asked again', () async {
      await judgedByV1('judged');
      await store.writeTriage('email', 'judged',
          status: 'triaged', result: TriageResult.fallback());

      expect(
        await store.rejudgeStaleTriage(source: 'email', sinceIso: window),
        0,
      );
      // `reply_expected = 0` is an answer, not an absence — the predicate that
      // makes this pass self-exhausting reads NULL only.
      expect(await statusOf('judged'), 'triaged');
    });

    test('nothing older than the window is re-judged', () async {
      await judgedByV1('ancient', age: const Duration(days: 40));

      expect(
        await store.rejudgeStaleTriage(source: 'email', sinceIso: window),
        0,
      );
      expect(await statusOf('ancient'), 'triaged');
    });

    test('the user’s own messages stay out of it', () async {
      await judgedByV1('mine',
          conversationKey: 'conv-sent', direction: 'outbound');

      expect(
        await store.rejudgeStaleTriage(source: 'email', sinceIso: window),
        0,
      );
      expect(await statusOf('mine'), 'triaged');
    });

    test('the other source is left alone', () async {
      await judgedByV1('chat', source: 'teams', conversationKey: 'chat-1');

      expect(
        await store.rejudgeStaleTriage(source: 'email', sinceIso: window),
        0,
      );
      expect(await statusOf('chat', source: 'teams'), 'triaged');
    });

    test('a second pass flips nothing once v2 has answered', () async {
      await judgedByV1('m1');
      expect(
        await store.rejudgeStaleTriage(source: 'email', sinceIso: window),
        1,
      );

      // What the triage worker does with the row this pass queued.
      await store.writeTriage('email', 'm1',
          status: 'triaged', result: TriageResult.fallback());

      expect(
        await store.rejudgeStaleTriage(source: 'email', sinceIso: window),
        0,
        reason: 'the pass must exhaust itself rather than loop the mailbox '
            'through the model on every sync',
      );
      expect(await statusOf('m1'), 'triaged');
    });
  });

  group('addressed_me backfills', () {
    String ago(Duration age) =>
        DateTime.now().toUtc().subtract(age).toIso8601String();

    late String window;

    setUp(() => window = ago(const Duration(days: 7)));

    Future<Object?> addressedMe(String id, {String source = 'email'}) async =>
        (await store.getMessageRow(source, id))?['addressed_me'];

    test('mail addressed to the user alone is marked, and nothing else',
        () async {
      await store.upsertMessage(messageRow(
          id: 'sole', toJson: '["lo@bond.com"]', receivedAt: ago(const Duration(days: 1))));
      await store.upsertMessage(messageRow(
          id: 'cased', toJson: '["LO@Bond.com"]', receivedAt: ago(const Duration(days: 1))));
      await store.upsertMessage(messageRow(
          id: 'two-up',
          toJson: '["lo@bond.com","sarah@x.com"]',
          receivedAt: ago(const Duration(days: 1))));
      await store.upsertMessage(messageRow(
          id: 'somebody-else',
          toJson: '["sarah@x.com"]',
          receivedAt: ago(const Duration(days: 1))));
      await store.upsertMessage(messageRow(
          id: 'ancient',
          toJson: '["lo@bond.com"]',
          receivedAt: ago(const Duration(days: 40))));
      await store.upsertMessage(messageRow(
          id: 'mine',
          direction: 'outbound',
          toJson: '["lo@bond.com"]',
          receivedAt: ago(const Duration(days: 1))));

      expect(
        await store.backfillEmailAddressedMe(
            userAddress: 'lo@bond.com', sinceIso: window),
        2,
      );

      expect(await addressedMe('sole'), 1);
      expect(await addressedMe('cased'), 1,
          reason: 'addresses are compared case-insensitively');
      for (final id in ['two-up', 'somebody-else', 'ancient', 'mine']) {
        expect(await addressedMe(id), 0, reason: id);
      }
    });

    test('a recipient list that will not decode marks nothing', () async {
      await store.upsertMessage(messageRow(
          id: 'garbled', toJson: 'not json', receivedAt: ago(const Duration(days: 1))));

      expect(
        await store.backfillEmailAddressedMe(
            userAddress: 'lo@bond.com', sinceIso: window),
        0,
      );
      expect(await addressedMe('garbled'), 0);
    });

    test('inbound chat in a 1:1 is marked; a group chat is not', () async {
      await store.upsertConversation(conversationRow(
        source: 'teams',
        key: 'chat-1on1',
        participantsJson: '[{"name":"Sarah","email":"teams:u1"}]',
      ));
      await store.upsertConversation(conversationRow(
        source: 'teams',
        key: 'chat-group',
        participantsJson:
            '[{"name":"Sarah","email":"teams:u1"},{"name":"Ed","email":"teams:u2"}]',
      ));

      Future<void> chat(String id, String key,
              {String direction = 'inbound',
              Duration age = const Duration(days: 1)}) =>
          store.upsertMessage(messageRow(
            id: id,
            source: 'teams',
            conversationKey: key,
            direction: direction,
            receivedAt: ago(age),
          ));

      await chat('direct', 'chat-1on1');
      await chat('direct-mine', 'chat-1on1', direction: 'outbound');
      await chat('direct-ancient', 'chat-1on1', age: const Duration(days: 40));
      await chat('group', 'chat-group');

      expect(await store.backfillTeamsAddressedMe(sinceIso: window), 1);

      expect(await addressedMe('direct', source: 'teams'), 1);
      // The roster is stored without the user, so two participants is a group
      // — and an @mention inside one was never stored anywhere to be read back.
      expect(await addressedMe('group', source: 'teams'), 0);
      expect(await addressedMe('direct-mine', source: 'teams'), 0);
      expect(await addressedMe('direct-ancient', source: 'teams'), 0);
    });

    test('a teams database with no chats at all backfills nothing', () async {
      expect(await store.backfillTeamsAddressedMe(sinceIso: window), 0);
    });
  });

  group('wipeAll', () {
    test('empties every mail table, cursors included', () async {
      await store.upsertMessage(messageRow(id: 'm1'));
      await store.setDeltaLink('inbox', 'cursor-1');
      await store.setSenderPref('eric@x.com', 'later');
      await store.recordFeedback(
        scope: 'thread',
        scopeKey: 'c1',
        direction: 'up',
        origin: 'explicit',
      );
      await store.enqueueWork('extract', 'email', 'm1');
      await store.recordActivity(kind: 'sync_mail', status: 'ok', count: 1);

      await store.wipeAll();

      for (final table in [
        'messages',
        'conversations',
        'sync_state',
        'work_items',
        'feedback_events',
        'sender_prefs',
        'activity_events',
      ]) {
        expect(
          (await store.db
                  .customSelect('SELECT COUNT(*) AS n FROM $table')
                  .get())
              .first
              .data['n'],
          0,
          reason: '$table must not survive a sign-out — the next account '
              'must find nothing of this one',
        );
      }
      // The cursor read path agrees: a fresh sign-in starts a first-run sync.
      expect(await store.getDeltaLink('inbox', source: 'email'), isNull);
    });

    test('settings survive it; the ownership claim and about-me do not',
        () async {
      // Deliberately changed from "everything goes": what a wipe isolates is
      // one PERSON'S presence. Which backend this machine talks through and
      // which server it points at are the machine's configuration, and taking
      // them out made every account switch a re-setup. The identity claim
      // must not outlive the rows, or the next sign-in reads a wiped mailbox
      // as still owned and never claims it — and the about-me text is one
      // person's self-description, which the next identity must not inherit.
      await store.setPref('backend_mode', 'sdk');
      await store.setPref(aboutMeKey, 'An LO in Denver');
      await store.setPref(dbOwnerKey, 'ada@example.test');

      await store.wipeAll();

      expect(await store.getPref('backend_mode'), 'sdk');
      expect(await store.getPref(aboutMeKey), isNull);
      expect(await store.getPref(dbOwnerKey), isNull);
    });
  });

  group('BondDatabase.memory', () {
    test('opens a schema-applied database', () async {
      final memory = testDb();
      addTearDown(memory.close);
      expect(
        await MessageStore(memory).loadConversations(),
        isEmpty,
      );
      expect(await MessageStore(memory).triageCounts(), isEmpty);
    });
  });
}
