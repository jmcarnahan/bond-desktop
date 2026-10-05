import 'package:flutter/material.dart';

import '../../providers/setup_provider.dart' show SetupController;
import '../../services/llm/model_probe.dart' show ModelProbeResult;
import '../../services/llm/model_slots.dart'
    show ModelPlacement, hostPort, routerBulkId, routerProseId;
import '../../theme/tokens.dart';
import '../../widgets/model_servers_form.dart';
import '../../widgets/settings_segments.dart';
import 'setup_controls.dart';

/// Where the models run, one role at a time.
///
/// Two questions, the same two the Settings Models page asks: where the
/// **Decision model** runs and where the **Generative model** runs, each
/// answered by two cards, **This Mac** or **Your server**. Embeddings always
/// run on this Mac and are not a question.
///
/// Your server renders the ONE form the Settings page renders, for that
/// role. There is no consent pane behind a wizard, so
/// [ModelServersForm.onThirdParty] is null here and a vendor's address is
/// refused with the form's own sentence: cloud services stay a Settings
/// decision, taken once, after the install works at all.
///
/// The way forward is at the foot: the generative form's own **Continue**
/// under Your server (it refuses, asks the server what it serves, writes, and
/// the host advances from inside that same press), or the step's Continue
/// under This Mac. The decision form sits above it and says **Connect**: it
/// writes its role at once and stays on the step, so the one press at the
/// foot is always the one that moves on.
///
/// PROP-ONLY, the settings bodies' discipline. The ACCESS KEY is in no prop:
/// it lives in each form's own controller and is handed to the write by
/// value, never into `SetupState`.
///
/// No dialogs: the choices are cards in the flow and the forms are blocks
/// under them rather than anything that floats.
class SetupWhereBody extends StatelessWidget {
  /// The generative choice so far, or null while nothing has been picked.
  /// Null leaves the way forward disabled.
  final ModelPlacement? placement;

  /// The decision choice.
  final ModelPlacement decisionPlacement;

  /// The managed generative model this Mac would take, resolved against the
  /// tier: `bond-prose` or `bond-bulk`.
  final String generativeManagedId;

  /// This Mac is on the inbox tier, where the 27B is not offered.
  final bool inboxTier;

  /// The EFFECTIVE values each form opens on. Never a key.
  final String generativeUrl;
  final String generativeModel;
  final bool generativeKeyStored;
  final String decisionUrl;
  final String decisionModel;
  final bool decisionKeyStored;

  /// Whether, with nothing in the keychain, each form's key is the one this
  /// build carries ([ModelServersForm.keyFromBuild]). Flags, never keys.
  final bool generativeKeyFromBuild;
  final bool decisionKeyFromBuild;

  /// Whether the decision model already runs on the owner's server, which is
  /// what its form's Connect writes. The step's way forward waits for it
  /// while Your server is chosen for that role.
  final bool decisionConnected;

  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for a probe made with the key field
  /// blank. A LOOKUP by id, never the value.
  final String? Function(String targetId)? storedBearer;

  final ValueChanged<ModelPlacement> onChoose;
  final ValueChanged<ModelPlacement> onChooseDecision;
  final ValueChanged<String> onChooseManaged;

  /// The step's own Continue, under This Mac for the generative model.
  final VoidCallback onContinueManaged;

  /// The generative form's press: the write AND the way forward. Returned
  /// rather than forgotten, so a refused write comes back to the form.
  final ServerConnect onConnect;

  /// The decision form's press: writes the role and stays on the step.
  final ServerConnect onConnectDecision;

  const SetupWhereBody({
    super.key,
    required this.placement,
    this.decisionPlacement = ModelPlacement.local,
    this.generativeManagedId = routerProseId,
    this.inboxTier = false,
    this.generativeUrl = '',
    this.generativeModel = '',
    this.generativeKeyStored = false,
    this.decisionUrl = '',
    this.decisionModel = '',
    this.decisionKeyStored = false,
    this.generativeKeyFromBuild = false,
    this.decisionKeyFromBuild = false,
    this.decisionConnected = false,
    this.probe,
    this.storedBearer,
    required this.onChoose,
    required this.onChooseDecision,
    required this.onChooseManaged,
    required this.onContinueManaged,
    required this.onConnect,
    required this.onConnectDecision,
  });

  /// The generative cards, by the keys the walk of the wizard has always
  /// read, and the decision cards beside them.
  static const Key managedCardKey = ValueKey('setup-where-managed');
  static const Key customCardKey = ValueKey('setup-where-custom');
  static const Key decisionManagedCardKey =
      ValueKey('setup-where-decision-managed');
  static const Key decisionCustomCardKey =
      ValueKey('setup-where-decision-custom');
  static const Key generativeModelKey =
      ValueKey('setup-where-generative-model');
  static const Key decisionConnectedKey =
      ValueKey('setup-where-decision-connected');

  static const String decisionTitle = 'Decision model';
  static const String decisionCaption = 'Sorts and flags every message.';
  static const String generativeTitle = 'Generative model';
  static const String generativeCaption =
      'Writes summaries, drafts and storylines.';

