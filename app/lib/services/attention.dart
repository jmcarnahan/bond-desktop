import 'dart:math' as math;

import '../models/message_models.dart';

/// The ranking and deferral rules, as pure functions over one thread.
///
/// Nothing here reads a database, a clock, or a preference store — every input
/// arrives as an argument, including `now`. That is what makes the numbers
/// testable and, more importantly, explainable: when a thread sits at the top
/// of Needs You, the reason is a short chain of constants a person can read,
/// not a model whose answer changed overnight.
///
/// Both functions are total. There is no input — a missing timestamp, an
/// unknown intent, a sender nobody has ruled on — that throws or returns null
/// where a number is expected. Mail with bad metadata still has to rank
/// somewhere, and "somewhere reasonable" beats "nowhere".

/// Every number the scorer uses, in one place.
///
/// They are constants rather than settings on purpose. The one thing the user
/// tunes is the THRESHOLD — how much reaches Needs You — and leaving the
/// weights fixed means the ordering the user learns to trust does not change
/// under them when they move that slider.
class AttentionTuning {
  /// A thread awaiting the user's reply. The unit everything else is relative to.
  static const double needsReplyBase = 1.0;

  /// A thread waiting on someone else. It can still climb — an urgent ask on a
  /// thread the user already answered is worth seeing — but it starts well below
  /// anything that is actually theirs to move.
  static const double waitingBase = 0.35;

  static const double urgentMultiplier = 1.5;
  static const double highMultiplier = 1.2;

  /// Added when the newest inbound message actually asks for something. Small:
  /// it separates two otherwise-equal threads, it does not promote a quiet one
  /// past a loud one.
  static const double questionBonus = 0.25;

  /// The most a sender's answer rate can add. Deliberately the smallest term
  /// here — it is derived from a rough count (see
  /// `MessageStore.senderReplyRates`) and should never decide anything on its
  /// own.
  static const double replyRateMax = 0.2;

  /// A week-old thread scores half what the same thread scored when it landed.
  /// Slow enough that Friday's mail still matters on Monday, fast enough that a
  /// month-old thread stops crowding out this morning's.
  static const double recencyHalfLifeDays = 7;

  /// The default cut for Needs You, when the user has not moved the slider.
  static const double defaultThreshold = 0.5;

  /// The most rows Needs You shows at once. A ranked list only helps if it is
  /// short enough to read in one glance; past this the rail offers a "+N more"
  /// into the full section rather than growing.
  static const int topCount = 7;

  /// Ceiling for [attentionScore]. Nothing needs to be more than twice as loud
  /// as a plain needs-reply thread, and a bounded range is what lets the
  /// threshold slider mean the same thing from one mailbox to the next.
  static const double maxScore = 2.0;

  /// What a `keep` sender's mail is multiplied by. A boost rather than a floor:
  /// the user said this sender matters, not that every message from them is
  /// urgent, and a floor would rank a two-month-old newsletter above this
  /// morning's real question.
  static const double keepBoost = 1.25;

  /// What a message addressed to the user singularly is multiplied by. The
  /// product rule it encodes: a message sent to them alone, or that @mentions
  /// them by name, gets particular attention — it is never the one that gets
  /// missed. A boost rather than a floor, for the same reason [keepBoost] is:
  /// being addressed directly does not make a three-week-old thread today's
  /// work.
  static const double directBoost = 1.25;

  /// The intents that count as the sender asking for something.
  static const Set<String> askingIntents = {'question', 'request', 'approval'};

  /// The intents that make a low-importance message deferrable.
  static const Set<String> quietIntents = {'fyi', 'transactional'};
}

