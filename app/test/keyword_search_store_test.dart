// `show BondDatabase`: drift generates row classes whose names collide with
// the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The word half of a search, against a real database.
///
/// What is worth pinning here is everything the meaning half cannot do:
/// dropped mail is findable, an exact number or address matches, the query is
/// read as words rather than as FTS5 syntax, and a row that matched one word
/// of two says so.
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
    String fromName = 'Dana Whitfield',
    String fromAddress = 'dana@example.com',
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
      'from_name': fromName,
      'from_address': fromAddress,
      'received_at': receivedAt,
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

  Future<List<KeywordHit>> hitsFor(
    String query, {
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async =>
      (await store.keywordSearchMessages(
        query,
        includeDropped: includeDropped,
        sources: sources,
      ))!;

  Future<List<String>> idsFor(
    String query, {
    bool includeDropped = false,
    List<String> sources = const ['email', 'teams'],
  }) async =>
      [
        for (final hit in await hitsFor(
          query,
          includeDropped: includeDropped,
          sources: sources,
        ))
          hit.row.sourceMessageId,
      ];

  test('a term matches in any of the text columns', () async {
    await seed('subj', subject: 'Invoice 4471 is overdue');
    await seed('prev', bodyPreview: 'the invoice');
    await seed('body', bodyText: 'about an invoice');
    await seed('none', subject: 'Parking permit');

    expect((await idsFor('invoice')).toSet(), {'subj', 'prev', 'body'});
  });

  test('the stemmer means a plural finds a singular', () async {
    await seed('m1', subject: 'Weekly roundup', bodyText: 'the plan for June');

    // `porter` is why: no prefix wildcard is written anywhere, and none is
    // needed.
    expect(await idsFor('plans'), ['m1']);
  });

  test('case does not matter, in either direction', () async {
    await seed('upper', subject: 'Invoice 4471');
    await seed('lower', subject: 'the invoice again');

    expect((await idsFor('invoice')).toSet(), {'upper', 'lower'});
    expect((await idsFor('INVOICE')).toSet(), {'upper', 'lower'});
  });

  group('the query is read as words, never as syntax', () {
    test('a hyphen is not an exclusion', () async {
      await seed('m1', subject: 'Retool rollout', bodyText: 'the test account');
      await seed('m2', subject: 'Parking permit');

      // Unquoted, FTS5 reads `-test` as "and NOT test" and this row is the one
      // it would throw away.
      expect(await idsFor('retool -test'), ['m1']);
    });

    test('a colon is not a column filter', () async {
      await seed('m1', subject: 'CRM login is broken');

      // `crm:login` unquoted asks FTS5 for the token "login" in a column named
      // `crm`, which does not exist — a raised error, not a narrower search.
      expect(await idsFor('crm:login'), ['m1']);
    });

    test('a bare NOT is a word', () async {
      await seed('m1', subject: 'Not urgent, but please read');
      await seed('m2', subject: 'Parking permit');

      // `not` alone is every word of the query, so the stopword list stands
      // down and it reaches FTS5 quoted — where unquoted it is the operator
      // that would have raised rather than searched.
      expect(await idsFor('NOT'), ['m1']);
    });

    test('a quote in the query does not end the term', () async {
      await seed('m1', subject: "Dana's invoice");

      expect(await idsFor("dana's"), ['m1']);
    });
  });

  test('a query of nothing but stopwords still searches', () async {
    await seed('m1', subject: 'How are you');
    await seed('m2', subject: 'Parking permit');

    // Stripping every word would answer a real question with silence, so the
    // stopword list stands down when it would empty the query.
    expect(await idsFor('how are you'), ['m1']);
  });

  test('a query with no words in it is not a question', () async {
    await seed('m1', subject: 'Invoice 4471');

    // A blank box must never return the mailbox.
    expect(await store.keywordSearchMessages(''), isEmpty);
    expect(await store.keywordSearchMessages('   '), isEmpty);
    expect(await store.keywordSearchMessages('!!'), isEmpty);
  });

  test('a query of nothing but apostrophes is an answer, not an error',
      () async {
    await seed('m1', subject: 'Invoice 4471');

    // The apostrophe is a word character to the tokeniser, so this is the one
    // input that reaches FTS5 as a real expression matching nothing. Quoted,
    // it comes back empty rather than raising.
    expect(await store.keywordSearchMessages("'''"), isEmpty);
  });

  test('the sender is searchable by name and by address', () async {
    await seed(
      'm1',
      subject: 'Weekly roundup',
      fromName: 'Dana Whitfield',
      fromAddress: 'dana@example.com',
    );
    await seed(
      'm2',
      subject: 'Weekly roundup',
      fromName: 'Priya Raman',
      fromAddress: 'priya@northgate.test',
    );

    expect(await idsFor('dana'), ['m1']);
    expect(await idsFor('whitfield'), ['m1']);
    // The address is tokenized on its punctuation, so the domain is a word of
    // its own — which is what makes "everything from example.com" a search.
    expect(await idsFor('example'), ['m1']);
  });

  test('a subject match outranks a body-only match', () async {
    await seed('subject', subject: 'The escalator clause');
    await seed(
      'body',
      subject: 'Weekly roundup',
      bodyText: 'somewhere in here we mention the escalator clause again',
    );

    final hits = await hitsFor('escalator');

    // The column weights are the whole reason: a person searching their mail
    // is nearly always reaching for a subject line they half remember.
    expect(hits.first.row.sourceMessageId, 'subject');
    expect(hits.first.bm25, greaterThan(hits.last.bm25));
  });

  test('coverage is the fraction of the query a row actually contains',
      () async {
    await seed('both', subject: 'Invoice renewal');
    await seed('one', subject: 'Invoice 4472');

    final hits = {
      for (final hit in await hitsFor('invoice renewal'))
        hit.row.sourceMessageId: hit.coverage,
    };

    expect(hits['both'], 1.0);
    expect(hits['one'], 0.5);
  });

  group('the dropped filter', () {
    setUp(() async {
      await seed('kept', subject: 'Invoice 4471 is overdue');
      await seed('gated', subject: 'Invoice from the newsletter', dropped: true);
    });

    test('home hides dropped mail, the way its table does', () async {
      expect(await idsFor('invoice'), ['kept']);
    });

    test('and the archive asks for it, which is why the read exists', () async {
      // The gated message has no vector at all — it never reached the embedder
      // — so this pass is the only thing that can find it.
      expect(
        (await idsFor('invoice', includeDropped: true)).toSet(),
        {'kept', 'gated'},
      );
    });
  });

  test('sources narrows the answer, and no source is no answer', () async {
    await seed('mail-1', subject: 'Invoice 4471');
    await seed('chat-1', source: 'teams', subject: 'Invoice 4471');

    expect(await idsFor('invoice', sources: const ['teams']), ['chat-1']);
    expect(await idsFor('invoice', sources: const ['email']), ['mail-1']);
    expect((await idsFor('invoice'))..sort(), ['chat-1', 'mail-1']);
    expect(
      await store.keywordSearchMessages('invoice', sources: const []),
      isEmpty,
    );
  });

  test('the rows come back whole, the way the feed reads them', () async {
    await seed('gated', subject: 'Invoice 4471 is overdue', dropped: true);

    final row =
        (await hitsFor('invoice', includeDropped: true)).single.row;

    expect(row.subject, 'Invoice 4471 is overdue');
    expect(row.fromName, 'Dana Whitfield');
    expect(row.fromAddress, 'dana@example.com');
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

    expect(
      await store.keywordSearchMessages('invoice', limit: 2),
      hasLength(2),
    );
  });

  group('over document passages', () {
    Future<void> attach(
      String messageId,
      String attachmentId, {
      required String name,
      required List<({int seq, String locator, String text})> passages,
    }) async {
      await store.upsertAttachments('email', messageId, [
        {
          'attachment_id': attachmentId,
          'ordinal': 0,
          'kind': 'file',
          'name': name,
          'content_type': 'application/pdf',
          'size': 240 * 1024,
        },
      ]);
      await store.replaceChunks('email', messageId, attachmentId, passages);
    }

    test('a digest passage never surfaces', () async {
      await seed('m1');
      await attach(
        'm1',
        'a1',
        name: 'Rent Roll.xlsx',
        passages: const [
          (seq: 0, locator: 'part 1', text: 'Line 14: escalator of three percent.'),
          (seq: 1, locator: 'digest', text: 'A lease with an escalator clause.'),
        ],
      );

      final hits = (await store.keywordSearchChunks('escalator'))!;

      // A search result promises the document's OWN words. A digest is a
      // model's summary of them.
      expect(hits, hasLength(1));
      expect(hits.single.locator, 'part 1');
    });

    test('a dropped message hides its documents too, unless asked', () async {
      await seed('gated', dropped: true);
      await attach(
        'gated',
        'a1',
        name: 'Rent Roll.xlsx',
        passages: const [
          (seq: 0, locator: 'part 1', text: 'Line 14: escalator of three percent.'),
        ],
      );

      expect(await store.keywordSearchChunks('escalator'), isEmpty);
      expect(
        (await store.keywordSearchChunks('escalator', includeDropped: true))!,
        hasLength(1),
      );
    });
  });
}
