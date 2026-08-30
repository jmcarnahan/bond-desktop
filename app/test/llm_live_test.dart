@Skip('live — needs llama-server on :8080. Run it with: '
    'flutter test test/llm_live_test.dart --run-skipped')
library;

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tests that talk to the real model.
///
/// Skipped by default because they need a server the CI box does not have, and
/// because they take about as long as every other test in this suite combined.
/// They exist for the things a fake cannot check: that this llama-server build
/// accepts each schema, that `enable_thinking: false` is honoured, and that a
/// realistic mortgage email comes back classified rather than merely
/// well-formed.

/// The email both live tests run on.
Message liveMessage() => Message(
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

void main() {
  test(
    'a real mortgage email comes back triaged',
    () async {
      final client = LlmClient();
      final message = liveMessage();

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

  test(
    'a real mortgage email comes back with facts extracted',
    () async {
      final client = LlmClient();

      final stopwatch = Stopwatch()..start();
      final result = await runTask(
        client,
        const ExtractTask(),
        ExtractionInput(liveMessage(), DateTime.now()),
        // As the handler runs it: the same email twice must be the same facts.
        temperature: 0,
      );
      stopwatch.stop();

      // ignore: avoid_print
      print(
        'evidence:      ${result.evidence}\n'
        'topics:        ${result.topics}\n'
        'people:        ${result.people}\n'
        'organizations: ${result.organizations}\n'
        'project:       ${result.project}\n'
        'intent:        ${result.intent}\n'
        'importance:    ${result.importance}\n'
        'elapsed:       ${stopwatch.elapsed.inMilliseconds} ms',
      );

      // The shape is the grammar's job; what a live run proves is that this
      // build accepts the schema at all and that the answer means something.
      expect(result.evidence, isNotEmpty);
      expect(result.topics, isNotEmpty);
      expect(
        result.intent,
        anyOf('request', 'question', 'approval', 'scheduling', 'fyi',
            'transactional', 'social'),
      );
      expect(result.importance, anyOf('low', 'normal', 'high'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'two related threads come back named as one storyline',
    () async {
      final client = LlmClient();

      // Two cards in the shape `buildConversationCard` produces:
      // subject | participants | topics | summary. Both are the same deal,
      // which is the thing the naming prompt has to notice.
      const cards = [
        'Rate lock expires Thursday | Sarah Chen | rate lock | '
            'Sarah is asking whether to extend the lock on Willow Street.',
        'Willow St appraisal came in | Dana Ruiz, Sarah Chen | appraisal | '
            'The appraisal on Willow Street came in at value.',
      ];

      final stopwatch = Stopwatch()..start();
      final result = await runTask(
        client,
        const NameStorylineTask(),
        const NameInput(cards),
        temperature: 0,
      );
      stopwatch.stop();

      // ignore: avoid_print
      print(
        'evidence: ${result.evidence}\n'
        'title:    ${result.title}\n'
        'summary:  ${result.summary}\n'
        'elapsed:  ${stopwatch.elapsed.inMilliseconds} ms',
      );

      // The shape is the grammar's job. What a live run proves is that this
      // build accepts the schema and that the name means something — a model
      // that fell back to the placeholder named nothing.
      expect(result.evidence, isNotEmpty);
      expect(result.title, isNotEmpty);
      expect(result.title, isNot(NameStorylineTask.fallbackTitle));
      expect(result.summary, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
