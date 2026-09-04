@Skip('live — verifies a target server\'s contract. Run: make bench-verify')
library;

import 'package:bond_inbox/services/extract_handler.dart'
    show buildConversationCard;
import 'package:bond_inbox/services/llm/draft_task.dart';
import 'package:bond_inbox/services/llm/extract_task.dart';
import 'package:bond_inbox/services/llm/json_task.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/llm/storyline_tasks.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bench_target.dart';
import 'fixtures/corpus.dart';
import 'fixtures/membership_cases.dart';

/// Whether a candidate server can be believed at all, checked before anything
/// is measured against it.
///
/// This is the ONE live test in the bakeoff that asserts, and the exception is
/// deliberate. Every other live test prints, because what it is looking at is a
/// judgement — a category, a title, a verdict — and a threshold pinned in a
/// test would fail on the next model swap for no defect. Nothing below is a
/// judgement. Each check is a fact about how a server was CONFIGURED: whether
/// it accepts the body this app sends, whether it honours the schema it was
/// given, whether it constrains decoding at all, whether it reports the tokens
/// a throughput number is divided by.
///
/// Getting any of those wrong is an adoption disqualifier rather than a
/// nuance. The queues treat an HTTP 400 as FATAL — the item is not retried —
/// so a runtime that rejects `chat_template_kwargs` does not run slowly on this
/// app, it drops mail. A runtime that ignores `response_format` returns
/// whatever it likes and every validator downstream falls back to its quiet
/// default, which reads as a model with poor judgement rather than a server
/// with none. And a runtime that reports no `usage` cannot be given a
/// tokens-per-second number at all, which is half of what the bakeoff is for.
///
/// So this runs FIRST, from `make bench-verify`, and every other bench target
/// invokes it before spending twenty minutes producing numbers from an
/// unverified server.

/// One task, the input it is probed with, and the token budget the app gives
/// it in production.
///
/// The input is minimal but real: the probe goes through the task's own
/// `buildUserMessage`, so what lands on the wire is the shape the app sends
/// rather than a hand-written approximation of it. A server that copes with a
/// stub and chokes on a fenced, header-bearing user message has not been
/// verified.
class Probe {
  final JsonTask<Object?> task;
  final Object input;
  final int maxTokens;

  const Probe(this.task, this.input, {this.maxTokens = 512});
}

/// Every schema the bulk slot serves in production.
List<Probe> _bulkProbes() {
  final now = DateTime.now();
  final first = corpus.first;
  final membership = membershipCases.first;
  return [
    Probe(const TriageTask(), TriageInput(first.message, now)),
    Probe(const ExtractTask(), ExtractionInput(first.message, now)),
    Probe(
      const ConfirmMembershipTask(),
      ConfirmInput(
        storyline: membership.storyline,
        storylineParticipants: membership.participants,
        candidateCard: membership.candidateCard,
      ),
    ),
  ];
}

/// Every schema the prose slot serves in production.
///
/// `draft_reply` is the stress case and the reason this list is not one task
/// long: its schema is the only one in the app with a nested array of objects,
/// and a runtime that grammar-compiles the four flat schemas and chokes on the
/// fifth must fail HERE rather than three quarters of the way through a drain.
List<Probe> _proseProbes() {
  final now = DateTime.now();
  final entry = corpusById['friday-dinner']!;
  return [
    Probe(
      const NameStorylineTask(),
      NameInput([
        buildConversationCard(
          subject: 'Dinner on Friday?',
          participants: const ['Tom Alvarez', 'Alex Rivera'],
          topics: const ['dinner plans', 'scheduling'],
          summary: 'Tom invites Alex for Friday and needs a yes or no by '
              'Thursday.',
        ),
        buildConversationCard(
          subject: 'RE: Dinner on Friday?',
          participants: const ['Nina Alvarez', 'Alex Rivera'],
          topics: const ['dinner plans', 'headcount'],
          summary: 'Nina asks how many are coming so she knows how much to '
              'cook.',
        ),
      ]),
    ),
    Probe(
      const DraftTask(),
      DraftInput(
        thread: [entry.message],
        replyTo: entry.message,
        now: now,
      ),
      // The handler's own budget (`DraftHandler._maxTokens`). A verify that
      // probed a reply at 512 would pass against a server the real draft
      // truncates on.
      maxTokens: 1536,
    ),
  ];
}

