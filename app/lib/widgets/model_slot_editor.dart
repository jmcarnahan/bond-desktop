import 'dart:async';

import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart' show LlmTarget, ModelSlot;
import '../theme/tokens.dart';
import 'chips.dart';
import 'inline_alert.dart';

/// One model slot's server, its model name, and a way to find out what that
/// server is actually serving.
///
/// Prop-only, like everything else on the settings screen: it holds no
/// providers and knows nothing about prefs. The host resolves the effective
/// target, answers whether the slot is on the build's default, and takes the
/// two values back on Save. That is what lets a test drive the whole editor
/// with three closures and no database.
///
/// It edits, it never applies: a Save hands the host two strings and the host
/// decides what that means. Nothing here dials a model — the only network this
/// widget can cause is [probe], which is diagnostics.
class ModelSlotEditor extends StatefulWidget {
  final ModelSlot slot;

  /// 'Fast · bulk work' — the slot's name and what it is for, in one line.
  final String title;

  /// One sentence naming the stages that run here, so the choice below is
  /// made with the consequence in view.
  final String blurb;

  /// The EFFECTIVE target: the host has already resolved "follow the build"
  /// into the build's own values, so the fields always open on something real
  /// rather than on two empty boxes.
  final LlmTarget current;

  /// What this build was compiled with. Save compares against it — typing the
  /// default back must store "follow the build", never freeze today's
  /// dart-define into the database.
  final LlmTarget compiledDefault;

  /// The host's answer, not a local guess: it is read from the stored prefs
  /// after every write, so the chip below follows what was actually saved.
  final bool isDefault;

  /// Asks a server what it serves. Expected never to throw — see
  /// `ModelServerProbe` — but this widget guards the call anyway.
  ///
  /// Null renders no 'Check server' at all, and the model stays a free field:
  /// a host that cannot ask has nothing to offer, and a button whose only
  /// answer is "nothing is wired" would be a fault report dressed as a control.
  final Future<ModelProbeResult> Function(String url)? probe;

  /// Fired by Save and by nothing else. Both halves travel together: a URL
  /// with the previous model's name against it is an HTTP 400 on an MLX
  /// runtime, which is fatal and never retried.
  final void Function({required String url, required String model}) onSave;

  /// Fired by 'Use build defaults'. The host clears the slot; this editor puts
  /// the compiled default in its own fields without waiting for the rebuild.
  final VoidCallback onReset;

  const ModelSlotEditor({
    super.key,
    required this.slot,
    required this.title,
    required this.blurb,
    required this.current,
    required this.compiledDefault,
    required this.isDefault,
    this.probe,
    required this.onSave,
    required this.onReset,
  });

  // Two editors sit on one screen with identical button labels — 'Check
  // server', 'Save', 'Cancel', 'Use build defaults' all appear twice — so a
  // test that tapped by text would be tapping whichever came first. Every
  // control a test needs is keyed by slot instead.

  static Key urlFieldKey(ModelSlot slot) => ValueKey('model-slot-url-${slot.name}');
  static Key modelFieldKey(ModelSlot slot) =>
      ValueKey('model-slot-model-${slot.name}');
  static Key modelPickerKey(ModelSlot slot) =>
      ValueKey('model-slot-picker-${slot.name}');
  static Key checkKey(ModelSlot slot) => ValueKey('model-slot-check-${slot.name}');
  static Key saveKey(ModelSlot slot) => ValueKey('model-slot-save-${slot.name}');
  static Key cancelKey(ModelSlot slot) =>
      ValueKey('model-slot-cancel-${slot.name}');
  static Key resetKey(ModelSlot slot) => ValueKey('model-slot-reset-${slot.name}');

  /// 'Fast' / 'Prose' / 'Embeddings' — the word the stage table's chip and the
  /// collapsed summary both use, so the table and the editors below it never
  /// call the same slot two things.
  static String slotLabel(ModelSlot slot) => switch (slot) {
        ModelSlot.fast => 'Fast',
        ModelSlot.prose => 'Prose',
        ModelSlot.embed => 'Embeddings',
      };

  @override
  State<ModelSlotEditor> createState() => _ModelSlotEditorState();
}

class _ModelSlotEditorState extends State<ModelSlotEditor> {
  late final TextEditingController _url = TextEditingController(
    text: widget.current.baseUrl,
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.current.model,
  );

  /// The baseline "dirty" is measured against. Save replaces it, Cancel
  /// restores from it, and NOTHING writes it on dispose — the same contract
  /// the about-me field keeps one section up.
  late LlmTarget _saved = widget.current;

  /// True while a server check is out. The button is the only thing that can
  /// start one, so it is also the only thing that has to be disabled.
  bool _probing = false;

  /// The trimmed URL the last check was asked about. A listing belongs to the
  /// URL it was asked of, so editing the field away from this makes the
  /// listing stale and it is dropped.
  String? _probedInput;

  ModelProbeResult? _probe;

