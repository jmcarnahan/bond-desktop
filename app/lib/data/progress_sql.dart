import '../services/decision/needs_you_predicate.dart';

/// The one SQL spelling of "did this message need the user", for the one
/// statement that has to write `message_progress.needs_you` without a Dart
/// answer to copy: the settle sweep.
///
/// The live path does not use this. A message the notification coordinator
/// settled gets its snapshot from `notifyWorthy` — the same call that decided
/// whether to interrupt the user — because a tile that disagreed with the
/// toast it came from is the failure this whole column exists to avoid. What
/// is left for SQL is the rows the coordinator never saw: messages that were
/// never admitted as candidates at all.
///
/// Term for term with `notifyWorthy`: the message's `needs_you_p` at or above
/// [threshold] (`needsYouAtSql`), its thread not `done`, and its thread not
/// filed `later`. The attention score orders Needs You and gates nothing, so
/// it is not here.
///
/// Written against a `messages` row aliased `m`, and reaching everything else
/// through scalar subqueries rather than joins so that the caller can drop it
/// in unchanged — it correlates back to a `message_progress` row being
/// updated.
///
/// [threshold] is the SQL text of the owner's Needs You slider, a bound
/// parameter.
///
/// The `is_read = 0` clause has no counterpart in `notifyWorthy` and is not a
/// divergence: the coordinator's decision table suppresses a read message
/// before worthiness is ever asked, so this is where that guard has to live
/// instead.
String needsYouSql({required String threshold}) => '''
CASE WHEN ${needsYouAtSql('m.needs_you_p', threshold)}
  AND m.is_read = 0
  AND COALESCE((
        SELECT c.state FROM conversations c
         WHERE c.source = m.source AND c.conversation_key = m.conversation_key
      ), '') <> 'done'
  AND COALESCE((
        SELECT ai.bucket FROM conversation_ai ai
         WHERE ai.source = m.source AND ai.conversation_key = m.conversation_key
      ), '') <> 'later'
THEN 1 ELSE 0 END''';

/// The v8 backfill's needs-you SQL, FROZEN: `from7To8` in `database.dart`
/// interpolates it and nothing else may.
///
/// That migration replays on every v1..v7 database a newer build opens, and
/// it must bring one up to the `message_progress` every earlier build
/// produced, so this text never follows the live rule ([needsYouSql]). It
/// predates the needs-you columns entirely — `needs_you_verdict` arrived in
/// v10 and `needs_you_p` in v21 — and reads only triage's asks against the
/// attention floor, which is what needs you meant at v8.
/// `progress_sql_test` pins it byte for byte.
String needsYouSqlV8Frozen(String threshold) => '''
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

/// The attention floor the v8 backfill judges history against — the v8
/// backfill's floor ONLY ([needsYouSqlV8Frozen]); nothing live reads it.
///
/// A literal because a migration runs before anything has read a preference,
/// and the alternative — leaving every backfilled row at 0 — would tell a user
/// upgrading that nothing had ever needed them. It was the attention slider's
/// default when v8 shipped; rows still open when the app launches are restated
/// by the first settle sweep against the owner's Needs You slider.
const String backfillNeedsYouThreshold = '0.5';
