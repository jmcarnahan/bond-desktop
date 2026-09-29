import 'dart:async';

import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart'
    show
        LlmTargetSpec,
        LlmWire,
        accessKeyCharsText,
        boxDecideId,
        boxDecideModel,
        boxProseId,
        cloudDraftsId,
        cloudDraftsName,
        decideModelDefault,
        isBoxOrigin,
        isThirdPartyHost,
        isUsableAccessKey,
        routerDecideId,
        wireForHost;
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'probe_status.dart' show ProbeStatus, guardedProbe;

/// Which target one [ModelServersForm] points somewhere.
///
/// The two ROLES read every message and never go to a vendor; the cloud
/// drafts target is the one place a third-party service may serve, behind
/// the consent pane. Each value carries the prefix its widget keys are built
/// on and the keychain id its stored token lives under.
enum ServerFormRole {
  decision('servers-decision', boxDecideId),
  generative('servers-generative', boxProseId),
  cloudDrafts('cloud-drafts', cloudDraftsId);

  const ServerFormRole(this.keyPrefix, this.targetId);

  /// `servers-decision-url`, `servers-generative-connect`, `cloud-drafts-key`…
  final String keyPrefix;

  /// The target whose stored token a probe borrows while the key field is
  /// blank. An ID, never the token.
  final String targetId;
}

/// What one press of [ModelServersForm] hands its host: the address as
/// typed, the model name the server itself listed, the key as typed (null
/// keeps the stored one) and whether the stored key must be FORGOTTEN
/// because the address now names another host.
typedef ServerConnect = Future<void> Function({
  required String url,
  required String model,
  String? key,
  required bool clearKey,
});

/// The one form for a server a person names: one address, one key, and a
/// press that asks the server what it serves.
///
/// One instance per target since the decision-model round: the Decision
/// model and the Generative model each get their own on the Models page, the
/// cloud drafts target gets one under Cloud drafts, and the wizard's Where
/// step renders the same widget with **Continue** as its word.
///
/// The model NAME is never typed. Connect probes the address with the key,
/// reads `/v1/models` and either uses the one id the server lists or puts a
/// picker under the address and waits for a second press. A decision server
/// is never asked to pick: the decision model's own name is taken when it is
/// listed, and the first id otherwise.
///
/// PROP-ONLY, like every other body in Settings: the host resolves the
/// prefilled values, takes the write back through [onConnect] and owns the
/// consent pane a third-party address opens. One exception to "no state":
/// the ACCESS KEY lives in its [TextEditingController], and in the one place
/// it reaches, the `resume` closure handed to [onThirdParty], which captures
/// the typed value so Continue can finish the same connect. The key is never
/// copied into this State, never logged, never put in a result, and the
/// controller is emptied the moment a connect lands.
///
/// KEY vs HOST: a key belongs to the host it was typed for. When the address
/// names a different host from the stored one and the key field is blank, the
/// stored token is NOT sent with the probe and the press asks the host to
/// forget it ([ServerConnect]'s `clearKey`), so a token for one machine never
/// rides a request to another.
class ModelServersForm extends StatefulWidget {
  final ServerFormRole role;

  /// The effective values to prefill: the stored ones where there are stored
  /// ones, the build's otherwise. Never a key.
  final String url;
  final String model;

  /// Whether a key for this target is in the keychain. A presence flag,
  /// never the token: it offers **Remove key** and hints that typing
  /// replaces something.
  final bool keyStored;

  /// Asks a server what it serves. **Null takes Connect off**: a form that
  /// cannot discover a name has nothing to write.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up one target's stored token for a probe's `Authorization` header.
  /// A LOOKUP by id, never the value.
  final String? Function(String targetId)? storedBearer;

  /// The write, once the name is known. May throw; an [ArgumentError]'s
  /// message is rendered under the form, anything else as [saveFailedText].
  final ServerConnect onConnect;

  /// Forgets the stored key. Null takes **Remove key** off.
  final Future<void> Function()? onRemoveKey;

