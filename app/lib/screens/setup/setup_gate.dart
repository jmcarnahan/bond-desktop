import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/setup_store.dart';
import '../../models/setup_step.dart';
import '../../providers/app_providers.dart';
import '../../providers/setup_provider.dart';
import '../../services/attachments/file_dialogs.dart';
import 'setup_flow.dart';

/// Chooses the first-run wizard or the rest of the app, from one stored word.
///
/// Built on `AuthGate`'s pattern and for its reasons: it answers ONCE at
/// launch, and again only when the flow reports itself finished or when
/// "Set up again" bumps [setupRestartProvider]. A gate that re-decided on
/// every rebuild would swap the whole screen out from under a download.
///
/// It sits BETWEEN `ServerBootstrap` and `AuthGate`. Above the auth gate
/// because setting the machine up comes before signing in — the wizard has a
/// sign-in step of its own, and meeting a bare sign-in screen before anything
/// has explained what Bond is would be the app asking for credentials as its
/// opening line. Below the bootstrap because the server is wanted whether or
/// not the wizard is showing: somebody who has already set up and re-opened
/// the wizard still has models to serve.
class SetupGate extends ConsumerStatefulWidget {
  final Widget child;

  /// Passed straight to [SetupFlow] so a test can pick a models folder.
  final FileDialogs? fileDialogs;

  const SetupGate({super.key, required this.child, this.fileDialogs});

  /// `--dart-define=BOND_DEV_SKIP_SETUP=1` skips the wizard entirely.
  ///
  /// For the engineers who run `make model fast embed` by hand: their machine
  /// is already set up, their models are in the Homebrew cache rather than
  /// this app's folder, and a wizard offering to download twenty-three
  /// gigabytes they already have would be in the way of every `make app-run`.
  /// A define rather than a preference because it describes the BUILD, not
  /// the person — see `local.mk` in QUICKSTART.
  static const String skipDefine =
      String.fromEnvironment('BOND_DEV_SKIP_SETUP');

  /// Whether a define's VALUE means skip.
  ///
  /// Any non-empty value does, except the three ways a build script says no —
  /// `0`, `false`, `no`, in any case and with any whitespace around them.
  /// QUICKSTART tells people to write `=1`; this is here so that somebody who
  /// wrote `=0` to turn the skip back off gets the wizard rather than the
  /// opposite of what they typed.
  static bool skipsSetup(String define) {
    final value = define.trim().toLowerCase();
    if (value.isEmpty) return false;
    return value != '0' && value != 'false' && value != 'no';
  }

  @override
  ConsumerState<SetupGate> createState() => _SetupGateState();
}

class _SetupGateState extends ConsumerState<SetupGate> {
  late Future<bool> _done = _decide();

  Future<bool> _decide() async {
    if (SetupGate.skipsSetup(SetupGate.skipDefine)) return true;
    try {
      final stored = await ref.read(setupStoreProvider).get(SetupStore.setupKey);
      return stored == SetupStep.done.name;
    } on Object {
      // A store read that throws is treated as "not set up", exactly as
      // `AuthGate` treats an unreadable keychain: the wizard is the
      // recoverable answer, and its first step costs a click.
      return false;
    }
  }

  void _reload() {
    setState(() {
      _done = _decide();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(setupRestartProvider, (_, _) {
      // The controller goes with it. Its state is where the wizard stopped,
      // and a second run over the first one's `SetupState` would open at the
      // step the last run finished on.
      ref.invalidate(setupControllerProvider);
      _reload();
    });
    return FutureBuilder<bool>(
      future: _done,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == true) return widget.child;
        return SetupFlow(
          onFinished: _reload,
          fileDialogs: widget.fileDialogs,
        );
      },
    );
  }
}
