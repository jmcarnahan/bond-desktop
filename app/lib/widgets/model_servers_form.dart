import 'dart:async';

import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart'
    show
        LlmTargetSpec,
        LlmWire,
        boxBulkId,
        boxProseId,
        boxProseName,
        isBoxOrigin,
        isThirdPartyHost,
        wireForHost;
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'probe_status.dart' show ProbeStatus, guardedProbe;

/// The one form for servers a person names: two addresses, one key, and a
/// press that asks each server what it serves.
///
/// The model NAME is never typed. Connect probes both addresses with the key,
/// reads `/v1/models` and either uses the one id a server lists or puts a
/// picker under that address and waits for a second press. That is the whole
/// of decision 16, and it is why this widget owns a probe rather than a
/// Check button: checking and connecting are the same question asked once.
///
/// PROP-ONLY, like every other body in Settings: the host resolves the
/// prefilled values, takes the write back through [onConnect] and owns the
/// consent pane a third-party address opens. One exception to "no state": the
/// ACCESS KEY lives in its two [TextEditingController]s, and in the one place
/// they reach — the `resume` closure handed to [onThirdParty], which captures
/// the typed values so Continue can finish the same connect. That closure is
/// held by whoever opened the consent pane, for as long as it is open, and
/// closing the pane drops it. The key is never copied into this State, never
/// logged, never put in a result, and the controllers are emptied the moment a
/// connect lands.
///
/// The Settings page and, from the wizard's Where step, the setup flow render
/// the same instance of this, which is why the two refusal sentences and the
/// two field keys are static members here rather than on either host.
class ModelServersForm extends StatefulWidget {
  /// The four effective values to prefill: the stored ones where there are
  /// stored ones, the build's otherwise. Never a key.
  final String bigUrl;
  final String smallUrl;
  final String bigModel;
  final String smallModel;

  /// Whether a key is in the keychain for either server, for one server or
  /// for the other. Presence flags, never the token: the first decides
  /// whether **Remove key** is offered at all, and the two below which field
  /// hints that typing replaces something.
  final bool keyStored;
  final bool bigKeyStored;
  final bool smallKeyStored;

  /// Asks a server what it serves. **Null takes Connect off**: a form that
  /// cannot discover a name has nothing to write, which is this screen's
  /// usual "absent wiring, absent control" discipline.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for a probe's `Authorization` header.
  /// A LOOKUP by id, never the value.
  final String? Function(String targetId)? storedBearer;

  /// The write, once both names are known. May throw [ArgumentError], whose
  /// message is rendered under the form: `setBoxServers` refuses a
  /// third-party big address while cloud drafts consent is false, and the
  /// person has to read why.
  final Future<void> Function({
    required String bigUrl,
    required String smallUrl,
    required String bigModel,
    required String smallModel,
    String? bigKey,
    String? smallKey,
  }) onConnect;

  /// Forgets both stored keys. Null takes **Remove key** off.
  final Future<void> Function()? onRemoveKey;

  /// Raised when the BIG address is somebody else's service, with the spec
  /// the consent pane asks about and the closure that finishes the connect.
  /// Null refuses such an address instead, which is what the wizard passes.
  final Future<void> Function(
    LlmTargetSpec big,
    Future<void> Function() resume,
  )? onThirdParty;

  /// The press's own word: **Connect** in Settings, **Continue** in the
  /// wizard, where it is also the way forward.
  final String connectLabel;

  const ModelServersForm({
    super.key,
    this.bigUrl = '',
    this.smallUrl = '',
    this.bigModel = '',
    this.smallModel = '',
    this.keyStored = false,
    this.bigKeyStored = false,
    this.smallKeyStored = false,
    this.probe,
    this.storedBearer,
    required this.onConnect,
    this.onRemoveKey,
    this.onThirdParty,
    this.connectLabel = 'Connect',
  });

