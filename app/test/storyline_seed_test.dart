import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/clustering_card.dart';
import 'package:bond_inbox/services/conversation_state.dart';
import 'package:bond_inbox/services/llm/embeddings_client.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_embed_server.dart';
import 'fixtures/golden_set.dart';
import 'fixtures/golden_storyline.dart';
import 'fixtures/storyline_seed.dart';
import 'fixtures/test_db.dart';

/// The mailbox the sweep replay sweeps, against the FICTIONAL fixture.
///
/// The live run needs the real set and three servers, so what is pinned here
/// is the part that decides whether the pool it builds is the pool the app
/// has: which messages the gates kept, which rows are the owner's own, that a
/// conversation two items share is seeded once, and that the vector lands
/// under the tag every reader filters on. Each of those failing silently costs
/// a ninety-minute run that scores a mailbox nobody could have.
///
/// Several cases need a shape the seven-item fixture does not carry — a gold
/// DROP on a thread that has a tail, or two items of one conversation. Those
/// are built by mutating a deep copy of the fixture's own JSON rather than by
/// widening the committed file: the variant belongs to the test that needs it,
/// and the fixture stays the one thing every golden test reads.
void main() {
  const fixturePath = 'test/fixtures/golden_fixture.json';

  late BondDatabase db;
  late MessageStore store;
  late Map<String, dynamic> rawFixture;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    rawFixture =
        jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;
  });

  tearDown(() async => db.close());

  /// The fixture, optionally with one item edited. Deep-copied through JSON so
  /// a mutation cannot leak into the next test.
  GoldenSet setWith([void Function(Map<String, dynamic> raw)? mutate]) {
    final copy =
        jsonDecode(jsonEncode(rawFixture)) as Map<String, dynamic>;
    mutate?.call(copy);
    return GoldenSet.fromJson(copy);
  }

  Map<String, dynamic> itemIn(Map<String, dynamic> raw, String id) =>
      (raw['items'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((item) => item['id'] == id);

  /// A bulk run file's worth of cards for one item.
  GoldenCards cardsFor(
    String id, {
    List<String> topics = const ['fit-out schedule', 'capped allowance'],
    String summary = 'Dana asks for a decision on the allowance clause.',
  }) =>
      GoldenCards.fromRunJson([
        {
          'id': id,
          'extract': {'topics': topics},
          'triage': {'summary': summary},
        },
      ]);

  Future<SeedReport> seed(
    GoldenSet set, {
    GoldenCards? cards,
    ClusteringCardVariant variant = ClusteringCardVariant.participants,
    String prefix = EmbeddingsClient.clusteringPrefix,
    FakeEmbedServer? server,
  }) =>
      seedGoldenMailbox(
        store,
        set,
        cards ?? const GoldenCards({}),
        variant: variant,
        prefix: prefix,
        embeddings: (server ?? FakeEmbedServer()).client,
        ownerName: 'Alex Rivera',
        ownerAddress: 'alex@example.com',
      );

  Future<List<Map<String, Object?>>> messagesOf(String key) async =>
      (await store.db
              .customSelect(
                'SELECT source_message_id, direction, triage_status, '
                'gate_reason, from_name, from_address FROM messages '
                'WHERE conversation_key = ? ORDER BY source_message_id',
                variables: [Variable<String>(key)],
              )
              .get())
          .map((row) => Map<String, Object?>.from(row.data))
          .toList();

  test('a kept inbound item and its tail are triaged, the owner\'s send is not',
      () async {
    await seed(setWith());

    final rows = await messagesOf('email:fx-conv-lease');
    // The item's own message plus its three tail entries.
    expect(rows, hasLength(4));

    final outbound = rows.where((r) => r['direction'] == 'outbound').toList();
    // The `You` entry in the tail is the owner writing, and it is born
    // skipped/outbound through `triageStatusOnInsert` — never triaged.
    expect(outbound, hasLength(1));
    expect(outbound.single['triage_status'], 'skipped');
    expect(outbound.single['gate_reason'], 'outbound');
    expect(outbound.single['from_name'], 'Alex Rivera');
    expect(outbound.single['from_address'], 'alex@example.com');

    for (final row in rows.where((r) => r['direction'] == 'inbound')) {
      expect(row['triage_status'], 'triaged');
      expect(row['gate_reason'], isNull);
    }
  });

  test('a gold-drop item skips its own message AND every inbound tail row',
      () async {
    // `keptMessageSql` counts anything not `skipped` as kept, so one unmarked
    // thread message would put a gated thread straight back into the sweep
    // pool — the whole reason the drop covers the tail.
    final set = setWith((raw) {
      (itemIn(raw, 'email:fx-keep-tail')['gold']
          as Map<String, dynamic>)['gate'] = {'verdict': 'drop'};
    });
    final report = await seed(set);

    final rows = await messagesOf('email:fx-conv-lease');
    for (final row in rows.where((r) => r['direction'] == 'inbound')) {
      expect(row['triage_status'], 'skipped');
      expect(row['gate_reason'], goldDropGateReason);
    }
    expect(await store.keptInboundCount('email', 'email:fx-conv-lease'), 0);

    final thread = report.threads
        .firstWhere((t) => t.conversationKey == 'email:fx-conv-lease');
    expect(thread.keptInbound, isFalse);
    // Seeded anyway: the gated pool is a thing the app HAS, and a bench that
    // left it out would sweep a mailbox nobody has.
    expect(thread.embedded, isFalse);
    expect(report.gatedThreads, greaterThan(0));
  });

  test('a conversation two items share is seeded once', () async {
    final set = setWith((raw) {
      (itemIn(raw, 'email:fx-reply')['provenance']
          as Map<String, dynamic>)['conversation_key'] = 'email:fx-conv-lease';
    });
    final report = await seed(set);

    // Seven items, six threads — two golden items drawn from one conversation
    // are one thread, and the app files threads.
    expect(set.items, hasLength(7));
    expect(report.conversations, 6);
    expect(
      report.threads.where((t) => t.conversationKey == 'email:fx-conv-lease'),
      hasLength(1),
    );

    // Both items' messages and both tails landed on the one thread. The two
    // items' six messages carry six distinct stamps in this fixture, so
    // nothing is de-duplicated here and these are the true counts: four rows
    // from the tailed item and two from the reply, five of them inbound.
    final rows = await messagesOf('email:fx-conv-lease');
    expect(rows, hasLength(6));
    final conversation =
        await store.getConversationRow('email', 'email:fx-conv-lease');
    expect(conversation!['message_count'], 6);
    expect(conversation['inbound_count'], 5);
  });

  test('one underlying message is one row, and the gated verdict wins it',
      () async {
    // A thread tail is recorded as TEXT with a synthetic id per item, so the
    // same message reaches the seeding twice when two items share a thread.
    // Here the drop item quotes a message the keep item also carries.
    final set = setWith((raw) {
      final reply = itemIn(raw, 'email:fx-reply');
      (reply['provenance'] as Map<String, dynamic>)['conversation_key'] =
          'email:fx-conv-lease';
      (reply['gold'] as Map<String, dynamic>)['gate'] = {'verdict': 'drop'};
      final tail = ((reply['stage_input'] as Map<String, dynamic>)['ctx_tail3']
          as Map<String, dynamic>)['thread_tail'] as List;
      (tail.first as Map<String, dynamic>)
        ..['received_at'] = '2026-09-04T09:20:00Z'
        ..['text'] = 'Sending the draft addendum over for your read.';
    });
    await seed(set);

    final rows = await messagesOf('email:fx-conv-lease');
    final byId = {for (final row in rows) row['source_message_id']: row};

    // Five rows, not six: the drop item's quotation of the shared message is
    // the same message, and the FIRST id seen is the one that survives.
    expect(rows, hasLength(5));
    expect(byId.containsKey('email:fx-reply#t0'), isFalse);

    // The gated verdict wins the collision, because gold calling a thread a
    // drop has to cover every row of it.
    expect(byId['email:fx-keep-tail#t0']!['triage_status'], 'skipped');
    expect(byId['email:fx-keep-tail#t0']!['gate_reason'], goldDropGateReason);
    // The drop item's own message is skipped in its own right.
    expect(byId['email:fx-reply']!['triage_status'], 'skipped');
    // And the keep item's own message is untouched by any of it.
    expect(byId['email:fx-keep-tail']!['triage_status'], 'triaged');
    expect(byId['email:fx-keep-tail']!['gate_reason'], isNull);

    // Both counters are over the de-duplicated rows, so a thread two items
    // quote does not look twice as long as it is.
    final conversation =
        await store.getConversationRow('email', 'email:fx-conv-lease');
    expect(conversation!['message_count'], 5);
    expect(conversation['inbound_count'], 4);
    // Something of the thread is still kept, so it stays in the pool.
    expect(await store.keptInboundCount('email', 'email:fx-conv-lease'), 2);
  });

  test('the vector is written under the tag every reader filters on', () async {
    final server = FakeEmbedServer();
    final report = await seed(
      setWith(),
      cards: cardsFor('email:fx-keep-tail'),
      server: server,
    );

    final ai = await store.getConversationAi('email', 'email:fx-conv-lease');
    expect(ai!['embed_model'], EmbeddingsClient.modelTag);
    expect(ai['embedding'], isNotNull);
    expect(ai['embedded_hash'], isNotNull);
    expect(report.embedded, server.calls);
    expect(report.embedFailures, 0);

    // The pool `sweep()` reads is filtered on that tag, so this is the query
    // that says the seeding is visible at all.
    final pool = await store.conversationsWithEmbeddings(
      embedModel: EmbeddingsClient.modelTag,
      sources: const ['email', 'teams'],
    );
    expect(
      pool.map((row) => row['conversation_key']),
      contains('email:fx-conv-lease'),
    );
  });

  test('an embedding server that is down costs threads, never the run',
      () async {
    final report = await seed(setWith(), server: FakeEmbedServer(status: null));

    expect(report.embedded, 0);
    expect(report.embedFailures, report.keptThreads);
    expect(
      await store.getConversationAi('email', 'email:fx-conv-lease'),
      isNull,
    );
  });

  group('the card that is embedded', () {
    /// The card behind the one embed call for the lease thread, with the
    /// clustering prefix taken off.
    Future<String> cardFor(FakeEmbedServer server, GoldenSet set) async {
      final index = set.items
          .map((item) => '${item.source}\n${item.conversationKey}')
          .toSet()
          .toList()
          .indexOf('email\nemail:fx-conv-lease');
      final input = server.inputs[index];
      expect(input, startsWith(EmbeddingsClient.clusteringPrefix));
      return input.substring(EmbeddingsClient.clusteringPrefix.length);
    }

    test('carries the subject, the people, the topics and the summary',
        () async {
      final server = FakeEmbedServer();
      final set = setWith();
      await seed(set, cards: cardsFor('email:fx-keep-tail'), server: server);

      final segments = (await cardFor(server, set)).split(' | ');
      expect(segments, hasLength(4));
      expect(segments[0], 'Addendum for the River Street suite');
      expect(segments[1], 'Dana Whitfield, Alex Rivera, Priya Raman');
      expect(segments[2], 'fit-out schedule, capped allowance');
      expect(segments[3], 'Dana asks for a decision on the allowance clause.');
    });

    test('the topics variant leaves the people segment empty', () async {
      final server = FakeEmbedServer();
      final set = setWith();
      await seed(
        set,
        cards: cardsFor('email:fx-keep-tail'),
        variant: ClusteringCardVariant.topics,
        server: server,
      );

      final segments = (await cardFor(server, set)).split(' | ');
      // Empty, not absent: the card is four segments by contract, and a
      // three-segment card would make the hash disagree with itself.
      expect(segments, hasLength(4));
      expect(segments[1], isEmpty);
      expect(segments[0], 'Addendum for the River Street suite');
      expect(segments[2], 'fit-out schedule, capped allowance');
    });

    test('a thread the run file carded nothing for embeds its durable half',
        () async {
      final server = FakeEmbedServer();
      final set = setWith();
      await seed(set, server: server);

      final segments = (await cardFor(server, set)).split(' | ');
      expect(segments, hasLength(4));
      expect(segments[2], isEmpty);
      expect(segments[3], isEmpty);
    });
  });

  group('the prefix and the width', () {
    test('the prefix rides in front of the card, trailing space and all',
        () async {
      // The candidate models document their own wording and several of them
      // end in a space. `make` and `--dart-define` both pass it through
      // quoted, and nothing between the define and the wire may trim it.
      const prefix = 'Instruct: group these | Query: ';
      final server = FakeEmbedServer();
      final report = await seed(setWith(), prefix: prefix, server: server);

      expect(report.prefixLength, prefix.length);
      for (final input in server.inputs) {
        expect(input, startsWith(prefix));
        // The card itself, not a second copy of the prefix.
        expect(input.substring(prefix.length), isNot(startsWith('Instruct:')));
      }
    });

    test('an empty prefix sends the card bare', () async {
      final server = FakeEmbedServer();
      final report = await seed(setWith(), prefix: '', server: server);

      expect(report.prefixLength, 0);
      expect(
        server.inputs.first,
        isNot(startsWith(EmbeddingsClient.clusteringPrefix)),
      );
    });

    test('the report carries the width of the first vector', () async {
      final report = await seed(setWith(), server: FakeEmbedServer());

      // A candidate model at another width is a different geometry, and a row
      // that did not say so would read as a comparison of two vectors in one
      // space. The fixture answers at the SHIPPED width, so this also pins
      // that the report reads the vector rather than a constant.
      expect(report.embedded, greaterThan(0));
      expect(report.dims, embedDims);
      expect(report.table(), contains('$embedDims dims'));
    });

    test('nothing embedded leaves the width at zero', () async {
      final report = await seed(
        setWith(),
        server: FakeEmbedServer(status: 500),
      );

      expect(report.embedded, 0);
      expect(report.dims, 0);
    });
  });

  test('the triage summary and the topics land where the app looks for them',
      () async {
    await seed(setWith(), cards: cardsFor('email:fx-keep-tail'));

    final cardData =
        await store.newestInboundCardData('email', 'email:fx-conv-lease');
    expect(cardData!['summary'],
        'Dana asks for a decision on the allowance clause.');
    expect(
      jsonDecode(cardData['extraction_json']! as String),
      {
        'topics': ['fit-out schedule', 'capped allowance'],
      },
    );
  });

  test('a gold-drop item is never triaged, however good its card', () async {
    final set = setWith((raw) {
      (itemIn(raw, 'email:fx-drop-notification')['gold']
          as Map<String, dynamic>)['gate'] = {'verdict': 'drop'};
    });
    await seed(set, cards: cardsFor('email:fx-drop-notification'));

    final rows = await messagesOf('email:fx-conv-weekly');
    expect(rows.single['triage_status'], 'skipped');
    // Nothing was written into the row the card would have come from.
    final cardData =
        await store.newestInboundCardData('email', 'email:fx-conv-weekly');
    expect(cardData!['summary'], isNull);
  });

  test('the thread carries the state and the newest stamp the set recorded',
      () async {
    final report = await seed(setWith());

    final conversation =
        await store.getConversationRow('email', 'email:fx-conv-lease');
    expect(conversation!['state'], 'needs_reply');
    // The newest of the item's message and its tail — the column the sweep
    // pool orders by, so two runs see one order.
    expect(conversation['last_message_at'], '2026-09-08T14:12:33Z');
    expect(
      report.threads
          .firstWhere((t) => t.conversationKey == 'email:fx-conv-lease')
          .lastMessageAt,
      '2026-09-08T14:12:33Z',
    );
  });

  group('seedThread', () {
    test('a seeded vector brings the kept inbound message it implies',
        () async {
      await seedThread(store, 'c1', vector: [1, 0]);

      expect(await store.keptInboundCount('email', 'c1'), 1);
      expect(
        (await store.conversationsWithEmbeddings(
          embedModel: EmbeddingsClient.modelTag,
        ))
            .map((row) => row['conversation_key']),
        ['c1'],
      );
    });

    test('keptInbound: false builds the gated thread on purpose', () async {
      await seedThread(store, 'c1', vector: [1, 0], keptInbound: false);

      expect(await store.keptInboundCount('email', 'c1'), 0);
      expect(
        await store.conversationsWithEmbeddings(
          embedModel: EmbeddingsClient.modelTag,
        ),
        isEmpty,
      );
    });

    test('no vector is a conversation and nothing else', () async {
      await seedThread(store, 'c1', participants: const ['Dana Whitfield']);

      expect(await store.getConversationAi('email', 'c1'), isNull);
      final conversation = await store.getConversationRow('email', 'c1');
      expect(conversation!['participants_json'], '[{"name":"Dana Whitfield"}]');
    });

    test('the counters and the sender reach the pool row', () async {
      // The three facts the series pre-pass reads. A test that means to build
      // a notification feed needs all three, and they have to arrive through
      // the query the sweep actually runs rather than through the columns.
      await seedThread(
        store,
        'c1',
        vector: [1, 0],
        messageCount: 4,
        inboundCount: 3,
        fromAddress: 'ops@example.com',
      );

      final row = (await store.conversationsWithEmbeddings(
        embedModel: EmbeddingsClient.modelTag,
      ))
          .single;
      expect(row['message_count'], 4);
      expect(row['inbound_count'], 3);
      expect(row['newest_kept_from'], 'ops@example.com');
    });

    test('the default subject gives every key its own series key', () async {
      // The fixture spells its digits out, because `seriesKeyFor` folds every
      // digit run: left as written, three default threads would be one
      // unanswered single-sender series and the pre-pass would drop them.
      await seedThread(store, 'c1', vector: [1, 0]);
      await seedThread(store, 'c2', vector: [1, 0]);

      final subjects = [
        for (final row in await store.conversationsWithEmbeddings(
          embedModel: EmbeddingsClient.modelTag,
        ))
          row['subject'] as String,
      ];
      expect(subjects, hasLength(2));
      expect(seriesKeyFor(subjects.first), isNot(seriesKeyFor(subjects.last)));
    });
  });
}
