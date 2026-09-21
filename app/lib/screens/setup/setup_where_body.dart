import 'package:flutter/material.dart';

import '../../services/llm/model_probe.dart' show ModelProbeResult;
import '../../services/llm/model_slots.dart' show ModelPlacement;
import '../../theme/tokens.dart';
import '../../widgets/model_slot_editor.dart' show ProbeStatus;
import 'setup_controls.dart';

/// Where the models run: the shared GPU box, or this Mac.
///
/// ONE widget for two places. The wizard's third step renders it with both
/// cards, and the Settings sub-pane behind **Use the shared GPU box** renders
/// it with [showChoices] false, so the address field, the key field and
/// **Check server** carry the same three keys and behave the same way in both.
/// Two copies of a form that takes a secret is exactly the kind of drift that
/// ends with one of them logging it.
///
/// PROP-ONLY, like every other step body: the controller owns the placement,
/// the address and the probe result, and the host hands them down. The one
/// exception is the access key, and it is the point of this widget being
/// stateful. The key lives in a [TextEditingController] here, is handed to
/// [onCheck] and [onContinue] by value, and is in no provider, no
/// [ModelProbeResult] and no stored state anywhere. It reaches the keychain
/// through `adoptBox` and nowhere else.
///
/// No dialogs: the choice is two cards in the flow and the Settings version is
/// a pane with a back link.
class SetupWhereBody extends StatefulWidget {
  /// The choice so far, or null while nothing has been picked. Null renders
  /// both cards unselected and leaves the way forward disabled.
  final ModelPlacement? placement;

  /// The box address, owned by the host so a quit and a resume keep it. Never
  /// the key.
  final String boxUrl;

  /// The last **Check server** answer, or null when none has been asked for.
  final ModelProbeResult? probeResult;

  /// A check is out. The button reads as busy and the result is stale.
  final bool probing;

  /// Whether to draw the two placement cards. False in the Settings pane,
  /// which was opened by a button that already made the choice.
  final bool showChoices;

  /// The primary button's label. 'Continue' in the wizard, 'Use this box' in
  /// Settings.
  final String continueLabel;

  final ValueChanged<ModelPlacement>? onChoose;
  final ValueChanged<String>? onUrlChanged;

  /// **Check server**, with the typed key. Null takes the button off, the
  /// discipline every optional control in this app follows.
  final ValueChanged<String>? onCheck;

  /// The way forward, with the typed key. The host decides what an empty
  /// field means; this widget does not refuse the press, because a button
  /// that goes quiet is a dead end and a host that knows why can say so.
  final ValueChanged<String> onContinue;

  const SetupWhereBody({
    super.key,
    required this.placement,
    required this.boxUrl,
    required this.onContinue,
    this.probeResult,
    this.probing = false,
    this.showChoices = true,
    this.continueLabel = 'Continue',
    this.onChoose,
    this.onUrlChanged,
    this.onCheck,
  });

  /// The two cards and the three controls, by key, so a walk of the wizard and
  /// a walk of the Settings pane read the same.
  static const Key boxCardKey = ValueKey('setup-where-box');
  static const Key localCardKey = ValueKey('setup-where-local');
  static const Key urlKey = ValueKey('setup-box-url');
  static const Key keyFieldKey = ValueKey('setup-box-key');
  static const Key checkKey = ValueKey('setup-box-check');

  /// The box card's title. The word recommended rides a middle dot rather
  /// than a parenthesis: user-facing strings carry neither parentheticals nor
  /// em-dashes.
  static const String boxTitle = 'Shared GPU box · recommended';
  static const String boxBlurb =
      'The inbox and writing steps run on the project’s GPU box, a machine '
      'the project rents in the cloud, so message text and drafts travel '
      'there over an encrypted connection. The embedding model stays on '
      'this Mac.';
  static const String localTitle = 'This Mac';
  static const String localBlurb =
      'Everything runs here and nothing leaves the machine.';

  @override
  State<SetupWhereBody> createState() => _SetupWhereBodyState();
}

class _SetupWhereBodyState extends State<SetupWhereBody> {
  /// The access key, and the only place in the app it ever sits outside the
  /// keychain. Not lifted into [SetupState] deliberately: state is stored, and
  /// a stored key would be a secret in `setup_state`.
  final TextEditingController _key = TextEditingController();

  late final TextEditingController _url =
      TextEditingController(text: widget.boxUrl);

  @override
  void initState() {
    super.initState();
    // Both fields drive the primary button's enabled state, so a rebuild per
    // keystroke is the point rather than a cost.
    _key.addListener(_onTyped);
    _url.addListener(_onTyped);
  }

  @override
  void didUpdateWidget(SetupWhereBody old) {
    super.didUpdateWidget(old);
    // The host is the owner of the address, but it must not fight the cursor:
    // only a value that differs from what is typed is written back, which is
    // a resume or a prefill rather than an echo of this frame's keystroke.
    if (widget.boxUrl != old.boxUrl && widget.boxUrl != _url.text) {
      _url.text = widget.boxUrl;
    }
  }

  @override
  void dispose() {
    _key.removeListener(_onTyped);
    _url.removeListener(_onTyped);
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _onTyped() {
    if (mounted) setState(() {});
  }

  bool get _isBox => widget.placement == ModelPlacement.box;

  /// Both fields filled, on the box choice. This Mac needs neither.
  bool get _canContinue => _isBox
      ? _url.text.trim().isNotEmpty && _key.text.trim().isNotEmpty
      : widget.placement != null;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showChoices) ...[
          _card(
            cardKey: SetupWhereBody.boxCardKey,
            title: SetupWhereBody.boxTitle,
            blurb: SetupWhereBody.boxBlurb,
            selected: _isBox,
            onTap: () => widget.onChoose?.call(ModelPlacement.box),
          ),
          const SizedBox(height: BondSpacing.s12),
          _card(
            cardKey: SetupWhereBody.localCardKey,
            title: SetupWhereBody.localTitle,
            blurb: SetupWhereBody.localBlurb,
            selected: widget.placement == ModelPlacement.local,
            onTap: () => widget.onChoose?.call(ModelPlacement.local),
          ),
        ],
        // The fields belong to the box choice and appear with it. In the
        // Settings pane there is no choice to make and they are always up.
        if (_isBox || !widget.showChoices) ...[
          const SizedBox(height: BondSpacing.s16),
          TextField(
            key: SetupWhereBody.urlKey,
            controller: _url,
            onChanged: (value) => widget.onUrlChanged?.call(value),
            decoration: const InputDecoration(
              labelText: 'Box address',
              hintText: 'https://box.example.com',
            ),
          ),
          const SizedBox(height: BondSpacing.s12),
          TextField(
            key: SetupWhereBody.keyFieldKey,
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Access key'),
          ),
          if (widget.onCheck case final check?) ...[
            const SizedBox(height: BondSpacing.s12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: SetupWhereBody.checkKey,
                onPressed: widget.probing
                    ? null
                    : () => check(_key.text.trim()),
                child: const Text('Check server'),
              ),
            ),
            const SizedBox(height: BondSpacing.s8),
            ProbeStatus(probing: widget.probing, result: widget.probeResult),
          ],
        ],
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(
          label: widget.continueLabel,
          onPressed:
              _canContinue ? () => widget.onContinue(_key.text.trim()) : null,
        ),
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
