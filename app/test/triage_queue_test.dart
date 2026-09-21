import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// A [ScriptedLlm] that answers the triage schema from a script and never
/// opens a socket.
///
/// It records concurrency as well as calls: how many requests the drain has in
/// flight is the number this phase is about, and a fake that only counted
/// calls could not tell a serial drain from a three-at-a-time one. Both
/// numbers are `maxInFlight` and `userMessages` on the shared fixture.
///
/// [TriageQueue] runs one task, so one schema name carries the whole script.
/// A request that has to be HELD open while the drain gets on with the others
/// is a COMPUTED step returning a completer's future — see [heldAnswer].
ScriptedLlm fakeLlm(List<Object> script) =>
    ScriptedLlm()..scriptFor('triage', script);

/// A step that answers with whatever [held] is eventually completed with,
/// which is how a request stays at the server while the drain launches its
/// siblings.
Future<Map<String, dynamic>> Function(LlmCall) heldAnswer(
        Completer<Map<String, dynamic>> held) =>
    (_) => held.future;

/// Stands in for `MailSync.ensureMessageBody`: records what it was asked for
/// and writes the detail a real Graph fetch would have stored.
class FakeDetailFetch {
  final MessageStore store;
  final String? bodyText;
  final Map<String, String>? headers;

  /// Thrown instead of storing anything — a Graph call that failed.
  final Object? error;

  /// What the real fetch also writes: the attachment rows, before the model is
  /// asked anything. Empty for every test that is not about them.
  final List<Map<String, Object?>> attachments;

  final List<String> fetched = [];

  FakeDetailFetch(
    this.store, {
    this.bodyText,
    this.headers,
    this.error,
    this.attachments = const [],
  });

  Future<void> call(String sourceMessageId) async {
    fetched.add(sourceMessageId);
    // A real fetch suspends, and the queue must await this one before it
    // reads the row back.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final failure = error;
    if (failure != null) throw failure;
    await store.updateMessageDetail(
      'email',
      sourceMessageId,
      bodyText: bodyText,
      sourceMetaJson:
          headers == null ? null : jsonEncode({'headers': headers}),
    );
    if (attachments.isNotEmpty) {
      await store.upsertAttachments('email', sourceMessageId, attachments);
    }
  }
}

/// A [DrainGate] that records every ask for a yield. The ask is what this
/// queue does on behalf of a waiting message, and the flag itself is cleared
/// by the very run the ask precedes, so counting the calls is the only way to
/// see it from outside.
class _RecordingGate extends DrainGate {
  int asks = 0;

  @override
  void requestYield() {
    asks++;
    super.requestYield();
  }
}

