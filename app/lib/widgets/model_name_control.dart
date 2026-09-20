import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../theme/tokens.dart';

/// The model name: a picker over what the server listed, or a free field when
/// nothing has listed anything.
///
/// ONE control for both editors. `ModelSlotEditor` and `LlmTargetEditor` ask
/// the same question about two different things — a build-in slot and a target
/// somebody added — and they used to answer it with two copies of the same
/// sixty lines whose only difference was which keys the field and the picker
/// carried. The keys are props here, which is the whole of what the two call
/// sites still have to say for themselves, and both editors' tests pass
/// untouched: every assertion in them is by key or by literal text, and every
/// string below is the string they were written against.
///
/// The picker is preferred wherever it can be built because a name the server
/// does not serve is the failure mode that costs the most — llama.cpp ignores
/// the field entirely and an MLX runtime answers HTTP 400, which is fatal and
/// never retried.
///
/// STATELESS, and deliberately: the controller belongs to the editor that owns
/// the form, the probe future stays in the editor that fired it, and this
/// widget holds neither. It reads the probe and it writes the controller, and
/// the rebuild is the caller's through [onPicked].
class ModelNameControl extends StatelessWidget {
  /// The field's text, owned by the editor. A pick writes into it rather than
  /// reporting a string, so the two ways of answering — typing and picking —
  /// end in the same place.
  final TextEditingController controller;

  /// What the last look at the server found, or null when nobody has looked.
  final ModelProbeResult? probe;

  /// The free-text field's key, and the picker's. Each editor's own, because
  /// a slot has four of these on one screen and a target editor has one.
  final Key fieldKey;
  final Key pickerKey;

  /// Fired after a pick has been written into [controller]. The editors pass
  /// their own `setState`: the controller's listener rebuilds them anyway, and
  /// this keeps the picker's behaviour exactly what it was.
  final VoidCallback? onPicked;

  const ModelNameControl({
    super.key,
    required this.controller,
    required this.probe,
    required this.fieldKey,
    required this.pickerKey,
    this.onPicked,
  });

  /// The ids to pick between, or null when there is no usable listing. A
  /// reachable server with an empty list is not a picker — it is a live server
  /// with nothing loaded, and the typed name is still the right answer.
  List<String>? get _listed =>
      probe?.reachable == true && probe!.modelIds.isNotEmpty
          ? probe!.modelIds
          : null;

  @override
  Widget build(BuildContext context) {
    // A Column of its own where the editors used to spread a list into theirs.
    // Both parents are `Column(crossAxisAlignment: stretch)`, which this
    // repeats, so the rows land exactly where they did.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: _children(),
    );
  }

  List<Widget> _children() {
    final listed = _listed;
    if (listed == null) {
      return [
        TextField(
          key: fieldKey,
          controller: controller,
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

    final typed = controller.text;
    final unlisted = typed.isNotEmpty && !listed.contains(typed);
    return [
      InputDecorator(
        decoration: const InputDecoration(labelText: 'Model'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: pickerKey,
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
              // The controller's own listener is what rebuilds the editor;
              // this is the whole of the change.
              controller.text = value;
              onPicked?.call();
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
