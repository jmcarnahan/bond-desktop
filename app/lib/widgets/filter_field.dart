import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// The light-pane live filter box: a magnifier, a hint, the typed needle, and
/// a × that empties it.
///
/// It filters as you type — it narrows rows already in memory, so there is
/// nothing to submit and no Enter to press. That is what separates it from
/// `FindField`, which lives on the dark rail and whose Enter opens the top
/// match, and from the archive's search box, which asks the store a question
/// and costs a round trip.
///
/// Escape clears, bound HERE rather than on the host screen on `FindField`'s
/// precedent: it only fires while the box holds focus, which is where the hand
/// that just typed already is, and the only place the key has an obvious
/// subject.
///
/// Stateless over the controller its owner holds, so the field can be rebuilt
/// on every keystroke without losing a half-typed needle.
class FilterField extends StatelessWidget {
  /// The typed text, owned by the pane — the box is a view of it.
  final TextEditingController controller;

  /// Fired per keystroke, and with the empty string when the box is cleared.
  final ValueChanged<String> onChanged;

  final String hint;

  final FocusNode? focusNode;

  static const Key clearKey = ValueKey('filter-field-clear');

  const FilterField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hint,
    this.focusNode,
  });

  void _clear() {
    controller.clear();
    onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _clear,
      },
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        style: BondType.body,
        onChanged: onChanged,
        cursorColor: BondColors.ink,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: BondType.body.copyWith(color: BondColors.inkMuted),
          border: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: const BorderSide(color: BondColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: const BorderSide(color: BondColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: const BorderSide(color: BondColors.primary),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s8,
            vertical: BondSpacing.s8,
          ),
          prefixIcon: const Icon(
            Icons.search,
            size: 16,
            color: BondColors.inkMuted,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          // Only once there is something to clear. An × over an empty box is a
          // control that does nothing, sitting in the width the hint needs.
          //
          // Listening to the controller directly rather than to the owner's
          // rebuild, so the × appears on the keystroke that earned it however
          // the host is built.
          suffixIcon: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (controller.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                key: clearKey,
                icon: const Icon(Icons.close, size: 14),
                color: BondColors.inkMuted,
                splashRadius: 12,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Clear',
                onPressed: _clear,
              );
            },
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
        ),
      ),
    );
  }
}
