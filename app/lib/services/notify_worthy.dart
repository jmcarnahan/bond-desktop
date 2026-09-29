import 'decision/needs_you_predicate.dart';

/// Whether this message is worth interrupting for: it needs the owner, and
/// its thread is still open and not deferred.
///
/// Top-level and public because it is asked twice about one message and the
/// two answers have to be the same answer. The sweep asks it to decide whether
/// to notify; the settle then asks it for the `needs_you` snapshot the home
/// screen shows. Two copies would drift, and the symptom is the tile
/// disagreeing with the toast it came from.
///
/// The ask is ONE predicate: the message's `needs_you_p`, the decision
/// model's probability that it needs the owner, at or above the owner's
/// slider ([needsYouAt]). Nothing else asks: not triage's `reply_expected` or
/// action item, not an urgency word, not a deadline, not the thread's CTA, and
/// the attention score, which orders Needs You, gates nothing. A NULL
/// probability is a message not decided yet, which needs nobody; a message
/// settled before it is decided is corrected by `refreshNeedsYou` when it is.
///
/// The thread half is the owner's own filing: a `done` thread and one filed
/// `later` interrupt nobody, whatever the probability says.
///
/// Read state is not asked about here, because a read message never reaches
/// this: [NotificationCoordinator]'s decision table suppresses it first.
/// `needsYouSql`, which judges the rows this never sees, has to carry that
/// guard itself.
bool notifyWorthy(Map<String, Object?> row, {required double threshold}) =>
    needsYouAt((row['needs_you_p'] as num?)?.toDouble(), threshold) &&
    row['conversation_state'] != 'done' &&
    row['bucket'] != 'later';

/// Whether the conversation's CTA fields are this message's own words.
///
/// They describe the newest message of the thread whose TEXT has landed, so
/// only a candidate whose own triage finished AND whose message-text stage
/// wrote its summary may be quoted by them. Triage writes the row from the
/// decision model and leaves the thread's older ask in place until the text
/// refolds it; a triaged row with no summary is not yet the owner of that ask.
/// (Rows triaged before the decision model carry their summary, so they are
/// unaffected.)
///
/// The toast asks this before it QUOTES the CTA, so a notification naming THIS
/// message never quotes another message's ask.
bool ownsCta(Map<String, Object?> row) =>
    row['triage_status'] == 'triaged' && row['summary'] != null;
