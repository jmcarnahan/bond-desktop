import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/data/progress_sql.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The needs-you verdict, rendered twice: once by `notifyWorthy` in Dart and
/// once by `needsYouSql` in SQLite.
///
/// They have to agree, and the failure they exist to prevent is a visible one.
/// `notifyWorthy` decides the TOAST the user sees and the `needs_you` snapshot
/// the settle stores with it; `needsYouSql` writes the same column for every
/// row the coordinator never saw — history at migration time, and the messages
/// that were never admitted as candidates. A disagreement means the Needs You
/// tile on the home screen contradicts the notification it came from, for one
/// message, with nothing in the app able to say which is right.
///
/// The tests below pin agreement on the clause this phase added, using a
/// message whose triage asks nothing at all: the verdict is then the only
/// thing either side can be answering.
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
  /// conversation — carrying [verdict] in `needs_you_verdict`.
  Future<void> seed(bool? verdict) async {
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
    await store.writeTriage(
      'email',
      'm-onboarding',
      status: 'triaged',
      result: const TriageResult(
        urgency: 'normal',
        category: 'work',
        summary: 'Alex Rivera wrote up where onboarding stands.',
        needsAction: false,
        actionItems: [],
        replyExpected: false,
        deadline: '',
      ),
    );
    if (verdict != null) {
      await store.writeNeedsYouVerdict(
        'email',
        'm-onboarding',
        verdict: verdict,
        reason: 'names the owner and asks them to pick a date',
      );
    }
    // Last, so the score is not older than the row it scores.
    await store.writeAttentionScore('email', 'conv-onboarding', 0.9);
  }

  /// What the SQL half says about the seeded message.
  Future<int?> sqlVerdict() async {
    final rows = await db.customSelect(
      'SELECT ${needsYouSql(threshold: '0.5')} AS needs_you '
      'FROM messages m WHERE m.source = ? AND m.source_message_id = ?',
      variables: [Variable('email'), Variable('m-onboarding')],
    ).get();
    return rows.single.data['needs_you'] as int?;
  }

  /// What the Dart half says, off the REAL candidate row — the same map shape
  /// the sweep judges, rather than one hand-built here that could quietly stop
  /// matching what the store projects.
  Future<bool> dartVerdict() async {
    await store.admitNotifyCandidates(
      armedAtIso: armedAt,
      recencyFloorIso: recencyFloor,
      deadlineIso: deadline,
    );
    final rows = await store.openNotifyCandidates();
    final row = rows.singleWhere(
      (r) => r['source_message_id'] == 'm-onboarding',
    );
    return notifyWorthy(row, threshold: 0.5);
  }

  test('a judged yes is worthy on both sides', () async {
    await seed(true);

    expect(await sqlVerdict(), 1);
    expect(await dartVerdict(), isTrue);
  });

  test('a judged no is unworthy on both sides', () async {
    await seed(false);

    expect(await sqlVerdict(), 0);
    expect(await dartVerdict(), isFalse);
  });

  test('an unjudged message is unworthy on both sides', () async {
    await seed(null);

    expect(await sqlVerdict(), 0);
    expect(await dartVerdict(), isFalse);
  });

  test('the migration keeps a copy of the SQL that predates the column', () {
    // `from7To8` replays on every v1..v7 database an at-or-past-v10 build
    // opens, and `needs_you_verdict` does not exist until v10. The frozen arm
    // is what keeps that migration from asking for a column that is not there
    // yet; the default is what every live caller gets.
    expect(
      needsYouSql(threshold: '0.5', verdict: false),
      isNot(contains('needs_you_verdict')),
    );
    expect(needsYouSql(threshold: '0.5'), contains('needs_you_verdict'));
  });
}
