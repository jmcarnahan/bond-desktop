import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/app_providers.dart' show ParkedFact;
import '../screens/setup/setup_download_body.dart' show SetupDownloadBody;
import '../services/decision/decision_client.dart' show DecisionServerKind;
import '../services/decision/decision_heads_file.dart' show DecisionHeadsFile;
import '../services/llm/llm_client.dart' as llm show decisionOlderModelText;
import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart'
    show
        ModelPlacement,
        boxDecideId,
        boxProseId,
        generativeNoAddressText,
        handServersBuild,
        hostPort,
        isLoopbackHost,
        routerBulkId,
        routerDecideId,
        routerProseId;
import '../services/models/download_state.dart' show DownloadError;
import '../services/models/managed_model_status.dart' show ManagedModelStatus;
import '../services/models/model_ensurer.dart' show EnsurePhase, EnsureState;
import '../services/models/registry_probe.dart' show RegistryCheck;
import '../services/server/server_state.dart';
import '../theme/tokens.dart';
import 'attachment_format.dart' show formatBytes;
import 'model_registry_form.dart' show ModelRegistryForm, RegistrySave;
import 'model_servers_form.dart' show ModelServersForm, ServerFormRole;
import 'settings_segments.dart';

/// One role write from the Models page: where the role runs and, on Your
/// server, the address, the discovered model and the key as typed.
/// [managedModel] is the generative role's managed choice (`bond-prose` or
/// `bond-bulk`) and is ignored for the decision role. [clearKey] forgets the
/// stored key because the address moved to another host.
typedef RoleWrite = Future<void> Function({
  required ModelPlacement placement,
  String? managedModel,
  String? url,
  String? model,
  String? key,
  bool clearKey,
});

/// The Models section as a tester reads it: three roles, top to bottom.
///
/// **Decision model** (sorts and flags every message) and **Generative
/// model** (writes summaries, drafts and storylines) each answer one
/// question, where it runs: **This Mac** or **Your server**. This Mac is a
/// status block (and, for the generative model, the choice of the 27B or the
/// 4B); Your server is the one-address [ModelServersForm]. **Embeddings**
/// always run on this Mac and are a status line only. **Model registry**
/// under them is where the decision model is downloaded from
/// ([ModelRegistryForm]).
///
/// PROP-ONLY, like every other body here: nothing reaches for a provider, the
/// host resolves every fact and takes every write back as a closure. The
/// state it owns is which segment is being edited before anything is written.
/// The ACCESS KEY is never held here: it lives in the form's own controller.
class SettingsModelsPage extends StatefulWidget {
  final ModelPlacement decisionPlacement;
  final ModelPlacement generativePlacement;

  /// The managed generative model's router id on this Mac (`bond-prose` or
  /// `bond-bulk`), already resolved against the tier.
  final String generativeManagedId;

  /// This Mac is on the inbox tier, where the 27B is not offered.
  final bool inboxTier;

  /// Whether the session's processing switch is on. Off, the server line
  /// says so and no park sentence is shown, because nothing retries.
  final bool processingOn;

  /// Where the app's own llama-server stands.
  final ServerState serverState;

  /// Whether this build runs its own llama-server. False under
  /// `BOND_DEV_HAND_SERVERS`, where `make embed` serves embeddings and
  /// nothing downloads them, so the Embeddings block offers no Download.
  final bool managedServer;

  /// The decision remote's effective address and model, and whether its key
  /// is stored. Never a key.
  final String decisionUrl;
  final String decisionModel;
  final bool decisionKeyStored;

  /// Whether, with nothing in the keychain, the decision remote's key is the
  /// one this build carries (its address on the build's origin). A flag,
  /// never a key.
  final bool decisionKeyFromBuild;

  /// What the decision remote turned out to be, once a Connect or a call has
  /// asked it; null before then, and the page says what it said before
  /// there were two kinds.
  final DecisionServerKind? decisionKind;

  /// The same four for the generative remote.
  final String generativeUrl;
  final String generativeModel;
  final bool generativeKeyStored;
  final bool generativeKeyFromBuild;

  /// This Mac's role models (`decision`, `generative`, `embed`), or null
  /// while they are still being read.
  final List<ManagedModelStatus>? statuses;

  /// Asks a server what it serves. Null takes both forms' Connect off.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for a probe. A LOOKUP, never the
  /// value.
  final String? Function(String targetId)? storedBearer;

  /// The decision role's write. **Null takes the whole page's decision
  /// controls off**, the house "absent wiring, absent control" rule.
  final RoleWrite? onUseDecision;

  /// The generative role's write, for either placement.
  final RoleWrite? onUseGenerative;

  /// **Check** under This Mac's decision model: re-reads the disk, asks the
  /// router to pick up a model that landed while the app runs, and asks the
  /// model ensurer to fetch what is missing. Null takes the button off.
  final Future<void> Function()? onCheckDecision;

  /// Forgets one role's stored key, by target id. Null takes **Remove key**
  /// off both forms.
  final Future<void> Function(String targetId)? onRemoveKey;

  /// Reruns the wizard, which is how the models folder changes and a download
  /// is retried. Null takes the link off.
  final VoidCallback? onSetUpAgain;

