import 'dart:convert';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/main.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/screens/sign_in_screen.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_auth.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

/// One session per SERVER, in one shared keychain.
///
/// The bug this file exists to prevent: the app kept a single MCP session
/// whatever server it was pointed at, so changing the endpoint in Settings
/// carried the old server's session onto the new one — and the only way out
/// was Sign out, which also wiped the mail database. What is pinned here is
/// that the slots are independent, that the pre-slot keys neither sign anyone
/// in nor linger, that ending one session leaves the others alone, and that
/// the gate in front of the inbox asks the session the switch just built.
///
/// The stubs are deliberately duplicated from the other auth tests rather than
/// shared, so no file can break another by editing it.
class _Tokens implements TokenStore {
  final Map<String, String> values = {};

  /// No session may wipe the store: it now holds one slot per server plus the
  /// direct-Graph session, and all of them would go down together.
  bool deleteAllCalled = false;

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
  Future<void> deleteAll() async {
    deleteAllCalled = true;
    values.clear();
  }
}

class _FakeBondMcpClient implements BondMcpClient {
  final Map<String, Object> scripted;

  _FakeBondMcpClient(this.scripted);

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    final reply = scripted[name];
    if (reply is Map<String, dynamic>) return reply;
    if (reply == null) throw McpTransportException('no script for "$name"');
    throw reply;
  }

  @override
  Future<void> close() async {}
}

/// An [AuthSession] that answers from a constant, and records what it was
/// asked to do. Enough for the gate, which only ever asks [isSignedIn].
class _FakeSession implements AuthSession {
  _FakeSession({required this.signedIn});

  final bool signedIn;
  int signOuts = 0;

  @override
  Future<bool> get isSignedIn async => signedIn;

  @override
  Future<bool> get needsReconsent async => false;

  @override
  Future<bool> hasScope(String bareScope) async => false;

  @override
  Future<AccountInfo?> get storedAccount async => null;

  @override
  Future<AccountInfo> signIn() async => const AccountInfo(displayName: 'X');

  @override
  Future<void> signOut() async => signOuts++;
}

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A Teams backend that opens no socket. Never actually called — the fake
/// session grants no scope, so `TeamsSync` returns before reaching it — but it
/// keeps the real one out of the graph the gate builds.
class _FakeTeams implements TeamsBackend {
  @override
  Future<String> myUserId() async => 'u1';

  @override
  Future<List<Map<String, dynamic>>> listChats({int maxPages = 4}) async =>
      const [];

  @override
  Future<List<Map<String, dynamic>>> chatMembers(String chatId) async =>
      const [];

  @override
  Future<List<Map<String, dynamic>>> chatMessagesSince(
    String chatId,
    String? sinceIso, {
    int maxPages = 40,
  }) async =>
      const [];
}

/// Two endpoints that resolve without DNS and refuse instantly. The widget
/// tests below build the real MCP stack, and a hostname would have them
/// waiting on a lookup for a server that was never going to answer.
const String _serverA = 'http://127.0.0.1:9/mcp';
const String _serverB = 'http://127.0.0.1:10/mcp';

/// A server that wants no token: the local `make dev` shape, and the sign-in
/// path that needs neither a browser nor an authorization server.
///
/// It ANSWERS the initialize POST the sign-in probe sends. Nothing less counts:
/// a server is only taken as open when it grants access outright, because the
/// statuses a bare GET produces are the same either side of an auth wall.
MockClient _openServer() => MockClient((request) async =>
    request.method == 'POST'
        ? http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': 0, 'result': <String, Object?>{}}),
            200,
            headers: {'content-type': 'application/json'},
          )
        : http.Response('Method Not Allowed', 405));

McpAuthSession _sessionAt(String url, TokenStore store) => McpAuthSession(
      mcpUrl: Uri.parse(url),
      mcpClient: _FakeBondMcpClient({
        'get_profile_json': {'error': 'not_connected', 'connect_url': null},
      }),
      httpClient: _openServer(),
      store: store,
      openBrowser: (_) async => fail('this server asks for no sign-in'),
    );

