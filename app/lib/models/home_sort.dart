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

  /// Whether this filter is bounded by the tiles' own window
  /// (`homeMetricsWindow`), so the number on a tile stays the number of rows
  /// under it.
  ///
  /// True for the five that count what the pipeline has been DOING — urgent,
  /// in flight, errors, dropped, processed. Those numbers only ever grow, and
  /// a lifetime total of processed mail is a number nobody can act on; a week
  /// of it is a readout of how the app has been running.
  ///
  /// False for [HomeFilter.fromOthers], which is the feed itself, and false
  /// for [HomeFilter.needsYou], which is the pile to burn down: work owed
  /// since before last Tuesday is exactly the work a window would hide, and a
  /// pile whose count and whose rows both stopped at seven days would read as
  /// empty while the oldest asks went unanswered.
  bool get windowed => switch (this) {
        HomeFilter.urgent ||
        HomeFilter.inFlight ||
        HomeFilter.errors ||
        HomeFilter.dropped ||
        HomeFilter.processed =>
          true,
        HomeFilter.fromOthers || HomeFilter.needsYou => false,
      };

  /// Whether dropped rows can appear under this filter — what the search
  /// runner's `includeDropped` is fed from.
  ///
  /// [HomeFilter.processed] and [HomeFilter.inFlight] are on this list because
  /// they ask about the OUTCOME rather than about the verdict: a dropped
  /// message has been processed, and hiding it under a filter that counts it
  /// would make the tile above disagree with the table below.
  ///
  /// [HomeFilter.needsYou] is on it because the list it draws already carries
  /// dropped rows. The row that stands for a thread is its newest KEPT
  /// message, and "kept" is a fact about the gate — a settle-time
  /// `not_worthy` drop is a verdict about a message the gate kept, so such a
  /// row is both dropped and the row this filter picked. A search under the
  /// filter has to be able to reach the rows the filter is showing.
  bool get showsDropped => switch (this) {
        HomeFilter.dropped ||
        HomeFilter.processed ||
        HomeFilter.inFlight ||
        HomeFilter.errors ||
        HomeFilter.needsYou =>
          true,
        HomeFilter.fromOthers || HomeFilter.urgent => false,
      };
}
