// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/read_ack_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The drain behind "I opened it, so it is read".
///
/// The rows it eats are written by [MessageStore.markConversationRead], so
/// every case here seeds them the way the app does — by reading a thread —
/// rather than by hand: a payload this file invented could disagree with the
/// one the app writes and nothing would notice.
///
/// The stubs are local to this file, following what the other queue tests do
/// to each other: neither can break the other by editing its stub.

/// A [MailBackend] that records every ack and answers with the ids it was told
/// to refuse. Only [markRead] is implemented — anything else this queue calls
/// would be a bug, and an UnimplementedError says so louder than an empty map.
class _FakeMail implements MailBackend {
  /// One entry per [markRead] call, in order.
  final List<List<String>> acks = [];

  /// Ids to report as retryable-failed. Everything else is accepted.
  final Set<String> refuse;

  /// Thrown instead of answering.
  Object? error;

  _FakeMail({this.refuse = const {}, this.error});

  @override
  Future<List<String>> markRead(
    List<String> messageIds, {
    bool isRead = true,
  }) async {
    acks.add(List.of(messageIds));
    final thrown = error;
    if (thrown != null) throw thrown;
    return [
      for (final id in messageIds)
        if (refuse.contains(id)) id,
    ];
  }

  @override
  Future<DeltaPage> deltaPage(
    String folder, {
    String? link,
    String? minReceivedIso,
  }) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> getMessageDetail(String id) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) =>
      throw UnimplementedError();

  @override
  Future<void> updateDraftBody(String draftId, String text) =>
      throw UnimplementedError();

  @override
  Future<void> sendDraft(String draftId) => throw UnimplementedError();
}

/// A [TeamsBackend] that records every chat it was told to mark read.
///
/// Only [markChatRead] is implemented, for [_FakeMail]'s reason: a chat ack is
/// one call against the conversation, and anything else this queue reached for
/// would be a bug worth an UnimplementedError.
class _FakeTeams implements TeamsBackend {
  /// One entry per [markChatRead] call, in order.
  final List<String> acks = [];

  /// Thrown instead of answering. Set after construction, since the queue is
  /// built in `setUp` and a failure is a per-test decision.
  Object? error;

  @override
  Future<void> markChatRead(String chatId) async {
    acks.add(chatId);
    final thrown = error;
    if (thrown != null) throw thrown;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A session that grants exactly what it was built with.
class _FakeAuth implements AuthSession {
  final Set<String> scopes;

  _FakeAuth({this.scopes = const {'mail.readwrite', 'chat.readwrite'}});

  @override
  Future<bool> hasScope(String bareScope) async => scopes.contains(bareScope);

  @override
  Future<bool> get isSignedIn async => true;

  @override
  Future<bool> get needsReconsent async => false;

  @override
  Future<AccountInfo?> get storedAccount async => null;

  @override
  Future<AccountInfo> signIn() => throw UnimplementedError();

  @override
  Future<void> signOut() => throw UnimplementedError();
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _FakeMail mail;
  late _FakeTeams teams;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    mail = _FakeMail();
    teams = _FakeTeams();
  });

  tearDown(() => db.close());

  ReadAckQueue queueWith({
    _FakeAuth? auth,
    ActivityLog? log,
  }) =>
      ReadAckQueue(
        store,
        mail,
        teams,
        auth ?? _FakeAuth(),
        activityLog: log,
      );

