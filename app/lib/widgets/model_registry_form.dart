import 'dart:async';

import 'package:flutter/material.dart';

import '../services/llm/model_slots.dart'
    show accessKeyCharsText, isBoxOrigin, isLoopbackHost, isUsableAccessKey,
        normalizeBoxBaseUrl, sameOrigin;
import '../services/models/registry_probe.dart' show RegistryCheck;
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'model_servers_form.dart' show ModelServersForm;

/// What a Save hands its host: the address as typed, the token as typed
/// (null keeps the stored one) and whether the stored token must be
/// forgotten because the address names another host. Answers a refusal
/// sentence, or null once the write landed.
typedef RegistrySave = Future<String?> Function({
  required String url,
  String? token,
  required bool clearToken,
});

/// Where Bond downloads the decision and embedding models from: the model
/// registry's address and its read token. Settings draws it on the Models
/// page, and the setup wizard's download step draws it, with no Check and no
/// Remove token, while a registry download has failed for a reason the
/// address or token fixes.
///
/// [ModelServersForm]'s discipline without its probe-and-discover press: the
/// registry serves files, not a model list, so **Save** writes what was
/// typed and **Check** asks the saved address for a byte of each model it
/// holds for this build. PROP-ONLY: the host resolves the address it opens on and takes the
/// write back through [onSave]. One exception to "no state": the TOKEN lives
/// in its [TextEditingController], is never copied into this State, never
/// logged, never put in a result, and the field is emptied the moment a Save
/// lands. A token belongs to the origin it was typed for, so a Save on
/// another origin with the field blank asks the host to forget the stored
/// one ([RegistrySave]'s `clearToken`).
class ModelRegistryForm extends StatefulWidget {
  /// The effective registry address to open on: the stored one, else the
  /// build's. Never a token.
  final String url;

  /// Whether a token is in the keychain. A presence flag, never the token.
  final bool tokenStored;

  /// Whether, with nothing in the keychain, the build's token applies to
  /// [url]'s origin. A presence flag, never the token.
  final bool tokenFromBuild;

  final RegistrySave onSave;

  /// Forgets the stored token. Null takes **Remove token** off.
  final Future<void> Function()? onRemoveToken;

  /// Asks the saved address for every model this build downloads from it,
  /// and answers the first that is not reachable. Null takes **Check** off.
  final Future<RegistryCheck> Function()? onCheck;

  /// A line the host has about the registry, shown under the buttons until
  /// a press of this form has something fresher to say.
  final String? status;

  const ModelRegistryForm({
    super.key,
    this.url = '',
    this.tokenStored = false,
    this.tokenFromBuild = false,
    required this.onSave,
    this.onRemoveToken,
    this.onCheck,
    this.status,
  });

  static const Key urlKey = ValueKey('settings-registry-url');
  static const Key tokenKey = ValueKey('settings-registry-token');
  static const Key saveKey = ValueKey('settings-registry-save');
  static const Key removeTokenKey = ValueKey('settings-registry-remove-token');
  static const Key checkKey = ValueKey('settings-registry-check');
  static const Key refusalKey = ValueKey('settings-registry-refusal');
  static const Key statusKey = ValueKey('settings-registry-status');

  static const String title = 'Model registry';
  static const String caption =
      'Where Bond downloads the decision and embedding models from.';
  static const String urlLabel = 'Registry address';
  static const String urlHint =
      'https://artifactory.example.com/artifactory/bond-models';
  static const String tokenLabel = 'Access token';
  static const String saveLabel = 'Save';
  static const String removeTokenLabel = 'Remove token';
  static const String checkLabel = 'Check';

  /// The token field's hints. It opens EMPTY whatever is stored.
  static const String storedHint = ModelServersForm.storedHint;
  static const String buildTokenHint =
      'Using the token from this build. Type to replace';
  static const String otherOriginHint = 'A new address needs its own token';

  /// Under a plain-http address on another machine: a proxy that upgrades it
  /// to https drops the token on the way, and the registry then refuses it.
  static const String httpsHint =
      'Use the https address when your registry has one.';

  static const String addressRefusalText = ModelServersForm.addressRefusalText;