  /// Keyed for the reason every control in Settings is: the words on them are
  /// ordinary words that also appear in the sentences beside them.
  static const Key bigUrlKey = ValueKey('servers-big-url');
  static const Key smallUrlKey = ValueKey('servers-small-url');
  static const Key keyKey = ValueKey('servers-key');
  static const Key smallKeyKey = ValueKey('servers-small-key');
  static const Key bigModelKey = ValueKey('servers-big-model');
  static const Key smallModelKey = ValueKey('servers-small-model');
  static const Key bigModelTextKey = ValueKey('servers-big-model-text');
  static const Key smallModelTextKey = ValueKey('servers-small-model-text');
  static const Key connectKey = ValueKey('servers-connect');
  static const Key removeKeyKey = ValueKey('servers-remove-key');
  static const Key errorKey = ValueKey('servers-error');

  static const String bigUrlLabel = 'Big model address';
  static const String smallUrlLabel = 'Small model address';
  static const String keyLabel = 'Access key';
  static const String smallKeyLabel = 'Access key for the small model';
  static const String modelLabel = 'Model';
  static const String removeKeyLabel = 'Remove key';

  /// What a key field says when there is one in the keychain. The field opens
  /// EMPTY: nothing on this screen ever reads a stored key back.
  static const String storedHint = 'Stored. Type to replace';

  /// An address that is not an address, in the same words the wizard used
  /// before this form existed.
  static const String addressRefusalText =
      'The address needs to start with http:// or https:// and name a server.';

  /// An origin where an endpoint belongs. `isBoxOrigin` cannot tell the two
  /// apart — it reads the scheme and the host and nothing else — so this is
  /// the rule that catches `https://box.example.com` pasted into a field that
  /// wants the chat completions URL.
  static const String endpointRefusalText =
      'The address needs to be the chat completions endpoint, ending in '
      '/v1/chat/completions.';

  /// A server that lists several models: the pick is the person's, and the
  /// press that discovered the list is not the press that connects.
  static const String chooseModelText =
      'This server lists several models. Choose one and press ';

  /// A Converse address, which has no `/v1/models` to ask.
  static const String modelNeededText =
      'Type the model name. This service does not list its models.';

  /// A write that did not land for a reason nobody typed: a locked keychain,
  /// a denied prompt, a store that would not answer. The person can only try
  /// again, so that is what it says.
  static const String saveFailedText =
      'The servers could not be saved. Try again.';

  /// A vendor's address where no consent pane can be opened, which is the
  /// wizard. Cloud services are a Settings decision, taken once, after the
  /// install works at all.
  static const String thirdPartyRefusalText =
      'Cloud services are connected under Settings after setup.';

  @override
  State<ModelServersForm> createState() => _ModelServersFormState();
}

class _ModelServersFormState extends State<ModelServersForm> {
  late final TextEditingController _bigUrl =
      TextEditingController(text: widget.bigUrl);
  late final TextEditingController _smallUrl =
      TextEditingController(text: widget.smallUrl);

  /// The two secrets, and the only place either one is held.
  final TextEditingController _key = TextEditingController();
  final TextEditingController _smallKey = TextEditingController();

  /// The typed model name for a Converse address, which lists nothing.
  late final TextEditingController _bigModelText =
      TextEditingController(text: widget.bigModel);
  late final TextEditingController _smallModelText =
      TextEditingController(text: widget.smallModel);

  /// What the last press found, per address.
  bool _probing = false;
  ModelProbeResult? _bigProbe;
  ModelProbeResult? _smallProbe;
  List<String> _bigIds = const [];
  List<String> _smallIds = const [];
  String? _bigPick;
  String? _smallPick;

  /// The sentence under each field, and the one under the form.
  String? _bigRefusal;
  String? _smallRefusal;
  bool _chooseBig = false;
  bool _chooseSmall = false;
  String? _error;

