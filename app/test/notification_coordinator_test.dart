import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The decision table: for one admitted message, which of `notified` and
/// `suppressed` it settles to, and when it settles at all.
///
/// Two things run through every case. The first is that **an open row is not a
/// decision**: a message whose pipeline is still working is left alone rather
/// than settled early, right up until the deadline forces the issue. The
/// second is that **worthiness is judged at settle time**, against whatever
/// the model has since written — which is why "the user read it while the
/// model thought about it" is a suppression and not a race.
void main() {
  late BondDatabase db;
  late MessageStore store;
  late DateTime now;
  late NotificationCoordinator coordinator;
  late List<MessageSettled> emitted;

  /// The arming instant. Every seeded message is stamped after it and every
  /// deadline is six minutes past it, so a test that wants the deadline to
  /// bite says so by moving [now] and nothing else.
  final armedAt = DateTime.utc(2026, 9, 2, 12);

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    now = armedAt;
    emitted = [];
    coordinator = NotificationCoordinator(store, clock: () => now);
    coordinator.notifications.listen(emitted.add);
    coordinator.noteSyncCompleted();
  });

  tearDown(() async {
    await coordinator.dispose();
    await db.close();
  });

  /// A thread and one unread inbound message on it: triaged, scored above the
  /// threshold, and expecting a reply — the shape of a candidate the pipeline
  /// has finished with AND that is worth announcing. Each argument below turns
  /// exactly one of those facts off, so a test names the single thing it is
  /// about and inherits the rest.
  ///
  /// The three pipeline arguments say what the RECORD says, not what the queue
  /// holds: completeness now reads `message_progress` stages and a written
  /// verdict, so a candidate the pipeline has finished with is one whose
  /// stages are terminal and whose verdict exists — which is what the defaults
  /// here spell out.
  Future<void> seedCandidate({
    String id = 'm-1',
    String key = 'conv-1',
    String source = 'email',
    String conversationState = 'needs_reply',
    String? ctaText,
    String triageStatus = 'triaged',
    int isRead = 0,
    double? attentionScore = 0.9,
    String? bucket,
    bool triageVerdict = true,
    bool needsAction = false,
    bool replyExpected = true,
    String urgency = 'normal',
    String deadline = '',
    bool? needsYouVerdict = false,
    String extractState = 'done',
    String storylineState = 'done',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': 'Thread $key',
      'state': conversationState,
      'cta_text': ctaText,
      'last_message_at': '2026-09-02T11:55:00.000Z',
    });
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Subject of $id',
      'from_name': 'Sarah',
      'received_at': '2026-09-02T11:55:00.000Z',
      'is_read': isRead,
      'created_at': '2026-09-02T12:01:00.000Z',
    });
    // The verdict before triage, because writing one stamps the message's
    // `updated_at` too and the score has to end up newer than every write to
    // the row. `null` leaves the message unjudged, which under the new
    // completeness rule holds the candidate open.
    if (needsYouVerdict != null) {
      await store.writeNeedsYouVerdict(
        source,
        id,
        verdict: needsYouVerdict,
        reason: 'seeded',
      );
    }
    // Triage second, so the message's `updated_at` is the newer of the two by
    // the time the score is written — the order the completeness check wants.
    await store.writeTriage(
      source,
      id,
      status: triageStatus,
      result: triageVerdict
          ? TriageResult(
              urgency: urgency,
              category: 'work',
              summary: 'what $id says',
              needsAction: needsAction,
              actionItems: const [],
              replyExpected: replyExpected,
              deadline: deadline,
            )
          : null,
    );
    // The stages, on `message_progress` rather than on `messages`, so neither
    // write disturbs the stamp ordering above.
    await store.writeExtractProgress(source, id, state: extractState);
    await store.writeStorylineProgress(source, key, state: storylineState);
    if (bucket != null) {
      await store.setConversationBucket(source, key, bucket: bucket);
    }
    if (attentionScore != null) {
      await store.writeAttentionScore(source, key, attentionScore);
    }
  }

  Future<Map<String, Object?>> notifyRow(String id) async {
    final rows = await db.customSelect(
      'SELECT * FROM message_notify WHERE source_message_id = ?',
      variables: [Variable<String>(id)],
    ).get();
    return Map<String, Object?>.from(rows.single.data);
  }

  Future<void> sweep() async {
    await coordinator.sweep();
    await pumpEventQueue();
  }

  group('suppressions', () {
    test('a message the gate threw out after admission settles silently',
        () async {
      await seedCandidate(triageStatus: 'pending');
      // Admitted while triage was still to come, gated afterwards — the row
      // still has to settle, because every admitted row settles.
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));
      await store.writeTriage('email', 'm-1', status: 'skipped');
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'gated');
      expect(emitted, isEmpty);
    });

    test('a message read while the model worked is not announced', () async {
      await seedCandidate(triageStatus: 'pending');
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.markConversationRead('email', 'conv-1');
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'read');
      expect(emitted, isEmpty);
    });

    test('a thread the user has finished with is not announced', () async {
      await seedCandidate(conversationState: 'done');
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'done');
      expect(emitted, isEmpty);
    });

    test('a complete but unremarkable message settles not_worthy', () async {
      await seedCandidate(attentionScore: 0.1);
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'not_worthy');
      expect(emitted, isEmpty);
    });
  });

  group('completeness', () {
    test('a finished, worthy message is announced', () async {
      await seedCandidate();
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'notified');
      expect(row['reason'], 'settled');

      final event = emitted.single;
      expect(event.sourceMessageId, 'm-1');
      expect(event.conversationKey, 'conv-1');
      expect(event.title, 'Subject of m-1');
      expect(event.summary, 'what m-1 says');
      expect(event.attentionScore, 0.9);
      expect(event.settledOnDeadline, isFalse);
      expect(event.key, 'email/conv-1');
    });

    test('triage still running holds the row open', () async {
      await seedCandidate(triageStatus: 'processing');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'pending'));
      expect(emitted, isEmpty);
    });

    test('a pending extract stage holds the row open, work row or not',
        () async {
      // The stage, not the queue. A message triaged mid-sync has no work rows
      // at all — they are enqueued after both drains — and reading that as
      // "finished" is what froze rows at `outcome = 'pending'` for good.
      await seedCandidate(extractState: 'pending');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.writeExtractProgress('email', 'm-1', state: 'done');
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('an open extract work row over a finished stage holds nothing',
        () async {
      // The other direction of the same rule: the queue is no longer
      // consulted, so a stale or re-queued work row cannot hold a row whose
      // stage has already been written.
      await seedCandidate();
      await store.enqueueWork('extract', 'email', 'm-1');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('a stage the pipeline skipped counts as finished', () async {
      // `skipped` is a real end state: a message the extractor was never going
      // to look at is not one to keep waiting on.
      await seedCandidate(extractState: 'skipped');
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('a pending storyline stage holds the row open', () async {
      // Keyed by conversation, deliberately: announcing a message under the
      // wrong storyline is worse than announcing it a few seconds late.
      await seedCandidate(storylineState: 'pending');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.writeStorylineProgress('email', 'conv-1', state: 'done');
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('no attention score yet holds the row open', () async {
      await seedCandidate(attentionScore: null);
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'pending'));
      expect(emitted, isEmpty);
    });

    test('a score older than the message holds the row open until restamped',
        () async {
      await seedCandidate();
      // The message changed after it was scored, so the score is a verdict
      // about an older version of it.
      await store.writeTriage('email', 'm-1', status: 'triaged');
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.writeAttentionScore('email', 'conv-1', 0.9);
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('an unjudged message holds the row open until a verdict is written',
        () async {
      // Needs-you has no stage column, so the verdict itself is the record.
      // Settling before it lands would announce — or stay silent about — a
      // message on an answer that had not arrived.
      await seedCandidate(needsYouVerdict: null);
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.writeNeedsYouVerdict('email', 'm-1',
          verdict: false, reason: 'model says so');
      await store.writeAttentionScore('email', 'conv-1', 0.9);
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('a finished needs-you work row counts as judged with no verdict',
        () async {
      // The handler ends an item `done` on every one of its own guards —
      // deleted, outbound, gated — without writing a verdict. Waiting past
      // that would be waiting on nobody.
      await seedCandidate(needsYouVerdict: null);
      await store.enqueueWork('needs_you', 'email', 'm-1');
      await store.writeWork('needs_you', 'email', 'm-1', status: 'done');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('an unjudged message with no work row settles on the deadline',
        () async {
      // The accepted price of reading the record instead of the queue: a
      // message past the 150-per-pass backlog cap has nothing enqueued for it
      // yet, so it waits out the deadline rather than settling at once. A
      // re-drain is not news.
      await seedCandidate(needsYouVerdict: null);
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      now = armedAt
          .add(NotificationCoordinator.settleDeadline)
          .add(const Duration(seconds: 1));
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'notified');
      expect(row['reason'], 'deadline');
    });
  });

  // Worthiness is an AND: the message must ask something of the reader, AND
  // the thread must be loud enough to be worth hearing about. Each test below
  // takes away exactly one of those halves and expects silence.
  group('worthiness', () {
    test('a quiet thread stays quiet even when the message asks', () async {
      // The threshold and the `later` bucket are the user's ONE loudness
      // control. An ask that could bypass them would take the control away in
      // exactly the case it exists for.
      await seedCandidate(attentionScore: 0.1);
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'suppressed'));
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
      expect(emitted, isEmpty);
    });

    test('a loud thread stays quiet when the message asks nothing', () async {
      // Volume alone is a ranking, not a request. Firing on it would announce
      // every unread message of every decent-scoring thread — the notification
      // stream this app exists to replace.
      await seedCandidate(replyExpected: false);
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'suppressed'));
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
      expect(emitted, isEmpty);
    });

    test('needs_action, urgency and a named deadline are each an ask on their '
        'own', () async {
      await seedCandidate(
          id: 'm-act', key: 'c-act', replyExpected: false, needsAction: true);
      await seedCandidate(
          id: 'm-urg', key: 'c-urg', replyExpected: false, urgency: 'urgent');
      await seedCandidate(
          id: 'm-due', key: 'c-due', replyExpected: false, deadline: 'Friday');
      await sweep();

      for (final id in ['m-act', 'm-urg', 'm-due']) {
        expect(await notifyRow(id), containsPair('state', 'notified'),
            reason: id);
      }
    });

    test("a thread's CTA is an ask when the message carries none", () async {
      await seedCandidate(replyExpected: false, ctaText: 'Send the appraisal');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
      expect(emitted.single.ctaText, 'Send the appraisal');
    });

    test("a thread's CTA is not this message's ask when its own triage failed",
        () async {
      // The CTA on a conversation belongs to its newest TRIAGED message. This
      // one's triage spent its attempts and ended in `error`, so the ask
      // sitting on the thread is somebody else's — and counting it would
      // announce THIS message while quoting THAT one.
      await seedCandidate(
        triageStatus: 'error',
        triageVerdict: false,
        ctaText: 'Send the appraisal',
      );
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'not_worthy');
      expect(emitted, isEmpty);
    });

    test('an unjudged reply_expected is not an ask', () async {
      // NULL means no v2 pass has judged this message, which is NOT a decided
      // "no reply expected" — but it is not a "yes" either. The score is well
      // over the threshold here, so the NULL is the only thing that can be
      // keeping this quiet.
      await seedCandidate(triageVerdict: false, attentionScore: 0.9);
      final stored = await store.getMessageRow('email', 'm-1');
      expect(stored!['reply_expected'], isNull);

      await sweep();
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
      expect(emitted, isEmpty);
    });

    test('the attention threshold gates an ask like anything else', () async {
      await seedCandidate(attentionScore: 0.6);
      final quiet = NotificationCoordinator(
        store,
        clock: () => now,
        attentionThreshold: () async => 0.8,
      );
      addTearDown(quiet.dispose);
      quiet.noteSyncCompleted();
      await quiet.sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'suppressed'));
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
    });

    test('even an ask stays quiet on a thread the user deferred', () async {
      await seedCandidate(bucket: 'later');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'suppressed'));
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
    });
  });

  // The needs-you stage's verdict, read as an ask alongside triage's. Every
  // candidate below is NARROW — triage found nothing to ask about — so the
  // verdict column is the only thing that can speak, and the tri-state is
  // tested one value at a time: yes, judged no, and never judged.
  group('the needs-you verdict', () {
    /// A candidate whose triage asks nothing, with [verdict] written onto it.
    ///
    /// The score is rewritten AFTER the verdict on purpose: writing a verdict
    /// bumps the message's `updated_at`, which correctly makes the existing
    /// score a verdict about an older version of the row. Restamping it is what
    /// the pipeline does in real life, and here it keeps these tests about
    /// worthiness rather than about completeness.
    Future<void> seedJudged(bool? verdict) async {
      await seedCandidate(replyExpected: false, needsYouVerdict: verdict);
      if (verdict == null) {
        // Unjudged is not a settled row on its own any more — completeness
        // holds it open for the verdict. A finished work row is the other way
        // a message counts as judged, and it is what the handler leaves behind
        // when its own guards end the item without writing one, so these
        // worthiness tests stay about worthiness.
        await store.enqueueWork('needs_you', 'email', 'm-1');
        await store.writeWork('needs_you', 'email', 'm-1', status: 'done');
      }
      await store.writeAttentionScore('email', 'conv-1', 0.9);
    }

    test('a judged yes is an ask on its own', () async {
      // Nothing triage wrote asks anything here, so this announcement exists
      // entirely because the needs-you pass said the message wants the owner.
      await seedJudged(true);
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'notified');
      expect(row['reason'], 'settled');
      expect(emitted.single.sourceMessageId, 'm-1');
    });

    test('a judged no adds nothing', () async {
      await seedJudged(false);
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'suppressed'));
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
      expect(emitted, isEmpty);
    });

    test('an unjudged message adds nothing either', () async {
      // NULL is "no pass has looked at this", which is not a yes — the same
      // rule `reply_expected` takes, and the reason both are read with `== 1`.
      await seedJudged(null);
      final stored = await store.getMessageRow('email', 'm-1');
      expect(stored!['needs_you_verdict'], isNull);

      await sweep();
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
      expect(emitted, isEmpty);
    });

    test('a judged yes is still gated by the attention threshold', () async {
      // The recorded decision: the verdict is the ask half only. It buys no
      // exemption from the user's one loudness control.
      await seedCandidate(replyExpected: false);
      await store.writeNeedsYouVerdict('email', 'm-1',
          verdict: true, reason: 'model says so');
      await store.writeAttentionScore('email', 'conv-1', 0.1);
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'suppressed'));
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
      expect(emitted, isEmpty);
    });

    test('a judged yes is still gated by the Later bucket', () async {
      await seedCandidate(replyExpected: false, bucket: 'later');
      await store.writeNeedsYouVerdict('email', 'm-1',
          verdict: true, reason: 'model says so');
      await store.writeAttentionScore('email', 'conv-1', 0.9);
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'suppressed'));
      expect(await notifyRow('m-1'), containsPair('reason', 'not_worthy'));
      expect(emitted, isEmpty);
    });
  });

  group('deadline', () {
    test('an unfinished but worthy message is announced when time runs out',
        () async {
      // Complete and worthy on its own terms — what holds it open is the
      // storyline stage, which is also what makes the null storyline below
      // mean "not known yet" rather than "no storyline".
      await seedCandidate(storylineState: 'pending');
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      now = armedAt.add(const Duration(minutes: 7));
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'notified');
      expect(row['reason'], 'deadline');

      final event = emitted.single;
      expect(event.settledOnDeadline, isTrue);
      // "Not known", not "none": the storyline pass may still be open, and
      // guessing a membership here would attach the message to the wrong
      // thread of work.
      expect(event.storylineId, isNull);
      expect(event.storylineTitle, isNull);
    });

    test("a CTA this message's own triage wrote is still an ask at the deadline",
        () async {
      // Triaged, so the thread's CTA is this message's own words. What holds
      // it open is the storyline stage, and the deadline settle quotes the ask
      // it earned.
      await seedCandidate(
        replyExpected: false,
        ctaText: 'Send the appraisal',
        storylineState: 'pending',
      );
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      now = armedAt.add(const Duration(minutes: 7));
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'notified');
      expect(row['reason'], 'deadline');
      expect(emitted.single.ctaText, 'Send the appraisal');
    });

    test("a CTA no triage of this message's wrote is not an ask at the deadline",
        () async {
      // The deadline forces a verdict on a message whose own triage never
      // finished, so the CTA on its thread was written by a different message
      // — and the score alone is not an ask. Before this it was: the toast
      // named this message and quoted the other one's request.
      await seedCandidate(
        triageStatus: 'pending',
        replyExpected: false,
        ctaText: 'Send the appraisal',
      );
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      now = armedAt.add(const Duration(minutes: 7));
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'deadline');
      expect(emitted, isEmpty);
    });

    test('an unfinished, unremarkable message is dropped when time runs out',
        () async {
      // Unfinished on the storyline stage and scored below the threshold. The
      // score has to exist: a candidate with none at all is given one more
      // deadline's grace, which is the case below this one.
      await seedCandidate(attentionScore: 0.1, storylineState: 'pending');
      await sweep();
      now = armedAt.add(const Duration(minutes: 7));
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'deadline');
      expect(emitted, isEmpty);
    });

    test('a candidate with no score waits out one more deadline', () async {
      // Settling a scoreless candidate scores it zero and writes the chip off,
      // and nothing revisits it. The attention sweep runs on every list load,
      // so one more deadline's grace is a cheap way to let the score land.
      await seedCandidate(attentionScore: null);
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      now = armedAt.add(const Duration(minutes: 7));
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      now = armedAt.add(const Duration(minutes: 13));
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'deadline');
    });
  });

  group('the event', () {
    test('carries the storyline the thread belongs to', () async {
      await seedCandidate();
      await store.insertStoryline(
        id: 's-1',
        title: 'The Harper closing',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('s-1', 'email', 'conv-1',
          addedBy: 'auto');
      await sweep();

      expect(emitted.single.storylineId, 's-1');
      expect(emitted.single.storylineTitle, 'The Harper closing');
    });

    test('falls back to the sender when the message has no subject', () async {
      await store.upsertConversation({
        'conversation_key': 'conv-1',
        'state': 'needs_reply',
        'last_message_at': '2026-09-02T11:55:00.000Z',
      });
      await store.upsertMessage({
        'source_message_id': 'm-1',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'from_name': 'Sarah',
        'received_at': '2026-09-02T11:55:00.000Z',
        'created_at': '2026-09-02T12:01:00.000Z',
      });
      await store.writeNeedsYouVerdict('email', 'm-1',
          verdict: false, reason: 'seeded');
      await store.writeTriage('email', 'm-1',
          status: 'triaged',
          result: const TriageResult(
            urgency: 'high',
            category: 'work',
            summary: 'no subject line',
            needsAction: false,
            actionItems: [],
          ));
      // The stages the pipeline would have written. Hand-seeded here because
      // this row is built column by column rather than through `seedCandidate`.
      await store.writeExtractProgress('email', 'm-1', state: 'done');
      await store.writeStorylineProgress('email', 'conv-1', state: 'done');
      await store.writeAttentionScore('email', 'conv-1', 0.9);
      await sweep();

      expect(emitted.single.title, 'Sarah');
    });

    test('two sweeps in a row announce one message once', () async {
      await seedCandidate();
      await Future.wait([coordinator.sweep(), coordinator.sweep()]);
      await pumpEventQueue();
      await sweep();

      expect(emitted, hasLength(1));
    });
  });

  /// What `message_progress` is left holding once the row settles — the value
  /// the home screen's tile counts.
  ///
  /// These build their own coordinator, because the shared one runs with
  /// progress writing disabled and the whole subject here is what it writes.
  group('the settle snapshot', () {
    Future<Map<String, Object?>> progressOf(String id) async {
      final rows = await db.customSelect(
        'SELECT * FROM message_progress WHERE source_message_id = ?',
        variables: [Variable<String>(id)],
      ).get();
      return Map<String, Object?>.from(rows.single.data);
    }

    NotificationCoordinator recording(MessageStore over) {
      final made = NotificationCoordinator(
        over,
        clock: () => now,
        progress: PipelineProgress(over),
      );
      addTearDown(made.dispose);
      made.noteSyncCompleted();
      return made;
    }

    test('a verdict that lands mid-sweep is the one the snapshot takes',
        () async {
      // The candidates are captured at the top of the sweep and settled at the
      // bottom of it. A verdict written in between used to be lost for good:
      // the settle snapshotted the stale answer, and the correction refuses a
      // row that was not settled yet when it ran.
      final racing = _RacingStore(db);
      final coordinator = recording(racing);

      await seedCandidate(needsYouVerdict: false, replyExpected: false);
      racing.onCandidatesRead = () => store.writeNeedsYouVerdict(
            'email',
            'm-1',
            verdict: true,
            reason: 'raced',
          );

      await coordinator.sweep();
      await pumpEventQueue();

      expect((await progressOf('m-1'))['needs_you'], 1);
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('a gated settle never carries a chip', () async {
      // The gate's answer beats the verdict: a dropped row is hidden from the
      // feed, so a chip on it would only be a number nobody can open.
      final coordinator = recording(store);
      await seedCandidate(needsYouVerdict: true, triageStatus: 'pending');
      await coordinator.sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.writeTriage(
        'email',
        'm-1',
        status: 'skipped',
        gateReason: 'newsletter',
      );
      await coordinator.sweep();
      await pumpEventQueue();

      final row = await progressOf('m-1');
      expect(row['needs_you'], 0);
      expect(row['dropped'], 1);
    });
  });
}

/// A store that lets a test write to the database in the window between the
/// sweep reading its candidates and settling them.
class _RacingStore extends MessageStore {
  _RacingStore(super.db);

  Future<void> Function()? onCandidatesRead;

  @override
  Future<List<Map<String, Object?>>> openNotifyCandidates({
    int limit = 50,
  }) async {
    final rows = await super.openNotifyCandidates(limit: limit);
    await onCandidatesRead?.call();
    return rows;
  }
}