  /// One unread inbound message, on `c1` unless told otherwise.
  Future<void> message(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String receivedAt = '2026-08-28T10:00:00Z',
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': conversationKey,
        'direction': 'inbound',
        'is_read': 0,
        'received_at': receivedAt,
      });

  Future<Map<String, Object?>> workRow(
    String entityId, {
    String source = 'email',
  }) async {
    final rows = await db
        .customSelect("SELECT * FROM work_items WHERE task_kind = 'mark_read'")
        .get();
    return rows
        .map((row) => row.data)
        .singleWhere((row) =>
            row['entity_id'] == entityId && row['source'] == source);
  }

  group('a queued ack', () {
    test('sends exactly the ids the thread flipped, and is then done',
        () async {
      await message('m1');
      await message('m2', receivedAt: '2026-08-28T11:00:00Z');
      await store.markConversationRead('email', 'c1');

      await queueWith().pump();

      expect(mail.acks.single, ['m2', 'm1'],
          reason: 'the payload as written, newest first');
      final row = await workRow('c1');
      expect(row['status'], 'done');
      expect(row['attempts'], 0);
    });

    test('a backend that returns nothing is a success, deletions and all',
        () async {
      // Ids the server no longer has are the BACKEND's problem: it drops a 404
      // rather than reporting it, so from here an empty answer is the only
      // shape success has.
      await message('m1');
      await store.markConversationRead('email', 'c1');

      await queueWith().pump();

      expect((await workRow('c1'))['status'], 'done');
    });

    test('a row naming no ids is done, not failed', () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');
      await db.customUpdate(
        "UPDATE work_items SET payload_json = '{oops' "
        "WHERE task_kind = 'mark_read'",
      );

      await queueWith().pump();

      expect(mail.acks, isEmpty, reason: 'there is nothing to ask about');
      expect((await workRow('c1'))['status'], 'done');
    });

    test('a second pump with nothing pending opens no socket', () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');
      final queue = queueWith();

      await queue.pump();
      await queue.pump();

      expect(mail.acks, hasLength(1));
    });
  });

  group('failure', () {
    test('one refused id spends an attempt and leaves the row pending',
        () async {
      await message('m1');
      await message('m2', receivedAt: '2026-08-28T11:00:00Z');
      mail = _FakeMail(refuse: {'m1'});
      await store.markConversationRead('email', 'c1');

      await queueWith().pump();

      final row = await workRow('c1');
      expect(row['status'], 'pending');
      expect(row['attempts'], 1);
      expect(row['error'], contains('1 of 2'));
    });

    test('the third failure parks the row', () async {
      await message('m1');
      mail = _FakeMail(refuse: {'m1'});
      await store.markConversationRead('email', 'c1');
      final queue = queueWith();

      await queue.pump();
      await queue.pump();
      await queue.pump();

      final row = await workRow('c1');
      expect(row['status'], 'error');
      expect(row['attempts'], 3);
      expect(mail.acks, hasLength(3),
          reason: 'three tries, and the parked row is not tried a fourth time '
              'inside the same drain');
    });

    test('a thrown failure counts the same as a refused id', () async {
      await message('m1');
      mail = _FakeMail(error: StateError('graph is down'));
      await store.markConversationRead('email', 'c1');

      await queueWith().pump();

      final row = await workRow('c1');
      expect(row['status'], 'pending');
      expect(row['attempts'], 1);
      expect(row['error'], contains('graph is down'));
    });

    test('a parked row is revived by the next pump, not by nothing', () async {
      await message('m1');
      mail = _FakeMail(refuse: {'m1'});
      await store.markConversationRead('email', 'c1');
      final queue = queueWith();
      for (var i = 0; i < 3; i++) {
        await queue.pump();
      }
      expect((await workRow('c1'))['status'], 'error');

      // Reviving buys one more attempt per pump, never a reset: the row is
      // only truly back to zero when the user opens the thread again.
      mail.refuse.clear();
      await queue.pump();

      final row = await workRow('c1');
      expect(row['status'], 'done');
      expect(row['attempts'], 3);
    });
  });

  group('the session ending', () {
    test('leaves the row pending, unattempted, and stops the drain', () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');
      await message('m2', conversationKey: 'c2');
      await store.markConversationRead('email', 'c2');
      mail = _FakeMail(error: const NotSignedIn());

      await queueWith().pump();

      expect(mail.acks, hasLength(1),
          reason: 'a dead session fails every ack identically, so nothing '
              'behind the first one is worth trying');
      for (final key in ['c1', 'c2']) {
        final row = await workRow(key);
        expect(row['status'], 'pending', reason: '$key survived');
        expect(row['attempts'], 0,
            reason: '$key: the session broke, not the item');
      }
    });
  });

  group('capability', () {
    test('without the write scope the row is skipped and nothing is sent',
        () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');

      // mail.read but not mail.readwrite: a readable session whose grant
      // definitively lacks the write half.
      await queueWith(auth: _FakeAuth(scopes: const {'mail.read'})).pump();

      expect(mail.acks, isEmpty,
          reason: 'the grant already says this cannot work — finding out from '
              'a 403 per thread would spend the requests to learn it');
      expect((await workRow('c1'))['status'], 'skipped');
    });

    test('a skipped row is not revived by a later pump', () async {
      await message('m1');
      await store.markConversationRead('email', 'c1');
      final queue = queueWith(auth: _FakeAuth(scopes: const {'mail.read'}));

      await queue.pump();
      await queue.pump();

      expect((await workRow('c1'))['status'], 'skipped');
      expect(mail.acks, isEmpty);
    });

    test('a session that cannot answer at all parks the row, not skips it',
        () async {
      // hasScope answers false to EVERYTHING when there is no grant to read —
      // a failed probe, an MCP server mid-restart, a signed-out launch. That
      // false must not be spent as the terminal `skipped`: the row waits.
      await message('m1');
      await store.markConversationRead('email', 'c1');
      final queue = queueWith(auth: _FakeAuth(scopes: const {}));

      await queue.pump();

      expect(mail.acks, isEmpty);
      final row = await workRow('c1');
      expect(row['status'], 'pending',
          reason: 'a dead probe is "not now", never "never"');
      expect(row['attempts'], 0);

      // And the session coming back is all it takes.
      await queueWith().pump();
      expect(mail.acks.single, ['m1']);
      expect((await workRow('c1'))['status'], 'done');
    });
  });

  group('chats', () {
    test('are acked by the chat, through the Teams backend, not the mail one',
        () async {
      // The whole shape of a Teams ack. The entity id IS the chat, and the
      // message ids the payload names are covered by construction: Teams keeps
      // one read viewpoint per conversation and moving it to the newest message
      // marks everything behind it read. Sending those ids anywhere — least of
      // all to the MAIL backend — would be the wrong call entirely.
      await message('chat-m1', source: 'teams', conversationKey: 'chat-1');
      await message('chat-m2',
          source: 'teams',
          conversationKey: 'chat-1',
          receivedAt: '2026-08-28T11:00:00Z');
      await store.markConversationRead('teams', 'chat-1');

      await queueWith().pump();

      expect(teams.acks, ['chat-1']);
      expect(mail.acks, isEmpty);
      final row = await workRow('chat-1', source: 'teams');
      expect(row['status'], 'done');
      expect(row['attempts'], 0);
    });

    test('and drain beside the mail rather than instead of it', () async {
      await message('chat-m1', source: 'teams', conversationKey: 'chat-1');
      await store.markConversationRead('teams', 'chat-1');
      await message('m1');
      await store.markConversationRead('email', 'c1');

      await queueWith().pump();

      expect(teams.acks, ['chat-1']);
      expect(mail.acks.single, ['m1']);
      expect((await workRow('c1'))['status'], 'done');
      expect((await workRow('chat-1', source: 'teams'))['status'], 'done');
    });

    test('a failed chat ack retries and then parks, like any other', () async {
      await message('chat-m1', source: 'teams', conversationKey: 'chat-1');
      await store.markConversationRead('teams', 'chat-1');
      teams.error = StateError('the chat is gone');
      final queue = queueWith();

      await queue.pump();
      var row = await workRow('chat-1', source: 'teams');
      expect(row['status'], 'pending');
      expect(row['attempts'], 1);
      expect(row['error'], contains('the chat is gone'));

      await queue.pump();
      await queue.pump();

      row = await workRow('chat-1', source: 'teams');
      expect(row['status'], 'error');
      expect(row['attempts'], 3);
      expect(teams.acks, hasLength(3));
    });

    test('a chat.readwrite the grant lacks skips the row, spending nothing',
        () async {
      // The gate is per SOURCE: mail can be ackable in the same drain that a
      // chat is not, because the two rest on different scopes.
      await message('chat-m1', source: 'teams', conversationKey: 'chat-1');
      await store.markConversationRead('teams', 'chat-1');
      await message('m1');
      await store.markConversationRead('email', 'c1');

      await queueWith(
        auth: _FakeAuth(scopes: const {'mail.read', 'mail.readwrite'}),
      ).pump();

      expect(teams.acks, isEmpty);
      expect((await workRow('chat-1', source: 'teams'))['status'], 'skipped');
      expect(mail.acks.single, ['m1']);
      expect((await workRow('c1'))['status'], 'done');
    });

    test('a dead session parks the chat row, unattempted', () async {
      await message('chat-m1', source: 'teams', conversationKey: 'chat-1');
      await store.markConversationRead('teams', 'chat-1');
      teams.error = const NotSignedIn();

      await queueWith().pump();

      final row = await workRow('chat-1', source: 'teams');
      expect(row['status'], 'pending');
      expect(row['attempts'], 0,
          reason: 'the session broke, not the item');
    });

    test('the panel is told how many messages the read was worth', () async {
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      await message('chat-m1', source: 'teams', conversationKey: 'chat-1');
      await message('chat-m2',
          source: 'teams',
          conversationKey: 'chat-1',
          receivedAt: '2026-08-28T11:00:00Z');
      await store.markConversationRead('teams', 'chat-1');

      await queueWith(log: log).pump();

      final event = (await store.recentActivity()).single;
      expect(event['kind'], 'mark_read');
      expect(event['status'], 'ok');
      expect(event['source'], 'teams');
      expect(event['entity_id'], 'chat-1');
      // The ids are not sent anywhere — one viewpoint call covers them — but
      // they are still what the read was worth, so the row says so.
      expect(event['count'], 2);
    });
  });

  group('what the panel is told', () {
    test('one row per ack, carrying how many messages it named', () async {
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      await message('m1');
      await message('m2', receivedAt: '2026-08-28T11:00:00Z');
      await store.markConversationRead('email', 'c1');

      await queueWith(log: log).pump();

      final event = (await store.recentActivity()).single;
      expect(event['kind'], 'mark_read');
      expect(event['status'], 'ok');
      expect(event['source'], 'email');
      expect(event['entity_id'], 'c1');
      expect(event['count'], 2);
    });

    test('a skipped ack says why', () async {
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      await message('m1');
      await store.markConversationRead('email', 'c1');

      await queueWith(auth: _FakeAuth(scopes: const {'mail.read'}), log: log)
          .pump();

      final event = (await store.recentActivity()).single;
      expect(event['status'], 'skipped');
      expect(event['detail_json'], contains('no_scope'));
    });
  });
}
