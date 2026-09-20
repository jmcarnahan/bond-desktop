import 'dart:async';

import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../services/llm/model_slots.dart' show LlmTargetSpec, LlmWire;
import '../theme/tokens.dart';
import 'chips.dart';
import 'inline_alert.dart';
import 'model_slot_editor.dart' show ProbeStatus;
import 'settings_models_body.dart' show SettingsModelsBody;

/// Every server a stage may be pointed at, and what is known about each one.
///
/// Prop-only, like the rest of the Models section: the host hands over the
/// resolved list and takes Add, Edit and Remove back as closures, so the whole
/// list is drivable from a widget test with no prefs, no keychain and no
/// network. The only network this widget can cause is [probe], which is
/// diagnostics.
///
/// The two built-ins are IN the list rather than above it, because "which
/// servers are there" is one question and answering it in two places would
/// make the picker's item list look invented. What they do not get is an Edit
/// or a Remove: they are derived from the four slot prefs and are edited by
/// the two [ModelSlotEditor]s further up the same section, which is what the
/// caption on their row says.
class SettingsTargetsBody extends StatefulWidget {
  /// Every target, built-ins first — `AppPrefs.allTargets`.
  final List<LlmTargetSpec> targets;

  /// Asks a server what it serves. Null takes **Check server** off every row,
  /// the same discipline the slot editors follow: a host that cannot ask does
  /// not offer to.
  final Future<ModelProbeResult> Function(String url, {String? bearer})? probe;

  /// Looks up the stored token for one target id, for the probe's
  /// `Authorization` header.
  ///
  /// A LOOKUP rather than the value: a secret must not sit in a widget field
  /// where a rebuild, a `toString` or a devtools inspection could reach it.
  /// The answer is read at the moment of the press, handed to [probe], and
  /// dropped again.
  final String? Function(String targetId)? storedBearer;

  /// Opens the editor pane on a new target. Null hides **Add target**.
  final VoidCallback? onAdd;

  /// Opens the editor pane on an existing user target. Null leaves the rows
  /// without an Edit; the built-ins never have one.
  final void Function(LlmTargetSpec spec)? onEdit;

  /// Forgets a user target. A future, because the row's buttons go inert until
  /// the write lands — a second press on a half-removed target would be a race
  /// over the same rows.
  final Future<void> Function(String id)? onRemove;

  const SettingsTargetsBody({
    super.key,
    required this.targets,
    this.probe,
    this.storedBearer,
    this.onAdd,
    this.onEdit,
    this.onRemove,
  });

  static Key rowKey(String id) => ValueKey('llm-target-row-$id');
  static Key checkKey(String id) => ValueKey('llm-target-check-$id');
  static Key editKey(String id) => ValueKey('llm-target-edit-$id');
  static Key removeKey(String id) => ValueKey('llm-target-remove-$id');
  static Key removeConfirmKey(String id) =>
      ValueKey('llm-target-remove-confirm-$id');
  static Key removeErrorKey(String id) =>
      ValueKey('llm-target-remove-error-$id');

  /// The one sentence a Remove that threw leaves under its row.
  static const String removeFailedText =
      'Could not remove this target. Check the settings store and try again.';
  static Key removeKeepKey(String id) => ValueKey('llm-target-remove-keep-$id');
  static const Key addKey = ValueKey('llm-target-add');

  /// `OpenAI` / `Converse` — the wire chip's word, short enough to sit beside
  /// a model name on one row.
  static String wireLabel(LlmWire wire) => switch (wire) {
        LlmWire.openAi => 'OpenAI',
        LlmWire.bedrockConverse => 'Converse',
      };

  @override
  State<SettingsTargetsBody> createState() => _SettingsTargetsBodyState();
}

class _SettingsTargetsBodyState extends State<SettingsTargetsBody> {
  /// The id whose check is out, and the answers so far. Per row rather than
  /// per section: two servers can be checked one after another and the first
  /// answer must not vanish when the second is asked for.
  String? _probingId;
  final Map<String, ModelProbeResult> _probes = {};

  /// The row whose Remove has been armed, and the one whose removal is in
  /// flight. Both are states the user put the row in, so neither is cleared by
  /// a rebuild.
  String? _confirmingId;
  String? _removingId;

