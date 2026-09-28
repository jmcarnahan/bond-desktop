import 'dart:async';

import 'package:bond_inbox/providers/app_providers.dart' show ParkedFact;
import 'package:bond_inbox/services/decision/decision_client.dart'
    show noTokenizeText, notDecisionModelText;
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/managed_model_status.dart';
import 'package:bond_inbox/services/server/server_state.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:bond_inbox/widgets/settings_models_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Models page: three roles, top to bottom, each saying where it runs.
///
/// Prop-only, so this file pumps it alone with no screen and no host around
/// it, which is what makes `pumpAndSettle` safe here. What the HOST resolves
/// into those props is `settings_models_host_test.dart`'s job; what the form
/// does with an address is `model_servers_form_test.dart`'s.
///
/// Rows and statuses are read BY KEY, never by position.

const _generativeUrl = 'https://box.example.com/prose/v1/chat/completions';
const _decisionUrl = 'https://box.example.com/decide/v1/embeddings';

/// One write the page made, as the host would receive it.
typedef Write = ({
  String role,
  ModelPlacement placement,
  String? managedModel,
  String? url,
  String? model,
  String? key,
  bool clearKey,
});

ManagedModelStatus _row(
  String roleId, {
  String name = 'A model',
  int bytes = 1024 * 1024 * 1024,
  bool onDisk = true,
  String? routerId,
  bool inUse = true,
  bool local = false,
  bool headsOnDisk = true,
}) =>
    ManagedModelStatus(
      roleId: roleId,
      displayName: name,
      bytes: bytes,
      onDisk: onDisk,
      routerId: routerId ??
          switch (roleId) {
            'decision' => routerDecideId,
            'generative' => routerProseId,
            _ => routerEmbedId,
          },
      inUse: inUse,
      local: local,
      headsOnDisk: headsOnDisk,
    );