  /// A URL the probe refused before making any request — no `/v1/` to derive a
  /// listing endpoint from. That is a fault in the FIELD, not a report about a
  /// server, so it renders as the field's own `errorText` rather than as a
  /// status line claiming something is unreachable.
  String? _urlError;

  /// The ids to pick between, or null when there is no usable listing. A
  /// reachable server with an empty list is not a picker — it is a live server
  /// with nothing loaded, and the typed name is still the right answer.
  List<String>? get _listed =>
      _probe?.reachable == true && _probe!.modelIds.isNotEmpty
          ? _probe!.modelIds
          : null;

  bool get _dirty =>
      _url.text != _saved.baseUrl || _model.text != _saved.model;

  /// Neither half may be blank. An empty URL is a request to nowhere, and an
  /// empty model name is one an MLX runtime answers with a fatal 400.
  bool get _canSave =>
      _dirty && _url.text.trim().isNotEmpty && _model.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Save and Cancel are both enabled by what is in the fields, so the
    // buttons have to hear every keystroke.
    _url.addListener(_onUrlChanged);
    _model.addListener(_onModelChanged);
  }

  void _onModelChanged() => setState(() {});

  void _onUrlChanged() {
    final input = _url.text.trim();
    setState(() {
      if (_probedInput != null && input != _probedInput) {
        _probe = null;
        _probedInput = null;
      }
      // The refusal was about the text that has just changed.
      _urlError = null;
    });
  }

  @override
  void didUpdateWidget(ModelSlotEditor old) {
    super.didUpdateWidget(old);
    // How a host rebuild reaches the fields: a Save the host has now written,
    // a reset from somewhere else, or an identity wipe underneath the pane. A
    // DIRTY editor keeps the user's edit — an unsaved change is theirs and is
    // never overwritten by a value arriving from outside.
    if (old.current != widget.current &&
        _url.text == _saved.baseUrl &&
        _model.text == _saved.model) {
      _saved = widget.current;
      _url.text = widget.current.baseUrl;
      _model.text = widget.current.model;
    }
  }

  @override
  void dispose() {
    // Nothing is saved here, deliberately: Save is the only commit, so
    // leaving means leaving.
    _url.removeListener(_onUrlChanged);
    _model.removeListener(_onModelChanged);
    _url.dispose();
    _model.dispose();
    super.dispose();
  }

  /// Asks the server in the FIELD — not the saved one — what it serves.
  ///
  /// The probe's own contract is that it never throws, and this catches
  /// anyway: a settings screen must not be able to crash on a diagnostics
  /// call, and the alternative to a caught error here is an unhandled async
  /// error from a button press nobody is awaiting.
  Future<void> _check() async {
    final probe = widget.probe;
    if (probe == null) return;
    final input = _url.text.trim();
    setState(() {
      _probing = true;
      _urlError = null;
      _probe = null;
      _probedInput = input;
    });
    try {
      final result = await probe(input);
      if (!mounted) return;
      // The field moved on while the answer was out — [_onUrlChanged] cleared
      // [_probedInput] — so this is a report about a server the user is no
      // longer pointing at. Showing it would put the old server's listing
      // under the new server's URL, and a name picked from it would be one
      // the new server may not serve.
      if (_probedInput != input) {
        setState(() => _probing = false);
        return;
      }
      setState(() {
        _probing = false;
        if (!result.reachable && result.probedUrl == null) {
          // No request was made — the URL itself is the problem.
          _urlError = result.error;
          _probe = null;
        } else {
          _probe = result;
        }
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

  void _save() {
    final url = _url.text.trim();
    final model = _model.text.trim();
    // Empty means "follow the build" and is stored as empty: a slot the user
    // has typed the compiled default back into must keep following the
    // dart-define, not freeze today's value into the database.
    widget.onSave(
      url: url == widget.compiledDefault.baseUrl ? '' : url,
      model: model == widget.compiledDefault.model ? '' : model,
    );
    setState(() {
      _saved = LlmTarget(baseUrl: url, model: model);
      // The fields hold what was saved, whitespace and all removed, so a
      // saved editor is genuinely clean rather than dirty by two spaces.
      _url.text = url;
      _model.text = model;
    });
  }

  void _cancel() {
    setState(() {
      _url.text = _saved.baseUrl;
      _model.text = _saved.model;
    });
  }

  void _reset() {
    widget.onReset();
    setState(() {
      _saved = widget.compiledDefault;
      _url.text = widget.compiledDefault.baseUrl;
      _model.text = widget.compiledDefault.model;
      // A listing belongs to the URL it was asked of, and the URL has just
      // been replaced.
      _probe = null;
      _probedInput = null;
      _urlError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                style: BondType.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: BondSpacing.s8),
            BondChip.semantic(
              widget.isDefault ? 'Default' : 'Custom',
              widget.isDefault ? BondTone.neutral : BondTone.primary,
            ),
          ],
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(widget.blurb, style: BondType.caption),
        const SizedBox(height: BondSpacing.s12),
        TextField(
          key: ModelSlotEditor.urlFieldKey(widget.slot),
          controller: _url,
          decoration: InputDecoration(
            labelText: 'Server URL',
            hintText: 'http://host:port/v1/chat/completions',
            errorText: _urlError,
          ),
        ),
        const SizedBox(height: BondSpacing.s8),
        if (widget.probe != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: ModelSlotEditor.checkKey(widget.slot),
              onPressed: _probing ? null : () => unawaited(_check()),
              child: const Text('Check server'),
            ),
          ),
          ProbeStatus(probing: _probing, result: _probe),
          const SizedBox(height: BondSpacing.s8),
        ],
        ..._modelControl(),
        const SizedBox(height: BondSpacing.s8),
        // An OverflowBar rather than a Row: three buttons with words on them
        // do not fit the pane at a doubled text scale, and wrapping is the
        // right failure.
        OverflowBar(
          alignment: MainAxisAlignment.end,
          spacing: BondSpacing.s8,
          children: [
            TextButton(
              key: ModelSlotEditor.resetKey(widget.slot),
              onPressed: widget.isDefault ? null : _reset,
              child: const Text('Use build defaults'),
            ),
            TextButton(
              key: ModelSlotEditor.cancelKey(widget.slot),
              onPressed: _dirty ? _cancel : null,
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: ModelSlotEditor.saveKey(widget.slot),
              onPressed: _canSave ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }

  /// The model name: a picker over what the server listed, or a free field
  /// when nothing has listed anything.
  ///
  /// The picker is preferred wherever it can be built because a name the
  /// server does not serve is the failure mode that costs the most — llama.cpp
  /// ignores the field entirely and an MLX runtime answers HTTP 400, which is
  /// fatal and never retried.
  List<Widget> _modelControl() {
    final listed = _listed;
    if (listed == null) {
      return [
        TextField(
          key: ModelSlotEditor.modelFieldKey(widget.slot),
          controller: _model,
          decoration: const InputDecoration(
            labelText: 'Model name',
            hintText: 'qwen3.8',
          ),
        ),
        const SizedBox(height: BondSpacing.s4),
        Text(
          'Check the server to pick from what it serves; llama.cpp ignores '
          'this name, MLX runtimes require it.',
          style: BondType.caption,
        ),
      ];
    }

    final typed = _model.text;
    final unlisted = typed.isNotEmpty && !listed.contains(typed);
    return [
      InputDecorator(
        decoration: const InputDecoration(labelText: 'Model'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: ModelSlotEditor.modelPickerKey(widget.slot),
            isExpanded: true,
            value: typed.isEmpty ? null : typed,
            hint: const Text('Pick a model'),
            items: [
              for (final id in listed)
                DropdownMenuItem(value: id, child: Text(id)),
              // The name already in the field stays selectable even when this
              // server does not offer it — dropping it would silently change
              // which model the app asks for.
              if (unlisted)
                DropdownMenuItem(
                  value: typed,
                  child: Text('$typed (not listed)'),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              // The controller's own listener is what rebuilds; this is the
              // whole of the change.
              setState(() => _model.text = value);
            },
          ),
        ),
      ),
      if (unlisted) ...[
        const SizedBox(height: BondSpacing.s4),
        Text(
          'This server did not list that name. llama.cpp will ignore it; an '
          'MLX runtime will refuse the request.',
          style: BondType.caption,
        ),
      ],
    ];
  }
}

/// What the last look at a server found, in one line.
///
/// Three outcomes render apart because they mean three different things to
/// somebody deciding what to type next: a live server with models, a live
/// server with nothing loaded, and a server that did not answer. The fourth —
/// a URL the probe refused before asking anything — never reaches here; it
/// belongs beside the field that holds it.
class ProbeStatus extends StatelessWidget {
  final bool probing;
  final ModelProbeResult? result;

  const ProbeStatus({super.key, required this.probing, required this.result});

  @override
  Widget build(BuildContext context) {
    if (probing) return Text('Checking…', style: BondType.small);
    final result = this.result;
    if (result == null) return const SizedBox.shrink();

    final Widget line;
    if (!result.reachable) {
      line = InlineAlert(
        severity: InlineAlertSeverity.error,
        text: result.error ?? 'Not reachable',
      );
    } else if (result.modelIds.isEmpty) {
      line = Text('Reachable · nothing loaded yet', style: BondType.small);
    } else {
      final n = result.modelIds.length;
      line = Text(
        n == 1 ? 'Reachable · 1 model' : 'Reachable · $n models',
        style: BondType.small,
      );
    }

    final probedUrl = result.probedUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line,
        // Where it actually looked. "Not reachable" against a server that is
        // demonstrably up is almost always a surprise about the derived
        // listing URL, and this is the line that resolves it in one glance.
        if (probedUrl != null)
          Text('Asked $probedUrl', style: BondType.caption),
      ],
    );
  }
}
