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
/// weights fixed means the ordering the LO learns to trust does not change
/// under them when they move that slider.
class AttentionTuning {
  /// A thread awaiting the LO's reply. The unit everything else is relative to.
  static const double needsReplyBase = 1.0;

  /// A thread waiting on someone else. It can still climb — an urgent ask on a
  /// thread the LO already answered is worth seeing — but it starts well below
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
  /// the LO said this sender matters, not that every message from them is
  /// urgent, and a floor would rank a two-month-old newsletter above this
  /// morning's real question.
  static const double keepBoost = 1.25;

  /// The intents that count as the sender asking for something.
  static const Set<String> askingIntents = {'question', 'request', 'approval'};

  /// The intents that make a low-importance message deferrable.
  static const Set<String> quietIntents = {'fyi', 'transactional'};
}

/// How loudly one thread is asking for the LO, from 0 to
/// [AttentionTuning.maxScore].
///
/// The chain, in order:
/// 1. A `later` sender rule, or a thread the LO closed, scores exactly 0. Both
///    are a person having already answered the question this function asks.
/// 2. A base by state: [AttentionTuning.needsReplyBase] for a thread awaiting
///    their reply, [AttentionTuning.waitingBase] for anything else still open.
/// 3. Multiplied by the ask's urgency, as triage read it.
/// 4. Plus [AttentionTuning.questionBonus] when the newest inbound message's
///    intent is one of [AttentionTuning.askingIntents].
/// 5. Plus up to [AttentionTuning.replyRateMax] for a sender the LO answers.
/// 6. Multiplied by recency, halving every
///    [AttentionTuning.recencyHalfLifeDays].
/// 7. Multiplied by [AttentionTuning.keepBoost] for a `keep` sender.
/// 8. Clamped.
///
/// [latestIntent] is the intent from the newest inbound message's extraction,
/// null when nothing has extracted it yet. [senderReplyRate] is a 0..1 fraction
/// and is clamped, so a caller cannot push a thread up by handing over a rate
/// of 40. [senderPref] is `'keep'`, `'later'`, or null.
double attentionScore({
  required Conversation conversation,
  String? latestIntent,
  double senderReplyRate = 0,
  String? senderPref,
  required DateTime now,
}) {
  // Both hard zeros, checked before anything else: a thread the LO has
  // dismissed must not be able to climb back up on a fresh timestamp.
  if (senderPref == 'later') return 0;
  if (conversation.state == ConversationState.done) return 0;

  var score = conversation.state == ConversationState.needsReply
      ? AttentionTuning.needsReplyBase
      : AttentionTuning.waitingBase;

  score *= switch (conversation.ctaUrgency) {
    CtaUrgency.urgent => AttentionTuning.urgentMultiplier,
    CtaUrgency.high => AttentionTuning.highMultiplier,
    // `low` does not discount. Triage's `low` means "not pressing", and a
    // thread the LO still has to answer is still theirs to answer.
    CtaUrgency.normal || CtaUrgency.low => 1.0,
  };

  if (latestIntent != null &&
      AttentionTuning.askingIntents.contains(latestIntent)) {
    score += AttentionTuning.questionBonus;
  }

  score += senderReplyRate.clamp(0.0, 1.0) * AttentionTuning.replyRateMax;

  score *= _recencyFactor(conversation.lastMessageAt, now);

  if (senderPref == 'keep') score *= AttentionTuning.keepBoost;

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
/// - A thread awaiting the LO's reply is NEVER deferred, whatever the model
///   thinks of the message. Getting this wrong hides work the LO is holding up,
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
