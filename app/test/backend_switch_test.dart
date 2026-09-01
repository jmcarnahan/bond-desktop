// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/graph_teams.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_auth.dart';
import 'package:bond_inbox/services/mcp/mcp_mail_backend.dart';
import 'package:bond_inbox/services/mcp/mcp_teams_backend.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The switch between the two backends, as a property of the WIRING.
///
/// None of the behaviour tests would notice if this broke: the app would keep
/// working perfectly against whichever backend it happened to build. What is
/// pinned here is which one each mode selects, that changing the preference
/// rebuilds everything downstream on its own, and that the MCP side needs no
/// build-time configuration at all — which is the whole reason it is the
/// default.

/// A client that counts calls instead of making them.
class _CountingMcp implements BondMcpClient {
  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add(name);
    return <String, dynamic>{};
  }

  @override
  Future<void> close() async {}
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

void main() {
  late BondDatabase db;
  late MessageStore store;

  /// A container with the stored settings already loaded: the notifier starts
  /// on the defaults and replaces them a microtask later, so a test that read
  /// a preference straight after building this would be reading the default
  /// rather than what the database holds.
  Future<ProviderContainer> container() async {
    final made = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(made.dispose);
    await made.read(appPrefsProvider.notifier).ready;
    return made;
  }

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  group('which backend a fresh install gets', () {
    test('is the MCP one, in all three providers', () async {
      final ref = await container();

      expect(ref.read(appPrefsProvider).backendMode, backendModeMcp);
      expect(ref.read(authSessionProvider), isA<McpAuthSession>());
      expect(ref.read(mailBackendProvider), isA<McpMailBackend>());
      expect(ref.read(teamsBackendProvider), isA<McpTeamsBackend>());
    });

    test('pointed at the default server for this build', () async {
      // The deployed URL arrives ONLY as a --dart-define (public repo: which
      // cluster a company runs is environment, not code). The test binary
      // carries no define, so the compiled constant must be empty and the
      // default must fall back to the local server — which is also the pin
      // that no hostname has crept back into source.
      expect(mcpDeployedUrl, isEmpty);
      expect(defaultMcpServerUrl, mcpLocalUrl);

      final ref = await container();
      expect(ref.read(appPrefsProvider).mcpServerUrl, defaultMcpServerUrl);
      expect(
        (ref.read(authSessionProvider) as McpAuthSession).mcpUrl.toString(),
        defaultMcpServerUrl,
      );
    });

    test('and it builds with no dart-defines at all', () async {
      // The whole reason MCP is the default: the direct-Graph session cannot
      // even start without MS_CLIENT_ID and MS_TENANT_ID compiled in, and this
      // test process has neither.
      expect(GraphAuth.clientId, isEmpty);
      expect(GraphAuth.tenantId, isEmpty);

      final ref = await container();

      expect(ref.read(authSessionProvider), isA<McpAuthSession>());
      expect(ref.read(mailBackendProvider), isA<McpMailBackend>());
      expect(ref.read(syncServiceProvider), isA<SyncService>());
      expect(ref.read(teamsSyncProvider), isA<TeamsSync>());
    });

    test('and the MCP session and client are one stack, not two', () async {
      final ref = await container();

      final stack = ref.read(mcpStackProvider);
      expect(identical(ref.read(mcpStackProvider), stack), isTrue);
      expect(identical(ref.read(authSessionProvider), stack.auth), isTrue);
    });
  });

  group('switching to the direct-Graph backend', () {
    test('changes all three providers', () async {
      final ref = await container();
      expect(ref.read(authSessionProvider), isA<McpAuthSession>());

      await ref.read(appPrefsProvider.notifier).setBackendMode(backendModeSdk);

      expect(ref.read(authSessionProvider), isA<GraphAuth>());
      expect(ref.read(mailBackendProvider), isA<GraphMail>());
      expect(ref.read(teamsBackendProvider), isA<GraphTeams>());
    });

    test('and everything built on them follows, with nothing invalidated by '
        'hand', () async {
      final ref = await container();
      final before = ref.read(syncServiceProvider);

      await ref.read(appPrefsProvider.notifier).setBackendMode(backendModeSdk);

      // The mail sync is two providers below the switch. It rebuilt because it
      // watches, which is the whole mechanism — a stale sync here would keep
      // draining through the backend the user just left.
      expect(identical(ref.read(syncServiceProvider), before), isFalse);
    });

    test('and the choice is remembered', () async {
      final ref = await container();

      await ref.read(appPrefsProvider.notifier).setBackendMode(backendModeSdk);

      expect(await store.getPref(backendModeKey), backendModeSdk);
      // A second launch reads it back.
      final relaunched = await container();
      expect(relaunched.read(appPrefsProvider).backendMode, backendModeSdk);
      expect(relaunched.read(authSessionProvider), isA<GraphAuth>());
    });

    test('and back again', () async {
      final ref = await container();
      await ref.read(appPrefsProvider.notifier).setBackendMode(backendModeSdk);

      await ref.read(appPrefsProvider.notifier).setBackendMode(backendModeMcp);

      expect(ref.read(authSessionProvider), isA<McpAuthSession>());
      expect(ref.read(mailBackendProvider), isA<McpMailBackend>());
    });
  });

  group('pointing MCP mode at another server', () {
    // A URL that is neither preset: with no dart-define the LOCAL server is
    // already the default, so switching "to Local" would be a no-op and prove
    // nothing about the rebuild.
    const custom = 'http://127.0.0.1:9999/mcp';

    test('rebuilds the stack against the new URL', () async {
      final ref = await container();
      final before = ref.read(mcpStackProvider);

      await ref.read(appPrefsProvider.notifier).setMcpServerUrl(custom);

      final after = ref.read(mcpStackProvider);
      expect(identical(after, before), isFalse);
      expect(after.auth.mcpUrl.toString(), custom);
      expect(await store.getPref(mcpServerUrlKey), custom);
    });

    test('and the session and backends follow it', () async {
      final ref = await container();
      final before = ref.read(mailBackendProvider);

      await ref.read(appPrefsProvider.notifier).setMcpServerUrl(custom);

      expect(identical(ref.read(mailBackendProvider), before), isFalse);
      expect(
        (ref.read(authSessionProvider) as McpAuthSession).mcpUrl.toString(),
        custom,
      );
    });

    test('an emptied field asks for the default back', () async {
      final ref = await container();
      await ref.read(appPrefsProvider.notifier).setMcpServerUrl(mcpLocalUrl);

      await ref.read(appPrefsProvider.notifier).setMcpServerUrl('   ');

      expect(ref.read(appPrefsProvider).mcpServerUrl, defaultMcpServerUrl);
    });
  });

  group('the poll timer still cannot reach Teams', () {
    /// A [TeamsSync] that counts calls instead of making them — the same
    /// stand-in `teams_refresh_test.dart` uses, for the same reason.
    ///
    /// **Microsoft's terms for the Teams messaging endpoints forbid background
    /// polling.** Moving the request to a server changes nothing about that:
    /// the calls are still made with the user's delegated consent. The line
    /// this group holds is that the new wiring did not quietly put Teams back
    /// on the sixty-second timer.
    test('a full hour of loads, with the MCP backend wired, is zero calls',
        () async {
      final mcp = _CountingMcp();
      final sync = _FakeSync();
      final teams = _RecordingTeams(McpTeamsBackend(mcp), store);
      await store.upsertConversation({
        'source': 'email',
        'conversation_key': 'c1',
        'subject': 'c1',
        'state': 'needs_reply',
        'last_message_at': '2026-08-28T10:00:00Z',
      });
      final notifier = ConversationsNotifier(store, sync, teamsSync: teams);

      for (var i = 0; i < 60; i++) {
        await notifier.load();
      }

      expect(sync.syncCalls, 60, reason: 'mail did sync');
      expect(teams.calls, 0);
      expect(mcp.calls, isEmpty, reason: 'not one tool call reached the wire');
    });

    test('and the connector the app builds is still the separate one',
        () async {
      final ref = await container();

      // Typed to the concrete TeamsSync, and built from its own provider: that
      // separation is what makes "the timer cannot reach Teams" a fact about
      // the wiring rather than a rule someone has to remember.
      final TeamsSync teams = ref.read(teamsSyncProvider);
      expect(teams, isA<TeamsSync>());
      expect(ref.read(syncServiceProvider), isNot(isA<TeamsSync>()));
    });
  });
}

class _RecordingTeams extends TeamsSync {
  int calls = 0;

  _RecordingTeams(super.teams, super.store);

  @override
  Future<void> syncNow() async => calls++;
}
