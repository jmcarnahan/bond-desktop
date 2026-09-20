import 'package:bond_inbox/screens/consent_screen.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
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
    Future<ModelProbeResult> Function(String)? probe,
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
      probe: (_) async => const ModelProbeResult(reachable: true),
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
    await open(tester, probe: (url) async {
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

  testWidgets('the whole section survives a doubled text scale',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester);
    await expand(tester, 'Models');

    expect(tester.takeException(), isNull);
  });
}
