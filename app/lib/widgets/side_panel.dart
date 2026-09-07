import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../providers/draft_provider.dart' show DraftTarget;
import '../theme/tokens.dart';
import 'app_rail.dart' show AppRail;

/// What is open beside the main pane, if anything.
///
/// One sealed type rather than a field per surface: the side panel shows
/// exactly one thing, and the shell decides which by asking what this is. A
/// second nullable field per kind is how the file preview and the full viewer
/// drifted apart — one could be set while the other said something else.
///
/// Phase 5/6 add `AboutPanel(storylineId)`, `PersonPanel(roomKey)` and
/// `WhyPanel(source, messageId)` here.
sealed class SidePanel {
  const SidePanel();
}

/// A conversation read beside whatever opened it — a storyline's episode card,
/// a person room's root message. The thread the MAIN pane is showing is not
/// this: that one is `_selectedId`, and the two are independent on purpose.
final class ThreadPanel extends SidePanel {
  final String source;
  final String conversationKey;

  const ThreadPanel({required this.source, required this.conversationKey});
}

/// A file read beside the thread or the storyline it was opened from.
final class FilePanel extends SidePanel {
  final AttachmentRef attachment;

  /// The conversation the file was opened from, where there was one — a
  /// storyline's shelf has none. It is what 'Use in reply' writes into and
  /// what a pin resolves its storyline through: the panel itself only knows
  /// about the file, and a draft keyed by the file would have nowhere to go.
  final DraftTarget? from;

  const FilePanel({required this.attachment, this.from});
}

/// The chrome around whatever is open beside the main pane: a title, the way
/// to give it the whole pane, and the way to close it.
///
/// Lifted out of `AttachmentPreviewPanel._header` so that every side panel
/// wears the same header whatever it holds — the preview renders with
/// `showHeader: false` inside this one rather than drawing a second header of
/// its own. The ⤢ and ✕ are THIS widget's, which is why the keys live here:
/// one owner for the two controls, whatever is in the panel.
class SidePanelHost extends StatelessWidget {
  /// One line, ellipsised. The file's name, the thread's subject.
  final String title;

  /// The quieter second line — who is on the thread. Null renders none.
  final String? subtitle;

  /// A glyph before the title: the file's kind mark, a source mark. Null
  /// leaves the title against the edge.
  final Widget? leading;

  /// Gives the panel the whole main pane. Null hides the control — a thread
  /// that no longer exists has nowhere to expand to.
  final VoidCallback? onExpand;

  final VoidCallback onClose;

  /// Anything the panel wants at the right end of the header, before the two
  /// controls. The file's size rides here.
  final Widget? trailing;

  final Widget child;

  const SidePanelHost({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.onExpand,
    required this.onClose,
    this.trailing,
    required this.child,
  });

  static const Key expandKey = ValueKey('side-panel-expand');
  static const Key closeKey = ValueKey('side-panel-close');

  /// How much of the space beside the rail the panel asks for, and the widths
  /// that stop it asking for too much.
  ///
  /// Two minimums, because the two panels are not the same reader's problem: a
  /// file under [fileMinWidth] is a column of clipped words, while a thread
  /// carries `ThreadDetailPanel`'s header — a Back arrow, a state chip, Mark
  /// done and an overflow menu, all of which take their width out of the
  /// subject — and stops being readable a good deal earlier. [threadMinWidth]
  /// is the transcript minimum the thread pane's own split already used.
  static const double fraction = 0.45;
  static const double fileMinWidth = 360;
  static const double threadMinWidth = 420;
  static const double maxWidth = 640;

  /// What the MAIN pane keeps whatever the side panel asks for. The same 420:
  /// it is the same transcript widget on the other side of the seam.
  static const double mainMinWidth = 420;

  /// The panel's width beside a main pane of [mainMinWidth] or more, or null
  /// when the two cannot both be had — in which case the panel REPLACES main
  /// rather than squeezing it, the same call the rail makes at its own
  /// breakpoint.
  ///
  /// [available] is measured POST-RAIL: the window less the rail's 260, its
  /// 1px divider and the 16px seam. The shell applies its two-pane breakpoint
  /// to that figure rather than to the window, so the split appears from a
  /// window of 1237px — close to the 1269 the thread pane's own split needed
  /// when this math lived inside its 24px padding.
  static double? widthFor({
    required double available,
    required double minWidth,
    required double mainMinWidth,
  }) {
    var width = (available * fraction).clamp(minWidth, maxWidth).toDouble();
    if (available - width < mainMinWidth) width = available - mainMinWidth;
    if (width < minWidth) return null;
    return width;
  }

  /// What [widthFor] measures against, from the whole window.
  static double availableBesideRail(double windowWidth) =>
      windowWidth - AppRail.width - 1 - BondSpacing.s16;

  @override
  Widget build(BuildContext context) {
    final expand = onExpand;
    final subtitle = this.subtitle;
    final leading = this.leading;
    final trailing = this.trailing;
    // A Material, not a decorated Container: rows inside the panel paint their
    // ink on the nearest Material, and a decoration over that ancestor would
    // swallow it (Flutter 3.47 asserts on exactly this shape).
    return Material(
      color: BondColors.surface,
      shape: const Border(left: BorderSide(color: BondColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BondSpacing.s16,
              vertical: BondSpacing.s12,
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading,
                  const SizedBox(width: BondSpacing.s8),
                ],
                // The title yields first: it is the one child that can give,
                // and everything beside it is either a control or a fact that
                // does not ellipsise.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style:
                            BondType.body.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: BondType.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: BondSpacing.s8),
                  trailing,
                ],
                if (expand != null)
                  IconButton(
                    key: expandKey,
                    onPressed: expand,
                    icon: const Icon(Icons.open_in_full),
                    iconSize: 18,
                    tooltip: 'Expand',
                  ),
                IconButton(
                  key: closeKey,
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                  iconSize: 18,
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: BondColors.border),
          Expanded(child: child),
        ],
      ),
    );
  }
}