  /// Opens the server's log. Null takes **Show log** off the failure line.
  final VoidCallback? onShowLog;

  /// Why the pipeline is parked and how much is waiting.
  final ParkedFact? parked;

  /// The model registry's effective address and whether its token is in the
  /// keychain or comes from the build. Flags, never a token.
  final String registryUrl;
  final bool registryTokenStored;
  final bool registryTokenFromBuild;

  /// The registry's write. **Null takes the Model registry block off.**
  final RegistrySave? onSaveRegistry;

  /// Forgets the stored registry token. Null takes **Remove token** off.
  final Future<void> Function()? onRemoveRegistryToken;

  /// Asks the saved registry for the decision model's file. Null takes
  /// **Check** off the registry block.
  final Future<RegistryCheck> Function()? onCheckRegistry;

  /// What the model ensurer is doing: a download's percentage, or why the
  /// last one failed. Null reads as idle.
  final EnsureState? ensureState;

  /// **Download**: asks the model ensurer to fetch what the placements need
  /// and the disk lacks. Null takes every Download button off.
  final Future<void> Function()? onDownloadModels;

  /// **Download again** on the decision row, in the two states a refused
  /// heads file parks in: the decide entry is fetched as though missing and
  /// the files already here are hashed again. Null takes the button off.
  final Future<void> Function()? onRedownloadDecision;

  const SettingsModelsPage({
    super.key,
    this.decisionPlacement = ModelPlacement.local,
    this.generativePlacement = ModelPlacement.local,
    this.generativeManagedId = routerProseId,
    this.inboxTier = false,
    this.processingOn = true,
    this.serverState = const ServerStopped(),
    this.managedServer = true,
    this.decisionUrl = '',
    this.decisionModel = '',
    this.decisionKeyStored = false,
    this.decisionKeyFromBuild = false,
    this.decisionKind,
    this.generativeUrl = '',
    this.generativeModel = '',
    this.generativeKeyStored = false,
    this.generativeKeyFromBuild = false,
    this.statuses,
    this.probe,
    this.storedBearer,
    this.onUseDecision,
    this.onUseGenerative,
    this.onCheckDecision,
    this.onRemoveKey,
    this.onSetUpAgain,
    this.onShowLog,
    this.parked,
    this.registryUrl = '',
    this.registryTokenStored = false,
    this.registryTokenFromBuild = false,
    this.onSaveRegistry,
    this.onRemoveRegistryToken,
    this.onCheckRegistry,
    this.ensureState,
    this.onDownloadModels,
    this.onRedownloadDecision,
  });

  static const Key decisionModeKey = ValueKey('settings-decision-mode');
  static const Key generativeModeKey = ValueKey('settings-generative-mode');
  static const Key generativeManagedKey =
      ValueKey('settings-generative-managed');
  static const Key decisionStatusKey = ValueKey('settings-decision-status');
  static const Key decisionKindKey = ValueKey('settings-decision-kind');
  static const Key decisionRedownloadKey =
      ValueKey('settings-decision-redownload');
  static const Key embedDownloadKey = ValueKey('settings-embed-download');
  static const Key decisionOlderHintKey =
      ValueKey('settings-decision-older-hint');
  static const Key generativeStatusKey = ValueKey('settings-generative-status');
  static const Key embedStatusKey = ValueKey('settings-embed-status');
  static const Key checkDecisionKey = ValueKey('settings-role-check-decision');
  static const Key decisionDownloadKey = ValueKey('settings-decision-download');
  static const Key generativeDownloadKey =
      ValueKey('settings-generative-download');
  static const Key statusKey = ValueKey('settings-models-status');
  static const Key progressKey = ValueKey('settings-models-progress');
  static const Key showLogKey = ValueKey('settings-show-log');
  static const Key setUpAgainKey = ValueKey('settings-set-up-again');
  static const Key idleGenerativeKey = ValueKey('settings-idle-models');

  static const String decisionTitle = 'Decision model';
  static const String generativeTitle = 'Generative model';
  static const String embedTitle = 'Embeddings';
  static const String serverTitle = 'Model server on this Mac';

  /// The two placements, in the owner's own words.
  static const String thisMacLabel = 'This Mac';
  static const String yourServerLabel = 'Your server';

  static const String decisionCaption =
      'Sorts and flags every message. It reads every message, so it runs on '
      'this Mac or on a server of your own.';
  static const String generativeCaption =
      'Writes summaries, drafts and storylines.';
  static const String embedCaption =
      'Finds related messages. Always runs on this Mac.';

  /// The managed generative choice.
  static const String model27bLabel = 'Qwen3.8 27B';
  static const String model4bLabel = 'Qwen3 4B';
  static const String managedCaption =
      'The 27B writes better. The 4B is smaller and faster.';
  static const String inboxTierCaption =
      'This Mac has too little memory for the 27B.';

  /// The server line while the processing switch is off.
  static const String processingOffText =
      'Processing is off. Turn it on under Processing, or in the sidebar, and '
      'the work starts.';

  /// A role's status while its form is open over an install that has not
  /// connected yet.
  static const String untilConnectText =
      'Running on this Mac until you connect.';

