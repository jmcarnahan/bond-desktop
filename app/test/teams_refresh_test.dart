import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

/// The read model's half of the Teams rule.
///
/// **Microsoft's terms for the Teams messaging endpoints forbid background
/// polling.** The inbox refreshes itself every sixty seconds through
/// [ConversationsNotifier.load], so the line this file holds is that `load`
/// cannot reach Teams by any path — not on a sync, not on a triage-driven
/// reload, not on a correction. Only [ConversationsNotifier.refreshTeams] can,
/// and only a person calls that.

class _Tokens implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

class _FakeSync implements MailSync {
  int syncCalls = 0;
  Object? syncError;

  @override
  Future<void> syncNow() async {
    syncCalls++;
    final error = syncError;
    if (error != null) throw error;
  }

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A [TeamsSync] that counts calls instead of making them. Subclassed rather
/// than faked behind an interface: there is no interface, and inventing one so
/// a test can count would put a seam in production code that only the test
/// needs.
class _RecordingTeams extends TeamsSync {
  int calls = 0;
  Object? error;

  _RecordingTeams(super.teams, super.store);

  @override
  Future<void> syncNow() async {
    calls++;
    final thrown = error;
    if (thrown != null) throw thrown;
  }
}

void main() {
  late Database db;
  late MessageStore store;
  late _FakeSync sync;
  late _RecordingTeams teams;

  /// Counts every socket the Teams client would have opened. Nothing in this
  /// file should move it off zero.
  var httpCalls = 0;

  void seed(String key, {String source = 'email', String? at}) {
    store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': key,
      'state': 'needs_reply',
      'last_message_at': at ?? '2026-08-28T10:00:00Z',
    });
  }

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
    sync = _FakeSync();
    httpCalls = 0;

    final client = MockClient((request) async {
      httpCalls++;
      return http.Response('{}', 200);
    });
    teams = _RecordingTeams(
      GraphTeams(
        GraphAuth(httpClient: client, store: _Tokens()),
        httpClient: client,
      ),
      store,
    );
  });

  tearDown(() => db.close());

  group('the poll path never reaches Teams', () {
    test('a full load, sync and all, leaves Teams untouched', () async {
      seed('c1');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);

      await notifier.load();

      expect(sync.syncCalls, 1, reason: 'mail did sync');
      expect(teams.calls, 0);
      expect(httpCalls, 0);
    });

    test('sixty loads in a row — a full hour of the timer — still zero',
        () async {
      seed('c1');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);

      for (var i = 0; i < 60; i++) {
        await notifier.load();
      }

      expect(sync.syncCalls, 60);
      expect(teams.calls, 0);
    });

    test('a local reload does not either', () async {
      seed('c1');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);

      await notifier.load(syncFirst: false);

      expect(teams.calls, 0);
    });

    test('nor does a correction, which reloads on its way out', () async {
      seed('c1');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);
      await notifier.load();

      await notifier.sendSenderToLater('sarah@harborline.com');
      await notifier.keepThreadInInbox('email', 'c1');

      expect(teams.calls, 0);
    });
  });

  group('refreshTeams', () {
    test('pulls, then re-reads the list', () async {
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);
      await notifier.load();
      seed('chat-1', source: 'teams');

      await notifier.refreshTeams();

      expect(teams.calls, 1);
      expect(sync.syncCalls, 1, reason: 'it re-reads without a mail sync');
      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.map((c) => c.id).toList(), ['chat-1']);
      expect(state.loadError, isNull);
    });

    test('a failure keeps the rows and says which half went wrong', () async {
      seed('c1');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);
      await notifier.load();
      teams.error = StateError('graph is down');

      await notifier.refreshTeams();

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.map((c) => c.id).toList(), ['c1'],
          reason: 'once loaded, never blank');
      expect(state.loadError, "Couldn't refresh Teams just now.");
      expect(state.loadError, isNot(contains('inbox')),
          reason: 'the mail beside it is perfectly current, and a banner '
              'that said otherwise would have the user doubting it');
    });

    test('a dead session is reported the same way, not as a sign-out',
        () async {
      seed('c1');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);
      await notifier.load();
      teams.error = const NotSignedIn();

      await notifier.refreshTeams();

      final state = notifier.state as ConversationsLoaded;
      expect(state.loadError, "Couldn't refresh Teams just now.");
      // The inbox load is what routes a dead session to sign-in; two banners
      // saying different things about one sign-out is one too many.
      expect(state, isA<ConversationsLoaded>());
    });

    test('a build with no Teams connector does nothing at all', () async {
      seed('c1');
      final notifier = ConversationsNotifier(store, sync);

      await notifier.refreshTeams();

      expect(notifier.state, isA<ConversationsInitial>(),
          reason: 'not even a reload — there is nothing to have refreshed');
    });
  });

  group('two sources, one list', () {
    test('chats and mail come back together', () async {
      seed('c1', at: '2026-08-28T09:00:00Z');
      seed('chat-1', source: 'teams', at: '2026-08-28T11:00:00Z');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);

      await notifier.load();

      final rows = (notifier.state as ConversationsLoaded).conversations;
      expect(rows.map((c) => c.id).toList(), ['chat-1', 'c1']);
      expect(rows.map((c) => c.source).toList(), ['teams', 'email']);
    });

    test('marking a chat done writes against the chat, not against mail',
        () async {
      seed('chat-1', source: 'teams');
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);
      await notifier.load();

      await notifier.markDone('chat-1');

      expect(
        store.getConversationRow('teams', 'chat-1')!['state'],
        'done',
      );
      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.done,
      );
    });

    test('a thread transcript reads both sources', () {
      store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'm1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'received_at': '2026-08-28T10:00:00Z',
        'body_text': 'hello',
      });

      expect(
        store.loadThread('chat-1', sources: inboxSources).single.source,
        'teams',
      );
    });
  });
}
