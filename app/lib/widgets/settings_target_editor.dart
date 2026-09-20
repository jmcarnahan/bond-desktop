import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart' show LlmTargetSpec, LlmWire;
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'model_name_control.dart';
import 'model_slot_editor.dart' show ProbeStatus;
import 'settings_models_body.dart' show SettingsModelsBody;
import 'settings_segments.dart';

/// One target being added or edited: where it is, what it serves, how it is
/// spoken to, and who else this machine may point at it.
///
/// The BODY of a pane, not the pane: `SettingsScreen` wraps it in the
/// [PaneSurface] with the title and the back arrow, because the screen is what
/// owns which sub-pane is open. Prop-only for the same reason everything else
/// on that screen is: the host writes, this edits, and a test drives the whole
/// editor with two closures.
///
/// It edits, it never applies. Save hands the host a spec and a bearer and the
/// host decides what that means; the only network this widget can cause is
/// [probe], which is diagnostics.
class LlmTargetEditor extends StatefulWidget {
  /// The target being edited, or null to add a new one. The three presets are
  /// meaningful on ADD only — on an edit they are absent and are passed false.
  final LlmTargetSpec? initial;

  /// Asks a server what it serves. Null takes **Check server** off the pane and
  /// leaves the model a typed name, the slot editors' discipline.
  final Future<ModelProbeResult> Function(String url)? probe;

  /// Save. [bearer] is the typed token or null: null with `spec.hasBearer`
  /// true keeps the stored one, null with `hasBearer` false clears it. That
  /// three-way is why the field is empty on an edit rather than pre-filled — a
  /// secret is never read back onto a screen, so "unchanged" has to be a state
  /// the field can be in.
  final Future<void> Function(
    LlmTargetSpec spec, {
    String? bearer,
    bool prose,
    bool confirm,
    bool bulk,
  }) onSave;

  final VoidCallback onCancel;

  const LlmTargetEditor({
    super.key,
    this.initial,
    this.probe,
    required this.onSave,
    required this.onCancel,
  });

  static const Key nameKey = ValueKey('llm-target-name');
  static const Key urlKey = ValueKey('llm-target-url');
  static const Key modelKey = ValueKey('llm-target-model');
  static const Key modelPickerKey = ValueKey('llm-target-model-picker');
  static const Key wireKey = ValueKey('llm-target-wire');
  static const Key bearerKey = ValueKey('llm-target-bearer');
  static const Key bearerClearKey = ValueKey('llm-target-bearer-clear');
  static const Key parallelKey = ValueKey('llm-target-parallel');
  static const Key streamsKey = ValueKey('llm-target-streams');
  static const Key checkKey = ValueKey('llm-target-check');
  static const Key saveKey = ValueKey('llm-target-save');
  static const Key saveErrorKey = ValueKey('llm-target-save-error');

  /// The one sentence a Save that threw leaves under the buttons.
  static const String saveFailedText =
      'Could not save this target. Check the settings store and try again.';
  static const Key cancelKey = ValueKey('llm-target-cancel');
  static const Key presetProseKey = ValueKey('llm-target-preset-prose');
  static const Key presetConfirmKey = ValueKey('llm-target-preset-confirm');
  static const Key presetBulkKey = ValueKey('llm-target-preset-bulk');

  /// A fresh target's id: `t-` and eight hex characters.
  ///
  /// NEVER derived from the name. The stage map and the keychain entry are
  /// keyed on this string, so two targets a person happened to call the same
  /// thing would otherwise share a token and overwrite each other's routing.
  /// The clock is the fallback for a platform with no secure random; collision
  /// resistance is not the point here, distinctness within one list is.
  static String newId() {
    // One generator for the eight nibbles. `Random.secure()` opens a platform
    // source each time it is constructed, and the constructor is also where
    // the unsupported-platform throw comes from, so building it once is both
    // the cheaper and the clearer shape.
    Random? random;
    try {
      random = Random.secure();
    } on UnsupportedError {
      random = null;
    }

    final buffer = StringBuffer('t-');
    final now = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < 8; i++) {
      final nibble = random?.nextInt(16) ?? ((now >> (i * 4)) & 0xf);
      buffer.write(nibble.toRadixString(16));
    }
    return buffer.toString();
  }

  @override
  State<LlmTargetEditor> createState() => _LlmTargetEditorState();
}

