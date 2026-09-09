import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'home_result.dart';
import 'source_glyph.dart';
import 'stage_bar.dart';
import 'time_format.dart';

/// One message in the Inbox feed: who it is from, what it is about, how far
/// through the pipeline it got, what the app decided, what is being asked, and
/// when it arrived.
///
/// A table row and not a card. The question this screen answers is
/// comparative — "is everything moving?", "what got dropped this morning?" —
/// and comparison needs columns that line up; a border per row at this density
/// is a grid of boxes rather than a table, so a single hairline underneath
/// carries the separation. The widths live here as consts and
/// [HomeFeedHeaderRow] reads the same ones, which is the only thing keeping
/// the header honest.
///
/// The Result cell is a LABEL — [resultLine] decides which — and the Ask ·
/// Summary cell beside it carries the words: the thread's own ask on a row
/// that needs the reader, the message's summary everywhere else, and the
/// result's reason clause on a row that has neither. They split because a
/// column of verdicts is only scannable if it is a column of verdicts; the
/// whole sentence is still one hover away.
///
/// Four gestures nest inside it, and the innermost wins the arena in this
/// order: the row itself opens the thread, the bar and the Result cell open
/// this message's history, the storyline name opens the storyline, and Retry
/// requeues what the row still owes.
class HomeFeedRowTile extends StatefulWidget {
  static const double glyphWidth = 20;

  /// Narrowed from 160 to make room for the Ask column. A sender's display
  /// name ellipsises here anyway, and the twenty pixels buy words.
  static const double fromWidth = 140;
  static const double barWidth = HomeStageBar.trackWidth;

  /// Wide enough for `MMM d, h:mm a`, which is what a row that did not arrive
  /// today now says — the old 76 was sized for `3h ago`.
  static const double whenWidth = 104;

  /// Subject and Ask share what is left, three to three: they are what a
  /// reader reads.
  static const int subjectFlex = 3;
  static const int askFlex = 3;

  /// Narrower under [compact], where the same two cells are the only flexed
  /// ones on the line: the ask is the reader's own work and the subject is how
  /// they recognise the thread, so the words get the larger share.
  static const int compactSubjectFlex = 2;

  /// The Result column is FIXED rather than flexed, because it holds one
  /// thing: a chip, a label, or `Filed in <name>`. A flexed cell made the
  /// column's left edge move with the window, which is the one thing a column
  /// of verdicts cannot do — the whole reason it is a column is that the eye
  /// runs down it. 168 px fits `Waiting on extract` and the chip beside a
  /// Retry, and ellipsises a long storyline name rather than the label.
  static const double resultWidth = 168;

  static const Duration entryDuration = Duration(milliseconds: 200);

  /// How far down a row is faded while it is on its way out. Faint enough to
  /// read as leaving, solid enough to still read.
  static const double dropFadeOpacity = 0.35;

  /// The drop vocabulary, which lives in `home_result.dart` with the rest of
  /// the narration. Kept here as an alias because callers and tests reach for
  /// it through the widget, and two copies of a label map is how a screen and
  /// its tooltip come to disagree.
  static const Map<String, String> dropLabels = homeDropLabels;

  static String dropLabel(String? reason) => homeDropLabel(reason);

  /// The sentence's key, so a test can read the Result cell without matching
  /// on its words. On a filed row it sits on the opening clause, because that
  /// sentence is built from three pieces around a tappable name.
  static ValueKey<String> resultTextKey(HomeFeedRow row) =>
      ValueKey('result-${row.feedKey}');

  static ValueKey<String> retryKey(HomeFeedRow row) =>
      ValueKey('retry-${row.feedKey}');

  /// The two history targets. Keyed apart rather than sharing one key because
  /// the bar and the sentence are two different places a reader looks when
  /// they want to know why, and a test that could only find one of them would
  /// pass with the other unwired.
  static ValueKey<String> historyBarKey(HomeFeedRow row) =>
      ValueKey('history-bar-${row.feedKey}');

