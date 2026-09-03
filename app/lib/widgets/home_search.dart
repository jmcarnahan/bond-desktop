import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// The search box over the home feed.
///
/// Two gestures, one meaning: Escape and the clear affordance both leave
/// search and go back to the live table. Escape is bound HERE rather than on
/// the screen, so it only fires while the box holds focus — which is where the
/// hand that just searched already is, and the only place the key has an
/// obvious subject.
///
/// Stateless on purpose: the typed text belongs to the controller its owner
/// holds, so this widget can be rebuilt with new props without ever losing a
/// half-typed query.
class HomeSearchField extends StatelessWidget {
  /// The typed text, owned by the pane — the box is a view of it.
  final TextEditingController controller;

  /// Whether a search is up: results on screen, or a query in flight. What
  /// keeps the way out visible on a box the reader has stopped typing in.
  final bool active;

  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;

  /// Wide enough for a sentence, narrow enough that it stays a control in a
  /// title row rather than becoming the row.
  static const double maxWidth = 480;

  const HomeSearchField({
    super.key,
    required this.controller,
    required this.onSubmit,
    required this.onClear,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): onClear,
        },
        child: TextField(
          controller: controller,
          style: BondType.small,
          textInputAction: TextInputAction.search,
          // Submission and nothing else: every query is one embedding call,
          // so a search that ran per keystroke would spend a round trip on
          // every prefix of a word nobody has finished typing.
          onSubmitted: onSubmit,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search your messages',
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (!active && value.text.isEmpty) {
                  return const SizedBox.shrink();
                }
                return IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  splashRadius: 14,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Back to live',
                  onPressed: onClear,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
