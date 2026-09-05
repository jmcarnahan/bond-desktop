/// The deterministic half of the needs-you judgement: the cases where the
/// message itself already settles the question and no model has to be asked.
///
/// Teams ingest collapses two facts into one bit. `teams_sync.dart`'s
/// `messageRow` writes `addressed_me` when an inbound chat message was sent to
/// the owner and nobody else, or when it named them — a 1:1 chat or an
/// @mention. Either way somebody typed the owner's name or opened a window
/// with only them in it, so for chat that single bit IS the floor, and no
/// second reading of the text can improve on it.
///
/// Mail's `addressed_me` is deliberately NOT part of this. It means the owner
/// was the sole To: recipient, which a mailing list, a receipt and a vendor
/// blast all satisfy — being the only address on an envelope is a hint about
/// the message, not a verdict about whether it wants an answer. Those are the
/// rows the model reads.
///
/// The floor can only RAISE the verdict, never lower it: a false here says
/// nothing at all about the message, and the judgement passes on to whoever
/// asks next. Nothing may read it as a "no".
library;

/// Whether one stored message's own row already says it needs the owner.
///
/// [row] is a `messages` row as `MessageStore.getMessageRow` returns it. The
/// flag comes back as an INTEGER — sqlite has no bool, and a STRICT column
/// holds 0 or 1 — so it is compared against 1 rather than trusted to be
/// truthy, exactly as `asksForAReply` does in `extract_handler.dart`.
bool needsYouFloor(Map<String, Object?> row) =>
    row['direction'] == 'inbound' &&
    row['source'] == 'teams' &&
    row['addressed_me'] == 1;