class _LlmTargetEditorState extends State<LlmTargetEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _url =
      TextEditingController(text: widget.initial?.url ?? '');
  late final TextEditingController _model =
      TextEditingController(text: widget.initial?.model ?? '');

  /// Always empty on arrival, even when a token is stored. A secret that has
  /// reached the keychain is never read back onto a screen; the hint is what
  /// says one is there.
  final TextEditingController _bearer = TextEditingController();

  late LlmWire _wire = widget.initial?.wire ?? LlmWire.openAi;
  /// What the segments SHOW. A stored 3 snaps to 2 to be drawn, so this is a
  /// display value and never what a Save writes on its own — see
  /// [_widthTouched].
  late int _parallel =
      SettingsModelsBody.knownWidth(widget.initial?.parallel ?? 1);

  /// Whether anybody actually pressed a width segment.
  ///
  /// Without this a target stored at 3 would be silently rewritten to 2 by a
  /// Save that only changed its name: the control cannot draw a 3, and the
  /// snapped value is a drawing decision rather than the owner's. Untouched
  /// means Save writes the number that was already there.
  bool _widthTouched = false;
  late bool _streams = widget.initial?.streams ?? true;

  /// Whether the stored token survives this Save. True on arrival for a target
  /// that has one; **Remove bearer** is the only thing that clears it, and
  /// typing a new one puts it back.
  late bool _keepBearer = widget.initial?.hasBearer ?? false;

  /// Pre-checked for EVERY new target, and the user unticks. The GPU box
  /// arrives over an ssh tunnel on loopback, so "not localhost" would miss the
  /// one machine these presets exist for; guessing wrong in the direction of
  /// an unticked box costs a person nothing but a tick.
  bool _presetProse = true;
  bool _presetConfirm = true;

  /// Not pre-checked: the bulk stages run on the small model by design, and
  /// moving eight stages onto a paid target is not a default anybody should
  /// arrive at by pressing Save.
  bool _presetBulk = false;

  bool _probing = false;
  ModelProbeResult? _probe;
  String? _probedInput;

  /// True while a Save is out. Both buttons go inert: the write reaches the
  /// keychain and the database, and a second press would be a race over the
  /// same rows.
  bool _saving = false;

  /// The last Save that threw, as one sentence under the buttons; cleared by
  /// the next press. Every other writing control on this screen shows its
  /// failure inline, and a Save that vanished into the zone showed nothing.
  String? _saveError;


  bool get _isAdd => widget.initial == null;

  @override
  void initState() {
    super.initState();
    _name.addListener(_onTextChanged);
    _model.addListener(_onTextChanged);
    _url.addListener(_onUrlChanged);
    _bearer.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _name.removeListener(_onTextChanged);
    _model.removeListener(_onTextChanged);
    _url.removeListener(_onUrlChanged);
    _bearer.removeListener(_onTextChanged);
    _name.dispose();
    _url.dispose();
    _model.dispose();
    _bearer.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  void _onUrlChanged() {
    final input = _url.text.trim();
    // The rebuild is UNCONDITIONAL on purpose, and it is not only about the
    // listing. [_blocker] reads this field, so Save's enabled state and the
    // sentence under it both follow every keystroke here exactly as they
    // follow one in the name and model fields. Returning early when no probe
    // result is being dropped leaves Save disabled after a URL is typed, and
    // `settings_target_editor_test.dart` fails on precisely that.
    setState(() {
      // A listing belongs to the URL it was asked of.
      if (_probedInput != null && input != _probedInput) {
        _probe = null;
        _probedInput = null;
      }
    });
  }

  /// Why Save is off, or null when it is on.
  ///
  /// A sentence rather than a red field: three things have to be true at once
  /// and a person who has filled in two of them is owed the third by name.
  String? get _blocker {
    if (_name.text.trim().isEmpty ||
        _url.text.trim().isEmpty ||
        _model.text.trim().isEmpty) {
      return 'A name, a server URL and a model name are all needed before '
          'this can be saved.';
    }
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || uri.host.isEmpty) {
      return 'The server URL needs a host, such as '
          'http://localhost:18100/v1/chat/completions';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _blocker;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: LlmTargetEditor.nameKey,
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'GPU box',
            ),
          ),
          const SizedBox(height: BondSpacing.s12),
          TextField(
            key: LlmTargetEditor.urlKey,
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://localhost:18100/v1/chat/completions',
            ),
          ),
          const SizedBox(height: BondSpacing.s8),
          if (widget.probe != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: LlmTargetEditor.checkKey,
                onPressed: _probing ? null : () => unawaited(_check()),
                child: const Text('Check server'),
              ),
            ),
            ProbeStatus(probing: _probing, result: _probe),
            const SizedBox(height: BondSpacing.s8),
          ],
          _modelControl(),
          const SizedBox(height: BondSpacing.s16),
          Text(
            'Wire',
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: BondSpacing.s8),
          SettingsSegments<LlmWire>(
            key: LlmTargetEditor.wireKey,
            segments: const [
              (value: LlmWire.openAi, label: 'OpenAI'),
              (value: LlmWire.bedrockConverse, label: 'Bedrock Converse'),
            ],
            selected: _wire,
            onChanged: (value) => setState(() => _wire = value),
            caption: 'Bedrock Converse is the shape AWS serves Anthropic '
                'models on. Everything else this app talks to is OpenAI.',
          ),
          const SizedBox(height: BondSpacing.s16),
          ..._bearerControl(),
          const SizedBox(height: BondSpacing.s16),
          Text(
            'Requests in flight',
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: BondSpacing.s8),
          SettingsSegments<int>(
            key: LlmTargetEditor.parallelKey,
            segments: const [
              (value: 1, label: '1'),
              (value: 2, label: '2'),
              (value: 4, label: '4'),
              (value: 8, label: '8'),
            ],
            selected: _parallel,
            onChanged: (value) => setState(() {
              _parallel = value;
              _widthTouched = true;
            }),
            caption: 'One per slot the server was started with. Extra '
                'requests queue at the server rather than fail.',
          ),
          const SizedBox(height: BondSpacing.s12),
          SwitchListTile(
            key: LlmTargetEditor.streamsKey,
            contentPadding: EdgeInsets.zero,
            value: _streams,
            onChanged: (value) => setState(() => _streams = value),
            title: const Text('Stream drafts word by word'),
            subtitle: Text(
              'Off for a server that cannot stream, such as Bedrock Converse',
              style: BondType.caption,
            ),
          ),
          if (_isAdd) ..._presets(),
          const SizedBox(height: BondSpacing.s16),
          if (blocker != null) ...[
            Text(blocker, style: BondType.caption),
            const SizedBox(height: BondSpacing.s8),
          ],
          if (_saveError != null) ...[
            InlineAlert(
              key: LlmTargetEditor.saveErrorKey,
              severity: InlineAlertSeverity.error,
              text: _saveError!,
            ),
            const SizedBox(height: BondSpacing.s8),
          ],
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: BondSpacing.s8,
            children: [
              TextButton(
                key: LlmTargetEditor.cancelKey,
                onPressed: _saving ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: LlmTargetEditor.saveKey,
                onPressed: blocker != null || _saving
                    ? null
                    : () => unawaited(_save()),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The model name: [ModelNameControl], with this editor's two keys — the
  /// slot editor's control, and for its reason. A name the server does not
  /// serve is a fatal HTTP 400 on an MLX runtime and is never retried.
  Widget _modelControl() => ModelNameControl(
        controller: _model,
        probe: _probe,
        fieldKey: LlmTargetEditor.modelKey,
        pickerKey: LlmTargetEditor.modelPickerKey,
        onPicked: () => setState(() {}),
      );

  /// The token field, obscured, plus the one control that can take a stored
  /// token away.
  List<Widget> _bearerControl() {
    final stored = _keepBearer && _bearer.text.isEmpty;
    return [
      TextField(
        key: LlmTargetEditor.bearerKey,
        controller: _bearer,
        obscureText: true,
        decoration: InputDecoration(
          labelText: 'Bearer token',
          hintText: stored ? 'Stored. Type to replace' : 'Leave empty for none',
        ),
      ),
      if (stored)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: LlmTargetEditor.bearerClearKey,
            onPressed: () => setState(() => _keepBearer = false),
            child: const Text('Remove bearer'),
          ),
        ),
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Kept in the keychain, never in the database, and sent as the '
        'Authorization header and nowhere else.',
        style: BondType.caption,
      ),
    ];
  }

  /// The three presets, on ADD only.
  ///
  /// Absent on an edit rather than disabled: re-pointing whole groups of
  /// stages is not what somebody opening a target to fix its port came for,
  /// and a checkbox that showed the CURRENT grouping would have to be a fourth
  /// state, since a preset is a write rather than a property of the target.
  List<Widget> _presets() {
    return [
      const SizedBox(height: BondSpacing.s16),
      Text(
        'Use this target for',
        style: BondType.small.copyWith(fontWeight: FontWeight.w600),
      ),
      CheckboxListTile(
        key: LlmTargetEditor.presetProseKey,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _presetProse,
        onChanged: (value) => setState(() => _presetProse = value ?? false),
        title: const Text('Prose stages'),
        subtitle: Text(
          'Storyline naming, refresh, recap and grouping, the reply decision '
          'and drafts',
          style: BondType.caption,
        ),
      ),
      CheckboxListTile(
        key: LlmTargetEditor.presetConfirmKey,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _presetConfirm,
        onChanged: (value) => setState(() => _presetConfirm = value ?? false),
        title: const Text('Storyline confirm'),
      ),
      CheckboxListTile(
        key: LlmTargetEditor.presetBulkKey,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _presetBulk,
        onChanged: (value) => setState(() => _presetBulk = value ?? false),
        title: const Text('All bulk stages'),
        subtitle: Text(
          'Triage, needs you, extraction, digests, the brief and the section '
          'pick',
          style: BondType.caption,
        ),
      ),
    ];
  }

  Future<void> _check() async {
    final probe = widget.probe;
    if (probe == null) return;
    final input = _url.text.trim();
    setState(() {
      _probing = true;
      _probe = null;
      _probedInput = input;
    });
    try {
      final result = await probe(input);
      if (!mounted) return;
      // The field moved on while the answer was out, so this is a report about
      // a server the user is no longer pointing at.
      if (_probedInput != input) {
        setState(() => _probing = false);
        return;
      }
      setState(() {
        _probing = false;
        _probe = result;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _probing = false;
        _probe = const ModelProbeResult(
          reachable: false,
          error: 'Could not check the server',
        );
      });
    }
  }

  Future<void> _save() async {
    final typed = _bearer.text.trim();
    final spec = LlmTargetSpec(
      // Kept on an edit: the stage map and the keychain entry are keyed on it.
      id: widget.initial?.id ?? LlmTargetEditor.newId(),
      name: _name.text.trim(),
      url: _url.text.trim(),
      model: _model.text.trim(),
      wire: _wire,
      hasBearer: typed.isNotEmpty || _keepBearer,
      parallel: _widthTouched
          ? _parallel
          : widget.initial?.parallel ?? _parallel,
      streams: _streams,
    );
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.onSave(
        spec,
        bearer: typed.isEmpty ? null : typed,
        prose: _isAdd && _presetProse,
        confirm: _isAdd && _presetConfirm,
        bulk: _isAdd && _presetBulk,
      );
    } on Object {
      // The pane stays open with the typed values intact and one sentence
      // under the buttons; nothing about the failure is worth more words.
      if (mounted) {
        setState(() => _saveError = LlmTargetEditor.saveFailedText);
      }
    } finally {
      // The pane is usually closed by now — the host closes it on a Save —
      // which is exactly why the guard is here.
      if (mounted) setState(() => _saving = false);
    }
  }
}
