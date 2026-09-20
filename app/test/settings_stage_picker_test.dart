import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/settings_models_body.dart';
import 'package:bond_inbox/widgets/stage_golden_notes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The per-stage picker: which stages get one, what a pick writes, and the one
/// pick that asks a question first.
///
/// Driven through `SettingsModelsBody` rather than the whole screen, because
/// the body is where the rule lives: a third-party target on a DRAFT stage is
/// the only combination that goes to the consent pane instead of to the store.

const _box = LlmTargetSpec(
  id: 't-1a2b3c4d',
  name: 'Studio box',
  url: 'http://localhost:18100/v1/chat/completions',
  model: 'qwen3-27b-fp8',
  parallel: 4,
);

const _bedrock = LlmTargetSpec(
  id: 't-99887766',
  name: 'Bedrock Opus',
  url: 'https://bedrock-runtime.us-east-2.amazonaws.com/',
  model: 'us.example.opus',
  wire: LlmWire.bedrockConverse,
);

const _fast = LlmTargetSpec(
  id: builtInFastId,
  name: builtInFastName,
  url: 'http://localhost:8082/v1/chat/completions',
  model: 'qwen3-4b',
);

const _prose = LlmTargetSpec(
  id: builtInProseId,
  name: builtInProseName,
  url: 'http://localhost:8080/v1/chat/completions',
  model: 'qwen3-27b',
);

const _all = [_fast, _prose, _box, _bedrock];