  /// The word recommended rides a middle dot rather than a parenthesis:
  /// user-facing strings carry neither parentheticals nor em-dashes.
  ///
  /// [managedTitle] and [customTitle] are the DECISION cards' words: that
  /// model reads every message and a local forward pass beats any hop. The
  /// generative cards recommend the other way round since the default-setup
  /// round (decision D9): [generativeManagedTitle] and
  /// [generativeCustomTitle].
  static const String managedTitle = 'This Mac · recommended';
  static const String generativeManagedTitle = 'This Mac';
  static const String generativeCustomTitle = 'Your server · recommended';
  static const String managedBlurb =
      'Bond downloads the model and runs it on this Mac. Nothing leaves the '
      'machine.';
  static const String customTitle = 'Your server';
  static const String customBlurb =
      'A server of your own, on this Mac or on a machine you name. Message '
      'text and drafts travel to it.';
  static const String decisionManagedBlurb =
      'Runs on this Mac in a few milliseconds a message. It is installed '
      'with make decide-install.';
  static const String decisionCustomBlurb =
      'A server of your own that serves the decision model. Every message '
      'travels to it.';
  static const String embedNote =
      'The embedding model always runs on this Mac.';

  static const String model27bLabel = 'Qwen3.8 27B';
  static const String model4bLabel = 'Qwen3 4B';
  static const String managedCaption =
      'The 27B writes better. The 4B is smaller and faster.';
  static const String inboxTierCaption =
      'This Mac has too little memory for the 27B.';

  @override
  Widget build(BuildContext context) {
    final generativeOnServer = placement == ModelPlacement.box;
    final decisionOnServer = decisionPlacement == ModelPlacement.box;
    final decisionWaiting = decisionOnServer && !decisionConnected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _heading(decisionTitle, decisionCaption),
        _card(
          cardKey: decisionManagedCardKey,
          title: managedTitle,
          blurb: decisionManagedBlurb,
          selected: !decisionOnServer,
          onTap: () => onChooseDecision(ModelPlacement.local),
        ),
        const SizedBox(height: BondSpacing.s12),
        _card(
          cardKey: decisionCustomCardKey,
          title: customTitle,
          blurb: decisionCustomBlurb,
          selected: decisionOnServer,
          onTap: () => onChooseDecision(ModelPlacement.box),
        ),
        if (decisionOnServer) ...[
          const SizedBox(height: BondSpacing.s16),
          ModelServersForm(
            role: ServerFormRole.decision,
            url: decisionUrl,
            model: decisionModel,
            keyStored: decisionKeyStored,
            keyFromBuild: decisionKeyFromBuild,
            probe: probe,
            storedBearer: storedBearer,
            onConnect: onConnectDecision,
            // No consent pane behind a wizard, and no vendor ever serves the
            // decision model, so the sentence is that role's own.
            thirdPartyRefusal: ModelServersForm.decisionThirdPartyRefusalText,
          ),
          if (decisionConnected) ...[
            const SizedBox(height: BondSpacing.s8),
            Text(
              key: decisionConnectedKey,
              'Connected · $decisionModel at ${hostPort(decisionUrl)}',
              style: BondType.small,
            ),
          ],
        ],
        const SizedBox(height: BondSpacing.s24),
        _heading(generativeTitle, generativeCaption),
        _card(
          cardKey: managedCardKey,
          title: generativeManagedTitle,
          blurb: managedBlurb,
          selected: placement == ModelPlacement.local,
          onTap: () => onChoose(ModelPlacement.local),
        ),
        const SizedBox(height: BondSpacing.s12),
        _card(
          cardKey: customCardKey,
          title: generativeCustomTitle,
          blurb: customBlurb,
          selected: generativeOnServer,
          onTap: () => onChoose(ModelPlacement.box),
        ),
        const SizedBox(height: BondSpacing.s8),
        Text(embedNote, style: BondType.caption),
        if (generativeOnServer) ...[
          const SizedBox(height: BondSpacing.s16),
          ModelServersForm(
            role: ServerFormRole.generative,
            url: generativeUrl,
            model: generativeModel,
            keyStored: generativeKeyStored,
            keyFromBuild: generativeKeyFromBuild,
            probe: probe,
            storedBearer: storedBearer,
            onConnect: onConnect,
            // No **Remove key** in a wizard, and no consent pane behind one:
            // a vendor's address is refused here in the form's own words.
            onRemoveKey: null,
            onThirdParty: null,
            connectLabel: 'Continue',
          ),
        ] else ...[
          if (placement == ModelPlacement.local) ...[
            const SizedBox(height: BondSpacing.s16),
            SettingsSegments<String>(
              key: generativeModelKey,
              segments: const [
                (value: routerProseId, label: model27bLabel),
                (value: routerBulkId, label: model4bLabel),
              ],
              selected: generativeManagedId,
              disabled: inboxTier ? const {routerProseId} : const {},
              onChanged: onChooseManaged,
              caption: inboxTier ? inboxTierCaption : managedCaption,
            ),
          ],
          if (decisionWaiting) ...[
            const SizedBox(height: BondSpacing.s16),
            Text(
              SetupController.decisionFirstText,
              style: BondType.caption,
            ),
          ],
          const SizedBox(height: BondSpacing.s24),
          SetupPrimaryButton(
            label: 'Continue',
            onPressed: placement == ModelPlacement.local && !decisionWaiting
                ? onContinueManaged
                : null,
          ),
        ],
      ],
    );
  }

  Widget _heading(String title, String caption) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(caption, style: BondType.caption),
          ],
        ),
      );

  Widget _card({
    required Key cardKey,
    required String title,
    required String blurb,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: cardKey,
      onTap: onTap,
      borderRadius: BondRadii.mdAll,
      child: Container(
        padding: const EdgeInsets.all(BondSpacing.s16),
        decoration: BoxDecoration(
          color: selected ? BondColors.primaryTint : BondColors.surface,
          borderRadius: BondRadii.mdAll,
          border: Border.all(
            color: selected ? BondColors.primary : BondColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: BondSpacing.s4),
            Text(blurb, style: BondType.caption),
          ],
        ),
      ),
    );
  }
}
