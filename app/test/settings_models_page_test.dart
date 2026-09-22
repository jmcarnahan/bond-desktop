import 'dart:async';

import 'package:bond_inbox/providers/app_providers.dart' show ParkedFact;
import 'package:bond_inbox/providers/prefs_provider.dart' show AppPrefs;
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/models/managed_model_status.dart';
import 'package:bond_inbox/services/server/server_state.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:bond_inbox/widgets/settings_models_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Models page: one question, two modes, one status line and three rows.
///
/// Prop-only, so this file pumps it alone with no screen and no host around
/// it — which is what makes `pumpAndSettle` safe here. What the HOST resolves
/// into those props is `settings_models_host_test.dart`'s job; what the form
/// does with an address is `model_servers_form_test.dart`'s.
///
/// The access key in these fixtures is `sk-fixture-…`, and the Check case
/// asserts that no rendered `Text` carries it.

const _bigUrl = 'https://box.example.com/prose/v1/chat/completions';
const _smallUrl = 'https://box.example.com/bulk/v1/chat/completions';

const _boxProse = LlmTargetSpec(
  id: boxProseId,
  name: boxProseName,
  url: _bigUrl,
  model: boxProseModel,
  hasBearer: true,
  parallel: 4,
);

const _boxBulk = LlmTargetSpec(
  id: boxBulkId,
  name: boxBulkName,
  url: _smallUrl,
  model: boxBulkModel,
  hasBearer: true,
  parallel: 4,
);

const _localProse = LlmTargetSpec(
  id: builtInProseId,
  name: builtInProseName,
  url: 'http://localhost:8080/v1/chat/completions',
  model: 'qwen3.8',
);

const _localFast = LlmTargetSpec(
  id: builtInFastId,
  name: builtInFastName,
  url: 'http://localhost:8082/v1/chat/completions',
  model: 'qwen3-4b',
);

/// The three rows a Managed install reports, built the way the host builds
/// them.
List<RoleLine> _localLines() => [
      RoleLine(
        id: 'big',
        title: 'Big model',
        detail: SettingsModelsPage.roleDetail(
          role: StageRole.big,
          spec: _localProse,
        ),
        checkUrl: _localProse.url,
      ),
      RoleLine(
        id: 'small',
        title: 'Small model',
        detail: SettingsModelsPage.roleDetail(
          role: StageRole.small,
          spec: _localFast,
        ),
        checkUrl: _localFast.url,
      ),
      RoleLine(
        id: 'embed',
        title: 'Embeddings',
        detail: SettingsModelsPage.roleDetail(
          role: StageRole.embed,
          spec: null,
        ),
        checkUrl: 'http://localhost:8081/v1/embeddings',
      ),
    ];

/// And the three a user-defined install reports, both chat rows carrying a
/// stored key.
List<RoleLine> _boxLines() => [
      RoleLine(
        id: 'big',
        title: 'Big model',
        detail: SettingsModelsPage.roleDetail(
          role: StageRole.big,
          spec: _boxProse,
        ),
        checkUrl: _boxProse.url,
        bearerId: _boxProse.id,
      ),
      RoleLine(
        id: 'small',
        title: 'Small model',
        detail: SettingsModelsPage.roleDetail(
          role: StageRole.small,
          spec: _boxBulk,
        ),
        checkUrl: _boxBulk.url,
        bearerId: _boxBulk.id,
      ),
      RoleLine(
        id: 'embed',
        title: 'Embeddings',
        detail: SettingsModelsPage.roleDetail(
          role: StageRole.embed,
          spec: null,
        ),
        checkUrl: 'http://localhost:8081/v1/embeddings',
      ),
    ];

ManagedModelStatus _status(
  String roleId,
  String name, {
  required String routerId,
  int bytes = 20 * 1024 * 1024 * 1024,
  bool onDisk = true,
}) =>
    ManagedModelStatus(
      roleId: roleId,
      displayName: name,
      bytes: bytes,
      onDisk: onDisk,
      routerId: routerId,
    );