  /// The row whose last Remove threw; cleared by the next Remove press.
  String? _removeErrorId;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final spec in widget.targets) _row(spec),
        if (widget.onAdd case final onAdd?) ...[
          const SizedBox(height: BondSpacing.s8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: SettingsTargetsBody.addKey,
              onPressed: onAdd,
              child: const Text('Add target'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _row(LlmTargetSpec spec) {
    final removing = _removingId == spec.id;
    return Padding(
      key: SettingsTargetsBody.rowKey(spec.id),
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            spec.name,
            style: BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: BondSpacing.s4),
          // A Wrap rather than a Row: a host, a model name and three chips do
          // not fit the pane at a doubled text scale, and wrapping is the right
          // failure.
          Wrap(
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(SettingsModelsBody.hostPort(spec.url), style: BondType.mono),
              Text(spec.model, style: BondType.small),
              BondChip.metric(SettingsTargetsBody.wireLabel(spec.wire)),
              // Presence, never the token. What is stored is a boolean here
              // and a keychain entry elsewhere, and this row is the only place
              // either is ever reported.
              BondChip.metric(spec.hasBearer ? 'Bearer set' : 'No bearer'),
              if (spec.parallel > 1) BondChip.metric('Parallel ${spec.parallel}'),
            ],
          ),
          const SizedBox(height: BondSpacing.s4),
          if (spec.isBuiltIn)
            Text('Edited above, under Fast and Prose', style: BondType.caption),
          OverflowBar(
            alignment: MainAxisAlignment.start,
            spacing: BondSpacing.s8,
            children: [
              if (widget.probe != null)
                OutlinedButton(
                  key: SettingsTargetsBody.checkKey(spec.id),
                  onPressed: _probingId != null || removing
                      ? null
                      : () => unawaited(_check(spec)),
                  child: const Text('Check server'),
                ),
              if (!spec.isBuiltIn) ..._rowActions(spec, removing: removing),
            ],
          ),
          ProbeStatus(probing: _probingId == spec.id, result: _probes[spec.id]),
          if (_removeErrorId == spec.id)
            InlineAlert(
              key: SettingsTargetsBody.removeErrorKey(spec.id),
              severity: InlineAlertSeverity.error,
              text: SettingsTargetsBody.removeFailedText,
            ),
        ],
      ),
    );
  }

  /// Edit and the two-step Remove, in the idiom the Processing section's clear
  /// blocks use: the first press arms, the second commits, and Keep stands the
  /// row back down.
  List<Widget> _rowActions(LlmTargetSpec spec, {required bool removing}) {
    final onEdit = widget.onEdit;
    final onRemove = widget.onRemove;
    return [
      if (onEdit != null)
        TextButton(
          key: SettingsTargetsBody.editKey(spec.id),
          onPressed: removing ? null : () => onEdit(spec),
          child: const Text('Edit'),
        ),
      if (onRemove != null)
        if (_confirmingId != spec.id)
          TextButton(
            key: SettingsTargetsBody.removeKey(spec.id),
            onPressed: removing
                ? null
                : () => setState(() => _confirmingId = spec.id),
            child: const Text('Remove'),
          )
        else ...[
          FilledButton(
            key: SettingsTargetsBody.removeConfirmKey(spec.id),
            style: FilledButton.styleFrom(
              backgroundColor: BondColors.error,
              foregroundColor: BondColors.surface,
            ),
            onPressed: removing ? null : () => unawaited(_remove(spec, onRemove)),
            child: const Text('Confirm remove'),
          ),
          TextButton(
            key: SettingsTargetsBody.removeKeepKey(spec.id),
            onPressed: removing ? null : () => setState(() => _confirmingId = null),
            child: const Text('Keep'),
          ),
        ],
    ];
  }

  Future<void> _remove(
    LlmTargetSpec spec,
    Future<void> Function(String id) onRemove,
  ) async {
    setState(() {
      _removingId = spec.id;
      _removeErrorId = null;
    });
    try {
      await onRemove(spec.id);
    } on Object {
      // The row stays, armed state dropped, with one sentence under it: the
      // Check server beside it already fails this way and a Remove that threw
      // into the zone showed nothing at all.
      if (mounted) setState(() => _removeErrorId = spec.id);
    } finally {
      // The row is usually gone by now — the host rebuilt the list without it
      // — so the guard is what keeps a settings screen from setting state on a
      // widget the same press disposed.
      if (mounted) {
        setState(() {
          _removingId = null;
          _confirmingId = null;
        });
      }
    }
  }

  /// Asks one target's server what it serves, on the slot editors' guarded
  /// shape: the probe's own contract is that it never throws, and a settings
  /// screen must not be able to crash on a diagnostics call anyway.
  Future<void> _check(LlmTargetSpec spec) async {
    final probe = widget.probe;
    if (probe == null) return;
    setState(() {
      _probingId = spec.id;
      _probes.remove(spec.id);
    });
    try {
      final result = await probe(
        spec.url,
        bearer: spec.hasBearer ? widget.storedBearer?.call(spec.id) : null,
      );
      if (!mounted) return;
      setState(() {
        _probingId = null;
        _probes[spec.id] = result;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _probingId = null;
        _probes[spec.id] = const ModelProbeResult(
          reachable: false,
          error: 'Could not check the server',
        );
      });
    }
  }
}
