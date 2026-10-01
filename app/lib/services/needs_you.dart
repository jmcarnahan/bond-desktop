/// One fact about a message that settles something before any model does.
///
/// Teams ingest collapses two facts into one bit. `teams_sync.dart`'s
/// `messageRow` writes `addressed_me` when an inbound chat message was sent to
/// the owner and nobody else, or when it named them — a 1:1 chat or an
/// @mention. Either way somebody typed the owner's name or opened a window
/// with only them in it, and [needsYouFloor] is that bit read as a row
/// predicate. It no longer raises a needs-you answer (the decision model's
/// probability against the owner's slider is the one rule for that); what it
/// still does is keep the learned gate off such a message in the triage pass.
///
/// Mail's `addressed_me` is deliberately NOT part of this. It means the owner
/// was the sole To: recipient, which a mailing list, a receipt and a vendor
/// blast all satisfy — being the only address on an envelope is a hint about
/// the message, not a verdict about whether it wants an answer.
library;

/// Whether one stored message's own row says somebody wrote to the owner by
/// name: a Teams 1:1 or @mention.
///
/// [row] is a `messages` row as `MessageStore.getMessageRow` returns it. The
/// flag comes back as an INTEGER — sqlite has no bool, and a STRICT column
/// holds 0 or 1 — so it is compared against 1 rather than trusted to be
/// truthy, exactly as `asksForAReply` does in `extract_handler.dart`.
///
bool needsYouFloor(Map<String, Object?> row) =>
    row['direction'] == 'inbound' &&
    row['source'] == 'teams' &&
    row['addressed_me'] == 1;
