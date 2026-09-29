@Skip('live — needs llama-server on :8080. Run it with: '
    'flutter test test/llm_live_test.dart --run-skipped')
library;

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/message_text_task.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tests that talk to the real model.
///
/// Skipped by default because they need a server the CI box does not have, and
/// because they take about as long as every other test in this suite combined.
/// They exist for the things a fake cannot check: that this llama-server build
/// accepts each schema, that `enable_thinking: false` is honoured, and that a
/// realistic everyday email comes back classified rather than merely
/// well-formed.

/// The email both live tests run on.
Message liveMessage() => Message(
      id: 'live-1',
      outbound: false,
      fromName: 'Marisa Okonkwo',
      fromAddress: 'marisa.okonkwo@example.com',
      subject: 'Launch is Thursday — are we still on?',
      receivedAt: '2026-08-29T16:05:00Z',
      bodyText: '''
Hi Alex,

The launch is this Thursday and we still haven't heard back about the homepage
copy. The printer needs the final files by tomorrow and we announced the date
to our whole list two weeks ago.

Can you find out today whether Thursday still holds? I'd rather tell people now
than on Wednesday night.

Thanks,
Marisa
''',
    );

void main() {
  test(
    'a real everyday email comes back with its text',
    () async {
      final client = LlmClient();

      final stopwatch = Stopwatch()..start();
      final result = await runTask(
        client,
        const MessageTextTask(),
        MessageTextInput(liveMessage(), DateTime.now()),
        // As the handler runs it: the same email twice must be the same facts.
        temperature: 0,
      );
      stopwatch.stop();

      // ignore: avoid_print
      print(
        'summary:      ${result.summary}\n'
        'action_items: ${result.actionItems}\n'
        'deadline:     ${result.deadline}\n'
        'topics:       ${result.topics}\n'
        'project:      ${result.project}\n'
        'elapsed:      ${stopwatch.elapsed.inMilliseconds} ms',
      );

      // The shape is the grammar's job; what a live run proves is that this
      // build accepts the schema at all and that the answer means something.
      expect(result.summary, isNotEmpty);
      expect(result.topics, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'two related threads come back named as one storyline',
    () async {
      final client = LlmClient();

      // Two cards in the shape `buildConversationCard` produces:
      // subject | participants | topics | summary. Both are the same project,
      // which is the thing the naming prompt has to notice.
      const cards = [
        'Launch is Thursday | Marisa Okonkwo | launch date | '
            'Marisa is asking whether the site still goes live on Thursday.',
        'Homepage copy is back | Jordan Feld, Marisa Okonkwo | homepage copy | '
            'The rewritten homepage copy is ready for a final read.',
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
