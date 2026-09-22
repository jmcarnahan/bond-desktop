import 'package:flutter/material.dart';

import '../services/llm/model_probe.dart' show ModelProbeResult;
import '../theme/tokens.dart';
import 'inline_alert.dart';

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
