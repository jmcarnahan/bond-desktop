import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';

/// The shared fixture's own tests.
///
/// Twenty-eight test files rest on `ScriptedLlm`, so its conventions — the
/// last step repeating, a hold answering with the NEXT step, a computed step
/// seeing the call it answers — are pinned here rather than rediscovered one
/// migration at a time.
void main() {
  const schema = <String, dynamic>{'type': 'object'};

  Future<Map<String, dynamic>> ask(
    ScriptedLlm llm,
    String schemaName, {
    String system = 'the system prompt',
    String user = 'the user message',
    double temperature = 0.2,
    int maxTokens = 512,
  }) =>
      llm.completeJson(
        system: system,
        user: user,
        schema: schema,
        schemaName: schemaName,
        temperature: temperature,
        maxTokens: maxTokens,
      );

  group('steps', () {
    test('a map step is returned, and the last step repeats', () async {
      final llm = ScriptedLlm()
        ..scriptFor('triage', [
          {'v': 1},
          {'v': 2},
        ]);

      expect(await ask(llm, 'triage'), {'v': 1});
      expect(await ask(llm, 'triage'), {'v': 2});
      expect(await ask(llm, 'triage'), {'v': 2});
      expect(llm.callsFor('triage'), 3);
    });

    test('scriptFor copies its list, so one script serves two clients',
        () async {
      final steps = <Object>[
        {'v': 1},
        {'v': 2},
      ];
      final a = ScriptedLlm()..scriptFor('triage', steps);
      final b = ScriptedLlm()..scriptFor('triage', steps);

      expect(await ask(a, 'triage'), {'v': 1});
      expect(await ask(b, 'triage'), {'v': 1});
      expect(steps, hasLength(2));
    });

    test('a string step answers complete, and completeJson refuses it',
        () async {
      final llm = ScriptedLlm(answers: {'complete': 'plain words'});

      expect(
        await llm.complete(system: 's', user: 'u'),
        'plain words',
      );
      expect(llm.schemas, ['complete']);

      final refuses = ScriptedLlm(answers: {'triage': 'plain words'});
      await expectLater(
        ask(refuses, 'triage'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('scripted'), contains('triage')),
          ),
        ),
      );
    });

    test('an Exception step and an Error step are both thrown', () async {
      final llm = ScriptedLlm()
        ..answer('triage', const LlmFormatException('not an object'))
        ..answer('extraction', StateError('the store is gone'));

      await expectLater(ask(llm, 'triage'), throwsA(isA<LlmFormatException>()));
      await expectLater(ask(llm, 'extraction'), throwsA(isA<StateError>()));
    });

    test('a hold is awaited and the NEXT step answers the call', () async {
      final gate = Completer<void>();
      final llm = ScriptedLlm()
        ..scriptFor('triage', [
          gate,
          {'v': 'after the hold'},
        ]);

      var answered = false;
      final pending = ask(llm, 'triage').then((m) {
        answered = true;
        return m;
      });

      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(answered, isFalse, reason: 'the hold has not been released');

      gate.complete();
      expect(await pending, {'v': 'after the hold'});
    });

    test('a hold as the LAST step repeats the answer before it', () async {
      final gate = Completer<void>();
      final llm = ScriptedLlm()
        ..scriptFor('triage', [
          {'v': 'first'},
          gate,
        ]);

      expect(await ask(llm, 'triage'), {'v': 'first'});

      final held = ask(llm, 'triage');
      gate.complete();
      expect(await held, {'v': 'first'});
    });

    test('a hold with nothing before it and nothing after it says so',
        () async {
      final gate = Completer<void>();
      final llm = ScriptedLlm(label: 'the fast client')
        ..scriptFor('triage', [gate]);

      final held = ask(llm, 'triage');
      gate.complete();
      await expectLater(
        held,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('the fast client'),
          ),
        ),
      );
    });

    test('a computed step sees the call it is answering', () async {
      final seen = <String>[];
      final llm = ScriptedLlm()
        ..answer('triage', (LlmCall call) {
          seen.add('${call.schemaName}/${call.user}');
          return {'echo': call.user, 'budget': call.maxTokens};
        });

      expect(
        await ask(llm, 'triage', user: 'Subject: m1', maxTokens: 1024),
        {'echo': 'Subject: m1', 'budget': 1024},
      );
      expect(seen, ['triage/Subject: m1']);
    });

    test('an async computed step is awaited', () async {
      final llm = ScriptedLlm()
        ..answer('triage', (LlmCall call) async {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return <String, dynamic>{'late': true};
        });

      expect(await ask(llm, 'triage'), {'late': true});
    });
  });

  group('unscripted schemas', () {
    test('the fallback answers every schema that has no script of its own',
        () async {
      final llm = ScriptedLlm(fallback: const {'union': 'answer'});

      expect(await ask(llm, 'triage'), {'union': 'answer'});
      expect(await ask(llm, 'storyline_name'), {'union': 'answer'});
      expect(llm.schemas, ['triage', 'storyline_name']);
    });

    test('a throwing fallback throws', () async {
      final llm = ScriptedLlm(fallback: StateError('bad answer'));
      await expectLater(ask(llm, 'triage'), throwsA(isA<StateError>()));
    });

    test('a hold as the fallback is refused rather than awaited', () async {
      // A hold answers with the step AFTER it, and a fallback has none, so
      // awaiting this one would park the call and fail anyway. It says so at
      // once, and the completer is never waited on.
      final gate = Completer<void>();
      final llm = ScriptedLlm(label: 'the prose client', fallback: gate);

      await expectLater(
        ask(llm, 'storyline_name'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('the prose client'),
              contains('storyline_name'),
              contains('hold'),
            ),
          ),
        ),
      );
      expect(gate.isCompleted, isFalse);
    });

    test('a bare future as the fallback is refused the same way', () async {
      final llm = ScriptedLlm(fallback: Future<void>.value());
      await expectLater(
        ask(llm, 'triage'),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('hold')),
        ),
      );
    });

    test('never() throws for any schema, naming itself and the schema',
        () async {
      final llm = ScriptedLlm.never(label: 'the repair');

      await expectLater(
        ask(llm, 'storyline_membership'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'the repair: no script for storyline_membership',
          ),
        ),
      );
      expect(llm.calls, hasLength(1));
    });

    test('the default label names an unscripted call', () async {
      await expectLater(
        ask(ScriptedLlm(), 'triage'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'scripted: no script for triage',
          ),
        ),
      );
    });
  });

  group('recording', () {
    test('the derived getters are projections of calls, index for index',
        () async {
      final llm = ScriptedLlm(fallback: const {'ok': true});

      await ask(llm, 'triage',
          system: 'sys A', user: 'user A', temperature: 0.0, maxTokens: 256);
      await ask(llm, 'storyline_name',
          system: 'sys B', user: 'user B', temperature: 0.4, maxTokens: 1024);

      expect(llm.calls, hasLength(2));
      expect(llm.schemas, ['triage', 'storyline_name']);
      expect(llm.schemaNames, llm.schemas);
      expect(llm.systems, ['sys A', 'sys B']);
      expect(llm.userMessages, ['user A', 'user B']);
      expect(llm.users, llm.userMessages);
      expect(llm.temperatures, [0.0, 0.4]);
      expect(llm.tokenBudgets, [256, 1024]);
      expect(llm.budgets, {'triage': 256, 'storyline_name': 1024});
      expect(llm.callsFor('triage'), 1);
      expect(llm.callsFor('extraction'), 0);

      // The idiom the storyline tests rest on: one index across two lists.
      expect(llm.userMessages[llm.schemas.indexOf('storyline_name')], 'user B');
    });

    test('budgets keeps the LAST call of a schema', () async {
      final llm = ScriptedLlm(fallback: const {'ok': true});

      await ask(llm, 'triage', maxTokens: 256);
      await ask(llm, 'triage', maxTokens: 1024);

      expect(llm.tokenBudgets, [256, 1024]);
      expect(llm.budgets, {'triage': 1024});
    });

    test('a call that threw is still recorded', () async {
      final llm = ScriptedLlm(fallback: StateError('nope'));

      await expectLater(ask(llm, 'triage'), throwsA(isA<StateError>()));
      expect(llm.schemas, ['triage']);
    });

    test('onCall runs before the answer, inside the in-flight window',
        () async {
      final order = <String>[];
      final llm = ScriptedLlm(
        answers: {
          'triage': (LlmCall call) {
            order.add('answer');
            return <String, dynamic>{'ok': true};
          },
        },
        onCall: (call) => order.add('onCall ${call.schemaName}'),
      );

      await ask(llm, 'triage');
      expect(order, ['onCall triage', 'answer']);
    });

    test('maxInFlight is the high-water mark of concurrent calls', () async {
      final gate = Completer<void>();
      final llm = ScriptedLlm(
        answers: {'triage': const {'ok': true}},
        onCall: (_) => gate.future,
      );

      final first = ask(llm, 'triage');
      final second = ask(llm, 'triage');
      await Future<void>.delayed(Duration.zero);
      expect(llm.inFlight, 2);

      gate.complete();
      await Future.wait([first, second]);

      expect(llm.maxInFlight, 2);
      expect(llm.inFlight, 0);
    });
  });

  group('streaming', () {
    test('the chunks arrive one at a time and reassemble into the answer',
        () async {
      const answer = <String, dynamic>{'reply_body': 'Thursday still works.'};
      final llm = ScriptedLlm(answers: {'draft_reply': answer})
        ..streamChunks = ['{"reply_body":"Thursday ', 'still works."}'];

      final seen = <String>[];
      final returned = await llm.completeJsonStreamed(
        system: 's',
        user: 'u',
        schema: schema,
        schemaName: 'draft_reply',
        onText: seen.add,
      );

      expect(seen, ['{"reply_body":"Thursday ', 'still works."}']);
      expect(jsonDecode(seen.join()), answer);
      expect(returned, answer);
      expect(llm.streamedCalls, 1);
      expect(llm.calls.single.streamed, isTrue);
      expect(llm.schemas, ['draft_reply']);
    });

    test('a plain call beside a streamed one leaves streamedCalls alone',
        () async {
      final llm = ScriptedLlm(fallback: const {'ok': true});
      await ask(llm, 'reply_decision');
      expect(llm.streamedCalls, 0);
      expect(llm.calls.single.streamed, isFalse);
    });

    test('a throwing step throws AFTER the chunks went out', () async {
      final llm = ScriptedLlm(
        answers: {'draft_reply': const LlmFormatException('cut off')},
      )..streamChunks = ['{"reply_', 'body":"half'];

      final seen = <String>[];
      await expectLater(
        llm.completeJsonStreamed(
          system: 's',
          user: 'u',
          schema: schema,
          schemaName: 'draft_reply',
          onText: seen.add,
        ),
        throwsA(isA<LlmFormatException>()),
      );
      expect(seen, ['{"reply_', 'body":"half']);
    });
  });

  group('records', () {
    test('a returned step reports ok with the fixed counts', () async {
      final records = <LlmCallRecord>[];
      final llm = ScriptedLlm(
        answers: {'triage': const {'ok': true}},
        observer: records.add,
        emitRecords: true,
      );

      await ask(llm, 'triage');

      expect(records, hasLength(1));
      expect(records.single.label, 'triage');
      expect(records.single.outcome, 'ok');
      expect(records.single.durationMs, 5);
      expect(records.single.promptTokens, 700);
      expect(records.single.completionTokens, 40);
      expect(records.single.error, isNull);
    });

    test('a thrown step reports unavailable before it throws', () async {
      final records = <LlmCallRecord>[];
      final llm = ScriptedLlm(
        answers: {'extraction': const LlmFormatException('not an object')},
        observer: records.add,
        emitRecords: true,
      );

      await expectLater(
        ask(llm, 'extraction'),
        throwsA(isA<LlmFormatException>()),
      );

      expect(records, hasLength(1));
      expect(records.single.label, 'extraction');
      expect(records.single.outcome, 'unavailable');
      expect(records.single.durationMs, 5);
      expect(records.single.error, 'not an object');
      expect(records.single.promptTokens, isNull);
    });

    test('a string step reaching completeJson reports nothing at all',
        () async {
      // The refusal is a scripting mistake rather than a call that happened,
      // so the observer hears neither an `ok` before the throw nor an
      // `unavailable` with it.
      final records = <LlmCallRecord>[];
      final llm = ScriptedLlm(
        answers: {'triage': 'plain words'},
        observer: records.add,
        emitRecords: true,
      );

      await expectLater(ask(llm, 'triage'), throwsA(isA<StateError>()));

      expect(records, isEmpty);
      // The call itself is still recorded: it reached the client.
      expect(llm.schemas, ['triage']);
    });

    test('emitRecords off is silent even with an observer', () async {
      final records = <LlmCallRecord>[];
      final llm = ScriptedLlm(
        answers: {'triage': const {'ok': true}},
        observer: records.add,
      );

      await ask(llm, 'triage');
      expect(records, isEmpty);
    });
  });
}
