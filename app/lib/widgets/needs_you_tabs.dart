import '../models/message_models.dart';
import 'app_rail.dart' show isWaitingRow;

/// The five ways to read the Needs You pile.
///
/// [all] leads and is the default, so arriving at the stop shows exactly what
/// it always showed — the ranked list. The other four are lenses on that same
/// list and never on a different one: each answers a question the ranking
/// cannot ("what is somebody waiting on ME for", "what has a date on it"), and
/// a tab that went back to the store for its own rows would eventually
/// disagree with the badge over the section.
enum NeedsYouTab { all, askedOfMe, waitingOnOthers, deadlines, suggestedDrafts }

extension NeedsYouTabLabel on NeedsYouTab {
  String get label => switch (this) {
        NeedsYouTab.all => 'All',
        NeedsYouTab.askedOfMe => 'Asked of me',
        NeedsYouTab.waitingOnOthers => 'Waiting on others',
        NeedsYouTab.deadlines => 'Deadlines',
        NeedsYouTab.suggestedDrafts => 'Suggested drafts',
      };
}

/// One tab's rows, out of the Needs You list the rail and the overview share.
///
/// The input is [needsYouRows]' output — already filtered by the attention
/// threshold and already ranked — and the ORDER SURVIVES. That is the contract
/// that makes these tabs cheap: they are filters over a ranking that was
/// decided once, so the third row on Deadlines is the same thread it was on
/// All, and a reader who switches tabs is not re-reading a reshuffled pile.
///
/// The two halves are complements of one predicate, as Needs You itself is:
/// [NeedsYouTab.askedOfMe] is everything [isWaitingRow] denies, and
/// [NeedsYouTab.waitingOnOthers] is everything it claims — so every row is on
/// exactly one of the two and the counts add up to [NeedsYouTab.all].
List<Conversation> needsYouTabRows(NeedsYouTab tab, List<Conversation> rows) =>
    switch (tab) {
      NeedsYouTab.all => rows,
      NeedsYouTab.askedOfMe => [
          for (final c in rows)
            if (!isWaitingRow(c)) c,
        ],
      NeedsYouTab.waitingOnOthers => [
          for (final c in rows)
            if (isWaitingRow(c)) c,
        ],
      NeedsYouTab.deadlines => [
          for (final c in rows)
            if (c.latestDeadline?.trim().isNotEmpty == true) c,
        ],
      NeedsYouTab.suggestedDrafts => [
          for (final c in rows)
            if (c.pendingDraftCount > 0) c,
        ],
    };
