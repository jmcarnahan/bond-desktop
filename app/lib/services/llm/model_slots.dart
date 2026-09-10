import 'package:flutter/foundation.dart' show immutable;

import 'embeddings_client.dart';

/// Which of the three local servers a piece of work goes to.
///
/// [embed] is here so the settings screen can DISPLAY it beside the other two.
/// It is deliberately not switchable: stored vectors carry a hardcoded model
/// tag ([EmbeddingsClient.modelTag]), so a swapped embedding model would
/// silently compare vectors from two different spaces.
enum ModelSlot { fast, prose, embed }

/// Where one slot points and what it calls the model there.
///
/// A value, not a client: it is what a resolver returns and what the prefs
/// compose, and holding it apart from `LlmClient` is what lets the URL and the
/// model name change together, atomically, between two requests.
@immutable
class LlmTarget {
  final String baseUrl;
  final String model;

  const LlmTarget({required this.baseUrl, required this.model});

  @override
  bool operator ==(Object other) =>
      other is LlmTarget && other.baseUrl == baseUrl && other.model == model;

  @override
  int get hashCode => Object.hash(baseUrl, model);

  @override
  String toString() => '$model @ $baseUrl';
}

/// The prose slot's compiled defaults (`--dart-define=LLAMA_URL=…`,
/// `LLAMA_MODEL=…`). Moved here from `LlmClient` so this file can build const
/// targets from them without importing upward; `LlmClient.defaultBaseUrl` and
/// friends are now const aliases of these, and every existing reference to
/// those names keeps working.
const String proseUrlDefault = String.fromEnvironment(
  'LLAMA_URL',
  defaultValue: 'http://localhost:8080/v1/chat/completions',
);
const String proseModelDefault =
    String.fromEnvironment('LLAMA_MODEL', defaultValue: 'qwen3.8');

/// The bulk slot's compiled defaults — its own server (`make fast`), its own
/// name, because an MLX-style runtime routes on the model field.
const String fastUrlDefault = String.fromEnvironment(
  'FAST_LLAMA_URL',
  defaultValue: 'http://localhost:8082/v1/chat/completions',
);
const String fastModelDefault =
    String.fromEnvironment('FAST_LLAMA_MODEL', defaultValue: 'qwen3.8');

const LlmTarget proseSlotDefault =
    LlmTarget(baseUrl: proseUrlDefault, model: proseModelDefault);
const LlmTarget fastSlotDefault =
    LlmTarget(baseUrl: fastUrlDefault, model: fastModelDefault);

/// Display only — nothing resolves through it. The "model" is the corpus tag
/// the vectors were written under, not a name any request carries.
const LlmTarget embedSlotDefault = LlmTarget(
  baseUrl: EmbeddingsClient.defaultBaseUrl,
  model: EmbeddingsClient.modelTag,
);

const Map<ModelSlot, LlmTarget> slotDefaults = {
  ModelSlot.fast: fastSlotDefault,
  ModelSlot.prose: proseSlotDefault,
  ModelSlot.embed: embedSlotDefault,
};

/// One pipeline stage, as the settings screen names it.
///
/// AUTHORED, not derived. The stage→slot mapping is decided in
/// `app_providers.dart` at construction and there is no per-call router, so
/// nothing at runtime can be asked which slot a stage uses. This table is the
/// app telling the user what that wiring is, and `model_slots_test.dart` is
/// what keeps it honest against the handler list.
@immutable
class PipelineStageInfo {
  /// The `schemaName` the task sends, where the stage makes a model call —
  /// which is also what lands in an activity row's `llm_label`.
  final String id;

  final String label;
  final String description;
  final ModelSlot slot;

  const PipelineStageInfo({
    required this.id,
    required this.label,
    required this.description,
    required this.slot,
  });
}

/// Every stage that dials a model, in pipeline order — the order of
/// `docs/pipeline/README.md`'s stage table.
const List<PipelineStageInfo> pipelineStages = [
  PipelineStageInfo(
    id: 'triage',
    label: 'Triage',
    description: 'Urgency, category, summary, action items',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'needs_you',
    label: 'Needs-you verdict',
    description: 'Whether a message wants the owner',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'extraction',
    label: 'Extraction',
    description: 'Evidence, topics, people, intent, importance',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'attachment_digest',
    label: 'Attachment digest',
    description: 'What an attached document is, and what it asks for',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'context_file_digest',
    label: 'Directory file digest',
    description: 'What one file in a registered directory is for, and what '
        'it found',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'context_brief',
    label: 'Directory brief',
    description: 'The standing notes and file map of a directory, compiled '
        'for replies',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'storyline_membership',
    label: 'Storyline membership',
    description: 'Whether a thread belongs to a storyline',
    slot: ModelSlot.fast,
  ),
  PipelineStageInfo(
    id: 'storyline_name',
    label: 'Storyline naming',
    description: 'The title and summary a group is given',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'storyline_refresh',
    label: 'Storyline refresh',
    description: 'Re-reading a group as it grows',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'storyline_recap',
    label: 'Storyline recap',
    description: 'Where the story stands right now',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'reply_decision',
    label: 'Reply decision',
    description: 'Whether a message needs an answer at all',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'draft_reply',
    label: 'Draft generation',
    description: 'The suggested reply itself',
    slot: ModelSlot.prose,
  ),
  PipelineStageInfo(
    id: 'embeddings',
    label: 'Embeddings and search',
    description: 'Clustering and per-message search vectors',
    slot: ModelSlot.embed,
  ),
];
