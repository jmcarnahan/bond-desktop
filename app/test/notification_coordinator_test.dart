import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
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

    test('an open extract work row holds the row open', () async {
      await seedCandidate();
      await store.enqueueWork('extract', 'email', 'm-1');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.writeWork('extract', 'email', 'm-1', status: 'done');
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test('an absent extract row counts as finished, not as pending', () async {
      // Never-queued is a real end state: a message the extractor was never
      // going to look at is not one to keep waiting on.
      await seedCandidate();
      await sweep();
      expect(await notifyRow('m-1'), containsPair('state', 'notified'));
    });

    test("a sibling thread's open storyline work holds the row open", () async {
      // Keyed by conversation, deliberately: announcing a message under the
      // wrong storyline is worse than announcing it a few seconds late.
      await seedCandidate();
      await store.enqueueWork('storyline', 'email', 'conv-1');
      await sweep();

      expect(await notifyRow('m-1'), containsPair('state', 'pending'));

      await store.writeWork('storyline', 'email', 'conv-1', status: 'done');
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

  group('deadline', () {
    test('an unfinished but worthy message is announced when time runs out',
        () async {
      // Complete and worthy on its own terms — what holds it open is the
      // storyline pass, which is also what makes the null storyline below mean
      // "not known yet" rather than "no storyline".
      await seedCandidate();
      await store.enqueueWork('storyline', 'email', 'conv-1');
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

    test('an unfinished, unremarkable message is dropped when time runs out',
        () async {
      await seedCandidate(attentionScore: null);
      await sweep();
      now = armedAt.add(const Duration(minutes: 7));
      await sweep();

      final row = await notifyRow('m-1');
      expect(row['state'], 'suppressed');
      expect(row['reason'], 'deadline');
      expect(emitted, isEmpty);
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
      await store.writeTriage('email', 'm-1',
          status: 'triaged',
          result: const TriageResult(
            urgency: 'high',
            category: 'work',
            summary: 'no subject line',
            needsAction: false,
            actionItems: [],
          ));
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
}