/// How loudly one thread is asking for the user, from 0 to
/// [AttentionTuning.maxScore].
///
/// The chain, in order:
/// 1. A `later` sender rule, or a thread the user closed, scores exactly 0. Both
///    are a person having already answered the question this function asks.
/// 2. A base by state: [AttentionTuning.needsReplyBase] for a thread awaiting
///    their reply, [AttentionTuning.waitingBase] for anything else still open —
///    and also for a QUIET FYI, a needs-reply thread triage judged nobody is
///    waiting on. See below.
/// 3. Multiplied by the ask's urgency, as triage read it.
/// 4. Plus [AttentionTuning.questionBonus] when the newest inbound message's
///    intent is one of [AttentionTuning.askingIntents].
/// 5. Plus up to [AttentionTuning.replyRateMax] for a sender the user answers —
///    skipped entirely on a quiet FYI.
/// 6. Multiplied by recency, halving every
///    [AttentionTuning.recencyHalfLifeDays].
/// 7. Multiplied by [AttentionTuning.keepBoost] for a `keep` sender.
/// 8. Multiplied by [AttentionTuning.directBoost] when the message was
///    addressed to the user singularly — or the needs-you stage judged it a
///    real ask — and nothing said no reply is wanted.
/// 9. Clamped.
///
/// **The quiet temper (steps 2 and 5).** A thread can sit in `needsReply`
/// because the state machine saw an unanswered inbound message, while triage
/// read that message and found nobody actually waiting: a broadcast to a group
/// chat, a receipt, a heads-up. Such a thread scores from
/// [AttentionTuning.waitingBase] instead, and skips the reply-rate bonus. The
/// skip is the load-bearing half: the answer-rate nudge exists to ORDER live
/// asks against each other, and 0.35 + 0.2 = 0.55 would carry a well-answered
/// sender's quiet FYI straight back over the 0.5 threshold — the exact thread
/// the temper exists to quiet. The question bonus needs no such guard, because
/// [AttentionTuning.askingIntents] and [AttentionTuning.quietIntents] are
/// disjoint: an intent that tempers can never be an intent that earns it.
///
/// The urgency multiplier still applies through the temper, deliberately. A
/// thread triage rated urgent survives it (0.35 × 1.5 = 0.525) and stays in
/// Needs You — showing one quiet thread too many is the failure this is willing
/// to have.
///
/// [latestReplyExpected] false is a POSITIVE judgment and the only thing that
/// tempers. Null means triage v2 never looked at this message, which is not the
/// same as it having looked and said no — an unjudged thread scores exactly as
/// it did before any of this existed.
///
/// **The needs-you verdict.** [needsYouVerdict] is the needs-you stage's
/// whole-message answer about that same newest inbound message, and it is the
/// one input here that reads the message rather than triage's fields about it.
/// It moves the score in exactly two places, both above: a judged YES breaks
/// the quiet temper (step 2, so the thread scores from
/// [AttentionTuning.needsReplyBase] and keeps its reply-rate nudge) and earns
/// the direct boost (step 8) on its own, without [addressedMe]. That pairing is
/// what lets a 1:1 Teams FYI the stage judged a real ask clear the default
/// threshold with no slider override.
///
/// Null and false move NOTHING. The fences are written to be asymmetric on
/// purpose — `!= true` on the temper, `== true` on the boost — so that a
/// message the stage never judged (null) and one it judged and declined (false)
/// both score exactly as they did before this input existed.
///
/// And it deliberately does not touch the THRESHOLD. A judged yes raises the
/// score through the same arithmetic every other signal uses and then takes its
/// chances against the user's slider like everything else; nothing here gets a
/// bypass into Needs You.
///
/// [latestIntent] is the intent from the newest inbound message's extraction,
/// null when nothing has extracted it yet. [senderReplyRate] is a 0..1 fraction
/// and is clamped, so a caller cannot push a thread up by handing over a rate
/// of 40. [senderPref] is `'keep'`, `'later'`, or null. [latestNeedsAction],
/// [latestDeadline], [addressedMe] and [needsYouVerdict] all describe that same
/// newest inbound message.
double attentionScore({
  required Conversation conversation,
  String? latestIntent,
  double senderReplyRate = 0,
  String? senderPref,
  bool? latestReplyExpected,
  bool? latestNeedsAction,
  String? latestDeadline,
  bool addressedMe = false,
  bool? needsYouVerdict,
  required DateTime now,
}) {
  // Both hard zeros, checked before anything else: a thread the user has
  // dismissed must not be able to climb back up on a fresh timestamp.
  if (senderPref == 'later') return 0;
  if (conversation.state == ConversationState.done) return 0;

  // Every clause is a separate reason to leave the thread alone, so every one
  // of them has to agree before the temper fires: the needs-you stage did not
  // call it a real ask, triage said no reply is wanted, it named no action and
  // no date, and the extraction read the message as an FYI rather than an ask.
  //
  // `!= true` on the first clause: a verdict nobody wrote (null) and one the
  // stage declined (false) leave the temper exactly as it was, and only a
  // judged yes breaks it.
  final quietFyi = needsYouVerdict != true &&
      conversation.state == ConversationState.needsReply &&
      latestReplyExpected == false &&
      latestNeedsAction != true &&
      (latestDeadline == null || latestDeadline.isEmpty) &&
      latestIntent != null &&
      AttentionTuning.quietIntents.contains(latestIntent);

  var score = conversation.state == ConversationState.needsReply && !quietFyi
      ? AttentionTuning.needsReplyBase
      : AttentionTuning.waitingBase;

  score *= switch (conversation.ctaUrgency) {
    CtaUrgency.urgent => AttentionTuning.urgentMultiplier,
    CtaUrgency.high => AttentionTuning.highMultiplier,
    // `low` does not discount. Triage's `low` means "not pressing", and a
    // thread the user still has to answer is still theirs to answer.
    CtaUrgency.normal || CtaUrgency.low => 1.0,
  };

  if (latestIntent != null &&
      AttentionTuning.askingIntents.contains(latestIntent)) {
    score += AttentionTuning.questionBonus;
  }

  // Skipped under the temper: see the doc comment. Nothing guards the question
  // bonus above, because the asking and quiet intent sets are disjoint and a
  // tempered thread cannot have earned it.
  if (!quietFyi) {
    score += senderReplyRate.clamp(0.0, 1.0) * AttentionTuning.replyRateMax;
  }

  score *= _recencyFactor(conversation.lastMessageAt, now);

  if (senderPref == 'keep') score *= AttentionTuning.keepBoost;

  // `!= false` rather than `== true` on purpose: a direct message triage has
  // never judged still gets the boost, and only an explicit "nobody is waiting
  // on this" declines it. That also makes this mutually exclusive with the
  // temper by construction, which requires the explicit false — still true of
  // the widened condition, since the temper's clauses are unchanged.
  //
  // The verdict earns the boost on `== true` alone, the opposite fence from
  // the temper's: being addressed is a fact about the header and reads as a
  // signal even unjudged, while a needs-you verdict IS a judgment, so its
  // absence says nothing to boost on.
  if ((addressedMe || needsYouVerdict == true) &&
      latestReplyExpected != false) {
    score *= AttentionTuning.directBoost;
  }

  return score.clamp(0.0, AttentionTuning.maxScore);
}