  /// Which press is the current one. Every edit bumps it and every press
  /// takes a new number, so an answer about a server nobody is asking about
  /// any more is dropped rather than rendered.
  int _connectSeq = 0;

  @override
  void didUpdateWidget(ModelServersForm old) {
    super.didUpdateWidget(old);
    // The host re-resolved the prefill — a connect landed, or the placement
    // moved. A field the person has not touched adopts it; one they have is
    // theirs.
    if (old.bigUrl != widget.bigUrl && _bigUrl.text == old.bigUrl) {
      _bigUrl.text = widget.bigUrl;
    }
    if (old.smallUrl != widget.smallUrl && _smallUrl.text == old.smallUrl) {
      _smallUrl.text = widget.smallUrl;
    }
    if (old.bigModel != widget.bigModel && _bigModelText.text == old.bigModel) {
      _bigModelText.text = widget.bigModel;
    }
    if (old.smallModel != widget.smallModel &&
        _smallModelText.text == old.smallModel) {
      _smallModelText.text = widget.smallModel;
    }
  }

  @override
  void dispose() {
    _bigUrl.dispose();
    _smallUrl.dispose();
    _key.dispose();
    _smallKey.dispose();
    _bigModelText.dispose();
    _smallModelText.dispose();
    super.dispose();
  }

  /// Whether the two addresses name two servers, recomputed on every edit.
  ///
  /// One host is one operator and one key; two hosts are two, and a token for
  /// one must never ride a request to the other. An address that does not
  /// parse has no host, and two blanks are one blank, so the second field
  /// stays away until there is a real difference to answer.
  bool get _twoHosts {
    final big = Uri.tryParse(_bigUrl.text.trim())?.host ?? '';
    final small = Uri.tryParse(_smallUrl.text.trim())?.host ?? '';
    return big.isNotEmpty && small.isNotEmpty && big != small;
  }

  bool _isConverse(String url) =>
      wireForHost(url) == LlmWire.bedrockConverse;

