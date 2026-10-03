import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/calendar_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/backend/calendar_backend.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_lexicon.dart';
import 'package:bond_inbox/services/calendar/command/command_planner.dart';
import 'package:bond_inbox/services/calendar/command/command_router.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// A target's URL is a setting, and a stored row outlives the setting.
///
/// `LlmClient` names the server it could not reach in the sentence it throws,
/// which is right on a screen and wrong in `activity_events` or a work row.
/// [redactEndpoints] is the one choke point between the sentence and the row,
/// and this file holds it at the three places a sentence becomes a row: the
/// call record the observer sees, the worker's failure row, and the work
/// item's own error column.
///
/// An answer the model gave that was not the JSON asked for is stricter
/// still: its sentence quotes the answer, so those rows carry the category
/// alone ([rowErrorFor]) — never a word of the mail, the calendar or the Day
/// bar the answer was written from.

/// A handler that fails the way a handler reading an unreachable server does:
/// with a sentence that spells the endpoint.
class _Throwing extends WorkHandler {
  @override
  final String kind = 'extract';

  @override
  Future<void> run(Map<String, Object?> item) async {
    throw StateError(
      'The model server at http://box.example.com:18100/v1/chat/completions '
      'is not reachable',
    );
  }
}


/// A real client over a server whose every answer is [content] as plain
/// text, not the JSON the call asked for — the format failure whose sentence
/// quotes the answer. The observer is the activity log's, as the app wires it.
LlmClient nonJsonClient(String content, ActivityLog log) => LlmClient(
      baseUrl: 'http://localhost:18100/v1/chat/completions',
      model: 'qwen3.8',
      httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': content},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          )),
      onCall: log.noteLlmCall,
    );

/// A brief handler cut down to its model call: the answer it gets back is
/// not JSON, so it fails the way `MeetingBriefHandler` does on that answer.
class _BriefOverNonJson extends WorkHandler {
  _BriefOverNonJson(this.client);

  final LlmClient client;

  @override
  final String kind = 'meeting_brief';

  @override
  Future<void> run(Map<String, Object?> item) async {
    await client.completeJson(
      system: 'system',
      user: 'user',
      schema: const {'type': 'object'},
      schemaName: 'meeting_brief',
    );
  }
}

class _NoWrites implements CalendarWriter {
  @override
  Future<PreviewResult> preview(CalendarWrite write) =>
      throw UnimplementedError();

  @override
  Future<WriteOutcome> commit(
    CalendarWrite write, {
    WritePreview? preview,
    bool isUndo = false,
  }) =>
      throw UnimplementedError();
}

class _NoBackend extends Fake implements CalendarBackend {}

class _NoPeople extends Fake implements PeopleBackend {
  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async =>
      const [];
}

/// A triage model that fails with a sentence spelling an address, the way a
/// 4xx body snippet or a transport wrapper can.
ScriptedLlm throwingLlm() => ScriptedLlm(
      fallback: StateError(
        'bad answer from http://box.example.com:18101/v1/chat/completions',
      ),
    );