Map<String, dynamic> answer({
  String urgency = 'high',
  String category = 'work',
  String summary = 'Jordan asks about the launch date.',
  bool needsAction = true,
  List<String> actionItems = const ['Call Sarah about the lock'],
  bool replyExpected = false,
  String deadline = '',
}) =>
    {
      'urgency': urgency,
      'category': category,
      'summary': summary,
      'needs_action': needsAction,
      'action_items': actionItems,
      'reply_expected': replyExpected,
      'deadline': deadline,
    };

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// [source] defaults to email because most of this file is about the drain
  /// rather than the channel; a chat row is the same seed with the columns a
  /// chat actually has — no subject, a `teams:` pseudo-address, and never any
  /// headers.
  Future<void> seedMessage({
    required String id,
    String source = 'email',
    String conversationKey = 'conv-1',
    String direction = 'inbound',
    String? from = 'sarah@example.com',
    String? subject = 'Launch date',
    String receivedAt = '2026-08-29T10:00:00Z',
    String triageStatus = 'pending',
    // False is what a message looks like straight off a delta page: a
    // preview, and no body until something fetches its detail.
    bool withBody = true,
    String? bodyText,
    String? bodyPreview,
    Map<String, String>? headers,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': subject,
      'from_name': 'Sarah',
      'from_address': from,
      'received_at': receivedAt,
      'body_preview': bodyPreview,
      'body_text': withBody ? (bodyText ?? 'Body of $id') : null,
      'source_meta_json':
          headers == null ? null : jsonEncode({'headers': headers}),
      'triage_status': triageStatus,
    });
  }

  Future<void> seedChat({
    required String id,
    String conversationKey = 'chat-1',
    String direction = 'inbound',
    String receivedAt = '2026-08-29T10:00:00Z',
    String triageStatus = 'pending',
    bool withBody = true,
    String? bodyText,
  }) =>
      seedMessage(
        id: id,
        source: 'teams',
        conversationKey: conversationKey,
        direction: direction,
        from: 'teams:u1',
        subject: null,
        receivedAt: receivedAt,
        triageStatus: triageStatus,
        withBody: withBody,
        bodyText: bodyText,
      );

  Future<void> seedConversation({
    String key = 'conv-1',
    String source = 'email',
    String? lastInboundAt = '2026-08-29T10:00:00Z',
    String? lastOutboundAt,
    String state = 'needs_reply',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': 'Launch date',
      'state': state,
      'last_inbound_at': lastInboundAt,
      'last_outbound_at': lastOutboundAt,
      'last_message_at': lastOutboundAt ?? lastInboundAt,
    });
  }

  Future<Map<String, Object?>> messageRow(String id,
          {String source = 'email'}) async =>
      (await store.getMessageRow(source, id))!;

  Future<Map<String, Object?>> conversationRow([String key = 'conv-1']) async =>
      (await store.getConversationRow('email', key))!;

  group('drain', () {
    test('a second pump does not start a racing drain', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      await seedMessage(id: 'm3', receivedAt: '2026-08-29T12:00:00Z');
      final llm = fakeLlm([answer()]);
      final queue = TriageQueue(store, llm);

      // Two pumps started together: the second must find the first running
      // and return rather than race it.
      await Future.wait([queue.pump(), queue.pump()]);

      // Three messages, three requests, and never more than one drain's worth
      // in flight. A second drain would have shown up as either extra calls or
      // a ceiling above the one queue's concurrency.
      expect(llm.userMessages.length, 3);
      expect(llm.maxInFlight, lessThanOrEqualTo(3));
    });

    test('two drains over one backlog take every message exactly once',
        () async {
      // A thread each, so "who asked for m5's body" has exactly one answer:
      // on one shared thread every message quotes the ones before it, and the
      // per-body count below could not tell a second claim from a quote.
      for (var i = 0; i < 9; i++) {
        await seedMessage(
          id: 'm$i',
          conversationKey: 'conv-$i',
          receivedAt: '2026-08-29T1$i:00:00Z',
        );
      }
      // Two queues rather than two pumps of one: the `_running` flag guards a
      // queue against itself, and each queue carries its own [DrainGate], so
      // these two drains genuinely overlap. It is the case the atomic claim
      // exists for — choosing a message and writing its `processing` are one
      // statement, so whichever claim lands second cannot be handed a row the
      // first already took.
      final first = fakeLlm([answer()]);
      final second = fakeLlm([answer()]);

      await Future.wait([
        TriageQueue(store, first).pump(),
        TriageQueue(store, second).pump(),
      ]);

      final asked = [...first.userMessages, ...second.userMessages];
      expect(asked.length, 9);
      for (var i = 0; i < 9; i++) {
        expect(
          asked.where((user) => user.contains('Body of m$i')).length,
          1,
          reason: 'm$i',
        );
      }
      expect(
        await store.triageCounts(sources: const ['email']),
        {'triaged': 9},
      );
    });

    test('a backlog runs three at a time', () async {
      for (var i = 0; i < 10; i++) {
        await seedMessage(id: 'm$i', receivedAt: '2026-08-29T${10 + i}:00:00Z');
      }
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      // The whole point of the phase: a backlog keeps three requests batched
      // at the server instead of leaving it idle between messages.
      expect(llm.maxInFlight, 3);
      expect(llm.userMessages.length, 10);
      expect(await store.triageCounts(sources: const ['email']), {'triaged': 10});
    });

    test('concurrency 1 is still available, and is still serial', () async {
      for (var i = 0; i < 10; i++) {
        await seedMessage(id: 'm$i', receivedAt: '2026-08-29T${10 + i}:00:00Z');
      }
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm, concurrency: 1).pump();

      // Not a vestige: the tests whose assertions are about request ORDER run
      // this way, and so would a machine whose server has one slot.
      expect(llm.maxInFlight, 1);
      expect(await store.triageCounts(sources: const ['email']), {'triaged': 10});
    });

    test('takes the newest message first', () async {
      await seedMessage(id: 'old', subject: 'Oldest', receivedAt: '2026-08-27T10:00:00Z');
      await seedMessage(id: 'new', subject: 'Newest', receivedAt: '2026-08-29T10:00:00Z');
      await seedMessage(id: 'mid', subject: 'Middle', receivedAt: '2026-08-28T10:00:00Z');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(
        [
          for (final user in llm.userMessages)
            if (user.contains('Subject: Newest'))
              'Newest'
            else if (user.contains('Subject: Middle'))
              'Middle'
            else
              'Oldest',
        ],
        ['Newest', 'Middle', 'Oldest'],
      );
    });

    test('stops when nothing is pending, having called nothing', () async {
      await seedMessage(id: 'm1', triageStatus: 'triaged');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
    });
  });

  group('gates', () {
    test('a gated message is skipped without reaching the model', () async {
      await seedMessage(id: 'm1', from: 'no-reply@bank.com');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'no_reply');
    });

    test('a drop rule gates at tier one, under its own reason', () async {
      // Data, not a pattern: the address is an ordinary human one and only
      // the owner's standing rule says anything about it.
      await seedMessage(id: 'm1', from: 'dana@example.com');
      await store.setSenderPref('dana@example.com', 'drop');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'sender_rule');
    });

    test('a restored message from a dropped sender still reaches the model',
        () async {
      // Restore is the escape hatch from EVERY gate, and the sender rule is
      // one of them: the owner pulling one message back outranks their own
      // standing rule about the address it came from.
      await seedMessage(id: 'm1', from: 'dana@example.com');
      await store.setSenderPref('dana@example.com', 'drop');
      await store.restoreMessage('email', 'm1');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, hasLength(1));
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });

    test('the self gate uses the address set after sign-in', () async {
      await seedMessage(id: 'm1', from: 'lo@bond.com');
      final llm = fakeLlm([answer()]);
      final queue = TriageQueue(store, llm)..userAddress = 'LO@bond.com';

      await queue.pump();

      expect(llm.userMessages, isEmpty);
      expect((await messageRow('m1'))['gate_reason'], 'self');
    });

    test('a sender gate folds the thread back to waiting', () async {
      // The fold at ingest reads only kept messages, and this one was kept
      // until the claim. Nothing else would ever tell the thread that the
      // message it is waiting on will never reach a model.
      await seedConversation();
      await seedMessage(id: 'm1', from: 'no-reply@bank.com');

      await TriageQueue(store, fakeLlm([answer()])).pump();

      expect((await conversationRow())['state'], 'waiting');
    });

    test('a gate on one message leaves a thread with a kept newer inbound '
        'alone', () async {
      await seedConversation(lastInboundAt: '2026-08-29T12:00:00Z');
      await seedMessage(
        id: 'bulk',
        from: 'no-reply@bank.com',
        receivedAt: '2026-08-29T11:00:00Z',
      );
      await seedMessage(id: 'real', receivedAt: '2026-08-29T12:00:00Z');

      await TriageQueue(store, fakeLlm([answer()])).pump();

      // One direction, and only when nothing kept is left: the newer message
      // is still somebody's question.
      expect((await conversationRow())['state'], 'needs_reply');
    });

    test('a gated message does not stop the drain behind it', () async {
      await seedMessage(
        id: 'bulk',
        from: 'noreply@bank.com',
        receivedAt: '2026-08-29T12:00:00Z',
      );
      await seedMessage(id: 'real', receivedAt: '2026-08-29T11:00:00Z');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 1);
      expect((await messageRow('real'))['triage_status'], 'triaged');
    });
  });

  /// The knock the queue gives the gate repair, at both tiers.
  ///
  /// What it is for is elsewhere — see `gate_repair_service_test.dart`. What
  /// is pinned here is only that the queue calls it, once, on a verdict rather
  /// than on a pass through the model, and that the verdict is on the row by
  /// the time it does.
  group('onGated', () {
    test('a sender gate tells it, with the verdict already written', () async {
      await seedMessage(id: 'm1', from: 'noreply@example.com');
      final gated = <(String, String)>[];
      final statusInside = <Object?>[];

      await TriageQueue(
        store,
        fakeLlm([answer()]),
        onGated: (source, id) async {
          gated.add((source, id));
          statusInside.add((await messageRow(id))['triage_status']);
        },
      ).pump();

      expect(gated, [('email', 'm1')]);
      // Before the progress emit, which is what "already written" buys: the
      // reload the rails do behind that tick reads the repaired state.
      expect(statusInside, ['skipped']);
    });

    test('a header gate tells it too', () async {
      await seedMessage(
        id: 'm1',
        withBody: false,
        bodyPreview: 'This week in rates',
      );
      final fetch = FakeDetailFetch(
        store,
        bodyText: 'Body',
        headers: const {'list-unsubscribe': '<mailto:stop@example.com>'},
      );
      final gated = <(String, String)>[];

      await TriageQueue(
        store,
        fakeLlm([answer()]),
        ensureBody: fetch.call,
        onGated: (source, id) async => gated.add((source, id)),
      ).pump();

      expect((await messageRow('m1'))['gate_reason'], 'newsletter');
      expect(gated, [('email', 'm1')]);
    });

    test('a message that reaches the model is not a gate', () async {
      await seedMessage(id: 'm1');
      final gated = <(String, String)>[];

      await TriageQueue(
        store,
        fakeLlm([answer()]),
        onGated: (source, id) async => gated.add((source, id)),
      ).pump();

      expect((await messageRow('m1'))['triage_status'], 'triaged');
      expect(gated, isEmpty);
    });

    test('a callback that throws does not cost the drain its verdict',
        () async {
      await seedMessage(id: 'm1', from: 'noreply@example.com');
      await seedMessage(
        id: 'm2',
        conversationKey: 'conv-2',
        receivedAt: '2026-08-29T09:00:00Z',
      );

      await TriageQueue(
        store,
        fakeLlm([answer()]),
        onGated: (source, id) async => throw StateError('repair is down'),
      ).pump();

      expect((await messageRow('m1'))['triage_status'], 'skipped');
      // And the message behind it is still triaged: the callback's failure is
      // not the drain's.
      expect((await messageRow('m2'))['triage_status'], 'triaged');
    });
  });

  /// A failed detail fetch on a machine-shaped sender, which is the one shape
  /// of degraded fetch where classifying from the preview throws away the
  /// verdict that mattered: the header gates would have caught exactly this
  /// mail, and they have nothing to read.
  group('headerless defer', () {
    /// A no-headers message from a machine mailbox no gate deliberately
    /// catches — `alerts` is prefix-anchored — plus a fetch that always fails.
    Future<FakeDetailFetch> seedDeferrable({
      String id = 'm1',
      String from = 'prod-alerts@example.com',
    }) async {
      await seedMessage(id: id, from: from, bodyText: 'Disk usage at 91%.');
      return FakeDetailFetch(store, error: Exception('graph down'));
    }

    /// The newest `triage` row with this status, as its raw columns plus its
    /// decoded detail. Raw rather than [ActivityEvent] because this file
    /// imports `database.dart`, whose generated row class owns that name.
    Future<Map<String, Object?>> triageRow(String status) async {
      final row = (await store.recentActivity(limit: 20)).firstWhere(
        (r) => r['kind'] == 'triage' && r['status'] == status,
      );
      return {
        ...row,
        'detail': jsonDecode(row['detail_json'] as String) as Map,
      };
    }

    test('two drains defer, the third classifies headerless', () async {
      final fetch = await seedDeferrable();
      final llm = fakeLlm([answer()]);
      final log = ActivityLog(store);
      addTearDown(log.dispose);
      TriageQueue queue() => TriageQueue(
            store,
            llm,
            ensureBody: fetch.call,
            activityLog: log,
          );

      await queue().pump();

      var row = await messageRow('m1');
      expect(row['triage_status'], 'pending');
      expect(row['triage_attempts'], 1);
      expect(llm.userMessages, isEmpty, reason: 'nothing was classified yet');
      expect(fetch.fetched, ['m1'], reason: 'one fetch, not a tight loop');
      final retry = await triageRow('retry');
      expect(retry['entity_id'], 'm1');
      final detail = retry['detail'] as Map;
      expect(detail['reason'], 'headerless');
      expect(detail['attempts'], 1);

      await queue().pump();

      row = await messageRow('m1');
      expect(row['triage_status'], 'pending');
      expect(row['triage_attempts'], 2);
      expect(llm.userMessages, isEmpty);

      await queue().pump();

      // Bounded means bounded: at the ceiling the message is classified from
      // its preview with no headers, exactly as it always was.
      row = await messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['triage_attempts'], 2);
      expect(llm.userMessages.length, 1);
    });

    test('a drain stops claiming once it has set aside the store\'s cap',
        () async {
      // One more deferrable message than `claimPendingTriage` will exclude.
      // Past the cap the newest set-aside row would be handed straight back
      // and its second attempt spent in this drain — so the drain stops.
      const cap = MessageStore.maxTriageExclusions;
      for (var i = 0; i <= cap; i++) {
        await seedMessage(
          id: 'm$i',
          conversationKey: 'conv-$i',
          from: 'prod-alerts@example.com',
          receivedAt: '2026-08-29T10:${i.toString().padLeft(2, '0')}:00Z',
          bodyText: 'Disk usage at 91%.',
        );
      }
      final fetch = FakeDetailFetch(store, error: Exception('graph down'));
      final llm = fakeLlm([answer()]);

      // Concurrency 1 makes the count exact. With more, the claims already in
      // flight when the cap is reached defer too — still one attempt each and
      // never re-claimed, only more of them.
      await TriageQueue(store, llm, ensureBody: fetch.call, concurrency: 1)
          .pump();

      var deferred = 0;
      var untouched = 0;
      for (var i = 0; i <= cap; i++) {
        final row = await messageRow('m$i');
        expect(row['triage_status'], 'pending');
        switch ((row['triage_attempts'] as num).toInt()) {
          case 1:
            deferred++;
          case 0:
            untouched++;
          default:
            fail('m$i spent a second attempt in one drain');
        }
      }
      expect(deferred, cap);
      expect(untouched, 1, reason: 'the oldest waits for the next pump');
      expect(fetch.fetched.length, cap, reason: 'one fetch per deferral');
      expect(llm.userMessages, isEmpty);
    });

    test('a person is classified headerless on the first failure', () async {
      final fetch = await seedDeferrable(from: 'sarah@example.com');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      // The deferral is about the gates that never got to speak, and no gate
      // was ever going to fire on a colleague.
      expect((await messageRow('m1'))['triage_status'], 'triaged');
      expect(llm.userMessages.length, 1);
    });

    test('the message behind a deferred one is still triaged in that drain',
        () async {
      // The machine one is NEWER, so it is what the claim's ordering hands
      // back first — and would keep handing back, without the exclusion.
      final fetch = FakeDetailFetch(store, error: Exception('graph down'));
      await seedMessage(
        id: 'machine',
        from: 'prod-alerts@example.com',
        receivedAt: '2026-08-29T12:00:00Z',
      );
      await seedMessage(
        id: 'human',
        conversationKey: 'conv-2',
        receivedAt: '2026-08-29T11:00:00Z',
      );
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect((await messageRow('human'))['triage_status'], 'triaged');
      final machine = await messageRow('machine');
      expect(machine['triage_status'], 'pending');
      expect(machine['triage_attempts'], 1);
    });

    test('a chat is never deferred — there is no detail fetch to retry',
        () async {
      await seedChat(id: 'c1', bodyText: 'Deploy finished.');
      final fetch = FakeDetailFetch(store, error: Exception('graph down'));
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, isEmpty);
      expect((await messageRow('c1', source: 'teams'))['triage_status'],
          'triaged');
    });
  });

  /// The owner's override, at both tiers.
  ///
  /// A gate is a judgement the claim re-derives every time, so clearing a
  /// `gate_reason` is not enough to bring a message back — the next claim
  /// would reach the same verdict. These pin that the stamp outranks it.
  group('gate override', () {
    test('a restored message reaches the model past the sender gate',
        () async {
      await seedMessage(id: 'm1', from: 'no-reply@example.com');
      await store.restoreMessage('email', 'm1');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 1);
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });

    test('the same message without the stamp is still gated', () async {
      // The other direction, spelled here rather than leaned on: the seed
      // above is only evidence about the override if this one is evidence
      // that the gate would otherwise have fired on it. (`a gated message is
      // skipped without reaching the model` pins the same rule for
      // `no-reply@bank.com`.)
      await seedMessage(id: 'm1', from: 'no-reply@example.com');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'no_reply');
    });

    test('a restored message survives the header gate after its fetch',
        () async {
      await seedMessage(
        id: 'm1',
        withBody: false,
        bodyPreview: 'This week in rates',
      );
      await store.restoreMessage('email', 'm1');
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(
        store,
        bodyText: 'Body',
        headers: const {'list-unsubscribe': '<mailto:stop@example.com>'},
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      // The fetch still happens — the override is about the verdict, not
      // about skipping the work that informs it — and the newsletter gate
      // that fired on exactly these headers a test ago does not.
      expect(fetch.fetched, ['m1']);
      expect(llm.userMessages.length, 1);
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });
  });

  group('two-tier fetch', () {
    test('a bodyless message is fetched before the model sees it', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(
        store,
        bodyText: 'The full unquoted body, all of it.',
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, ['m1']);
      // The ordering that matters: the model was called with what the fetch
      // stored, not with the preview the delta page carried.
      expect(llm.userMessages.single, contains('The full unquoted body'));
      expect(llm.userMessages.single, isNot(contains('Short preview')));
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });

    test('headers from the fetch let the newsletter gate fire', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'This week in rates');
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(
        store,
        bodyText: 'Body',
        headers: const {'list-unsubscribe': '<mailto:stop@news.com>'},
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      // Fetched, then gated on what the fetch brought back — so the gates
      // demonstrably re-run against the reloaded row.
      expect(fetch.fetched, ['m1']);
      expect(llm.userMessages, isEmpty);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'newsletter');
    });

    test('a header gate folds the thread back to waiting', () async {
      // Tier two, where the gate has headers to read for the first time — the
      // thread has to hear about a drop there exactly as it does at tier one.
      await seedConversation();
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'This week');
      final fetch = FakeDetailFetch(
        store,
        bodyText: 'Body',
        headers: const {'list-unsubscribe': '<mailto:stop@news.example.com>'},
      );

      await TriageQueue(store, fakeLlm([answer()]), ensureBody: fetch.call)
          .pump();

      expect((await messageRow('m1'))['gate_reason'], 'newsletter');
      expect((await conversationRow())['state'], 'waiting');
    });

    test('a sender gate skips the fetch entirely', () async {
      await seedMessage(id: 'm1', from: 'no-reply@bank.com', withBody: false);
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      // The whole economic point of running the address gates first.
      expect(fetch.fetched, isEmpty);
      expect(llm.userMessages, isEmpty);
      expect((await messageRow('m1'))['gate_reason'], 'no_reply');
    });

    test('the self gate skips the fetch too', () async {
      await seedMessage(id: 'm1', from: 'lo@bond.com', withBody: false);
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      final queue = TriageQueue(store, llm, ensureBody: fetch.call)
        ..userAddress = 'lo@bond.com';
      await queue.pump();

      expect(fetch.fetched, isEmpty);
      expect((await messageRow('m1'))['gate_reason'], 'self');
    });

    test('a failed fetch degrades to the preview instead of parking', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(
        store,
        error: StateError('Graph is having a moment'),
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, ['m1']);
      expect(llm.userMessages.single, contains('Short preview'));
      final row = await messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['triage_attempts'], 0);
    });

    test('a dead session parks the drain instead of degrading', () async {
      await seedMessage(
        id: 'm1',
        withBody: false,
        bodyPreview: 'Short preview',
        receivedAt: '2026-08-29T12:00:00Z',
      );
      await seedMessage(
        id: 'm2',
        withBody: false,
        bodyPreview: 'Another preview',
        receivedAt: '2026-08-29T11:00:00Z',
      );
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, error: const NotSignedIn());

      // Serial: this asserts that m2's fetch was never ATTEMPTED, which is a
      // claim about what the drain does after the park rather than about what
      // it had already sent.
      await TriageQueue(store, llm, ensureBody: fetch.call, concurrency: 1)
          .pump();

      // The session is over, so triaging m1 from its preview would be model
      // time spent on an answer the next sign-in could have done properly —
      // and m2 would fail identically.
      expect(fetch.fetched, ['m1']);
      expect(llm.userMessages, isEmpty);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'pending');
      expect(row['triage_attempts'], 0);
      expect((await messageRow('m2'))['triage_status'], 'pending');
    });

    test('missing consent parks the drain the same way', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, error: const ReconsentRequired());

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(llm.userMessages, isEmpty);
      expect((await messageRow('m1'))['triage_status'], 'pending');
    });

    test('a generic auth wobble still degrades to the preview', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = fakeLlm([answer()]);
      // Not NotSignedIn and not ReconsentRequired: a 5xx or an offline
      // laptop, which the session survives.
      final fetch = FakeDetailFetch(
        store,
        error: const AuthException('Microsoft is having a moment'),
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(llm.userMessages.single, contains('Short preview'));
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });

    test('a message that already has body and headers is not refetched',
        () async {
      await seedMessage(
        id: 'm1',
        headers: const {'received': 'from mail.example.com'},
      );
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, isEmpty);
      expect(llm.userMessages.length, 1);
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });

    test('with no fetcher wired, triage runs on whatever is stored', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.single, contains('Short preview'));
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });
  });

  group('chats', () {
    test('a chat is claimed and triaged like mail, and stays a chat', () async {
      await seedChat(id: 'c1', bodyText: 'Can you send the CD today?');
      final llm = fakeLlm([answer()]);
      final log = ActivityLog(store);
      addTearDown(log.dispose);

      await TriageQueue(store, llm, activityLog: log).pump();

      expect(llm.userMessages.single, contains('Can you send the CD today?'));
      final row = await messageRow('c1', source: 'teams');
      expect(row['triage_status'], 'triaged');
      expect(row['urgency'], 'high');
      // Every write the drain makes is keyed `(source, id)`, so a source read
      // off the wrong place would silently update nothing at all.
      final event = (await store.recentActivity())
          .firstWhere((r) => r['kind'] == 'triage');
      expect(event['source'], 'teams');
      expect(event['entity_id'], 'c1');
    });

    test('a file-only chat message reaches the model as what was shared',
        () async {
      // Somebody dropped a contract into a thread and typed nothing with it.
      // The body IS the marker, so a handler that builds its message from a
      // bare row sends the model a blank message about a file it never hears
      // of.
      await seedChat(id: 'c1', bodyText: '[[att:a1]]');
      await store.upsertAttachments('teams', 'c1', [
        {
          'attachment_id': 'a1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'Contract-v2.docx',
          'size': 0,
        },
      ]);
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.single, contains('Shared a file: Contract-v2.docx'));
      expect(llm.userMessages.single, isNot(contains('[[att:')));
    });

    test('a chat never asks for a mail detail fetch', () async {
      // Body stored, headers absent — which for a chat is not "detail is
      // missing" but "this source has no such thing": `source_meta_json` is
      // the mail sync's column. An unguarded fetch fires on every chat and can
      // only fail.
      await seedChat(id: 'c1');
      // The control, and the proof the fetcher is live: a bodyless mail row
      // beside it, which does get fetched.
      await seedMessage(
        id: 'm1',
        receivedAt: '2026-08-29T09:00:00Z',
        withBody: false,
        bodyPreview: 'Short preview',
      );
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'The full body');

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, ['m1']);
      expect((await messageRow('c1', source: 'teams'))['triage_status'],
          'triaged');
    });

    test('a chat that stripped down to nothing is gated, not modelled',
        () async {
      // What a lone emoji reaction or an image-only post leaves behind.
      await seedChat(id: 'c1', withBody: false);
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
      final row = await messageRow('c1', source: 'teams');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'empty');
    });

    test('the fold-up lands on the chat’s own conversation', () async {
      await seedConversation(key: 'chat-1', source: 'teams');
      // Same conversation_key under email, to catch a fold-up that writes the
      // right key against the wrong source.
      await seedConversation(key: 'chat-1');
      await seedChat(id: 'c1');
      final llm = fakeLlm([
        answer(urgency: 'urgent', actionItems: const ['Send the CD']),
      ]);

      await TriageQueue(store, llm).pump();

      final chat = (await store.getConversationRow('teams', 'chat-1'))!;
      expect(chat['cta_text'], 'Send the CD');
      expect(chat['cta_urgency'], 'urgent');
      expect((await store.getConversationRow('email', 'chat-1'))!['cta_text'],
          isNull);
    });

    test('one drain empties both sources, newest first', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T09:00:00Z');
      await seedChat(id: 'c1', receivedAt: '2026-08-29T11:00:00Z');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm, concurrency: 1).pump();

      expect(llm.userMessages.length, 2);
      expect(llm.userMessages.first, contains('Body of c1'));
      expect(await store.triageCounts(sources: TriageQueue.sources),
          {'triaged': 2});
    });

    test('resetInterrupted frees a claimed chat too', () async {
      await seedChat(id: 'c1', triageStatus: 'processing');
      await seedMessage(id: 'm1', triageStatus: 'processing');

      await TriageQueue(store, fakeLlm([answer()])).resetInterrupted();

      expect((await messageRow('c1', source: 'teams'))['triage_status'],
          'pending');
      expect((await messageRow('m1'))['triage_status'], 'pending');
    });
  });

  group('thread context', () {
    test('the judged message carries what came before it on its thread',
        () async {
      await seedMessage(
        id: 'first',
        receivedAt: '2026-08-29T09:00:00Z',
        bodyText: 'Can you still make Thursday?',
      );
      await seedMessage(
        id: 'second',
        receivedAt: '2026-08-29T10:00:00Z',
        bodyText: 'Any word on that?',
      );
      final llm = fakeLlm([answer()]);

      // Serial, because the assertion is about WHICH request carried what:
      // newest first, so `second` goes out before `first`.
      await TriageQueue(store, llm, concurrency: 1).pump();

      final judgingSecond = llm.userMessages.first;
      expect(judgingSecond, contains('<untrusted_data source="thread">'));
      // The earlier message is quoted as context — this is what lets the model
      // see that a question a message back never got answered.
      expect(
        judgingSecond.indexOf('Can you still make Thursday?'),
        lessThan(judgingSecond.indexOf('Judge ONLY this message:')),
      );
      expect(
        judgingSecond.indexOf('Any word on that?'),
        greaterThan(judgingSecond.indexOf('Judge ONLY this message:')),
      );
    });

    test('triage sends the thread tail and never a digest', () async {
      // The context ladder measured on 2026-09-16/17 left triage exactly here:
      // the newest three turns verbatim, and no `thread_digest` fence. The
      // prompt field still exists and `TriageTask` still renders it, so this
      // pins that the QUEUE never fills it in.
      await seedMessage(
        id: 'earlier',
        receivedAt: '2026-08-29T09:00:00Z',
        bodyText: 'The dock survey is booked for Tuesday.',
      );
      await seedMessage(
        id: 'latest',
        receivedAt: '2026-08-29T10:00:00Z',
        bodyText: 'Did the surveyor confirm?',
      );
      final llm = fakeLlm([answer()]);

      // Serial, so the first request out is the one judging `latest`.
      await TriageQueue(store, llm, concurrency: 1).pump();

      final judgingLatest = llm.userMessages.first;
      expect(judgingLatest, contains('<untrusted_data source="thread">'));
      expect(judgingLatest, contains('The dock survey is booked for Tuesday.'));
      expect(judgingLatest, isNot(contains('thread_digest')));
    });

    test('the oldest message on a thread has no thread to quote', () async {
      await seedMessage(
        id: 'first',
        receivedAt: '2026-08-29T09:00:00Z',
        bodyText: 'Can you still make Thursday?',
      );
      await seedMessage(
        id: 'second',
        receivedAt: '2026-08-29T10:00:00Z',
        bodyText: 'Any word on that?',
      );
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm, concurrency: 1).pump();

      // Only what came BEFORE: a later message is not context for a judgement
      // about an earlier one.
      final judgingFirst = llm.userMessages.last;
      expect(judgingFirst, isNot(contains('source="thread"')));
      expect(judgingFirst, isNot(contains('Any word on that?')));
    });

    test('a thread of one — the message itself is never its own context',
        () async {
      await seedMessage(id: 'm1', bodyText: 'The only message.');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.single, isNot(contains('source="thread"')));
      expect('The only message.'.allMatches(llm.userMessages.single).length, 1);
    });

    test('a chat quotes its own thread and not the mail sharing its key',
        () async {
      await seedChat(
        id: 'c1',
        receivedAt: '2026-08-29T09:00:00Z',
        bodyText: 'Did the CD go out?',
      );
      await seedChat(
        id: 'c2',
        receivedAt: '2026-08-29T10:00:00Z',
        bodyText: 'Bumping this.',
      );
      // Same conversation_key under email, to catch a thread load that reads
      // the right key against the wrong source.
      await seedMessage(
        id: 'm1',
        conversationKey: 'chat-1',
        receivedAt: '2026-08-29T08:00:00Z',
        bodyText: 'A mail that merely shares the key.',
        triageStatus: 'triaged',
      );
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm, concurrency: 1).pump();

      final judgingC2 = llm.userMessages.first;
      expect(judgingC2, contains('Did the CD go out?'));
      expect(judgingC2, isNot(contains('A mail that merely shares the key.')));
    });
  });

  group('attachments', () {
    test('the names and sizes reach the model beside the message', () async {
      await seedMessage(id: 'm1');
      await store.upsertAttachments('email', 'm1', [
        {
          'attachment_id': 'att-1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'lease-addendum.pdf',
          'content_type': 'application/pdf',
          'size': 184320,
          'is_inline': false,
        },
      ]);
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.single, contains('Attachments: '));
      expect(llm.userMessages.single, contains('lease-addendum.pdf (180 KB)'));
    });

    test('the detail fetch writes them before the model is asked', () async {
      // The ordering the whole line depends on: `_triageClaimed` calls
      // `ensureBody` inside the claim, so a mail attachment is on the row by
      // the time the prompt is built.
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short');
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(
        store,
        bodyText: 'Signed copy attached.',
        attachments: const [
          {
            'attachment_id': 'att-1',
            'ordinal': 0,
            'kind': 'file',
            'name': 'lease-addendum.pdf',
            'content_type': 'application/pdf',
            'size': 184320,
            'is_inline': false,
          },
        ],
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, ['m1']);
      expect(llm.userMessages.single, contains('lease-addendum.pdf'));
    });

    test('a failed fetch costs the line, never the triage', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = fakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, error: StateError('graph is down'));

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(llm.userMessages.single, isNot(contains('Attachments:')));
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });

    test('a message with nothing attached says nothing', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.single, isNot(contains('Attachments:')));
    });
  });

  group('results', () {
    test('a success writes every result column', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        answer(
          urgency: 'urgent',
          category: 'work',
          summary: 'Marisa needs the final copy today.',
          actionItems: const ['Send the final copy', 'Call Marisa'],
        ),
      ]);

      await TriageQueue(store, llm).pump();

      final row = await messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['urgency'], 'urgent');
      expect(row['category'], 'work');
      expect(row['summary'], 'Marisa needs the final copy today.');
      expect(row['needs_action'], 1);
      expect(
        jsonDecode(row['action_items_json'] as String),
        ['Send the final copy', 'Call Marisa'],
      );
    });

    test('reply_expected reaches the row, so a NULL becomes a judgement',
        () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([answer(replyExpected: true, deadline: 'Friday')]);

      await TriageQueue(store, llm).pump();

      final row = await messageRow('m1');
      // 0/1, because STRICT sqlite has no bool — and the point is that it is
      // no longer NULL: something has now judged this message.
      expect(row['reply_expected'], 1);
      expect(row['deadline'], 'Friday');
    });

    test('a nonsense answer is clamped rather than stored raw', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        {
          'urgency': 'CRITICAL',
          'category': 'errand',
          'summary': 'x' * 900,
          'needs_action': 'yes',
          'action_items': ['one', 'two', 'three', 'four'],
        },
      ]);

      await TriageQueue(store, llm).pump();

      final row = await messageRow('m1');
      expect(row['urgency'], 'normal');
      expect(row['category'], 'other');
      expect((row['summary'] as String).length, 500);
      expect(row['needs_action'], 0);
      expect((jsonDecode(row['action_items_json'] as String) as List).length, 3);
    });
  });

  group('conversation fold-up', () {
    test('the first action item becomes the thread CTA', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        answer(urgency: 'urgent', actionItems: const ['Send the final invoice']),
      ]);

      await TriageQueue(store, llm).pump();

      final row = await conversationRow();
      expect(row['cta_text'], 'Send the final invoice');
      expect(row['cta_urgency'], 'urgent');
      expect(row['category'], 'work');
    });

    test('with no action items, a needed summary stands in', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        answer(
          summary: 'Sarah is waiting on the lock extension.',
          actionItems: const [],
        ),
      ]);

      await TriageQueue(store, llm).pump();

      expect(
        (await conversationRow())['cta_text'],
        'Sarah is waiting on the lock extension.',
      );
    });

    test('a deadline rides along on the CTA', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        answer(
          actionItems: const ['Send the final invoice'],
          deadline: 'Friday',
        ),
      ]);

      await TriageQueue(store, llm).pump();

      expect(
        (await conversationRow())['cta_text'],
        'Send the final invoice — by Friday',
      );
    });

    test('a CTA with its deadline still fits the cap', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      // An ask already at the cap: appending the deadline must cost the ask
      // its tail rather than push the pair over.
      final llm = fakeLlm([
        answer(actionItems: ['a' * 200], deadline: 'Friday'),
      ]);

      await TriageQueue(store, llm).pump();

      final cta = (await conversationRow())['cta_text'] as String;
      expect(cta.length, 200);
      expect(cta, startsWith('aaa'));
    });

    test('no deadline leaves the ask exactly as the model wrote it', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = fakeLlm([answer(actionItems: const ['Send the invoice'])]);

      await TriageQueue(store, llm).pump();

      expect((await conversationRow())['cta_text'], 'Send the invoice');
    });

    test('a deadline with nothing to hang it on adds no CTA', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        answer(needsAction: false, actionItems: const [], deadline: 'Friday'),
      ]);

      await TriageQueue(store, llm).pump();

      // " — by Friday" on its own is not an ask, and a row showing one would
      // be advertising work the message never asked for.
      expect((await conversationRow())['cta_text'], isNull);
    });

    test('a message that needs nothing leaves no CTA', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        answer(
          urgency: 'low',
          needsAction: false,
          actionItems: const [],
        ),
      ]);

      await TriageQueue(store, llm).pump();

      final row = await conversationRow();
      expect(row['cta_text'], isNull);
      expect(row['cta_urgency'], 'low');
    });

    test('an older message never overwrites the newest inbound message\'s ask',
        () async {
      await seedConversation(lastInboundAt: '2026-08-29T10:00:00Z');
      // Only the older message is pending — the newer one was triaged on a
      // previous run and its CTA is already on the thread.
      await store.updateConversationTriage(
        'email',
        'conv-1',
        ctaText: 'Send the project brief',
        ctaUrgency: 'urgent',
        category: 'work',
      );
      await seedMessage(
        id: 'newest',
        receivedAt: '2026-08-29T10:00:00Z',
        triageStatus: 'triaged',
      );
      await seedMessage(id: 'older', receivedAt: '2026-08-20T09:00:00Z');
      final llm = fakeLlm([
        answer(urgency: 'low', actionItems: const ['Reply about parking']),
      ]);

      await TriageQueue(store, llm).pump();

      expect((await messageRow('older'))['triage_status'], 'triaged');
      final row = await conversationRow();
      expect(row['cta_text'], 'Send the project brief');
      expect(row['cta_urgency'], 'urgent');
    });

    test('an ask the user already answered never comes back as a CTA',
        () async {
      // The resurrection case: the CTA was cleared when the user's reply
      // synced in, then a re-judgment backfill (or an error revive, or a
      // reply that beat the first drain) sends the same inbound message
      // through triage again. The fold must not write the dead ask back —
      // nor the urgency multiplier that would push an answered thread into
      // Needs You.
      await seedConversation(
        lastInboundAt: '2026-08-29T10:00:00Z',
        lastOutboundAt: '2026-08-29T11:00:00Z',
        state: 'waiting',
      );
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      final llm = fakeLlm([
        answer(
          urgency: 'urgent',
          actionItems: const ['Confirm attendance'],
          deadline: 'Friday',
        ),
      ]);

      await TriageQueue(store, llm).pump();

      // The message itself is still judged — its own columns are what the
      // scorer and a future re-judgment read.
      expect((await messageRow('m1'))['triage_status'], 'triaged');
      final row = await conversationRow();
      expect(row['cta_text'], isNull);
      expect(row['cta_urgency'], 'normal');
      expect(row['state'], 'waiting');
    });

    test('a reply at the same instant as the ask still counts as the answer',
        () async {
      // Ties resolve toward the reply, exactly as outboundResolves reads
      // them when it clears the CTA at ingest — the two guards must agree on
      // the boundary or a same-second pair would clear and resurrect in turn.
      await seedConversation(
        lastInboundAt: '2026-08-29T10:00:00Z',
        lastOutboundAt: '2026-08-29T10:00:00Z',
        state: 'waiting',
      );
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      final llm = fakeLlm([
        answer(actionItems: const ['Confirm attendance']),
      ]);

      await TriageQueue(store, llm).pump();

      expect((await conversationRow())['cta_text'], isNull);
    });

    test('an ask newer than the last reply still folds up', () async {
      // The inverse must keep working: the user replied, then the sender
      // asked again. That newer ask is unanswered and owns the thread.
      await seedConversation(
        lastInboundAt: '2026-08-29T12:00:00Z',
        lastOutboundAt: '2026-08-29T11:00:00Z',
      );
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T12:00:00Z');
      final llm = fakeLlm([
        answer(actionItems: const ['Send the revised draft']),
      ]);

      await TriageQueue(store, llm).pump();

      expect((await conversationRow())['cta_text'], 'Send the revised draft');
    });

    test('a message with no conversation row folds up into nothing', () async {
      await seedMessage(id: 'm1', conversationKey: 'orphan');
      final llm = fakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect((await messageRow('m1'))['triage_status'], 'triaged');
      expect(await store.getConversationRow('email', 'orphan'), isNull);
    });
  });

  group('failure', () {
    test('a bad answer is retried once, then left as an error', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([const LlmFormatException('not json')]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 2);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'error');
      expect(row['triage_attempts'], 2);
      expect(row['triage_error'], contains('not json'));
    });

    test('a retry that succeeds stores the result', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([const LlmFormatException('not json'), answer()]);

      await TriageQueue(store, llm).pump();

      final row = await messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['triage_attempts'], 1);
    });

    test('a schema 400 is this app\'s bug and is never retried', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        const LlmException('JSON schema conversion failed', 400),
      ]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 1);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'error');
      expect(row['triage_attempts'], 1);
    });

    test('a failure does not stop the drain', () async {
      await seedMessage(id: 'bad', receivedAt: '2026-08-29T12:00:00Z');
      await seedMessage(id: 'good', receivedAt: '2026-08-29T11:00:00Z');
      final llm = fakeLlm([
        const LlmException('boom', 400),
        answer(),
      ]);

      // Serial: which message gets the 400 and which gets the answer is the
      // script's ORDER, and only a one-at-a-time drain pins it.
      await TriageQueue(store, llm, concurrency: 1).pump();

      expect((await messageRow('bad'))['triage_status'], 'error');
      expect((await messageRow('good'))['triage_status'], 'triaged');
    });

    test('a model server that is down costs the message nothing', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T12:00:00Z');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      final llm = fakeLlm([const LlmUnavailableException('not reachable')]);

      // Serial: the assertion is that exactly one call went out, which is a
      // claim about the launch AFTER the park. The concurrent case — a park
      // arriving with siblings already at the server — is the next test.
      await TriageQueue(store, llm, concurrency: 1).pump();

      // One call, then the drain gives up: the second message would have
      // failed identically.
      expect(llm.userMessages.length, 1);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'pending');
      expect(row['triage_attempts'], 0);
      expect((await messageRow('m2'))['triage_status'], 'pending');
    });

    test('a park keeps the requests already in flight and launches no more',
        () async {
      for (var i = 1; i <= 5; i++) {
        await seedMessage(id: 'm$i', receivedAt: '2026-08-29T1$i:00:00Z');
      }
      // Launch order is newest first, so m5, m4 and m3 go out together. m5 and
      // m3 are held open until m4 has found the server gone, which is the
      // state a serial drain can never be in: a park with siblings mid-flight.
      final held = Completer<Map<String, dynamic>>();
      final llm = fakeLlm([
        heldAnswer(held),
        const LlmUnavailableException('not reachable'),
        heldAnswer(held),
      ]);
      final queue = TriageQueue(store, llm);

      final drain = queue.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      held.complete(answer());
      await drain;

      // Three requests, and only three: the park stopped the launcher, so m2
      // and m1 were never claimed.
      expect(llm.userMessages.length, 3);

      // The two that were already at the server were paid for either way, so
      // their answers are kept rather than thrown away with the park.
      expect((await messageRow('m5'))['triage_status'], 'triaged');
      expect((await messageRow('m3'))['triage_status'], 'triaged');

      // Nothing was wrong with any of these three, so none of them spends an
      // attempt — the parked one included.
      for (final id in ['m4', 'm2', 'm1']) {
        final row = await messageRow(id);
        expect(row['triage_status'], 'pending', reason: id);
        expect(row['triage_attempts'], 0, reason: id);
      }
    });

    test('an older message finishing last still loses the fold-up', () async {
      await seedConversation(lastInboundAt: '2026-08-29T12:00:00Z');
      await seedMessage(id: 'newer', receivedAt: '2026-08-29T12:00:00Z');
      await seedMessage(id: 'older', receivedAt: '2026-08-20T09:00:00Z');
      // Both go out at once, and the older one is held open so it folds up
      // LAST. Serially that ordering was impossible; concurrently it is the
      // normal case, and `_foldUp`'s newest-inbound guard is the only thing
      // standing between it and a thread advertising last week's ask.
      final held = Completer<Map<String, dynamic>>();
      final llm = fakeLlm([
        answer(urgency: 'urgent', actionItems: const ['Ship on Thursday']),
        heldAnswer(held),
      ]);

      final drain = TriageQueue(store, llm).pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await conversationRow())['cta_text'], 'Ship on Thursday');
      held.complete(
        answer(urgency: 'low', actionItems: const ['Reply about parking']),
      );
      await drain;

      expect((await messageRow('older'))['triage_status'], 'triaged');
      final row = await conversationRow();
      expect(row['cta_text'], 'Ship on Thursday');
      expect(row['cta_urgency'], 'urgent');
    });

    test('the next pump picks up where a downed server left off', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        const LlmUnavailableException('not reachable'),
        answer(),
      ]);
      final queue = TriageQueue(store, llm);

      await queue.pump();
      expect((await messageRow('m1'))['triage_status'], 'pending');

      await queue.pump();
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });
  });

  group('interruption', () {
    test('resetInterrupted returns a claimed message to the queue', () async {
      await seedMessage(id: 'm1', triageStatus: 'processing');
      await seedMessage(id: 'm2', triageStatus: 'triaged');
      final llm = fakeLlm([answer()]);
      final queue = TriageQueue(store, llm);

      expect(await store.nextPendingTriage(), isNull);
      await queue.resetInterrupted();
      expect(await store.nextPendingTriage(), isNotNull);

      await queue.pump();

      expect((await messageRow('m1'))['triage_status'], 'triaged');
      expect((await messageRow('m2'))['triage_status'], 'triaged');
    });

    test('a message is claimed before the model is called', () async {
      await seedMessage(id: 'm1');
      var statusDuringCall = '';
      final llm = inspectingLlm(() async {
        statusDuringCall = (await messageRow('m1'))['triage_status'] as String;
      });

      await TriageQueue(store, llm).pump();

      expect(statusDuringCall, 'processing');
    });
  });

  group('progress', () {
    test('emits after every message, counting what is left', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T12:00:00Z');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      await seedMessage(id: 'sent', direction: 'outbound', triageStatus: 'skipped');
      final llm = fakeLlm([answer()]);
      // Serial: the emitted numbers are the rows as they stand when each emit
      // reads them, so two messages finishing together legitimately skip a
      // number. What that would test is the scheduler; what this tests is that
      // the count is emitted, and correct, once per message.
      final queue = TriageQueue(store, llm, concurrency: 1);
      final seen = <int>[];
      final subscription = queue.progress.listen((p) => seen.add(p.remaining));

      await queue.pump();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      // Two pending before the first call, then one, then none — the leading
      // emit is what puts a count on screen before the first 17-second wait.
      expect(seen, [2, 1, 0]);
    });

    test('counts are the rows, so done and total add up', () async {
      await seedMessage(id: 'm1');
      await seedMessage(id: 'gated', from: 'noreply@x.com');
      final llm = fakeLlm([answer()]);
      final queue = TriageQueue(store, llm);
      TriageProgress? last;
      final subscription = queue.progress.listen((p) => last = p);

      await queue.pump();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(last!.total, 2);
      expect(last!.done, 2);
      expect(last!.remaining, 0);
      expect(last!.counts, {'triaged': 1, 'skipped': 1});
    });

    test('a park carries its reason, and the next verdict clears it',
        () async {
      // The fact already exists inside the drain; before Round G it died
      // there. No poller: the reason rides the stream the counts already ride,
      // and the next pump is what clears it.
      await seedMessage(id: 'm1');
      final llm = fakeLlm([
        const LlmUnavailableException('down'),
        answer(),
      ]);
      final queue = TriageQueue(store, llm, concurrency: 1);
      final seen = <String?>[];
      final subscription =
          queue.progress.listen((p) => seen.add(p.parkedReason));

      await queue.pump();
      await Future<void>.delayed(Duration.zero);
      expect(seen.last, 'model_unavailable');

      await queue.pump();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(seen.last, isNull);
      expect(seen.first, isNull, reason: 'nothing is parked before the first');
    });

    test('a refused key parks with its own reason', () async {
      await seedMessage(id: 'm1');
      final llm = fakeLlm([const LlmUnauthorizedException('refused')]);
      final queue = TriageQueue(store, llm, concurrency: 1);
      TriageProgress? last;
      final subscription = queue.progress.listen((p) => last = p);

      await queue.pump();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(last!.parkedReason, 'unauthorized');
      // Parked, so the message is still waiting and cost no attempt.
      expect((await messageRow('m1'))['triage_status'], 'pending');
    });
  });

  /// The knock on the AI worker's door. Extraction and needs-you are not
  /// handed a message triage has not spoken about, so a worker drain that won
  /// the shared gate first leaves them pending — this callback is what makes
  /// it walk again once the verdicts are written.
  group('onDrained', () {
    test('fires once after a drain that triaged something', () async {
      await seedMessage(id: 'm1');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      var called = 0;
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        onDrained: (_) async => called++,
      );

      await queue.pump();

      // Once per DRAIN, not once per message: the worker walks its whole
      // queue when it runs, so a second knock would be a second drain over
      // the same rows.
      expect(called, 1);
      expect(await store.triageCounts(), {'triaged': 2});
    });

    test('is not called after a dispose that cut the drain short', () async {
      await seedMessage(id: 'm1');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      var called = 0;
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        concurrency: 1,
        onDrained: (_) async => called++,
      );

      final drain = queue.pump();
      // Torn down while the first message is at the model — waited for on the
      // store, not on a timer, so the claim has really been taken. The verdict
      // it was waiting on still lands — that answer is paid for — but a knock
      // on a worker that has just handed back its own claims would start a
      // drain on a pair the app has already thrown away.
      while ((await store.triageCounts())['processing'] != 1) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await queue.dispose();
      await drain;

      expect(called, 0);
      expect(
        (await store.triageCounts())['triaged'],
        greaterThanOrEqualTo(1),
        reason: 'the in-flight verdict was written; only the knock was held',
      );
    });

    test('fires after a drain that only gated things', () async {
      // A gate is a verdict too, and the items behind it still have to be
      // closed — the handlers write them `done` with a `skipped` note.
      await seedMessage(id: 'm1', from: 'noreply@example.com');
      var called = 0;
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        onDrained: (_) async => called++,
      );

      await queue.pump();

      expect(called, 1);
      expect(await store.triageCounts(), {'skipped': 1});
    });

    test('is not called when nothing was pending', () async {
      var called = 0;
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        onDrained: (_) async => called++,
      );

      await queue.pump();

      expect(called, 0);
    });

    test('is not called when the drain parked', () async {
      // The model server is down. Nothing was decided, so there is nothing
      // for the worker to come and collect — and waking it onto the same dead
      // servers is the last thing that moment needs.
      await seedMessage(id: 'm1');
      var called = 0;
      final queue = TriageQueue(
        store,
        fakeLlm([const LlmUnavailableException('off')]),
        onDrained: (_) async => called++,
      );

      await queue.pump();

      expect(called, 0);
      expect(await store.triageCounts(), {'pending': 1});
    });

    test('is not called when the drain only spent messages into error',
        () async {
      // A 400 is this app's schema being wrong and is fatal on the first
      // attempt, so the message ends `error` inside one drain. That IS a
      // terminal status and the worker may now claim its items — but the
      // knock is deliberately withheld: this drain was failing through the
      // model, and waking a second drain onto the same servers is the last
      // thing that moment needs. The next sync's pump collects the row.
      await seedMessage(id: 'm1');
      var called = 0;
      final queue = TriageQueue(
        store,
        fakeLlm([const LlmException('JSON schema conversion failed', 400)]),
        onDrained: (_) async => called++,
      );

      await queue.pump();

      expect(called, 0);
      expect(await store.triageCounts(), {'error': 1});
    });

    test('a second drain that writes nothing does not knock again', () async {
      await seedMessage(id: 'm1');
      var called = 0;
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        onDrained: (_) async => called++,
      );

      await queue.pump();
      await queue.pump();

      expect(called, 1, reason: 'the counter is reset per drain, not summed');
    });

    test('a callback that throws does not fail the pump', () async {
      await seedMessage(id: 'm1');
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        onDrained: (_) async => throw StateError('the worker blew up'),
      );

      await expectLater(queue.pump(), completes);
      // The verdicts are written and kept: re-running them would cost a
      // second set of model calls for the same answers.
      expect(await store.triageCounts(), {'triaged': 1});
    });

    test('carries the pairs this drain wrote a verdict for', () async {
      await seedMessage(id: 'm1');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      // A gated message is a verdict too, and it unblocks the work queue's
      // untriaged guard exactly as a triaged one does, so it rides along.
      await seedMessage(
        id: 'm3',
        receivedAt: '2026-08-29T09:00:00Z',
        from: 'noreply@example.com',
      );
      var carried = <({String source, String id})>[];
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        onDrained: (triaged) async => carried = triaged,
      );

      await queue.pump();

      expect(
        carried.map((ref) => ref.id).toSet(),
        {'m1', 'm2', 'm3'},
      );
      expect(carried.every((ref) => ref.source == 'email'), isTrue);
      expect(await store.triageCounts(), {'triaged': 2, 'skipped': 1});
    });

    test('the list is fresh each drain, not the session', () async {
      await seedMessage(id: 'm1');
      final seen = <List<({String source, String id})>>[];
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        onDrained: (triaged) async => seen.add(triaged),
      );

      await queue.pump();
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      await queue.pump();

      expect(seen.length, 2);
      expect(seen[0].map((ref) => ref.id), ['m1']);
      expect(seen[1].map((ref) => ref.id), ['m2']);
    });
  });

  group('the yield ask', () {
    test('is made when something is pending', () async {
      await seedMessage(id: 'm1');
      final gate = _RecordingGate();
      final queue = TriageQueue(store, fakeLlm([answer()]), gate: gate);

      await queue.pump();

      expect(gate.asks, 1);
    });

    test('is not made when nothing is pending', () async {
      final gate = _RecordingGate();
      final queue = TriageQueue(store, fakeLlm([answer()]), gate: gate);

      await queue.pump();

      // A sixty-second poll over an empty queue would otherwise end the
      // worker's pass every minute for nothing.
      expect(gate.asks, 0);
    });

    test('is not made on the OFF branch, however much is pending', () async {
      await seedMessage(id: 'm1');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      final gate = _RecordingGate();
      final queue = TriageQueue(
        store,
        fakeLlm([answer()]),
        gate: gate,
        enabled: () => false,
      );

      await queue.pump();

      expect(gate.asks, 0);
      expect(await store.triageCounts(), {'pending': 2});
    });
  });

  test('stop ends the drain after the message in flight', () async {
    await seedMessage(id: 'm1', receivedAt: '2026-08-29T12:00:00Z');
    await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
    late TriageQueue queue;
    final llm = inspectingLlm(() => queue.stop());
    // Serial, so "the message in flight" is exactly one message: at three at a
    // time the drain has legitimately launched siblings before the stop lands,
    // and what happens to those is the park test's subject rather than this
    // one's. The claim here is that stop launches nothing FURTHER.
    queue = TriageQueue(store, llm, concurrency: 1);

    await queue.pump();

    expect(llm.userMessages.length, 1);
    expect((await messageRow('m2'))['triage_status'], 'pending');
  });
}

/// A client that runs a callback mid-request, for the assertions that are
/// about what is true WHILE the model is being called.
///
/// The callback is the fixture's `onCall`, which runs inside the in-flight
/// window and before the answer. [FutureOr] because the interesting thing to
/// inspect mid-request is a query: reading the row back is what tells us the
/// claim landed.
ScriptedLlm inspectingLlm(FutureOr<void> Function() onCall) =>
    ScriptedLlm(answers: {'triage': answer()}, onCall: (_) => onCall());