void main() {
  late List<(String, String?)> writes;
  late List<(String, String)> asked;

  setUp(() {
    writes = [];
    asked = [];
  });

  Future<void> open(
    WidgetTester tester, {
    List<PipelineStageInfo> stages = pipelineStages,
    Map<String, String?> stageTargetIds = const {},
    bool consent = false,
    bool wirePickers = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsModelsBody(
            slotTargets: slotDefaults,
            isDefault: const {
              ModelSlot.fast: true,
              ModelSlot.prose: true,
              ModelSlot.embed: true,
            },
            compiledDefaults: slotDefaults,
            stages: stages,
            onSave: (_, {required url, required model}) {},
            onReset: (_) {},
            targets: _all,
            stageTargetIds: stageTargetIds,
            cloudDraftsConsent: consent,
            onStageTargetChanged:
                wirePickers ? (stage, target) => writes.add((stage, target)) : null,
            onConsentNeeded: (stage, target) => asked.add((stage, target.id)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Opens one stage's picker and chooses the item with [label] on it.
  ///
  /// The label appears twice once the menu is up — on the closed button and in
  /// the overlay — so the last one is the item.
  Future<void> pick(WidgetTester tester, String stageId, String label) async {
    final picker = find.byKey(SettingsModelsBody.stagePickerKey(stageId));
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// The one stage in the table with no picker, and the reason is the vectors:
  /// they carry a corpus tag, so there is nothing to choose between.
  testWidgets('every stage but embeddings gets a picker', (tester) async {
    await open(tester);

    for (final stage in pipelineStages) {
      final picker = find.byKey(SettingsModelsBody.stagePickerKey(stage.id));
      if (stage.slot == ModelSlot.embed) {
        expect(picker, findsNothing, reason: '${stage.id} should have no picker');
      } else {
        expect(picker, findsOneWidget, reason: '${stage.id} is missing a picker');
      }
    }
  });

  testWidgets('an unwired host keeps the chips it always had', (tester) async {
    await open(tester, wirePickers: false);

    for (final stage in pipelineStages) {
      expect(find.byKey(SettingsModelsBody.stagePickerKey(stage.id)), findsNothing);
    }
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  testWidgets('a pick moves one stage and leaves the rest alone',
      (tester) async {
    await open(tester);

    await pick(tester, 'storyline_name', 'Studio box');

    expect(writes, [('storyline_name', _box.id)]);
  });

  testWidgets('an optional stage offers None and reports it as null',
      (tester) async {
    await open(
      tester,
      stages: const [
        PipelineStageInfo(
          id: 'draft_improve',
          label: 'Improve a draft',
          description: 'A second pass over a suggested reply',
          slot: ModelSlot.prose,
          optional: true,
        ),
      ],
      stageTargetIds: const {'draft_improve': builtInProseId},
    );

    await pick(tester, 'draft_improve', 'None');

    expect(writes, [('draft_improve', null)]);
  });

  testWidgets('the ledger note sits under the stages it was measured on',
      (tester) async {
    await open(tester);

    expect(
      find.text('Golden set: 64 on the local 4B, 82 on the 27B'),
      findsOneWidget,
    );
    // Two stages share the draft line, and both render it.
    expect(
      find.text('Golden set: 6 of 25 on the local 27B, 17 of 25 on Opus 5'),
      findsNWidgets(2),
    );
    // A stage the ledger never measured gets no line rather than a blank one.
    final brief = find.ancestor(
      of: find.text('Directory brief'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: brief, matching: find.textContaining('Golden set:')),
      findsNothing,
    );
  });

  group('third-party drafts', () {
    testWidgets('a draft stage asks before it writes', (tester) async {
      await open(tester);

      await pick(tester, 'draft_reply', 'Bedrock Opus');

      expect(asked, [('draft_reply', _bedrock.id)]);
      expect(writes, isEmpty);
    });

    testWidgets('with consent already given it just writes', (tester) async {
      await open(tester, consent: true);

      await pick(tester, 'draft_reply', 'Bedrock Opus');

      expect(asked, isEmpty);
      expect(writes, [('draft_reply', _bedrock.id)]);
    });

    testWidgets('a tunnel on loopback is not a third party', (tester) async {
      await open(tester);

      await pick(tester, 'draft_reply', 'Studio box');

      expect(asked, isEmpty);
      expect(writes, [('draft_reply', _box.id)]);
    });

    testWidgets('a stage that is not a draft never asks', (tester) async {
      await open(tester);

      await pick(tester, 'triage', 'Bedrock Opus');

      expect(asked, isEmpty);
      expect(writes, [('triage', _bedrock.id)]);
    });
  });

  /// A gated pick is the one state where the row NAMES one target and the app
  /// dials another, so the row has to say so: `specForStage` sends a
  /// third-party draft target back to the local one until the consent stands.
  group('the gated caption', () {
    Finder gated(String stageId) =>
        find.byKey(SettingsModelsBody.stageGatedKey(stageId));

    testWidgets('says where a gated draft stage actually goes', (tester) async {
      await open(tester, stageTargetIds: const {'draft_reply': 't-99887766'});

      expect(gated('draft_reply'), findsOneWidget);
      expect(
        find.text('Sends to $builtInProseName until you allow cloud drafts'),
        findsOneWidget,
      );
    });

    testWidgets('goes away once the consent stands', (tester) async {
      await open(
        tester,
        stageTargetIds: const {'draft_reply': 't-99887766'},
        consent: true,
      );

      expect(gated('draft_reply'), findsNothing);
    });

    testWidgets('never appears for a loopback target', (tester) async {
      await open(tester, stageTargetIds: const {'draft_reply': 't-1a2b3c4d'});

      expect(gated('draft_reply'), findsNothing);
    });

    testWidgets('never appears on a stage that is not a draft', (tester) async {
      await open(tester, stageTargetIds: const {'triage': 't-99887766'});

      expect(gated('triage'), findsNothing);
    });
  });

  testWidgets('a stored id nothing carries falls back without throwing',
      (tester) async {
    await open(
      tester,
      stages: const [
        PipelineStageInfo(
          id: 'triage',
          label: 'Triage',
          description: 'Urgency, category, summary, action items',
          slot: ModelSlot.fast,
        ),
      ],
      stageTargetIds: const {'triage': 't-removed0'},
    );

    expect(tester.takeException(), isNull);
    final picker = tester.widget<DropdownButton<String>>(
      find.byKey(SettingsModelsBody.stagePickerKey('triage')),
    );
    expect(picker.value, builtInFastId);
  });

  /// The notes are a const table in `lib/`, and this is the only thing keeping
  /// it honest: a key nothing renders under would be a silent omission, and a
  /// value carrying an address or a link would be corpus leaking onto a
  /// settings screen in a public repo.
  test('every golden note names a real stage and carries numbers only', () {
    final ids = {for (final stage in pipelineStages) stage.id};
    for (final entry in stageGoldenNotes.entries) {
      expect(ids, contains(entry.key));
      for (final forbidden in ['@', 'http', '.com', '\n']) {
        expect(
          entry.value.contains(forbidden),
          isFalse,
          reason: '${entry.key} carries "$forbidden"',
        );
      }
    }
  });
}