void main() {
  Future<void> open(
    WidgetTester tester, {
    ModelPlacement placement = ModelPlacement.local,
    bool processingOn = true,
    ServerState serverState = const ServerStopped(),
    String boxBigUrl = _bigUrl,
    String boxSmallUrl = _smallUrl,
    bool boxKeyStored = false,
    bool? boxBigKeyStored,
    bool? boxSmallKeyStored,
    Future<ModelProbeResult> Function(String, {String? bearer})? probe,
    String? Function(String)? storedBearer,
    Future<void> Function()? onUseManaged,
    VoidCallback? onSetUpAgain,
    VoidCallback? onShowLog,
    bool wireForm = true,
    List<RoleLine> roleLines = const [],
    ParkedFact? parked,
    // An indeterminate bar never stops animating, so the two cases that put
    // one up pump by hand rather than waiting for a tree that will not settle.
    bool settle = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsModelsPage(
            modelPlacement: placement,
            processingOn: processingOn,
            serverState: serverState,
            boxBigUrl: boxBigUrl,
            boxSmallUrl: boxSmallUrl,
            boxKeyStored: boxKeyStored,
            boxBigKeyStored: boxBigKeyStored ?? boxKeyStored,
            boxSmallKeyStored: boxSmallKeyStored ?? boxKeyStored,
            probe: probe,
            storedBearer: storedBearer,
            onUseBox: !wireForm
                ? null
                : ({
                    required bigUrl,
                    required smallUrl,
                    required bigModel,
                    required smallModel,
                    bigKey,
                    smallKey,
                  }) async {},
            onUseManaged: onUseManaged,
            onSetUpAgain: onSetUpAgain,
            onShowLog: onShowLog,
            roleLines: roleLines,
            parked: parked,
          ),
        ),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> press(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Finder segment(String label) => find.descendant(
        of: find.byType(SegmentedButton<ModelPlacement>),
        matching: find.text(label),
      );

  String status(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(SettingsModelsPage.statusKey)).data!;

  List<String> rendered(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? '',
      ];

  group('the two modes', () {
    testWidgets('the question, both modes and the caption are up',
        (tester) async {
      await open(tester);

      expect(find.text(SettingsModelsPage.whereHeading), findsOneWidget);
      expect(segment(SettingsModelsPage.managedLabel), findsOneWidget);
      expect(segment(SettingsModelsPage.userDefinedLabel), findsOneWidget);
      expect(find.text(SettingsModelsPage.modeCaption), findsOneWidget);
    });

    testWidgets('Managed is a status block with no form on it', (tester) async {
      await open(tester);

      expect(find.byKey(ModelServersForm.bigUrlKey), findsNothing);
      expect(find.byKey(ModelServersForm.connectKey), findsNothing);
    });

    testWidgets('choosing Managed from a user-defined install acts at once',
        (tester) async {
      var managed = 0;
      await open(
        tester,
        placement: ModelPlacement.box,
        boxKeyStored: true,
        onUseManaged: () async => managed++,
      );

      await press(tester, segment(SettingsModelsPage.managedLabel));

      expect(managed, 1);
    });

    testWidgets('choosing User defined opens the form and writes nothing',
        (tester) async {
      var managed = 0;
      await open(tester, onUseManaged: () async => managed++);

      await press(tester, segment(SettingsModelsPage.userDefinedLabel));

      expect(find.byKey(ModelServersForm.bigUrlKey), findsOneWidget);
      expect(find.byKey(ModelServersForm.smallUrlKey), findsOneWidget);
      expect(status(tester), SettingsModelsPage.untilConnectText);
      expect(managed, 0);

      // And back again: the form closes and nothing was written either way.
      await press(tester, segment(SettingsModelsPage.managedLabel));
      expect(find.byKey(ModelServersForm.bigUrlKey), findsNothing);
      expect(managed, 0);
    });

    testWidgets('a user-defined install opens on the form, prefilled',
        (tester) async {
      await open(tester, placement: ModelPlacement.box, boxKeyStored: true);

      expect(
        tester
            .widget<TextField>(find.byKey(ModelServersForm.bigUrlKey))
            .controller!
            .text,
        _bigUrl,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(ModelServersForm.smallUrlKey))
            .controller!
            .text,
        _smallUrl,
      );
    });
  });

  group('the status line', () {
    testWidgets('the switch being off is said before anything else',
        (tester) async {
      // The last parked fact outlives the drains it came from, and a park
      // sentence promises a retry nothing is going to make.
      await open(
        tester,
        placement: ModelPlacement.box,
        boxKeyStored: true,
        processingOn: false,
        parked: const ParkedFact(reason: 'model_unavailable', waiting: 3),
      );

      expect(status(tester), SettingsModelsPage.processingOffText);
    });

    testWidgets('a user-defined install says whether it has a key',
        (tester) async {
      await open(tester, placement: ModelPlacement.box);
      expect(status(tester), SettingsModelsPage.keyNeededText);

      await open(tester, placement: ModelPlacement.box, boxKeyStored: true);
      expect(status(tester), SettingsModelsPage.connectedText);
    });

    testWidgets('a key stored for one server does not answer for the other',
        (tester) async {
      // `boxKeyStored` is "either", and two different hosts are two
      // operators: a line reading Connected with the big server unkeyed
      // would be describing an install that cannot draft.
      await open(
        tester,
        placement: ModelPlacement.box,
        boxSmallUrl: 'https://box2.example.com/bulk/v1/chat/completions',
        boxKeyStored: true,
        boxBigKeyStored: false,
        boxSmallKeyStored: true,
      );
      expect(status(tester), SettingsModelsPage.keyNeededText);

      await open(
        tester,
        placement: ModelPlacement.box,
        boxSmallUrl: 'https://box2.example.com/bulk/v1/chat/completions',
        boxKeyStored: true,
        boxBigKeyStored: true,
        boxSmallKeyStored: false,
      );
      expect(status(tester), SettingsModelsPage.keyNeededText);

      await open(
        tester,
        placement: ModelPlacement.box,
        boxSmallUrl: 'https://box2.example.com/bulk/v1/chat/completions',
        boxKeyStored: true,
        boxBigKeyStored: true,
        boxSmallKeyStored: true,
      );
      expect(status(tester), SettingsModelsPage.connectedText);
    });

    testWidgets('a server on this machine is asked for no key, whichever side '
        'it is on', (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxBigUrl: 'http://localhost:8080/v1/chat/completions',
        boxSmallUrl: 'http://127.0.0.1:8082/v1/chat/completions',
      );
      expect(status(tester), SettingsModelsPage.connectedText);

      // One of each: the remote side still wants its own key.
      await open(
        tester,
        placement: ModelPlacement.box,
        boxBigUrl: 'http://localhost:8080/v1/chat/completions',
        boxSmallUrl: _smallUrl,
      );
      expect(status(tester), SettingsModelsPage.keyNeededText);
    });

    testWidgets('all three parks are answered under User defined',
        (tester) async {
      for (final (reason, sentence) in [
        ('model_unavailable', SettingsModelsPage.serverParkedText),
        ('unauthorized', SettingsModelsPage.serverUnauthorizedText),
        ('embed_unavailable', SettingsModelsPage.embedUnavailableText),
      ]) {
        await open(
          tester,
          placement: ModelPlacement.box,
          boxKeyStored: true,
          parked: ParkedFact(reason: reason, waiting: 3),
        );
        expect(status(tester), sentence, reason: reason);
      }
    });

    testWidgets('under Managed only the embedding park is this page’s to '
        'answer', (tester) async {
      // The other two are about a server whose own line is right here, and
      // the rail already says `Model server unreachable`.
      await open(
        tester,
        serverState: const ServerReady(port: 8080, pid: 42),
        parked: const ParkedFact(reason: 'model_unavailable', waiting: 3),
      );
      expect(status(tester), SettingsModelsPage.runningText);

      await open(
        tester,
        serverState: const ServerReady(port: 8080, pid: 42),
        parked: const ParkedFact(reason: 'embed_unavailable', waiting: 3),
      );
      expect(status(tester), SettingsModelsPage.embedUnavailableText);
    });

    testWidgets('a park word this page cannot answer for is left alone',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxKeyStored: true,
        parked: const ParkedFact(reason: 'session', waiting: 3),
      );

      expect(status(tester), SettingsModelsPage.connectedText);
    });

    testWidgets('Managed says what the app’s own server is doing',
        (tester) async {
      for (final (state, sentence) in <(ServerState, String)>[
        (const ServerStopped(), SettingsModelsPage.notRunningText),
        (const ServerStarting(port: 8080), SettingsModelsPage.startingText),
        (
          const ServerLoading(port: 8080, pid: 42, loaded: {
            'bond-prose': false,
            'bond-bulk': true,
            'bond-embed': false,
          }),
          'Loading models · 1 of 3',
        ),
        (const ServerReady(port: 8080, pid: 42), SettingsModelsPage.runningText),
        (
          const ServerFailed('exited (code 1)'),
          'Not running: exited (code 1)',
        ),
        (const ServerPortInUse(8080), 'Port 8080 is in use'),
        (
          const ServerPortInUse(8080, holder: 'llama-server'),
          'Port 8080 is in use by llama-server',
        ),
        (const ServerDisabled(), SettingsModelsPage.handServersText),
      ]) {
        await open(tester, serverState: state, settle: false);
        expect(status(tester), sentence, reason: '$state');
      }
    });
  });

  group('the loading bar and the log', () {
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
        serverState: const ServerLoading(port: 8080, pid: 42, loaded: {
          'bond-prose': false,
          'bond-bulk': true,
          'bond-embed': false,
        }),
      );

      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(SettingsModelsPage.progressKey),
      );
      expect(bar.value, closeTo(1 / 3, 0.001));
    });

    testWidgets('a running server has no bar at all', (tester) async {
      await open(tester, serverState: const ServerReady(port: 8080, pid: 42));

      expect(find.byKey(SettingsModelsPage.progressKey), findsNothing);
    });

    testWidgets('Show log is offered under a failure and nowhere else',
        (tester) async {
      var shown = 0;
      await open(
        tester,
        serverState: const ServerReady(port: 8080, pid: 42),
        onShowLog: () => shown++,
      );
      expect(find.byKey(SettingsModelsPage.showLogKey), findsNothing);

      await open(
        tester,
        serverState: const ServerFailed('exited (code 1)'),
        onShowLog: () => shown++,
      );
      await press(tester, find.byKey(SettingsModelsPage.showLogKey));
      expect(shown, 1);

      // And a host that cannot open one offers nothing rather than a dead
      // button.
      await open(tester, serverState: const ServerFailed('exited (code 1)'));
      expect(find.byKey(SettingsModelsPage.showLogKey), findsNothing);
    });
  });

  group('the three role rows', () {
    testWidgets('a Managed install names each model, its size and its state',
        (tester) async {
      await open(
        tester,
        serverState: const ServerReady(port: 8080, pid: 42),
        roleLines: RoleLine.withStatus(
          _localLines(),
          statuses: [
            _status('big', 'Qwen3.8 27B', routerId: routerProseId),
            _status('small', 'Qwen3 4B Instruct', routerId: routerBulkId),
            _status(
              'embed',
              'Qwen3 Embedding 0.6B',
              routerId: routerEmbedId,
              bytes: 1234567890,
              onDisk: false,
            ),
          ],
          serverState: const ServerReady(port: 8080, pid: 42),
          placement: ModelPlacement.local,
        ),
      );

      expect(find.text('Big model'), findsOneWidget);
      expect(
        find.text('Qwen3.8 27B on this Mac · 20.0 GB · on disk · loaded'),
        findsOneWidget,
      );
      expect(
        find.text('Qwen3 4B Instruct on this Mac · 20.0 GB · on disk · loaded'),
        findsOneWidget,
      );
      expect(
        find.text('Qwen3 Embedding 0.6B on this Mac · 1.1 GB · not downloaded'),
        findsOneWidget,
      );
    });

    testWidgets('a user-defined install names the model and the host',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxKeyStored: true,
        roleLines: RoleLine.withStatus(
          _boxLines(),
          statuses: [
            _status(
              'embed',
              'Qwen3 Embedding 0.6B',
              routerId: routerEmbedId,
              bytes: 1234567890,
            ),
          ],
          serverState: const ServerReady(port: 8080, pid: 42),
          placement: ModelPlacement.box,
        ),
      );

      expect(find.text('qwen3.8 at box.example.com'), findsOneWidget);
      expect(find.text('qwen3-4b at box.example.com'), findsOneWidget);
      expect(
        find.text(
          'Qwen3 Embedding 0.6B on this Mac · 1.1 GB · on disk · loaded',
        ),
        findsOneWidget,
      );
    });

    testWidgets('each Check asks that role’s own URL with its stored key',
        (tester) async {
      final asked = <(String, String?)>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxKeyStored: true,
        roleLines: _boxLines(),
        storedBearer: (id) => 'sk-fixture-stored-$id',
        probe: (url, {bearer}) async {
          asked.add((url, bearer));
          return const ModelProbeResult(reachable: true, modelIds: ['a']);
        },
      );

      await press(tester, find.byKey(SettingsModelsPage.roleCheckKey('small')));

      expect(asked, [(_smallUrl, 'sk-fixture-stored-$boxBulkId')]);
      expect(find.text('Reachable · 1 model'), findsOneWidget);
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('a row that moves to another server drops its old answer',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxKeyStored: true,
        storedBearer: (_) => 'sk-fixture-stored',
        probe: (url, {bearer}) async =>
            const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
        roleLines: _boxLines(),
      );
      await press(tester, find.byKey(SettingsModelsPage.roleCheckKey('big')));
      expect(find.textContaining('Reachable'), findsOneWidget);

      await open(tester, roleLines: _localLines());

      expect(find.textContaining('Reachable'), findsNothing);
    });

    testWidgets('a Check that outlives its row renders nothing under the new '
        'one', (tester) async {
      final hold = Completer<ModelProbeResult>();
      await open(
        tester,
        placement: ModelPlacement.box,
        boxKeyStored: true,
        storedBearer: (_) => 'sk-fixture-stored',
        probe: (url, {bearer}) => hold.future,
        roleLines: _boxLines(),
      );

      await tester.tap(find.byKey(SettingsModelsPage.roleCheckKey('big')));
      await tester.pump();
      expect(find.text('Checking…'), findsOneWidget);

      // The host moved the install to this Mac while the answer was out.
      await open(tester, roleLines: _localLines());
      expect(find.text('Checking…'), findsNothing);

      hold.complete(
        const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
      );
      await tester.pumpAndSettle();

      // The server that answered is not the server the row now asks.
      expect(find.textContaining('Reachable'), findsNothing);
    });

    testWidgets('a host that cannot ask offers no Check anywhere',
        (tester) async {
      await open(tester, roleLines: _localLines());

      for (final id in ['big', 'small', 'embed']) {
        expect(
          find.byKey(SettingsModelsPage.roleCheckKey(id)),
          findsNothing,
          reason: '$id still offers a check with no probe wired',
        );
      }
    });
  });

  group('the rows the host joins', () {
    RoleLine row(List<RoleLine> rows, String id) =>
        rows.singleWhere((r) => r.id == id);

    test('a file that has not landed says so, and quotes what it will cost',
        () {
      final rows = RoleLine.withStatus(
        _localLines(),
        statuses: [
          _status(
            'big',
            'Qwen3.8 27B',
            routerId: routerProseId,
            onDisk: false,
          ),
        ],
        serverState: const ServerReady(port: 8080, pid: 42),
        placement: ModelPlacement.local,
      );

      expect(row(rows, 'big').detail, 'Qwen3.8 27B on this Mac');
      expect(row(rows, 'big').size, '20.0 GB');
      expect(row(rows, 'big').state, 'not downloaded');
      // The rows the statuses say nothing about keep what the prefs said.
      expect(row(rows, 'small').size, isNull);
      expect(row(rows, 'small').detail, 'Qwen3 4B on this Mac');
    });

    test('on disk is not loaded until the router says so', () {
      List<RoleLine> join(ServerState state) => RoleLine.withStatus(
            _localLines(),
            statuses: [_status('big', 'Qwen3.8 27B', routerId: routerProseId)],
            serverState: state,
            placement: ModelPlacement.local,
          );

      expect(row(join(const ServerStopped()), 'big').state, 'on disk');
      expect(
        row(join(const ServerReady(port: 8080, pid: 42)), 'big').state,
        'on disk · loaded',
      );
      // Keyed by ROUTER id, which on a small Mac is the bulk file's even for
      // the big row.
      expect(
        row(
          join(const ServerLoading(port: 8080, pid: 42, loaded: {
            routerProseId: true,
            routerBulkId: false,
          })),
          'big',
        ).state,
        'on disk · loaded',
      );
      expect(
        row(
          join(const ServerLoading(port: 8080, pid: 42, loaded: {
            routerProseId: false,
          })),
          'big',
        ).state,
        'on disk',
      );
    });

    test('a host still reading changes nothing at all', () {
      final lines = _localLines();
      final rows = RoleLine.withStatus(
        lines,
        statuses: null,
        serverState: const ServerReady(port: 8080, pid: 42),
        placement: ModelPlacement.local,
      );

      expect(rows, same(lines));
    });

    test('under User defined only the embedding row is dressed', () {
      final rows = RoleLine.withStatus(
        _boxLines(),
        statuses: [
          // A big row resolved a frame before the mode moved. It names a
          // machine this app cannot see, and the placement is what says so.
          _status('big', 'Qwen3.8 27B', routerId: routerProseId),
          _status(
            'embed',
            'Qwen3 Embedding 0.6B',
            routerId: routerEmbedId,
            bytes: 1234567890,
          ),
        ],
        serverState: const ServerReady(port: 8080, pid: 42),
        placement: ModelPlacement.box,
      );

      expect(row(rows, 'big').size, isNull);
      expect(row(rows, 'big').state, isNull);
      expect(row(rows, 'big').detail, 'qwen3.8 at box.example.com');
      expect(row(rows, 'embed').size, '1.1 GB');
      expect(row(rows, 'embed').state, 'on disk · loaded');
    });

    test('a role whose steps disagree names the count and nothing else', () {
      // The screen that could have shown which ones went with the fold.
      expect(
        SettingsModelsPage.roleDetail(
          role: StageRole.big,
          spec: _localProse,
          overrides: 1,
        ),
        'Custom · 1 step points elsewhere',
      );
      expect(
        SettingsModelsPage.roleDetail(
          role: StageRole.small,
          spec: _localFast,
          overrides: 3,
        ),
        'Custom · 3 steps point elsewhere',
      );
    });

    test('a fresh install on this Mac reads the two built-ins and embeddings',
        () {
      const prefs = AppPrefs();
      final rows = RoleLine.fromPrefs(prefs);

      expect([for (final r in rows) r.id], ['big', 'small', 'embed']);
      expect(row(rows, 'big').detail, 'Qwen3.8 27B on this Mac');
      expect(row(rows, 'small').detail, 'Qwen3 4B on this Mac');
      expect(row(rows, 'embed').detail, 'Qwen3 Embedding 0.6B on this Mac');
    });

    test('a user-defined install reads the two servers it was given', () {
      const prefs = AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxBigUrl: _bigUrl,
        boxSmallUrl: _smallUrl,
        boxKeyStored: true,
      );
      final rows = RoleLine.fromPrefs(prefs);

      expect(row(rows, 'big').detail, 'qwen3.8 at box.example.com');
      expect(row(rows, 'big').bearerId, boxProseId);
      expect(row(rows, 'small').detail, 'qwen3-4b at box.example.com');
      expect(row(rows, 'small').bearerId, boxBulkId);
    });
  });

  group('the way out', () {
    testWidgets('Set up again is offered when the host wires it',
        (tester) async {
      var again = 0;
      await open(tester);
      expect(find.byKey(SettingsModelsPage.setUpAgainKey), findsNothing);

      await open(tester, onSetUpAgain: () => again++);
      await press(tester, find.byKey(SettingsModelsPage.setUpAgainKey));

      expect(again, 1);
    });
  });

  group('the collapsed summary', () {
    test('Managed carries the server’s own state', () {
      expect(
        SettingsModelsPage.summary(
          placement: ModelPlacement.local,
          serverLine: SettingsModelsPage.runningText,
          bigUrl: _bigUrl,
          smallUrl: _smallUrl,
        ),
        'Managed · Running',
      );
    });

    test('User defined names the hosts, and one when they are the same', () {
      expect(
        SettingsModelsPage.summary(
          placement: ModelPlacement.box,
          serverLine: SettingsModelsPage.runningText,
          bigUrl: _bigUrl,
          smallUrl: _smallUrl,
        ),
        'User defined · box.example.com',
      );
      expect(
        SettingsModelsPage.summary(
          placement: ModelPlacement.box,
          serverLine: SettingsModelsPage.runningText,
          bigUrl: _bigUrl,
          smallUrl: 'http://localhost:8082/v1/chat/completions',
        ),
        'User defined · box.example.com · localhost:8082',
      );
    });

    test('a user-defined install with no address says so rather than lying',
        () {
      expect(
        SettingsModelsPage.summary(
          placement: ModelPlacement.box,
          serverLine: SettingsModelsPage.notRunningText,
          bigUrl: '',
          smallUrl: '',
        ),
        'User defined · no address yet',
      );
    });
  });

  testWidgets('the whole page survives a doubled text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(
      tester,
      placement: ModelPlacement.box,
      boxKeyStored: true,
      roleLines: _boxLines(),
      probe: (_, {bearer}) async => const ModelProbeResult(reachable: true),
    );

    expect(tester.takeException(), isNull);
  });
}
