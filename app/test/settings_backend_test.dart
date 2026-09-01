import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/widgets/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The settings dialog's backend half: which server the app talks through, and
/// what that server says the workspace may do.
///
/// The dialog stays a plain [StatefulWidget] over callbacks — no provider reads
/// inside — so everything here is driven with closures, and what is pinned is
/// which callback fires and what the connection status renders as.

/// A stand-in for the compiled `BOND_MCP_SERVER_URL` define. The test binary
/// carries no define (backend_switch_test pins that), so exercising the
/// Deployed preset means injecting a URL through the widget's parameter.
const String _deployed = 'https://mcp.example.test/mcp';

void main() {
  Future<void> open(
    WidgetTester tester, {
    String backendMode = backendModeMcp,
    String mcpServerUrl = _deployed,
    String deployedUrl = _deployed,
    void Function(String mode)? onBackendModeChanged,
    void Function(String url)? onMcpServerUrlChanged,
    Future<Map<String, Object?>?> Function()? connectionStatus,
    VoidCallback? onConnectMicrosoft,
    Future<bool> Function(String)? hasScope,
    VoidCallback? onSignInAgain,
    Future<bool> Function()? isTargetSignedIn,
    Future<String?> Function()? targetAccountLabel,
    Future<void> Function()? onSignIn,
    Future<void> Function()? onSignOutOfServer,
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
                deployedUrl: deployedUrl,
                onBackendModeChanged: onBackendModeChanged,
                onMcpServerUrlChanged: onMcpServerUrlChanged,
                connectionStatus: connectionStatus,
                onConnectMicrosoft: onConnectMicrosoft,
                hasScope: hasScope,
                onSignInAgain: onSignInAgain,
                isTargetSignedIn: isTargetSignedIn,
                targetAccountLabel: targetAccountLabel,
                onSignIn: onSignIn,
                onSignOutOfServer: onSignOutOfServer,
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

    testWidgets('the toggle swaps the permissions in place, without closing',
        (tester) async {
      // The UX bug this pins: the dialog used to be closed on a switch (and
      // kept a stale answer on reopen-before-the-fix), so a user never saw
      // what their own click did. Now the switch re-asks the OTHER source
      // and renders its answer in the still-open dialog.
      var statusAsks = 0;
      var scopeAsks = 0;
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: () async {
          statusAsks++;
          return {'connected': true, 'scopes': <Object?>[]};
        },
        hasScope: (_) async {
          scopeAsks++;
          return true;
        },
      );

      // Opened in MCP mode: the platform answered, the keychain was not
      // asked at all.
      expect(statusAsks, 1);
      expect(scopeAsks, 0);
      expect(find.byIcon(Icons.check), findsWidgets);

      await tester.tap(find.text('This Mac'));
      await tester.pumpAndSettle();

      // Still open, and the static table answered from the keychain.
      expect(find.text('Settings'), findsOneWidget);
      expect(scopeAsks, SettingsDialog.permissions.length);
      expect(find.byIcon(Icons.check), findsWidgets);

      await tester.tap(find.text('Bond server').first);
      await tester.pumpAndSettle();

      // And back: the platform is asked FRESH, not remembered.
      expect(statusAsks, 2);
    });

    testWidgets('picking another server re-asks the platform', (tester) async {
      // A committed server is a new connection; rows answering for the one
      // just left were the other half of the same UX bug.
      var statusAsks = 0;
      await open(
        tester,
        onBackendModeChanged: (_) {},
        onMcpServerUrlChanged: (_) {},
        connectionStatus: () async {
          statusAsks++;
          return {'connected': false};
        },
      );
      expect(statusAsks, 1);

      await tester.tap(find.text('Deployed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local').last);
      await tester.pumpAndSettle();

      expect(statusAsks, 2);
    });

    testWidgets('the server picker is MCP-only', (tester) async {
      await open(
        tester,
        backendMode: backendModeSdk,
        onBackendModeChanged: (_) {},
      );

      expect(find.text('Deployed'), findsNothing);
    });

    testWidgets('a build with no deployed endpoint offers no Deployed preset',
        (tester) async {
      // The deployed URL is a --dart-define, absent from most builds — the
      // dropdown must not offer a preset that would commit an empty URL.
      await open(
        tester,
        deployedUrl: '',
        mcpServerUrl: mcpLocalUrl,
        onBackendModeChanged: (_) {},
      );

      await tester.tap(find.text('Local'));
      await tester.pumpAndSettle();
      expect(find.text('Deployed'), findsNothing);
      expect(find.text('Custom…'), findsWidgets);
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

      final field = find.widgetWithText(TextField, _deployed);
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
      expect(find.text('Teams chats'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNWidgets(2));
      // Chat.Read was not granted; there is nothing in this dialog that can
      // change that, so there is no offer beside it either.
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('Sign in again to enable'), findsNothing);
    });

    testWidgets('the wider grant satisfies the read-only question',
        (tester) async {
      // The platform's admin grant is Chat.ReadWrite / Mail.ReadWrite; the
      // rows ask chat.read / mail.readwrite. The dialog's matcher must agree
      // with McpAuthSession.hasScope, or it contradicts the Teams pill that
      // is enabled right behind it.
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: status({
          'connected': true,
          'scopes': ['Mail.Send', 'Mail.ReadWrite', 'Chat.ReadWrite'],
        }),
        onConnectMicrosoft: () {},
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check), findsNWidgets(3));
      expect(find.byIcon(Icons.close), findsNothing);
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

    testWidgets('a status that could not be read says so, and offers no button',
        (tester) async {
      // "We could not ask" is a different claim from "nothing is connected",
      // and a Connect Microsoft button on top of it is a dead click — it needs
      // a session to fetch the connect link with. Say what is actually known.
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: status(null),
        onConnectMicrosoft: () {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Connect Microsoft'), findsNothing);
      expect(find.textContaining('it may be unreachable'), findsOneWidget);
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

  group('the session for the selected target', () {
    // The dialog is where sessions live now: the gate in front of the app
    // decides at launch only, so a target with no session has to be a thing
    // this dialog states and fixes, in place, without the screen underneath
    // changing.

    testWidgets('an unsigned target is named, and the server is not probed',
        (tester) async {
      // Probing a server that is going to answer 401 buys nothing: the reason
      // it will is already on screen, one line up, with the fix beside it.
      var statusAsks = 0;
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: () async {
          statusAsks++;
          return {'connected': true};
        },
        isTargetSignedIn: () async => false,
        onSignIn: () async {},
      );

      expect(find.text('Not signed in to this server.'), findsOneWidget);
      expect(find.text('Sign in…'), findsOneWidget);
      expect(statusAsks, 0, reason: 'a 401 is not worth a round trip');
      expect(
        find.text('Microsoft permissions'),
        findsNothing,
        reason: 'there is no workspace grant to report without a session',
      );
    });

    testWidgets('Sign in… runs the sign-in and re-asks everything',
        (tester) async {
      var signedIn = false;
      var sessionAsks = 0;
      var statusAsks = 0;
      var signIns = 0;
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: () async {
          statusAsks++;
          return {'connected': true, 'scopes': ['Mail.Send']};
        },
        isTargetSignedIn: () async {
          sessionAsks++;
          return signedIn;
        },
        targetAccountLabel: () async => 'lo@bank.test',
        onSignIn: () async {
          signIns++;
          signedIn = true;
        },
      );
      expect(sessionAsks, 1);
      expect(statusAsks, 0);

      await tester.tap(find.text('Sign in…'));
      await tester.pumpAndSettle();

      expect(signIns, 1);
      expect(sessionAsks, 2, reason: 'the new session is asked, not assumed');
      expect(statusAsks, 1, reason: 'and now the server is worth asking');
      expect(find.text('Signed in as lo@bank.test.'), findsOneWidget);
      expect(find.text('Send mail'), findsOneWidget);
    });

    testWidgets('a sign-in that fails says why, inline, and stays open',
        (tester) async {
      // AuthException messages are already written for a person, and this one
      // belongs beside the button that produced it — the user is about to
      // press it again.
      var attempts = 0;
      await open(
        tester,
        onBackendModeChanged: (_) {},
        isTargetSignedIn: () async => false,
        onSignIn: () async {
          attempts++;
          if (attempts == 1) throw const AuthException('no browser');
        },
      );

      await tester.tap(find.text('Sign in…'));
      await tester.pumpAndSettle();

      expect(find.text('no browser'), findsOneWidget);
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in…'))
            .onPressed,
        isNotNull,
        reason: 'a failure re-arms the button rather than stranding it busy',
      );

      await tester.tap(find.text('Sign in…'));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(
        find.text('no browser'),
        findsNothing,
        reason: 'the second attempt owns the slot, not the first',
      );
    });

    testWidgets('a signed-in target names the account and can leave it',
        (tester) async {
      var signedIn = true;
      var sessionAsks = 0;
      var signOuts = 0;
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: () async => {'connected': true, 'scopes': const []},
        isTargetSignedIn: () async {
          sessionAsks++;
          return signedIn;
        },
        targetAccountLabel: () async => 'lo@bank.test',
        onSignIn: () async {},
        onSignOutOfServer: () async {
          signOuts++;
          signedIn = false;
        },
      );

      expect(find.text('Signed in as lo@bank.test.'), findsOneWidget);

      await tester.tap(find.text('Sign out of this server'));
      await tester.pumpAndSettle();

      expect(signOuts, 1);
      expect(sessionAsks, 2);
      expect(find.text('Not signed in to this server.'), findsOneWidget);
      expect(find.byType(SettingsDialog), findsOneWidget,
          reason: 'leaving one server does not close the dialog');
    });

    testWidgets('a signed-in server that does not answer says it is unreachable',
        (tester) async {
      await open(
        tester,
        onBackendModeChanged: (_) {},
        connectionStatus: () async => null,
        isTargetSignedIn: () async => true,
        onSignIn: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Signed in.'), findsOneWidget,
          reason: 'a session with no name to give still reports the state');
      expect(find.textContaining('it may be unreachable'), findsOneWidget);
    });

    testWidgets('the session block replaces the old sign-in-again offer',
        (tester) async {
      // Two sign-in buttons in one dialog is one too many, and the one in the
      // session block is the same action beside the state it fixes.
      await open(
        tester,
        backendMode: backendModeSdk,
        onBackendModeChanged: (_) {},
        hasScope: (_) async => false,
        onSignInAgain: () {},
        isTargetSignedIn: () async => true,
        onSignIn: () async {},
        onSignOutOfServer: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.close), findsNWidgets(3));
      expect(find.text('Sign in again to enable'), findsNothing);
      expect(find.text('Sign out of this server'), findsOneWidget);
    });
  });

  group('the dialog being unmounted by its own callback', () {
    testWidgets('a backend switch does not throw from the dispose-time save',
        (tester) async {
      // The crash this pins: the mode callback pops the dialog and mutates the
      // prefs; the mutation rebuilds the watching host, which unmounts the
      // dialog INSIDE that frame; the dialog's dispose then saved the about-me
      // text straight into the notifier — a provider write in a locked tree,
      // an exception on every switch. The save must land, just not inline.
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            final mode = ref.watch(_prefsProvider);
            return Scaffold(
              body: Column(children: [
                Text('mode:$mode'),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (dialogContext) => SettingsDialog(
                        threshold: 0.5,
                        aboutMe: 'who I am',
                        onThresholdChanged: (_) {},
                        onAboutMeChanged: (text) => ref
                            .read(_prefsProvider.notifier)
                            .saveAboutMe(text),
                        backendMode: ref.read(_prefsProvider),
                        onBackendModeChanged: (picked) {
                          Navigator.of(dialogContext).pop();
                          ref.read(_prefsProvider.notifier).setMode(picked);
                        },
                        connectionStatus: () async => null,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ]),
            );
          }),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Edited, not just present: an untouched text is no longer saved at all
      // (see the settings_dialog tests), and this test needs the save to
      // actually FIRE through the unmount-inside-callback path it guards.
      await tester.enterText(find.byType(TextField), 'who I am, edited');
      await tester.tap(find.text('This Mac'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('mode:$backendModeSdk'), findsOneWidget);
      final prefs = ProviderScope.containerOf(
        tester.element(find.text('mode:$backendModeSdk')),
      ).read(_prefsProvider.notifier);
      expect(prefs.aboutMeSaves, ['who I am, edited']);
    });
  });
}

/// The regression shape behind the backend-switch crash: the host WATCHES a
/// notifier, the mode callback pops the dialog and then mutates that notifier
/// — which rebuilds the host and unmounts the dialog inside the same frame —
/// and the dialog's dispose-time about-me save writes to the notifier too.
/// Duplicated minimal rather than wired through the real prefs provider, so
/// this file needs no database.
class _RecordingPrefs extends StateNotifier<String> {
  final List<String> aboutMeSaves = [];

  _RecordingPrefs() : super(backendModeMcp);

  void setMode(String mode) => state = mode;

  void saveAboutMe(String text) => aboutMeSaves.add(text);
}

final _prefsProvider =
    StateNotifierProvider<_RecordingPrefs, String>((ref) => _RecordingPrefs());