void main() {
  late List<Write> writes;
  late int checks;

  setUp(() {
    writes = [];
    checks = 0;
  });

  RoleWrite recorder(String role) => ({
        required placement,
        managedModel,
        url,
        model,
        key,
        clearKey = false,
      }) async =>
          writes.add((
            role: role,
            placement: placement,
            managedModel: managedModel,
            url: url,
            model: model,
            key: key,
            clearKey: clearKey,
          ));

  Future<void> open(
    WidgetTester tester, {
    ModelPlacement decision = ModelPlacement.local,
    ModelPlacement generative = ModelPlacement.local,
    String managedId = routerProseId,
    bool inboxTier = false,
    bool processingOn = true,
    ServerState serverState = const ServerStopped(),
    bool decisionKeyStored = false,
    bool generativeKeyStored = false,
    String generativeUrl = _generativeUrl,
    List<ManagedModelStatus>? statuses,
    ParkedFact? parked,
    String? decideInstallDir,
    Future<ModelProbeResult> Function(String, {String? bearer})? probe,
    Future<void> Function()? onCheckDecision,
    VoidCallback? onShowLog,
    VoidCallback? onSetUpAgain,
    bool wireRoles = true,
    bool settle = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsModelsPage(
            decisionPlacement: decision,
            generativePlacement: generative,
            generativeManagedId: managedId,
            inboxTier: inboxTier,
            processingOn: processingOn,
            serverState: serverState,
            decisionUrl: _decisionUrl,
            decisionModel: 'bond-decide-fixture',
            decisionKeyStored: decisionKeyStored,
            generativeUrl: generativeUrl,
            generativeModel: 'qwen3.8-27b',
            generativeKeyStored: generativeKeyStored,
            statuses: statuses,
            parked: parked,
            decideInstallDir: decideInstallDir,
            probe: probe ??
                (url, {bearer}) async => const ModelProbeResult(
                      reachable: true,
                      modelIds: ['listed-model'],
                    ),
            onUseDecision: wireRoles ? recorder('decision') : null,
            onUseGenerative: wireRoles ? recorder('generative') : null,
            onCheckDecision: onCheckDecision ?? () async => checks++,
            onShowLog: onShowLog,
            onSetUpAgain: onSetUpAgain,
          ),
        ),
      ),
    ));
    // An indeterminate bar animates forever, so a settle would never land.
    settle ? await tester.pumpAndSettle() : await tester.pump();
  }

  String textOf(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).data!;

  Future<void> tapSegment(WidgetTester tester, Key control, String label) async {
    final target =
        find.descendant(of: find.byKey(control), matching: find.text(label));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  group('the three roles', () {
    testWidgets('are titled in order, and embeddings has no control',
        (tester) async {
      await open(tester);

      final decision = tester.getTopLeft(
        find.text(SettingsModelsPage.decisionTitle),
      );
      final generative = tester.getTopLeft(
        find.text(SettingsModelsPage.generativeTitle),
      );
      final embed = tester.getTopLeft(find.text(SettingsModelsPage.embedTitle));
      expect(decision.dy, lessThan(generative.dy));
      expect(generative.dy, lessThan(embed.dy));
      expect(find.byKey(SettingsModelsPage.decisionModeKey), findsOneWidget);
      expect(find.byKey(SettingsModelsPage.generativeModeKey), findsOneWidget);
      expect(find.byKey(SettingsModelsPage.embedStatusKey), findsOneWidget);
      // Both placement controls say the same two words.
      for (final control in [
        SettingsModelsPage.decisionModeKey,
        SettingsModelsPage.generativeModeKey,
      ]) {
        for (final label in [
          SettingsModelsPage.thisMacLabel,
          SettingsModelsPage.yourServerLabel,
        ]) {
          expect(
            find.descendant(of: find.byKey(control), matching: find.text(label)),
            findsOneWidget,
          );
        }
      }
    });

    testWidgets('a host that cannot write draws no role controls',
        (tester) async {
      await open(tester, wireRoles: false);

      expect(find.byKey(SettingsModelsPage.decisionModeKey), findsNothing);
      expect(find.byKey(SettingsModelsPage.generativeModeKey), findsNothing);
      expect(find.byKey(SettingsModelsPage.embedStatusKey), findsOneWidget);
    });
  });

  group('the decision model', () {
    testWidgets('on this Mac, not installed, says how to install it',
        (tester) async {
      await open(tester, statuses: [
        _row('decision', onDisk: false, local: true),
      ]);

      expect(
        textOf(tester, SettingsModelsPage.decisionStatusKey),
        SettingsModelsPage.decisionNotInstalledText,
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          'Not installed · run make decide-install');
      expect(find.byKey(ModelServersForm.urlKey(ServerFormRole.decision)),
          findsNothing);
    });

    testWidgets('a moved models folder is named in the command, park or not',
        (tester) async {
      const dir = '/Volumes/Models/bond/local_bond-decide';
      const sentence =
          "Not installed · run make decide-install DECIDE_DIR='$dir'";
      await open(
        tester,
        decideInstallDir: dir,
        statuses: [_row('decision', onDisk: false, local: true)],
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey), sentence);

      await open(
        tester,
        decideInstallDir: dir,
        parked: const ParkedFact(reason: 'decision_not_installed', waiting: 3),
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey), sentence);
    });

    test("a folder with an apostrophe is quoted the shell's way", () {
      expect(
        SettingsModelsPage.decisionNotInstalledIn(
            "/Volumes/Sam's Models/local_bond-decide"),
        'Not installed · run make decide-install '
        "DECIDE_DIR='/Volumes/Sam'\\''s Models/local_bond-decide'",
      );
    });

    testWidgets('installed reads loaded or not from the router',
        (tester) async {
      await open(
        tester,
        statuses: [_row('decision', name: 'Bond decision model', local: true)],
        serverState: const ServerLoading(
          port: 8080,
          pid: 1,
          loaded: {routerDecideId: true, routerEmbedId: false},
        ),
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.installedLoadedText);
      expect(find.text('Bond decision model · 1.0 GB'), findsOneWidget);

      await open(
        tester,
        statuses: [_row('decision', local: true)],
        serverState: const ServerStopped(),
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.installedNotLoadedText);
    });

    testWidgets('Check calls the host, and is off while it runs',
        (tester) async {
      final hold = Completer<void>();
      await open(tester, onCheckDecision: () {
        checks++;
        return hold.future;
      });

      await tester.tap(find.byKey(SettingsModelsPage.checkDecisionKey));
      await tester.pump();
      expect(checks, 1);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(SettingsModelsPage.checkDecisionKey),
            )
            .onPressed,
        isNull,
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.checkingText);

      hold.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(SettingsModelsPage.checkDecisionKey),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('Your server opens the form and writes nothing until Connect',
        (tester) async {
      await open(tester);

      await tapSegment(tester, SettingsModelsPage.decisionModeKey,
          SettingsModelsPage.yourServerLabel);

      expect(writes, isEmpty);
      expect(find.byKey(ModelServersForm.urlKey(ServerFormRole.decision)),
          findsOneWidget);
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.untilConnectText);
      // No Check on somebody's server: the form's Connect is the question.
      expect(find.byKey(SettingsModelsPage.checkDecisionKey), findsNothing);

      final connect = find.byKey(
        ModelServersForm.connectKey(ServerFormRole.decision),
      );
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pumpAndSettle();

      expect(writes.single.role, 'decision');
      expect(writes.single.placement, ModelPlacement.box);
      expect(writes.single.url, _decisionUrl);
      expect(writes.single.model, 'listed-model');
    });

    testWidgets('This Mac from Your server acts at once', (tester) async {
      await open(tester, decision: ModelPlacement.box);

      await tapSegment(tester, SettingsModelsPage.decisionModeKey,
          SettingsModelsPage.thisMacLabel);

      expect(writes.single.role, 'decision');
      expect(writes.single.placement, ModelPlacement.local);
    });

    testWidgets('a vendor is refused with the decision sentence',
        (tester) async {
      await open(tester, decision: ModelPlacement.box);
      await tester.enterText(
        find.byKey(ModelServersForm.urlKey(ServerFormRole.decision)),
        'https://api.openai.com/v1/embeddings',
      );
      final connect = find.byKey(
        ModelServersForm.connectKey(ServerFormRole.decision),
      );
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pumpAndSettle();

      expect(find.text(ModelServersForm.decisionThirdPartyRefusalText),
          findsOneWidget);
      expect(writes, isEmpty);
    });

    testWidgets('Your server says whether a key is needed', (tester) async {
      await open(tester, decision: ModelPlacement.box);
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.keyNeededText);

      await open(tester, decision: ModelPlacement.box, decisionKeyStored: true);
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          'Connected · bond-decide-fixture at box.example.com');
    });
  });

  group('the decision model on your server', () {
    testWidgets('without the heads file on this Mac is not installed, '
        'whatever the server says', (tester) async {
      await open(
        tester,
        decision: ModelPlacement.box,
        decisionKeyStored: true,
        statuses: [
          _row('decision',
              onDisk: false, local: true, inUse: false, headsOnDisk: false),
        ],
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.decisionNotInstalledText);

      // The heads alone are enough: the GGUF is the server's business.
      await open(
        tester,
        decision: ModelPlacement.box,
        decisionKeyStored: true,
        statuses: [
          _row('decision', onDisk: false, local: true, inUse: false),
        ],
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          'Connected · bond-decide-fixture at box.example.com');
    });
  });

  group('a not-installed park that the install has overtaken', () {
    const park = ParkedFact(reason: 'decision_not_installed', waiting: 3);

    testWidgets('says Installed · loading once both files are on disk',
        (tester) async {
      await open(
        tester,
        parked: park,
        statuses: [_row('decision', local: true, inUse: false)],
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.installedLoadingText);
    });

    testWidgets('and Installed · loaded once the router serves it',
        (tester) async {
      await open(
        tester,
        parked: park,
        serverState: const ServerReady(port: 8080, pid: 1),
        statuses: [_row('decision', local: true)],
      );
      expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
          SettingsModelsPage.installedLoadedText);
    });

    testWidgets('keeps the park while either file is still missing',
        (tester) async {
      for (final row in [
        _row('decision', local: true, onDisk: false),
        _row('decision', local: true, headsOnDisk: false),
      ]) {
        await open(tester, parked: park, statuses: [row]);
        expect(textOf(tester, SettingsModelsPage.decisionStatusKey),
            SettingsModelsPage.decisionNotInstalledText);
      }
    });
  });

  group('the generative model', () {
    testWidgets('on this Mac offers the 27B and the 4B, and a pick writes '
        'the managed model', (tester) async {
      await open(tester);

      expect(find.byKey(SettingsModelsPage.generativeManagedKey),
          findsOneWidget);
      await tapSegment(tester, SettingsModelsPage.generativeManagedKey,
          SettingsModelsPage.model4bLabel);

      expect(writes.single.role, 'generative');
      expect(writes.single.placement, ModelPlacement.local);
      expect(writes.single.managedModel, routerBulkId);
    });

    testWidgets('the inbox tier cannot pick the 27B, and says why',
        (tester) async {
      await open(tester, inboxTier: true, managedId: routerBulkId);

      expect(find.text(SettingsModelsPage.inboxTierCaption), findsOneWidget);
      final segmented = tester.widget<SegmentedButton<String>>(
        find.descendant(
          of: find.byKey(SettingsModelsPage.generativeManagedKey),
          matching: find.byType(SegmentedButton<String>),
        ),
      );
      final prose =
          segmented.segments.firstWhere((s) => s.value == routerProseId);
      expect(prose.enabled, isFalse);

      await tester.tap(find.text(SettingsModelsPage.model27bLabel));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
    });

    testWidgets('a chosen model not on disk says to set up again',
        (tester) async {
      await open(
        tester,
        managedId: routerBulkId,
        statuses: [_row('generative', onDisk: false, routerId: routerBulkId)],
        onSetUpAgain: () {},
      );

      expect(textOf(tester, SettingsModelsPage.generativeStatusKey),
          'Not downloaded · Set up again to download it');
      expect(find.byKey(SettingsModelsPage.setUpAgainKey), findsOneWidget);
    });

    testWidgets('a row about the other model is not read as the chosen one',
        (tester) async {
      await open(
        tester,
        managedId: routerBulkId,
        statuses: [_row('generative', routerId: routerProseId)],
      );

      expect(textOf(tester, SettingsModelsPage.generativeStatusKey),
          'Qwen3 4B on this Mac');
    });

    testWidgets('on disk reads loaded from the router', (tester) async {
      await open(
        tester,
        statuses: [_row('generative', name: 'Qwen3.8 27B')],
        serverState: const ServerReady(port: 8080, pid: 1),
      );

      expect(textOf(tester, SettingsModelsPage.generativeStatusKey),
          SettingsModelsPage.onDiskLoadedText);
    });

    testWidgets('Your server connects through the generative form',
        (tester) async {
      await open(tester);
      await tapSegment(tester, SettingsModelsPage.generativeModeKey,
          SettingsModelsPage.yourServerLabel);
      expect(writes, isEmpty);
      expect(find.byKey(SettingsModelsPage.generativeManagedKey), findsNothing);

      final connect = find.byKey(
        ModelServersForm.connectKey(ServerFormRole.generative),
      );
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pumpAndSettle();

      expect(writes.single.role, 'generative');
      expect(writes.single.placement, ModelPlacement.box);
      expect(writes.single.url, _generativeUrl);
      expect(writes.single.model, 'listed-model');
    });

    testWidgets('a cloud service is pointed at Cloud drafts', (tester) async {
      await open(tester, generative: ModelPlacement.box);
      await tester.enterText(
        find.byKey(ModelServersForm.urlKey(ServerFormRole.generative)),
        'https://api.openai.com/v1/chat/completions',
      );
      final connect = find.byKey(
        ModelServersForm.connectKey(ServerFormRole.generative),
      );
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pumpAndSettle();

      expect(find.text(ModelServersForm.generativeThirdPartyRefusalText),
          findsOneWidget);
      expect(writes, isEmpty);
    });

    testWidgets('This Mac from Your server acts at once', (tester) async {
      await open(tester, generative: ModelPlacement.box);

      await tapSegment(tester, SettingsModelsPage.generativeModeKey,
          SettingsModelsPage.thisMacLabel);

      expect(writes.single.role, 'generative');
      expect(writes.single.placement, ModelPlacement.local);
    });

    testWidgets('a server on this machine is asked for no key',
        (tester) async {
      await open(
        tester,
        generative: ModelPlacement.box,
        generativeUrl: 'http://localhost:8080/v1/chat/completions',
      );

      expect(textOf(tester, SettingsModelsPage.generativeStatusKey),
          'Connected · qwen3.8-27b at localhost:8080');
    });

    testWidgets('the weights left behind are listed as on disk, not loaded',
        (tester) async {
      await open(
        tester,
        generative: ModelPlacement.box,
        generativeKeyStored: true,
        statuses: [_row('generative', name: 'Qwen3.8 27B', inUse: false)],
      );

      expect(textOf(tester, SettingsModelsPage.idleGenerativeKey),
          'Qwen3.8 27B · 1.0 GB · on disk · not loaded');
    });
  });

  group('the parks, each under its own role', () {
    const parkedAt = {
      'decision_unavailable': SettingsModelsPage.decisionStatusKey,
      'embed_unavailable': SettingsModelsPage.embedStatusKey,
      'model_unavailable': SettingsModelsPage.generativeStatusKey,
      'unauthorized': SettingsModelsPage.generativeStatusKey,
      // The managed generative model, said on this Mac's server line.
      'not_installed': SettingsModelsPage.statusKey,
      'decision_not_installed': SettingsModelsPage.decisionStatusKey,
      'decision_misconfigured': SettingsModelsPage.decisionStatusKey,
      'decision_unauthorized': SettingsModelsPage.decisionStatusKey,
    };
    const sentence = {
      'decision_unavailable': SettingsModelsPage.decisionUnavailableText,
      'embed_unavailable': SettingsModelsPage.embedUnavailableText,
      'model_unavailable': SettingsModelsPage.serverParkedText,
      'unauthorized': SettingsModelsPage.serverUnauthorizedText,
      'not_installed': SettingsModelsPage.notInstalledText,
      'decision_not_installed': SettingsModelsPage.decisionNotInstalledText,
      'decision_misconfigured': SettingsModelsPage.decisionMisconfiguredText,
      'decision_unauthorized': SettingsModelsPage.decisionUnauthorizedText,
    };

    for (final reason in parkedAt.keys) {
      testWidgets('$reason is said under its role', (tester) async {
        await open(
          tester,
          generative: ModelPlacement.box,
          generativeKeyStored: true,
          parked: ParkedFact(reason: reason, waiting: 3),
        );

        expect(textOf(tester, parkedAt[reason]!), sentence[reason]);
        // And under no other role.
        for (final other in parkedAt.values.toSet()..remove(parkedAt[reason])) {
          expect(textOf(tester, other), isNot(sentence[reason]));
        }
      });
    }

    testWidgets('on this Mac the generative model leaves a server park to the '
        'server line', (tester) async {
      await open(
        tester,
        parked: const ParkedFact(reason: 'model_unavailable', waiting: 3),
      );

      expect(find.text(SettingsModelsPage.serverParkedText), findsNothing);
    });

    testWidgets('nothing waiting, nothing said', (tester) async {
      await open(
        tester,
        parked: const ParkedFact(reason: 'decision_unavailable'),
      );

      expect(find.text(SettingsModelsPage.decisionUnavailableText),
          findsNothing);
    });

    testWidgets('the switch being off outranks every park', (tester) async {
      await open(
        tester,
        processingOn: false,
        parked: const ParkedFact(reason: 'embed_unavailable', waiting: 2),
      );

      expect(textOf(tester, SettingsModelsPage.statusKey),
          SettingsModelsPage.processingOffText);
      expect(find.text(SettingsModelsPage.embedUnavailableText), findsNothing);
    });
  });

  group('the server line, the bar and the log', () {
    testWidgets('say what the app’s own server is doing', (tester) async {
      await open(tester, serverState: const ServerReady(port: 8080, pid: 1));
      expect(textOf(tester, SettingsModelsPage.statusKey),
          SettingsModelsPage.runningText);
      expect(find.byKey(SettingsModelsPage.progressKey), findsNothing);
    });

    testWidgets('a starting server gets an indeterminate bar', (tester) async {
      await open(
        tester,
        serverState: const ServerStarting(port: 8080),
        settle: false,
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(SettingsModelsPage.progressKey),
      );
      expect(bar.value, isNull);
    });

    testWidgets('a loading server gets the fraction the router reports',
        (tester) async {
      await open(
        tester,
        serverState: const ServerLoading(
          port: 8080,
          pid: 1,
          loaded: {routerDecideId: true, routerEmbedId: false},
        ),
      );
      expect(textOf(tester, SettingsModelsPage.statusKey),
          SettingsModelsPage.loadingText(1, 2));
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(SettingsModelsPage.progressKey),
      );
      expect(bar.value, 0.5);
    });

    testWidgets('Show log is offered under a failure and nowhere else',
        (tester) async {
      var shown = 0;
      await open(
        tester,
        serverState: const ServerFailed('exited'),
        onShowLog: () => shown++,
      );
      await tester.tap(find.byKey(SettingsModelsPage.showLogKey));
      expect(shown, 1);

      await open(tester, onShowLog: () => shown++);
      expect(find.byKey(SettingsModelsPage.showLogKey), findsNothing);
    });
  });

  group('embeddings', () {
    testWidgets('are a status line about this Mac', (tester) async {
      await open(
        tester,
        statuses: [_row('embed', name: 'Qwen3 Embedding 0.6B')],
        serverState: const ServerReady(port: 8080, pid: 1),
      );

      expect(textOf(tester, SettingsModelsPage.embedStatusKey),
          SettingsModelsPage.onDiskLoadedText);
      expect(find.text('Qwen3 Embedding 0.6B · 1.0 GB'), findsOneWidget);
    });
  });

  group('the collapsed summary', () {
    test('names where each role runs, then the server', () {
      expect(
        SettingsModelsPage.summary(
          decisionPlacement: ModelPlacement.local,
          generativePlacement: ModelPlacement.local,
          generativeUrl: _generativeUrl,
          serverLine: 'Running',
        ),
        'Decision on this Mac · Generative on this Mac · Running',
      );
      expect(
        SettingsModelsPage.summary(
          decisionPlacement: ModelPlacement.box,
          generativePlacement: ModelPlacement.box,
          generativeUrl: _generativeUrl,
          serverLine: 'Running',
        ),
        'Decision on your server · Generative at box.example.com · Running',
      );
      expect(
        SettingsModelsPage.summary(
          decisionPlacement: ModelPlacement.local,
          generativePlacement: ModelPlacement.box,
          generativeUrl: '',
          serverLine: 'Not running',
        ),
        'Decision on this Mac · Generative on your server · Not running',
      );
    });
  });

  testWidgets('no user-facing sentence carries an em-dash', (tester) async {
    for (final text in [
      SettingsModelsPage.decisionCaption,
      SettingsModelsPage.generativeCaption,
      SettingsModelsPage.embedCaption,
      SettingsModelsPage.managedCaption,
      SettingsModelsPage.inboxTierCaption,
      SettingsModelsPage.decisionNotInstalledText,
      SettingsModelsPage.decisionNotInstalledIn('/Volumes/Models/x'),
      SettingsModelsPage.decisionMisconfiguredText,
      SettingsModelsPage.installedLoadingText,
      SettingsModelsPage.notInstalledText,
      SettingsModelsPage.notDownloadedText,
      notDecisionModelText('http://127.0.0.1:8081'),
      noTokenizeText('http://127.0.0.1:8081'),
      ModelServersForm.generativeThirdPartyRefusalText,
      ModelServersForm.decisionThirdPartyRefusalText,
      ModelServersForm.otherHostHint,
    ]) {
      expect(text, isNot(contains('—')), reason: text);
    }
  });

  testWidgets('the whole page survives a doubled text scale', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SettingsModelsPage(
              decisionPlacement: ModelPlacement.box,
              generativePlacement: ModelPlacement.local,
              statuses: [_row('decision'), _row('generative'), _row('embed')],
              onUseDecision: recorder('decision'),
              onUseGenerative: recorder('generative'),
              onCheckDecision: () async {},
              onSetUpAgain: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
