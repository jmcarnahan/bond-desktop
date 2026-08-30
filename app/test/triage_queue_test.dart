import 'dart:convert';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/triage_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// An [LlmClient] that answers from a script and never opens a socket.
///
/// It records concurrency as well as calls: "one request in flight, ever" is
/// the queue's central promise, and a fake that only counted calls could not
/// tell a serial drain from a parallel one.
class FakeLlm extends LlmClient {
  /// Answers in order. A `Map` is returned, an `Exception` is thrown. The last
  /// entry repeats once the script runs out.
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
      final step = script.length > 1 ? script.removeAt(0) : script.first;
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
    store.updateMessageDetail(
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
  late Database db;
  late MessageStore store;

  setUp(() {
    db = openDbAt(':memory:');
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  void seedMessage({
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
  }) {
    store.upsertMessage({
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

  void seedConversation({
    String key = 'conv-1',
    String? lastInboundAt = '2026-08-29T10:00:00Z',
    String state = 'needs_reply',
  }) {
    store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Rate lock',
      'state': state,
      'last_inbound_at': lastInboundAt,
      'last_message_at': lastInboundAt,
    });
  }

  Map<String, Object?> messageRow(String id) => Map<String, Object?>.from(
        db.select(
          'SELECT * FROM messages WHERE source_message_id = ?',
          [id],
        ).first,
      );

  Map<String, Object?> conversationRow([String key = 'conv-1']) =>
      store.getConversationRow('email', key)!;

  group('drain', () {
    test('runs strictly one request at a time', () async {
      seedMessage(id: 'm1', receivedAt: '2026-08-29T10:00:00Z');
      seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      seedMessage(id: 'm3', receivedAt: '2026-08-29T12:00:00Z');
      final llm = FakeLlm([answer()]);
      final queue = TriageQueue(store, llm);

      // Two pumps started together: the second must find the first running
      // and return rather than race it.
      await Future.wait([queue.pump(), queue.pump()]);

      expect(llm.maxInFlight, 1);
      expect(llm.userMessages.length, 3);
    });

    test('takes the newest message first', () async {
      seedMessage(id: 'old', subject: 'Oldest', receivedAt: '2026-08-27T10:00:00Z');
      seedMessage(id: 'new', subject: 'Newest', receivedAt: '2026-08-29T10:00:00Z');
      seedMessage(id: 'mid', subject: 'Middle', receivedAt: '2026-08-28T10:00:00Z');
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
      seedMessage(id: 'm1', triageStatus: 'triaged');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
    });
  });

  group('gates', () {
    test('a gated message is skipped without reaching the model', () async {
      seedMessage(id: 'm1', from: 'no-reply@bank.com');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages, isEmpty);
      final row = messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'no_reply');
    });

    test('the self gate uses the address set after sign-in', () async {
      seedMessage(id: 'm1', from: 'lo@bond.com');
      final llm = FakeLlm([answer()]);
      final queue = TriageQueue(store, llm)..userAddress = 'LO@bond.com';

      await queue.pump();

      expect(llm.userMessages, isEmpty);
      expect(messageRow('m1')['gate_reason'], 'self');
    });

    test('a gated message does not stop the drain behind it', () async {
      seedMessage(
        id: 'bulk',
        from: 'noreply@bank.com',
        receivedAt: '2026-08-29T12:00:00Z',
      );
      seedMessage(id: 'real', receivedAt: '2026-08-29T11:00:00Z');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 1);
      expect(messageRow('real')['triage_status'], 'triaged');
    });
  });

  group('two-tier fetch', () {
    test('a bodyless message is fetched before the model sees it', () async {
      seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
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
      expect(messageRow('m1')['triage_status'], 'triaged');
    });

    test('headers from the fetch let the newsletter gate fire', () async {
      seedMessage(id: 'm1', withBody: false, bodyPreview: 'This week in rates');
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
      final row = messageRow('m1');
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], 'newsletter');
    });

    test('a sender gate skips the fetch entirely', () async {
      seedMessage(id: 'm1', from: 'no-reply@bank.com', withBody: false);
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      // The whole economic point of running the address gates first.
      expect(fetch.fetched, isEmpty);
      expect(llm.userMessages, isEmpty);
      expect(messageRow('m1')['gate_reason'], 'no_reply');
    });

    test('the self gate skips the fetch too', () async {
      seedMessage(id: 'm1', from: 'lo@bond.com', withBody: false);
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      final queue = TriageQueue(store, llm, ensureBody: fetch.call)
        ..userAddress = 'lo@bond.com';
      await queue.pump();

      expect(fetch.fetched, isEmpty);
      expect(messageRow('m1')['gate_reason'], 'self');
    });

    test('a failed fetch degrades to the preview instead of parking', () async {
      seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(
        store,
        error: StateError('Graph is having a moment'),
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, ['m1']);
      expect(llm.userMessages.single, contains('Short preview'));
      final row = messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['triage_attempts'], 0);
    });

