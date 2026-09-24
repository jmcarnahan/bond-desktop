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
///
/// [suppressed] is the one thing allowed to switch the floor off, and it exists
/// for exactly one caller: a standing label rule (`LabelRule`) whose
/// `unless_mentions_me` is OFF. That flag is the owner saying "this kind of mail,
/// even when it names me" — a chat they have decided they are done with, where
/// being addressed is precisely what every message in it does. Leaving the floor
/// in place there would make the rule inert and give no way to express the
/// choice. It is a parameter rather than a second function because the rule is
/// still "the row decides", with the owner's one exception written on top, and
/// two functions would drift.
///
/// [coldOutreach] is the second and last thing allowed to switch the floor off,
/// and it is a RANKING rather than an instruction: see [isColdOutreach]. A
/// stranger's first approach does not get a floor handed to it by the envelope it
/// arrived in; it earns the rail through what the message says, or it sits in the
/// inbox like every other thread. It is a separate parameter from [suppressed]
/// because the two are different facts with different owners — one is the owner's
/// standing word about a class of mail, the other is arithmetic on an address and
/// a thread's own history — and a caller reading a single flag would eventually
/// pass the wrong one.
///
/// Read this as the floor NOT SPEAKING rather than as a "no": a false here still
/// says nothing about the message, and the judgement still passes on.
bool needsYouFloor(
  Map<String, Object?> row, {
  bool suppressed = false,
  bool coldOutreach = false,
}) =>
    !suppressed &&
    !coldOutreach &&
    row['direction'] == 'inbound' &&
    row['source'] == 'teams' &&
    row['addressed_me'] == 1;

/// Whether this thread is a STRANGER'S FIRST APPROACH: a sender from outside the
/// owner's organisation, on a conversation the owner has never written on.
///
/// The case is unsolicited vendor and analyst outreach. One of them landed in
/// Needs You marked `Needs reply` with a suggested reply already written, beside
/// a colleague's actual question — because the envelope said the owner was the
/// only recipient and the body politely asked them to confirm a meeting. Every
/// signal a cold approach is BUILT to produce.
///
/// BOTH halves are required, and the second is what keeps this from being a
/// rule about outsiders. Customers, counsel, candidates and suppliers the owner
/// works with every week are all external, and their mail is some of the most
/// important the inbox carries; what marks an approach as cold is that the owner
/// has never answered this thread. [lastOutboundAt] is the conversation's own
/// `last_outbound_at` — a fact the row already carries, deliberately rather than
/// a sender-history query, because a per-item lookup of "have I ever written to
/// this address" is a scan the verdict path has no budget for and answers a
/// wider question than this one asks.
///
/// It is not a drop and it is not a verdict. The thread stays in the inbox, the
/// model still reads it, and a real ask still raises it — all this withholds is
/// the free pass.
bool isColdOutreach({required bool external, String? lastOutboundAt}) =>
    external && (lastOutboundAt?.trim() ?? '').isEmpty;
