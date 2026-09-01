// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/sign_in_screen.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_auth.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The sign-in screen's second step.
///
/// Signing in to the Bond workspace and connecting a Microsoft account are two
/// different grants held in two different places, and a user who has done the
/// first but not the second is signed in with nothing to read. The line this
/// file holds is that the screen notices that case and can leave it — and that
/// an existing remote user, whose workspace is already connected, never sees
/// the step at all.

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

/// The wire, scripted. The last reply is sticky.
class _FakeMcp implements BondMcpClient {
  final List<Map<String, dynamic>> replies;
  final List<String> calls = [];

  _FakeMcp(this.replies);

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add(name);
    return replies.length == 1 ? replies.first : replies.removeAt(0);
  }

  @override
  Future<void> close() async {}
}

/// A session that signs in without a browser. [needsReconsent] is what the
/// screen routes on, and here it is simply told.
class _FakeSession implements AuthSession {
  final bool reconsent;
  int signIns = 0;

  _FakeSession({this.reconsent = false});

  @override
  Future<bool> get isSignedIn async => signIns > 0;

  @override
  Future<bool> get needsReconsent async => reconsent;

  @override
  Future<bool> hasScope(String bareScope) async => true;

  @override
  Future<AccountInfo?> get storedAccount async => null;

  @override
  Future<AccountInfo> signIn() async {
    signIns++;
    return const AccountInfo(displayName: 'Jared');
  }

  @override
  Future<void> signOut() async {}
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// Pumps the screen over a faked session and a faked MCP wire.
  ///
  /// The stack override is a REAL [McpAuthSession] — the screen calls its
  /// `microsoftConnectUrl` and `invalidateStatusCache` directly, and faking
  /// those would test a stand-in rather than the flow.
  Future<_FakeMcp> pump(
    WidgetTester tester, {
    required _FakeSession session,
    required List<Map<String, dynamic>> statuses,
    required VoidCallback onSignedIn,
    String backendMode = backendModeMcp,
  }) async {
    await store.setPref(backendModeKey, backendMode);
    final mcp = _FakeMcp(statuses);
    final auth = McpAuthSession(
      mcpUrl: Uri.parse(mcpLocalUrl),
      mcpClient: mcp,
      store: _Tokens(),
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        authSessionProvider.overrideWithValue(session),
        mcpStackProvider.overrideWithValue((auth: auth, client: mcp)),
      ],
      child: MaterialApp(home: SignInScreen(onSignedIn: onSignedIn)),
    ));
    await tester.pumpAndSettle();
    return mcp;
  }

  testWidgets('MCP mode signs in to the workspace, not to Microsoft',
      (tester) async {
    var signedIn = 0;
    await pump(
      tester,
      session: _FakeSession(),
      statuses: [
        {'connected': true},
      ],
      onSignedIn: () => signedIn++,
    );

    expect(
      find.text('Sign in to your Bond workspace to read your mail.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    // A workspace that is already connected is one sign-in long. This is the
    // existing remote user's whole journey.
    expect(signedIn, 1);
    expect(find.text('Connect your Microsoft account'), findsNothing);
  });

  testWidgets('a workspace with no Microsoft account shows the connect step',
      (tester) async {
    var signedIn = 0;
    final mcp = await pump(
      tester,
      session: _FakeSession(reconsent: true),
      statuses: [
        {'connected': false, 'connect_url': 'https://bond.example/connect'},
      ],
      onSignedIn: () => signedIn++,
    );

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(signedIn, 0, reason: 'there is nothing to read yet');
    expect(find.text('Connect your Microsoft account'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Connect Microsoft'),
      ).onPressed,
      isNotNull,
      reason: 'the platform offered a connect URL',
    );
    expect(mcp.calls, contains('connection_status'));
  });

  testWidgets('a server with no connect flow says so rather than dead-ending',
      (tester) async {
    await pump(
      tester,
      session: _FakeSession(reconsent: true),
      statuses: [
        {'connected': false, 'connect_url': null},
      ],
      onSignedIn: () {},
    );

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Connect Microsoft'),
      ).onPressed,
      isNull,
    );
    expect(find.textContaining('no connect step of its own'), findsOneWidget);
  });

  testWidgets('continuing re-probes, and a landed connection goes in',
      (tester) async {
    var signedIn = 0;
    final mcp = await pump(
      tester,
      session: _FakeSession(reconsent: true),
      statuses: [
        {'connected': false, 'connect_url': 'https://bond.example/connect'},
        {'connected': true, 'scopes': const ['Mail.Read']},
      ],
      onSignedIn: () => signedIn++,
    );

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I've connected — continue"));
    await tester.pumpAndSettle();

    expect(signedIn, 1);
    // The status cache is thirty seconds long and the user has just spent that
    // long in a browser — the probe has to be dropped, or the screen reports
    // the state they went to fix.
    expect(mcp.calls.length, greaterThanOrEqualTo(2));
  });

  testWidgets('a connection that still has not landed says so and stays put',
      (tester) async {
    var signedIn = 0;
    await pump(
      tester,
      session: _FakeSession(reconsent: true),
      statuses: [
        {'connected': false, 'connect_url': 'https://bond.example/connect'},
      ],
      onSignedIn: () => signedIn++,
    );

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I've connected — continue"));
    await tester.pumpAndSettle();

    expect(signedIn, 0);
    expect(find.textContaining('still not connected'), findsOneWidget);
    expect(find.text('Connect your Microsoft account'), findsOneWidget);
  });

  testWidgets('SDK mode is untouched: one button, and nothing is asked of the '
      'platform', (tester) async {
    var signedIn = 0;
    final mcp = await pump(
      tester,
      backendMode: backendModeSdk,
      // Even a session that would report a missing consent: in SDK mode the
      // sign-in IS the Microsoft consent, and there is no second step to offer.
      session: _FakeSession(reconsent: true),
      statuses: [
        {'connected': false},
      ],
      onSignedIn: () => signedIn++,
    );

    expect(
      find.text('Connect your Microsoft account to read your mail.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Sign in with Microsoft'));
    await tester.pumpAndSettle();

    expect(signedIn, 1);
    expect(mcp.calls, isEmpty);
  });

  testWidgets('a refused sign-in lands in the error slot', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        authSessionProvider.overrideWithValue(_RefusingSession()),
      ],
      child: MaterialApp(home: SignInScreen(onSignedIn: () {})),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in was refused: nope'), findsOneWidget);
  });
}

class _RefusingSession extends _FakeSession {
  @override
  Future<AccountInfo> signIn() async =>
      throw const AuthException('Sign-in was refused: nope');
}