  /// The parks this page can answer for, each under its own role.
  static const String serverParkedText =
      'Your server is not answering. Work is waiting and will retry each '
      'minute.';
  static const String serverUnauthorizedText =
      'Your server refused the access key. Change it here.';
  static const String embedUnavailableText =
      'The embedding model on this Mac is not answering. Work is waiting and '
      'will retry each minute.';
  static const String decisionUnavailableText =
      'The decision model is not answering. Work is waiting and will retry '
      'each minute.';

  /// The decision server answers, but not as the decision model: another
  /// model's tokenizer, normalised vectors, no `/tokenize` — or this Mac's
  /// heads file does not match this build. No retry is promised, because
  /// waiting fixes neither.
  static const String decisionMisconfiguredText =
      'The decision server is not the decision model, or its heads file does '
      'not match this build. Check its address here, or press Download again.';

  /// [decisionMisconfiguredText] for a hand-installed (`source: local`)
  /// decision model, which no button downloads.
  static const String decisionMisconfiguredLocalText =
      'The decision server is not the decision model, or its heads file does '
      'not match this build. Check its address here, or copy the current '
      'model files into the models folder.';

  /// The installed heads file is the older decision model's, which this
  /// build no longer reads: the same plain sentence the rail and the heads
  /// refusal say, with no command in it.
  static const String decisionOlderModelText = llm.decisionOlderModelText;

  /// The quieter line under [decisionOlderModelText]: the **Download again**
  /// button beside it fetches the current model over the old file.
  static const String decisionOlderModelHint =
      'Press Download again to replace it.';

  /// [decisionOlderModelHint] for a hand-installed decision model.
  static const String decisionOlderModelLocalHint =
      '${DecisionHeadsFile.copyFilesText}.';

  /// Under Your server's decision form, what the server is.
  static const String systemOneKindText =
      'Kev 4B on your server (answers there; no files needed on this Mac)';
  static const String encoderKindText =
      "ModernBERT on your server (uses this Mac's heads file)";

  /// The decision server refused the key, whichever way the generative
  /// model is placed.
  static const String decisionUnauthorizedText =
      'The decision server refused the access key. Change it here.';

  /// A managed GENERATIVE model the router cannot serve because it is not on
  /// disk. Said on this Mac's server line, on the page that has the button,
  /// so it names the button rather than the way here.
  static const String notInstalledText =
      'A model this Mac runs is not downloaded. Press Download to get it.';

  /// Your server's status before a key has been pasted, and after one has.
  static const String keyNeededText =
      'Access key needed. Paste it and press Connect.';
  static String connectedText(String model, String url) =>
      'Connected · $model at ${hostPort(url)}';

  /// A hand-installed (`source: local`) decision model that is not in the
  /// models folder: the files are copied there by hand, nothing downloads it.
  static const String decisionNotInstalledText =
      'Not installed. Copy the model files into the models folder.';

  /// A downloaded model (the registry's decision model, a generative model
  /// this Mac runs) that is not on disk and is not downloading, with nothing
  /// failed: the Download button beside it fetches it.
  static const String notDownloadedYetText = 'Not downloaded yet.';

  /// A download the model ensurer is running for this row.
  static String downloadingText(double fraction) =>
      'Downloading ${(fraction * 100).floor()}%';

  /// A download is running whose percentage this row does not know: the
  /// wizard's run, still going, that the model ensurer is waiting for.
  static const String downloadingPlainText = 'Downloading';

  static const String downloadLabel = 'Download';
  static const String redownloadLabel = 'Download again';
  static const String installedLoadedText = 'Installed · loaded';
  static const String installedNotLoadedText = 'Installed · not loaded';

  /// Installed since the park that still says otherwise: the files are on
  /// disk and the router is on its way to serving them.
  static const String installedLoadingText = 'Installed · loading';
  /// The Embeddings row's missing line, the same words as the other two
  /// roles' now that the model ensurer fetches it too.
  static const String notDownloadedText = notDownloadedYetText;

  /// The Embeddings row on a build with no managed server: `make embed`
  /// serves the model, and nothing here downloads it.
  static const String embedHandServedText =
      'Served by your own embedding server.';
  static const String onDiskLoadedText = 'On disk · loaded';
  static const String onDiskNotLoadedText = 'On disk · not loaded';

  /// [installedLoadingText] for a downloaded decision model.
  static const String onDiskLoadingText = 'On disk · loading';
  static const String checkingText = 'Checking…';

  /// The server line, one sentence per state of the app's own server.
  static const String startingText = 'Starting…';
  static String loadingText(int loaded, int total) =>
      'Loading models · $loaded of $total';
  static const String runningText = 'Running';
  static const String notRunningText = 'Not running';
  static String failedText(String reason) => 'Not running: $reason';
  static String portInUseText(int port, String? holder) => holder == null
      ? 'Port $port is in use'
      : 'Port $port is in use by $holder';
  static const String handServersText =
      'Servers are started by hand for this build.';

  static const String checkLabel = 'Check';
  static const String showLogLabel = 'Show log';
  static const String setUpAgainLabel = 'Set up again';

