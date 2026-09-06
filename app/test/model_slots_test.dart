import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/services/llm/needs_you_task.dart';
import 'package:bond_inbox/services/llm/reply_decision_task.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The authored stage table, held against the pipeline it claims to describe.
///
/// Nothing at runtime can be asked which slot a stage uses — the mapping is
/// decided when the providers are built and there is no per-call router — so
/// the settings screen reads a hand-written table. These tests are the only
/// thing keeping that table honest: a task shipped without a row, a row for a
/// stage that no longer runs, or a stage quietly moved between servers all
/// fail here rather than in a screen nobody re-reads.

/// The `schemaName` of every task that makes a model call, built from real
/// instances so a renamed schema fails this file rather than drifting.
Set<String> taskSchemaNames() => {
      const TriageTask().schemaName,
      const NeedsYouTask().schemaName,
      const ExtractTask().schemaName,
      const ConfirmMembershipTask().schemaName,
      const NameStorylineTask().schemaName,
      const RefineStorylineTask().schemaName,
      const StorylineRecapTask().schemaName,
      const ReplyDecisionTask().schemaName,
      const DraftTask().schemaName,
    };

void main() {
  test('every stage that dials a model is in the table', () {
    final ids = pipelineStages.map((stage) => stage.id).toList();

    for (final name in taskSchemaNames()) {
      expect(ids.where((id) => id == name), hasLength(1), reason: name);
    }
  });

  test('the table has no stage the pipeline does not run', () {
    final names = taskSchemaNames();

    for (final stage in pipelineStages) {
      // Embeddings send no chat schema — they are the one row with no task
      // behind them, and the only exception this containment allows.
      if (stage.slot == ModelSlot.embed) {
        expect(stage.id, 'embeddings');
        continue;
      }
      expect(names, contains(stage.id), reason: stage.id);
    }
  });

  test('each stage names the slot its provider wires', () {
    Set<String> idsOn(ModelSlot slot) => {
          for (final stage in pipelineStages)
            if (stage.slot == slot) stage.id,
        };

    // Literals, not a derivation: moving a stage between slots must force an
    // edit here, and therefore an edit to docs/pipeline/10-model-routing.md.
    expect(idsOn(ModelSlot.fast), {
      'triage',
      'needs_you',
      'extraction',
      'storyline_membership',
    });
    expect(idsOn(ModelSlot.prose), {
      'storyline_name',
      'storyline_refresh',
      'storyline_recap',
      'reply_decision',
      'draft_reply',
    });
    expect(idsOn(ModelSlot.embed), {'embeddings'});
  });

  test('ids are unique and labels are non-empty', () {
    final ids = pipelineStages.map((stage) => stage.id).toList();
    expect(ids.toSet(), hasLength(ids.length));

    for (final stage in pipelineStages) {
      expect(stage.label, isNotEmpty, reason: stage.id);
      expect(stage.description, isNotEmpty, reason: stage.id);
    }
  });

  test('the slot defaults are the compiled constants', () {
    expect(fastSlotDefault.baseUrl, LlmClient.fastBaseUrl);
    expect(fastSlotDefault.model, LlmClient.fastModel);
    expect(proseSlotDefault.baseUrl, LlmClient.defaultBaseUrl);
    expect(proseSlotDefault.model, LlmClient.defaultModel);
    expect(embedSlotDefault.baseUrl, EmbeddingsClient.defaultBaseUrl);
    expect(embedSlotDefault.model, EmbeddingsClient.modelTag);

    // Two servers is the point — one slot accidentally aliasing the other
    // would route every label back onto the 27B.
    expect(fastSlotDefault, isNot(proseSlotDefault));
    expect(slotDefaults[ModelSlot.fast], fastSlotDefault);
    expect(slotDefaults[ModelSlot.prose], proseSlotDefault);
    expect(slotDefaults[ModelSlot.embed], embedSlotDefault);
  });
}
