import 'package:bond_inbox/data/progress_sql.dart';
import 'package:flutter_test/flutter_test.dart';

/// The v8 backfill's needs-you SQL, byte for byte.
///
/// `from7To8` interpolates it, and that migration replays on every v1..v7
/// database a newer build opens, so the text it ran with is frozen: a change
/// here would bring an old database up to a different `message_progress` than
/// the one every earlier build produced. The live rule moved to the decision
/// model's probability; this copy never follows it.
void main() {
  test('the v8 backfill SQL is frozen', () {
    expect(needsYouSqlV8Frozen(backfillNeedsYouThreshold), _frozenV8);
  });
}

const _frozenV8 = r'''
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
      ), 0) >= 0.5
THEN 1 ELSE 0 END''';