  static ValueKey<String> historyCellKey(HomeFeedRow row) =>
      ValueKey('history-cell-${row.feedKey}');

  /// The Ask · Summary cell's words, and the stamp. Keyed rather than matched
  /// on their text because both are written by the model or by a clock, and a
  /// finder that had to guess at either would pin the fixture instead of the
  /// column.
  static ValueKey<String> askKey(HomeFeedRow row) =>
      ValueKey('ask-${row.feedKey}');

  static ValueKey<String> whenKey(HomeFeedRow row) =>
      ValueKey('when-${row.feedKey}');

  final HomeFeedRow row;

  /// The clock, injected so a test pins what "3h ago" means.
  final DateTime now;

  /// Whether this row is arriving now, rather than having been read off a
  /// page. False renders it whole on the first frame with nothing animating,
  /// which is every row a page read hands over.
  final bool animateIn;

  /// Whether the app has dropped this row and it is on its way off the table:
  /// grayed where it stands, so the reader gets to see what went and why.
  final bool fading;

  /// The last beat of that: the row gives up its height and the feed closes
  /// over it.
  final bool collapsing;

  /// Holds the bar down whatever the row's own outcome says. What a search
  /// result sets: its bar is context for a message somebody went looking for,
  /// not progress anybody is watching.
  final bool muteBar;

  /// Folds the row onto two lines. Set by the pane below
  /// [HomePane.compactBelow], where seven columns cannot line up — see the doc
  /// on that constant.
  final bool compact;

  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;

  /// Puts the stages the row still owes back on their queues. Optional, and
  /// null is what the archive pane passes: a dropped row is Restore's
  /// business, and a Retry there would offer to re-run a pipeline that is
  /// going to refuse the message again at the first gate.
  final void Function(String source, String sourceMessageId)? onRetry;

  /// Opens the whole story of THIS message — every stage, judgement, filing
  /// and queue row behind the sentence in the Result cell. Optional, and null
  /// draws no target at all: the bar and the cell stay part of the row's own
  /// tap, which is what a host with nowhere to show a history needs.
  final void Function(String source, String sourceMessageId)? onOpenHistory;

  const HomeFeedRowTile({
    super.key,
    required this.row,
    required this.now,
    required this.onOpenThread,
    required this.onOpenStoryline,
    this.animateIn = false,
    this.fading = false,
    this.collapsing = false,
    this.muteBar = false,
    this.compact = false,
    this.onRetry,
    this.onOpenHistory,
  });

  @override
  State<HomeFeedRowTile> createState() => _HomeFeedRowTileState();
}

class _HomeFeedRowTileState extends State<HomeFeedRowTile> {
  /// Starts settled unless the row said it was arriving, so a row that did not
  /// opt in never animates and a scroll back through history never replays an
  /// entrance.
  late bool _settled = !widget.animateIn;

