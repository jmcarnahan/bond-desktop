import 'package:bond_inbox/screens/consent_screen.dart';
import 'package:bond_inbox/screens/setup/setup_controls.dart'
    show setupContinueKey;
import 'package:bond_inbox/screens/setup/setup_where_body.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/system/system_info.dart' show HardwareInfo;
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/model_slot_editor.dart';
import 'package:bond_inbox/widgets/settings_models_body.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:bond_inbox/widgets/settings_targets_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Models section as the SCREEN assembles it.
///
/// `model_slot_editor_test.dart` pins what one editor does with the values it
/// is handed; this pins the section around them — the collapsed summary, the
/// authored stage table, which slots get an editor and which does not, and that
/// a Save reaches the host tagged with the slot it came from.
///
/// Screen-only: `SettingsScreen` is prop-only, so there is no `InboxScreen` and
/// no sixty-second timer, which is what makes `pumpAndSettle` safe here.

const LlmTarget _fastCustom = LlmTarget(
  baseUrl: 'http://127.0.0.1:9000/v1/chat/completions',
  model: 'qwen3-4b',
);

void main() {
  Future<void> open(
    WidgetTester tester, {
    Map<ModelSlot, LlmTarget>? slotTargets,
    Map<ModelSlot, bool>? isDefault,
    Future<ModelProbeResult> Function(String, {String? bearer})? probe,
    void Function(ModelSlot, {required String url, required String model})?
        onSave,
    void Function(ModelSlot)? onReset,
    bool wireModels = true,
    Widget? modelsHeader,
    String? localServerSummary,
    int proseParallel = 1,
    void Function(int)? onProseParallelChanged,
    bool wireWidth = true,
    String? proseParallelTargetName,
    List<LlmTargetSpec> targets = const [],
    Map<String, String?> stageTargetIds = const {},
    bool cloudDraftsConsent = false,
    Future<void> Function(
      LlmTargetSpec spec, {
      String? bearer,
      bool prose,
      bool confirm,
      bool bulk,
    })? onTargetSaved,
    void Function(String stageId, String? targetId)? onStageTargetChanged,
    Future<void> Function()? onCloudDraftsConsent,
    bool wireTargets = false,
    HardwareInfo? hardware,
    MachineTier? machineTier,
    Future<void> Function()? onApplyTierDefaults,
    bool wireTier = false,
    ModelPlacement modelPlacement = ModelPlacement.local,
    Future<void> Function(String baseUrl, String key)? onAdoptBox,
    Future<void> Function()? onAdoptLocal,
    bool wirePlacement = false,
    String? boxParkedReason,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
          threshold: 0.5,
          aboutMe: '',
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          onBack: () {},
          slotTargets: slotTargets ?? slotDefaults,
          slotIsDefault: isDefault ??
              const {
                ModelSlot.fast: true,
                ModelSlot.prose: true,
                ModelSlot.embed: true,
              },
          probeServer: probe,
          onSlotTargetChanged: wireModels
              ? (onSave ?? (_, {required url, required model}) {})
              : null,
          onSlotReset: onReset,
          proseParallel: proseParallel,
          onProseParallelChanged: wireWidth
              ? (onProseParallelChanged ?? (_) {})
              : null,
          proseParallelTargetName: proseParallelTargetName,
          targets: targets,
          stageTargetIds: stageTargetIds,
          cloudDraftsConsent: cloudDraftsConsent,
          onTargetSaved: wireTargets
              ? (onTargetSaved ??
                  (spec, {bearer, prose = false, confirm = false, bulk = false}) async {})
              : null,
          onStageTargetChanged:
              wireTargets ? (onStageTargetChanged ?? (_, _) {}) : null,
          onCloudDraftsConsent: onCloudDraftsConsent,
          hardware: hardware,
          machineTier: machineTier,
          onApplyTierDefaults:
              wireTier ? (onApplyTierDefaults ?? () async {}) : null,
          modelPlacement: modelPlacement,
          boxParkedReason: boxParkedReason,
          onAdoptBox: wirePlacement
              ? (onAdoptBox ?? (_, _) async {})
              : null,
          onAdoptLocal:
              wirePlacement ? (onAdoptLocal ?? () async {}) : null,
          modelsHeader: modelsHeader,
          localServerSummary: localServerSummary,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester, String title) async {
    final toggle = find.byKey(SettingsSection.toggleKey(title));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  /// How many chips carry one slot's name. The stage table is the only place
  /// these three words appear INSIDE a chip — the embeddings card's own
  /// heading is body text, not a chip — so this counts stage rows.
  int chipsSaying(WidgetTester tester, String label) => tester
      .widgetList(
        find.descendant(of: find.byType(BondChip), matching: find.text(label)),
      )
      .length;

  testWidgets('the collapsed summary says where all three slots point',
      (tester) async {
    await open(
      tester,
      slotTargets: {
        ModelSlot.fast: _fastCustom,
        ModelSlot.prose: proseSlotDefault,
        ModelSlot.embed: embedSlotDefault,
      },
      isDefault: const {
        ModelSlot.fast: false,
        ModelSlot.prose: true,
        ModelSlot.embed: true,
      },
    );

    expect(
      find.text('Fast qwen3-4b @ 127.0.0.1:9000 · '
          'Prose qwen3.8 @ localhost:8080 · '
          'Embeddings localhost:8081'),
      findsOneWidget,
    );
  });

  testWidgets('the stage table lists every stage against its slot',
      (tester) async {
    await open(tester);
    await expand(tester, 'Models');

    for (final stage in pipelineStages) {
      expect(find.text(stage.label), findsOneWidget,
          reason: '${stage.id} is missing from the table');
    }
    // The authored mapping: eight bulk stages, seven prose ones, one
    // embedding. Two of the prose rows describe features that are off until
    // something turns them on — `storyline_group` runs only under
    // `GroupingMode.model`, and `draft_improve` only once somebody points it
    // at a target — and both have a row anyway, because the table is the app
    // telling the user what its wiring IS, and a stage with no row is a stage
    // nothing could ever be pointed at.
    expect(chipsSaying(tester, 'Fast'), 8);
    expect(chipsSaying(tester, 'Prose'), 7);
    expect(chipsSaying(tester, 'Embeddings'), 1);
  });

  testWidgets('the two chat slots get an editor and embeddings does not',
      (tester) async {
    await open(
      tester,
      probe: (_, {bearer}) async => const ModelProbeResult(reachable: true),
    );
    await expand(tester, 'Models');

    expect(
      find.byKey(ModelSlotEditor.saveKey(ModelSlot.fast)),
      findsOneWidget,
    );
    expect(
      find.byKey(ModelSlotEditor.saveKey(ModelSlot.prose)),
      findsOneWidget,
    );
    // Read-only: every stored vector is tagged with this model, so there is
    // nothing here to save.
    expect(find.byKey(ModelSlotEditor.saveKey(ModelSlot.embed)), findsNothing);
    expect(
      find.byKey(ModelSlotEditor.checkKey(ModelSlot.embed)),
      findsOneWidget,
    );
  });

  testWidgets('a host that cannot ask a server offers no Check server anywhere',
      (tester) async {
    await open(tester);
    await expand(tester, 'Models');

    for (final slot in ModelSlot.values) {
      expect(find.byKey(ModelSlotEditor.checkKey(slot)), findsNothing,
          reason: '${slot.name} still offers a check with no probe wired');
    }
    // The editors are all still there — one control fewer, not disabled.
    expect(
      find.byKey(ModelSlotEditor.saveKey(ModelSlot.fast)),
      findsOneWidget,
    );
  });

  testWidgets('the embeddings card checks its own server', (tester) async {
    final asked = <String>[];
    await open(tester, probe: (url, {bearer}) async {
      asked.add(url);
      return const ModelProbeResult(
        reachable: true,
        modelIds: ['Qwen3-Embedding-0.6B'],
      );
    });
    await expand(tester, 'Models');

    final button = find.byKey(ModelSlotEditor.checkKey(ModelSlot.embed));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(asked, ['http://localhost:8081/v1/embeddings']);
    expect(find.text('Reachable · 1 model'), findsOneWidget);
  });

  testWidgets('a Save reaches the host tagged with its slot', (tester) async {
    final saves = <(ModelSlot, String, String)>[];
    await open(
      tester,
      onSave: (slot, {required url, required model}) =>
          saves.add((slot, url, model)),
    );
    await expand(tester, 'Models');

    final urlField = find.byKey(ModelSlotEditor.urlFieldKey(ModelSlot.fast));
    await tester.ensureVisible(urlField);
    await tester.pumpAndSettle();
    await tester.enterText(urlField, 'http://127.0.0.1:9000/v1/chat/completions');
    await tester.enterText(
      find.byKey(ModelSlotEditor.modelFieldKey(ModelSlot.fast)),
      'qwen3-4b',
    );
    await tester.pumpAndSettle();

    final save = find.byKey(ModelSlotEditor.saveKey(ModelSlot.fast));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(saves, [
      (ModelSlot.fast, 'http://127.0.0.1:9000/v1/chat/completions', 'qwen3-4b'),
    ]);
  });

  testWidgets('Use build defaults reaches the host tagged with its slot',
      (tester) async {
    final resets = <ModelSlot>[];
    await open(
      tester,
      slotTargets: {
        ModelSlot.fast: fastSlotDefault,
        ModelSlot.prose: const LlmTarget(
          baseUrl: 'http://127.0.0.1:9001/v1/chat/completions',
          model: 'big',
        ),
        ModelSlot.embed: embedSlotDefault,
      },
      isDefault: const {
        ModelSlot.fast: true,
        ModelSlot.prose: false,
        ModelSlot.embed: true,
      },
      onReset: resets.add,
    );
    await expand(tester, 'Models');

    final reset = find.byKey(ModelSlotEditor.resetKey(ModelSlot.prose));
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(resets, [ModelSlot.prose]);
  });

  testWidgets('the section is absent when the host cannot store a change',
      (tester) async {
    await open(tester, wireModels: false);

    expect(find.text('Models'), findsNothing);
    // And the placeholder it replaced is gone for good.
    expect(find.text('Configured at build time'), findsNothing);
  });

  /// The Local server card is injected by the host — this section knows
  /// nothing about a supervisor — so what is pinned here is the JOIN: the
  /// server's own line comes first in the collapsed summary, and its card comes
  /// first inside the expanded body, above the stage table.
  testWidgets('a wired local server leads the summary and the body',
      (tester) async {
    await open(
      tester,
      localServerSummary: 'Ready on 127.0.0.1:8080',
      modelsHeader: const Text('HEADER'),
    );

    expect(
      find.text('Ready on 127.0.0.1:8080 · '
          'Fast qwen3.8 @ localhost:8082 · '
          'Prose qwen3.8 @ localhost:8080 · '
          'Embeddings localhost:8081'),
      findsOneWidget,
    );
    expect(find.text('HEADER'), findsNothing);

    await expand(tester, 'Models');
    expect(find.text('HEADER'), findsOneWidget);
    // Above the stage table, not below it.
    expect(
      tester.getTopLeft(find.text('HEADER')).dy,
      lessThan(tester.getTopLeft(find.text('Which model each step uses')).dy),
    );
  });

  group('Drafts in flight', () {
    testWidgets('it renders under the prose editor and reports the width',
        (tester) async {
      final reported = <int>[];
      await open(
        tester,
        onProseParallelChanged: reported.add,
      );
      await expand(tester, 'Models');

      expect(find.text('Drafts in flight'), findsOneWidget);
      expect(
        find.text(
          'For Local prose. One per slot the server was started with (SLOTS '
          'in local.mk, --max-num-seqs on vLLM). Extra requests queue at the '
          'server rather than fail.',
        ),
        findsOneWidget,
      );
      // Under the prose slot it is about, not under the fast one.
      expect(
        tester.getTopLeft(find.text('Drafts in flight')).dy,
        greaterThan(
          tester.getTopLeft(find.text('Prose · reads and writes')).dy,
        ),
      );

      final four = find.descendant(
        of: find.byType(SegmentedButton<int>),
        matching: find.text('4'),
      );
      await tester.ensureVisible(four);
      await tester.pumpAndSettle();
      await tester.tap(four);
      await tester.pumpAndSettle();

      // Reported the instant it moves, like every other control here: the next
      // draft is what it governs, and one can be queued while this is open.
      expect(reported, [4]);
    });

    /// The width is the DRAFT TARGET's since Round E, not the prose slot's: a
    /// box has slots this Mac does not, so the caption has to say whose number
    /// the segments are about.
    testWidgets('it names the draft target and reports the width',
        (tester) async {
      final reported = <int>[];
      await open(
        tester,
        proseParallel: 4,
        proseParallelTargetName: 'GPU box',
        onProseParallelChanged: reported.add,
      );
      await expand(tester, 'Models');

      expect(find.textContaining('For GPU box.'), findsOneWidget);

      final eight = find.descendant(
        of: find.byType(SegmentedButton<int>),
        matching: find.text('8'),
      );
      await tester.ensureVisible(eight);
      await tester.pumpAndSettle();
      await tester.tap(eight);
      await tester.pumpAndSettle();

      expect(reported, [8]);
    });

    testWidgets('a host that cannot store it is offered no control',
        (tester) async {
      await open(tester, wireWidth: false);
      await expand(tester, 'Models');

      expect(find.text('Drafts in flight'), findsNothing);
      // And the rest of the section is exactly what it was.
      expect(
        find.byKey(ModelSlotEditor.saveKey(ModelSlot.prose)),
        findsOneWidget,
      );
    });

    testWidgets('it does not touch the collapsed summary', (tester) async {
      // The summary names where the three slots point and nothing else. It is
      // pinned by the test at the top of this file and by docs/settings.md,
      // and a width is not a destination.
      await open(tester, proseParallel: 8);

      expect(
        find.text('Fast qwen3.8 @ localhost:8082 · '
            'Prose qwen3.8 @ localhost:8080 · '
            'Embeddings localhost:8081'),
        findsOneWidget,
      );
    });
  });

  /// The summary a machine with no added targets reads is BYTE-IDENTICAL to
  /// what it read before routing was data. The count is news only when there
  /// is something to count, and the two built-ins are not additions.
  testWidgets('the summary counts added targets and nothing else',
      (tester) async {
    const builtIns = [
      LlmTargetSpec(
        id: builtInFastId,
        name: builtInFastName,
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3.8',
      ),
      LlmTargetSpec(
        id: builtInProseId,
        name: builtInProseName,
        url: 'http://localhost:8080/v1/chat/completions',
        model: 'qwen3.8',
      ),
    ];
    const unchanged = 'Fast qwen3.8 @ localhost:8082 · '
        'Prose qwen3.8 @ localhost:8080 · '
        'Embeddings localhost:8081';

    await open(tester, targets: builtIns);
    expect(find.text(unchanged), findsOneWidget);

    await open(tester, targets: const [
      ...builtIns,
      LlmTargetSpec(
        id: 't-1a2b3c4d',
        name: 'Studio box',
        url: 'http://localhost:18100/v1/chat/completions',
        model: 'qwen3-27b-fp8',
      ),
    ]);
    expect(find.text('$unchanged · 1 more target'), findsOneWidget);

    await open(tester, targets: const [
      ...builtIns,
      LlmTargetSpec(
        id: 't-1a2b3c4d',
        name: 'Studio box',
        url: 'http://localhost:18100/v1/chat/completions',
        model: 'qwen3-27b-fp8',
      ),
      LlmTargetSpec(
        id: 't-99887766',
        name: 'Bedrock Opus',
        url: 'https://bedrock-runtime.us-east-2.amazonaws.com/',
        model: 'us.example.opus',
        wire: LlmWire.bedrockConverse,
      ),
    ]);
    expect(find.text('$unchanged · 2 more targets'), findsOneWidget);
  });

  /// The house rule is one pane at a time with a way back, so the sub-panes
  /// REPLACE the sections rather than floating over them — and the sections'
  /// expansion state lives on the screen's own State, which is what brings a
  /// person back to the section they left rather than to a closed list.
  group('the sub-panes', () {
    const box = LlmTargetSpec(
      id: 't-1a2b3c4d',
      name: 'Studio box',
      url: 'http://localhost:18100/v1/chat/completions',
      model: 'qwen3-27b-fp8',
    );
    const bedrock = LlmTargetSpec(
      id: 't-99887766',
      name: 'Bedrock Opus',
      url: 'https://bedrock-runtime.us-east-2.amazonaws.com/',
      model: 'us.example.opus',
      wire: LlmWire.bedrockConverse,
    );
    const builtIns = [
      LlmTargetSpec(
        id: builtInFastId,
        name: builtInFastName,
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3.8',
      ),
      LlmTargetSpec(
        id: builtInProseId,
        name: builtInProseName,
        url: 'http://localhost:8080/v1/chat/completions',
        model: 'qwen3.8',
      ),
    ];

    Future<void> press(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('Add target opens the editor and Back leaves Models open',
        (tester) async {
      await open(tester, wireTargets: true, targets: builtIns);
      await expand(tester, 'Models');

      await press(tester, find.byKey(SettingsTargetsBody.addKey));
      expect(find.text('Add target'), findsOneWidget);
      // The sections are gone while the pane is up: one surface at a time.
      expect(find.text('Which model each step uses'), findsNothing);

      await press(tester, find.byTooltip('Back'));
      // Back where it was, still expanded, not collapsed to the list.
      expect(find.text('Which model each step uses'), findsOneWidget);
      expect(find.text('Add target'), findsOneWidget);
    });

    testWidgets('Edit opens the pane on that target', (tester) async {
      await open(
        tester,
        wireTargets: true,
        targets: const [...builtIns, box],
      );
      await expand(tester, 'Models');

      await press(tester, find.byKey(SettingsTargetsBody.editKey(box.id)));

      expect(find.text('Edit target'), findsOneWidget);
      expect(find.text('qwen3-27b-fp8'), findsOneWidget);
    });

    testWidgets('a third-party draft target opens the consent pane, and '
        'Continue records the consent before the stage', (tester) async {
      final order = <String>[];
      await open(
        tester,
        wireTargets: true,
        targets: const [...builtIns, bedrock],
        onStageTargetChanged: (stage, target) => order.add('stage $stage $target'),
        onCloudDraftsConsent: () async => order.add('consent'),
      );
      await expand(tester, 'Models');

      final picker =
          find.byKey(SettingsModelsBody.stagePickerKey('draft_reply'));
      await press(tester, picker);
      await press(tester, find.text('Bedrock Opus').last);

      expect(find.text('Send drafts to Bedrock Opus?'), findsOneWidget);
      expect(order, isEmpty);

      await press(tester, find.byKey(CloudDraftsConsentPane.continueKey));

      // The flag first, then the stage: `specForStage` sends a third-party
      // draft target back to the local one while the flag is false.
      expect(order, ['consent', 'stage draft_reply ${bedrock.id}']);
      expect(find.text('Which model each step uses'), findsOneWidget);
    });

    testWidgets('Not now writes nothing and goes back', (tester) async {
      final order = <String>[];
      await open(
        tester,
        wireTargets: true,
        targets: const [...builtIns, bedrock],
        onStageTargetChanged: (stage, target) => order.add('stage'),
        onCloudDraftsConsent: () async => order.add('consent'),
      );
      await expand(tester, 'Models');

      await press(
        tester,
        find.byKey(SettingsModelsBody.stagePickerKey('draft_reply')),
      );
      await press(tester, find.text('Bedrock Opus').last);
      await press(tester, find.byKey(CloudDraftsConsentPane.notNowKey));

      expect(order, isEmpty);
      expect(find.text('Which model each step uses'), findsOneWidget);
    });
  });

  /// The fact line and **Use this Mac's defaults**: what the machine is, and
  /// one press that points the pipeline at what it can actually run.
  group('where the models run', () {
    testWidgets('the heading and both buttons render on this Mac',
        (tester) async {
      await open(tester, wireTier: true, wirePlacement: true);
      await expand(tester, 'Models');

      expect(find.text(SettingsModelsBody.whereHeading), findsOneWidget);
      expect(find.text('Everything runs on this Mac.'), findsOneWidget);
      expect(find.text('Use the shared GPU box'), findsOneWidget);
      // The tier button is untouched and still says what it always said.
      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsOneWidget);
      expect(find.text("Use this Mac's defaults"), findsOneWidget);
    });

    testWidgets('on the box the button offers this Mac instead', (tester) async {
      var local = 0;
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        modelPlacement: ModelPlacement.box,
        onAdoptLocal: () async => local++,
      );
      await expand(tester, 'Models');

      expect(find.text("Use this Mac's models"), findsOneWidget);
      expect(find.text('Use the shared GPU box'), findsNothing);
      // The line says where work actually goes, and that the embedding model
      // stays here.
      expect(
        find.text('The inbox and writing steps run on the shared GPU box. '
            'The embedding model runs here.'),
        findsOneWidget,
      );
      // And that the local models stop.
      expect(
        find.text('Puts every step back on this Mac and starts the local '
            'models again.'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();
      expect(local, 1);
    });

    testWidgets('the parked line shows only on the box, and only when parked',
        (tester) async {
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        modelPlacement: ModelPlacement.box,
        boxParkedReason: 'model_unavailable',
      );
      await expand(tester, 'Models');
      expect(find.text(SettingsModelsBody.boxParkedText), findsOneWidget);

      // Same fact, local placement: the sentence names the box, so it has no
      // business on a machine that is not pointed at one.
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        boxParkedReason: 'model_unavailable',
      );
      await expand(tester, 'Models');
      expect(find.text(SettingsModelsBody.boxParkedText), findsNothing);
    });

    // A refused key is not a box that is down, and the two sentences send a
    // person to two different places: one to wait, one to type a new key into
    // the pane the button below it opens.
    testWidgets('a refused key reads as a refused key, not as a dead box',
        (tester) async {
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        modelPlacement: ModelPlacement.box,
        boxParkedReason: 'unauthorized',
      );
      await expand(tester, 'Models');
      expect(find.text(SettingsModelsBody.boxUnauthorizedText), findsOneWidget);
      expect(find.text(SettingsModelsBody.boxParkedText), findsNothing);
    });

    // Not gated on a park: a key is rotated on the box's side, and the door to
    // type the new one has to be open before anything has failed yet.
    testWidgets('Change the access key is on the box placement and not on this '
        'Mac', (tester) async {
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        modelPlacement: ModelPlacement.box,
      );
      await expand(tester, 'Models');
      expect(find.byKey(SettingsModelsBody.changeBoxKeyKey), findsOneWidget);
    });

    testWidgets('Change the access key is absent on the local placement',
        (tester) async {
      await open(tester, wireTier: true, wirePlacement: true);
      await expand(tester, 'Models');
      expect(find.byKey(SettingsModelsBody.changeBoxKeyKey), findsNothing);
    });

    // The whole point of the button: the same pane, the address already in it
    // off the stored pair, and a save that re-adopts. `adoptBox` replaces both
    // fixed-id targets and the keychain entry, so re-adopting the same address
    // IS the key change.
    testWidgets('Change the access key re-adopts with the stored address',
        (tester) async {
      final adopted = <(String, String)>[];
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        wireTargets: true,
        modelPlacement: ModelPlacement.box,
        targets: const [
          LlmTargetSpec(
            id: boxProseId,
            name: boxProseName,
            url: 'https://box.example.com/prose/v1/chat/completions',
            model: boxProseModel,
          ),
        ],
        onAdoptBox: (url, key) async => adopted.add((url, key)),
      );
      await expand(tester, 'Models');

      await tester.ensureVisible(
        find.byKey(SettingsModelsBody.changeBoxKeyKey),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsModelsBody.changeBoxKeyKey));
      await tester.pumpAndSettle();

      // The same pane the adopt button opens, and no dialog.
      expect(find.text('Shared GPU box'), findsOneWidget);
      // Prefilled from the stored writing target, origin only.
      expect(
        tester.widget<TextField>(find.byKey(SetupWhereBody.urlKey)).controller
            ?.text,
        'https://box.example.com',
      );
      // The key field starts EMPTY: nothing on this screen ever holds one.
      expect(
        tester.widget<TextField>(find.byKey(SetupWhereBody.keyFieldKey))
            .controller
            ?.text,
        '',
      );

      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-rotated-not-a-real-key',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(setupContinueKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(setupContinueKey));
      await tester.pumpAndSettle();

      expect(adopted, [
        ('https://box.example.com', 'sk-fixture-rotated-not-a-real-key'),
      ]);
      expect(find.text('Shared GPU box'), findsNothing);
    });

    // The two controls write different things and are wired apart. A host
    // that can move the placement but not the tier defaults, or the other way
    // round, must get exactly the one it can write: the placement block used
    // to ride on the tier button's wiring and vanished with it. Four tests
    // rather than four `open`s in one, because the section's expanded state
    // survives a re-pump and a second `expand` would collapse it.
    testWidgets('the placement alone renders without the tier button',
        (tester) async {
      await open(tester, wirePlacement: true);
      await expand(tester, 'Models');

      expect(find.byKey(SettingsModelsBody.adoptBoxKey), findsOneWidget);
      expect(find.text(SettingsModelsBody.whereHeading), findsOneWidget);
      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsNothing);
    });

    testWidgets('the tier button alone renders without the placement block',
        (tester) async {
      await open(tester, wireTier: true);
      await expand(tester, 'Models');

      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsOneWidget);
      expect(find.byKey(SettingsModelsBody.adoptBoxKey), findsNothing);
      expect(find.text(SettingsModelsBody.whereHeading), findsNothing);
    });

    testWidgets('neither wiring renders neither control', (tester) async {
      await open(tester);
      await expand(tester, 'Models');

      expect(find.byKey(SettingsModelsBody.adoptBoxKey), findsNothing);
      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsNothing);
      expect(find.text(SettingsModelsBody.whereHeading), findsNothing);
    });

    testWidgets('both wirings render both, which is the app', (tester) async {
      await open(tester, wireTier: true, wirePlacement: true);
      await expand(tester, 'Models');

      expect(find.byKey(SettingsModelsBody.adoptBoxKey), findsOneWidget);
      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsOneWidget);
    });

    testWidgets('the button opens the pane, and its save calls adoptBox',
        (tester) async {
      final adopted = <(String, String)>[];
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        onAdoptBox: (url, key) async => adopted.add((url, key)),
      );
      await expand(tester, 'Models');

      await tester.ensureVisible(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();

      // A PANE with a title and a back arrow, never a dialog.
      expect(find.text('Shared GPU box'), findsOneWidget);
      expect(find.byKey(SetupWhereBody.urlKey), findsOneWidget);
      expect(find.byKey(SetupWhereBody.keyFieldKey), findsOneWidget);
      // The pane was opened by a button that already made the choice, so it
      // does not ask again.
      expect(find.byKey(SetupWhereBody.boxCardKey), findsNothing);

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com/',
      );
      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(setupContinueKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(setupContinueKey));
      await tester.pumpAndSettle();

      expect(adopted,
          [('https://box.example.com', 'sk-fixture-not-a-real-box-key')]);
      // Saved and gone: the sections are back.
      expect(find.text('Shared GPU box'), findsNothing);
    });

    testWidgets('the pane refuses to save with a field empty', (tester) async {
      final adopted = <(String, String)>[];
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        onAdoptBox: (url, key) async => adopted.add((url, key)),
      );
      await expand(tester, 'Models');
      await tester.ensureVisible(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com',
      );
      await tester.pumpAndSettle();

      // Disabled rather than absent: a way forward that vanished would read
      // as a dead end.
      final button =
          tester.widget<FilledButton>(find.byKey(setupContinueKey));
      expect(button.onPressed, isNull);
      expect(adopted, isEmpty);
    });

    testWidgets("Check server sends the typed key and shows what it found",
        (tester) async {
      final asked = <(String, String?)>[];
      await open(
        tester,
        wireTier: true,
        wirePlacement: true,
        probe: (url, {bearer}) async {
          asked.add((url, bearer));
          return const ModelProbeResult(
            reachable: true,
            modelIds: ['qwen3.8'],
          );
        },
      );
      await expand(tester, 'Models');
      await tester.ensureVisible(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsModelsBody.adoptBoxKey));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(SetupWhereBody.urlKey),
        'https://box.example.com',
      );
      await tester.enterText(
        find.byKey(SetupWhereBody.keyFieldKey),
        'sk-fixture-not-a-real-box-key',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(SetupWhereBody.checkKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SetupWhereBody.checkKey));
      await tester.pumpAndSettle();

      // The writing slot, because that is the one whose model a person
      // recognises, and the key rides the request.
      expect(asked, [
        (
          'https://box.example.com/prose/v1/chat/completions',
          'sk-fixture-not-a-real-box-key',
        )
      ]);
      expect(find.text('Reachable · 1 model'), findsOneWidget);

      // The key is in the field it was typed into, obscured, and NOWHERE
      // else: not in the probe's answer, not in a caption, not in a label.
      // `find.text` reads an EditableText's controller rather than the
      // bullets it draws, so the field itself is the one match allowed.
      expect(
        tester
            .widget<TextField>(find.byKey(SetupWhereBody.keyFieldKey))
            .obscureText,
        isTrue,
      );
      final rendered = [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          t.data ?? '',
      ];
      expect(rendered, everyElement(isNot(contains('sk-fixture'))));
    });
  });

  group('this Mac and its defaults', () {
    const big = HardwareInfo(
      chip: 'Apple M2 Max',
      memoryBytes: 64 * 1024 * 1024 * 1024,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    const small = HardwareInfo(
      chip: 'Apple M2',
      memoryBytes: 16 * 1024 * 1024 * 1024,
      appleSilicon: true,
      rosetta: false,
      osVersion: '15.6',
    );
    const inboxCaption =
        'Points naming, refresh, recap, grouping, the reply decision and '
        'drafts at Local fast and sets drafts to Only when asked.';
    const fullCaption =
        'Clears the six prose stage picks back to Local prose and sets drafts '
        'to For messages that need you.';

    const box = LlmTargetSpec(
      id: 't-1a2b3c4d',
      name: 'Studio box',
      url: 'http://localhost:18100/v1/chat/completions',
      model: 'qwen3-27b-fp8',
    );
    const builtIns = [
      LlmTargetSpec(
        id: builtInFastId,
        name: builtInFastName,
        url: 'http://localhost:8082/v1/chat/completions',
        model: 'qwen3.8',
      ),
      LlmTargetSpec(
        id: builtInProseId,
        name: builtInProseName,
        url: 'http://localhost:8080/v1/chat/completions',
        model: 'qwen3.8',
      ),
      box,
    ];

    OutlinedButton button(WidgetTester tester) =>
        tester.widget<OutlinedButton>(
          find.byKey(SettingsModelsBody.tierDefaultsKey),
        );

    testWidgets('a big Mac reads as all three models, with the full caption',
        (tester) async {
      await open(
        tester,
        wireTier: true,
        hardware: big,
        machineTier: MachineTier.full,
      );
      await expand(tester, 'Models');

      expect(
        find.text('This Mac: Apple M2 Max, 64.0 GB, runs all three models'),
        findsOneWidget,
      );
      expect(find.text(fullCaption), findsOneWidget);
      expect(button(tester).onPressed, isNotNull);
    });

    testWidgets('a 16 GB Mac reads as the inbox models, with its own caption',
        (tester) async {
      await open(
        tester,
        wireTier: true,
        hardware: small,
        machineTier: MachineTier.inbox,
      );
      await expand(tester, 'Models');

      expect(
        find.text('This Mac: Apple M2, 16.0 GB, runs the inbox models'),
        findsOneWidget,
      );
      expect(find.text(inboxCaption), findsOneWidget);
    });

    testWidgets('the button waits, disabled, while the tier is unknown',
        (tester) async {
      await open(tester, wireTier: true);
      await expand(tester, 'Models');

      // Disabled rather than absent: the button is a fact about this machine
      // and it must not appear a frame late under the reader's cursor.
      expect(button(tester).onPressed, isNull);
      expect(find.text('Reading this Mac…'), findsOneWidget);
      expect(find.textContaining('This Mac:'), findsNothing);
    });

    testWidgets('a Mac whose memory did not read gets the fact and no button',
        (tester) async {
      // `ChannelSystemInfo.hardware()` ANSWERS `HardwareInfo.unknown` when the
      // channel is missing or throws, so this state resolves like any other
      // and the tier comes back `full` by the never-refuse rule. Writing the
      // full tier's defaults off a number nobody read is exactly what must not
      // be offered.
      await open(
        tester,
        wireTier: true,
        hardware: HardwareInfo.unknown,
        machineTier: MachineTier.full,
      );
      await expand(tester, 'Models');

      expect(find.text('This Mac: memory could not be read'), findsOneWidget);
      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsNothing);
      expect(find.text(fullCaption), findsNothing);
      // Never the placeholder chip and never a bare zero.
      expect(find.textContaining('unknown,'), findsNothing);
      expect(find.textContaining('0 B'), findsNothing);
    });

    testWidgets('a hardware read that threw gets the fact and no button',
        (tester) async {
      // The rejection rather than the zero. `ChannelSystemInfo.hardware()`
      // catches a missing plugin and a `PlatformException` and answers
      // `unknown`; anything else it throws, and a channel that goes quiet
      // times out, so the hardware future rejects while the tier — read off
      // that same future — still resolves `full` by the never-refuse rule.
      // A resolved tier beside no hardware is the unreadable machine, and it
      // must not be offered a press that writes the full tier's defaults.
      await open(
        tester,
        wireTier: true,
        machineTier: MachineTier.full,
      );
      await expand(tester, 'Models');

      expect(find.text('This Mac: memory could not be read'), findsOneWidget);
      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsNothing);
      expect(find.text(fullCaption), findsNothing);
    });

    testWidgets('a host that cannot write it does not offer it',
        (tester) async {
      await open(tester, hardware: big, machineTier: MachineTier.full);
      await expand(tester, 'Models');

      expect(find.byKey(SettingsModelsBody.tierDefaultsKey), findsNothing);
      expect(find.textContaining('This Mac:'), findsNothing);
      expect(find.text(fullCaption), findsNothing);
    });

    testWidgets('one press, one call', (tester) async {
      var calls = 0;
      await open(
        tester,
        wireTier: true,
        hardware: small,
        machineTier: MachineTier.inbox,
        onApplyTierDefaults: () async => calls++,
      );
      await expand(tester, 'Models');

      final finder = find.byKey(SettingsModelsBody.tierDefaultsKey);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    /// The body directly rather than through the screen: what is under test
    /// is that the pickers re-render off the host's new map, so the host has
    /// to be one that CHANGES its map, and the screen's forty props are not
    /// what this is about.
    testWidgets('the pickers show the new picks without a reopen',
        (tester) async {
      var ids = <String, String?>{
        for (final stage in pipelineStages)
          stage.id: stage.slot == ModelSlot.embed
              ? null
              : defaultTargetIdFor(stage.slot),
        // Two stages OUTSIDE the six, seeded to something the press could
        // visibly undo. Left on their own default they would read
        // `local-fast` before and after, and "nothing else moves" would be a
        // sentence no failure could reach.
        'triage': box.id,
        'storyline_membership': box.id,
      };

      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setLocalState) => SingleChildScrollView(
              child: SettingsModelsBody(
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
                targets: builtIns,
                stageTargetIds: ids,
                onStageTargetChanged: (_, _) {},
                hardware: small,
                machineTier: MachineTier.inbox,
                // What the real host does through the prefs notifier: the
                // tier's entries over the map it already had.
                onApplyTierDefaults: () async => setLocalState(() {
                  ids = {...ids, ...tierStageDefaults(MachineTier.inbox)};
                }),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      String picked(String stageId) => tester
          .widget<DropdownButton<String>>(
            find.byKey(SettingsModelsBody.stagePickerKey(stageId)),
          )
          .value!;

      expect(picked('storyline_name'), builtInProseId);

      final finder = find.byKey(SettingsModelsBody.tierDefaultsKey);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();

      expect(picked('storyline_name'), builtInFastId);
      expect(picked('draft_reply'), builtInFastId);
      // Not one of the six: the caption names what it rewrites and nothing
      // outside that moves. Both were seeded onto the box above, so either one
      // being reset to a built-in would fail here.
      expect(picked('triage'), box.id);
      expect(picked('storyline_membership'), box.id);
    });
  });

  testWidgets('the whole section survives a doubled text scale',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester);
    await expand(tester, 'Models');

    expect(tester.takeException(), isNull);
  });
}
