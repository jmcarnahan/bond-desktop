import 'dart:async';
import 'dart:convert';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// An [LlmClient] that answers from a script and never opens a socket.
///
/// It records concurrency as well as calls: how many requests the drain has in
/// flight is the number this phase is about, and a fake that only counted
/// calls could not tell a serial drain from a three-at-a-time one.
class FakeLlm extends LlmClient {
  /// Answers in order. A `Map` is returned, an `Exception` is thrown, and a
  /// `Future` is awaited first and then treated as whichever of those it
  /// yields — which is the only way to hold one request open while the drain
  /// gets on with the others. The last entry repeats once the script runs out.
  final List<Object> script;

  final List<String> userMessages = [];
  int inFlight = 0;
  int maxInFlight = 0;

  FakeLlm(this.script) : super(baseUrl: 'http://127.0.0.1:1/never-dialled');

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
    userMessages.add(user);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      // A real call suspends; without a suspension here two overlapping pumps
      // could interleave in a way the fake would never see.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      var step = script.length > 1 ? script.removeAt(0) : script.first;
      if (step is Future<Object>) step = await step;
      if (step is Exception) throw step;
      return Map<String, dynamic>.from(step as Map);
    } finally {
      inFlight--;
    }
  }
}

/// Stands in for `MailSync.ensureMessageBody`: records what it was asked for
/// and writes the detail a real Graph fetch would have stored.
class FakeDetailFetch {
  final MessageStore store;
  final String? bodyText;
  final Map<String, String>? headers;

  /// Thrown instead of storing anything — a Graph call that failed.
  final Object? error;

  final List<String> fetched = [];

  FakeDetailFetch(this.store, {this.bodyText, this.headers, this.error});

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
  }
}

