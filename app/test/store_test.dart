import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

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
  late Database db;
  late MessageStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  group('schema', () {
    test('applies cleanly and is idempotent', () {
      applySchema(db);
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'] as String)
          .toSet();
      expect(tables, containsAll(['messages', 'conversations', 'sync_state']));
    });

    test('every table is STRICT', () {
      final ddl = db
          .select("SELECT sql FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['sql'] as String);
      for (final sql in ddl) {
        expect(sql, contains('STRICT'));
      }
    });

    test('STRICT rejects a TEXT value bound to an INTEGER column', () {
      // What STRICT actually buys: a mistyped write fails here rather than
      // being coerced and surfacing as a wrong number somewhere downstream.
      expect(
        () => db.execute(
          'INSERT INTO messages (source, source_message_id, conversation_key, '
          'direction, needs_action, created_at, updated_at) '
          "VALUES ('email', 'm', 'c', 'inbound', ?, 'now', 'now')",
          ['not-an-int'],
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('a Dart bool is coerced to 0/1 by the driver, not rejected', () {
      // Documents the behaviour MessageStore does NOT rely on: it binds
      // explicit ints so the write matches how needs_action is read back.
      db.execute(
        'INSERT INTO messages (source, source_message_id, conversation_key, '
        'direction, needs_action, created_at, updated_at) '
        "VALUES ('email', 'm', 'c', 'inbound', ?, 'now', 'now')",
        [true],
      );
      expect(db.select('SELECT needs_action FROM messages').single[
          'needs_action'], 1);
    });
  });

  group('upsertMessage', () {
    test('the same (source, source_message_id) twice leaves one row', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.upsertMessage(messageRow(id: 'm1', subject: 'Updated', isRead: 1));

      final rows = db.select('SELECT * FROM messages');
      expect(rows.length, 1);
      expect(rows.single['subject'], 'Updated');
      expect(rows.single['is_read'], 1);
    });

    test('a re-sync carrying no body does not clobber the stored body', () {
      store.upsertMessage(messageRow(id: 'm1', bodyText: 'The full body'));
      store.upsertMessage(
        messageRow(id: 'm1', bodyText: null, bodyPreview: null, isRead: 1),
      );

      final row = db.select('SELECT * FROM messages').single;
      expect(row['body_text'], 'The full body');
      expect(row['body_preview'], 'Preview');
      expect(row['is_read'], 1);
    });

    test('a completed triage survives a re-sync of the same message', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.writeTriage(
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
      store.upsertMessage(messageRow(id: 'm1', isRead: 1));

      final row = db.select('SELECT * FROM messages').single;
      expect(row['triage_status'], 'done');
      expect(row['urgency'], 'urgent');
      expect(row['needs_action'], 1);
    });

    test('the same id under a different source is a different row', () {
      // Pins the composite primary key: a Teams message and an email message
      // may legitimately share an id.
      store.upsertMessage(messageRow(id: 'shared-id', source: 'email'));
      store.upsertMessage(messageRow(id: 'shared-id', source: 'teams'));

      expect(db.select('SELECT * FROM messages').length, 2);
    });
  });

  group('loadThread', () {
    test('returns one conversation oldest-first', () {
      store.upsertMessage(messageRow(
          id: 'm2', receivedAt: '2026-08-28T12:00:00Z', bodyText: 'second'));
      store.upsertMessage(messageRow(
          id: 'm1', receivedAt: '2026-08-28T09:00:00Z', bodyText: 'first'));
      store.upsertMessage(messageRow(
          id: 'm3', receivedAt: '2026-08-28T15:00:00Z', bodyText: 'third'));
      store.upsertMessage(messageRow(id: 'other', conversationKey: 'conv-2'));

      final thread = store.loadThread('conv-1');
      expect(thread.map((m) => m.id).toList(), ['m1', 'm2', 'm3']);
      expect(thread.first.bodyText, 'first');
    });

    test('filters by source', () {
      store.upsertMessage(messageRow(id: 'm1', source: 'email'));
      store.upsertMessage(messageRow(id: 'm2', source: 'teams'));

      expect(store.loadThread('conv-1').length, 1);
      expect(store.loadThread('conv-1', sources: ['email', 'teams']).length, 2);
      expect(store.loadThread('conv-1', sources: const []), isEmpty);
    });
  });

  group('loadConversations', () {
    setUp(() {
      store.upsertConversation(conversationRow(
        key: 'c-old',
        state: 'waiting',
        lastMessageAt: '2026-08-20T10:00:00Z',
      ));
      store.upsertConversation(conversationRow(
        key: 'c-new',
        state: 'needs_reply',
        ctaText: 'Do the thing',
        ctaUrgency: 'urgent',
        lastMessageAt: '2026-08-28T10:00:00Z',
      ));
      store.upsertConversation(conversationRow(
        key: 'c-mid',
        state: 'done',
        lastMessageAt: '2026-08-25T10:00:00Z',
      ));
    });

    test('newest last_message_at first', () {
      expect(
        store.loadConversations().map((c) => c.id).toList(),
        ['c-new', 'c-mid', 'c-old'],
      );
    });

    test('the state filter narrows to one bucket', () {
      final needsReply =
          store.loadConversations(state: ConversationState.needsReply);
      expect(needsReply.length, 1);
      expect(needsReply.single.id, 'c-new');
      expect(needsReply.single.ctaText, 'Do the thing');
      expect(needsReply.single.ctaUrgency, CtaUrgency.urgent);

      expect(
        store.loadConversations(state: ConversationState.done).single.id,
        'c-mid',
      );
      expect(
        store.loadConversations(state: ConversationState.waiting).single.id,
        'c-old',
      );
    });

    test('an empty source list returns nothing rather than failing', () {
      expect(store.loadConversations(sources: const []), isEmpty);
    });

    test('the same key under a different source is a different row', () {
      store.upsertConversation(conversationRow(key: 'c-new', source: 'teams'));
      expect(
        store.loadConversations(sources: ['email', 'teams']).length,
        4,
      );
    });
  });

  group('setConversationState', () {
    test('flips the state and stamps state_changed_at', () {
      store.upsertConversation(conversationRow(key: 'c1', state: 'needs_reply'));
      expect(
        db.select('SELECT state_changed_at FROM conversations').single[
            'state_changed_at'],
        isNull,
      );

      store.setConversationState('email', 'c1', ConversationState.done);

      final row = db.select('SELECT * FROM conversations').single;
      expect(row['state'], 'done');
      expect(row['state_changed_at'], isNotNull);
      expect(store.loadConversations().single.state, ConversationState.done);
    });
  });

  group('delta links', () {
    test('round-trip, overwrite, and clear', () {
      expect(store.getDeltaLink('inbox'), isNull);

      store.setDeltaLink('inbox', 'https://graph/delta?token=1');
      expect(store.getDeltaLink('inbox'), 'https://graph/delta?token=1');

      store.setDeltaLink('inbox', 'https://graph/delta?token=2');
      expect(store.getDeltaLink('inbox'), 'https://graph/delta?token=2');
      expect(db.select('SELECT * FROM sync_state').length, 1);

      // A null link is "resync from scratch", not "leave what was there".
      store.setDeltaLink('inbox', null);
      expect(store.getDeltaLink('inbox'), isNull);
      expect(db.select('SELECT * FROM sync_state').length, 1);
    });

    test('folders and sources are keyed separately', () {
      store.setDeltaLink('inbox', 'a');
      store.setDeltaLink('archive', 'b');
      store.setDeltaLink('inbox', 'c', source: 'teams');

      expect(store.getDeltaLink('inbox'), 'a');
      expect(store.getDeltaLink('archive'), 'b');
      expect(store.getDeltaLink('inbox', source: 'teams'), 'c');
    });
  });

  group('triage', () {
    test('nextPendingTriage takes the newest pending inbound message', () {
      store.upsertMessage(messageRow(
          id: 'old-inbound', receivedAt: '2026-08-20T10:00:00Z'));
      store.upsertMessage(messageRow(
          id: 'new-inbound', receivedAt: '2026-08-28T10:00:00Z'));
      store.upsertMessage(messageRow(
        id: 'newest-outbound',
        direction: 'outbound',
        receivedAt: '2026-08-29T10:00:00Z',
      ));

      expect(store.nextPendingTriage()?['source_message_id'], 'new-inbound');
    });

    test('a triaged message drops out of the queue', () {
      store.upsertMessage(messageRow(
          id: 'a', receivedAt: '2026-08-28T10:00:00Z'));
      store.upsertMessage(messageRow(
          id: 'b', receivedAt: '2026-08-27T10:00:00Z'));

      store.writeTriage('email', 'a',
          status: 'done', result: TriageResult.fallback());
      expect(store.nextPendingTriage()?['source_message_id'], 'b');

      store.writeTriage('email', 'b', status: 'gated', gateReason: 'bulk');
      expect(store.nextPendingTriage(), isNull);
    });

    test('reviveErroredTriage flips errors below the ceiling back to pending',
        () {
      store.upsertMessage(messageRow(id: 'healable'));
      store.upsertMessage(messageRow(id: 'done-for'));
      store.writeTriage('email', 'healable',
          status: 'error', error: 'timeout', attempts: 2);
      store.writeTriage('email', 'done-for',
          status: 'error', error: 'timeout', attempts: 6);

      expect(store.reviveErroredTriage(), 1);

      final healed = store.db.select(
          'SELECT triage_status, triage_attempts FROM messages '
          "WHERE source_message_id = 'healable'").first;
      expect(healed['triage_status'], 'pending');
      // Kept, not reset — one more try per revival, permanent at the ceiling.
      expect(healed['triage_attempts'], 2);

      final capped = store.db.select(
          'SELECT triage_status FROM messages '
          "WHERE source_message_id = 'done-for'").first;
      expect(capped['triage_status'], 'error');
    });

    test('writeTriage records a result as columns, bools as 0/1', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.writeTriage(
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

      final row = db.select('SELECT * FROM messages').single;
      expect(row['triage_status'], 'done');
      expect(row['urgency'], 'high');
      expect(row['category'], 'rate_lock');
      expect(row['summary'], 'Extend or float');
      expect(row['needs_action'], 1);
      expect(row['triage_attempts'], 1);

      final m = store.loadThread('conv-1').single;
      expect(m.needsAction, isTrue);
      expect(m.actionItems, ['Quote the extension', 'Submit the lock']);
      expect(m.triageStatus, 'done');
    });

    test('writeTriage records an error and a gate reason without a result', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.writeTriage('email', 'm1',
          status: 'failed', error: 'model timed out', attempts: 3);

      final row = db.select('SELECT * FROM messages').single;
      expect(row['triage_status'], 'failed');
      expect(row['triage_error'], 'model timed out');
      expect(row['triage_attempts'], 3);
      // A failure must not invent a classification.
      expect(row['urgency'], isNull);
      expect(row['needs_action'], isNull);
    });

    test('a status-only write leaves an earlier result in place', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.writeTriage('email', 'm1',
          status: 'done', result: TriageResult.fallback());
      store.writeTriage('email', 'm1', status: 'stale');

      final row = db.select('SELECT * FROM messages').single;
      expect(row['triage_status'], 'stale');
      expect(row['urgency'], 'normal');
      expect(row['category'], 'other');
    });

    test('writeTriage only touches the addressed (source, id) pair', () {
      store.upsertMessage(messageRow(id: 'shared', source: 'email'));
      store.upsertMessage(messageRow(id: 'shared', source: 'teams'));

      store.writeTriage('email', 'shared', status: 'done');

      final rows = db.select(
          'SELECT source, triage_status FROM messages ORDER BY source');
      expect(rows[0]['source'], 'email');
      expect(rows[0]['triage_status'], 'done');
      expect(rows[1]['source'], 'teams');
      expect(rows[1]['triage_status'], 'pending');
    });

    test('triageCounts groups by status', () {
      store.upsertMessage(messageRow(id: 'a'));
      store.upsertMessage(messageRow(id: 'b'));
      store.upsertMessage(messageRow(id: 'c'));
      store.writeTriage('email', 'a', status: 'done');
      store.writeTriage('email', 'b', status: 'failed');

      expect(store.triageCounts(), {'pending': 1, 'done': 1, 'failed': 1});
    });

    test('triageCounts is scoped by source', () {
      store.upsertMessage(messageRow(id: 'a', source: 'email'));
      store.upsertMessage(messageRow(id: 'b', source: 'teams'));

      expect(store.triageCounts(), {'pending': 1});
      expect(store.triageCounts(sources: ['email', 'teams']), {'pending': 2});
      expect(store.triageCounts(sources: const []), isEmpty);
    });
  });

  group('wipeAll', () {
    test('empties every table, cursors and prefs included', () {
      store.upsertMessage(messageRow(id: 'm1'));
      store.setDeltaLink('inbox', 'cursor-1');
      store.setSenderPref('eric@x.com', 'later');
      store.recordFeedback(
        scope: 'thread',
        scopeKey: 'c1',
        direction: 'up',
        origin: 'explicit',
      );
      store.enqueueWork('extract', 'email', 'm1');

      store.wipeAll();

      for (final table in [
        'messages',
        'conversations',
        'sync_state',
        'work_items',
        'feedback_events',
        'sender_prefs',
      ]) {
        expect(
          store.db.select('SELECT COUNT(*) AS n FROM $table').first['n'],
          0,
          reason: '$table must not survive a sign-out — the next account '
              'must find nothing of this one',
        );
      }
      // The cursor read path agrees: a fresh sign-in starts a first-run sync.
      expect(store.getDeltaLink('inbox', source: 'email'), isNull);
    });
  });

  group('openDbAt', () {
    test("':memory:' opens a schema-applied database", () {
      final memory = openDbAt(':memory:');
      addTearDown(memory.close);
      expect(
        MessageStore(memory).loadConversations(),
        isEmpty,
      );
      expect(MessageStore(memory).triageCounts(), isEmpty);
    });
  });
}
