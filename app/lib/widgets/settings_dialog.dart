import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The two things the LO gets to say about how the inbox behaves.
///
/// A dialog rather than a settings screen because there are two of them, and a
/// screen with two controls on it reads as a promise of more. It stays a plain
/// [StatefulWidget] over callbacks rather than reaching for the providers
/// itself, so the screen owns the wiring and a test can drive it with nothing
/// but a pair of closures.
class SettingsDialog extends StatefulWidget {
  /// Where the Needs You cut sits now, 0..1.
  final double threshold;

  final String aboutMe;

  /// Fired when the user lets go of the slider, not on every pixel of the
  /// drag: each call writes a preference and reloads the list, and doing that
  /// sixty times a second would make the slider feel like it was fighting back.
  final void Function(double value) onThresholdChanged;

  /// Fired once, when the dialog closes. Text is not a thing to save per
  /// keystroke, and there is nothing on screen waiting to read it.
  final void Function(String value) onAboutMeChanged;

  const SettingsDialog({
    super.key,
    required this.threshold,
    required this.aboutMe,
    required this.onThresholdChanged,
    required this.onAboutMeChanged,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late double _threshold = widget.threshold.clamp(0.0, 1.0);
  late final TextEditingController _aboutMe =
      TextEditingController(text: widget.aboutMe);

  /// Ten stops. Enough that the slider feels like it has an opinion, few enough
  /// that the same drag lands on the same value twice.
  static const int _divisions = 10;

  @override
  void dispose() {
    // On the way out, whichever way the dialog was dismissed — the Done button,
    // the scrim, or Escape. A save wired to the button alone would quietly lose
    // the text of anyone who clicks outside, which is most people.
    widget.onAboutMeChanged(_aboutMe.text);
    _aboutMe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'How much lands in Needs You',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: BondSpacing.s4),
            // The direction is the thing worth stating: the slider raises a
            // score threshold, so RIGHT means more mail, and a label-less
            // slider would leave that a coin flip.
            Slider(
              value: 1 - _threshold,
              divisions: _divisions,
              onChanged: (value) => setState(() => _threshold = 1 - value),
              onChangeEnd: (value) => widget.onThresholdChanged(1 - value),
            ),
            // Both halves flex: the labels are long enough relative to the
            // dialog that a fixed Row overflows at the default text scale.
            Row(
              children: [
                Expanded(
                  child: Text('Only the critical', style: BondType.caption),
                ),
                Expanded(
                  child: Text(
                    'Anything plausible',
                    style: BondType.caption,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: BondSpacing.s24),
            Text(
              'About me & my role',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: BondSpacing.s4),
            TextField(
              controller: _aboutMe,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'e.g. I am a loan officer; I own rate locks and '
                    'closing dates, my processor handles document chasing.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
