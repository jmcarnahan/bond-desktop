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
          category: 'rate_lock',
          summary: 'Extend or float',
          needsAction: true,
          actionItems: ['Quote the extension', 'Submit the lock'],
        ),
        attempts: 1,
      );

      final row = (await db.customSelect('SELECT * FROM messages').get()).single;
      expect(row.data['triage_status'], 'done');
      expect(row.data['urgency'], 'high');
      expect(row.data['category'], 'rate_lock');
      expect(row.data['summary'], 'Extend or float');
      expect(row.data['needs_action'], 1);
      expect(row.data['triage_attempts'], 1);

      final m = (await store.loadThread('conv-1')).single;
      expect(m.needsAction, isTrue);
      expect(m.actionItems, ['Quote the extension', 'Submit the lock']);
      expect(m.triageStatus, 'done');
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