/// Exponential decay on the thread's last message, halving every
/// [AttentionTuning.recencyHalfLifeDays].
///
/// A timestamp that does not parse returns 1.0 — no decay at all — rather than
/// 0. A thread with a broken date is a thread the app knows nothing about, and
/// scoring it to the bottom would hide real mail behind a metadata bug. A
/// timestamp in the future gets the same treatment via the clamp: clock skew
/// must not be able to boost anything above a message that just landed.
double _recencyFactor(String? lastMessageAt, DateTime now) {
  if (lastMessageAt == null || lastMessageAt.isEmpty) return 1;
  final parsed = DateTime.tryParse(lastMessageAt);
  if (parsed == null) return 1;

  final ageDays =
      now.difference(parsed).inMilliseconds / Duration.millisecondsPerDay;
  if (ageDays <= 0) return 1;
  return math.exp(
    -ageDays * math.ln2 / AttentionTuning.recencyHalfLifeDays,
  );
}

/// Where one thread belongs: `'later'`, or null for the inbox.
///
/// The single decision both writers share — the extraction handler, which
/// files a thread the moment the model has read its newest message, and the
/// scoring sweep, which re-files the whole mailbox on every list load. Two
/// copies of this rule would drift, and the symptom would be a thread that
/// moves buckets depending on which pass ran last.
///
/// In order:
/// - A sender rule wins outright, in both directions. It is a person's
///   standing instruction, and the model does not get to overrule it by being
///   confident.
/// - A thread awaiting the user's reply is NEVER deferred, whatever the model
///   thinks of the message. Getting this wrong hides work the user is holding up,
///   which is the one failure this feature cannot afford.
/// - What is left goes to Later only when the model says both that it is low
///   importance AND that the sender is not asking for anything.
String? bucketFor({
  String? senderPref,
  required String intent,
  required String importance,
  required bool needsReply,
}) {
  if (senderPref == 'later') return 'later';
  if (senderPref == 'keep') return null;
  if (needsReply) return null;
  if (importance == 'low' && AttentionTuning.quietIntents.contains(intent)) {
    return 'later';
  }
  return null;
}

/// Why [bucketFor] returned the bucket it did. Only meaningful when it
/// returned one.
///
/// The reason is what makes the sweep safe to re-run: it clears only the
/// buckets it wrote (`low_value`) and never touches one a person asked for
/// (`sender_pref`).
String bucketReasonFor(String? senderPref) =>
    senderPref == 'later' ? 'sender_pref' : 'low_value';
