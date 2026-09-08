/// Whether this message is worth interrupting for: a message-level ask AND a
/// thread-level volume, never one of the two.
///
/// Top-level and public because it is asked twice about one message and the
/// two answers have to be the same answer. The sweep asks it to decide whether
/// to notify; the settle then asks it for the `needs_you` snapshot the home
/// screen shows. Two copies would drift, and the symptom is the tile
/// disagreeing with the toast it came from.
///
/// BOTH halves are required, and they answer different questions. The ask
/// says the message wants something from the reader. The volume says the
/// user wants to hear about this thread at all — the attention threshold and
/// the `later` bucket are their ONE loudness control, and an ask that
/// bypassed them would take the control away exactly when it matters.
/// Volume alone is worse still: a high score is a ranking, not a request, so
/// firing on it would announce every unread message of every decent thread
/// and invert the app into the notification stream it exists to replace.
/// Either half alone is a notification the user did not sign up for.
///
/// `== 1` comparisons only, never truthiness: `reply_expected` NULL means
/// "no v2 pass has judged this", which is not a "no". Reading NULL as 0
/// would turn every un-judged message into a decided negative.
///
/// Every ask below is the message's own except `cta_text`, which lives on the
/// CONVERSATION and belongs to whichever message was triaged into it last.
/// The thread's CTA therefore testifies for this message only when this
/// message's own triage wrote it: `triaged` is the one status whose pass
/// rewrote the conversation's CTA fields. Counted for a candidate still
/// `pending` at its deadline, or one whose triage ended in `error`, it is
/// another message's ask — and the toast that followed named THIS message
/// while quoting THAT one.
///
/// Read state is not asked about here, because a read message never reaches
/// this: [NotificationCoordinator]'s decision table suppresses it first.
/// `needsYouSql`, which judges the rows this never sees, has to carry that
/// guard itself.
///
/// `needs_you_verdict` is an ask in its own right, and the only one that was
/// decided about THIS message as a whole rather than inferred from a field:
/// the needs-you stage wrote it either from the deterministic Teams floor or
/// from a confident model yes, so a 1 here is already the considered answer to
/// "does this want the owner". It is the ASK HALF ONLY. The volume half below
/// is untouched by it — the attention threshold, the `later` bucket and the
/// `done` state still gate a judged yes exactly as they gate every other ask,
/// because the user's one loudness control does not get an exception carved
/// into it for the newest stage. NULL and 0 add nothing, per the `== 1` rule
/// above: never judged is not a yes, and judged no is not a veto either — the
/// other asks stand on their own.
bool notifyWorthy(Map<String, Object?> row, {required double threshold}) {
  final ask = _int(row['needs_you_verdict']) == 1 ||
      _int(row['reply_expected']) == 1 ||
      _int(row['needs_action']) == 1 ||
      row['urgency'] == 'urgent' ||
      row['urgency'] == 'high' ||
      (row['deadline'] as String? ?? '').isNotEmpty ||
      (ownsCta(row) && (row['cta_text'] as String? ?? '').isNotEmpty);
  final score = (row['attention_score'] as num?)?.toDouble() ?? 0;
  return ask &&
      row['conversation_state'] != 'done' &&
      row['bucket'] != 'later' &&
      score >= threshold;
}

/// Whether the conversation's CTA fields are this message's own words.
///
/// They describe the newest TRIAGED message of the thread, so only a
/// candidate whose own triage finished may be judged — or quoted — by them.
///
/// Public alongside [notifyWorthy] and for its reason: the settle asks this to
/// decide whether the CTA is an ask, and then asks it again to decide whether
/// the toast may QUOTE that CTA. A second copy would eventually let one answer
/// yes and the other no about the same message.
bool ownsCta(Map<String, Object?> row) => row['triage_status'] == 'triaged';

int? _int(Object? value) => (value as num?)?.toInt();
