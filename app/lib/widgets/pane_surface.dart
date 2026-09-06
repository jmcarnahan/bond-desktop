import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The bordered surface and titled header every full-pane screen wears, so a
/// pane reads as the main pane changing rather than as an overlay.
///
/// Generalised out of the storyline pickers' private copy when Settings became
/// a screen: Settings is the first pane deep enough that Back alone is not
/// enough of a way out, so [onHome] exists — one click to the landing screen
/// from anywhere, rather than Back-Back-Back through wherever the user came
/// from.
class PaneSurface extends StatelessWidget {
  final String title;

  /// Leaves the pane, back to whatever was underneath.
  final VoidCallback onBack;

  /// Goes straight to Home. Null renders no home affordance at all — panes
  /// reached from a single click do not need one.
  final VoidCallback? onHome;

  /// Anything the pane wants at the right end of the header. Null renders
  /// nothing; the title takes the space.
  final Widget? trailing;

  final Widget child;

  const PaneSurface({
    super.key,
    required this.title,
    required this.onBack,
    this.onHome,
    this.trailing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final home = onHome;
    return Container(
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
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
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                  iconSize: 20,
                  tooltip: 'Back',
                ),
                const SizedBox(width: BondSpacing.s4),
                // The title yields first: it is an Expanded with one ellipsised
                // line so that a long name, or a large text scale, never pushes
                // the home button or the trailing slot off the end.
                Expanded(
                  child: Text(
                    title,
                    style: BondType.titleSm,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (home != null) ...[
                  const SizedBox(width: BondSpacing.s8),
                  // Labelled, not an icon alone: Home is a destination rather
                  // than a control, and the rail's bolt is not a glyph anyone
                  // reads as "home" without the word beside it.
                  Tooltip(
                    message: 'Home',
                    child: TextButton.icon(
                      onPressed: home,
                      icon: const Icon(Icons.bolt, size: 18),
                      label: const Text('Home'),
                    ),
                  ),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: BondSpacing.s8),
                  trailing!,
                ],
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
