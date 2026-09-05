import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/model_slot_editor.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
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
    Map<ModelSlot, LlmTarget>? targets,
    Map<ModelSlot, bool>? isDefault,
    Future<ModelProbeResult> Function(String)? probe,
    void Function(ModelSlot, {required String url, required String model})?
        onSave,
    void Function(ModelSlot)? onReset,
    bool wireModels = true,
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
          slotTargets: targets ?? slotDefaults,
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
      targets: {
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
    // The authored mapping: four bulk stages, five prose ones, one embedding.
    expect(chipsSaying(tester, 'Fast'), 4);
    expect(chipsSaying(tester, 'Prose'), 5);
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
        modelIds: ['embeddinggemma-300M'],
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
      targets: {
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

  testWidgets('the whole section survives a doubled text scale',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(tester);
    await expand(tester, 'Models');

    expect(tester.takeException(), isNull);
  });
}
