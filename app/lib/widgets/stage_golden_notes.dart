/// One measured line per stage where the ledger has one, shown under the
/// stage's picker so a person choosing a target sees what the two model sizes
/// scored. Numbers and model sizes only, never a corpus word.
///
/// The numbers come from `docs/model-bakeoff.md`'s golden-set ledger. They are
/// const rather than read from a run file on purpose: a settings screen must
/// not depend on the golden set existing on the machine, and the golden set is
/// real mail — the one thing that may never reach a widget. What survives the
/// trip is the score, which is a count.
///
/// A stage with no row here renders no note at all. That is the honest state
/// for a stage the ledger has never measured, and it is why this is a sparse
/// map rather than a row per `pipelineStages` entry.
const Map<String, String> stageGoldenNotes = {
  'triage': 'Golden set: category 89 on the local 4B, 92 on the 27B',
  'needs_you': 'Golden set: verdict 92 on the local 4B, 93 on the 27B',
  'extraction': 'Golden set: intent 75 on the local 4B, 86 on the 27B',
  'storyline_membership':
      'Golden set: 84 of 98 on the local 4B, 83 of 98 on the GPU 27B',
  'reply_decision': 'Golden set: 64 on the local 4B, 82 on the 27B',
  'draft_reply': 'Golden set: 6 of 25 on the local 27B, 17 of 25 on Opus 5',
  'draft_improve': 'Golden set: 6 of 25 on the local 27B, 17 of 25 on Opus 5',
};
