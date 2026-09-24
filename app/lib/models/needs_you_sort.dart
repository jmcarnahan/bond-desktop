import 'message_models.dart';
import 'stable_sort.dart';

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
/// [quickWins] and [oldest] are the two session orders of entry 12g, and they
/// answer questions about the READER rather than about the mail: one is "I have
/// ten minutes", the other is "I am getting to the bottom of this today".
///
/// It lives in `models/` rather than beside the tabs because a preference
/// reads it, and a provider importing a widget file for an enum is the wrong
/// direction for that dependency to run. `needs_you_tabs.dart` re-exports it,
/// so the widgets that already had the tabs have the order too.
enum NeedsYouSort { priority, newest, quickWins, oldest }

extension NeedsYouSortLabel on NeedsYouSort {
  String get label => switch (this) {
        NeedsYouSort.priority => 'By priority',
        NeedsYouSort.newest => 'Newest first',
        NeedsYouSort.quickWins => 'Quick wins',
        NeedsYouSort.oldest => 'Oldest first',
      };
}

/// How long a thread can be and still be a quick win. Three messages is one
/// exchange and a reply to it: past that, clearing the thread means reading it,
/// whatever the ask on it turned out to be.
const int quickWinMessages = 3;

/// Whether one thread could plausibly be cleared in a line.
///
/// Two ways to qualify, and the first is the model saying so outright: a thread
/// triage judged to expect NO reply is a read-and-clear however long it is.
/// The second is the shape of the thing — no action item on it ([ctaText] is
/// the folded-up "triage left an ask here", the same reading the list pane's
/// own Needs-action bucket takes) and short enough to take in at a glance.
///
/// It is a GUESS about effort, never a verdict, and that is why it only ever
/// reorders: nothing here drops a thread, hides one, or writes anything. A
/// reader who disagrees picks another order.
bool isQuickWin(Conversation c) =>
    c.replyExpected == false ||
    ((c.ctaText?.trim().isEmpty ?? true) && c.messageCount <= quickWinMessages);

/// The pile in [sort] order.
///
/// [NeedsYouSort.priority] is the input UNTOUCHED — that is [needsYouRows]'
/// own order, decided once, and re-deriving it here would be a second opinion
/// about a ranking that already has one.
///
/// [NeedsYouSort.newest] is by `lastMessageAt` descending and STABLE
/// ([stableSorted]): rows with equal stamps keep the order they arrived in, so
/// the ranking still shows through wherever the clock says nothing, and a row
/// with no stamp at all sorts last rather than to the top a missing string
/// would otherwise buy it.
///
/// [NeedsYouSort.oldest] is that clock run backwards, with the same two rules:
/// stable, and an undated row last rather than first — which it would be under
/// a plain ascending compare of the empty string, and "no stamp" is not "the
/// beginning of time".
///
/// [NeedsYouSort.quickWins] is a PARTITION and not a ranking: the threads
/// [isQuickWin] can see an end to move above the ones it cannot, and each half
/// keeps the ranking it came in with. Sorting inside the halves would be this
/// file inventing a second opinion about a pile that already has one.
///
/// Same rows in, same rows out. This never filters — the tabs do that, and a
/// sort that could also drop a row would make the badge over the section a
/// lie.
List<Conversation> sortNeedsYou(NeedsYouSort sort, List<Conversation> rows) {
  if (sort == NeedsYouSort.priority) return rows;

  if (sort == NeedsYouSort.quickWins) {
    return stableSorted(rows, (a, b) {
      final left = isQuickWin(a) ? 0 : 1;
      final right = isQuickWin(b) ? 0 : 1;
      return left.compareTo(right);
    });
  }

  final newestFirst = sort == NeedsYouSort.newest;
  return stableSorted(rows, (a, b) {
    final left = a.lastMessageAt ?? '';
    final right = b.lastMessageAt ?? '';
    // An undated row goes to the bottom whichever side it is on, and whichever
    // end of the clock the reader asked for. ISO-8601 UTC strings compare
    // lexicographically, so nothing has to be parsed to put the rest in order.
    if (left.isEmpty != right.isEmpty) return left.isEmpty ? 1 : -1;
    return newestFirst ? right.compareTo(left) : left.compareTo(right);
  });
}
