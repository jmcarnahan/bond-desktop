/// When a suggested reply is written without anyone asking for it.
///
/// Three modes, and the middle one is the whole point of the setting. Drafting
/// is the most expensive thing this app does — one big-model decision and one
/// big-model draft per message — so a sixty-message backlog that drafts
/// everything spends a quarter of an hour of the prose server on replies
/// nobody will read, while the message that actually needs an answer waits
/// behind them.
///
/// [needsYou] is the default: only the messages the pipeline already judged to
/// be the owner's to answer are drafted ahead of time, and at most
/// [prefetchCap] of them are in flight at once. [all] is the behaviour this
/// setting replaced, kept because someone whose inbox is small enough to draft
/// whole should be able to say so. [onDemand] writes nothing until a person
/// presses **Draft reply** — which works in every mode, so the two prefetching
/// modes only ever decide what is ready BEFORE it is asked for.
///
/// It lives in `models/` rather than beside the handler that reads it for
/// `needs_you_sort.dart`'s reason: a preference reads it, `services/` never
/// imports `providers/`, and a provider importing a service file for an enum
/// would run that dependency the wrong way.
enum DraftPolicy {
  /// Prefetch a reply for the messages judged to need the owner, capped.
  needsYou,

  /// Every message that passes `asksForAReply` — the pre-round behaviour.
  all,

  /// Nothing until a person presses **Draft reply**.
  onDemand;

  /// At most this many `draft` rows pending or running at once under
  /// [needsYou].
  ///
  /// Ten, because ten drafts at ~27 s on one prose slot is about four and a
  /// half minutes of prefetch — long enough to have covered the top of the
  /// pile by the time a person has read the first message, short enough that
  /// the lane is free when they ask for the eleventh by hand. It is a SOFT
  /// cap: extraction drains three wide, so three items can read the count
  /// before any of them writes and the real ceiling is twelve.
  static const int prefetchCap = 10;
}

extension DraftPolicyLabel on DraftPolicy {
  /// The collapsed Settings summary — a sentence about what the app does, not
  /// the name of the mode.
  String get label => switch (this) {
        DraftPolicy.needsYou => 'For messages that need you',
        DraftPolicy.all => 'For every reply-worthy message',
        DraftPolicy.onDemand => 'Only when asked',
      };

  /// The segment label. Short enough for three segments on one row.
  String get short => switch (this) {
        DraftPolicy.needsYou => 'Needs you',
        DraftPolicy.all => 'All',
        DraftPolicy.onDemand => 'When asked',
      };
}
