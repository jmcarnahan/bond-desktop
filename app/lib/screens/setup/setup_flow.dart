import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/setup_step.dart';
import '../../providers/app_providers.dart';
import '../../providers/setup_provider.dart';
import '../../services/attachments/file_dialogs.dart';
import '../../services/models/model_manifest.dart';
import '../../theme/tokens.dart';
import '../../widgets/pane_surface.dart';
import 'setup_controls.dart';
import 'setup_device_body.dart';
import 'setup_done_body.dart';
import 'setup_download_body.dart';
import 'setup_models_body.dart';
import 'setup_notifications_body.dart';
import 'setup_signin_body.dart';
import 'setup_storage_body.dart';
import 'setup_welcome_body.dart';

/// The first run, laid out.
///
/// This is the only file in the flow that touches a provider. Every step body
/// is prop-only — the `SettingsLocalServerBody` discipline — so the host reads
/// the controller once, decides what each step needs, and hands down values
/// and closures. A null callback hides its control; nothing below this line
/// knows what a `ref` is.
///
/// One pane, not eight screens. The step changes inside a [PaneSurface] whose
/// title is the step's and whose trailing slot counts them, so the wizard
/// reads as one place the user is moving through rather than as eight windows
/// that keep replacing each other.
class SetupFlow extends ConsumerStatefulWidget {
  /// Fired once the last step has committed. The gate re-reads the store.
  final VoidCallback onFinished;

  /// The folder panel, injectable so a test can pick a directory without a
  /// platform channel — exactly as the inbox injects it.
  final FileDialogs? fileDialogs;

  const SetupFlow({super.key, required this.onFinished, this.fileDialogs});

  /// The key the primary button of EVERY step carries — see
  /// [setupContinueKey] for why there is only one.
  static const Key continueKey = setupContinueKey;

  @override
  ConsumerState<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends ConsumerState<SetupFlow> {
  @override
  void initState() {
    super.initState();
    // Guarded because the controller survives a rebuild of this widget: the
    // gate re-mounts the flow after a finish that did not take, and a second
    // `init()` would re-enter the current step and re-probe the machine.
    if (!ref.read(setupControllerProvider).loaded) {
      unawaited(ref.read(setupControllerProvider.notifier).init());
    }
  }

  SetupController get _controller => ref.read(setupControllerProvider.notifier);

  Future<void> _chooseFolder() async {
    final dialogs = widget.fileDialogs ?? const SystemFileDialogs();
    final path = await dialogs.chooseDirectory();
    if (path == null || !mounted) return;
    await _controller.setFolder(path);
  }

  Future<void> _openLicense(ModelFile file) async {
    final uri = Uri.tryParse(file.licenseUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Leaves ONLY on a finish that saved. A false answer means the managed
  /// preference or the stored `done` did not land, and the step stays up with
  /// the alert on it rather than handing over an inbox whose setup is not on
  /// disk.
  Future<void> _finish() async {
    final saved = await _controller.finish();
    if (!mounted || !saved) return;
    widget.onFinished();
  }

  /// The other way out of the wizard, and the only one that does not go
  /// through Finish. It reaches the gate exactly as [_finish] does — the
  /// controller has put the stored word back, and the gate re-reads it.
  Future<void> _returnToInbox() async {
    final restored = await _controller.returnToInbox();
    if (!mounted || !restored) return;
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(setupControllerProvider);
    if (!state.loaded) {
      return const Scaffold(
        backgroundColor: BondColors.ground,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final step = state.step;
    return Scaffold(
      backgroundColor: BondColors.ground,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s24),
            child: PaneSurface(
              title: step.title,
              // Nowhere to go back to from the first step, and nowhere worth
              // going while the finish is committing.
              onBack: step == SetupStep.welcome || state.finishing
                  ? null
                  : () => unawaited(_controller.back()),
              trailing: Text(
                'Step ${step.number} of ${SetupStep.count}',
                style: BondType.caption,
              ),
              child: Padding(
                padding: const EdgeInsets.all(BondSpacing.s24),
                child: SingleChildScrollView(child: _body(state)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(SetupState state) {
    final manifest = ref.read(modelManifestProvider);
    void next() => unawaited(_controller.next());
    switch (state.step) {
      case SetupStep.welcome:
        return SetupWelcomeBody(
          migration: state.migration,
          onContinue: next,
          // Null on a first run: a null callback hides its control, and there
          // is no inbox behind THAT wizard to offer.
          onReturnToInbox: state.canReturnToInbox
              ? () => unawaited(_returnToInbox())
              : null,
        );
      case SetupStep.device:
        final prose = manifest.byRole(ModelRole.prose);
        return SetupDeviceBody(
          hardware: state.hardware,
          blocked: _controller.deviceBlocked,
          lowMemory: _controller.lowMemory,
          proseName: prose.displayName,
          proseMinRamBytes: prose.minRamBytes,
          onContinue: next,
        );
      case SetupStep.models:
        return SetupModelsBody(
          manifest: manifest,
          onOpenLicense: (file) => unawaited(_openLicense(file)),
          onContinue: next,
        );
      case SetupStep.storage:
        return SetupStorageBody(
          folder: state.modelsFolder,
          disk: state.disk,
          onChooseFolder: () => unawaited(_chooseFolder()),
          onContinue: next,
        );
      case SetupStep.download:
        return SetupDownloadBody(
          files: manifest.bySize,
          progress: state.downloads,
          running: state.downloadRunning,
          paused: state.downloadPaused,
          complete: state.downloadsComplete,
          onStart: () => unawaited(_controller.startDownload()),
          onPause: () => unawaited(_controller.pauseDownload()),
          onResume: () => unawaited(_controller.resumeDownload()),
          onCancel: () => unawaited(_controller.cancelDownload()),
          onContinue: next,
        );
      case SetupStep.signIn:
        return SetupSignInBody(
          signedIn: state.signedIn,
          // The same call the gate's sign-in screen makes, and it advances
          // rather than re-probing: the session just answered, and asking it
          // again would be a round trip to learn what was settled a
          // microsecond ago.
          onSignedIn: next,
          onContinue: next,
        );
      case SetupStep.notifications:
        return SetupNotificationsBody(
          granted: state.notificationsGranted,
          onContinue: () => unawaited(_controller.continueFromNotifications()),
          onOpenSettings: () =>
              unawaited(_controller.openNotificationSettings()),
        );
      case SetupStep.done:
        return SetupDoneBody(
          folder: state.modelsFolder,
          routerPort: state.routerPort,
          accountName: state.accountName,
          notificationsGranted: state.notificationsGranted,
          finishing: state.finishing,
          finishFailed: state.finishFailed,
          onFinish: () => unawaited(_finish()),
        );
    }
  }
}