/// Lets the fire-and-forget work a constructor started actually run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('a session belongs to its server', () {
    test('two servers hold two independent sessions', () async {
      final store = _Tokens();
      final a = _sessionAt(_serverA, store);

      await a.signIn();

      expect(await a.isSignedIn, isTrue);
      expect(
        await _sessionAt(_serverB, store).isSignedIn,
        isFalse,
        reason: 'pointing the app at another server must not carry the first '
            "server's session onto it",
      );
    });

    test('signing out of one leaves the other signed in', () async {
      final store = _Tokens();
      final a = _sessionAt(_serverA, store);
      final b = _sessionAt(_serverB, store);
      await a.signIn();
      await b.signIn();

      await a.signOut();

      expect(await a.isSignedIn, isFalse);
      expect(await b.isSignedIn, isTrue);
      expect(store.deleteAllCalled, isFalse);
    });

    test('one URL is one slot, trailing slash or not', () async {
      // The canonical form is what the audience is compared against, and it
      // has to be what the slot is derived from too — or the same server
      // typed two ways would ask the user to sign in twice.
      expect(
        McpAuthSession.slotFor(Uri.parse(_serverA)),
        _sessionAt('$_serverA/', _Tokens()).refreshTokenKey.split('_').last,
      );
    });
  });

  group('the pre-slot global keys', () {
    test('are not a session, and do not survive construction', () async {
      final store = _Tokens()
        ..values['mcp_refresh_token'] = 'rt-from-some-server'
        ..values['mcp_account_json'] = '{"displayName":"Ada"}'
        ..values['mcp_local_mode'] = '1';

      final session = _sessionAt(_serverA, store);

      // They are not migrated, deliberately: nothing in them says which
      // server they came from, and adopting them into the wrong slot is the
      // half-state this whole scheme exists to kill. One sign-in per server
      // is the entire migration cost.
      expect(await session.isSignedIn, isFalse);

      await _settle();
      expect(store.values.containsKey('mcp_refresh_token'), isFalse);
      expect(store.values.containsKey('mcp_account_json'), isFalse);
      expect(store.values.containsKey('mcp_local_mode'), isFalse);
    });

    test('retiring them leaves every slot alone', () async {
      final store = _Tokens();
      final a = _sessionAt(_serverA, store);
      await a.signIn();

      // A second session constructed later runs the retirement again; the
      // first server's slot must not be collateral.
      _sessionAt(_serverB, store);
      await _settle();

      expect(await a.isSignedIn, isTrue);
    });
  });

  group('the direct-Graph session ends alone', () {
    test('signOut clears its three keys and nothing else', () async {
      final store = _Tokens()
        ..values['refresh_token'] = 'graph-rt'
        ..values['granted_scopes'] = 'Mail.Read User.Read'
        ..values['account_json'] = '{"displayName":"Graph User"}'
        ..values['mcp_rt_deadbeefdeadbeef'] = 'workspace-rt'
        ..values['mcp_local_cafecafecafecafe'] = '1';

      await GraphAuth(store: store).signOut();

      expect(store.values.containsKey('refresh_token'), isFalse);
      expect(store.values.containsKey('granted_scopes'), isFalse);
      expect(store.values.containsKey('account_json'), isFalse);
      expect(
        store.values['mcp_rt_deadbeefdeadbeef'],
        'workspace-rt',
        reason: 'the keychain is shared with the per-server MCP sessions, and '
            'ending one session must not execute the others',
      );
      expect(store.values['mcp_local_cafecafecafecafe'], '1');
      expect(store.deleteAllCalled, isFalse);
    });

    test('an invalid_grant refresh clears the same three, and no more',
        () async {
      final store = _Tokens()
        ..values['refresh_token'] = 'graph-rt'
        ..values['granted_scopes'] = 'Mail.Read User.Read'
        ..values['mcp_rt_deadbeefdeadbeef'] = 'workspace-rt';
      final auth = GraphAuth(
        store: store,
        httpClient: MockClient((request) async =>
            http.Response(jsonEncode({'error': 'invalid_grant'}), 400)),
      );

      await expectLater(
        auth.getValidAccessToken(),
        throwsA(isA<NotSignedIn>()),
      );

      expect(store.values.containsKey('refresh_token'), isFalse);
      expect(store.values.containsKey('granted_scopes'), isFalse);
      expect(store.values['mcp_rt_deadbeefdeadbeef'], 'workspace-rt');
    });
  });

  group('the gate follows the session', () {
    late Database db;
    late MessageStore store;

    setUp(() {
      db = sqlite3.openInMemory();
      applySchema(db);
      store = MessageStore(db);
    });

    tearDown(() => db.close());

    /// The real [AuthGate] over a session that exists per server URL, the way
    /// [mcpStackProvider] builds one.
    ///
    /// The session is faked rather than seeded into a keychain because the
    /// production stack constructs its own [SecureTokenStore] and there is no
    /// seam to hand it another — and what this group is about is the GATE
    /// noticing a new session, which a fake keyed on the URL reproduces
    /// exactly. The slots themselves are pinned above, against a real store.
    Future<Map<String, _FakeSession>> pumpGate(
      WidgetTester tester, {
      required Set<String> signedInAt,
    }) async {
      final built = <String, _FakeSession>{};
      await tester.pumpWidget(ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          syncServiceProvider.overrideWithValue(_FakeSync()),
          teamsBackendProvider.overrideWithValue(_FakeTeams()),
          // One session per (mode, server), which is what the real provider
          // graph builds — and what makes a switch of either a NEW session
          // for the gate to notice.
          authSessionProvider.overrideWith((ref) {
            final prefs = ref.watch(appPrefsProvider);
            final at = '${prefs.backendMode}:${prefs.mcpServerUrl}';
            return built[at] = _FakeSession(signedIn: signedInAt.contains(at));
          }),
        ],
        child: const MaterialApp(home: AuthGate()),
      ));
      // The gate's answer is a Future, and the inbox behind it loads on a
      // microtask of its own.
      await tester.pump();
      await tester.pump();
      return built;
    }

    testWidgets('switching servers re-asks, and switching back resumes',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.setPref(mcpServerUrlKey, _serverA);

      final sessions =
          await pumpGate(tester, signedInAt: {'$backendModeMcp:$_serverA'});
      expect(find.byType(InboxScreen), findsOneWidget);

      final container =
          ProviderScope.containerOf(tester.element(find.byType(AuthGate)));
      container.read(appPrefsProvider.notifier).setMcpServerUrl(_serverB);
      await tester.pump();
      await tester.pump();

      expect(
        find.byType(SignInScreen),
        findsOneWidget,
        reason: 'the new server has no session, and the gate must say so now '
            'rather than at the next launch',
      );

      container.read(appPrefsProvider.notifier).setMcpServerUrl(_serverA);
      await tester.pump();
      await tester.pump();

      expect(find.byType(InboxScreen), findsOneWidget);
      expect(
        sessions.values.every((s) => s.signOuts == 0),
        isTrue,
        reason: 'changing endpoints must cost no sign-out — that is the whole '
            'point of a slot per server',
      );
    });

    testWidgets('a switch to an unsigned backend closes the open settings',
        (tester) async {
      // The dialog is a route above the inbox, so nothing dismisses it when
      // the gate swaps the inbox for a sign-in screen — it would sit there
      // over the wrong screen, holding a ref whose element is gone, and
      // answer the next question with a crash.
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.setPref(mcpServerUrlKey, _serverA);

      await pumpGate(tester, signedInAt: {'$backendModeMcp:$_serverA'});
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);

      // The direct-Graph backend, which this run has never signed in to.
      await tester.tap(find.text('This Mac'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsDialog), findsNothing);
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
