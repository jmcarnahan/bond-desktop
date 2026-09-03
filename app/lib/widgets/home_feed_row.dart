import 'package:flutter/material.dart';

import '../models/home_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
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

  /// The machine-readable drop reasons in the words a person would use.
  /// Anything unmapped falls back to the raw reason with its underscores
  /// opened up — a reason a newer build introduced reads awkwardly rather than
  /// rendering an empty chip.
  static const Map<String, String> dropLabels = {
    'fyi': 'FYI',
    'newsletter': 'Newsletter',
    'auto_generated': 'Automated',
    'no_reply': 'No reply needed',
    'not_worthy': 'Nothing to do',
    'outbound': 'Outbound',
    'self': 'Your own',
    'empty': 'Empty',
    'backlog': 'Backlog',
    'gated': 'Filtered',
  };

  static String dropLabel(String? reason) {
    if (reason == null || reason.isEmpty) return 'Dropped';
    return dropLabels[reason] ?? reason.replaceAll('_', ' ');
  }

  final HomeFeedRow row;

  /// The clock, injected so a test pins what "3h ago" means.
  final DateTime now;

  /// Whether this row is arriving now, rather than having been read off a
  /// page. False renders it whole on the first frame with nothing animating —
  /// which is every row this build ships; the live phase is what sets it.
  final bool animateIn;

  final void Function(String source, String conversationKey) onOpenThread;
  final void Function(String storylineId) onOpenStoryline;

  const HomeFeedRowTile({
    super.key,
    required this.row,
    required this.now,
    required this.onOpenThread,
    required this.onOpenStoryline,
    this.animateIn = false,
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

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    return AnimatedSlide(
      duration: HomeFeedRowTile.entryDuration,
      curve: Curves.easeOut,
      offset: _settled ? Offset.zero : const Offset(0, -0.4),
      child: AnimatedOpacity(
        duration: HomeFeedRowTile.entryDuration,
        curve: Curves.easeOut,
        opacity: _settled ? 1 : 0,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => widget.onOpenThread(row.source, row.conversationKey),
            hoverColor: BondColors.faintGround,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: BondSpacing.s4,
                vertical: BondSpacing.s8,
              ),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: BondColors.border)),
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
                      muted: row.outcome != 'pending',
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
    );
  }

  /// What the app decided, in priority order.
  ///
  /// A dropped row shows its reason and NOTHING else: it is behind the toggle
  /// precisely because the app judged it did not need the user, and a "Needs
  /// You" chip beside "Newsletter" would be the app arguing with itself.
  /// Everything else can co-occur — a thread can be both the user's to answer
  /// and part of a storyline, and both facts are worth a glance.
  Widget _result(HomeFeedRow row) {
    if (row.dropped) {
      return Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s4,
        children: [
          BondChip.semantic(
            HomeFeedRowTile.dropLabel(row.dropReason),
            BondTone.neutral,
          ),
        ],
      );
    }

    final storylineId = row.storylineId;
    final storylineTitle = row.storylineTitle;
    final chips = <Widget>[
      if (row.needsYou)
        BondChip.semantic(
          'Needs You',
          row.urgency == 'urgent' ? BondTone.error : BondTone.attention,
        ),
      // Both halves, because the tap needs the id and the reader needs the
      // name: a title with no id behind it would be a link to nowhere.
      if (storylineId != null && (storylineTitle?.isNotEmpty ?? false))
        _storylineLink(storylineId, storylineTitle!),
    ];

    // Nothing decided yet, or nothing to say about it. A dash rather than a
    // blank: an empty cell in a table reads as missing data.
    if (chips.isEmpty) return Text('—', style: BondType.caption);

    return Wrap(
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s4,
      children: chips,
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
