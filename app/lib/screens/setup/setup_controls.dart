import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The key EVERY step's primary button carries.
///
/// One key across eight different labels — `Get started`, `Continue`,
/// `Finish` — because a test walking the flow presses "the button that moves
/// this on", and keying each step separately would make that walk a list of
/// eight labels to keep in step with the copy.
///
/// It lives here rather than on `SetupFlow` so the bodies can reach it
/// without importing the host that lays them out; `SetupFlow.continueKey` is
/// this constant under the name the host reads by.
const Key setupContinueKey = ValueKey('setup-continue');

/// The wizard's primary button — `SignInScreen`'s look, full width, one to a
/// step.
///
/// A null [onPressed] renders it DISABLED rather than absent, which is the
/// opposite of this app's usual rule about null callbacks and is deliberate:
/// on a wizard the way forward must be visible even while it is not
/// available, or the step reads as a dead end.
class SetupPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  /// Replaces the label with a spinner while the press is still working.
  final bool busy;

  const SetupPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        key: setupContinueKey,
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: BondColors.primary,
          foregroundColor: BondColors.surface,
          padding: const EdgeInsets.symmetric(vertical: BondSpacing.s16),
          shape: const RoundedRectangleBorder(borderRadius: BondRadii.smAll),
        ),
        child: busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: BondColors.surface,
                ),
              )
            : Text(
                label,
                style: BondType.body.copyWith(color: BondColors.surface),
              ),
      ),
    );
  }
}

/// One `<label>  <value>` line, the shape the device and done steps read in.
///
/// The label column is fixed so the values line up down the pane; it wraps
/// rather than clips, because a models path is longer than any column.
class SetupFactRow extends StatelessWidget {
  final String label;
  final String value;

  /// The value in mono — paths, and nothing else.
  final bool mono;

  const SetupFactRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: BondType.small.copyWith(color: BondColors.inkSecondary),
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          Expanded(
            child: Text(value, style: mono ? BondType.mono : BondType.body),
          ),
        ],
      ),
    );
  }
}
