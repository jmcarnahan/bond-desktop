import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../sign_in_screen.dart' show SignInBody;
import 'setup_controls.dart';

/// Step six: the same sign-in the gate shows, inside the wizard's pane.
///
/// It hosts [SignInBody] rather than reimplementing it. That body reads
/// providers of its own, which is allowed here for the reason it is allowed
/// anywhere: it is an existing screen component with its own behaviour — a
/// browser handoff, an identity guard, an MCP connect step — and a prop-only
/// copy of it would be a second implementation to keep in step.
///
/// There is NO Continue while signed out: signing in is what advances the
/// step, and a button beside it would offer a way past the one thing this
/// step is for. Somebody already signed in — anybody who reached the wizard
/// through "Set up again" — sees one sentence and a Continue.
class SetupSignInBody extends StatelessWidget {
  final bool signedIn;

  /// Fired by [SignInBody] once tokens are stored.
  final VoidCallback onSignedIn;

  final VoidCallback onContinue;

  const SetupSignInBody({
    super.key,
    required this.signedIn,
    required this.onSignedIn,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    if (!signedIn) {
      return SignInBody(onSignedIn: onSignedIn, showTitle: false);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("You're signed in.", style: BondType.body),
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(label: 'Continue', onPressed: onContinue),
      ],
    );
  }
}