void main() {
  group('redactEndpoints', () {
    test('replaces an http URL with its port and path', () {
      expect(
        redactEndpoints('The model server at '
            'http://localhost:18100/v1/chat/completions is not reachable'),
        'The model server at <endpoint> is not reachable',
      );
    });

    test('replaces https, and every URL in the sentence', () {
      expect(
        redactEndpoints('tried https://bedrock.example.com/model/x/converse '
            'then http://127.0.0.1:8080/v1'),
        'tried <endpoint> then <endpoint>',
      );
    });

    test('stops at a quote, a bracket or whitespace', () {
      expect(
        redactEndpoints('"http://a.example.com/v1" (http://b.example.com)'),
        '"<endpoint>" (<endpoint>)',
      );
    });

    test('leaves a sentence with no URL alone', () {
      const text = 'The local model did not answer within 90 seconds.';
      expect(redactEndpoints(text), text);
    });
  });

  group('the call record', () {
    test('carries the redacted sentence, and the exception the full one',
        () async {
      final records = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: 'http://localhost:18100/v1/chat/completions',
        model: 'qwen3.8',
        httpClient: MockClient(
          (_) async => throw const SocketException('connection refused'),
        ),
        onCall: records.add,
      );

      Object? thrown;
      try {
        await client.completeJson(
          system: 'system',
          user: 'user',
          schema: const {'type': 'object'},
          schemaName: 'probe',
        );
      } on LlmUnavailableException catch (e) {
        thrown = e;
      }

      // The screen still gets the sentence with the address in it.
      expect(thrown, isA<LlmUnavailableException>());
      expect((thrown! as LlmUnavailableException).message, contains('18100'));
      // The row does not.
      expect(records, hasLength(1));
      expect(records.single.outcome, 'unavailable');
      expect(records.single.error, contains('<endpoint>'));
      expect(records.single.error, isNot(contains('http')));
      expect(records.single.error, isNot(contains('18100')));
    });
  });

  group('an answer that is not JSON', () {
    late BondDatabase db;
    late MessageStore store;
    late ActivityLog log;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
      log = ActivityLog(store);
    });

    tearDown(() async {
      log.dispose();
      await db.close();
    });

    test('the call record names the category; the exception keeps the quote',
        () async {
      final records = <LlmCallRecord>[];
      final client = LlmClient(
        baseUrl: 'http://localhost:18100/v1/chat/completions',
        model: 'qwen3.8',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'Robin asked about invoice 4471'},
                  },
                ],
              }),
              200,
            )),
        onCall: records.add,
      );
      Object? thrown;
      try {
        await client.completeJson(
          system: 'system',
          user: 'user',
          schema: const {'type': 'object'},
          schemaName: 'probe',
        );
      } on LlmFormatException catch (e) {
        thrown = e;
      }
      expect((thrown! as LlmFormatException).message, contains('invoice 4471'),
          reason: 'the screen still gets the whole sentence');
      expect(records.single.outcome, 'format');
      expect(records.single.error, 'format: not JSON');
      expect(rowErrorFor(thrown), 'format: not JSON');
    });

    test('a calendar_intent answer never reaches the command row', () async {
      await initCalendarZones();
      final la = CalendarZone.tryNamed('America/Los_Angeles')!;
      final now = la.localDateTime(const CalendarDate(2026, 10, 14), 10, 42);
      final router = CommandRouter(
        classifiers: const [LexiconClassifier()],
        planner: CommandPlanner(
          calendar: CalendarStore(db),
          backend: _NoBackend(),
          writer: _NoWrites(),
          mailbox: () async => null,
        ),
        intentClient: () => nonJsonClient(
            'catch up with Dana about the Fabrikam renewal', log),
        people: _NoPeople(),
        activityLog: log,
      );

      await router.submit(
        'catch up w/ Dana sometime',
        now: now,
        zone: la,
        today: const CalendarDate(2026, 10, 14),
        people: const [
          KnownPerson(name: 'Dana Whitfield', address: 'dana@contoso.com'),
        ],
        events: const [],
      );

      final rows = [
        for (final row in await store.recentActivity())
          if (row['kind'] == 'calendar_command') row,
      ];
      expect(rows, hasLength(1));
      final raw = rows.single['detail_json'] as String;
      final detail = jsonDecode(raw) as Map;
      expect(detail['llm_error'], 'format: not JSON');
      for (final word in ['catch', 'Dana', 'Fabrikam', 'renewal']) {
        expect(raw, isNot(contains(word)));
      }
    });

    test('a failed meeting_brief writes the category to both rows', () async {
      await store.enqueueWork('meeting_brief', 'calendar', 'occ-1');
      final worker = AiWorker(
        store,
        handlers: [
          _BriefOverNonJson(
              nonJsonClient('Dana asked for the Fabrikam numbers', log)),
        ],
        activityLog: log,
      );
      addTearDown(worker.dispose);

      await worker.pump();

      final rows = [
        for (final row in await store.recentActivity())
          if (row['kind'] == 'meeting_brief') row,
      ];
      expect(rows, isNotEmpty, reason: 'the claim happened');
      for (final row in rows) {
        final raw = row['detail_json'] as String;
        final detail = jsonDecode(raw) as Map;
        expect(detail['error'], 'format: not JSON');
        expect(detail['llm_error'], 'format: not JSON');
        expect(raw, isNot(contains('Fabrikam')));
        expect(raw, isNot(contains('Dana')));
      }
      final work = await db
          .customSelect(
            'SELECT error FROM work_items '
            "WHERE task_kind = 'meeting_brief' AND entity_id = 'occ-1'",
          )
          .getSingle();
      expect(work.data['error'], 'format: not JSON');
    });
  });

  group('the worker', () {
    late BondDatabase db;
    late MessageStore store;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
    });

    tearDown(() => db.close());

    test('writes a redacted failure row and a redacted work item', () async {
      await store.enqueueWork('extract', 'email', 'm1');
      final worker = AiWorker(
        store,
        handlers: [_Throwing()],
        activityLog: ActivityLog(store),
      );

      await worker.pump();

      // The worker retries once inside the same pump, so there are two rows,
      // `retry` then `error`, and both must be clean.
      final rows = [
        for (final row in await store.recentActivity())
          if (row['kind'] == 'extract') row,
      ];
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final detail = jsonDecode(row['detail_json'] as String) as Map;
        expect(detail['error'], contains('<endpoint>'));
        expect(detail['error'], isNot(contains('http')));
        expect(detail['error'], isNot(contains('box.example.com')));
      }

      final work = await db
          .customSelect(
            'SELECT error FROM work_items '
            "WHERE task_kind = 'extract' AND entity_id = 'm1'",
          )
          .getSingle();
      expect(work.data['error'], contains('<endpoint>'));
      expect(work.data['error'], isNot(contains('http')));
    });

    test('and the triage queue, its twin, writes the same two rows clean',
        () async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'subject': 'Invoice 4471',
        'from_name': 'Robin Ellery',
        'from_address': 'robin@example.com',
        'received_at': '2026-09-18T10:00:00Z',
        'body_text': 'Is the invoice paid?',
        'triage_status': 'pending',
      });
      final queue = TriageQueue(
        store,
        decisionClient: ScriptedDecisionClient(throwingLlm()),
        concurrency: 1,
        activityLog: ActivityLog(store),
      );
      addTearDown(queue.dispose);

      await queue.pump();

      final rows = [
        for (final row in await store.recentActivity())
          if (row['kind'] == 'triage') row,
      ];
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final detail = jsonDecode(row['detail_json'] as String) as Map;
        expect(detail['error'], contains('<endpoint>'));
        expect(detail['error'], isNot(contains('http')));
      }
      final message = await db
          .customSelect(
            "SELECT triage_error FROM messages WHERE source_message_id = 'm1'",
          )
          .getSingle();
      expect(message.data['triage_error'], contains('<endpoint>'));
      expect(message.data['triage_error'], isNot(contains('http')));
    });
  });
}
