// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/source_filter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The whole screen, with sqlite real and every socket faked.
///
/// Two things are pinned here that cannot be pinned anywhere else, because
/// both are properties of the WIRING rather than of any one class:
///
/// - **the sixty-second poll timer never reaches Teams.** Microsoft's terms
///   for the Teams messaging endpoints forbid background polling, and the only
///   place that rule can actually be broken is here, where the timer is
///   created and the refresh button is wired.
/// - **a chat thread has no composer.** Drafting and sending are email-only:
///   Graph builds a mail reply for this app through `createReply`, and there is
///   no equivalent for a chat, so a reply box on one would be a box that
///   cannot send.

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

  @override
  Future<void> syncNow() async => syncCalls++;

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

class _RecordingTeams extends TeamsSync {
  int calls = 0;

  _RecordingTeams(super.teams, super.store);

  @override
  Future<void> syncNow() async => calls++;
}

const String _coreScopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';
const String _withChat = '$_coreScopes https://graph.microsoft.com/Chat.Read';

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _FakeSync sync;
  late _RecordingTeams teams;

  /// Every socket the app would have opened. Nothing in this file may move it.
  var httpCalls = 0;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    sync = _FakeSync();
    httpCalls = 0;
  });

  tearDown(() => db.close());

  Future<void> seedChat(String key, {String subject = 'Sarah Whitfield'}) async {
    await store.upsertMessage({
      'source': 'teams',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_name': 'Sarah Whitfield',
      'from_address': 'teams:u1',
      'received_at': '2026-08-28T11:00:00Z',
      'body_text': 'Any word on the CD?',
      'body_preview': 'Any word on the CD?',
      'triage_status': 'skipped',
      'gate_reason': teamsSourceGate,
    });
    await store.upsertConversation({
      'source': 'teams',
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"Sarah Whitfield","email":"teams:u1"}]',
      'state': 'needs_reply',
      'last_message_at': '2026-08-28T11:00:00Z',
      'last_inbound_at': '2026-08-28T11:00:00Z',
      'last_message_preview': 'Any word on the CD?',
    });
    await store.recomputeConversationCounts('teams', key);
  }

  Future<void> seedMail(String key, {String subject = 'Homepage copy'}) async {
    await store.upsertMessage({
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_name': 'Eric Vance',
      'from_address': 'eric@example.com',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'The homepage copy is in.',
    });
    await store.upsertConversation({
      'conversation_key': key,
      'subject': subject,
      'participants_json': '[{"name":"Eric Vance","email":"eric@example.com"}]',
      'state': 'needs_reply',
      'last_message_at': '2026-08-28T09:00:00Z',
      'last_inbound_at': '2026-08-28T09:00:00Z',
    });
    await store.recomputeConversationCounts('email', key);
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    String grantedScopes = _withChat,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((request) async {
      httpCalls++;
      return http.Response('{}', 200);
    });
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt-1';
    tokens.values['granted_scopes'] = grantedScopes;
    final auth = GraphAuth(httpClient: client, store: tokens);
    teams = _RecordingTeams(
      GraphTeams(auth, httpClient: client),
      store,
    );
    // This screen is pumped over a faked GraphAuth, which is the SDK backend —
    // and the app's default is now the MCP one, whose session would answer the
    // scope question by asking a server that is not there. Said in the store
    // because that is where the app reads it, once, at construction.
    await store.setPref(backendModeKey, backendModeSdk);
    // Read here rather than left to load a microtask into the first frame,
    // which is what `main()` does and for the same reason: every backend
    // provider watches the mode, so a stored setting arriving late rebuilds
    // the session — and with it the inbox's read model, which would then sit
    // at its initial state, spinning, with the load that this screen kicks
    // from `initState` having landed on the notifier that was replaced.
    final prefs = await AppPrefsNotifier.read(store);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider.overrideWithValue(prefs),
        graphAuthProvider.overrideWithValue(auth),
        syncServiceProvider.overrideWithValue(sync),
        teamsSyncProvider.overrideWithValue(teams),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // The launch refresh is a microtask; two pumps settle it and the loads
    // behind it without advancing the poll timer. A third for the reads
    // themselves, which are round trips through drift now — and pumps rather
    // than a settle, because this screen owns a sixty-second periodic timer
    // and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  group('the poll timer', () {
    testWidgets('refreshes mail and never Teams', (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);

      final atLaunch = teams.calls;
      expect(atLaunch, 1, reason: 'opening the app is an app-focus event');
      final mailAtLaunch = sync.syncCalls;

      // Five minutes of the timer.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 61));
      }

      expect(sync.syncCalls, greaterThan(mailAtLaunch),
          reason: 'the timer did fire');
      expect(teams.calls, atLaunch,
          reason: 'Microsoft’s terms forbid polling the Teams messaging '
              'endpoints — only a person may refresh them');
      expect(httpCalls, 0, reason: 'every socket in this test is faked');
    });

    testWidgets('the refresh button does reach Teams', (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);
      final before = teams.calls;

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pump();

      expect(teams.calls, before + 1);
    });
  });

  group('a chat thread', () {
    testWidgets('offers no composer, and says where to reply', (tester) async {
      await seedChat('chat-1');
      await pumpScreen(tester);

      await tester.tap(find.text('💬 Sarah Whitfield').first);
      await tester.pump();
      await tester.pump();

      expect(find.byType(Composer), findsNothing,
          reason: 'a reply box that cannot send is worse than none');
      expect(find.text('Reply in Microsoft Teams'), findsOneWidget);
    });

    testWidgets('a mail thread still has one', (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);

      await tester.tap(find.text('Eric Vance').first);
      await tester.pump();
      await tester.pump();

      expect(find.byType(Composer), findsOneWidget);
      expect(find.text('Reply in Microsoft Teams'), findsNothing);
    });
  });

  group('the source filter', () {
    testWidgets('narrows the whole screen, rail included', (tester) async {
      await seedMail('c1');
      await seedChat('chat-1');
      await pumpScreen(tester);

      expect(find.text('Eric Vance'), findsWidgets);
      expect(find.text('💬 Sarah Whitfield'), findsWidgets);

      await tester.tap(find.byKey(SourceFilterBar.teamsKey));
      await tester.pump();

      expect(find.text('Eric Vance'), findsNothing);
      expect(find.text('💬 Sarah Whitfield'), findsWidgets);

      await tester.tap(find.byKey(SourceFilterBar.mailKey));
      await tester.pump();

      expect(find.text('Eric Vance'), findsWidgets);
      expect(find.text('💬 Sarah Whitfield'), findsNothing);

      await tester.tap(find.byKey(SourceFilterBar.allKey));
      await tester.pump();

      expect(find.text('Eric Vance'), findsWidgets);
      expect(find.text('💬 Sarah Whitfield'), findsWidgets);
    });

    testWidgets('without Chat.Read the Teams pill is dead rather than gone',
        (tester) async {
      await seedMail('c1');
      await pumpScreen(tester, grantedScopes: _coreScopes);
      // The scope is a keychain read behind a FutureBuilder.
      await tester.pump();

      final pill = tester.widget<Widget>(find.byKey(SourceFilterBar.teamsKey));
      expect(pill, isNotNull);
      expect(
        find.byTooltip(SourceFilterBar.unavailableTooltip),
        findsOneWidget,
      );
    });
  });

  group('the freshness caption', () {
    testWidgets('says nothing before the first pull, and how old after',
        (tester) async {
      await seedMail('c1');
      await pumpScreen(tester);
      expect(find.textContaining('Teams updated'), findsNothing);

      await store.setSyncedAt(
        TeamsSync.folder,
        DateTime.now().toUtc().subtract(const Duration(minutes: 4))
            .toIso8601String(),
        source: TeamsSync.source,
      );
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Teams updated 4m ago'), findsOneWidget);
    });
  });
}
