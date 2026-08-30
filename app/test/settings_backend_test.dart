import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/widgets/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The settings dialog's backend half: which server the app talks through, and
/// what that server says the workspace may do.
///
/// The dialog stays a plain [StatefulWidget] over callbacks — no provider reads
/// inside — so everything here is driven with closures, and what is pinned is
/// which callback fires and what the connection status renders as.

void main() {
  Future<void> open(
    WidgetTester tester, {
    String backendMode = backendModeMcp,
    String mcpServerUrl = mcpDeployedUrl,
    void Function(String mode)? onBackendModeChanged,
    void Function(String url)? onMcpServerUrlChanged,
    Future<Map<String, Object?>?> Function()? connectionStatus,
    VoidCallback? onConnectMicrosoft,
    Future<bool> Function(String)? hasScope,
    VoidCallback? onSignInAgain,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SettingsDialog(
                threshold: 0.5,
                aboutMe: '',
                onThresholdChanged: (_) {},
                onAboutMeChanged: (_) {},
                backendMode: backendMode,
                mcpServerUrl: mcpServerUrl,
                onBackendModeChanged: onBackendModeChanged,
                onMcpServerUrlChanged: onMcpServerUrlChanged,
                connectionStatus: connectionStatus,
                onConnectMicrosoft: onConnectMicrosoft,
                hasScope: hasScope,
                onSignInAgain: onSignInAgain,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('the backend switch', () {
    testWidgets('is absent when the host wires none', (tester) async {
      // The same discipline hasScope follows: a host with nothing to switch
      // gets no section rather than a dead control.
      await open(tester);

      expect(find.text('Microsoft connection'), findsNothing);
    });

    testWidgets('offers both backends and fires on a pick', (tester) async {
      final picked = <String>[];
      await open(tester, onBackendModeChanged: picked.add);

      expect(find.text('Microsoft connection'), findsOneWidget);
      expect(find.text('Bond server'), findsWidgets);

      await tester.tap(find.text('This Mac'));
      await tester.pumpAndSettle();

      expect(picked, [backendModeSdk]);
    });

    testWidgets('the server picker is MCP-only', (tester) async {
      await open(
        tester,
        backendMode: backendModeSdk,
        onBackendModeChanged: (_) {},
      );

      expect(find.text('Deployed'), findsNothing);
    });

    testWidgets('picking the local preset commits it', (tester) async {
      final urls = <String>[];
      await open(
        tester,
        onBackendModeChanged: (_) {},
        onMcpServerUrlChanged: urls.add,
      );

      await tester.tap(find.text('Deployed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local').last);
      await tester.pumpAndSettle();

      expect(urls, [mcpLocalUrl]);
    });

    testWidgets('Custom reveals a field that commits on submit', (tester) async {
      final urls = <String>[];
      await open(
        tester,
        onBackendModeChanged: (_) {},
        onMcpServerUrlChanged: urls.add,
      );

      await tester.tap(find.text('Deployed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom…').last);
      await tester.pumpAndSettle();

      final field = find.widgetWithText(TextField, mcpDeployedUrl);
      expect(field, findsOneWidget, reason: 'it opens on what is set now');
      expect(urls, isEmpty, reason: 'revealing the field commits nothing');

      await tester.enterText(field, 'http://127.0.0.1:9999/mcp');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(urls, ['http://127.0.0.1:9999/mcp']);
    });

    testWidgets('a server typed and then left commits too', (tester) async {
      // Most people click away rather than pressing Enter.
      final urls = <String>[];
      await open(
        tester,
        mcpServerUrl: 'http://elsewhere/mcp',
        onBackendModeChanged: (_) {},
        onMcpServerUrlChanged: urls.add,
      );

      final field = find.widgetWithText(TextField, 'http://elsewhere/mcp');
      expect(field, findsOneWidget,
          reason: 'a stored server that is neither preset opens on Custom');

      await tester.enterText(field, 'http://typed/mcp');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(urls, ['http://typed/mcp']);
    });
  });

  group('what the workspace may do', () {
    Future<Map<String, Object?>?> Function() status(
      Map<String, Object?>? answer, {
      List<int>? counter,
    }) =>
        () async {
          counter?.add(1);
          return answer;
        };

    testWidgets('reads the granted scopes off the status', (tester) async {
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: status({
          'connected': true,
          'scopes': ['Mail.Send', 'Mail.ReadWrite'],
        }),
        onConnectMicrosoft: () {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Send mail'), findsOneWidget);
      expect(find.text('Save drafts'), findsOneWidget);
      expect(find.text('Teams chats — awaiting admin approval'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNWidgets(2));
      // Chat.Read is admin-gated and was not granted; there is nothing in this
      // dialog that can change that, so there is no offer beside it either.
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('Sign in again to enable'), findsNothing);
    });

    testWidgets('a connected account with no scopes recorded is mail-only',
        (tester) async {
      // Rows that predate the platform storing scopes were all mail grants —
      // the same answer McpAuthSession.hasScope gives.
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: status({'connected': true, 'scopes': const []}),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check), findsNWidgets(2));
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('nothing connected offers the connect step', (tester) async {
      var asked = 0;
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: status({'error': 'not_connected', 'connect_url': 'x'}),
        onConnectMicrosoft: () => asked++,
      );
      await tester.pumpAndSettle();

      expect(
        find.text('No Microsoft account is connected to this workspace.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check), findsNothing);

      await tester.tap(find.text('Connect Microsoft'));
      await tester.pumpAndSettle();

      expect(asked, 1);
    });

    testWidgets('a status that could not be read reads the same way',
        (tester) async {
      // This section reports; "we could not ask" is closer to nothing-connected
      // than to a row of ticks nobody verified.
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: status(null),
        onConnectMicrosoft: () {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Connect Microsoft'), findsOneWidget);
    });

    testWidgets('the platform is asked once, not once per rebuild',
        (tester) async {
      final counter = <int>[];
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: status({'connected': true}, counter: counter),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider), const Offset(-100, 0));
      await tester.pumpAndSettle();

      expect(counter, hasLength(1), reason: 'it is a round trip, not a read');
    });

    testWidgets('SDK mode still renders the static table', (tester) async {
      final asked = <String>[];
      await open(
        tester,
        backendMode: backendModeSdk,
        onBackendModeChanged: (_) {},
        hasScope: (scope) async {
          asked.add(scope);
          return true;
        },
        onSignInAgain: () {},
      );
      await tester.pumpAndSettle();

      expect(asked, ['mail.send', 'mail.readwrite', 'chat.read']);
      expect(find.byIcon(Icons.check), findsNWidgets(3));
      expect(find.text('Connect Microsoft'), findsNothing);
    });
  });
}
