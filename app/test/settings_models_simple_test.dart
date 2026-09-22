import 'dart:async';

import 'package:bond_inbox/providers/app_providers.dart' show ParkedFact;
import 'package:bond_inbox/providers/prefs_provider.dart' show AppPrefs;
import 'package:bond_inbox/screens/setup/setup_controls.dart'
    show setupContinueKey;
import 'package:bond_inbox/screens/setup/setup_where_body.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/settings_models_body.dart';
import 'package:bond_inbox/widgets/settings_models_simple.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The simple Models page: one question, one form, one status line, three
/// answers and one fold.
///
/// Prop-only, so this file pumps it alone with no screen and no host around
/// it — which is what makes `pumpAndSettle` safe here. What the HOST resolves
/// into those props is `settings_models_host_test.dart`'s job; what the fold
/// contains is still `settings_models_test.dart`'s.
///
/// The access key in these fixtures is the string `sk-fixture-…`, and several
/// cases assert that no rendered `Text` carries it. `find.text` reads an
/// `EditableText`'s controller rather than the bullets it draws, so the field
/// itself is the one match allowed anywhere.

const _boxProse = LlmTargetSpec(
  id: boxProseId,
  name: boxProseName,
  url: 'https://box.example.com/prose/v1/chat/completions',
  model: boxProseModel,
  hasBearer: true,
  parallel: 4,
);

const _boxBulk = LlmTargetSpec(
  id: boxBulkId,
  name: boxBulkName,
  url: 'https://box.example.com/bulk/v1/chat/completions',
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
  model: 'qwen3.8',
);

/// The three rows a local install reports, built the way the host builds them.
List<RoleLine> _localLines() => [
      RoleLine(
        id: 'big',
        title: 'Big model',
        detail: SettingsModelsSimple.roleDetail(
          role: StageRole.big,
          spec: _localProse,
        ),
        checkUrl: _localProse.url,
      ),
      RoleLine(
        id: 'small',
        title: 'Small model',
        detail: SettingsModelsSimple.roleDetail(
          role: StageRole.small,
          spec: _localFast,
        ),
        checkUrl: _localFast.url,
      ),
      RoleLine(
        id: 'embed',
        title: 'Embeddings',
        detail: SettingsModelsSimple.roleDetail(
          role: StageRole.embed,
          spec: null,
        ),
        checkUrl: 'http://localhost:8081/v1/embeddings',
      ),
    ];

/// And the three a box install reports, both chat rows carrying a stored key.
List<RoleLine> _boxLines() => [
      RoleLine(
        id: 'big',
        title: 'Big model',
        detail: SettingsModelsSimple.roleDetail(
          role: StageRole.big,
          spec: _boxProse,
        ),
        checkUrl: _boxProse.url,
        bearerId: _boxProse.id,
      ),
      RoleLine(
        id: 'small',
        title: 'Small model',
        detail: SettingsModelsSimple.roleDetail(
          role: StageRole.small,
          spec: _boxBulk,
        ),
        checkUrl: _boxBulk.url,
        bearerId: _boxBulk.id,
      ),
      RoleLine(
        id: 'embed',
        title: 'Embeddings',
        detail: SettingsModelsSimple.roleDetail(
          role: StageRole.embed,
          spec: null,
        ),
        checkUrl: 'http://localhost:8081/v1/embeddings',
      ),
    ];