  /// Raised when the address is somebody else's service, with the spec the
  /// consent pane asks about and the closure that finishes the connect.
  /// Null refuses such an address with [thirdPartyRefusal] instead.
  final Future<void> Function(
    LlmTargetSpec target,
    Future<void> Function() resume,
  )? onThirdParty;

  /// The sentence a third-party address is refused with while
  /// [onThirdParty] is null. Null reads as [thirdPartyRefusalText], the
  /// wizard's.
  final String? thirdPartyRefusal;

  /// The press's own word: **Connect** in Settings, **Continue** in the
  /// wizard, where it is also the way forward.
  final String connectLabel;

  const ModelServersForm({
    super.key,
    required this.role,
    this.url = '',
    this.model = '',
    this.keyStored = false,
    this.probe,
    this.storedBearer,
    required this.onConnect,
    this.onRemoveKey,
    this.onThirdParty,
    this.thirdPartyRefusal,
    this.connectLabel = 'Connect',
  });

  /// Keyed for the reason every control in Settings is: the words on them are
  /// ordinary words that also appear in the sentences beside them.
  static Key urlKey(ServerFormRole role) => ValueKey('${role.keyPrefix}-url');
  static Key keyKey(ServerFormRole role) => ValueKey('${role.keyPrefix}-key');
  static Key modelKey(ServerFormRole role) =>
      ValueKey('${role.keyPrefix}-model');
  static Key modelTextKey(ServerFormRole role) =>
      ValueKey('${role.keyPrefix}-model-text');
  static Key connectKey(ServerFormRole role) =>
      ValueKey('${role.keyPrefix}-connect');
  static Key errorKey(ServerFormRole role) =>
      ValueKey('${role.keyPrefix}-error');
  static Key refusalKey(ServerFormRole role) =>
      ValueKey('${role.keyPrefix}-refusal');
  static Key removeKeyKey(ServerFormRole role) =>
      ValueKey('${role.keyPrefix}-remove-key');

  static String urlLabel(ServerFormRole role) => switch (role) {
        ServerFormRole.decision => 'Decision model address',
        ServerFormRole.generative => 'Generative model address',
        ServerFormRole.cloudDrafts => 'Cloud drafts address',
      };

  static String urlHint(ServerFormRole role) => switch (role) {
        ServerFormRole.decision =>
          'https://box.example.com/decide/v1/embeddings',
        ServerFormRole.generative =>
          'https://box.example.com/prose/v1/chat/completions',
        ServerFormRole.cloudDrafts =>
          'https://api.example.com/v1/chat/completions',
      };

  static const String keyLabel = 'Access key';
  static const String modelLabel = 'Model';
  static const String removeKeyLabel = 'Remove key';

  /// What the key field says when there is one in the keychain. The field
  /// opens EMPTY: nothing on this screen ever reads a stored key back.
  static const String storedHint = 'Stored. Type to replace';

  /// What it says once the address names another host: the stored key is
  /// for the old one, and this press will forget it unless a new one is
  /// typed.
  static const String otherHostHint =
      "The stored key is for another server. Type this server's key.";

  /// An address that is not an address.
  static const String addressRefusalText =
      'The address needs to start with http:// or https:// and name a server.';

  /// An origin where an endpoint belongs, for the two chat targets.
  static const String endpointRefusalText =
      'The address needs to be the chat completions endpoint, ending in '
      '/v1/chat/completions.';

  /// The same for the decision model: an embeddings server (ModernBERT), or
  /// a Kev server's systemone endpoint.
  static const String decisionEndpointRefusalText =
      'The address needs to be the embeddings endpoint, ending in '
      '/v1/embeddings, or a Kev server\'s, ending in /v1/systemone.';

  /// A server that lists several models: the pick is the person's, and the
  /// press that discovered the list is not the press that connects.
  static const String chooseModelText =
      'This server lists several models. Choose one and press ';

  /// A Converse address, which has no `/v1/models` to ask.
  static const String modelNeededText =
      'Type the model name. This service does not list its models.';

  /// A write that did not land for a reason nobody typed.
  static const String saveFailedText =
      'The server could not be saved. Try again.';