  @override
  void initState() {
    super.initState();
    if (_settled) return;
    // A frame, not a timer: the implicit animations below need one build at
    // the start value before they have something to animate from.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _settled = true);
    });
  }

  /// The collapse is the outermost thing that happens to a row, because it is
  /// the only one that changes its size: everything inside animates within a
  /// height this decides.
  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: homeDropCollapse,
      curve: Curves.easeIn,
      // From the top, so the rows below rise into the space rather than this
      // one sinking out of its own.
      alignment: Alignment.topCenter,
      child: widget.collapsing
          ? const SizedBox(width: double.infinity, height: 0)
          : _content(widget.row),
    );
  }

  /// The entry animations stay OUTSIDE the drop's, so the two multiply rather
  /// than argue: a row that arrives already dropped — a newsletter the gate
  /// threw out — slides in and grays at once, and neither animation has to
  /// know the other exists.
  Widget _content(HomeFeedRow row) {
    return AnimatedSlide(
      duration: HomeFeedRowTile.entryDuration,
      curve: Curves.easeOut,
      offset: _settled ? Offset.zero : const Offset(0, -0.4),
      child: AnimatedOpacity(
        duration: HomeFeedRowTile.entryDuration,
        curve: Curves.easeOut,
        opacity: _settled ? 1 : 0,
        child: AnimatedOpacity(
          duration: homeDropCollapse,
          curve: Curves.easeOut,
          opacity: widget.fading ? HomeFeedRowTile.dropFadeOpacity : 1,
          child: AnimatedContainer(
            duration: homeDropCollapse,
            curve: Curves.easeOut,
            color: widget.fading ? BondColors.faintGround : Colors.transparent,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () =>
                    widget.onOpenThread(row.source, row.conversationKey),
                hoverColor: BondColors.faintGround,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BondSpacing.s4,
                    vertical: BondSpacing.s8,
                  ),
                  decoration: const BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: BondColors.border)),
                  ),
                  // One narrator per row, read once and handed to both cells:
                  // the Result label and the Ask fallback are two readings of
                  // the same judgement, and computing it twice is how they
                  // would come to disagree about a row that changed between
                  // them.
                  child: widget.compact
                      ? _compact(row, resultLine(row, now: widget.now))
                      : _wide(row, resultLine(row, now: widget.now)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Seven columns, the way the header names them.
  Widget _wide(HomeFeedRow row, HomeResult result) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _glyph(row),
        const SizedBox(width: BondSpacing.s8),
        _from(row),
        const SizedBox(width: BondSpacing.s8),
        Expanded(flex: HomeFeedRowTile.subjectFlex, child: _subject(row)),
        const SizedBox(width: BondSpacing.s8),
        _bar(row),
        const SizedBox(width: BondSpacing.s8),
        SizedBox(
          width: HomeFeedRowTile.resultWidth,
          child: _historyTarget(
            row,
            key: HomeFeedRowTile.historyCellKey(row),
            child: _result(row, result),
          ),
        ),
        const SizedBox(width: BondSpacing.s8),
        Expanded(flex: HomeFeedRowTile.askFlex, child: _ask(row, result)),
        const SizedBox(width: BondSpacing.s8),
        _when(row),
      ],
    );
  }

  /// ONE line: who it is from, what it is about, what is being asked, and
  /// when.
  ///
  /// No bar and no Result cell, which is the whole point. This layout is what
  /// the pane folds to with a thread open beside it, and at that width there
  /// is not room for both a verdict and a progress bar and the words — and
  /// there is no need: the thread beside is carrying both, and its Why panel's
  /// `What happened ›` is the door to this message's history that the Result
  /// cell used to be.
  ///
  /// The ask keeps its tone as a dot in front of it, so a row that needs the
  /// reader is still findable by scanning down the column the words are in.
  Widget _compact(HomeFeedRow row, HomeResult result) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _glyph(row),
        const SizedBox(width: BondSpacing.s8),
        _from(row),
        const SizedBox(width: BondSpacing.s8),
        Expanded(
          flex: HomeFeedRowTile.compactSubjectFlex,
          child: _subject(row),
        ),
        const SizedBox(width: BondSpacing.s8),
        Expanded(flex: HomeFeedRowTile.askFlex, child: _ask(row, result)),
        const SizedBox(width: BondSpacing.s8),
        _when(row),
      ],
    );
  }

  Widget _glyph(HomeFeedRow row) => SizedBox(
        width: HomeFeedRowTile.glyphWidth,
        child: Text(sourceChipPrefix(row.source), style: BondType.small),
      );

  Widget _from(HomeFeedRow row) => SizedBox(
        width: HomeFeedRowTile.fromWidth,
        child: Text(
          row.fromName ?? row.fromAddress ?? '(no sender)',
          style: BondType.body.copyWith(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );

  Widget _subject(HomeFeedRow row) => Text(
        (row.subject?.isNotEmpty ?? false) ? row.subject! : '(no subject)',
        style: BondType.small.copyWith(color: BondColors.ink),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );

  /// The history InkWell sits INSIDE the SizedBox and OUTSIDE the bar, so every
  /// segment keeps its own tooltip and the bar as a whole is still one target.
  Widget _bar(HomeFeedRow row) => SizedBox(
        width: HomeFeedRowTile.barWidth,
        child: _historyTarget(
          row,
          key: HomeFeedRowTile.historyBarKey(row),
          child: HomeStageBar.forRow(
            row,
            // A finished row's bar is history, not progress.
            muted: widget.muteBar || row.outcome != 'pending',
          ),
        ),
      );

  /// What the thread is asking, or what the message was about.
  ///
  /// An ask is the reader's own work and is drawn as such — full ink, semibold.
  /// A summary is context and stays quiet. Two lines and then an ellipsis: the
  /// cell is a column in a table, not a preview pane, and the whole of it is on
  /// the tooltip for anyone who wants it.
  ///
  /// Under [compact] an ask carries the result's tone as a dot in front of it.
  /// The chip is what colours a needs-you row in the wide layout, and compact
  /// has no Result cell to put a chip in — without the dot, the one row on the
  /// table the reader is on the hook for would look like every other row.
  /// A summary gets no dot: it is not a verdict about anything.
  Widget _ask(HomeFeedRow row, HomeResult result) {
    final ask = askLine(row, result);
    final style = BondType.small.copyWith(
      color: ask.ask ? BondColors.ink : BondColors.inkSecondary,
      fontWeight: ask.ask ? FontWeight.w600 : null,
    );
    final dot = widget.compact && ask.ask && ask.text.isNotEmpty;
    // Text.rich in both cases, so the key sits on the same widget type
    // whichever layout is up and a finder cannot pass on one and miss on the
    // other.
    final text = Text.rich(
      TextSpan(
        children: [
          if (dot)
            TextSpan(
              text: '● ',
              style: style.copyWith(
                color: bondToneColors[result.tone]!.foreground,
              ),
            ),
          TextSpan(text: ask.text),
        ],
      ),
      key: HomeFeedRowTile.askKey(row),
      style: style,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    // A tooltip over an empty cell is a hover target that says nothing.
    return ask.text.isEmpty ? text : Tooltip(message: ask.text, child: text);
  }

  /// When it arrived, as the stamp rather than as an age.
  ///
  /// "3h ago" answers "is this current?", which is the question a refresh
  /// caption asks. A table of mail is scanned for WHEN, and two rows four
  /// minutes apart both reading "3h ago" is a column that cannot be scanned.
  /// The age is still there, on the tooltip beside the full stamp.
  Widget _when(HomeFeedRow row) {
    final iso = row.receivedAt;
    final stamp = feedStamp(iso, widget.now) ?? '';
    final text = Text(
      stamp,
      key: HomeFeedRowTile.whenKey(row),
      style: BondType.caption,
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return SizedBox(
      width: HomeFeedRowTile.whenWidth,
      child: stamp.isEmpty
          ? text
          : Tooltip(
              message: '${formatTimestamp(iso)} · '
                  '${relativeTime(iso, widget.now)}',
              child: text,
            ),
    );
  }

  /// Wraps a cell in the tap that opens this message's history, or hands it
  /// straight back when the host wired none up.
  ///
  /// Its own [InkWell] INSIDE the row's, for [_storylineLink]'s reason: the
  /// innermost gesture wins the arena, so pressing the bar or the sentence
  /// asks why rather than opening the thread underneath. The storyline link
  /// and Retry sit inside this one in turn and still win over it.
  Widget _historyTarget(
    HomeFeedRow row, {
    required Key key,
    required Widget child,
  }) {
    final open = widget.onOpenHistory;
    if (open == null) return child;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: () => open(row.source, row.sourceMessageId),
        borderRadius: BondRadii.smAll,
        child: child,
      ),
    );
  }

  /// What the app decided, as a label — and, under it, the storyline the row
  /// belongs to.
  ///
  /// TWO LINES rather than one row of pieces, because the cell is one fixed
  /// column now and a verdict beside a storyline name is two things competing
  /// for the same 168 px: whichever lost was ellipsised into nothing. The
  /// verdict is what the column is for, so it gets the line; the filing is
  /// context and sits under it, quiet, in a caption.
  ///
  /// A dropped row shows its reason and NOTHING else: it is out of the default
  /// feed precisely because the app judged it did not need the user, and a
  /// "Needs you" chip beside "Newsletter" would be the app arguing with itself.
  /// A filed row shows no second line either — the storyline IS its label.
  ///
  /// Which label is [resultLine]'s judgement, not this widget's. All that
  /// happens here is the dressing.
  ///
  /// The gesture arena over this cell is four deep once a host wires up
  /// [onOpenHistory]: the row opens the thread, the cell around this one opens
  /// the history, and the storyline link and Retry inside it win over both.
  Widget _result(HomeFeedRow row, HomeResult result) {
    final storylineId = row.storylineId;
    final storylineTitle = row.storylineTitle;
    final linked = storylineId != null && (storylineTitle?.isNotEmpty ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(child: _label(result, row)),
            // Retry is the ONE thing that shares the verdict's line, because
            // it is about the verdict: a row that stalled is a row somebody
            // wants to push again, and a link on the next line down would read
            // as being about the storyline instead.
            if (result.retryable && widget.onRetry != null) ...[
              const SizedBox(width: BondSpacing.s8),
              // Flexible for the label's reason: a child with no flex on it is
              // laid out against an UNBOUNDED main axis, so at a narrow width
              // it would take the whole cell and push the label off the end
              // rather than share what there is.
              Flexible(child: _retryLink(row)),
            ],
          ],
        ),
        // Already inside the label when the label IS the filing, and never on
        // a dropped row, whose reason is the whole of what it has to say.
        if (!row.dropped && linked && result.kind != HomeResultKind.filed)
          _storylineLink(storylineId, storylineTitle!, caption: true),
      ],
    );
  }

  /// The label itself, under a tooltip carrying the whole sentence — the cell
  /// holds the verdict and the reason lives one column over, so the hover is
  /// where the two are put back together.
  ///
  /// A needs-you row is ONE chip and not a chip beside a sentence: the chip and
  /// the words said the same thing twice, and the words are now in the Ask
  /// cell where the reader is already looking.
  ///
  /// A filed row is `Filed in <name>` and stops there. The evidence that used
  /// to hang off it after a dash is [HomeResult.detail] — it is in the tooltip
  /// and it is what the Ask cell falls back to — and inside a fixed 168 px it
  /// only ever ellipsised the storyline's name away.
  Widget _label(HomeResult result, HomeFeedRow row) {
    final style = BondType.small.copyWith(
      color: bondToneColors[result.tone]!.foreground,
    );

    if (result.kind == HomeResultKind.needsYou) {
      return Tooltip(
        message: result.tooltip,
        child: Align(
          alignment: Alignment.centerLeft,
          child: BondChip.semantic(
            'Needs you',
            result.tone,
            key: HomeFeedRowTile.resultTextKey(row),
          ),
        ),
      );
    }

    if (result.kind == HomeResultKind.filed) {
      return Tooltip(
        message: result.tooltip,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'Filed in ',
              key: HomeFeedRowTile.resultTextKey(row),
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Flexible(
              child: _storylineLink(row.storylineId!, row.storylineTitle!),
            ),
          ],
        ),
      );
    }

    return Tooltip(
      message: result.tooltip,
      child: Text(
        result.text,
        key: HomeFeedRowTile.resultTextKey(row),
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// Requeue what the row still owes.
  ///
  /// Its own [InkWell] inside the row's, for [_storylineLink]'s reason: the
  /// innermost gesture wins the arena, so pressing Retry does not also open
  /// the thread underneath it.
  Widget _retryLink(HomeFeedRow row) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: HomeFeedRowTile.retryKey(row),
        onTap: () => widget.onRetry!(row.source, row.sourceMessageId),
        borderRadius: BondRadii.smAll,
        child: Text(
          'Retry',
          style: BondType.small.copyWith(
            fontWeight: FontWeight.w600,
            color: BondColors.primary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// The storyline the message was filed under, as a link.
  ///
  /// Its own [InkWell] inside the row's: the innermost gesture wins the arena,
  /// so tapping the name opens the storyline and tapping anywhere else on the
  /// row opens the thread.
  ///
  /// [caption] is the second line of the Result cell, where the name is
  /// context under a verdict rather than part of a sentence beside one. One
  /// widget with two sizes rather than two widgets, because both are the same
  /// link to the same place and a second copy is how one of them ends up
  /// opening nothing.
  Widget _storylineLink(String id, String title, {bool caption = false}) {
    return Tooltip(
      message: title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => widget.onOpenStoryline(id),
          borderRadius: BondRadii.smAll,
          child: Text(
            title,
            style: (caption ? BondType.caption : BondType.small).copyWith(
              fontWeight: FontWeight.w600,
              color: BondColors.primary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// Names the feed's columns once, above the list.
///
/// A sibling of the list rather than its first item, so it stays put while the
/// rows scroll under it. Built from [HomeFeedRowTile]'s widths rather than
/// through a shared layout widget, because the header is the one place where a
/// wrong grid is visible immediately.
///
/// [compact] names the four columns the folded row keeps — From, Subject,
/// Ask · Summary, When. Pipeline and Result are absent because the folded row
/// does not draw them: with a thread open beside this table there is no width
/// for a bar and a verdict, and the thread beside carries both.
class HomeFeedHeaderRow extends StatelessWidget {
  final bool compact;

  const HomeFeedHeaderRow({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    Widget cell(String text, double width, {TextAlign? align}) => SizedBox(
          width: width,
          child: Text(text, style: BondType.label, textAlign: align),
        );

    Widget flexible(String text, int flex) => Expanded(
          flex: flex,
          child: Text(text, style: BondType.label),
        );

    return Container(
      color: BondColors.faintGround,
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s4,
        vertical: BondSpacing.s8,
      ),
      child: Row(
        children: [
          // The glyph has no header of its own; its width is reserved so From
          // starts in the same place it does on every row.
          const SizedBox(width: HomeFeedRowTile.glyphWidth),
          const SizedBox(width: BondSpacing.s8),
          cell('From', HomeFeedRowTile.fromWidth),
          const SizedBox(width: BondSpacing.s8),
          if (compact) ...[
            flexible('Subject', HomeFeedRowTile.compactSubjectFlex),
            const SizedBox(width: BondSpacing.s8),
            flexible('Ask · Summary', HomeFeedRowTile.askFlex),
            const SizedBox(width: BondSpacing.s8),
          ] else ...[
            flexible('Subject', HomeFeedRowTile.subjectFlex),
            const SizedBox(width: BondSpacing.s8),
            cell('Pipeline', HomeFeedRowTile.barWidth),
            const SizedBox(width: BondSpacing.s8),
            cell('Result', HomeFeedRowTile.resultWidth),
            const SizedBox(width: BondSpacing.s8),
            flexible('Ask · Summary', HomeFeedRowTile.askFlex),
            const SizedBox(width: BondSpacing.s8),
          ],
          cell('When', HomeFeedRowTile.whenWidth, align: TextAlign.right),
        ],
      ),
    );
  }
}
