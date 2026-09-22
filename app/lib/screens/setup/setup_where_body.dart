import 'package:flutter/material.dart';

import '../../services/llm/model_probe.dart' show ModelProbeResult;
import '../../services/llm/model_slots.dart'
    show ModelPlacement, isBoxOrigin, normalizeBoxBaseUrl;
import '../../theme/tokens.dart';
import '../../widgets/inline_alert.dart';
import '../../widgets/model_slot_editor.dart' show ProbeStatus;
import 'setup_controls.dart';

/// Where the models run: the GPU server, or this Mac.
///
/// ONE widget for two places. The wizard's third step renders it with both
/// cards, and the simple Models page renders it inline with [showChoices]
/// false under its GPU server segment, so the address field, the key field and
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
/// through `AppPrefsNotifier.useBox` and nowhere else.
///
/// It also owns the ONE address rule, so the wizard and Settings refuse the
/// same address in the same words. See [addressRefusalText].
///
/// No dialogs: the choice is two cards in the flow, and in Settings the form
/// is a block on the page rather than anything that floats.
class SetupWhereBody extends StatefulWidget {
  /// The choice so far, or null while nothing has been picked. Null renders
  /// both cards unselected and leaves the way forward disabled.
  final ModelPlacement? placement;

  /// The box address, owned by the host so a quit and a resume keep it. Never
  /// the key.
  final String boxUrl;

  /// The last **Check server** answer, or null when none has been asked for.
  /// The WRITING slot's, once a host asks for two.
  final ModelProbeResult? probeResult;

  /// The inbox slot's answer, for a host that checks both of the box's
  /// servers. The second of the two lines [twoSlots] draws.
  final ModelProbeResult? bulkProbeResult;

  /// Whether this host checks BOTH of the box's servers.
  ///
  /// True draws the two captioned [ProbeStatus] lines from the first frame, so
  /// the captions are on screen while a check is in flight rather than
  /// appearing under the reader once the second answer lands. False draws the
  /// single uncaptioned line, for a host that asks about one server.
  final bool twoSlots;

  /// Whether a key for this address is already in the keychain.
  ///
  /// True opens the key field EMPTY with the hint `Stored. Type to replace`
  /// and lets the way forward through with it blank, on the target editor's
  /// precedent: a token that has reached the keychain is never read back onto
  /// a screen, so "unchanged" has to be a state the empty field can be in.
  final bool keyStored;

  /// A check is out. The button reads as busy and the result is stale.
  final bool probing;

  /// Whether to draw the two placement cards. False in Settings, where the
  /// segments above the form have already asked the question.
  final bool showChoices;

