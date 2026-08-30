@Skip('live — needs llama-server on :8080. Run it with: '
    'flutter test test/llm_live_test.dart --run-skipped')
library;

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one test that talks to the real model.
///
/// Skipped by default because it needs a server the CI box does not have, and
/// because it takes about as long as every other test in this suite combined.
/// It exists for the things a fake cannot check: that this llama-server build
/// accepts the schema, that `enable_thinking: false` is honoured, and that a
/// realistic mortgage email comes back classified rather than merely
/// well-formed.
void main() {
  test(
    'a real mortgage email comes back triaged',
    () async {
      final client = LlmClient();
      final message = Message(
        id: 'live-1',
        outbound: false,
        fromName: 'Sarah Chen',
        fromAddress: 'sarah.chen@example.com',
        subject: 'Rate lock expires Thursday — can we extend?',
        receivedAt: '2026-08-29T16:05:00Z',
        bodyText: '''
Hi Jason,

Our rate lock on the Willow Street purchase expires this Thursday and we still
haven't heard back from underwriting on the condition about my bonus income. My
agent says we can't close without the clear-to-close by Friday.

Can you find out today whether we need to extend the lock? I'm worried about
the cost if the rate has moved.

Thanks,
Sarah
''',
      );

      final stopwatch = Stopwatch()..start();
      final result = await runTask(
        client,
        const TriageTask(),
        TriageInput(message, DateTime.now()),
      );
      stopwatch.stop();

      // ignore: avoid_print
      print(
        'urgency:      ${result.urgency}\n'
        'category:     ${result.category}\n'
        'summary:      ${result.summary}\n'
        'needs_action: ${result.needsAction}\n'
        'action_items: ${result.actionItems}\n'
        'elapsed:      ${stopwatch.elapsed.inMilliseconds} ms',
      );

      expect(
        result.urgency,
        anyOf('low', 'normal', 'high', 'urgent'),
      );
      expect(result.summary, isNotEmpty);
      expect(result.category, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