void main() {
  Future<void> open(
    WidgetTester tester, {
    ModelPlacement placement = ModelPlacement.local,
    String boxUrl = '',
    bool boxKeyStored = false,
    bool processingOn = true,
    Future<ModelProbeResult> Function(String, {String? bearer})? probe,
    String? Function(String)? storedBearer,
    Future<void> Function(String, String?)? onUseBox,
    Future<void> Function()? onUseLocal,
    bool wireBox = true,
    List<RoleLine> roleLines = const [],
    ParkedFact? parked,
    Widget? localServer,
    String? hardwareLine,
    String? embedServerLine,
    Widget? advanced,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var advancedOpen = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setLocalState) => SingleChildScrollView(
            child: SettingsModelsSimple(
              modelPlacement: placement,
              boxUrl: boxUrl,
              boxKeyStored: boxKeyStored,
              processingOn: processingOn,
              probe: probe,
              storedBearer: storedBearer,
              onUseBox: wireBox ? (onUseBox ?? (_, _) async {}) : null,
              onUseLocal: onUseLocal ?? () async {},
              roleLines: roleLines,
              parked: parked,
              localServer: localServer,
              hardwareLine: hardwareLine,
              embedServerLine: embedServerLine,
              advanced: advanced ?? const Text('ADVANCED BODY'),
              advancedOpen: advancedOpen,
              onToggleAdvanced: () =>
                  setLocalState(() => advancedOpen = !advancedOpen),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// The segment button, found inside the control rather than by its words:
  /// `This Mac` is also most of the hardware line under it.
  Finder segment(String label) => find.descendant(
        of: find.byType(SegmentedButton<ModelPlacement>),
        matching: find.text(label),
      );

  String status(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(SettingsModelsSimple.statusKey)).data!;

  /// Every rendered string, for the two assertions about what must never be
  /// on screen.
  List<String> rendered(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          t.data ?? '',
      ];

  group('the one question', () {
    testWidgets('both choices render and the segment opens on the placement',
        (tester) async {
      await open(tester);

      expect(find.text(SettingsModelsSimple.whereHeading), findsOneWidget);
      expect(segment(SettingsModelsSimple.boxSegmentLabel), findsOneWidget);
      expect(segment(SettingsModelsSimple.localSegmentLabel), findsOneWidget);
      expect(find.text(SettingsModelsSimple.segmentsCaption), findsOneWidget);

      final control =
          tester.widget<SegmentedButton<ModelPlacement>>(
        find.byType(SegmentedButton<ModelPlacement>),
      );
      expect(control.selected, {ModelPlacement.local});
    });

    testWidgets('a box install opens on the GPU server segment',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
      );

      final control =
          tester.widget<SegmentedButton<ModelPlacement>>(
        find.byType(SegmentedButton<ModelPlacement>),
      );
      expect(control.selected, {ModelPlacement.box});
      expect(find.byKey(SetupWhereBody.urlKey), findsOneWidget);
    });

    testWidgets('choosing a segment writes nothing', (tester) async {
      final used = <String>[];
      await open(
        tester,
        onUseBox: (url, key) async => used.add('box'),
        onUseLocal: () async => used.add('local'),
      );

      await press(tester, segment(SettingsModelsSimple.boxSegmentLabel));

      // The form came up and nothing was written by the touch alone.
      expect(find.byKey(SetupWhereBody.urlKey), findsOneWidget);
      expect(used, isEmpty);
    });
  });

  group('the box form', () {
    testWidgets('the address is prefilled and the key field starts empty',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
      );

      expect(
        tester
            .widget<TextField>(find.byKey(SetupWhereBody.urlKey))
            .controller
            ?.text,
        'https://box.example.com',
      );
      // Nothing on this screen ever holds a key.
      expect(
        tester
            .widget<TextField>(find.byKey(SetupWhereBody.keyFieldKey))
            .controller
            ?.text,
        '',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(SetupWhereBody.keyFieldKey))
            .obscureText,
        isTrue,
      );
      expect(find.text(SettingsModelsSimple.boxCaption), findsOneWidget);
    });

    testWidgets('a stored key hints that typing replaces it, and Save is live '
        'with the field blank', (tester) async {
      final saved = <(String, String?)>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        onUseBox: (url, key) async => saved.add((url, key)),
      );

      final field =
          tester.widget<TextField>(find.byKey(SetupWhereBody.keyFieldKey));
      expect(field.decoration?.hintText, SetupWhereBody.keyStoredHint);

      await press(tester, find.byKey(setupContinueKey));

      // Null, not the empty string: the host reads that as "keep the stored
      // one" and writes no keychain entry at all.
      expect(saved, [('https://box.example.com', null)]);
    });

    testWidgets('with no key stored Save waits for one', (tester) async {
      final saved = <(String, String?)>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        onUseBox: (url, key) async => saved.add((url, key)),
      );

      // Disabled rather than absent: a way forward that vanished would read
      // as a dead end.
      expect(
        tester.widget<FilledButton>(find.byKey(setupContinueKey)).onPressed,
        isNull,
      );
      expect(saved, isEmpty);
    });

    testWidgets('Save sends the typed address and the typed key',
        (tester) async {
      final saved = <(String, String?)>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        onUseBox: (url, key) async => saved.add((url, key)),
      );

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com/',
      );
      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await tester.pumpAndSettle();
      await press(tester, find.byKey(setupContinueKey));

      // Normalised: one trailing slash is what a pasted address arrives with.
      expect(saved, [
        ('https://box.example.com', 'sk-fixture-not-a-real-box-key'),
      ]);
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('Check server asks both slots with the typed key and reports '
        'each', (tester) async {
      final asked = <(String, String?)>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        probe: (url, {bearer}) async {
          asked.add((url, bearer));
          return const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']);
        },
      );

      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await tester.pumpAndSettle();
      await press(tester, find.byKey(SetupWhereBody.checkKey));

      // The writing slot first, then the inbox one, and the key rides both.
      expect(asked, [
        (
          'https://box.example.com/prose/v1/chat/completions',
          'sk-fixture-not-a-real-box-key',
        ),
        (
          'https://box.example.com/bulk/v1/chat/completions',
          'sk-fixture-not-a-real-box-key',
        ),
      ]);
      expect(find.text(SetupWhereBody.proseProbeLabel), findsOneWidget);
      expect(find.text(SetupWhereBody.bulkProbeLabel), findsOneWidget);
      expect(find.text('Reachable · 1 model'), findsNWidgets(2));
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('with the field blank the check sends the stored key',
        (tester) async {
      final asked = <(String, String?)>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        storedBearer: (id) => 'sk-fixture-stored-$id',
        probe: (url, {bearer}) async {
          asked.add((url, bearer));
          return const ModelProbeResult(reachable: true);
        },
      );

      await press(tester, find.byKey(SetupWhereBody.checkKey));

      expect(asked, [
        (
          'https://box.example.com/prose/v1/chat/completions',
          'sk-fixture-stored-$boxProseId',
        ),
        (
          'https://box.example.com/bulk/v1/chat/completions',
          'sk-fixture-stored-$boxBulkId',
        ),
      ]);
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });
  });

  group('a check in flight', () {
    testWidgets('both captions are up before either answer lands',
        (tester) async {
      final hold = Completer<ModelProbeResult>();
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        storedBearer: (_) => 'sk-fixture-stored',
        probe: (url, {bearer}) => hold.future,
      );

      await tester.tap(find.byKey(SetupWhereBody.checkKey));
      await tester.pump();

      // The two captions and two busy lines, from the first frame: a reader
      // is not handed a relabelled line halfway through a check.
      expect(find.text(SetupWhereBody.proseProbeLabel), findsOneWidget);
      expect(find.text(SetupWhereBody.bulkProbeLabel), findsOneWidget);
      expect(find.text('Checking…'), findsNWidgets(2));

      hold.complete(const ModelProbeResult(reachable: true, modelIds: ['m']));
      await tester.pumpAndSettle();
      expect(find.text('Checking…'), findsNothing);
    });

    testWidgets('a check that outlives an address edit writes nothing',
        (tester) async {
      final hold = Completer<ModelProbeResult>();
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        storedBearer: (_) => 'sk-fixture-stored',
        probe: (url, {bearer}) => hold.future,
      );
      await tester.tap(find.byKey(SetupWhereBody.checkKey));
      await tester.pump();
      expect(find.text('Checking…'), findsNWidgets(2));

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box2.example.com',
      );
      await tester.pump();
      // The busy lines come off with the edit.
      expect(find.text('Checking…'), findsNothing);

      hold.complete(const ModelProbeResult(reachable: true, modelIds: ['m']));
      await tester.pumpAndSettle();
      // And the stale answers never land: the line still says not checked.
      expect(status(tester), SettingsModelsSimple.notCheckedText);
      expect(find.textContaining('Reachable'), findsNothing);
    });
  });

  group('this Mac', () {
    testWidgets('the card, the hardware line and the button are all here',
        (tester) async {
      var local = 0;
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        localServer: const Text('SERVER CARD'),
        hardwareLine: 'This Mac: Apple M1 Max, 64.0 GB, runs all three models',
        onUseLocal: () async => local++,
      );

      await press(tester, segment(SettingsModelsSimple.localSegmentLabel));

      expect(find.text('SERVER CARD'), findsOneWidget);
      expect(
        find.text('This Mac: Apple M1 Max, 64.0 GB, runs all three models'),
        findsOneWidget,
      );
      // Above the card, because it is the answer and the card is the detail.
      expect(
        tester.getTopLeft(find.byKey(SettingsModelsSimple.useLocalKey)).dy,
        lessThan(tester.getTopLeft(find.text('SERVER CARD')).dy),
      );

      await press(tester, find.byKey(SettingsModelsSimple.useLocalKey));
      expect(local, 1);
    });

    testWidgets('the button is inert once the install is already here',
        (tester) async {
      await open(tester, localServer: const Text('SERVER CARD'));

      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(SettingsModelsSimple.useLocalKey),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('the status line', () {
    testWidgets('on this Mac it says so and nothing more', (tester) async {
      await open(tester);
      expect(status(tester), SettingsModelsSimple.localStatusText);
    });

    testWidgets('on the box with no key it asks for one', (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
      );
      expect(status(tester), SettingsModelsSimple.keyNeededText);
    });

    testWidgets('with a key and no check it says so', (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
      );
      expect(status(tester), SettingsModelsSimple.notCheckedText);
    });

    testWidgets('a check that both slots answered reads as both', (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        storedBearer: (_) => 'sk-fixture-stored',
        probe: (url, {bearer}) async =>
            const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
      );

      await press(tester, find.byKey(SetupWhereBody.checkKey));

      expect(status(tester), SettingsModelsSimple.bothAnsweredText);
    });

    testWidgets('one slot down puts that slot’s sentence on the line',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        storedBearer: (_) => 'sk-fixture-stored',
        probe: (url, {bearer}) async => url.contains('/bulk/')
            ? const ModelProbeResult(
                reachable: false,
                error: 'Connection refused',
              )
            : const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
      );

      await press(tester, find.byKey(SetupWhereBody.checkKey));

      expect(status(tester), 'Checked: Connection refused');
    });

    testWidgets('a park wins over everything the page could say about itself',
        (tester) async {
      for (final (reason, sentence) in [
        ('model_unavailable', SettingsModelsSimple.boxParkedText),
        ('unauthorized', SettingsModelsSimple.boxUnauthorizedText),
        ('embed_unavailable', SettingsModelsSimple.embedUnavailableText),
      ]) {
        await open(
          tester,
          placement: ModelPlacement.box,
          boxUrl: 'https://box.example.com',
          boxKeyStored: true,
          parked: ParkedFact(reason: reason, waiting: 3),
        );
        expect(status(tester), sentence, reason: reason);
      }
    });

    testWidgets('with processing off it says so rather than that work is '
        'retrying', (tester) async {
      // The last parked fact outlives the drains it came from, and a park
      // sentence promises a retry nothing is going to make.
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        processingOn: false,
        parked: const ParkedFact(reason: 'model_unavailable', waiting: 3),
      );
      expect(status(tester), SettingsModelsSimple.processingOffText);
    });

    testWidgets('a missing key is said before a park about it',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        parked: const ParkedFact(reason: 'unauthorized', waiting: 3),
      );
      expect(status(tester), SettingsModelsSimple.keyNeededText);
    });

    testWidgets('an address with no scheme is refused under the field, and '
        'typing clears it', (tester) async {
      final saves = <String>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        onUseBox: (url, _) async => saves.add(url),
      );

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'box.example.com',
      );
      await tester.pumpAndSettle();
      await press(tester, find.byKey(setupContinueKey));

      // The form owns the rule and answers under the field it is about, so
      // the status line goes on saying what it was saying.
      expect(saves, isEmpty);
      expect(find.text(SetupWhereBody.addressRefusalText), findsOneWidget);
      expect(status(tester), SettingsModelsSimple.notCheckedText);

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com',
      );
      await tester.pumpAndSettle();
      expect(find.text(SetupWhereBody.addressRefusalText), findsNothing);
      expect(status(tester), SettingsModelsSimple.notCheckedText);
    });

    testWidgets('a park word this page cannot answer for is left alone',
        (tester) async {
      // `session` is a sign-out. The inbox routes it and a second sentence
      // about it here would be the app saying the same thing twice.
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        parked: const ParkedFact(reason: 'session', waiting: 3),
      );
      expect(status(tester), SettingsModelsSimple.notCheckedText);
    });

    testWidgets('the embedding server gets its own line, and only on the box',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        embedServerLine: 'Embedding model: Ready on 127.0.0.1:8080',
      );
      expect(
        find.text('Embedding model: Ready on 127.0.0.1:8080'),
        findsOneWidget,
      );

      await open(
        tester,
        embedServerLine: 'Embedding model: Ready on 127.0.0.1:8080',
      );
      expect(
        find.text('Embedding model: Ready on 127.0.0.1:8080'),
        findsNothing,
      );
    });
  });

  group('the three role lines', () {
    testWidgets('a local install names the three models on this Mac',
        (tester) async {
      await open(tester, roleLines: _localLines());

      expect(find.text('Big model'), findsOneWidget);
      expect(find.text('Qwen3.8 27B on this Mac'), findsOneWidget);
      expect(find.text('Small model'), findsOneWidget);
      expect(find.text('Qwen3 4B on this Mac'), findsOneWidget);
      expect(find.text('Embeddings'), findsOneWidget);
      expect(find.text('Qwen3 Embedding 0.6B on this Mac'), findsOneWidget);
    });

    test('a small Mac whose big steps run on the 4B says so', () {
      // The name follows the TARGET the role resolves to, never the role: an
      // inbox-tier Mac points its six prose steps at Local fast, and a row
      // that said 27B there would be naming a model the Mac is not running.
      expect(
        SettingsModelsSimple.roleDetail(role: StageRole.big, spec: _localFast),
        'Qwen3 4B on this Mac',
      );
    });

    testWidgets('a box install names the two the box serves, and keeps '
        'embeddings here', (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        roleLines: _boxLines(),
      );

      expect(find.text('qwen3.8 on the GPU server'), findsOneWidget);
      expect(find.text('qwen3-4b on the GPU server'), findsOneWidget);
      expect(find.text('Qwen3 Embedding 0.6B on this Mac'), findsOneWidget);
    });

    testWidgets('a role whose steps disagree says how many and where to look',
        (tester) async {
      expect(
        SettingsModelsSimple.roleDetail(
          role: StageRole.big,
          spec: _localProse,
          overrides: 1,
        ),
        'Custom · 1 step points elsewhere · see Advanced',
      );
      expect(
        SettingsModelsSimple.roleDetail(
          role: StageRole.small,
          spec: _localFast,
          overrides: 3,
        ),
        'Custom · 3 steps point elsewhere · see Advanced',
      );

      await open(
        tester,
        roleLines: [
          RoleLine(
            id: 'big',
            title: 'Big model',
            detail: SettingsModelsSimple.roleDetail(
              role: StageRole.big,
              spec: _localProse,
              overrides: 2,
            ),
          ),
        ],
      );
      expect(
        find.text('Custom · 2 steps point elsewhere · see Advanced'),
        findsOneWidget,
      );
    });

    testWidgets('a role on somebody’s own target names the model and the host',
        (tester) async {
      expect(
        SettingsModelsSimple.roleDetail(
          role: StageRole.big,
          spec: const LlmTargetSpec(
            id: 't-1a2b3c4d',
            name: 'Studio box',
            url: 'http://localhost:18100/v1/chat/completions',
            model: 'qwen3-27b-fp8',
          ),
        ),
        'qwen3-27b-fp8 at localhost:18100',
      );
    });

    testWidgets('each Check asks that role’s own URL with its stored key',
        (tester) async {
      final asked = <(String, String?)>[];
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        roleLines: _boxLines(),
        storedBearer: (id) => 'sk-fixture-stored-$id',
        probe: (url, {bearer}) async {
          asked.add((url, bearer));
          return const ModelProbeResult(reachable: true, modelIds: ['a']);
        },
      );

      await press(
        tester,
        find.byKey(SettingsModelsSimple.roleCheckKey('small')),
      );

      expect(asked, [
        (
          'https://box.example.com/bulk/v1/chat/completions',
          'sk-fixture-stored-$boxBulkId',
        ),
      ]);
      expect(find.text('Reachable · 1 model'), findsOneWidget);
      expect(rendered(tester), everyElement(isNot(contains('sk-fixture'))));
    });

    testWidgets('a role with no stored key sends none', (tester) async {
      final asked = <(String, String?)>[];
      await open(
        tester,
        roleLines: _localLines(),
        storedBearer: (id) => 'sk-fixture-stored-$id',
        probe: (url, {bearer}) async {
          asked.add((url, bearer));
          return const ModelProbeResult(reachable: true);
        },
      );

      await press(
        tester,
        find.byKey(SettingsModelsSimple.roleCheckKey('embed')),
      );

      expect(asked, [('http://localhost:8081/v1/embeddings', null)]);
    });

    testWidgets('a row that moves to another server drops its old answer',
        (tester) async {
      await open(
        tester,
        placement: ModelPlacement.box,
        boxUrl: 'https://box.example.com',
        boxKeyStored: true,
        storedBearer: (_) => 'sk-fixture-stored',
        probe: (url, {bearer}) async =>
            const ModelProbeResult(reachable: true, modelIds: ['qwen3.8']),
        roleLines: _boxLines(),
      );
      await press(tester, find.byKey(SettingsModelsSimple.roleCheckKey('big')));
      expect(find.textContaining('Reachable'), findsOneWidget);

      // The host moved the install to this Mac: the big row asks a different
      // server now, and the box's green line must not be read as its answer.
      await open(tester, roleLines: _localLines());
      expect(find.textContaining('Reachable'), findsNothing);
    });

    testWidgets('a host that cannot ask offers no Check anywhere',
        (tester) async {
      await open(tester, roleLines: _localLines());

      for (final id in ['big', 'small', 'embed']) {
        expect(
          find.byKey(SettingsModelsSimple.roleCheckKey(id)),
          findsNothing,
          reason: '$id still offers a check with no probe wired',
        );
      }
      expect(find.byKey(SetupWhereBody.checkKey), findsNothing);
    });
  });

  group('the rows the host builds', () {
    const url = 'https://box.example.com';
    const own = LlmTargetSpec(
      id: 't-1a2b3c4d',
      name: 'Studio box',
      url: 'http://localhost:18100/v1/chat/completions',
      model: 'qwen3-27b-fp8',
    );
    const custom1 = 'Custom · 1 step points elsewhere · see Advanced';
    RoleLine row(List<RoleLine> rows, String id) =>
        rows.singleWhere((r) => r.id == id);

    test('a fresh install on this Mac reads the two built-ins and embeddings',
        () {
      const prefs = AppPrefs();
      final rows = RoleLine.fromPrefs(prefs);
      expect([for (final r in rows) r.id], ['big', 'small', 'embed']);
      expect(row(rows, 'big').detail, 'Qwen3.8 27B on this Mac');
      expect(row(rows, 'big').checkUrl, prefs.proseSpec.url);
      expect(row(rows, 'small').detail, 'Qwen3 4B on this Mac');
      expect(row(rows, 'small').checkUrl, prefs.fastSpec.url);
      expect(row(rows, 'embed').detail, 'Qwen3 Embedding 0.6B on this Mac');
      expect(row(rows, 'embed').checkUrl, endsWith('/v1/embeddings'));
      expect(rows.every((r) => r.bearerId == null), isTrue);
    });

    test('a box install reads the two the box serves, with the key by id', () {
      const prefs = AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxUrl: url,
        boxKeyStored: true,
      );
      final rows = RoleLine.fromPrefs(prefs);
      expect(row(rows, 'big').detail, 'qwen3.8 on the GPU server');
      expect(row(rows, 'big').checkUrl, '$url/prose/v1/chat/completions');
      expect(row(rows, 'big').bearerId, boxProseId);
      expect(row(rows, 'small').detail, 'qwen3-4b on the GPU server');
      expect(row(rows, 'small').checkUrl, '$url/bulk/v1/chat/completions');
      expect(row(rows, 'small').bearerId, boxBulkId);
      expect(row(rows, 'embed').bearerId, isNull);

      // No key in the keychain: the rows still point at the box, and Check
      // sends nothing rather than a token nobody stored.
      final bare = RoleLine.fromPrefs(
        const AppPrefs(modelPlacement: ModelPlacement.box, boxUrl: url),
      );
      expect(row(bare, 'big').bearerId, isNull);
    });

    test('membership on the small model on the box makes the big row Custom, '
        'and its Check still asks the prose target', () {
      const prefs = AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxUrl: url,
        stageTargets: {'storyline_membership': boxBulkId},
      );
      final rows = RoleLine.fromPrefs(prefs);
      expect(row(rows, 'big').detail, custom1);
      expect(row(rows, 'big').checkUrl, '$url/prose/v1/chat/completions');

      // On this Mac the same entry is the rule's own answer, so nothing is
      // Custom: membership is the small model's work here.
      final here = RoleLine.fromPrefs(
        const AppPrefs(stageTargets: {'storyline_membership': builtInFastId}),
      );
      expect(row(here, 'big').detail, 'Qwen3.8 27B on this Mac');
      expect(row(here, 'small').detail, 'Qwen3 4B on this Mac');
    });

    test('the odd step out counts as one even when it is the lead stage', () {
      const prefs = AppPrefs(
        targets: [own],
        stageTargets: {'draft_reply': 't-1a2b3c4d'},
      );
      final rows = RoleLine.fromPrefs(prefs);
      expect(row(rows, 'big').detail, custom1);
      // The row describes the target the other five share, and Check asks it
      // rather than the one step that wandered.
      expect(row(rows, 'big').checkUrl, prefs.proseSpec.url);
      expect(row(rows, 'small').detail, 'Qwen3 4B on this Mac');
    });

    test('a role moved whole onto somebody’s own target names it', () {
      final prefs = AppPrefs(
        targets: const [own],
        stageTargets: {for (final id in proseStageIds) id: 't-1a2b3c4d'},
      );
      final rows = RoleLine.fromPrefs(prefs);
      expect(row(rows, 'big').detail, 'qwen3-27b-fp8 at localhost:18100');
      expect(row(rows, 'big').checkUrl, own.url);
    });

    test('an optional stage never makes a role Custom', () {
      const prefs = AppPrefs(
        targets: [own],
        stageTargets: {'draft_improve': 't-1a2b3c4d'},
      );
      expect(
        row(RoleLine.fromPrefs(prefs), 'big').detail,
        'Qwen3.8 27B on this Mac',
      );
    });

    test('a small Mac’s six prose steps on the 4B read as the 4B', () {
      final prefs =
          AppPrefs(stageTargets: tierStageDefaults(MachineTier.inbox));
      final rows = RoleLine.fromPrefs(prefs);
      expect(row(rows, 'big').detail, 'Qwen3 4B on this Mac');
      expect(row(rows, 'big').checkUrl, prefs.fastSpec.url);
      expect(row(rows, 'small').detail, 'Qwen3 4B on this Mac');
    });

    test('a third-party draft pick with consent withheld is not Custom', () {
      const cloud = LlmTargetSpec(
        id: 'cloud-1',
        name: 'Cloud prose',
        url: 'https://bedrock-runtime.example.com',
        model: 'us.example.big-model',
        wire: LlmWire.bedrockConverse,
      );
      const prefs = AppPrefs(
        modelPlacement: ModelPlacement.box,
        boxUrl: url,
        targets: [cloud],
        stageTargets: {'draft_reply': 'cloud-1'},
      );
      // What a request would reach is the fallback, on every one of the six,
      // and the row says what a request would reach.
      expect(
        row(RoleLine.fromPrefs(prefs), 'big').detail,
        'qwen3.8 on the GPU server',
      );
    });
  });

  group('the Advanced fold', () {
    testWidgets('it is collapsed on arrival and opens onto the stage table',
        (tester) async {
      await open(
        tester,
        advanced: SettingsModelsBody(
          slotTargets: slotDefaults,
          isDefault: const {
            ModelSlot.fast: true,
            ModelSlot.prose: true,
            ModelSlot.embed: true,
          },
          compiledDefaults: slotDefaults,
          stages: pipelineStages,
          onSave: (_, {required url, required model}) {},
          onReset: (_) {},
        ),
      );

      expect(find.text(SettingsModelsSimple.advancedTitle), findsOneWidget);
      expect(find.text(SettingsModelsSimple.advancedSummary), findsOneWidget);
      expect(find.text('Which model each step uses'), findsNothing);

      await press(
        tester,
        find.byKey(
          SettingsSection.toggleKey(SettingsModelsSimple.advancedTitle),
        ),
      );

      expect(find.text('Which model each step uses'), findsOneWidget);
    });
  });

  group('the collapsed summary', () {
    test('the box names the host and says where embeddings stay', () {
      expect(
        SettingsModelsSimple.summary(
          placement: ModelPlacement.box,
          boxUrl: 'https://box.example.com',
          server: 'Ready on 127.0.0.1:8080',
        ),
        'GPU server · box.example.com · embeddings on this Mac',
      );
    });

    test('this Mac names the server’s own state', () {
      expect(
        SettingsModelsSimple.summary(
          placement: ModelPlacement.local,
          boxUrl: '',
          server: 'Ready on 127.0.0.1:8080',
        ),
        'This Mac · Ready on 127.0.0.1:8080',
      );
      expect(
        SettingsModelsSimple.summary(
          placement: ModelPlacement.local,
          boxUrl: '',
        ),
        'This Mac',
      );
    });

    test('a box placement with no address says so rather than lying', () {
      expect(
        SettingsModelsSimple.summary(
          placement: ModelPlacement.box,
          boxUrl: '',
        ),
        'GPU server · no address yet',
      );
    });
  });

  testWidgets('the whole page survives a doubled text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(
      tester,
      placement: ModelPlacement.box,
      boxUrl: 'https://box.example.com',
      boxKeyStored: true,
      roleLines: _boxLines(),
      probe: (_, {bearer}) async => const ModelProbeResult(reachable: true),
    );

    expect(tester.takeException(), isNull);
  });
}
