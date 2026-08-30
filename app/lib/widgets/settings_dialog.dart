import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// What the LO gets to say about how the inbox behaves, plus what Microsoft
/// has actually let this app do.
///
/// A dialog rather than a settings screen because there is very little in it,
/// and a screen with three things on it reads as a promise of more. It stays a
/// plain [StatefulWidget] over callbacks rather than reaching for the providers
/// itself, so the screen owns the wiring and a test can drive it with nothing
/// but closures.
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

  /// Answers "did Microsoft grant this bare scope". Null hides the whole
  /// permissions section, which is what a host with no auth wired wants.
  final Future<bool> Function(String bareScope)? hasScope;

  /// Starts a fresh sign-in, which is the only way a missing consent is ever
  /// fixed — a refresh cannot add a scope nobody consented to.
  final VoidCallback? onSignInAgain;

  const SettingsDialog({
    super.key,
    required this.threshold,
    required this.aboutMe,
    required this.onThresholdChanged,
    required this.onAboutMeChanged,
    this.hasScope,
    this.onSignInAgain,
  });

  /// The three extended permissions, in the order they matter to the LO, with
  /// the bare scope each one is really asking about.
  static const List<(String, String)> permissions = [
    ('Send mail', 'mail.send'),
    ('Save drafts', 'mail.readwrite'),
    ('Teams chats', 'chat.read'),
  ];

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

  /// Asked once, at construction, rather than on every build: a [FutureBuilder]
  /// handed a future built inside `build` re-runs the whole keychain read on
  /// every rebuild, including the ones the slider causes as it is dragged.
  late final Future<List<bool>>? _granted = widget.hasScope == null
      ? null
      : Future.wait([
          for (final (_, scope) in SettingsDialog.permissions)
            widget.hasScope!(scope),
        ]);

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
            ..._permissionsSection(),
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

  /// What Microsoft actually granted, and the one thing that can change it.
  ///
  /// It reports rather than persuades: a tick or a cross per permission, and
  /// the sign-in offer only when something is missing. A tenant that will not
  /// grant these is a tenant nobody in this dialog can argue with, so nagging
  /// about it every time the dialog opens would be noise.
  List<Widget> _permissionsSection() {
    final granted = _granted;
    if (granted == null) return const [];
    return [
      const SizedBox(height: BondSpacing.s24),
      Text(
        'Microsoft permissions',
        style: BondType.body.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: BondSpacing.s4),
      FutureBuilder<List<bool>>(
        future: granted,
        builder: (context, snapshot) {
          // Absent an answer, every row reads as not granted — the same thing
          // the composer assumes while it is waiting, so the two never
          // disagree on screen.
          final answers = snapshot.data ??
              List.filled(SettingsDialog.permissions.length, false);
          final missing = answers.contains(false);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < SettingsDialog.permissions.length; i++)
                _permissionRow(SettingsDialog.permissions[i].$1, answers[i]),
              if (missing && widget.onSignInAgain != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: widget.onSignInAgain,
                    child: const Text('Sign in again to enable'),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }

  Widget _permissionRow(String label, bool granted) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            granted ? Icons.check : Icons.close,
            size: 16,
            color: granted ? BondColors.success : BondColors.inkMuted,
          ),
          const SizedBox(width: BondSpacing.s8),
          Expanded(child: Text(label, style: BondType.small)),
        ],
      ),
    );
  }
}
