import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

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
        throwingLlm(),
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
