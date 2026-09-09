import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One button on the strip.
class HoverAction {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Key? key;

  const HoverAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.key,
  });
}

/// The small strip of per-message actions that appears at a row's top-right
/// under the mouse — Slack's own gesture, and for Slack's reason: a transcript
/// where every row wore its buttons all the time would be a column of controls
/// with some words between them.
///
/// A WRAPPER around the row rather than a change to it. `MessageRow` seeds its
/// collapsed state once, from what it was handed; hover is a per-frame fact
/// about the pointer, and putting it inside the row would rebuild the message
/// every time the mouse crossed it.
///
/// Touch never enters a [MouseRegion], so the strip never appears on a
/// touchscreen. Nothing here may be the ONLY way to do a thing — every action
/// on this strip has a home somewhere the pointer is not needed.
class HoverActions extends StatefulWidget {
  final Widget child;
  final List<HoverAction> actions;

  const HoverActions({
    super.key,
    required this.child,
    required this.actions,
  });

  static Key replyKeyFor(String messageId) => ValueKey('hover-reply-$messageId');

  static Key suggestKeyFor(String messageId) =>
      ValueKey('hover-suggest-$messageId');

  /// The third button: why this message got the verdict it did.
  static Key whyKeyFor(String messageId) => ValueKey('hover-why-$messageId');

  /// The fourth: every stage, judgement and queue row behind this message.
  static Key historyKeyFor(String messageId) =>
      ValueKey('hover-history-$messageId');

  @override
  State<HoverActions> createState() => _HoverActionsState();
}

class _HoverActionsState extends State<HoverActions> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Nothing to offer is not an empty strip, it is no MouseRegion at all: an
    // outbound row would otherwise pay for a hover listener that could never
    // draw anything.
    if (widget.actions.isEmpty) return widget.child;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_hovered)
            Positioned(
              top: 0,
              right: 0,
              child: Material(
                color: BondColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BondRadii.smAll,
                  side: const BorderSide(color: BondColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in widget.actions)
                      IconButton(
                        key: action.key,
                        onPressed: action.onTap,
                        icon: Icon(action.icon),
                        iconSize: 16,
                        tooltip: action.tooltip,
                        padding: const EdgeInsets.all(BondSpacing.s4),
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