  @override
  Widget build(BuildContext context) {
    final bigUrl = _bigUrl.text.trim();
    final smallUrl = _smallUrl.text.trim();
    final onRemove = widget.onRemoveKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._address(
          fieldKey: ModelServersForm.bigUrlKey,
          label: ModelServersForm.bigUrlLabel,
          controller: _bigUrl,
          url: bigUrl,
          refusal: _bigRefusal,
          result: _bigProbe,
          ids: _bigIds,
          pick: _bigPick,
          onPick: (value) => setState(() => _bigPick = value),
          pickerKey: ModelServersForm.bigModelKey,
          modelTextKey: ModelServersForm.bigModelTextKey,
          modelText: _bigModelText,
          choose: _chooseBig,
        ),
        const SizedBox(height: BondSpacing.s12),
        ..._address(
          fieldKey: ModelServersForm.smallUrlKey,
          label: ModelServersForm.smallUrlLabel,
          controller: _smallUrl,
          url: smallUrl,
          refusal: _smallRefusal,
          result: _smallProbe,
          ids: _smallIds,
          pick: _smallPick,
          onPick: (value) => setState(() => _smallPick = value),
          pickerKey: ModelServersForm.smallModelKey,
          modelTextKey: ModelServersForm.smallModelTextKey,
          modelText: _smallModelText,
          choose: _chooseSmall,
        ),
        const SizedBox(height: BondSpacing.s12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                key: ModelServersForm.keyKey,
                controller: _key,
                obscureText: true,
                onChanged: (_) => _edited(),
                decoration: InputDecoration(
                  labelText: ModelServersForm.keyLabel,
                  hintText: widget.bigKeyStored
                      ? ModelServersForm.storedHint
                      : null,
                ),
              ),
            ),
            if (widget.keyStored && onRemove != null) ...[
              const SizedBox(width: BondSpacing.s8),
              TextButton(
                key: ModelServersForm.removeKeyKey,
                onPressed: () => unawaited(onRemove()),
                child: const Text(ModelServersForm.removeKeyLabel),
              ),
            ],
          ],
        ),
        if (_twoHosts) ...[
          const SizedBox(height: BondSpacing.s12),
          TextField(
            key: ModelServersForm.smallKeyKey,
            controller: _smallKey,
            obscureText: true,
            onChanged: (_) => _edited(),
            decoration: InputDecoration(
              labelText: ModelServersForm.smallKeyLabel,
              hintText:
                  widget.smallKeyStored ? ModelServersForm.storedHint : null,
            ),
          ),
        ],
        if (_error case final message?) ...[
          const SizedBox(height: BondSpacing.s12),
          InlineAlert(
            key: ModelServersForm.errorKey,
            severity: InlineAlertSeverity.error,
            text: message,
          ),
        ],
        const SizedBox(height: BondSpacing.s16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: ModelServersForm.connectKey,
            onPressed: widget.probe == null || _probing
                ? null
                : () => unawaited(_connect()),
            child: Text(widget.connectLabel),
          ),
        ),
      ],
    );
  }

  /// One address, and everything the last press has to say about it.
  List<Widget> _address({
    required Key fieldKey,
    required String label,
    required TextEditingController controller,
    required String url,
    required String? refusal,
    required ModelProbeResult? result,
    required List<String> ids,
    required String? pick,
    required ValueChanged<String?> onPick,
    required Key pickerKey,
    required Key modelTextKey,
    required TextEditingController modelText,
    required bool choose,
  }) {
    final converse = _isConverse(url);
    return [
      TextField(
        key: fieldKey,
        controller: controller,
        onChanged: (_) => _edited(),
        decoration: InputDecoration(
          labelText: label,
          hintText: 'https://box.example.com/v1/chat/completions',
        ),
      ),
      if (refusal != null) ...[
        const SizedBox(height: BondSpacing.s8),
        InlineAlert(severity: InlineAlertSeverity.error, text: refusal),
      ],
      // A Converse service lists nothing, so there is nothing to probe and
      // nothing to pick: the name is typed, once.
      if (converse) ...[
        const SizedBox(height: BondSpacing.s8),
        TextField(
          key: modelTextKey,
          controller: modelText,
          onChanged: (_) => _edited(),
          decoration: const InputDecoration(
            labelText: ModelServersForm.modelLabel,
          ),
        ),
      ] else ...[
        const SizedBox(height: BondSpacing.s4),
        ProbeStatus(probing: _probing, result: result),
        if (ids.length > 1) ...[
          const SizedBox(height: BondSpacing.s4),
          Align(
            alignment: Alignment.centerLeft,
            child: DropdownButton<String>(
              key: pickerKey,
              value: pick,
              onChanged: onPick,
              items: [
                for (final id in ids)
                  DropdownMenuItem(value: id, child: Text(id)),
              ],
            ),
          ),
          if (choose)
            Text(
              '${ModelServersForm.chooseModelText}${widget.connectLabel} '
              'again.',
              style: BondType.caption,
            ),
        ],
      ],
    ];
  }

  /// Any edit, anywhere: the press it would have belonged to is dropped and
  /// every answer about the old values comes off the screen.
  void _edited() {
    setState(() {
      _connectSeq++;
      _probing = false;
      _bigProbe = null;
      _smallProbe = null;
      _bigIds = const [];
      _smallIds = const [];
      _bigPick = null;
      _smallPick = null;
      _bigRefusal = null;
      _smallRefusal = null;
      _chooseBig = false;
      _chooseSmall = false;
      _error = null;
    });
  }

  /// The one press: refuse, probe, discover, ask for consent where it is
  /// owed, write.
  ///
  /// Every step after the first is guarded by [_connectSeq], so an address
  /// edited while a server was being asked leaves nothing behind.
  Future<void> _connect() async {
    final probe = widget.probe;
    if (probe == null) return;
    final seq = ++_connectSeq;
    final bigUrl = _bigUrl.text.trim();
    final smallUrl = _smallUrl.text.trim();

    final bigRefusal = _refuse(bigUrl);
    final smallRefusal = _refuse(smallUrl);
    if (bigRefusal != null || smallRefusal != null) {
      setState(() {
        _bigRefusal = bigRefusal;
        _smallRefusal = smallRefusal;
        _error = null;
      });
      return;
    }

    // The typed key beats the stored one, which is what checking a rotated
    // key before writing it means. With one host there is one key and it
    // rides both requests.
    final typedBig = _key.text.trim();
    final typedSmall = _twoHosts ? _smallKey.text.trim() : typedBig;
    final bigKey = typedBig.isEmpty ? null : typedBig;
    final smallKey = typedSmall.isEmpty ? null : typedSmall;
    final bigBearer = bigKey ?? widget.storedBearer?.call(boxProseId);
    final smallBearer = smallKey ?? widget.storedBearer?.call(boxBulkId);

    final bigConverse = _isConverse(bigUrl);
    final smallConverse = _isConverse(smallUrl);
    setState(() {
      _probing = true;
      _bigProbe = null;
      _smallProbe = null;
      _bigRefusal = null;
      _smallRefusal = null;
      _chooseBig = false;
      _chooseSmall = false;
      _error = null;
    });
    final answers = await Future.wait([
      bigConverse
          ? Future<ModelProbeResult?>.value()
          : guardedProbe(probe, bigUrl, bigBearer),
      smallConverse
          ? Future<ModelProbeResult?>.value()
          : guardedProbe(probe, smallUrl, smallBearer),
    ]);
    if (!mounted || seq != _connectSeq) return;
    final bigResult = answers[0];
    final smallResult = answers[1];
    final bigIds = bigResult?.modelIds ?? const <String>[];
    final smallIds = smallResult?.modelIds ?? const <String>[];
    setState(() {
      _probing = false;
      _bigProbe = bigResult;
      _smallProbe = smallResult;
      _bigIds = bigIds;
      _smallIds = smallIds;
    });
    // A server that did not answer stops the press where it is: the line
    // under its own field says what happened, and nothing is written.
    if (bigResult != null && !bigResult.reachable) return;
    if (smallResult != null && !smallResult.reachable) return;

    final bigName = _name(
      converse: bigConverse,
      typed: _bigModelText.text.trim(),
      ids: bigIds,
      pick: _bigPick,
    );
    final smallName = _name(
      converse: smallConverse,
      typed: _smallModelText.text.trim(),
      ids: smallIds,
      pick: _smallPick,
    );
    if (bigName is! _Name || smallName is! _Name) {
      setState(() {
        if (bigName is _NeedsName) _bigRefusal = bigName.refusal;
        if (bigName is _NeedsPick) {
          _bigPick = bigName.first;
          _chooseBig = true;
        }
        if (smallName is _NeedsName) _smallRefusal = smallName.refusal;
        if (smallName is _NeedsPick) {
          _smallPick = smallName.first;
          _chooseSmall = true;
        }
      });
      return;
    }
    // A server that listed nothing named nothing: the probe's own line says
    // so and there is no name to write.
    if (bigName.value.isEmpty || smallName.value.isEmpty) return;

    Future<void> write() => _write(
          seq: seq,
          bigUrl: bigUrl,
          smallUrl: smallUrl,
          bigModel: bigName.value,
          smallModel: smallName.value,
          bigKey: bigKey,
          smallKey: smallKey,
        );

    // Somebody else's service on the address the drafts go to. The pane
    // belongs to the host: it writes the consent and calls back.
    if (isThirdPartyHost(bigUrl) || bigConverse) {
      final ask = widget.onThirdParty;
      if (ask == null) {
        setState(
          () => _bigRefusal = ModelServersForm.thirdPartyRefusalText,
        );
        return;
      }
      await ask(
        LlmTargetSpec(
          id: boxProseId,
          name: boxProseName,
          url: bigUrl,
          model: bigName.value,
          wire: wireForHost(bigUrl),
          hasBearer: bigKey != null || widget.bigKeyStored,
          parallel: 1,
        ),
        write,
      );
      return;
    }
    await write();
  }

  /// The write itself, and the one place the key fields are emptied.
  ///
  /// The call is DELIBERATELY not guarded by `mounted`. A connect resumed from
  /// the consent pane runs with this form unmounted — the pane replaced the
  /// sections that held it — and a guard here would make Continue write
  /// nothing at all.
  ///
  /// EVERYTHING can throw, not just the refusal. `useBox` is three writes and
  /// one of them is the keychain, which answers with a `PlatformException` on
  /// a locked keychain, a denied prompt or a missing plugin. Unhandled, that
  /// left the key field full, no sentence on screen and the placement
  /// unmoved, so the catch is `on Object` and the sentence is either the
  /// refusal's own or [ModelServersForm.saveFailedText]. When this form is
  /// gone the throw is RETHROWN instead, to whoever resumed the connect.
  Future<void> _write({
    required int seq,
    required String bigUrl,
    required String smallUrl,
    required String bigModel,
    required String smallModel,
    String? bigKey,
    String? smallKey,
  }) async {
    try {
      await widget.onConnect(
        bigUrl: bigUrl,
        smallUrl: smallUrl,
        bigModel: bigModel,
        smallModel: smallModel,
        bigKey: bigKey,
        smallKey: smallKey,
      );
    } on Object catch (e) {
      // A form that cannot DRAW the sentence must not swallow it: a connect
      // resumed from the consent pane runs with this widget unmounted, and
      // the pane standing in its place is what shows the refusal there.
      if (!mounted) rethrow;
      // Guarded on the way out, like every other step: a press outlived by an
      // edit must not put a sentence about the old values under fields that
      // have moved on.
      if (seq != _connectSeq) return;
      setState(() => _error = e is ArgumentError
          ? e.message.toString()
          : ModelServersForm.saveFailedText);
      return;
    }
    if (!mounted || seq != _connectSeq) return;
    setState(() {
      _error = null;
      // The key has reached the keychain; nothing on this screen holds it
      // for a second longer.
      _key.clear();
      _smallKey.clear();
    });
  }

  /// What a URL is refused for, or null when it may be asked.
  String? _refuse(String url) {
    if (!isBoxOrigin(url)) return ModelServersForm.addressRefusalText;
    if (_isConverse(url)) return null;
    return Uri.parse(url).path.contains('/v1/')
        ? null
        : ModelServersForm.endpointRefusalText;
  }

  /// One address's model name: the typed one for a Converse service, the one
  /// id a server lists, or the pick under a server that lists several.
  _Discovered _name({
    required bool converse,
    required String typed,
    required List<String> ids,
    required String? pick,
  }) {
    if (converse) {
      return typed.isEmpty
          ? const _NeedsName(ModelServersForm.modelNeededText)
          : _Name(typed);
    }
    if (ids.isEmpty) return const _Name('');
    if (ids.length == 1) return _Name(ids.first);
    // The press that first produced the list is not the press that connects:
    // the first id is filled in, the picker comes up, and a second press
    // takes whatever is showing.
    if (pick == null || !ids.contains(pick)) return _NeedsPick(ids.first);
    return _Name(pick);
  }
}

/// What one address's name resolved to, as three outcomes rather than a
/// nullable string: a name, a picker that has to be shown first, or a field
/// that has to be typed into.
sealed class _Discovered {
  const _Discovered();
}

class _Name extends _Discovered {
  final String value;
  const _Name(this.value);
}

class _NeedsPick extends _Discovered {
  final String first;
  const _NeedsPick(this.first);
}

class _NeedsName extends _Discovered {
  final String refusal;
  const _NeedsName(this.refusal);
}
