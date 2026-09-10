import 'dart:async';

import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart'
    show LlmTarget, ModelSlot, PipelineStageInfo, slotDefaults;
import '../theme/tokens.dart';
import 'chips.dart';
import 'model_slot_editor.dart';

/// The Models section's body: which model each step of the pipeline uses, and
/// the two slots the user is allowed to move.
///
/// Its own file rather than another private method on the settings screen,
/// which is already thirteen hundred lines. Nothing here reaches for a
/// provider — the host resolves every target and takes the writes back, so
/// this whole section is drivable from a test with three closures.
class SettingsModelsBody extends StatefulWidget {
  /// The EFFECTIVE target per slot, defaults already resolved by the host.
  final Map<ModelSlot, LlmTarget> targets;

  /// Whether each slot is still on the build's own values. The host's answer,
  /// read back from the stored prefs, never a guess made here.
  final Map<ModelSlot, bool> isDefault;

  /// What this build was compiled with, per slot. Save normalises against it —
  /// see [ModelSlotEditor].
  final Map<ModelSlot, LlmTarget> compiledDefaults;

  /// The stage → slot table, as authored in `model_slots.dart`.
  final List<PipelineStageInfo> stages;

  /// Null takes every 'Check server' off the section — the editors' and the
  /// embeddings card's alike. See [ModelSlotEditor.probe].
  final Future<ModelProbeResult> Function(String url)? probe;
  final void Function(ModelSlot slot, {required String url, required String model})
      onSave;
  final void Function(ModelSlot slot) onReset;

  /// Rendered ABOVE the stage table, before anything else in the section — the
  /// Local server card, when the host has one to give. Injected rather than
  /// built here so this file keeps knowing nothing about a supervisor: the
  /// section is about where model calls go, and what is running is the host's
  /// answer to hand over.
  final Widget? header;

  const SettingsModelsBody({
    super.key,
    this.header,
    required this.targets,
    required this.isDefault,
    required this.compiledDefaults,
    required this.stages,
    this.probe,
    required this.onSave,
    required this.onReset,
  });

  /// The collapsed summary — where the three slots point, in one line.
  ///
  /// Static so the screen can build it without this widget existing: a
  /// collapsed section renders its summary and nothing else, and a summary
  /// that needed the body would defeat the whole shape.
  /// [server] is the local server's own one-liner, prefixed when there is one.
  /// Null leaves the summary byte-identical to what it has always said, which
  /// is what a host that wires no server card gets.
  static String summary(Map<ModelSlot, LlmTarget> targets, {String? server}) {
    final fast = _resolve(targets, ModelSlot.fast);
    final prose = _resolve(targets, ModelSlot.prose);
    final embed = _resolve(targets, ModelSlot.embed);
    final slots = 'Fast ${fast.model} @ ${hostPort(fast.baseUrl)} · '
        'Prose ${prose.model} @ ${hostPort(prose.baseUrl)} · '
        'Embeddings ${hostPort(embed.baseUrl)}';
    return server == null ? slots : '$server · $slots';
  }

  /// `localhost:8082` out of a full completions URL — the part a person reads
  /// to tell two servers apart, without the `/v1/chat/completions` every one
  /// of them ends in.
  ///
  /// A URL that does not parse is returned WHOLE. Something typed into the
  /// field is still the answer to "where does this point", and hiding it
  /// behind a blank would leave the summary lying about a slot that is
  /// genuinely misconfigured.
  static String hostPort(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  /// The compiled default is the last resort, not an empty target: a host that
  /// passed an incomplete map still gets a summary that names a real server.
  static LlmTarget _resolve(Map<ModelSlot, LlmTarget> targets, ModelSlot slot) =>
      targets[slot] ?? slotDefaults[slot]!;

  @override
  State<SettingsModelsBody> createState() => _SettingsModelsBodyState();
}

class _SettingsModelsBodyState extends State<SettingsModelsBody> {
  /// The embeddings card runs its own check, because it is the one slot with
  /// no editor to hold that state for it.
  bool _embedProbing = false;
  ModelProbeResult? _embedProbe;

  LlmTarget _target(ModelSlot slot) =>
      widget.targets[slot] ??
      widget.compiledDefaults[slot] ??
      slotDefaults[slot]!;

