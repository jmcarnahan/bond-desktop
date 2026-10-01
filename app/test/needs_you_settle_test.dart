import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/data/progress_sql.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';

/// The needs-you rule, rendered twice: once by `notifyWorthy` in Dart and once
/// by `needsYouSql` in SQLite.
///
/// They have to agree, and the failure they exist to prevent is a visible one.
/// `notifyWorthy` decides the TOAST the user sees and the `needs_you` snapshot
/// the settle stores with it; `needsYouSql` writes the same column for every
/// row the coordinator never saw — history at migration time, and the messages
/// that were never admitted as candidates. A disagreement means the Needs You
/// tile on the home screen contradicts the notification it came from, for one
/// message, with nothing in the app able to say which is right.
///
/// The tests below pin agreement on the one ask both sides read — the
/// message's needs-you probability against the slider — using a message
/// whose triage asks nothing at all, and then one whose triage asks
/// everything, to show triage's asks are no part of either side.
///
/// One divergence is intended and documented on both sides: the SQL carries an
/// `is_read = 0` guard and the Dart does not. The coordinator's decision table
/// suppresses a read message before worthiness is ever asked, so `notifyWorthy`
/// never sees one; the SQL, which judges rows no coordinator looked at, has to
/// carry the guard itself.
void main() {
  late BondDatabase db;
  late MessageStore store;

  /// Well before the seeded message, so admission's `created_at >` and
  /// `received_at >=` floors both pass.
  const armedAt = '2026-09-04T09:00:00.000Z';
  const recencyFloor = '2026-09-04T03:00:00.000Z';
  const deadline = '2026-09-04T10:06:00.000Z';

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One unread inbound message on a scored thread, triaged as asking NOTHING
  /// — no reply expected, no action, normal urgency, no deadline, no CTA on the
  /// conversation — carrying [p] in `needs_you_p`.
  ///
  /// [triageAsks] flips triage to the Jira-broadcast shape instead: a reply
  /// expected and an action item, neither of which asks on either side.
  Future<void> seed(double? p, {bool triageAsks = false}) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'conv-onboarding',
      'subject': 'Onboarding notes',
      'state': 'needs_reply',
      'last_message_at': '2026-09-04T09:55:00.000Z',
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm-onboarding',
      'conversation_key': 'conv-onboarding',
      'direction': 'inbound',
      'subject': 'Onboarding notes',
      'from_name': 'Priya Natarajan',
      'from_address': 'priya.natarajan@example.com',
      'received_at': '2026-09-04T09:55:00.000Z',
      'is_read': 0,
      'created_at': '2026-09-04T09:56:00.000Z',
    });
    await writeTriaged(
      store,
      'email',
      'm-onboarding',
      status: 'triaged',
      urgency: 'normal',
      category: 'work',
      summary: 'Alex Rivera wrote up where onboarding stands.',
      needsAction: triageAsks,
      actionItems: triageAsks ? const ['Review the issue'] : const [],
      replyExpected: triageAsks,
      deadline: '',
    );
    if (p != null) {
      await store.writeNeedsYouP(
        'email',
        'm-onboarding',
        p: p,
        reason: 'names the owner and asks them to pick a date',
      );
    }
    // Last, so the score is not older than the row it scores.
    await store.writeAttentionScore('email', 'conv-onboarding', 0.9);
  }

  /// What the SQL half says about the seeded message at [threshold].
  Future<int?> sqlVerdict({double threshold = 0.5}) async {
    final rows = await db.customSelect(
      'SELECT ${needsYouSql(threshold: '$threshold')} AS needs_you '
      'FROM messages m WHERE m.source = ? AND m.source_message_id = ?',
      variables: [Variable('email'), Variable('m-onboarding')],
    ).get();
    return rows.single.data['needs_you'] as int?;
  }

  /// What the Dart half says, off the REAL candidate row — the same map shape
  /// the sweep judges, rather than one hand-built here that could quietly stop
  /// matching what the store projects.
  Future<bool> dartVerdict({double threshold = 0.5}) async {
    await store.admitNotifyCandidates(
      armedAtIso: armedAt,
      recencyFloorIso: recencyFloor,
      deadlineIso: deadline,
    );
    final rows = await store.openNotifyCandidates();
    final row = rows.singleWhere(
      (r) => r['source_message_id'] == 'm-onboarding',
    );
    return notifyWorthy(row, threshold: threshold);
  }

  test("a thread's CTA is no ask on either side", () async {
    await seed(null);
    await store.updateConversationTriage('email', 'conv-onboarding',
        ctaText: 'Send the appraisal', ctaUrgency: 'urgent');
    await store.writeAttentionScore('email', 'conv-onboarding', 0.9);

    expect(await sqlVerdict(), 0);
    expect(await dartVerdict(), isFalse);
  });

  test('a probability over the slider is worthy on both sides', () async {
    await seed(0.9);

    expect(await sqlVerdict(), 1);
    expect(await dartVerdict(), isTrue);
  });

  test('a probability exactly at the slider is worthy on both sides',
      () async {
    await seed(0.5);

    expect(await sqlVerdict(threshold: 0.5), 1);
    expect(await dartVerdict(threshold: 0.5), isTrue);
  });

  test('a probability below the slider is unworthy on both sides', () async {
    await seed(0.1);

    expect(await sqlVerdict(), 0);
    expect(await dartVerdict(), isFalse);
  });

  test('an undecided message is unworthy on both sides', () async {
    await seed(null);

    expect(await sqlVerdict(), 0);
    expect(await dartVerdict(), isFalse);
  });

  // Triage's asks are no part of the rule on either side: a broadcast read
  // as a reply expected with an action item is not the owner's while its
  // probability sits below the slider, nor while nothing has decided it.
  test("a low probability outranks triage's asks on both sides", () async {
    await seed(0.1, triageAsks: true);

    expect(await sqlVerdict(), 0);
    expect(await dartVerdict(), isFalse);
  });

  test("triage's asks alone ask nothing on either side", () async {
    await seed(null, triageAsks: true);

    expect(await sqlVerdict(), 0);
    expect(await dartVerdict(), isFalse);
  });

  test('the attention score gates neither side', () async {
    await seed(0.9);
    await store.writeAttentionScore('email', 'conv-onboarding', 0.01);

    expect(await sqlVerdict(), 1);
    expect(await dartVerdict(), isTrue);
  });

  test('a low_value Later cannot coexist with an open ask', () async {
    // D5's whole claim, pinned on the two predicates that still carry a
    // `bucket <> 'later'` clause. Neither of them was changed: what changed is
    // that the automatic filing can no longer put a thread with an unanswered
    // ask over the slider into Later, so the clause only ever bites on a Later
    // a person asked for.
    const at = '2026-09-04T09:55:00.000Z';
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'conv-quiet',
      'subject': 'Quarter close notes',
      'state': 'waiting',
      // On the conversation, not on the message: triage's loudness, which
      // lifts the thread's score and is no ask for either predicate.
      'cta_urgency': 'urgent',
      'last_message_at': at,
      'last_inbound_at': at,
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm-quiet',
      'conversation_key': 'conv-quiet',
      'direction': 'inbound',
      'subject': 'Quarter close notes',
      'from_name': 'Priya Natarajan',
      'from_address': 'priya@x.com',
      'received_at': at,
      'is_read': 0,
      'created_at': '2026-09-04T09:56:00.000Z',
    });
    await writeTriaged(
      store,
      'email',
      'm-quiet',
      status: 'triaged',
      urgency: 'normal',
      category: 'work',
      summary: 'Where the quarter close stands.',
      needsAction: false,
      actionItems: [],
      replyExpected: false,
      deadline: '',
    );
    // What the extraction made of it — exactly the pair the quiet rule defers
    // on.
    await store.writeExtraction(
      'email',
      'm-quiet',
      jsonEncode({'intent': 'fyi', 'importance': 'low'}),
    );
    await store.writeNeedsYouP('email', 'm-quiet',
        p: 0.9, reason: 'asks the owner to confirm the close date');

    // The sweep both scores and files, so it writes the bucket this asserts on
    // and the score both predicates read.
    await AttentionService(store).recomputeAll(now: DateTime.parse(at));

    expect(
      (await store.getConversationAi('email', 'conv-quiet'))?['bucket'],
      isNull,
    );

    final sqlRows = await db.customSelect(
      'SELECT ${needsYouSql(threshold: '0.5')} AS needs_you '
      'FROM messages m WHERE m.source = ? AND m.source_message_id = ?',
      variables: [Variable('email'), Variable('m-quiet')],
    ).get();
    expect(sqlRows.single.data['needs_you'], 1);

    await store.admitNotifyCandidates(
      armedAtIso: armedAt,
      recencyFloorIso: recencyFloor,
      deadlineIso: deadline,
    );
    final row = (await store.openNotifyCandidates())
        .singleWhere((r) => r['source_message_id'] == 'm-quiet');
    expect(notifyWorthy(row, threshold: 0.5), isTrue);
  });

  test('the migration keeps a copy of the SQL that predates the columns', () {
    // `from7To8` replays on every v1..v7 database a newer build opens, and
    // neither needs-you column exists yet when it runs. The frozen copy is
    // what keeps that migration from asking for a column that is not there;
    // the live rule is what every live caller gets. `progress_sql_test` pins
    // the frozen text byte for byte.
    expect(
      needsYouSqlV8Frozen(backfillNeedsYouThreshold),
      isNot(contains('needs_you')),
    );
    expect(needsYouSql(threshold: '0.5'), contains('needs_you_p'));
  });
}
