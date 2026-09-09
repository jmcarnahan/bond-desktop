import 'message_models.dart';

/// How the Needs You pile is ordered, everywhere it is drawn.
///
/// One order for the rail, the overview and Find's Enter, because those three
/// are the same pile seen from three places: a reader who put today's mail on
/// top and then found the rail still ranking by loudness would have learned
/// that the control does not mean what it says.
///
/// [priority] is the default and is [needsYouRows]' own ranking — needs-reply
/// first, then attention score. [newest] answers the question the ranking
/// cannot: a thread that landed this morning can sit sixth under five older
/// ones that outscore it, and the reader who was looking for it concludes it
/// is missing.
///
/// It lives in `models/` rather than beside the tabs because a preference
/// reads it, and a provider importing a widget file for an enum is the wrong
/// direction for that dependency to run. `needs_you_tabs.dart` re-exports it,
/// so the widgets that already had the tabs have the order too.
enum NeedsYouSort { priority, newest }

extension NeedsYouSortLabel on NeedsYouSort {
  String get label => switch (this) {
        NeedsYouSort.priority => 'By priority',
        NeedsYouSort.newest => 'Newest first',
      };
}

/// The pile in [sort] order.
///
/// [NeedsYouSort.priority] is the input UNTOUCHED — that is [needsYouRows]'
/// own order, decided once, and re-deriving it here would be a second opinion
/// about a ranking that already has one.
///
/// [NeedsYouSort.newest] is by `lastMessageAt` descending and STABLE: rows
/// with equal stamps keep the order they arrived in, so the ranking still
/// shows through wherever the clock says nothing, and a row with no stamp at
/// all sorts last rather than to the top a missing string would otherwise buy
/// it. Dart's own sort is not stable, so the input position is carried through
/// and used as the final tie-break rather than trusted.
///
/// Same rows in, same rows out. This never filters — the tabs do that, and a
/// sort that could also drop a row would make the badge over the section a
/// lie.
List<Conversation> sortNeedsYou(NeedsYouSort sort, List<Conversation> rows) {
  if (sort == NeedsYouSort.priority) return rows;

  final indexed = <(int, Conversation)>[];
  var index = 0;
  for (final c in rows) {
    indexed.add((index++, c));
  }
  indexed.sort((a, b) {
    final left = a.$2.lastMessageAt ?? '';
    final right = b.$2.lastMessageAt ?? '';
    // An undated row goes to the bottom whichever side it is on. ISO-8601 UTC
    // strings compare lexicographically, so nothing has to be parsed to put
    // the rest in order.
    if (left.isEmpty != right.isEmpty) return left.isEmpty ? 1 : -1;
    final byDate = right.compareTo(left);
    if (byDate != 0) return byDate;
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, c) in indexed) c];
}