  LlmTarget _compiled(ModelSlot slot) =>
      widget.compiledDefaults[slot] ?? slotDefaults[slot]!;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.header != null) ...[
          widget.header!,
          const SizedBox(height: BondSpacing.s24),
          const Divider(height: 1),
          const SizedBox(height: BondSpacing.s24),
        ],
        Text(
          'Which model each step uses',
          style: BondType.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: BondSpacing.s4),
        for (final stage in widget.stages) _stageRow(stage),
        const SizedBox(height: BondSpacing.s24),
        ModelSlotEditor(
          key: const ValueKey('model-slot-editor-fast'),
          slot: ModelSlot.fast,
          title: 'Fast · bulk work',
          blurb: 'Triage, extraction, the Needs You verdict and storyline '
              'membership. A small, quick model.',
          current: _target(ModelSlot.fast),
          compiledDefault: _compiled(ModelSlot.fast),
          isDefault: widget.isDefault[ModelSlot.fast] ?? true,
          probe: widget.probe,
          onSave: ({required url, required model}) =>
              widget.onSave(ModelSlot.fast, url: url, model: model),
          onReset: () => widget.onReset(ModelSlot.fast),
        ),
        const SizedBox(height: BondSpacing.s16),
        ModelSlotEditor(
          key: const ValueKey('model-slot-editor-prose'),
          slot: ModelSlot.prose,
          title: 'Prose · reads and writes',
          blurb: 'Storyline titles, recaps, the reply decision and drafts. '
              'The big model.',
          current: _target(ModelSlot.prose),
          compiledDefault: _compiled(ModelSlot.prose),
          isDefault: widget.isDefault[ModelSlot.prose] ?? true,
          probe: widget.probe,
          onSave: ({required url, required model}) =>
              widget.onSave(ModelSlot.prose, url: url, model: model),
          onReset: () => widget.onReset(ModelSlot.prose),
        ),
        const SizedBox(height: BondSpacing.s8),
        Text(
          'Pointing both slots at one server makes them share its cache and '
          'its queue — slower than two servers, never broken.',
          style: BondType.caption,
        ),
        const SizedBox(height: BondSpacing.s24),
        ..._embeddingsCard(),
      ],
    );
  }

  /// One authored row: what the stage is, what it does, and which slot answers
  /// it.
  ///
  /// The table is AUTHORED — see `pipelineStages`. The stage → slot mapping is
  /// decided when the providers are built and there is no runtime router to
  /// interrogate, so this is the app telling the user what its own wiring is,
  /// kept honest by `model_slots_test.dart`.
  Widget _stageRow(PipelineStageInfo stage) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stage.label,
                  style: BondType.small.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(stage.description, style: BondType.caption),
              ],
            ),
          ),
          const SizedBox(width: BondSpacing.s12),
          Expanded(
            flex: 2,
            // A Wrap rather than a Row: the chip and a long model name do not
            // fit two fifths of the pane at a doubled text scale, and wrapping
            // is the right failure.
            child: Wrap(
              spacing: BondSpacing.s8,
              runSpacing: BondSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                BondChip.metric(ModelSlotEditor.slotLabel(stage.slot)),
                Text(_target(stage.slot).model, style: BondType.small),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The embeddings slot: where it points and whether it answers, and nothing
  /// else.
  ///
  /// Read-only on purpose, and the note says why in the place somebody would
  /// go looking for the missing control.
  List<Widget> _embeddingsCard() {
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              'Embeddings',
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          // Read from the same map as the editors' chips, not hard-coded:
          // the slot is not switchable today, and the chip must say what the
          // host says rather than what this file assumes.
          BondChip.semantic(
            (widget.isDefault[ModelSlot.embed] ?? true) ? 'Default' : 'Custom',
            (widget.isDefault[ModelSlot.embed] ?? true)
                ? BondTone.neutral
                : BondTone.primary,
          ),
        ],
      ),
      const SizedBox(height: BondSpacing.s4),
      Text(_target(ModelSlot.embed).baseUrl, style: BondType.mono),
      if (widget.probe != null) ...[
        const SizedBox(height: BondSpacing.s8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: ModelSlotEditor.checkKey(ModelSlot.embed),
            onPressed: _embedProbing ? null : () => unawaited(_checkEmbed()),
            child: const Text('Check server'),
          ),
        ),
        // A URL this one refuses renders here as an error alert rather than
        // beside a field, because there is no field: nothing on this card is
        // editable, so there is nowhere else for the message to go.
        ProbeStatus(probing: _embedProbing, result: _embedProbe),
      ],
      const SizedBox(height: BondSpacing.s4),
      Text(
        'Not switchable: every stored vector is tagged with this model, so '
        'changing it means re-embedding everything. Set EMBED_URL at build '
        'time.',
        style: BondType.caption,
      ),
    ];
  }

  /// Same mounted-guarded shape the editors use: the pane can be left while a
  /// check is out, and a settings screen must not crash on diagnostics.
  Future<void> _checkEmbed() async {
    final probe = widget.probe;
    if (probe == null) return;
    setState(() {
      _embedProbing = true;
      _embedProbe = null;
    });
    try {
      final result = await probe(_target(ModelSlot.embed).baseUrl);
      if (!mounted) return;
      setState(() {
        _embedProbing = false;
        _embedProbe = result;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _embedProbing = false;
        _embedProbe = const ModelProbeResult(
          reachable: false,
          error: 'Could not check the server',
        );
      });
    }
  }
}
