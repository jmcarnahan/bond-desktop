// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart' show ConversationState;
import 'package:bond_inbox/providers/draft_provider.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/composer.dart' show SendCapability;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Replying to a chat, from the button press to the next pull.
///
/// The one thing here that no other test can cover: a chat send writes its own
/// outbound row, which no other send in this app does. Mail waits for
/// `sentitems` because `sendDraft` answers 202 with no body; a chat post answers
/// with the message Graph stored, so the reply can appear in the transcript at
/// once — and MUST carry the id Graph assigned, because that id is the only
/// thing standing between "the reply is there" and "the reply is there twice,
/// and the thread the user just answered has reopened itself".

const String _myId = 'me-1';

/// A [TeamsBackend] that stores what it is sent and hands it back the way Graph
/// would, then serves it to the next sync exactly as a pull would find it.
class _FakeTeams implements TeamsBackend {
  final List<({String chatId, String text})> sends = [];

  /// Every message the chat holds, oldest first — the sends land here too,
  /// which is what makes the follow-up sync a real replay rather than a
  /// staged one.
  final List<Map<String, dynamic>> stored = [];

  /// The preview timestamp the chat list reports. Newer than anything stored
  /// locally, so the sync always fetches.
  String previewAt = '2026-08-28T23:00:00Z';

  /// Thrown from [sendChatMessage] instead of answering.
  Object? error;

  int nextId = 1;

  @override
  Future<String> myUserId() async => _myId;

  @override
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4}) async => [
        {
          'id': 'chat-1',
          'topic': 'Sarah Whitfield',
          'lastMessagePreview': {'createdDateTime': previewAt},
          'viewpoint': null,
        },
      ];

  @override
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) async => [
        {'userId': 'u1', 'displayName': 'Sarah Whitfield'},
      ];

  @override
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  }) async =>
      [
        // Newest first, as Graph orders them.
        for (final message in stored.reversed) message,
      ];

  @override
  Future<void> markChatRead(String chatId) async {}

  @override
  Future<Map<String, dynamic>> sendChatMessage(
    String chatId,
    String text,
  ) async {
    sends.add((chatId: chatId, text: text));
    final thrown = error;
    if (thrown != null) throw thrown;
    final message = {
      'id': 'sent-${nextId++}',
      'messageType': 'message',
      'createdDateTime': '2026-08-28T22:00:00Z',
      'lastModifiedDateTime': '2026-08-28T22:00:00Z',
      'body': {'contentType': 'text', 'content': text},
      'from': {
        'user': {'id': _myId, 'displayName': 'Jordan Bond'},
      },
    };
    stored.add(message);
    return message;
  }
}

/// A mail backend that would throw if a chat send ever reached it. It must not:
/// the Teams branch of `send` comes before the mail path precisely so none of
/// `createReply`/`updateBody`/`sendDraft` — none of which have a chat
/// equivalent — is ever attempted for one.
class _UnreachableMail implements MailBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A session that grants exactly what it was built with.
class _FakeAuth implements AuthSession {
  final Set<String> scopes;

  _FakeAuth({this.scopes = const {'chat.readwrite'}});

