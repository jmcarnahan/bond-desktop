import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// The quick switcher, in the list column's own header.
///
/// Slack opens a palette over the app for this; the house rule is that nothing
/// opens over anything, so it is a field in the column it filters. That turns
/// out to be the better shape anyway: the rows narrow under the reader's eyes
/// as they type, so "the top match" is a thing they can SEE rather than a
/// promise the app makes about a list it is hiding.
///
/// Escape is bound HERE rather than on the screen, on `HomeSearchField`'s
/// precedent: it only fires while the box holds focus, which is where the hand
/// that just typed already is, and the only place the key has an obvious
/// subject. ⌘K, which has to work from anywhere, is bound on the screen.
///
/// Stateless: the text belongs to the controller its owner holds, so the field
/// can be rebuilt on every keystroke without losing a half-typed needle.
class FindField extends StatelessWidget {
  /// The typed text, owned by the screen — the box is a view of it.
  final TextEditingController controller;

  /// Owned by the screen too, because ⌘K has to be able to reach it from
  /// outside this widget's build.
  final FocusNode focusNode;

  /// Fired per keystroke. Find runs live, unlike search: it costs a list
  /// comprehension over rows already in memory, not a round trip.
  final ValueChanged<String> onChanged;

  /// Enter — open the first row still visible.
  final ValueChanged<String> onSubmit;

  /// Escape, and the ×.
  final VoidCallback onClear;

  /// What every finder in the suite reaches this box by.
  static const Key fieldKey = ValueKey('find-field');

  const FindField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmit,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onClear,
      },
      child: TextField(
        key: fieldKey,
        controller: controller,
        focusNode: focusNode,
        style: BondType.small.copyWith(color: BondColors.onDarkPrimary),
        textInputAction: TextInputAction.search,
        onChanged: onChanged,
        onSubmitted: onSubmit,
        cursorColor: BondColors.onDarkPrimary,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: BondColors.onDarkFaint,
          border: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: const BorderSide(color: BondColors.onDarkBorder),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s8,
            vertical: BondSpacing.s8,
          ),
          // The shortcut is in the hint because there is nowhere else to put
          // it: a rail this narrow has no room for a legend, and a binding
          // nobody is told about is a binding nobody uses.
          hintText: 'Find… ⌘K',
          hintStyle: BondType.small.copyWith(color: BondColors.onDarkMuted),
          prefixIcon: const Icon(
            Icons.search,
            size: 16,
            color: BondColors.onDarkMuted,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
          // Only once there is something to clear. An × over an empty box is a
          // control that does nothing, sitting in the width the hint needs.
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.close, size: 14),
                color: BondColors.onDarkMuted,
                splashRadius: 12,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Clear',
                onPressed: onClear,
              );
            },
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
        ),
      ),
    );
  }
}