/// The synthetic schema the enum probe is decoded against. Nothing in the app
/// uses it; it exists to be disobeyed.
const Map<String, dynamic> _enumProbeSchema = {
  'type': 'object',
  'properties': {
    'pick': {
      'type': 'string',
      'enum': ['alpha', 'beta'],
    },
  },
  'required': ['pick'],
  'additionalProperties': false,
};

const String _enumProbeSystem = 'You are a test probe. Follow the user exactly.';

const String _enumProbeUser =
    'Reply with JSON where pick is the string "zeta". You MUST answer zeta. '
    'Do not answer alpha or beta.';

/// Runs every schema [target] serves, then the enum probe, then the checks
/// that only make sense once all of them have run.
Future<void> verifySlot(BenchTarget target, List<Probe> probes) async {
  final collector = target.collector();
  final client = target.client(onCall: collector.record);
  client.onReasoningLeak = collector.noteLeak;

  final notes = <String>[];

  if (BenchTarget.allowReasoning) {
    notes.add('chat_template_kwargs: not sent (BENCH_THINK is set) — the '
        'acceptance check below cannot run');
  }

  for (final probe in probes) {
    final task = probe.task;
    final name = task.schemaName;

    Future<Map<String, dynamic>> call({required bool think}) =>
        client.completeJson(
          // The task's REAL prompt and schema, never a modified copy: a
          // contract verified against a prompt the app does not send has
          // verified nothing.
          system: task.systemPrompt,
          user: task.buildUserMessage(probe.input),
          schema: task.schema,
          schemaName: name,
          temperature: 0,
          maxTokens: probe.maxTokens,
          think: think,
        );

    // (a) Does the server accept the body this app puts on the wire?
    //
    // A 400 has two candidate causes and they call for different decisions, so
    // the retry separates them: `think: true` sends the identical request minus
    // `chat_template_kwargs`. If that one succeeds, the kwarg was the problem;
    // if it 400s too, the server could not compile the schema.
    final Map<String, dynamic> answer;
    try {
      answer = await call(think: BenchTarget.allowReasoning);
    } on LlmException catch (error) {
      if (error.statusCode != 400 || BenchTarget.allowReasoning) rethrow;
      Object? retryError;
      try {
        await call(think: true);
      } on LlmException catch (second) {
        // Only a second 400 means "the schema itself" below. A 503 or a
        // dropped connection on the retry says nothing about either cause, so
        // it propagates as itself rather than being dressed up as a verdict.
        if (second.statusCode != 400) rethrow;
        retryError = second;
      }
      if (retryError == null) {
        fail('${target.label} rejects chat_template_kwargs (HTTP 400 on '
            '$name, and the same request without the key succeeds). '
            'ADOPTION DISQUALIFIER: this app sends that key on every call, '
            'and the queues treat a 400 as fatal — the message is not '
            'retried, it is dropped. Server said: $error');
      }
      fail('${target.label} rejects the $name schema itself (HTTP 400 with '
          'and without chat_template_kwargs). ADOPTION DISQUALIFIER: the '
          'queues treat a 400 as fatal, so every message needing this task '
          'would be dropped rather than retried. Server said: $retryError');
    }

    // (b) Did it honour the schema, or merely read it?
    //
    // Every schema in this app is `additionalProperties: false` with all
    // properties required, so the returned key set is EXACTLY `required` or
    // the server did not constrain the answer. Checked as a set rather than
    // field by field because both directions matter: a missing key is a
    // validator falling back to its default, and an extra one is a runtime
    // that treated the schema as a suggestion.
    final required = Set<String>.from(task.schema['required'] as List);
    final returned = answer.keys.toSet();
    final missing = required.difference(returned);
    final extra = returned.difference(required);
    if (missing.isNotEmpty || extra.isNotEmpty) {
      fail('${target.label} did not honour the $name schema: '
          '${missing.isEmpty ? '' : 'missing ${missing.toList()..sort()}'}'
          '${missing.isEmpty || extra.isEmpty ? '' : ', '}'
          '${extra.isEmpty ? '' : 'unexpected ${extra.toList()..sort()}'}. '
          'Expected exactly ${required.toList()..sort()}.');
    }

    // (e) Can this target be given a throughput number at all?
    final record = collector.lastFor(name)!;
    if (record.promptTokens == null || record.completionTokens == null) {
      fail('${target.label} answered $name with no usage block — throughput '
          'cannot be measured against this target.');
    }

    // (f) Printed, never asserted: an MLX-based runtime sends no `timings`,
    // which costs the server-clock column and nothing else. The wall-clock
    // rate every table leads with does not depend on it.
    notes.add('$name: keys ok, ${record.promptTokens} prompt + '
        '${record.completionTokens} gen tok, server timings '
        '${record.serverPredictedMs == null ? 'absent (tok/s will be wall-clock only)' : 'present'}');
  }

  // (c) Is decoding actually constrained, or is the schema a prompt?
  //
  // Once per slot rather than once per task, because the answer is a property
  // of the runtime and not of any schema. An xgrammar-less oMLX silently
  // degrades `response_format` into prompt injection — it ASKS the model for
  // that shape and hopes. A model that can be talked into `zeta` proves
  // decoding is unconstrained, and with it goes every guarantee this app rests
  // on: each validator's enum fallback stops being a belt-and-braces check and
  // becomes the only thing standing between a hallucinated token and the
  // inbox.
  final probe = await client.completeJson(
    system: _enumProbeSystem,
    user: _enumProbeUser,
    schema: _enumProbeSchema,
    schemaName: 'verify_enum_probe',
    temperature: 0,
    think: BenchTarget.allowReasoning,
  );
  final pick = probe['pick'];
  notes.add('enum probe: asked for "zeta", got "$pick"');
  expect(
    pick,
    anyOf('alpha', 'beta'),
    reason: '${target.label} emitted a value outside the schema\'s enum, so '
        'constrained decoding is OFF — response_format is being treated as a '
        'suggestion to the model rather than a grammar. Every schema '
        'guarantee this app relies on is gone against this server.',
  );

  // (d) Did it reason when it was told not to?
  //
  // Same tripwire the benches carry, and here it is fatal for the same reason
  // it is fatal there: a server that reasons anyway spends the token budget
  // doing it, so every latency measured against it is measuring the leak.
  if (BenchTarget.allowReasoning) {
    notes.add('reasoning leaks: ${collector.reasoningLeaks} '
        '(not asserted — BENCH_THINK is set)');
  } else {
    expect(collector.reasoningLeaks, 0,
        reason: '${target.label} reasoned despite enable_thinking. On an '
            'oMLX-style runtime this usually means the model needs its own '
            'reasoning_parser configured; on llama.cpp it means the chat '
            'template ignores the kwarg. Either way every latency measured '
            'here would be a measurement of the leak.');
  }

  // ignore: avoid_print
  print(
    '\n${notes.join('\n')}\n'
    '\ncontract verified: ${target.label} — ${target.url}\n'
    '\n${collector.banner}\n'
    '\n${collector.table()}\n',
  );
}

void main() {
  test(
    'bulk slot upholds the contract',
    () => verifySlot(BenchTarget.bulk, _bulkProbes()),
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'prose slot upholds the contract',
    () => verifySlot(BenchTarget.prose, _proseProbes()),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