  @override
  Future<bool> hasScope(String bareScope) async => scopes.contains(bareScope);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  // The copy-only rung reaches the clipboard, which is a platform channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  late BondDatabase db;
  late MessageStore store;
  late _FakeTeams teams;
  late int syncsAfterSend;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    teams = _FakeTeams();
    syncsAfterSend = 0;
  });

  tearDown(() => db.close());

  DraftNotifier notifierFor({_FakeAuth? auth}) {
    final notifier = DraftNotifier(
      store,
      auth ?? _FakeAuth(),
      _UnreachableMail(),
      (source: 'teams', conversationKey: 'chat-1'),
      teams: teams,
      onSent: () async => syncsAfterSend++,
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  /// A notifier that has read its grant. The capability starts at the safe
  /// rung, so a send before this lands would only ever copy.
  Future<DraftNotifier> loaded({_FakeAuth? auth}) async {
    final notifier = notifierFor(auth: auth);
    await notifier.load();
    return notifier;
  }

  /// One chat waiting on an answer, with a CTA the reply resolves.
  Future<void> seedChat() async {
    final inbound = {
      'id': 'm1',
      'messageType': 'message',
      'createdDateTime': '2026-08-28T21:00:00Z',
      'lastModifiedDateTime': '2026-08-28T21:00:00Z',
      'body': {'contentType': 'text', 'content': 'Any word on the CD?'},
      'from': {
        'user': {'id': 'u1', 'displayName': 'Sarah Whitfield'},
      },
    };
    teams.stored.add(inbound);
    await store.upsertMessage({
      'source': 'teams',
      'source_message_id': 'm1',
      'conversation_key': 'chat-1',
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      'from_address': 'teams:u1',
      'received_at': '2026-08-28T21:00:00Z',
      'body_text': 'Any word on the CD?',
      'body_preview': 'Any word on the CD?',
      'is_read': 1,
      'triage_status': 'skipped',
      'gate_reason': teamsSourceGate,
    });
    await store.upsertConversation({
      'source': 'teams',
      'conversation_key': 'chat-1',
      'subject': 'Sarah Whitfield',
      'state': 'needs_reply',
      'cta_text': 'Send the closing disclosure',
      'cta_urgency': 'high',
      'last_message_at': '2026-08-28T21:00:00Z',
      'last_inbound_at': '2026-08-28T21:00:00Z',
    });
    await store.recomputeConversationCounts('teams', 'chat-1');
  }

  Future<List<Map<String, Object?>>> teamsMessages() async {
    final rows = await db
        .customSelect(
          "SELECT * FROM messages WHERE source = 'teams' ORDER BY received_at",
        )
        .get();
    return [for (final row in rows) row.data];
  }

  Future<Map<String, Object?>> conversation() async =>
      (await store.getConversationRow('teams', 'chat-1'))!;

  group('the send', () {
    test(
        'a chat send takes the Needs You chip off — the one path the sync '
        'can never clear', () async {
      await seedChat();
      await store.writeSettledProgress(
        'teams',
        'm1',
        needsYou: true,
        reason: 'settled',
        dropped: false,
      );
      // The pipeline is passed explicitly here and nowhere else in this file:
      // the outbound row the chat send writes is one the next pull skips as
      // already-seen, so the sync's `resolvesAsk` arm never runs for it and
      // THIS is the only place the chip can come off.
      final notifier = DraftNotifier(
        store,
        _FakeAuth(),
        _UnreachableMail(),
        (source: 'teams', conversationKey: 'chat-1'),
        teams: teams,
        pipeline: PipelineProgress(store),
        onSent: () async => syncsAfterSend++,
      );
      addTearDown(notifier.dispose);
      await notifier.load();

      await notifier.send('Sending it over now.');

      final row = (await store
              .progressRowsFor([(source: 'teams', id: 'm1')]))
          .single;
      expect(row.needsYou, isFalse);
    });

    test('goes to the chat, not through anything mail owns', () async {
      await seedChat();
      final notifier = await loaded();
      expect(notifier.state.capability, SendCapability.send,
          reason: 'chat.readwrite is the top rung for a chat');

      expect(await notifier.send('On it — sending today.'), SendOutcome.sent);

      expect(teams.sends.single.chatId, 'chat-1');
      expect(teams.sends.single.text, 'On it — sending today.');
    });

    test('writes exactly one outbound row, carrying the id Graph returned',
        () async {
      await seedChat();
      await (await loaded()).send('On it.');

      final messages = await teamsMessages();
      expect(messages, hasLength(2));
      final reply = messages.last;
      // The id is the whole point: it is what the next pull recognises.
      expect(reply['source_message_id'], 'sent-1');
      expect(reply['direction'], 'outbound');
      expect(reply['conversation_key'], 'chat-1');
      expect(reply['body_text'], 'On it.');
      expect(reply['received_at'], '2026-08-28T22:00:00Z');
      expect(reply['is_read'], 1, reason: 'the user wrote it');
      // The same columns the sync would have written, because the same code
      // wrote them — and triage never asks whether the user's own message
      // needs the user.
      expect(reply['triage_status'], 'skipped');
      expect(reply['gate_reason'], 'outbound');
      // Nothing the user wrote was addressed to the user, whatever kind of
      // chat it went into — which is why the send path passes none of the
      // params that decide the flag and still writes the right one.
      expect(reply['addressed_me'], 0);
    });

    test('a sent reply recaps the storyline it belongs to', () async {
      await seedChat();
      await store.insertStoryline(
        id: 'sl-1',
        title: 'The CD for the Whitfield file',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'teams', 'chat-1',
          addedBy: 'auto');
      await store.writeWork('storyline_recap', 'email', 'sl-1',
          status: 'done');

      await (await loaded()).send('Sent it over just now.');

      // The one outbound row in this app that no ingest will ever see — the
      // next pull skips it as already-known — so the recap has to be woken
      // here or wait for the next sync's catch-up. The label is 'email' for
      // both connectors, exactly as `StorylineService` writes it.
      final work = await store.nextPendingWork('storyline_recap');
      expect(work?['entity_id'], 'sl-1');
      expect(work?['source'], 'email');
    });

    test('a reply into a thread no storyline holds queues no recap', () async {
      await seedChat();

      await (await loaded()).send('Sent it over just now.');

      expect(await store.nextPendingWork('storyline_recap'), isNull);
    });

    test('flips the thread to waiting and answers the CTA', () async {
      await seedChat();
      await (await loaded()).send('On it.');

      final row = await conversation();
      // The reply leaving IS the needs-you exit, said now rather than whenever
      // the user next refreshes Teams — which, under Microsoft's polling terms,
      // may be a long while.
      expect(row['state'], ConversationState.waiting.wire);
      expect(row['cta_text'], isNull);
      expect(row['cta_urgency'], 'normal');
    });

    test('recounts the thread, so the transcript and the row agree', () async {
      await seedChat();
      expect((await conversation())['message_count'], 1);

      await (await loaded()).send('On it.');

      expect((await conversation())['message_count'], 2);
      expect((await conversation())['inbound_count'], 1);
    });

    test('reports the send and bumps the epoch once', () async {
      await seedChat();
      final notifier = await loaded();

      await notifier.send('On it.');

      expect(syncsAfterSend, 1);
      expect(notifier.state.sendEpoch, 1);
      expect(notifier.state.sending, isFalse);
      expect(notifier.state.error, isNull);
    });

    test('a failed send changes nothing but the error', () async {
      await seedChat();
      teams.error = const GraphTeamsException('Graph said no', 502);
      final notifier = await loaded();

      expect(await notifier.send('On it.'), SendOutcome.failed);

      expect(notifier.state.error, 'Graph said no');
      expect(await teamsMessages(), hasLength(1));
      expect((await conversation())['state'], 'needs_reply');
      expect((await conversation())['cta_text'], isNotNull);
    });

    test('a card\'s send marks that message\'s suggestion sent', () async {
      // A chat send marked no draft row at all until the cards moved under the
      // messages they answer. It was harmless while only the newest suggestion
      // was tappable; now an older card can send, and a row left 'suggested'
      // would offer the reply again straight after it went.
      await seedChat();
      await store.upsertDraft(
        source: 'teams',
        conversationKey: 'chat-1',
        replyToMessageId: 'm1',
        body: 'Sending it over now.',
      );

      await (await loaded()).send('Sending it over now.', replyTo: 'm1');

      final draft = (await store.getDraftForMessage('teams', 'm1'))!;
      expect(draft['status'], 'sent');
      expect(draft['body'], 'Sending it over now.');
    });

    test('and a send that names no message changes no suggestion', () async {
      // The composer's own send, which resolves its target elsewhere. Pinned
      // because it is existing behaviour and not an oversight.
      await seedChat();
      await store.upsertDraft(
        source: 'teams',
        conversationKey: 'chat-1',
        replyToMessageId: 'm1',
        body: 'Sending it over now.',
      );

      await (await loaded()).send('Typed from scratch.');

      final draft = (await store.getDraftForMessage('teams', 'm1'))!;
      expect(draft['status'], 'suggested');
      expect(draft['body'], 'Sending it over now.');
    });

    test('without the grant the reply only reaches the clipboard', () async {
      // The bottom rung of the chat ladder. Nothing may leave the machine.
      await seedChat();
      final notifier = await loaded(auth: _FakeAuth(scopes: const {}));

      expect(await notifier.send('On it.'), SendOutcome.copied);

      expect(teams.sends, isEmpty);
      expect(await teamsMessages(), hasLength(1));
    });
  });

  group('the next pull', () {
    test('finds the reply already stored and does not fold it again', () async {
      await seedChat();
      await (await loaded()).send('On it.');
      // Closed by hand, so a second fold would have something to undo: folding
      // the reply again would reopen a thread the user had finished with.
      await store.setConversationState(
        'teams',
        'chat-1',
        ConversationState.done,
      );

      await TeamsSync(teams, store).syncNow();

      expect((await conversation())['state'], ConversationState.done.wire);
      final messages = await teamsMessages();
      expect(messages, hasLength(2), reason: 'the id matched, so no duplicate');
      expect(messages.last['source_message_id'], 'sent-1');
      expect((await conversation())['message_count'], 2);
    });

    test('and a chat this app never replied to still folds normally', () async {
      // The control: the guard above is `hasMessage`, not "outbound messages
      // are ignored". A message the app has not seen must still reopen its
      // thread.
      await seedChat();
      await store.setConversationState(
        'teams',
        'chat-1',
        ConversationState.done,
      );
      teams.stored.add({
        'id': 'm2',
        'messageType': 'message',
        'createdDateTime': '2026-08-28T22:30:00Z',
        'lastModifiedDateTime': '2026-08-28T22:30:00Z',
        'body': {'contentType': 'text', 'content': 'Still waiting.'},
        'from': {
          'user': {'id': 'u1', 'displayName': 'Sarah Whitfield'},
        },
      });

      await TeamsSync(teams, store).syncNow();

      expect((await conversation())['state'], 'needs_reply');
    });
  });
}
