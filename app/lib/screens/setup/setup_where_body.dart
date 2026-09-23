import 'package:flutter/material.dart';

import '../../services/llm/model_probe.dart' show ModelProbeResult;
import '../../services/llm/model_slots.dart' show ModelPlacement;
import '../../theme/tokens.dart';
import '../../widgets/model_servers_form.dart';
import 'setup_controls.dart';

/// Where the models run: Bond's own, or the user's.
///
/// Two cards and nothing else. Managed means Bond downloads the models and
/// runs them on this Mac; User defined means the person names their own
/// servers, and under that card this step renders the ONE user-defined form
/// the Settings page renders, with **Continue** as its word.
///
/// There is no consent pane behind a wizard, so [ModelServersForm.onThirdParty]
/// is null here and a vendor's address is refused with the form's own
/// sentence: cloud services stay a Settings decision, taken once, after the
/// install works at all.
///
/// There is also NO second Continue under User defined. The form's press is
/// the way forward: it refuses per field, asks both servers what they serve,
/// takes the names they list and writes, and the host advances the step from
/// inside that same press. Two buttons both reading Continue, one of which
/// wrote nothing, is the confusion this round exists to remove.
///
/// PROP-ONLY, the settings bodies' discipline: the host resolves the four
/// prefilled values and takes the write back as a closure. The ACCESS KEY is
/// not among them and never will be — it lives in the form's own controllers,
/// is handed to [onConnect] by value and is in no `SetupState`, because state
/// is what gets stored and a stored key would be a secret in `setup_state`.
///
/// No dialogs: the choice is two cards in the flow and the form is a block
/// under them rather than anything that floats.
class SetupWhereBody extends StatelessWidget {
  /// The choice so far, or null while nothing has been picked. Null renders
  /// both cards unselected and leaves the way forward disabled.
  final ModelPlacement? placement;

  /// The four EFFECTIVE values, to prefill the form: the stored ones where
  /// there are stored ones, the build's otherwise. Never a key.
  final String bigUrl;
  final String smallUrl;
  final String bigModel;
  final String smallModel;

  /// Whether a key is in the keychain for one server or for the other, so
  /// the field it belongs to can say that typing replaces it. Presence flags,
  /// never the token. The form's third flag, the one that offers **Remove
  /// key**, is not taken here: a wizard has no Remove key.
  final bool bigKeyStored;
  final bool smallKeyStored;

  /// Asks a server what it serves, handed down to the form for Connect's
  /// discovery. Null takes the form's button off.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for a probe made with the key field
  /// blank. A LOOKUP by id, never the value.
  final String? Function(String targetId)? storedBearer;

  final ValueChanged<ModelPlacement> onChoose;

  /// The step's own Continue, under Managed. The other card has none.
  final VoidCallback onContinueManaged;

  /// The form's press, under User defined: the write AND the way forward.
  /// Returned rather than forgotten, so a refused write comes back to the
  /// form, which is the thing that can draw it.
  final Future<void> Function({
    required String bigUrl,
    required String smallUrl,
    required String bigModel,
    required String smallModel,
    String? bigKey,
    String? smallKey,
  }) onConnect;

  const SetupWhereBody({
    super.key,
    required this.placement,
    required this.bigUrl,
    required this.smallUrl,
    required this.bigModel,
    required this.smallModel,
    this.bigKeyStored = false,
    this.smallKeyStored = false,
    this.probe,
    this.storedBearer,
    required this.onChoose,
    required this.onContinueManaged,
    required this.onConnect,
  });

  /// The two cards, by key, so a walk of the wizard reads the same as the
  /// page it grew out of.
  static const Key managedCardKey = ValueKey('setup-where-managed');
  static const Key customCardKey = ValueKey('setup-where-custom');

  /// The word recommended rides a middle dot rather than a parenthesis:
  /// user-facing strings carry neither parentheticals nor em-dashes.
  static const String managedTitle = 'Managed · recommended';
  static const String managedBlurb =
      'Bond downloads the models and runs them on this Mac. Nothing leaves '
      'the machine.';
  static const String customTitle = 'User defined';
  static const String customBlurb =
      'Your own servers, on this Mac or on a machine you name. Message text '
      'and drafts travel to them. The embedding model always runs on this '
      'Mac.';

  @override
  Widget build(BuildContext context) {
    final custom = placement == ModelPlacement.box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _card(
          cardKey: managedCardKey,
          title: managedTitle,
          blurb: managedBlurb,
          selected: placement == ModelPlacement.local,
          onTap: () => onChoose(ModelPlacement.local),
        ),
        const SizedBox(height: BondSpacing.s12),
        _card(
          cardKey: customCardKey,
          title: customTitle,
          blurb: customBlurb,
          selected: custom,
          onTap: () => onChoose(ModelPlacement.box),
        ),
        if (custom) ...[
          const SizedBox(height: BondSpacing.s16),
          ModelServersForm(
            bigUrl: bigUrl,
            smallUrl: smallUrl,
            bigModel: bigModel,
            smallModel: smallModel,
            bigKeyStored: bigKeyStored,
            smallKeyStored: smallKeyStored,
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
          const SizedBox(height: BondSpacing.s24),
          SetupPrimaryButton(
            label: 'Continue',
            onPressed:
                placement == ModelPlacement.local ? onContinueManaged : null,
          ),
        ],
      ],
    );
  }

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