  /// The models this build runs on this Mac, by router id, for the frame
  /// before the statuses are read.
  static const Map<String, String> localModelNames = {
    routerProseId: model27bLabel,
    routerBulkId: model4bLabel,
    routerDecideId: 'Bond decision model',
  };
  static const String embedModelName = 'Qwen3 Embedding 0.6B';

  /// The collapsed Models summary: where each role runs, then the server.
  static String summary({
    required ModelPlacement decisionPlacement,
    required ModelPlacement generativePlacement,
    required String generativeUrl,
    required String serverLine,
  }) {
    final host = hostPort(generativeUrl);
    return [
      decisionPlacement == ModelPlacement.local
          ? 'Decision on this Mac'
          : 'Decision on your server',
      generativePlacement == ModelPlacement.local
          ? 'Generative on this Mac'
          : (host.isEmpty
              ? 'Generative on your server'
              : 'Generative at $host'),
      serverLine,
    ].join(' · ');
  }

  /// The server line, from the state alone.
  static String serverLine(ServerState state) {
    if (handServersBuild || state is ServerDisabled) return handServersText;
    return switch (state) {
      ServerStopped() => notRunningText,
      ServerStarting() => startingText,
      ServerLoading(loaded: final loaded) => loadingText(
          loaded.values.where((v) => v).length,
          loaded.length,
        ),
      ServerReady() => runningText,
      ServerFailed(reason: final reason) => failedText(reason),
      ServerPortInUse(port: final port, holder: final holder) =>
        portInUseText(port, holder),
      ServerDisabled() => handServersText,
    };
  }

  /// Whether the router holds [status]'s model. A file the placements do not
  /// use is not loaded by definition.
  static bool loaded(ManagedModelStatus status, ServerState state) {
    if (!status.onDisk || !status.inUse) return false;
    return switch (state) {
      ServerReady() => true,
      ServerLoading(loaded: final map) => map[status.routerId] == true,
      _ => false,
    };
  }

  @override
  State<SettingsModelsPage> createState() => _SettingsModelsPageState();
}

class _SettingsModelsPageState extends State<SettingsModelsPage> {
  /// Whether a role's form is open on an install that still runs it here.
  /// Choosing Your server opens it and writes nothing; Connect moves the
  /// role, and the placement prop coming back as `box` closes this again.
  bool _decisionEditing = false;
  bool _generativeEditing = false;

  /// A Check is out.
  bool _checking = false;

  @override
  void didUpdateWidget(SettingsModelsPage old) {
    super.didUpdateWidget(old);
    if (widget.decisionPlacement == ModelPlacement.box) {
      _decisionEditing = false;
    }
    if (widget.generativePlacement == ModelPlacement.box) {
      _generativeEditing = false;
    }
  }

  bool get _decisionOnServer =>
      widget.decisionPlacement == ModelPlacement.box || _decisionEditing;
  bool get _generativeOnServer =>
      widget.generativePlacement == ModelPlacement.box || _generativeEditing;

  ManagedModelStatus? _row(String roleId) {
    for (final row in widget.statuses ?? const <ManagedModelStatus>[]) {
      if (row.roleId == roleId) return row;
    }
    return null;
  }

