/// How the Inbox feed is ordered and which rows it keeps.
///
/// Two enums rather than one, because they answer two different questions —
/// what order the table runs in, and which messages are in it — and a single
/// vocabulary spanning both would let a control ask for "Newest first" as a
/// filter.
///
/// They live in `models/` for [NeedsYouSort]'s reason: a preference reads one
/// of them ([HomeSort], stored as `home_sort`), and a provider importing a
/// widget file for an enum is the wrong direction for that dependency to run.
library;

/// How the Inbox feed is ordered.
enum HomeSort { newest, oldest }

extension HomeSortLabel on HomeSort {
  String get label => switch (this) {
        HomeSort.newest => 'Newest first',
        HomeSort.oldest => 'Oldest first',
      };
}

/// Which rows the Inbox feed keeps. One at a time; the tiles above the table
/// are the control.
enum HomeFilter {
  fromOthers,
  needsYou,
  urgent,
  inFlight,
  errors,
  dropped,
  processed,
}

extension HomeFilterLabel on HomeFilter {
  String get label => switch (this) {
        HomeFilter.fromOthers => 'Everyone',
        HomeFilter.needsYou => 'Needs you',
        HomeFilter.urgent => 'Urgent',
        HomeFilter.inFlight => 'In flight',
        HomeFilter.errors => 'Errors',
        HomeFilter.dropped => 'Dropped',
        HomeFilter.processed => 'Processed',
      };

  /// Whether dropped rows can appear under this filter — what the search
  /// runner's `includeDropped` is fed from.
  ///
  /// [HomeFilter.processed] and [HomeFilter.inFlight] are on this list because
  /// they ask about the OUTCOME rather than about the verdict: a dropped
  /// message has been processed, and hiding it under a filter that counts it
  /// would make the tile above disagree with the table below.
  bool get showsDropped => switch (this) {
        HomeFilter.dropped ||
        HomeFilter.processed ||
        HomeFilter.inFlight ||
        HomeFilter.errors =>
          true,
        HomeFilter.fromOthers || HomeFilter.needsYou || HomeFilter.urgent =>
          false,
      };
}
