import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'home_result.dart';
import 'source_glyph.dart';
import 'stage_bar.dart';
import 'time_format.dart';

/// One message in the home feed: who it is from, what it is about, how far
/// through the pipeline it got, what the app decided, and when it arrived.
///
/// A table row and not a card. The question this screen answers is
/// comparative — "is everything moving?", "what got dropped this morning?" —
/// and comparison needs columns that line up; a border per row at this density
/// is a grid of boxes rather than a table, so a single hairline underneath
/// carries the separation. The widths live here as consts and
/// [HomeFeedHeaderRow] reads the same ones, which is the only thing keeping
/// the header honest.
///
/// The Result cell is a SENTENCE with the reason in it — [resultLine] decides
/// which one — rather than a chip that names a verdict and leaves the reader
/// to guess what stood behind it. Three gestures nest inside it, and the
/// innermost wins the arena in this order: the row itself opens the thread,
/// the storyline name opens the storyline, and Retry requeues what the row
/// still owes.
class HomeFeedRowTile extends StatefulWidget {
  static const double glyphWidth = 20;
  static const double fromWidth = 160;
  static const double barWidth = HomeStageBar.trackWidth;
  static const double whenWidth = 76;

  /// Subject and Result share what is left, three to two. The subject is what
  /// a reader scans; the result is a chip or two.
  static const int subjectFlex = 3;
  static const int resultFlex = 2;

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

  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;

  /// Puts the stages the row still owes back on their queues. Optional, and
  /// null is what the archive pane passes: a dropped row is Restore's
  /// business, and a Retry there would offer to re-run a pipeline that is
  /// going to refuse the message again at the first gate.
  final void Function(String source, String sourceMessageId)? onRetry;

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
    this.onRetry,
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
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: HomeFeedRowTile.glyphWidth,
                        child: Text(
                          sourceChipPrefix(row.source),
                          style: BondType.small,
                        ),
                      ),
                      const SizedBox(width: BondSpacing.s8),
                      SizedBox(
                        width: HomeFeedRowTile.fromWidth,
                        child: Text(
                          row.fromName ?? row.fromAddress ?? '(no sender)',
                          style: BondType.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: BondSpacing.s8),
                      Expanded(
                        flex: HomeFeedRowTile.subjectFlex,
                        child: Text(
                          (row.subject?.isNotEmpty ?? false)
                              ? row.subject!
                              : '(no subject)',
                          style: BondType.small.copyWith(color: BondColors.ink),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: BondSpacing.s8),
                      SizedBox(
                        width: HomeFeedRowTile.barWidth,
                        child: HomeStageBar.forRow(
                          row,
                          // A finished row's bar is history, not progress.
                          muted: widget.muteBar || row.outcome != 'pending',
                        ),
                      ),
                      const SizedBox(width: BondSpacing.s8),
                      Expanded(
                        flex: HomeFeedRowTile.resultFlex,
                        child: _result(row),
                      ),
                      const SizedBox(width: BondSpacing.s8),
                      SizedBox(
                        width: HomeFeedRowTile.whenWidth,
                        child: Text(
                          relativeTime(row.receivedAt, widget.now) ?? '',
                          style: BondType.caption,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// What the app decided, as a sentence with its reason.
  ///
  /// A dropped row shows its reason and NOTHING else: it is behind the toggle
  /// precisely because the app judged it did not need the user, and a "Needs
  /// You" chip beside "Newsletter" would be the app arguing with itself.
  /// Everything else can co-occur — a thread can be both the user's to answer
  /// and part of a storyline — so a sentence that is not about the filing
  /// still carries the storyline link after it.
  ///
  /// Which sentence is [resultLine]'s judgement, not this widget's. All that
  /// happens here is the dressing.
  Widget _result(HomeFeedRow row) {
    final result = resultLine(row, now: widget.now);
    final storylineId = row.storylineId;
    final storylineTitle = row.storylineTitle;
    final linked = storylineId != null && (storylineTitle?.isNotEmpty ?? false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (row.needsYou && !row.dropped) ...[
          BondChip.semantic(
            'Needs You',
            row.urgency == 'urgent' ? BondTone.error : BondTone.attention,
          ),
          const SizedBox(width: BondSpacing.s8),
        ],
        Expanded(child: _sentence(result, row)),
        // Already inside the sentence when the sentence IS the filing.
        if (!row.dropped &&
            linked &&
            result.kind != HomeResultKind.filed) ...[
          const SizedBox(width: BondSpacing.s8),
          Flexible(child: _storylineLink(storylineId, storylineTitle!)),
        ],
        if (result.retryable && widget.onRetry != null) ...[
          const SizedBox(width: BondSpacing.s8),
          _retryLink(row),
        ],
      ],
    );
  }

  /// The sentence itself, under a tooltip carrying the whole of it — the cell
  /// is two flexible columns wide and most reasons are longer than that.
  ///
  /// A filed row is built from three pieces rather than one string, because
  /// the storyline's name in the middle has to stay tappable; the words either
  /// side of it are the same sentence [resultLine] already composed.
  Widget _sentence(HomeResult result, HomeFeedRow row) {
    final style = BondType.small.copyWith(
      color: bondToneColors[result.tone]!.foreground,
    );
    if (result.kind == HomeResultKind.filed) {
      final evidence = homeFiledEvidence(row);
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
            if (evidence != null)
              Flexible(
                child: Text(
                  ' — $evidence',
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
        ),
      ),
    );
  }

  /// The storyline the message was filed under, as a link.
  ///
  /// Its own [InkWell] inside the row's: the innermost gesture wins the arena,
  /// so tapping the name opens the storyline and tapping anywhere else on the
  /// row opens the thread.
  Widget _storylineLink(String id, String title) {
    return Tooltip(
      message: title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => widget.onOpenStoryline(id),
          borderRadius: BondRadii.smAll,
          child: Text(
            title,
            style: BondType.small.copyWith(
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
class HomeFeedHeaderRow extends StatelessWidget {
  const HomeFeedHeaderRow({super.key});

  @override
  Widget build(BuildContext context) {
    Widget cell(String text, double width, {TextAlign? align}) => SizedBox(
          width: width,
          child: Text(text, style: BondType.label, textAlign: align),
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
          Expanded(
            flex: HomeFeedRowTile.subjectFlex,
            child: Text('Subject', style: BondType.label),
          ),
          const SizedBox(width: BondSpacing.s8),
          cell('Pipeline', HomeFeedRowTile.barWidth),
          const SizedBox(width: BondSpacing.s8),
          Expanded(
            flex: HomeFeedRowTile.resultFlex,
            child: Text('Result', style: BondType.label),
          ),
          const SizedBox(width: BondSpacing.s8),
          cell('When', HomeFeedRowTile.whenWidth, align: TextAlign.right),
        ],
      ),
    );
  }
}
