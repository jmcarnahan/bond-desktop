import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/setup_store.dart';
import '../../models/setup_step.dart';
import '../../providers/app_providers.dart';
import '../../providers/prefs_provider.dart';
import '../../providers/setup_provider.dart';
import '../../services/attachments/file_dialogs.dart';
import '../../services/llm/model_slots.dart';
import '../../services/models/model_manifest.dart';
import '../../services/system/system_info.dart';
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
  late Future<bool> _done = _decideAndSay();

  /// [_decide], and then what follows from the answer, said in the callback
  /// the answer arrives in rather than during a build: [setupShowingProvider]
  /// follows what is on screen, and a gate that lets the APP through kicks
  /// the model ensurer, which downloads what the placements need and the
  /// disk lacks (decision D6). That covers a launch, the return after
  /// Finish, and `BOND_DEV_SKIP_SETUP`. A gate that shows the WIZARD hands
  /// it the one downloader instead ([_handToWizard]).
  Future<bool> _decideAndSay() async {
    final done = await _decide();
    if (mounted) {
      if (done) {
        ref.read(setupShowingProvider.notifier).state = false;
        unawaited(ref.read(modelEnsurerProvider).ensure());
      } else {
        _handToWizard();
      }
    }
    return done;
  }

  /// The wizard owns the downloader from here: the flag goes up, so the
  /// model ensurer starts nothing, and a run the ensurer has in flight is
  /// cancelled with its parts kept, so the wizard's own run resumes from the
  /// byte (its `startDownload` waits for the cancelled run to end).
  void _handToWizard() {
    ref.read(setupShowingProvider.notifier).state = true;
    unawaited(ref.read(modelEnsurerProvider).standDown());
  }

  /// Set up, AND set up against the models this build ships FOR THIS MAC.
  ///
  /// The stored word alone is not enough. A manifest bump that keeps the file
  /// names leaves a machine whose `setup` still says `done` and whose weights
  /// are the previous checkpoint — and a gate that let it through would serve
  /// those weights for ever, since nothing downstream compares digests. The
  /// ledger is the cheap way to notice: the wizard opens on its download step
  /// and fetches what has moved.
  ///
  /// The comparison is against [managedManifestProvider]'s GATING view: the
  /// Hugging Face files this Mac serves under the role placements, on the
  /// memory of the Mac this launch is on. A models folder carried to a
  /// smaller Mac holds a writing model that machine will not start, and a
  /// gate demanding it would send a finished setup back through the wizard
  /// for a file it is never going to want. The decision model is never
  /// demanded, whether hand-installed or from the model registry (decision
  /// D7): a missing one parks the decision pass rather than forcing the
  /// wizard, whose screens cannot reach the registry address in Settings.
  ///
  /// `DownloadLedger.matches` asks whether every file the RESOLVED manifest
  /// names is current and says nothing about the rest, so an install that
  /// moves a role to its own server after a full download keeps the files on
  /// disk and still passes.
  Future<bool> _decide() async {
    if (SetupGate.skipsSetup(SetupGate.skipDefine)) return true;
    try {
      final store = ref.read(setupStoreProvider);
      final stored = await store.get(SetupStore.setupKey);
      if (stored != SetupStep.done.name) return false;
      // READ and awaited ONCE, never watched: this gate answers once, and a
      // manifest or a tier provider it subscribed to would be a second way to
      // rebuild it.
      //
      // And it is the one await on this path that a platform could hold open.
      // A channel that hangs would leave the launch on a spinner; one that
      // throws would fall into the catch below and send a machine that IS set
      // up back through the wizard. Both answer the same way instead: unknown
      // memory, which is the full tier.
      ModelManifest served;
      try {
        served = await ref
            .read(managedManifestProvider.future)
            .timeout(hardwareProbeTimeout);
      } on Object {
        // The same roles on the tier unknown memory answers (the full one),
        // so a role on the owner's server is not demanded here either.
        final prefs = ref.read(appPrefsProvider);
        final tier = machineTierFor(HardwareInfo.unknown.memoryBytes);
        served = ref.read(modelManifestProvider).forRoles(
              hardwareTier: tier,
              decisionManaged: prefs.decisionSpec.id == localDecisionId,
              generativeManagedId: prefs.managedServer &&
                      prefs.generativeSpec.id == localGenerativeId
                  ? managedGenerativeIdFor(tier, prefs.generativeManagedModel)
                  : null,
            );
      }
      // The GATING entries only (decision D7): a registry file is
      // best-effort, and a missing or failed one parks its role rather than
      // sending a finished install back through the wizard.
      return (await store.downloadLedger()).matches(served.gating);
    } on Object {
      // A store read that throws is treated as "not set up", exactly as
      // `AuthGate` treats an unreadable keychain: the wizard is the
      // recoverable answer, and its first step costs a click.
      return false;
    }
  }

  void _reload() {
    setState(() {
      _done = _decideAndSay();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(setupRestartProvider, (_, _) {
      // The controller goes with it. Its state is where the wizard stopped,
      // and a second run over the first one's `SetupState` would open at the
      // step the last run finished on.
      ref.invalidate(setupControllerProvider);
      // At once, not when the new answer arrives: the wizard is coming.
      _handToWizard();
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