  static const String savedText = 'Saved.';
  static const String reachableText = 'Registry reachable.';
  static const String unauthorizedText =
      'The model registry refused the access token.';
  static const String notFoundText =
      'The model registry does not have this model. Check its address.';
  static const String unreachableText = 'Registry unreachable.';
  static const String notConfiguredText =
      'No registry address yet. Type one and press Save.';
  static const String notAModelText =
      'The model registry answered with a web page, not a model. Check its '
      'address.';
  static const String redirectedText =
      'The registry answered with a redirect. A download will follow it.';

  /// Under Check while the typed address is not the saved one: Check asks
  /// the SAVED address, and an unsaved host is never sent the token.
  static const String saveFirstText = 'Save the address first to check it.';

  static String checkText(RegistryCheck check) => switch (check) {
        RegistryCheck.reachable => reachableText,
        RegistryCheck.unauthorized => unauthorizedText,
        RegistryCheck.notFound => notFoundText,
        RegistryCheck.unreachable => unreachableText,
        RegistryCheck.notConfigured => notConfiguredText,
        RegistryCheck.notAModel => notAModelText,
        RegistryCheck.redirected => redirectedText,
      };

  @override
  State<ModelRegistryForm> createState() => _ModelRegistryFormState();
}

class _ModelRegistryFormState extends State<ModelRegistryForm> {
  late final TextEditingController _url =
      TextEditingController(text: widget.url);

  /// The secret, and the only place it is held.
  final TextEditingController _token = TextEditingController();

  String? _refusal;
  String? _tokenError;
  String? _result;
  bool _busy = false;

  /// Which press is the current one; an edit drops an answer in flight.
  int _seq = 0;

  /// The address the last Save that landed wrote, normalised: blank when it
  /// asked to follow the build.
  String? _lastSaved;