Map<String, dynamic> answer({
  String urgency = 'high',
  String category = 'borrower',
  String summary = 'Sarah asks about the rate lock.',
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

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seedMessage({
    required String id,
    String conversationKey = 'conv-1',
    String direction = 'inbound',
    String? from = 'sarah@example.com',
    String subject = 'Rate lock',
    String receivedAt = '2026-08-29T10:00:00Z',
    String triageStatus = 'pending',
    // False is what a message looks like straight off a delta page: a
    // preview, and no body until something fetches its detail.
    bool withBody = true,
    String? bodyPreview,
    Map<String, String>? headers,
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': subject,
      'from_name': 'Sarah',
      'from_address': from,
      'received_at': receivedAt,
      'body_preview': bodyPreview,
      'body_text': withBody ? 'Body of $id' : null,
      'source_meta_json':
          headers == null ? null : jsonEncode({'headers': headers}),
      'triage_status': triageStatus,
    });
  }

  Future<void> seedConversation({
    String key = 'conv-1',
    String? lastInboundAt = '2026-08-29T10:00:00Z',
    String state = 'needs_reply',
  }) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Rate lock',
      'state': state,
      'last_inbound_at': lastInboundAt,
      'last_message_at': lastInboundAt,
    });
  }

  Future<Map<String, Object?>> messageRow(String id) async =>
      (await store.getMessageRow('email', id))!;

  Future<Map<String, Object?>> conversationRow([String key = 'conv-1']) async =>
      (await store.getConversationRow('email', key))!;

  group('drain', () {
    test('a second pump does not start a racing drain', () async {
      await seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      await seedMessage(id: 'm3', receivedAt: '2026-08-29T12:00:00Z');
      final llm = FakeLlm([answer()]);
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
      for (var i = 0; i < 9; i++) {
        await seedMessage(id: 'm$i', receivedAt: '2026-08-29T1$i:00:00Z');
      }
      // Two queues rather than two pumps of one: the `_running` flag guards a
      // queue against itself, and each queue carries its own [DrainGate], so
      // these two drains genuinely overlap. It is the case the atomic claim
      // exists for — choosing a message and writing its `processing` are one
      // statement, so whichever claim lands second cannot be handed a row the
      // first already took.
      final first = FakeLlm([answer()]);
      final second = FakeLlm([answer()]);

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
      final llm = FakeLlm([answer()]);

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
      final llm = FakeLlm([answer()]);

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
      final llm = FakeLlm([answer()]);

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
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
    });
  });

  group('gates', () {
    test('a gated message is skipped without reaching the model', () async {
      await seedMessage(id: 'm1', from: 'no-reply@bank.com');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'no_reply');
    });

    test('the self gate uses the address set after sign-in', () async {
      await seedMessage(id: 'm1', from: 'lo@bond.com');
      final llm = FakeLlm([answer()]);
      final queue = TriageQueue(store, llm)..userAddress = 'LO@bond.com';

      await queue.pump();

      expect(llm.userMessages, isEmpty);
      expect((await messageRow('m1'))['gate_reason'], 'self');
    });

    test('a gated message does not stop the drain behind it', () async {
      await seedMessage(
        id: 'bulk',
        from: 'noreply@bank.com',
        receivedAt: '2026-08-29T12:00:00Z',
      );
      await seedMessage(id: 'real', receivedAt: '2026-08-29T11:00:00Z');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 1);
      expect((await messageRow('real'))['triage_status'], 'triaged');
    });
  });

  group('two-tier fetch', () {
    test('a bodyless message is fetched before the model sees it', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);
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
      final llm = FakeLlm([answer()]);
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

    test('a sender gate skips the fetch entirely', () async {
      await seedMessage(id: 'm1', from: 'no-reply@bank.com', withBody: false);
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      // The whole economic point of running the address gates first.
      expect(fetch.fetched, isEmpty);
      expect(llm.userMessages, isEmpty);
      expect((await messageRow('m1'))['gate_reason'], 'no_reply');
    });

    test('the self gate skips the fetch too', () async {
      await seedMessage(id: 'm1', from: 'lo@bond.com', withBody: false);
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      final queue = TriageQueue(store, llm, ensureBody: fetch.call)
        ..userAddress = 'lo@bond.com';
      await queue.pump();

      expect(fetch.fetched, isEmpty);
      expect((await messageRow('m1'))['gate_reason'], 'self');
    });

    test('a failed fetch degrades to the preview instead of parking', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);
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
      final llm = FakeLlm([answer()]);
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
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, error: const ReconsentRequired());

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(llm.userMessages, isEmpty);
      expect((await messageRow('m1'))['triage_status'], 'pending');
    });

    test('a generic auth wobble still degrades to the preview', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);
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
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, isEmpty);
      expect(llm.userMessages.length, 1);
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });

    test('with no fetcher wired, triage runs on whatever is stored', () async {
      await seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.single, contains('Short preview'));
      expect((await messageRow('m1'))['triage_status'], 'triaged');
    });
  });

  group('results', () {
    test('a success writes every result column', () async {
      await seedMessage(id: 'm1');
      final llm = FakeLlm([
        answer(
          urgency: 'urgent',
          category: 'title_escrow',
          summary: 'Escrow needs the payoff today.',
          actionItems: const ['Send the payoff demand', 'Call escrow'],
        ),
      ]);

      await TriageQueue(store, llm).pump();

      final row = await messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['urgency'], 'urgent');
      expect(row['category'], 'title_escrow');
      expect(row['summary'], 'Escrow needs the payoff today.');
      expect(row['needs_action'], 1);
      expect(
        jsonDecode(row['action_items_json'] as String),
        ['Send the payoff demand', 'Call escrow'],
      );
    });

    test('a nonsense answer is clamped rather than stored raw', () async {
      await seedMessage(id: 'm1');
      final llm = FakeLlm([
        {
          'urgency': 'CRITICAL',
          'category': 'mortgage',
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
      final llm = FakeLlm([
        answer(urgency: 'urgent', actionItems: const ['Send the payoff demand']),
      ]);

      await TriageQueue(store, llm).pump();

      final row = await conversationRow();
      expect(row['cta_text'], 'Send the payoff demand');
      expect(row['cta_urgency'], 'urgent');
      expect(row['category'], 'borrower');
    });

    test('with no action items, a needed summary stands in', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = FakeLlm([
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

    test('a message that needs nothing leaves no CTA', () async {
      await seedConversation();
      await seedMessage(id: 'm1');
      final llm = FakeLlm([
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
        ctaText: 'Send the closing disclosure',
        ctaUrgency: 'urgent',
        category: 'borrower',
      );
      await seedMessage(
        id: 'newest',
        receivedAt: '2026-08-29T10:00:00Z',
        triageStatus: 'triaged',
      );
      await seedMessage(id: 'older', receivedAt: '2026-08-20T09:00:00Z');
      final llm = FakeLlm([
        answer(urgency: 'low', actionItems: const ['Reply about parking']),
      ]);

      await TriageQueue(store, llm).pump();

      expect((await messageRow('older'))['triage_status'], 'triaged');
      final row = await conversationRow();
      expect(row['cta_text'], 'Send the closing disclosure');
      expect(row['cta_urgency'], 'urgent');
    });

    test('a message with no conversation row folds up into nothing', () async {
      await seedMessage(id: 'm1', conversationKey: 'orphan');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect((await messageRow('m1'))['triage_status'], 'triaged');
      expect(await store.getConversationRow('email', 'orphan'), isNull);
    });
  });

  group('failure', () {
    test('a bad answer is retried once, then left as an error', () async {
      await seedMessage(id: 'm1');
      final llm = FakeLlm([const LlmFormatException('not json')]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 2);
      final row = await messageRow('m1');
      expect(row['triage_status'], 'error');
      expect(row['triage_attempts'], 2);
      expect(row['triage_error'], contains('not json'));
    });

    test('a retry that succeeds stores the result', () async {
      await seedMessage(id: 'm1');
      final llm = FakeLlm([const LlmFormatException('not json'), answer()]);

      await TriageQueue(store, llm).pump();

      final row = await messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['triage_attempts'], 1);
    });

    test('a schema 400 is this app\'s bug and is never retried', () async {
      await seedMessage(id: 'm1');
      final llm = FakeLlm([
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
      final llm = FakeLlm([
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
      final llm = FakeLlm([const LlmUnavailableException('not reachable')]);

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
      final held = Completer<Object>();
      final llm = FakeLlm([
        held.future,
        const LlmUnavailableException('not reachable'),
        held.future,
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
      final held = Completer<Object>();
      final llm = FakeLlm([
        answer(urgency: 'urgent', actionItems: const ['Extend the lock']),
        held.future,
      ]);

      final drain = TriageQueue(store, llm).pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await conversationRow())['cta_text'], 'Extend the lock');
      held.complete(
        answer(urgency: 'low', actionItems: const ['Reply about parking']),
      );
      await drain;

      expect((await messageRow('older'))['triage_status'], 'triaged');
      final row = await conversationRow();
      expect(row['cta_text'], 'Extend the lock');
      expect(row['cta_urgency'], 'urgent');
    });

    test('the next pump picks up where a downed server left off', () async {
      await seedMessage(id: 'm1');
      final llm = FakeLlm([
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
      final llm = FakeLlm([answer()]);
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
      final llm = _InspectingLlm(() async {
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
      final llm = FakeLlm([answer()]);
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
      final llm = FakeLlm([answer()]);
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
  });

  test('stop ends the drain after the message in flight', () async {
    await seedMessage(id: 'm1', receivedAt: '2026-08-29T12:00:00Z');
    await seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
    late TriageQueue queue;
    final llm = _InspectingLlm(() => queue.stop());
    queue = TriageQueue(store, llm);

    await queue.pump();

    expect(llm.userMessages.length, 1);
    expect((await messageRow('m2'))['triage_status'], 'pending');
  });
}

/// A fake that runs a callback mid-request, for the assertions that are about
/// what is true WHILE the model is being called.
class _InspectingLlm extends FakeLlm {
  /// [FutureOr] because the interesting thing to inspect mid-request is now a
  /// query: reading the row back is what tells us the claim landed.
  final FutureOr<void> Function() onCall;

  _InspectingLlm(this.onCall) : super([answer()]);

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
    await onCall();
    return super.completeJson(
      system: system,
      user: user,
      schema: schema,
      schemaName: schemaName,
      maxTokens: maxTokens,
      temperature: temperature,
      think: think,
    );
  }
}