    test('a dead session parks the drain instead of degrading', () async {
      seedMessage(
        id: 'm1',
        withBody: false,
        bodyPreview: 'Short preview',
        receivedAt: '2026-08-29T12:00:00Z',
      );
      seedMessage(
        id: 'm2',
        withBody: false,
        bodyPreview: 'Another preview',
        receivedAt: '2026-08-29T11:00:00Z',
      );
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, error: const NotSignedIn());

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      // The session is over, so triaging m1 from its preview would be model
      // time spent on an answer the next sign-in could have done properly —
      // and m2 would fail identically.
      expect(fetch.fetched, ['m1']);
      expect(llm.userMessages, isEmpty);
      final row = messageRow('m1');
      expect(row['triage_status'], 'pending');
      expect(row['triage_attempts'], 0);
      expect(messageRow('m2')['triage_status'], 'pending');
    });

    test('missing consent parks the drain the same way', () async {
      seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, error: const ReconsentRequired());

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(llm.userMessages, isEmpty);
      expect(messageRow('m1')['triage_status'], 'pending');
    });

    test('a generic auth wobble still degrades to the preview', () async {
      seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);
      // Not NotSignedIn and not ReconsentRequired: a 5xx or an offline
      // laptop, which the session survives.
      final fetch = FakeDetailFetch(
        store,
        error: const AuthException('Microsoft is having a moment'),
      );

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(llm.userMessages.single, contains('Short preview'));
      expect(messageRow('m1')['triage_status'], 'triaged');
    });

    test('a message that already has body and headers is not refetched',
        () async {
      seedMessage(
        id: 'm1',
        headers: const {'received': 'from mail.example.com'},
      );
      final llm = FakeLlm([answer()]);
      final fetch = FakeDetailFetch(store, bodyText: 'Body');

      await TriageQueue(store, llm, ensureBody: fetch.call).pump();

      expect(fetch.fetched, isEmpty);
      expect(llm.userMessages.length, 1);
      expect(messageRow('m1')['triage_status'], 'triaged');
    });

    test('with no fetcher wired, triage runs on whatever is stored', () async {
      seedMessage(id: 'm1', withBody: false, bodyPreview: 'Short preview');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.single, contains('Short preview'));
      expect(messageRow('m1')['triage_status'], 'triaged');
    });
  });

  group('results', () {
    test('a success writes every result column', () async {
      seedMessage(id: 'm1');
      final llm = FakeLlm([
        answer(
          urgency: 'urgent',
          category: 'title_escrow',
          summary: 'Escrow needs the payoff today.',
          actionItems: const ['Send the payoff demand', 'Call escrow'],
        ),
      ]);

      await TriageQueue(store, llm).pump();

      final row = messageRow('m1');
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
      seedMessage(id: 'm1');
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

      final row = messageRow('m1');
      expect(row['urgency'], 'normal');
      expect(row['category'], 'other');
      expect((row['summary'] as String).length, 500);
      expect(row['needs_action'], 0);
      expect((jsonDecode(row['action_items_json'] as String) as List).length, 3);
    });
  });

  group('conversation fold-up', () {
    test('the first action item becomes the thread CTA', () async {
      seedConversation();
      seedMessage(id: 'm1');
      final llm = FakeLlm([
        answer(urgency: 'urgent', actionItems: const ['Send the payoff demand']),
      ]);

      await TriageQueue(store, llm).pump();

      final row = conversationRow();
      expect(row['cta_text'], 'Send the payoff demand');
      expect(row['cta_urgency'], 'urgent');
      expect(row['category'], 'borrower');
    });

    test('with no action items, a needed summary stands in', () async {
      seedConversation();
      seedMessage(id: 'm1');
      final llm = FakeLlm([
        answer(
          summary: 'Sarah is waiting on the lock extension.',
          actionItems: const [],
        ),
      ]);

      await TriageQueue(store, llm).pump();

      expect(
        conversationRow()['cta_text'],
        'Sarah is waiting on the lock extension.',
      );
    });

    test('a message that needs nothing leaves no CTA', () async {
      seedConversation();
      seedMessage(id: 'm1');
      final llm = FakeLlm([
        answer(
          urgency: 'low',
          needsAction: false,
          actionItems: const [],
        ),
      ]);

      await TriageQueue(store, llm).pump();

      final row = conversationRow();
      expect(row['cta_text'], isNull);
      expect(row['cta_urgency'], 'low');
    });

    test('an older message never overwrites the newest inbound message\'s ask',
        () async {
      seedConversation(lastInboundAt: '2026-08-29T10:00:00Z');
      // Only the older message is pending — the newer one was triaged on a
      // previous run and its CTA is already on the thread.
      store.updateConversationTriage(
        'email',
        'conv-1',
        ctaText: 'Send the closing disclosure',
        ctaUrgency: 'urgent',
        category: 'borrower',
      );
      seedMessage(
        id: 'newest',
        receivedAt: '2026-08-29T10:00:00Z',
        triageStatus: 'triaged',
      );
      seedMessage(id: 'older', receivedAt: '2026-08-20T09:00:00Z');
      final llm = FakeLlm([
        answer(urgency: 'low', actionItems: const ['Reply about parking']),
      ]);

      await TriageQueue(store, llm).pump();

      expect(messageRow('older')['triage_status'], 'triaged');
      final row = conversationRow();
      expect(row['cta_text'], 'Send the closing disclosure');
      expect(row['cta_urgency'], 'urgent');
    });

    test('a message with no conversation row folds up into nothing', () async {
      seedMessage(id: 'm1', conversationKey: 'orphan');
      final llm = FakeLlm([answer()]);

      await TriageQueue(store, llm).pump();

      expect(messageRow('m1')['triage_status'], 'triaged');
      expect(store.getConversationRow('email', 'orphan'), isNull);
    });
  });

  group('failure', () {
    test('a bad answer is retried once, then left as an error', () async {
      seedMessage(id: 'm1');
      final llm = FakeLlm([const LlmFormatException('not json')]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 2);
      final row = messageRow('m1');
      expect(row['triage_status'], 'error');
      expect(row['triage_attempts'], 2);
      expect(row['triage_error'], contains('not json'));
    });

    test('a retry that succeeds stores the result', () async {
      seedMessage(id: 'm1');
      final llm = FakeLlm([const LlmFormatException('not json'), answer()]);

      await TriageQueue(store, llm).pump();

      final row = messageRow('m1');
      expect(row['triage_status'], 'triaged');
      expect(row['triage_attempts'], 1);
    });

    test('a schema 400 is this app\'s bug and is never retried', () async {
      seedMessage(id: 'm1');
      final llm = FakeLlm([
        const LlmException('JSON schema conversion failed', 400),
      ]);

      await TriageQueue(store, llm).pump();

      expect(llm.userMessages.length, 1);
      final row = messageRow('m1');
      expect(row['triage_status'], 'error');
      expect(row['triage_attempts'], 1);
    });

    test('a failure does not stop the drain', () async {
      seedMessage(id: 'bad', receivedAt: '2026-08-29T12:00:00Z');
      seedMessage(id: 'good', receivedAt: '2026-08-29T11:00:00Z');
      final llm = FakeLlm([
        const LlmException('boom', 400),
        answer(),
      ]);

      await TriageQueue(store, llm).pump();

      expect(messageRow('bad')['triage_status'], 'error');
      expect(messageRow('good')['triage_status'], 'triaged');
    });

    test('a model server that is down costs the message nothing', () async {
      seedMessage(id: 'm1', receivedAt: '2026-08-29T12:00:00Z');
      seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      final llm = FakeLlm([const LlmUnavailableException('not reachable')]);

      await TriageQueue(store, llm).pump();

      // One call, then the drain gives up: the second message would have
      // failed identically.
      expect(llm.userMessages.length, 1);
      final row = messageRow('m1');
      expect(row['triage_status'], 'pending');
      expect(row['triage_attempts'], 0);
      expect(messageRow('m2')['triage_status'], 'pending');
    });

    test('the next pump picks up where a downed server left off', () async {
      seedMessage(id: 'm1');
      final llm = FakeLlm([
        const LlmUnavailableException('not reachable'),
        answer(),
      ]);
      final queue = TriageQueue(store, llm);

      await queue.pump();
      expect(messageRow('m1')['triage_status'], 'pending');

      await queue.pump();
      expect(messageRow('m1')['triage_status'], 'triaged');
    });
  });

  group('interruption', () {
    test('resetInterrupted returns a claimed message to the queue', () async {
      seedMessage(id: 'm1', triageStatus: 'processing');
      seedMessage(id: 'm2', triageStatus: 'triaged');
      final llm = FakeLlm([answer()]);
      final queue = TriageQueue(store, llm);

      expect(store.nextPendingTriage(), isNull);
      queue.resetInterrupted();
      expect(store.nextPendingTriage(), isNotNull);

      await queue.pump();

      expect(messageRow('m1')['triage_status'], 'triaged');
      expect(messageRow('m2')['triage_status'], 'triaged');
    });

    test('a message is claimed before the model is called', () async {
      seedMessage(id: 'm1');
      var statusDuringCall = '';
      final llm = _InspectingLlm(() {
        statusDuringCall = messageRow('m1')['triage_status'] as String;
      });

      await TriageQueue(store, llm).pump();

      expect(statusDuringCall, 'processing');
    });
  });

  group('progress', () {
    test('emits after every message, counting what is left', () async {
      seedMessage(id: 'm1', receivedAt: '2026-08-29T12:00:00Z');
      seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
      seedMessage(id: 'sent', direction: 'outbound', triageStatus: 'skipped');
      final llm = FakeLlm([answer()]);
      final queue = TriageQueue(store, llm);
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
      seedMessage(id: 'm1');
      seedMessage(id: 'gated', from: 'noreply@x.com');
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
    seedMessage(id: 'm1', receivedAt: '2026-08-29T12:00:00Z');
    seedMessage(id: 'm2', receivedAt: '2026-08-29T11:00:00Z');
    late TriageQueue queue;
    final llm = _InspectingLlm(() => queue.stop());
    queue = TriageQueue(store, llm);

    await queue.pump();

    expect(llm.userMessages.length, 1);
    expect(messageRow('m2')['triage_status'], 'pending');
  });
}

/// A fake that runs a callback mid-request, for the assertions that are about
/// what is true WHILE the model is being called.
class _InspectingLlm extends FakeLlm {
  final void Function() onCall;

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
  }) {
    onCall();
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
