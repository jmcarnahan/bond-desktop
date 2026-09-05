// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The archive's text read, against a real database.
///
/// What is worth pinning here is everything the semantic half cannot do:
/// dropped mail is findable, a query with a wildcard in it means the wildcard
/// literally, and two words narrow rather than widen.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  /// One message, plus the `message_progress` row `upsertMessage` writes with
  /// it, moved to whichever side of the gate this test needs.
  Future<void> seed(
    String id, {
    String source = 'email',
    String subject = 'Weekly roundup',
    String? bodyPreview,
    String? bodyText,
    String receivedAt = '2026-09-01T10:00:00Z',
    bool dropped = false,
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': 'c-$id',
      'direction': 'inbound',
      'subject': subject,
      'body_preview': bodyPreview,
      'body_text': bodyText,
      'from_name': 'Alex Rivera',
      'from_address': 'alex.rivera@example.com',
      'received_at': receivedAt,
      'created_at': receivedAt,
      'updated_at': receivedAt,
    });
    await db.customUpdate(
      "UPDATE message_progress SET dropped = ?, drop_reason = ?, "
      "outcome = ?, triage_state = 'done', settle_state = 'done' "
      'WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable(dropped ? 1 : 0),
        Variable(dropped ? 'newsletter' : null),
        Variable(dropped ? 'dropped' : 'done'),
        Variable(source),
        Variable(id),
      ],
    );
  }

  Future<List<String>> idsFor(String query) async => [
        for (final row in await store.textSearchMessages(query))
          row.sourceMessageId,
      ];

  test('a term matches in any of the three text columns', () async {
    await seed('subj', subject: 'Invoice 4471 is overdue');
    await seed('prev', subject: 'Weekly roundup', bodyPreview: 'the invoice');
    await seed('body', subject: 'Weekly roundup', bodyText: 'about an invoice');
    await seed('none', subject: 'Parking permit');

    expect((await idsFor('invoice')).toSet(), {'subj', 'prev', 'body'});
  });

  test('two terms narrow, and may sit in different columns of one message',
      () async {
    await seed('both', subject: 'Invoice 4471', bodyText: 'renewal attached');
    await seed('one', subject: 'Invoice 4472', bodyText: 'nothing else here');
    await seed('other', subject: 'Parking renewal');

    expect(await idsFor('invoice renewal'), ['both']);
  });

  test('case does not matter, in either direction', () async {
    await seed('upper', subject: 'Invoice 4471');
    await seed('lower', subject: 'the invoice again');

    expect((await idsFor('invoice')).toSet(), {'upper', 'lower'});
    expect((await idsFor('INVOICE')).toSet(), {'upper', 'lower'});
  });

  test('a percent in the query is a percent, not "anything"', () async {
    await seed('literal', subject: '50% off renewals');
    await seed('wild', subject: '50 of anything');

    // Unescaped, `50%` would match both — the second is exactly the row a
    // wildcard would drag in.
    expect(await idsFor('50%'), ['literal']);
  });

  test('an underscore in the query is an underscore, not "any character"',
      () async {
    await seed('literal', subject: 'alex_rivera build');
    await seed('wild', subject: 'alexArivera build');

    expect(await idsFor('alex_rivera'), ['literal']);
  });

  test('a backslash in the query is a backslash', () async {
    // The escape character itself: escaped last, it would arrive at sqlite
    // escaping the escapes written around it.
    await seed('slash', subject: r'path\to invoice');
    await seed('plain', subject: 'path to invoice');

    expect(await idsFor(r'path\to'), ['slash']);
  });

  test('dropped messages are always in the answer', () async {
    await seed('kept', subject: 'Invoice 4471', dropped: false);
    await seed('gated', subject: 'Invoice 4472', dropped: true);

    // The whole reason this read exists: the gated one has no vector and would
    // otherwise be findable by nothing at all.
    expect((await idsFor('invoice')).toSet(), {'kept', 'gated'});
  });

  test('newest first', () async {
    await seed('old', subject: 'Invoice 1', receivedAt: '2026-09-01T09:00:00Z');
    await seed('new', subject: 'Invoice 2', receivedAt: '2026-09-01T11:00:00Z');
    await seed('mid', subject: 'Invoice 3', receivedAt: '2026-09-01T10:00:00Z');

    expect(await idsFor('invoice'), ['new', 'mid', 'old']);
  });

  test('the rows come back whole, the way the feed reads them', () async {
    await seed('gated', subject: 'Invoice 4471 is overdue', dropped: true);

    final row = (await store.textSearchMessages('invoice')).single;

    expect(row.subject, 'Invoice 4471 is overdue');
    expect(row.fromName, 'Alex Rivera');
    expect(row.fromAddress, 'alex.rivera@example.com');
    expect(row.conversationKey, 'c-gated');
    expect(row.receivedAt, '2026-09-01T10:00:00Z');
    expect(row.dropped, true);
    expect(row.dropReason, 'newsletter');
  });

  test('the limit is honoured', () async {
    for (var i = 0; i < 5; i++) {
      await seed(
        'd$i',
        subject: 'Invoice $i',
        receivedAt: '2026-09-0${i + 1}T10:00:00Z',
      );
    }

    expect(await store.textSearchMessages('invoice', limit: 2), hasLength(2));
  });

  test('a query with no words in it is not a question', () async {
    await seed('any', subject: 'Invoice 4471');

    // Empty and whitespace both: a bare `%%` would otherwise return the whole
    // mailbox, which is the one answer a blank box must never give.
    expect(await store.textSearchMessages(''), isEmpty);
    expect(await store.textSearchMessages('   '), isEmpty);
    expect(await store.textSearchMessages('\n \t'), isEmpty);
  });

  test('no source is no answer', () async {
    await seed('any', subject: 'Invoice 4471');

    expect(await store.textSearchMessages('invoice', sources: const []),
        isEmpty);
  });
}