  /// A vendor's address where no consent pane can be opened, which is the
  /// wizard. Cloud services are a Settings decision, taken once, after the
  /// install works at all.
  static const String thirdPartyRefusalText =
      'Cloud services are connected under Settings after setup.';

  /// A vendor's address on the Decision model's field: it reads every
  /// message, and no cloud service serves that role from any screen.
  static const String decisionThirdPartyRefusalText =
      'The decision model reads every message, so it runs on this Mac or on '
      'a server of your own.';

  /// A vendor's address on the Generative model's field in Settings, which
  /// points at the one place a vendor may serve.
  static const String generativeThirdPartyRefusalText =
      'A cloud service can write drafts only. Set it up under Cloud drafts.';

  @override
  State<ModelServersForm> createState() => _ModelServersFormState();
}

class _ModelServersFormState extends State<ModelServersForm> {
  late final TextEditingController _url =
      TextEditingController(text: widget.url);

  /// The secret, and the only place it is held.
  final TextEditingController _key = TextEditingController();

  /// The typed model name for a Converse address, which lists nothing.
  late final TextEditingController _modelText =
      TextEditingController(text: widget.model);

  bool _probing = false;
  ModelProbeResult? _probe;
  List<String> _ids = const [];
  String? _pick;
  String? _refusal;
  bool _choose = false;
  String? _error;

  /// The sentence under the key field when what was typed cannot be sent.
  String? _keyError;

  /// Which press is the current one. Every edit bumps it and every press
  /// takes a new number, so an answer about a server nobody is asking about
  /// any more is dropped rather than rendered.
  int _connectSeq = 0;

  ServerFormRole get _role => widget.role;

  @override
  void didUpdateWidget(ModelServersForm old) {
    super.didUpdateWidget(old);
    // The host re-resolved the prefill. A field the person has not touched
    // adopts it; one they have is theirs.
    if (old.url != widget.url && _url.text == old.url) {
      _url.text = widget.url;
    }
    if (old.model != widget.model && _modelText.text == old.model) {
      _modelText.text = widget.model;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _modelText.dispose();
    super.dispose();
  }

  /// The ORIGIN a key belongs to: scheme, host and port, with the default
  /// port spelled out, so `https://h` and `https://h:443` are one origin and
  /// `http://h` or `https://h:8443` are another. Empty for no address.
  static String _origin(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return '';
    // `Uri.port` already answers 443 / 80 for an unspelled https / http port.
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}';
  }

  /// Whether the typed address names another server than the stored one. A
  /// scheme or a port change counts: a token must not ride plain http, or to
  /// another service on the same machine.
  bool get _hostChanged => _origin(_url.text) != _origin(widget.url);

  bool _isConverse(String url) => wireForHost(url) == LlmWire.bedrockConverse;

