import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/calendar/write_rules.dart' show emailedLine;
import '../theme/tokens.dart';

/// The inline confirm a calendar write waits on: what it will do, who it
/// will email, and Send or Cancel.
///
/// Inline, in the place the write was asked for, and never a dialog (the
/// house rule): the person is looking at the meeting when they press, and
/// the confirm belongs beside it. Enter confirms and Escape dismisses, so a
/// keyboard-driven RSVP is Yes, Enter. While [busy] both buttons are off and
/// neither key does anything — a second Enter must not send twice.
///
/// It takes the keyboard when it appears, explicitly rather than by
/// `autofocus` alone: the press that raised it was often an Enter in a field
/// that still holds focus, and autofocus yields to a focused field — which
/// would leave Enter re-submitting the field instead of confirming.
class WriteConfirmStrip extends StatefulWidget {
  const WriteConfirmStrip({
    super.key,
    required this.summary,
    required this.notifies,
    required this.confirmLabel,
    required this.dismissLabel,
    required this.onConfirm,
    required this.onDismiss,
    this.busy = false,
  });

  static const Key confirmKey = ValueKey('write-confirm-send');
  static const Key dismissKey = ValueKey('write-confirm-dismiss');
  static const Key emailsKey = ValueKey('write-confirm-emails');

  final String summary;

  /// The addresses the dry run said the write would email.
  final List<String> notifies;
  final String confirmLabel;
  final String dismissLabel;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;
  final bool busy;

  @override
  State<WriteConfirmStrip> createState() => _WriteConfirmStripState();
}

class _WriteConfirmStripState extends State<WriteConfirmStrip> {
  final FocusNode _focus = FocusNode(debugLabel: 'write-confirm');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.busy;
    final emails = emailedLine(widget.notifies);
    // [WriteConfirmStrip.busy] is read when the key or the press lands, not
    // when this frame was built: the shortcuts and the buttons share these
    // two, and neither acts while a send is in flight.
    void confirm() {
      if (!widget.busy) widget.onConfirm();
    }

    void dismiss() {
      if (!widget.busy) widget.onDismiss();
    }

    return CallbackShortcuts(
      bindings: {
        // No repeats: a held Enter is one send.
        const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
            confirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter,
            includeRepeats: false): confirm,
        const SingleActivator(LogicalKeyboardKey.escape): dismiss,
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Container(
          padding: const EdgeInsets.all(BondSpacing.s12),
          decoration: BoxDecoration(
            color: BondColors.primaryTint,
            border: Border.all(color: BondColors.primaryTintBorder),
            borderRadius: BondRadii.mdAll,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.summary, style: BondType.small),
              if (emails != null) ...[
                const SizedBox(height: BondSpacing.s4),
                Text(
                  emails,
                  key: WriteConfirmStrip.emailsKey,
                  style: BondType.caption
                      .copyWith(color: BondColors.inkSecondary),
                ),
              ],
              const SizedBox(height: BondSpacing.s8),
              Wrap(
                spacing: BondSpacing.s8,
                runSpacing: BondSpacing.s4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    key: WriteConfirmStrip.confirmKey,
                    onPressed: busy ? null : confirm,
                    child: Text(widget.confirmLabel),
                  ),
                  TextButton(
                    key: WriteConfirmStrip.dismissKey,
                    onPressed: busy ? null : dismiss,
                    child: Text(widget.dismissLabel),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