  /// The primary button's label. 'Continue' in the wizard, 'Save' in
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
    this.bulkProbeResult,
    this.twoSlots = false,
    this.keyStored = false,
    this.probing = false,
    this.showChoices = true,
    this.continueLabel = 'Continue',
    this.onChoose,
    this.onUrlChanged,
    this.onCheck,
  });

  /// The two cards and the three controls, by key, so a walk of the wizard and
  /// a walk of the Settings page read the same.
  static const Key boxCardKey = ValueKey('setup-where-box');
  static const Key localCardKey = ValueKey('setup-where-local');
  static const Key urlKey = ValueKey('setup-box-url');
  static const Key keyFieldKey = ValueKey('setup-box-key');
  static const Key checkKey = ValueKey('setup-box-check');

  /// The box card's title. The word recommended rides a middle dot rather
  /// than a parenthesis: user-facing strings carry neither parentheticals nor
  /// em-dashes.
  static const String boxTitle = 'GPU server · recommended';
  static const String boxBlurb =
      'The inbox and writing steps run on the project’s GPU server, a machine '
      'the project rents in the cloud, so message text and drafts travel '
      'there over an encrypted connection. The embedding model stays on '
      'this Mac.';
  static const String localTitle = 'This Mac';
  static const String localBlurb =
      'Everything runs here and nothing leaves the machine.';

  /// What the key field says when one is already in the keychain. The target
  /// editor's own words, because it is the same promise: the stored token is
  /// never read back, and typing replaces it.
  static const String keyStoredHint = 'Stored. Type to replace';

  /// The two captions over a two-slot check.
  static const String proseProbeLabel = 'Writing model';
  static const String bulkProbeLabel = 'Inbox model';

  /// What a press says when the address is not one the app can dial.
  ///
  /// The rule belongs to the FORM rather than to either host, so the wizard
  /// and the Settings page refuse the same address in the same words. It is
  /// the rule `setBoxUrl` throws on, said here before the press reaches it:
  /// both presses are fire-and-forget, and a throw past one of them is an
  /// unhandled error and, to the person, a button that did nothing.
  static const String addressRefusalText =
      'The address needs to start with http:// or https:// and name a server.';

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

  /// A press refused for its address, until the address is typed in again.
  /// A refusal about a string that has since been edited is a report about a
  /// different address.
  bool _refused = false;

  @override
  void initState() {
    super.initState();
    // Both fields drive the primary button's enabled state, so a rebuild per
    // keystroke is the point rather than a cost.
    _key.addListener(_onTyped);
    _url.addListener(_onUrlTyped);
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
    _url.removeListener(_onUrlTyped);
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _onTyped() {
    if (mounted) setState(() {});
  }

  void _onUrlTyped() {
    if (mounted) setState(() => _refused = false);
  }

  bool get _isBox => widget.placement == ModelPlacement.box;

  /// Whether the typed address is one the app can dial. Both presses ask.
  bool get _addressOk => isBoxOrigin(normalizeBoxBaseUrl(_url.text));

  /// A press on the box choice, refused with a sentence when the address is
  /// not an origin. [action] runs only on an address that passes, so neither
  /// host is ever handed one it would have to throw on.
  void _guarded(VoidCallback action) {
    if (_isBox && !_addressOk) {
      setState(() => _refused = true);
      return;
    }
    action();
  }

  /// Both fields filled, on the box choice. This Mac needs neither.
  ///
  /// A key already in the keychain answers the second half: the field opens
  /// empty on purpose, so demanding something in it would make a stored key
  /// impossible to keep while the address is changed.
  ///
  /// A BAD address does not come in here. The button stays live over one, so
  /// that the press can say why it is refused rather than going quiet.
  bool get _canContinue => _isBox
      ? _url.text.trim().isNotEmpty &&
          (widget.keyStored || _key.text.trim().isNotEmpty)
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
          if (_refused) ...[
            const SizedBox(height: BondSpacing.s8),
            const InlineAlert(
              severity: InlineAlertSeverity.error,
              text: SetupWhereBody.addressRefusalText,
            ),
          ],
          const SizedBox(height: BondSpacing.s12),
          TextField(
            key: SetupWhereBody.keyFieldKey,
            controller: _key,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Access key',
              hintText: widget.keyStored ? SetupWhereBody.keyStoredHint : null,
            ),
          ),
          if (widget.onCheck case final check?) ...[
            const SizedBox(height: BondSpacing.s12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: SetupWhereBody.checkKey,
                onPressed: widget.probing
                    ? null
                    : () => _guarded(() => check(_key.text.trim())),
                child: const Text('Check server'),
              ),
            ),
            const SizedBox(height: BondSpacing.s8),
            ..._probeLines(),
          ],
        ],
        const SizedBox(height: BondSpacing.s24),
        SetupPrimaryButton(
          label: widget.continueLabel,
          onPressed: _canContinue
              ? () => _guarded(() => widget.onContinue(_key.text.trim()))
              : null,
        ),
      ],
    );
  }

  /// What a check reports: one line for the one server a host asked about, or
  /// two captioned ones when it asked about both of the box's slots.
  ///
  /// The captions are the two roles rather than the two URL paths, because
  /// `/prose` and `/bulk` are wire spellings and the person reading this is
  /// deciding whether the writing model answered.
  ///
  /// [SetupWhereBody.twoSlots] decides the shape, never the answers: the
  /// captions are up from the first frame of a check, so the reader is not
  /// handed a relabelled line halfway through one.
  List<Widget> _probeLines() {
    if (!widget.twoSlots) {
      return [ProbeStatus(probing: widget.probing, result: widget.probeResult)];
    }
    return [
      Text(SetupWhereBody.proseProbeLabel, style: BondType.caption),
      ProbeStatus(probing: widget.probing, result: widget.probeResult),
      const SizedBox(height: BondSpacing.s8),
      Text(SetupWhereBody.bulkProbeLabel, style: BondType.caption),
      ProbeStatus(probing: widget.probing, result: widget.bulkProbeResult),
    ];
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
