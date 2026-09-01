import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/corpus.dart';
import 'fixtures/test_db.dart';
import 'fixtures/fake_llama_server.dart';

/// A whole inbox drained end to end: the real queue, the real store, the real
/// `LlmClient`, and a socket that answers like llama-server.
///
/// `triage_queue_test.dart` covers the queue's decisions one contrived message
/// at a time. This file runs the corpus through all of it at once, which is
/// what catches the failures that only appear in aggregate — a gate that stops
/// firing and quietly adds a model call per sync, a drain that parks on the
/// wrong message, a fold-up that lands on the wrong row.

Map<String, dynamic> triageAnswer({
  String urgency = 'high',
  String category = 'borrower',
  String summary = 'The borrower is asking about the rate lock.',
  bool needsAction = true,
  List<String> actionItems = const ['Call Sarah about the lock'],
}) =>
    {
      'urgency': urgency,
      'category': category,
      'summary': summary,
      'needs_action': needsAction,
      'action_items': actionItems,
    };

/// Newest first, which is the order the drain reads them in.
List<CorpusEmail> byRecency(Iterable<CorpusEmail> entries) {
  final sorted = entries.toList()
    ..sort((a, b) =>
        (b.message.receivedAt ?? '').compareTo(a.message.receivedAt ?? ''));
  return sorted;
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late FakeLlamaServer fake;
  late LlmClient client;

  /// Every email entry, seeded the way a delta page plus a detail fetch would
  /// have left it — body, headers and all, so the queue's own fetch step has
  /// nothing to do and the gates have everything to read.
  Future<void> seedCorpus(Iterable<CorpusEmail> entries) async {
    for (final entry in entries) {
      final message = entry.message;
      await store.upsertMessage({
        'source': message.source,
        'source_message_id': entry.id,
        'conversation_key': entry.conversationKey,
        'direction': message.outbound ? 'outbound' : 'inbound',
        'subject': message.subject,
        'from_name': message.fromName,
        'from_address': message.fromAddress,
        'received_at': message.receivedAt,
        'body_preview': message.bodyPreview,
        'body_text': message.bodyText,
        'source_meta_json': message.sourceMetaJson,
        'triage_status': 'pending',
      });
    }
  }

  Future<void> seedConversation(String key, String lastInboundAt) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Willow St purchase',
      'state': 'needs_reply',
      'last_inbound_at': lastInboundAt,
      'last_message_at': lastInboundAt,
    });
  }

  Future<Map<String, Object?>> messageRow(String id) async =>
      (await store.getMessageRow('email', id))!;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
    fake = await FakeLlamaServer.start();
    client = LlmClient(baseUrl: fake.chatUrl);
  });

  tearDown(() async {
    await fake.close();
    db.close();
  });

  group('a full drain', () {
    final emails = emailCorpus.toList();
    final gated = emails.where((entry) => entry.expectedGate != null).toList();
    final ungated = emails.where((entry) => entry.expectedGate == null).toList();

    setUp(() async {
      await seedCorpus(emails);
      // The Willow St thread's newest inbound is the rate-lock email, so that
      // is the message whose ask the row should end up carrying.
      await seedConversation('conv-willow-st', '2026-08-30T16:05:00Z');
      fake.scriptFor('triage', [
        triageAnswer(
          urgency: 'urgent',
          category: 'borrower',
          actionItems: const ['Extend the lock through Friday'],
        ),
      ]);

      await TriageQueue(store, client, userAddress: loAddress).pump();
    });

    test('every gated message is skipped with its own reason', () async {
      expect(gated, isNotEmpty);
      for (final entry in gated) {
        final row = await messageRow(entry.id);
        expect(row['triage_status'], 'skipped', reason: entry.id);
        expect(row['gate_reason'], entry.expectedGate, reason: entry.id);
      }
    });

    test('every message that reaches the model comes back triaged', () async {
      for (final entry in ungated) {
        expect((await messageRow(entry.id))['triage_status'], 'triaged',
            reason: entry.id);
      }
    });

    test('the gated mail costs no model time at all', () {
      // The economics of the whole gate tier, in one number: the sockets
      // opened are exactly the messages no gate caught.
      expect(fake.requests.length, ungated.length);
    });

    test('the newest inbound message\'s ask lands on the thread', () async {
      final row = (await store.getConversationRow('email', 'conv-willow-st'))!;
      expect(row['cta_text'], 'Extend the lock through Friday');
      expect(row['cta_urgency'], 'urgent');
      expect(row['category'], 'borrower');
    });
  });

  test('a server that goes down parks the drain and spends no attempt',
      () async {
    // Only the mail that reaches the model, so the 503 lands on a message
    // rather than behind a gate.
    final ungated = byRecency(
      emailCorpus.where((entry) => entry.expectedGate == null),
    );
    await seedCorpus(ungated);
    fake.scriptFor('triage', [triageAnswer(), 503]);

    // Serial on purpose. The claims below are about drain SHAPE — which
    // message the 503 lands on, and that exactly two sockets were opened —
    // and both need the requests to go out one at a time. What a park does
    // with three requests already in flight is `triage_queue_test.dart`'s
    // job, and it owns that coverage.
    await TriageQueue(store, client, userAddress: loAddress, concurrency: 1)
        .pump();

    expect((await messageRow(ungated.first.id))['triage_status'], 'triaged');

    // Nothing was wrong with this message, so it goes back to the queue
    // whole — and the drain stops rather than marking every message behind it
    // against a server that is seconds from healthy.
    final parked = await messageRow(ungated[1].id);
    expect(parked['triage_status'], 'pending');
    expect(parked['triage_attempts'], 0);

    for (final entry in ungated.skip(2)) {
      final row = await messageRow(entry.id);
      expect(row['triage_status'], 'pending', reason: entry.id);
      expect(row['triage_attempts'], 0, reason: entry.id);
    }

    // One answered, one refused, and then nothing.
    expect(fake.requests.length, 2);
  });
}
