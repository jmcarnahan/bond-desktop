import 'package:bond_inbox/services/server/server_state.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/settings_local_server_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Local server card, driven by props alone.
///
/// It reaches for no provider, so there is no `InboxScreen`, no supervisor and
/// no sixty-second timer here — which is what makes `pumpAndSettle` safe.
///
/// What is pinned: the sentence each state produces, which of the three
/// lifecycle buttons a state offers, that the port field refuses a number no
/// server could bind, and that the switch is the only live control while the
/// app is not the one running the server.
void main() {
  Future<void> open(
    WidgetTester tester, {
    ServerState state = const ServerStopped(),
    bool managed = true,
    int port = 8080,
    String folder = '/Users/x/Library/Application Support/com.bondinbox.app/models',
    void Function(bool)? onManagedChanged,
    void Function(int)? onPortSaved,
    Future<int> Function()? onPickFreePort,
    VoidCallback? onChooseFolder,
    VoidCallback? onStart,
    VoidCallback? onStop,
    VoidCallback? onRestart,
    VoidCallback? onShowLog,
    VoidCallback? onSetUpAgain,
    bool wireLifecycle = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsLocalServerBody(
            state: state,
            managed: managed,
            port: port,
            modelsFolder: folder,
            onManagedChanged: onManagedChanged ?? (_) {},
            onPortSaved: onPortSaved ?? (_) {},
            onPickFreePort: onPickFreePort ?? () async => 45123,
            onChooseFolder: onChooseFolder ?? () {},
            onStart: wireLifecycle ? (onStart ?? () {}) : null,
            onStop: wireLifecycle ? (onStop ?? () {}) : null,
            onRestart: wireLifecycle ? (onRestart ?? () {}) : null,
            onShowLog: onShowLog ?? () {},
            onSetUpAgain: onSetUpAgain,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, Key key) {
    final widget = tester.widget(find.byKey(key));
    if (widget is TextField) return widget.enabled ?? true;
    return (widget as ButtonStyleButton).onPressed != null;
  }

  group('the summary', () {
    test('says what each state is, when the app runs the server', () {
      String say(ServerState state) =>
          SettingsLocalServerBody.summary(state, managed: true);

      expect(say(const ServerStopped()), 'Stopped');
      expect(say(const ServerStarting()), 'Starting…');
      expect(say(const ServerStarting(port: 8080)), 'Starting… on port 8080');
      expect(
        say(const ServerLoading(port: 8080, pid: 7, loaded: {
          'bond-embed': true,
          'bond-bulk': false,
          'bond-prose': false,
        })),
        'Loading models (1 of 3) on port 8080',
      );
      expect(say(const ServerReady(port: 8080, pid: 7)), 'Ready on 127.0.0.1:8080');
      expect(say(const ServerFailed('exited (code 1)')), 'Failed: exited (code 1)');
      expect(say(const ServerPortInUse(8080)), 'Port 8080 is in use');
      expect(
        say(const ServerPortInUse(8080, holder: 'llama-server (pid 91)')),
        'Port 8080 is in use by llama-server (pid 91)',
      );
      expect(say(const ServerDisabled()), 'Off — servers are started by hand');
    });

    /// The switch WINS: turning the preference off stops the server
    /// asynchronously, and a card still saying 'Ready' for that second would
    /// be reporting a server the app has already stopped using.
    test('says off for every state once the switch is off', () {
      for (final state in const <ServerState>[
        ServerStopped(),
        ServerStarting(port: 8080),
        ServerReady(port: 8080, pid: 7),
        ServerFailed('exited (code 1)'),
        ServerPortInUse(8080),
      ]) {
        expect(
          SettingsLocalServerBody.summary(state, managed: false),
          'Off — servers are started by hand',
        );
      }
    });
  });

  testWidgets('the status line renders the summary it is given', (tester) async {
    await open(tester, state: const ServerReady(port: 9310, pid: 7));
    expect(find.text('Ready on 127.0.0.1:9310'), findsOneWidget);
  });

  testWidgets('a failure is an error alert carrying the log tail',
      (tester) async {
    await open(
      tester,
      state: ServerFailed(
        'exited (code 1)',
        logTail: [for (var i = 0; i < 20; i++) 'line $i'],
      ),
    );

    final alert = tester.widget<InlineAlert>(find.byType(InlineAlert));
    expect(alert.severity, InlineAlertSeverity.error);
    expect(alert.text, 'Failed: exited (code 1)');
    // The last twelve, and nothing older.
    expect(find.textContaining('line 19'), findsOneWidget);
    expect(find.textContaining('line 8'), findsOneWidget);
    expect(find.textContaining('line 7'), findsNothing);
  });

  testWidgets('a held port says who can fix it, and how', (tester) async {
    await open(tester, state: const ServerPortInUse(8080, holder: 'llama-server (pid 91)'));

    final alert = tester.widget<InlineAlert>(find.byType(InlineAlert));
    expect(alert.severity, InlineAlertSeverity.error);
    expect(
      find.text('Pick a free port below, or stop the other program.'),
      findsOneWidget,
    );
  });

  testWidgets('a start in progress is an attention alert, not an error',
      (tester) async {
    await open(tester, state: const ServerStarting(port: 8080));
    expect(
      tester.widget<InlineAlert>(find.byType(InlineAlert)).severity,
      InlineAlertSeverity.attention,
    );
  });

  testWidgets('the switch reports what it was moved to', (tester) async {
    final reported = <bool>[];
    await open(tester, managed: false, onManagedChanged: reported.add);

    await tester.tap(find.byKey(SettingsLocalServerBody.managedKey));
    await tester.pumpAndSettle();

    expect(reported, [true]);
    // And the card follows its own switch without waiting for the host.
    expect(find.text('Stopped'), findsOneWidget);
  });

  group('the port field', () {
    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(SettingsLocalServerBody.portFieldKey),
        text,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Save is dead on the current port', (tester) async {
      await open(tester, port: 8080);
      expect(enabled(tester, SettingsLocalServerBody.savePortKey), isFalse);
    });

    testWidgets('Save is dead on a port below the range', (tester) async {
      await open(tester);
      await type(tester, '80');
      expect(enabled(tester, SettingsLocalServerBody.savePortKey), isFalse);
      expect(find.text(SettingsLocalServerBody.portError), findsOneWidget);
    });

    testWidgets('Save is dead on something that is not a number',
        (tester) async {
      await open(tester);
      await type(tester, 'abc');
      expect(enabled(tester, SettingsLocalServerBody.savePortKey), isFalse);
    });

    testWidgets('Save fires with a usable port', (tester) async {
      final saved = <int>[];
      await open(tester, onPortSaved: saved.add);
      await type(tester, '9000');

      expect(enabled(tester, SettingsLocalServerBody.savePortKey), isTrue);
      await tester.tap(find.byKey(SettingsLocalServerBody.savePortKey));
      await tester.pumpAndSettle();

      expect(saved, [9000]);
    });

    testWidgets('Pick a free port fills the field and saves nothing',
        (tester) async {
      final saved = <int>[];
      await open(
        tester,
        onPortSaved: saved.add,
        onPickFreePort: () async => 45123,
      );

      await tester.tap(find.byKey(SettingsLocalServerBody.pickPortKey));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(SettingsLocalServerBody.portFieldKey),
      );
      expect(field.controller!.text, '45123');
      expect(saved, isEmpty);
      expect(enabled(tester, SettingsLocalServerBody.savePortKey), isTrue);
    });
  });

  group('the lifecycle buttons', () {
    testWidgets('a stopped server offers Start alone', (tester) async {
      await open(tester, state: const ServerStopped());
      expect(find.byKey(SettingsLocalServerBody.startKey), findsOneWidget);
      expect(find.byKey(SettingsLocalServerBody.stopKey), findsNothing);
      expect(find.byKey(SettingsLocalServerBody.restartKey), findsNothing);
    });

    testWidgets('a failed server offers Start', (tester) async {
      await open(tester, state: const ServerFailed('exited (code 1)'));
      expect(find.byKey(SettingsLocalServerBody.startKey), findsOneWidget);
    });

    testWidgets('a held port offers Start', (tester) async {
      await open(tester, state: const ServerPortInUse(8080));
      expect(find.byKey(SettingsLocalServerBody.startKey), findsOneWidget);
    });

    testWidgets('a starting server offers Stop and not Restart',
        (tester) async {
      await open(tester, state: const ServerStarting(port: 8080));
      expect(find.byKey(SettingsLocalServerBody.startKey), findsNothing);
      expect(find.byKey(SettingsLocalServerBody.stopKey), findsOneWidget);
      expect(find.byKey(SettingsLocalServerBody.restartKey), findsNothing);
    });

    testWidgets('a loading server offers Stop and Restart', (tester) async {
      await open(
        tester,
        state: const ServerLoading(port: 8080, pid: 7, loaded: {'bond-bulk': false}),
      );
      expect(find.byKey(SettingsLocalServerBody.stopKey), findsOneWidget);
      expect(find.byKey(SettingsLocalServerBody.restartKey), findsOneWidget);
    });

    testWidgets('a ready server offers Stop and Restart, and they fire',
        (tester) async {
      var stops = 0;
      var restarts = 0;
      await open(
        tester,
        state: const ServerReady(port: 8080, pid: 7),
        onStop: () => stops++,
        onRestart: () => restarts++,
      );

      await tester.tap(find.byKey(SettingsLocalServerBody.stopKey));
      await tester.tap(find.byKey(SettingsLocalServerBody.restartKey));
      await tester.pumpAndSettle();

      expect(stops, 1);
      expect(restarts, 1);
    });

    testWidgets('an unwired host gets no lifecycle buttons at all',
        (tester) async {
      await open(tester, wireLifecycle: false);
      expect(find.byKey(SettingsLocalServerBody.startKey), findsNothing);
      expect(find.byKey(SettingsLocalServerBody.stopKey), findsNothing);
      expect(find.byKey(SettingsLocalServerBody.restartKey), findsNothing);
    });
  });

  testWidgets('Show log is offered in every state', (tester) async {
    for (final state in const <ServerState>[
      ServerStopped(),
      ServerReady(port: 8080, pid: 7),
      ServerFailed('exited (code 1)'),
    ]) {
      await open(tester, state: state);
      expect(find.byKey(SettingsLocalServerBody.showLogKey), findsOneWidget);
    }
  });

  testWidgets('Set up again is absent until it is wired', (tester) async {
    await open(tester);
    expect(find.byKey(SettingsLocalServerBody.setUpAgainKey), findsNothing);

    await open(tester, onSetUpAgain: () {});
    expect(find.byKey(SettingsLocalServerBody.setUpAgainKey), findsOneWidget);
  });

  testWidgets('the folder is shown, and Change folder… reports', (tester) async {
    var chosen = 0;
    await open(tester, folder: '/Volumes/Big/models', onChooseFolder: () => chosen++);

    expect(find.text('/Volumes/Big/models'), findsOneWidget);
    await tester.tap(find.byKey(SettingsLocalServerBody.chooseFolderKey));
    await tester.pumpAndSettle();
    expect(chosen, 1);
  });

  testWidgets('with the switch off, only the switch is live', (tester) async {
    await open(tester, managed: false, state: const ServerStopped());

    expect(find.text('Off — servers are started by hand'), findsOneWidget);
    expect(enabled(tester, SettingsLocalServerBody.portFieldKey), isFalse);
    expect(enabled(tester, SettingsLocalServerBody.savePortKey), isFalse);
    expect(enabled(tester, SettingsLocalServerBody.pickPortKey), isFalse);
    expect(enabled(tester, SettingsLocalServerBody.chooseFolderKey), isFalse);
    expect(enabled(tester, SettingsLocalServerBody.startKey), isFalse);
    expect(enabled(tester, SettingsLocalServerBody.showLogKey), isFalse);
    // The switch itself is always live — it is the way back.
    final tile = tester.widget<SwitchListTile>(
      find.byKey(SettingsLocalServerBody.managedKey),
    );
    expect(tile.onChanged, isNotNull);
  });
}