  /// A park sentence for [reasons], when processing is on and work waits.
  String? _parked(Set<String> reasons) {
    final parked = widget.parked;
    if (!widget.processingOn || parked == null || parked.waiting <= 0) {
      return null;
    }
    if (!reasons.contains(parked.reason)) return null;
    return switch (parked.reason) {
      'model_unavailable' => SettingsModelsPage.serverParkedText,
      'unauthorized' => SettingsModelsPage.serverUnauthorizedText,
      'embed_unavailable' => SettingsModelsPage.embedUnavailableText,
      'decision_unavailable' => SettingsModelsPage.decisionUnavailableText,
      'not_installed' => SettingsModelsPage.notInstalledText,
      'no_address' => generativeNoAddressText,
      'decision_not_installed' => _decisionNotHere(_row('decision')),
      'decision_older_model' => SettingsModelsPage.decisionOlderModelText,
      'decision_misconfigured' => _decisionLocal
          ? SettingsModelsPage.decisionMisconfiguredLocalText
          : SettingsModelsPage.decisionMisconfiguredText,
      'decision_unauthorized' => SettingsModelsPage.decisionUnauthorizedText,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(SettingsModelsPage.serverTitle),
        Text(
          key: SettingsModelsPage.statusKey,
          widget.processingOn
              // Only a generative model this Mac runs can be not
              // downloaded, so that park is said on this Mac's server line.
              ? _parked(const {'not_installed'}) ??
                  SettingsModelsPage.serverLine(widget.serverState)
              : SettingsModelsPage.processingOffText,
          style: BondType.small,
        ),
        ..._serverProgress(),
        if (widget.onUseDecision != null) ...[
          const SizedBox(height: BondSpacing.s24),
          ..._decisionBlock(widget.onUseDecision!),
        ],
        if (widget.onUseGenerative != null) ...[
          const SizedBox(height: BondSpacing.s24),
          ..._generativeBlock(widget.onUseGenerative!),
        ],
        const SizedBox(height: BondSpacing.s24),
        ..._embedBlock(),
        if (widget.onSaveRegistry case final save?) ...[
          const SizedBox(height: BondSpacing.s24),
          ModelRegistryForm(
            key: const ValueKey('settings-registry-form'),
            url: widget.registryUrl,
            tokenStored: widget.registryTokenStored,
            tokenFromBuild: widget.registryTokenFromBuild,
            onSave: save,
            onRemoveToken: widget.onRemoveRegistryToken,
            onCheck: widget.onCheckRegistry,
          ),
        ],
        if (widget.onSetUpAgain case final again?) ...[
          const SizedBox(height: BondSpacing.s16),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: SettingsModelsPage.setUpAgainKey,
              onPressed: again,
              child: const Text(SettingsModelsPage.setUpAgainLabel),
            ),
          ),
        ],
      ],
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s8),
        child: Text(
          text,
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
      );

  Widget _placementSegments({
    required Key key,
    required bool onServer,
    required String caption,
    required ValueChanged<ModelPlacement> onChanged,
  }) =>
      SettingsSegments<ModelPlacement>(
        key: key,
        segments: const [
          (value: ModelPlacement.local, label: SettingsModelsPage.thisMacLabel),
          (value: ModelPlacement.box, label: SettingsModelsPage.yourServerLabel),
        ],
        selected: onServer ? ModelPlacement.box : ModelPlacement.local,
        onChanged: onChanged,
        caption: caption,
      );

  /// One line of this Mac's facts about a model: its name and its size.
  Widget? _detail(ManagedModelStatus? row) {
    if (row == null) return null;
    return Text(
      '${row.displayName} · ${formatBytes(row.bytes)}',
      style: BondType.caption,
    );
  }

  // ── Decision ───────────────────────────────────────────────────────────

  List<Widget> _decisionBlock(RoleWrite write) {
    final onServer = _decisionOnServer;
    final row = _row('decision');
    final check = widget.onCheckDecision;
    final status = _decisionStatus(row);
    return [
      _heading(SettingsModelsPage.decisionTitle),
      _placementSegments(
        key: SettingsModelsPage.decisionModeKey,
        onServer: onServer,
        caption: SettingsModelsPage.decisionCaption,
        onChanged: (mode) {
          if (mode == ModelPlacement.box) {
            if (widget.decisionPlacement != ModelPlacement.box) {
              setState(() => _decisionEditing = true);
            }
            return;
          }
          if (widget.decisionPlacement == ModelPlacement.box) {
            unawaited(write(placement: ModelPlacement.local));
            return;
          }
          if (_decisionEditing) setState(() => _decisionEditing = false);
        },
      ),
      const SizedBox(height: BondSpacing.s12),
      if (onServer) ...[
        ModelServersForm(
          key: const ValueKey('settings-decision-form'),
          role: ServerFormRole.decision,
          url: widget.decisionUrl,
          model: widget.decisionModel,
          keyStored: widget.decisionKeyStored,
          keyFromBuild: widget.decisionKeyFromBuild,
          probe: widget.probe,
          storedBearer: widget.storedBearer,
          onConnect: ({required url, required model, key, required clearKey}) =>
              write(
            placement: ModelPlacement.box,
            url: url,
            model: model,
            key: key,
            clearKey: clearKey,
          ),
          onRemoveKey: widget.onRemoveKey == null
              ? null
              : () => widget.onRemoveKey!(boxDecideId),
          thirdPartyRefusal: ModelServersForm.decisionThirdPartyRefusalText,
        ),
        const SizedBox(height: BondSpacing.s12),
        if (!_decisionEditing && widget.decisionKind != null) ...[
          Text(
            key: SettingsModelsPage.decisionKindKey,
            switch (widget.decisionKind!) {
              DecisionServerKind.systemOne =>
                SettingsModelsPage.systemOneKindText,
              DecisionServerKind.encoderHeads =>
                SettingsModelsPage.encoderKindText,
            },
            style: BondType.caption,
          ),
          const SizedBox(height: BondSpacing.s8),
        ],
      ] else
        ?_detail(row),
      Row(
        children: [
          Expanded(
            child: Text(
              key: SettingsModelsPage.decisionStatusKey,
              status,
              style: BondType.small,
            ),
          ),
          if (_decisionDownloadable(row)) ...[
            const SizedBox(width: BondSpacing.s12),
            _downloadButton(SettingsModelsPage.decisionDownloadKey),
          ],
          if (_decisionRedownloadable(row)) ...[
            const SizedBox(width: BondSpacing.s12),
            OutlinedButton(
              key: SettingsModelsPage.decisionRedownloadKey,
              onPressed: () => unawaited(widget.onRedownloadDecision!()),
              child: const Text(SettingsModelsPage.redownloadLabel),
            ),
          ],
          if (!onServer && check != null) ...[
            const SizedBox(width: BondSpacing.s12),
            OutlinedButton(
              key: SettingsModelsPage.checkDecisionKey,
              onPressed: _checking ? null : () => unawaited(_check(check)),
              child: const Text(SettingsModelsPage.checkLabel),
            ),
          ],
        ],
      ),
      if (status == SettingsModelsPage.decisionOlderModelText) ...[
        const SizedBox(height: BondSpacing.s4),
        Text(
          key: SettingsModelsPage.decisionOlderHintKey,
          _decisionLocal
              ? SettingsModelsPage.decisionOlderModelLocalHint
              : SettingsModelsPage.decisionOlderModelHint,
          style: BondType.caption,
        ),
      ],
    ];
  }

  /// A run is in flight, whoever owns it: the model ensurer's own, or the
  /// wizard's that it is waiting for. No Download button while it is.
  bool get _downloading =>
      widget.ensureState?.phase == EnsurePhase.downloading;

  /// The decision model is a hand-installed (`source: local`) entry, which
  /// no button downloads.
  bool get _decisionLocal => _row('decision')?.local ?? false;

  /// A **Download** button, wired to the model ensurer.
  Widget _downloadButton(Key key) => OutlinedButton(
        key: key,
        onPressed: () => unawaited(widget.onDownloadModels!()),
        child: const Text(SettingsModelsPage.downloadLabel),
      );

  /// The failures whose fix is the registry's address or token: the
  /// sentence names it, and the registry block's Save retries the download,
  /// so a Download button would only repeat the same refusal.
  static const Set<String> _registryFixes = {
    DownloadError.registryNotConfigured,
    DownloadError.unauthorized,
    DownloadError.registryNotFound,
    DownloadError.registryNotAModel,
  };

  /// Whether a missing downloaded model's row offers **Download**: not
  /// while any run is in flight, and not after a failure whose fix is in
  /// the registry block.
  bool _offersDownload(String routerId) {
    if (widget.onDownloadModels == null || _downloading) return false;
    final ensure = widget.ensureState;
    if (ensure != null && ensure.failedIds.contains(routerId)) {
      return !_registryFixes.contains(ensure.errorFor(routerId));
    }
    return true;
  }

  /// Whether the decision row offers **Download**: a downloaded (not hand
  /// installed) decision model whose files this Mac needs and lacks. This
  /// Mac needs the whole entry; Your server needs only the heads file, and
  /// only for a ModernBERT server.
  bool _decisionDownloadable(ManagedModelStatus? row) {
    if (row == null || row.local || _decisionEditing) return false;
    final needed = widget.decisionPlacement == ModelPlacement.box
        ? widget.decisionKind == DecisionServerKind.encoderHeads &&
            !row.headsOnDisk
        : !row.onDisk;
    return needed && _offersDownload(row.routerId);
  }

  /// Whether the decision row offers **Download again**: the heads file is
  /// here and was REFUSED (the older model's, or one that does not match
  /// this build), on a downloaded entry whose heads this Mac reads.
  bool _decisionRedownloadable(ManagedModelStatus? row) {
    if (widget.onRedownloadDecision == null || _downloading) return false;
    if (row == null || row.local || _decisionEditing) return false;
    final reason = widget.parked?.reason;
    if (_parked(const {'decision_older_model', 'decision_misconfigured'}) ==
            null ||
        (reason != 'decision_older_model' &&
            reason != 'decision_misconfigured')) {
      return false;
    }
    if (widget.decisionPlacement == ModelPlacement.box) {
      return widget.decisionKind == DecisionServerKind.encoderHeads &&
          row.headsOnDisk;
    }
    return row.onDisk;
  }

  /// What a downloaded model that is not on disk says, by what the model
  /// ensurer is doing for it: ITS percentage while it downloads, plain
  /// `Downloading` while another owner's run is going, why it failed, or
  /// that it has not landed yet.
  String _downloadStatus(String routerId) {
    final ensure = widget.ensureState;
    if (ensure != null && ensure.phase == EnsurePhase.downloading) {
      final own = ensure.fractionFor(routerId);
      if (own != null) return SettingsModelsPage.downloadingText(own);
      if (ensure.waiting) return SettingsModelsPage.downloadingPlainText;
    }
    if (ensure != null && ensure.failedIds.contains(routerId)) {
      return SetupDownloadBody.describeDownloadError(ensure.errorFor(routerId));
    }
    return SettingsModelsPage.notDownloadedYetText;
  }

  /// The decision model is missing on this Mac: a hand-installed one says
  /// how it gets here, a downloaded one says where its download stands.
  String _decisionNotHere(ManagedModelStatus? row) =>
      row == null || row.local
          ? SettingsModelsPage.decisionNotInstalledText
          : _downloadStatus(row.routerId);

  String _decisionStatus(ManagedModelStatus? row) {
    final onServer = widget.decisionPlacement == ModelPlacement.box;
    // A not-installed park outlives the download that fixed it: it clears
    // only when triage next drains, and on this Mac that waits for the router
    // to restart onto a preset with the decision model in it, behind whatever
    // else that preset loads. Once the files are on disk the row is the
    // fresher fact, so the line stops saying the model is missing the moment
    // it lands. A Kev server reads no file on this Mac, so for it the park
    // is stale the moment the role is on it.
    final kev = onServer && widget.decisionKind == DecisionServerKind.systemOne;
    final stale =
        kev || (row != null && row.headsOnDisk && (onServer || row.onDisk));
    if (_parked(const {
      'decision_unavailable',
      'decision_not_installed',
      'decision_older_model',
      'decision_misconfigured',
      'decision_unauthorized',
    })
        case final parked?) {
      if (widget.parked?.reason != 'decision_not_installed' || !stale) {
        return parked;
      }
      // Off the server `stale` already implies a row; this says so to the
      // type system.
      if (!onServer && !_decisionEditing && row != null) {
        final loaded = SettingsModelsPage.loaded(row, widget.serverState);
        if (row.local) {
          return loaded
              ? SettingsModelsPage.installedLoadedText
              : SettingsModelsPage.installedLoadingText;
        }
        return loaded
            ? SettingsModelsPage.onDiskLoadedText
            : SettingsModelsPage.onDiskLoadingText;
      }
    }
    if (_decisionEditing) return SettingsModelsPage.untilConnectText;
    if (onServer) {
      // An encoder-heads server's heads run here (D12): without the heads
      // file it still cannot decide anything. A Kev server answers there and
      // needs none, and a server whose kind is not known yet is not told to
      // fetch a file it may not need: the host is asking it.
      if (widget.decisionKind == DecisionServerKind.encoderHeads &&
          row != null &&
          !row.headsOnDisk) {
        return _decisionNotHere(row);
      }
      return _remoteStatus(
        widget.decisionUrl,
        widget.decisionModel,
        widget.decisionKeyStored || widget.decisionKeyFromBuild,
      );
    }
    if (_checking) return SettingsModelsPage.checkingText;
    if (row == null) {
      return '${SettingsModelsPage.localModelNames[routerDecideId]} on this Mac';
    }
    if (!row.onDisk) return _decisionNotHere(row);
    final loaded = SettingsModelsPage.loaded(row, widget.serverState);
    if (row.local) {
      return loaded
          ? SettingsModelsPage.installedLoadedText
          : SettingsModelsPage.installedNotLoadedText;
    }
    return loaded
        ? SettingsModelsPage.onDiskLoadedText
        : SettingsModelsPage.onDiskNotLoadedText;
  }

  /// Your server's line: a key is needed unless one is at hand (the
  /// keychain's, or this build's on its own origin) or the server is on this
  /// machine, which needs none.
  String _remoteStatus(String url, String model, bool hasKey) {
    if (!hasKey && !isLoopbackHost(url)) {
      return SettingsModelsPage.keyNeededText;
    }
    return SettingsModelsPage.connectedText(model, url);
  }

  Future<void> _check(Future<void> Function() check) async {
    setState(() => _checking = true);
    try {
      await check();
    } on Object {
      // The status line re-reads the disk either way; a Check that could not
      // finish has nothing more useful to say than the line below it.
    }
    if (!mounted) return;
    setState(() => _checking = false);
  }

  // ── Generative ─────────────────────────────────────────────────────────

  List<Widget> _generativeBlock(RoleWrite write) {
    final onServer = _generativeOnServer;
    final row = _row('generative');
    // The row answers for the CHOSEN model only; in the frame after a switch
    // it may still describe the other one.
    final chosen = row != null && row.routerId == widget.generativeManagedId
        ? row
        : null;
    return [
      _heading(SettingsModelsPage.generativeTitle),
      _placementSegments(
        key: SettingsModelsPage.generativeModeKey,
        onServer: onServer,
        caption: SettingsModelsPage.generativeCaption,
        onChanged: (mode) {
          if (mode == ModelPlacement.box) {
            if (widget.generativePlacement != ModelPlacement.box) {
              setState(() => _generativeEditing = true);
            }
            return;
          }
          if (widget.generativePlacement == ModelPlacement.box) {
            unawaited(write(placement: ModelPlacement.local));
            return;
          }
          if (_generativeEditing) setState(() => _generativeEditing = false);
        },
      ),
      const SizedBox(height: BondSpacing.s12),
      if (onServer) ...[
        ModelServersForm(
          key: const ValueKey('settings-generative-form'),
          role: ServerFormRole.generative,
          url: widget.generativeUrl,
          model: widget.generativeModel,
          keyStored: widget.generativeKeyStored,
          keyFromBuild: widget.generativeKeyFromBuild,
          probe: widget.probe,
          storedBearer: widget.storedBearer,
          onConnect: ({required url, required model, key, required clearKey}) =>
              write(
            placement: ModelPlacement.box,
            url: url,
            model: model,
            key: key,
            clearKey: clearKey,
          ),
          onRemoveKey: widget.onRemoveKey == null
              ? null
              : () => widget.onRemoveKey!(boxProseId),
          thirdPartyRefusal: ModelServersForm.generativeThirdPartyRefusalText,
        ),
        const SizedBox(height: BondSpacing.s12),
      ] else ...[
        SettingsSegments<String>(
          key: SettingsModelsPage.generativeManagedKey,
          segments: const [
            (value: routerProseId, label: SettingsModelsPage.model27bLabel),
            (value: routerBulkId, label: SettingsModelsPage.model4bLabel),
          ],
          selected: widget.generativeManagedId,
          disabled: widget.inboxTier ? const {routerProseId} : const {},
          onChanged: (id) {
            if (id == widget.generativeManagedId) return;
            unawaited(write(placement: ModelPlacement.local, managedModel: id));
          },
          caption: widget.inboxTier
              ? SettingsModelsPage.inboxTierCaption
              : SettingsModelsPage.managedCaption,
        ),
        const SizedBox(height: BondSpacing.s8),
        ?_detail(chosen),
      ],
      Row(
        children: [
          Expanded(
            child: Text(
              key: SettingsModelsPage.generativeStatusKey,
              _generativeStatus(chosen),
              style: BondType.small,
            ),
          ),
          // A generative model this Mac runs that is not on disk: the model
          // ensurer fetches it as it fetches the decision model.
          if (!onServer &&
              chosen != null &&
              !chosen.onDisk &&
              _offersDownload(chosen.routerId)) ...[
            const SizedBox(width: BondSpacing.s12),
            _downloadButton(SettingsModelsPage.generativeDownloadKey),
          ],
        ],
      ),
      // The weights a switch to Your server left behind: on the disk, and
      // nothing holding them in memory.
      if (widget.generativePlacement == ModelPlacement.box &&
          row != null &&
          row.onDisk) ...[
        const SizedBox(height: BondSpacing.s4),
        Text(
          key: SettingsModelsPage.idleGenerativeKey,
          '${row.displayName} · ${formatBytes(row.bytes)} · on disk · not '
          'loaded',
          style: BondType.caption,
        ),
      ],
    ];
  }

  String _generativeStatus(ManagedModelStatus? row) {
    final box = widget.generativePlacement == ModelPlacement.box;
    // Under This Mac the server line above is already saying what the
    // router is doing, so only Your server speaks for these two parks.
    if (box) {
      if (_parked(const {'model_unavailable', 'unauthorized', 'no_address'})
          case final parked?) {
        return parked;
      }
      // Your server with no address anywhere: the role is unavailable and
      // says what fixes it, whether or not anything is waiting yet.
      if (widget.generativeUrl.isEmpty && !_generativeEditing) {
        return generativeNoAddressText;
      }
      return _remoteStatus(
        widget.generativeUrl,
        widget.generativeModel,
        widget.generativeKeyStored || widget.generativeKeyFromBuild,
      );
    }
    if (_generativeEditing) return SettingsModelsPage.untilConnectText;
    if (row == null) {
      final name =
          SettingsModelsPage.localModelNames[widget.generativeManagedId] ??
              widget.generativeManagedId;
      return '$name on this Mac';
    }
    if (!row.onDisk) return _downloadStatus(row.routerId);
    return SettingsModelsPage.loaded(row, widget.serverState)
        ? SettingsModelsPage.onDiskLoadedText
        : SettingsModelsPage.onDiskNotLoadedText;
  }

  // ── Embeddings ─────────────────────────────────────────────────────────

  List<Widget> _embedBlock() {
    final row = _row('embed');
    final parked = _parked(const {'embed_unavailable'});
    final String status;
    if (parked != null) {
      status = parked;
    } else if (!widget.managedServer) {
      status = SettingsModelsPage.embedHandServedText;
    } else if (row == null) {
      status = '${SettingsModelsPage.embedModelName} on this Mac';
    } else if (!row.onDisk) {
      status = _downloadStatus(row.routerId);
    } else {
      status = SettingsModelsPage.loaded(row, widget.serverState)
          ? SettingsModelsPage.onDiskLoadedText
          : SettingsModelsPage.onDiskNotLoadedText;
    }
    return [
      _heading(SettingsModelsPage.embedTitle),
      Text(SettingsModelsPage.embedCaption, style: BondType.caption),
      const SizedBox(height: BondSpacing.s4),
      ?_detail(row),
      Row(
        children: [
          Expanded(
            child: Text(
              key: SettingsModelsPage.embedStatusKey,
              status,
              style: BondType.small,
            ),
          ),
          if (parked == null &&
              widget.managedServer &&
              row != null &&
              !row.onDisk &&
              _offersDownload(row.routerId)) ...[
            const SizedBox(width: BondSpacing.s12),
            _downloadButton(SettingsModelsPage.embedDownloadKey),
          ],
        ],
      ),
    ];
  }

  /// The bar under the server line, and the way to the log.
  List<Widget> _serverProgress() {
    final state = widget.serverState;
    final onShowLog = widget.onShowLog;
    return [
      if (state is ServerStarting)
        const Padding(
          padding: EdgeInsets.only(top: BondSpacing.s8),
          child: LinearProgressIndicator(key: SettingsModelsPage.progressKey),
        )
      else if (state is ServerLoading)
        Padding(
          padding: const EdgeInsets.only(top: BondSpacing.s8),
          child: LinearProgressIndicator(
            key: SettingsModelsPage.progressKey,
            value: state.loaded.isEmpty
                ? null
                : state.loaded.values.where((v) => v).length /
                    state.loaded.length,
          ),
        ),
      if (state is ServerFailed && onShowLog != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: SettingsModelsPage.showLogKey,
            onPressed: onShowLog,
            child: const Text(SettingsModelsPage.showLogLabel),
          ),
        ),
    ];
  }
}
