import 'dart:async';

// `show`: drift generates an `ActivityEvent` row class from the
// `activity_events` table, and this file means the log's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_llama_server.dart';
import 'fixtures/test_db.dart';

/// The activity log under the concurrent drains — the exact break its
/// original single-slot design predicted for itself ("if a future phase
/// parallelizes the drains, this slot is the thing that breaks").
///
/// The claim under test is attribution: with three messages in flight at
/// once, each one's model-call tally must fold into ITS activity row, not
/// into whichever row records first. The end-to-end test drives the real
/// [TriageQueue] with all three requests deliberately held open together,
/// because overlap is the whole condition — a fake that answers instantly
/// would pass on the broken single slot too.

/// Answers every triage request only after [release] completes, reporting a
/// per-message [LlmCallRecord] the way the real client's observer does —
/// from inside the request, which is what places it inside the item's span.
class HeldLlm extends LlmClient {
  final ActivityLog log;
  final Completer<void> release = Completer<void>();

  /// `entity id → the duration its record carried`, for the assertion.
  final Map<String, int> reported = {};

  HeldLlm(this.log) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

  @override
  Future<Map<String, dynamic>> completeJson({
    required String system,
    required String user,
    required Map<String, dynamic> schema,
    String schemaName = 'result',
    int maxTokens = 512,
    double temperature = 0.2,
    bool think = false,
  }) async {
    // The message id rides in the user prompt's subject line; a distinct
    // duration per message is what makes cross-attribution visible.
    final id = RegExp(r'Subject: (m\d)').firstMatch(user)!.group(1)!;
    final durationMs = 100 * (int.parse(id.substring(1)) + 1);
    reported[id] = durationMs;

    await release.future;
    log.noteLlmCall(LlmCallRecord(
      label: 'triage',
      durationMs: durationMs,
      outcome: 'ok',
      completionTokens: durationMs,
    ));
    return {
      'urgency': 'normal',
      'category': 'borrower',
      'summary': 'A borrower question.',
      'needs_action': true,
      'action_items': const ['Reply'],
    };
  }
}

void main() {
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

  Future<void> seedMessage(String id) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': 'conv-$id',
      'direction': 'inbound',
      'subject': id,
      'from_name': 'Sarah Chen',
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-29T1${id.substring(1)}:00:00Z',
      'body_text': 'Can we extend the lock through Friday?',
      'triage_status': 'pending',
    });
  }

  Future<Map<String, ActivityEvent>> triageEventsById() async => {
        for (final row in await store.recentActivity(limit: 20))
          if (row['kind'] == 'triage')
            ActivityEvent.fromRow(row).entityId!: ActivityEvent.fromRow(row),
      };

  test('three concurrent messages each keep their own model tally', () async {
    for (final id in ['m0', 'm1', 'm2']) {
      await seedMessage(id);
    }
    final llm = HeldLlm(log);
    final queue = TriageQueue(store, llm, activityLog: log);

    final drain = queue.pump();
    // All three must be AT the server together before any answers: overlap is
    // the condition under test, not an accident of timing.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(llm.reported.length, 3);
    llm.release.complete();
    await drain;

    final events = await triageEventsById();
    expect(events.keys, unorderedEquals(['m0', 'm1', 'm2']));
    for (final entry in llm.reported.entries) {
      final event = events[entry.key]!;
      // One call each, carrying ITS duration — the single-slot design would
      // have put all three calls (600ms) on one row and nothing on the rest.
      expect(event.detail['llm_calls'], 1, reason: entry.key);
      expect(event.detail['llm_ms'], entry.value, reason: entry.key);
      expect(event.detail['completion_tokens'], entry.value, reason: entry.key);
    }
  });

  test('the real observer path lands in the item\'s span too', () async {
    // The design's load-bearing claim, exercised with the PRODUCTION wiring
    // rather than a shortcut: a real LlmClient whose `onCall` observer is the
    // log's noteLlmCall, against a real socket that delays every answer so
    // three requests genuinely overlap. The observer fires inside `_post`,
    // which runs in the item's zone — a Dart callback executes in the zone
    // that invokes it, and this test is where that stops being an inference.
    final fake = await FakeLlamaServer.start();
    addTearDown(fake.close);
    fake.delay = const Duration(milliseconds: 30);
    fake.scriptFor('triage', [
      {
        'urgency': 'normal',
        'category': 'borrower',
        'summary': 'A borrower question.',
        'needs_action': true,
        'action_items': const ['Reply'],
      },
    ]);
    for (final id in ['m0', 'm1', 'm2']) {
      await seedMessage(id);
    }

    final client = LlmClient(baseUrl: fake.chatUrl, onCall: log.noteLlmCall);
    await TriageQueue(store, client, activityLog: log).pump();

    final events = await triageEventsById();
    expect(events.keys, unorderedEquals(['m0', 'm1', 'm2']));
    for (final event in events.values) {
      // Exactly one observed call per row. The single-slot design would have
      // lumped whichever calls had answered onto the first row to record.
      expect(event.detail['llm_calls'], 1, reason: event.entityId);
      expect(event.detail['llm_label'], 'triage', reason: event.entityId);
    }
  });

  test('the root slot still serves a caller outside any span', () async {
    log.note({'chats_seen': 4});
    log.noteLlmCall(const LlmCallRecord(
      label: 'triage',
      durationMs: 250,
      outcome: 'ok',
      completionTokens: 40,
    ));
    await log.record('triage', source: 'email', entityId: 'solo');

    final event = (await triageEventsById())['solo']!;
    expect(event.detail['llm_calls'], 1);
    expect(event.detail['llm_ms'], 250);
    expect(event.detail['chats_seen'], 4);
  });

  test('a span cannot leak its status onto a sibling', () async {
    final results = await Future.wait([
      log.inSpan(() async {
        log.noteStatus('skipped');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return log.pendingStatusOr('ok');
      }),
      log.inSpan(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return log.pendingStatusOr('ok');
      }),
    ]);

    // The first span's early-return status is its own; the sibling that set
    // nothing keeps the worker's fallback.
    expect(results, ['skipped', 'ok']);
  });
}