  @override
  void didUpdateWidget(ModelRegistryForm old) {
    super.didUpdateWidget(old);
    // The host re-resolved the address. A field the person has not touched
    // adopts it; one they have is theirs.
    if (old.url != widget.url && _url.text == old.url) {
      _url.text = widget.url;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  /// Whether the typed address names another origin than the one the form
  /// opened on. Blank is not another origin: it means follow the build.
  bool get _otherOrigin {
    final typed = _url.text.trim();
    if (typed.isEmpty) return false;
    return !sameOrigin(typed, widget.url);
  }

  /// The typed address is not the saved one, so Check, which asks the
  /// saved one, would answer about somewhere else. A blank field that was
  /// SAVED blank is the saved one: it follows the build, and [widget.url] is
  /// then the build's address.
  bool get _unsaved {
    final typed = normalizeBoxBaseUrl(_url.text);
    if (typed == normalizeBoxBaseUrl(widget.url)) return false;
    return !(typed.isEmpty && _lastSaved == '');
  }

  bool get _plainHttpElsewhere {
    final uri = Uri.tryParse(_url.text.trim());
    return uri != null &&
        uri.scheme == 'http' &&
        uri.host.isNotEmpty &&
        !isLoopbackHost(_url.text.trim());
  }

  void _edited() {
    setState(() {
      _seq++;
      _refusal = null;
      _tokenError = null;
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final onRemove = widget.onRemoveToken;
    final onCheck = widget.onCheck;
    final hint = _otherOrigin
        ? ModelRegistryForm.otherOriginHint
        : widget.tokenStored
            ? ModelRegistryForm.storedHint
            : (widget.tokenFromBuild ? ModelRegistryForm.buildTokenHint : null);
    final status = _result ?? widget.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s8),
          child: Text(
            ModelRegistryForm.title,
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        Text(ModelRegistryForm.caption, style: BondType.caption),
        const SizedBox(height: BondSpacing.s8),
        TextField(
          key: ModelRegistryForm.urlKey,
          controller: _url,
          // Held while a Save is out: what was sent is what lands, and the
          // token field is emptied after it whatever happened meanwhile.
          enabled: !_busy,
          onChanged: (_) => _edited(),
          decoration: const InputDecoration(
            labelText: ModelRegistryForm.urlLabel,
            hintText: ModelRegistryForm.urlHint,
          ),
        ),
        if (_refusal case final refusal?) ...[
          const SizedBox(height: BondSpacing.s8),
          InlineAlert(
            key: ModelRegistryForm.refusalKey,
            severity: InlineAlertSeverity.error,
            text: refusal,
          ),
        ],
        if (_plainHttpElsewhere) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(ModelRegistryForm.httpsHint, style: BondType.caption),
        ],
        const SizedBox(height: BondSpacing.s12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                key: ModelRegistryForm.tokenKey,
                controller: _token,
                enabled: !_busy,
                obscureText: true,
                onChanged: (_) => _edited(),
                decoration: InputDecoration(
                  labelText: ModelRegistryForm.tokenLabel,
                  hintText: hint,
                  errorText: _tokenError,
                ),
              ),
            ),
            if (widget.tokenStored && onRemove != null) ...[
              const SizedBox(width: BondSpacing.s8),
              TextButton(
                key: ModelRegistryForm.removeTokenKey,
                onPressed: _busy ? null : () => unawaited(_remove(onRemove)),
                child: const Text(ModelRegistryForm.removeTokenLabel),
              ),
            ],
          ],
        ),
        const SizedBox(height: BondSpacing.s16),
        Wrap(
          spacing: BondSpacing.s8,
          runSpacing: BondSpacing.s8,
          children: [
            FilledButton(
              key: ModelRegistryForm.saveKey,
              onPressed: _busy ? null : () => unawaited(_save()),
              child: const Text(ModelRegistryForm.saveLabel),
            ),
            if (onCheck != null)
              OutlinedButton(
                key: ModelRegistryForm.checkKey,
                onPressed: _busy || _unsaved
                    ? null
                    : () => unawaited(_check(onCheck)),
                child: const Text(ModelRegistryForm.checkLabel),
              ),
          ],
        ),
        if (onCheck != null && _unsaved) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(ModelRegistryForm.saveFirstText, style: BondType.caption),
        ],
        if (status != null) ...[
          const SizedBox(height: BondSpacing.s8),
          Text(
            key: ModelRegistryForm.statusKey,
            status,
            style: BondType.small,
          ),
        ],
      ],
    );
  }

  /// Refuse, then write. The one place the token field is emptied.
  Future<void> _save() async {
    final seq = ++_seq;
    final url = _url.text.trim();
    if (url.isNotEmpty && !isBoxOrigin(url)) {
      setState(() {
        _refusal = ModelRegistryForm.addressRefusalText;
        _result = null;
      });
      return;
    }
    final typed = _token.text.trim();
    // Refused before it goes anywhere, and the sentence never quotes it.
    if (typed.isNotEmpty && !isUsableAccessKey(typed)) {
      setState(() => _tokenError = accessKeyCharsText);
      return;
    }
    final token = typed.isEmpty ? null : typed;
    final clearToken = token == null && _otherOrigin;
    setState(() {
      _busy = true;
      _refusal = null;
      _result = null;
    });
    String? refusal;
    try {
      refusal = await widget.onSave(
        url: url,
        token: token,
        clearToken: clearToken,
      );
    } on Object {
      refusal = ModelServersForm.saveFailedText;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (refusal != null) {
        if (seq == _seq) _refusal = refusal;
        return;
      }
      // The token has reached the keychain; nothing here holds it now. The
      // fields were held during the Save, so this is what was sent.
      _token.clear();
      _lastSaved = normalizeBoxBaseUrl(url);
      if (seq == _seq) _result = ModelRegistryForm.savedText;
    });
  }

  Future<void> _remove(Future<void> Function() remove) async {
    final seq = ++_seq;
    setState(() => _busy = true);
    try {
      await remove();
    } on Object {
      // The hint follows the host's flag either way.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (seq == _seq) _result = null;
    });
  }

  Future<void> _check(Future<RegistryCheck> Function() check) async {
    final seq = ++_seq;
    setState(() {
      _busy = true;
      _result = null;
    });
    RegistryCheck answer;
    try {
      answer = await check();
    } on Object {
      answer = RegistryCheck.unreachable;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (seq == _seq) _result = ModelRegistryForm.checkText(answer);
    });
  }
}
