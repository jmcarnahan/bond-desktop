/// The one SQL spelling of "did this message need the user", shared by the two
/// statements that have to write `message_progress.needs_you` without a Dart
/// verdict to copy: the v8 backfill and the settle sweep.
///
/// The live path does not use this. A message the notification coordinator
/// settled gets its snapshot from `notifyWorthy` — the same call that decided
/// whether to interrupt the user — because a tile that disagreed with the
/// toast it came from is the failure this whole column exists to avoid. What
/// is left for SQL is the rows the coordinator never saw: history at migration
/// time, and messages that were never admitted as candidates at all.
///
/// Written against a `messages` row aliased `m`, and reaching everything else
/// through scalar subqueries rather than joins so that both call sites can
/// drop it in unchanged — one has `messages` in its FROM, the other correlates
/// it back to a `message_progress` row being updated.
///
/// [threshold] is the SQL text of the attention floor: a bound parameter at a
/// caller that knows the user's setting, a literal at the migration, which
/// must not read preferences.
///
/// The `is_read = 0` clause has no counterpart in `notifyWorthy` and is not a
/// divergence: the coordinator's decision table suppresses a read message
/// before worthiness is ever asked, so this is where that guard has to live
/// instead.
String needsYouSql({required String threshold}) => '''
CASE WHEN (
       m.reply_expected = 1
    OR m.needs_action = 1
    OR m.urgency IN ('urgent', 'high')
    OR COALESCE(m.deadline, '') <> ''
    OR (m.triage_status = 'triaged' AND COALESCE((
         SELECT c.cta_text FROM conversations c
          WHERE c.source = m.source AND c.conversation_key = m.conversation_key
       ), '') <> '')
  )
  AND m.is_read = 0
  AND COALESCE((
        SELECT c.state FROM conversations c
         WHERE c.source = m.source AND c.conversation_key = m.conversation_key
      ), '') <> 'done'
  AND COALESCE((
        SELECT ai.bucket FROM conversation_ai ai
         WHERE ai.source = m.source AND ai.conversation_key = m.conversation_key
      ), '') <> 'later'
  AND COALESCE((
        SELECT ai.attention_score FROM conversation_ai ai
         WHERE ai.source = m.source AND ai.conversation_key = m.conversation_key
      ), 0) >= $threshold
THEN 1 ELSE 0 END''';

/// The attention floor the v8 backfill judges history against.
///
/// A literal because a migration runs before anything has read a preference,
/// and the alternative — leaving every backfilled row at 0 — would tell a user
/// upgrading that nothing had ever needed them. It is the same number
/// `AttentionTuning.defaultThreshold` carries; rows still open when the app
/// launches are restated by the first settle sweep against the real setting.
const String backfillNeedsYouThreshold = '0.5';