  @override
  Widget build(BuildContext context) {
    final url = _url.text.trim();
    final onRemove = widget.onRemoveKey;
    final converse = _isConverse(url);
    final hint = !widget.keyStored
        ? null
        : (_hostChanged
            ? ModelServersForm.otherHostHint
            : ModelServersForm.storedHint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: ModelServersForm.urlKey(_role),
          controller: _url,
          onChanged: (_) => _edited(),
          decoration: InputDecoration(
            labelText: ModelServersForm.urlLabel(_role),
            hintText: ModelServersForm.urlHint(_role),
          ),
        ),
        if (_refusal case final refusal?) ...[
          const SizedBox(height: BondSpacing.s8),
          InlineAlert(
            key: ModelServersForm.refusalKey(_role),
            severity: InlineAlertSeverity.error,
            text: refusal,
          ),
        ],
        // A Converse service lists nothing, so there is nothing to probe and
        // nothing to pick: the name is typed, once.
        if (converse) ...[
          const SizedBox(height: BondSpacing.s8),
          TextField(
            key: ModelServersForm.modelTextKey(_role),
            controller: _modelText,
            onChanged: (_) => _edited(),
            decoration: const InputDecoration(
              labelText: ModelServersForm.modelLabel,
            ),
          ),
        ] else ...[
          const SizedBox(height: BondSpacing.s4),
          ProbeStatus(probing: _probing, result: _probe),
          if (_ids.length > 1 && _role != ServerFormRole.decision) ...[
            const SizedBox(height: BondSpacing.s4),
            Align(
              alignment: Alignment.centerLeft,
              child: DropdownButton<String>(
                key: ModelServersForm.modelKey(_role),
                value: _pick,
                onChanged: (value) => setState(() => _pick = value),
                items: [
                  for (final id in _ids)
                    DropdownMenuItem(value: id, child: Text(id)),
                ],
              ),
            ),
            if (_choose)
              Text(
                '${ModelServersForm.chooseModelText}${widget.connectLabel} '
                'again.',
                style: BondType.caption,
              ),
          ],
        ],
        const SizedBox(height: BondSpacing.s12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                key: ModelServersForm.keyKey(_role),
                controller: _key,
                obscureText: true,
                onChanged: (_) => _edited(),
                decoration: InputDecoration(
                  labelText: ModelServersForm.keyLabel,
                  hintText: hint,
                  errorText: _keyError,
                ),
              ),
            ),
            if (widget.keyStored && onRemove != null) ...[
              const SizedBox(width: BondSpacing.s8),
              TextButton(
                key: ModelServersForm.removeKeyKey(_role),
                onPressed: () => unawaited(onRemove()),
                child: const Text(ModelServersForm.removeKeyLabel),
              ),
            ],
          ],
        ),
        if (_error case final message?) ...[
          const SizedBox(height: BondSpacing.s12),
          InlineAlert(
            key: ModelServersForm.errorKey(_role),
            severity: InlineAlertSeverity.error,
            text: message,
          ),
        ],
        const SizedBox(height: BondSpacing.s16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: ModelServersForm.connectKey(_role),
            onPressed: widget.probe == null || _probing
                ? null
                : () => unawaited(_connect()),
            child: Text(widget.connectLabel),
          ),
        ),
      ],
    );
  }

  /// Any edit, anywhere: the press it would have belonged to is dropped and
  /// every answer about the old values comes off the screen.
  void _edited() {
    setState(() {
      _connectSeq++;
      _probing = false;
      _probe = null;
      _ids = const [];
      _pick = null;
      _refusal = null;
      _choose = false;
      _error = null;
      _keyError = null;
    });
  }

  /// The one press: refuse, probe, discover, ask for consent where it is
  /// owed, write. Every step after the first is guarded by [_connectSeq].
  Future<void> _connect() async {
    final probe = widget.probe;
    if (probe == null) return;
    final seq = ++_connectSeq;
    final url = _url.text.trim();

    final refusal = _refuse(url);
    if (refusal != null) {
      setState(() {
        _refusal = refusal;
        _error = null;
      });
      return;
    }
    final converse = _isConverse(url);
    final thirdParty = isThirdPartyHost(url) || converse;
    // Somebody else's service where no consent can be asked: refused BEFORE
    // anything is sent to it, the stored key included.
    if (thirdParty && widget.onThirdParty == null) {
      setState(() {
        _refusal =
            widget.thirdPartyRefusal ?? ModelServersForm.thirdPartyRefusalText;
        _error = null;
      });
      return;
    }

    // The typed key beats the stored one, which is what checking a rotated
    // key before writing it means. A stored key rides the probe only to the
    // host it was typed for.
    final typed = _key.text.trim();
    // Refused here, before any probe carries it: a key with a line break or
    // a character outside printable ASCII is not a header any server
    // accepts. The sentence never quotes it.
    if (typed.isNotEmpty && !isUsableAccessKey(typed)) {
      setState(() => _keyError = accessKeyCharsText);
      return;
    }
    final key = typed.isEmpty ? null : typed;
    final hostChanged = _hostChanged;
    final bearer = key ??
        (hostChanged ? null : widget.storedBearer?.call(_role.targetId));
    final clearKey = key == null && hostChanged && widget.keyStored;

    setState(() {
      _probing = !converse;
      _probe = null;
      _refusal = null;
      _choose = false;
      _error = null;
    });
    final result = converse ? null : await guardedProbe(probe, url, bearer);
    if (!mounted || seq != _connectSeq) return;
    final ids = result?.modelIds ?? const <String>[];
    setState(() {
      _probing = false;
      _probe = result;
      _ids = ids;
      // A server that still lists the name this install already uses is not
      // asking a question.
      _pick ??= ids.contains(widget.model) ? widget.model : null;
    });
    // A server that did not answer stops the press where it is: the line
    // under the field says what happened, and nothing is written.
    if (result != null && !result.reachable) return;

    final name = _name(
      converse: converse,
      typed: _modelText.text.trim(),
      ids: ids,
      pick: _pick,
    );
    final String model;
    switch (name) {
      case _NeedsName(:final refusal):
        setState(() => _refusal = refusal);
        return;
      case _NeedsPick(:final first):
        setState(() {
          _pick = first;
          _choose = true;
        });
        return;
      case _Name(:final value):
        model = value;
    }
    // A server that listed nothing named nothing: the probe's own line says
    // so and there is no name to write.
    if (model.isEmpty) return;

    Future<void> write() => _write(
          seq: seq,
          url: url,
          model: model,
          key: key,
          clearKey: clearKey,
        );

    if (thirdParty) {
      await widget.onThirdParty!(
        LlmTargetSpec(
          id: cloudDraftsId,
          name: cloudDraftsName,
          url: url,
          model: model,
          wire: wireForHost(url),
          hasBearer: key != null || (widget.keyStored && !clearKey),
          parallel: 1,
        ),
        write,
      );
      return;
    }
    await write();
  }

  /// The write itself, and the one place the key field is emptied.
  ///
  /// DELIBERATELY not guarded by `mounted`: a connect resumed from the
  /// consent pane runs with this form unmounted, and a guard here would make
  /// Continue write nothing. When this form is gone a throw is RETHROWN, to
  /// whoever resumed the connect.
  Future<void> _write({
    required int seq,
    required String url,
    required String model,
    String? key,
    required bool clearKey,
  }) async {
    try {
      await widget.onConnect(
        url: url,
        model: model,
        key: key,
        clearKey: clearKey,
      );
    } on Object catch (e) {
      if (!mounted) rethrow;
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
    });
  }

  /// What a URL is refused for, or null when it may be asked.
  String? _refuse(String url) {
    if (!isBoxOrigin(url)) return ModelServersForm.addressRefusalText;
    if (_isConverse(url)) return null;
    final path = Uri.parse(url).path;
    if (_role == ServerFormRole.decision) {
      return path.endsWith('/embeddings') || path.endsWith('/v1/systemone')
          ? null
          : ModelServersForm.decisionEndpointRefusalText;
    }
    return path.contains('/v1/') ? null : ModelServersForm.endpointRefusalText;
  }

  /// The model name: the typed one for a Converse service, the one id a
  /// server lists (the decision model's own for a decision server), or the
  /// pick under a server that lists several.
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
    if (_role == ServerFormRole.decision) return _Name(_decisionId(ids));
    if (ids.length == 1) return _Name(ids.first);
    if (pick == null || !ids.contains(pick)) return _NeedsPick(ids.first);
    return _Name(pick);
  }

  /// The decision model's name among [ids]. A router lists every model it
  /// serves, and the embedding model's name first is as likely as not, so the
  /// decision model's known names win: the router's id, the box's served name,
  /// this build's hand-server name, and the name this install already uses.
  /// The first id only when none of them is listed — a single-model server
  /// that was started under some other name.
  String _decisionId(List<String> ids) {
    for (final known in [
      routerDecideId,
      boxDecideModel,
      decideModelDefault,
      widget.model,
    ]) {
      if (known.isNotEmpty && ids.contains(known)) return known;
    }
    return ids.first;
  }
}

/// What the address's name resolved to: a name, a picker that has to be
/// shown first, or a field that has to be typed into.
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
