import 'dart:math' as math;

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/services/search_fusion.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ranking, with no database and no server under it.
///
/// Every number here is an input the test states, which is the point: the
/// fusion is the one place a search decides what "good enough to show" means,
/// and a rule that could only be checked against a live mailbox would be a
/// rule nobody could change safely.

HomeFeedRow row(
  String id, {
  String source = 'email',
  String receivedAt = '2026-09-01T10:00:00Z',
  String? subject,
}) =>
    HomeFeedRow(
      source: source,
      sourceMessageId: id,
      conversationKey: 'c-$id',
      receivedAt: receivedAt,
      triageState: 'done',
      extractState: 'done',
      storylineState: 'done',
      draftState: 'skipped',
      settleState: 'done',
      outcome: 'done',
      dropped: false,
      subject: subject ?? id,
    );

AttachmentChunkHit chunk(
  int id, {
  required String name,
  int size = 1024,
  String? sha,
  double? distance,
  double? bm25,
  double? coverage,
}) =>
    AttachmentChunkHit(
      ref: AttachmentRef(
        source: 'email',
        messageId: 'm-$id',
        attachmentId: 'a-$id',
        name: name,
        size: size,
        blobSha256: sha,
      ),
      chunkId: id,
      seq: 0,
      locator: 'part 1',
      text: 'passage $id',
      outbound: false,
      distance: distance,
      bm25: bm25,
      coverage: coverage,
    );

void main() {
  group('the vector ramp', () {
    test('runs from 1 at the near end to 0 at the far end', () {
      // 0.45 is as good as this corpus gets and 0.80 is past the point where
      // anything is real — both measured, not chosen.
      expect(vectorRelevance(SearchTuning.vectorNear), 1.0);
      expect(vectorRelevance(SearchTuning.vectorFar), 0.0);
      expect(vectorRelevance(0.625), closeTo(0.5, 1e-9));
    });

    test('clamps rather than running off either end', () {
      expect(vectorRelevance(0.0), 1.0);
      expect(vectorRelevance(1.4), 0.0);
    });
  });

  group('the keyword score', () {
    test('is a fraction of the best score this query found', () {
      expect(
        keywordRelevance(bm25: 3.0, best: 6.0, coverage: 1),
        closeTo(0.5, 1e-9),
      );
      expect(keywordRelevance(bm25: 6.0, best: 6.0, coverage: 1), 1.0);
    });

    test('is discounted by the square root of coverage', () {
      // A passage that matched one rare term of three can top the bm25
      // ranking on that term's rarity alone. `sqrt` discounts it without
      // erasing it.
      expect(
        keywordRelevance(bm25: 6.0, best: 6.0, coverage: 1 / 3),
        closeTo(math.sqrt(1 / 3), 1e-9),
      );
    });

    test('a query that matched nothing scores nothing rather than dividing '
        'by zero', () {
      expect(keywordRelevance(bm25: 0, best: 0, coverage: 1), 0);
    });
  });

  group('buildFtsQuery', () {
    test('drops the function words and quotes what is left', () {
      final query = buildFtsQuery('what messages are about the lunch plans')!;

      expect(query.terms, ['lunch', 'plans']);
      expect(query.match, '"lunch" OR "plans"');
    });

    test('keeps every word when dropping them would empty the query', () {
      final query = buildFtsQuery('how are you')!;

      // Answering a real question with silence because every word of it is
      // common would be worse than answering it badly.
      expect(query.terms, ['how', 'are', 'you']);
    });

    test('reads FTS5 operators as words', () {
      expect(buildFtsQuery('retool -test')!.match, '"retool" OR "test"');
      expect(buildFtsQuery('crm:login')!.match, '"crm" OR "login"');
      // `not` is a function word and goes with the rest of them — but it is
      // never handed to FTS5 as the operator it would otherwise be, which is
      // what the all-stopword fallback below has to prove.
      expect(buildFtsQuery('NOT urgent')!.match, '"urgent"');
      expect(buildFtsQuery('NOT')!.match, '"not"');
    });

    test('a distance that is not a number scores nothing', () {
      // `clamp` compares, and every comparison against NaN is false — so
      // without the guard a NaN would clear the floor and then sort ABOVE
      // every real hit under `double.compareTo`'s total order.
      expect(vectorRelevance(double.nan), 0);
      expect(vectorRelevance(double.infinity), 0);
    });

    test('a bm25 that is not a number scores nothing', () {
      expect(keywordRelevance(bm25: double.nan, best: 2, coverage: 1), 0);
      expect(keywordRelevance(bm25: 1, best: double.nan, coverage: 1), 0);
      expect(
        keywordRelevance(bm25: double.infinity, best: 2, coverage: 1),
        0,
      );
    });

    test('doubles a quote inside a term rather than ending the string', () {
      expect(quoteTerm('say"what'), '"say""what"');
    });

    test('a word typed twice is one term', () {
      // Not a wasted slot but a wrong fraction: coverage counts one match per
      // element of [terms], so the duplicate would score a row containing only
      // "lunch" at two of three.
      expect(buildFtsQuery('lunch lunch plans')!.terms, ['lunch', 'plans']);
    });

    test('a query of nothing but apostrophes matches nothing, harmlessly', () {
      // The one input that survives the tokeniser as a non-empty expression
      // and reaches FTS5's parser matching nothing. A lone quote, star or
      // hyphen is caught by the tokeniser and comes back null.
      final query = buildFtsQuery("'''");

      expect(query, isNotNull);
      expect(query!.match, '"\'\'\'"');
    });

    test('caps the terms it sends', () {
      final query = buildFtsQuery(
        'alpha bravo charlie delta echo foxtrot golf hotel india',
      )!;

      expect(query.terms, hasLength(SearchTuning.maxTerms));
      expect(query.terms.last, 'hotel');
    });

    test('a query with no words in it is null, not an empty search', () {
      expect(buildFtsQuery(''), isNull);
      expect(buildFtsQuery('   '), isNull);
      expect(buildFtsQuery('!! -- ??'), isNull);
    });
  });

  group('fuseMessages', () {
    List<String> idsOf(List<SearchHit> hits) =>
        [for (final hit in hits) hit.row.sourceMessageId];

    test('a row both passes found outranks either single-signal row', () {
      final hits = fuseMessages(
        semantic: [
          SemanticHit(row('both'), 0.50),
          SemanticHit(row('meaning'), 0.50),
        ],
        keywords: [
          KeywordHit(row('both'), bm25: 8.0, coverage: 1),
          KeywordHit(row('words'), bm25: 8.0, coverage: 1),
        ],
        limit: 10,
      );

      // Order between the two single-signal rows is whatever their own
      // numbers say; what D19 promises is that neither of them leads.
      expect(idsOf(hits).first, 'both');
      expect(hits.first.score, greaterThan(hits[1].score));
      expect(hits.first.matchedBy, MatchedBy.both);
      expect(
        {for (final hit in hits.skip(1)) hit.matchedBy},
        {MatchedBy.meaning, MatchedBy.words},
      );
    });

    test('a row only the words could reach still shows', () {
      // A gate-dropped message was never embedded, so meaning can never find
      // it. Half a score is the right amount of visible.
      final hits = fuseMessages(
        semantic: const [],
        keywords: [KeywordHit(row('gated'), bm25: 4.0, coverage: 1)],
        limit: 10,
      );

      expect(idsOf(hits), ['gated']);
      expect(hits.single.distance, isNull);
      expect(hits.single.score, closeTo(0.5, 1e-9));
    });

    test('the floor drops what did not earn its place', () {
      final hits = fuseMessages(
        semantic: [
          // 0.5 * (0.80 - 0.63)/0.35 = 0.243 — just under.
          SemanticHit(row('below'), 0.63),
          // 0.5 * (0.80 - 0.625)/0.35 = 0.25 — exactly at it.
          SemanticHit(row('at'), 0.625),
        ],
        keywords: const [],
        limit: 10,
      );

      expect(idsOf(hits), ['at']);
    });

    test('a pass that did not run is not a pass that found nothing', () {
      // Null and empty behave the same here on purpose: the sentence about a
      // half-search belongs on the result, not in the arithmetic.
      final hits = fuseMessages(
        semantic: null,
        keywords: [KeywordHit(row('words'), bm25: 4.0, coverage: 1)],
        limit: 10,
      );

      expect(idsOf(hits), ['words']);
    });

    test('rows the score cannot separate come back newest first', () {
      final hits = fuseMessages(
        semantic: [
          SemanticHit(row('old', receivedAt: '2026-09-01T10:00:00Z'), 0.5),
          SemanticHit(row('new', receivedAt: '2026-09-03T10:00:00Z'), 0.5),
          SemanticHit(row('mid', receivedAt: '2026-09-02T10:00:00Z'), 0.5),
        ],
        keywords: const [],
        limit: 10,
      );

      expect(idsOf(hits), ['new', 'mid', 'old']);
    });

    test('one id in two connectors is two rows', () {
      // Keyed on the feed key rather than the message id: an id is unique only
      // within its connector.
      final hits = fuseMessages(
        semantic: [SemanticHit(row('m1', source: 'email'), 0.5)],
        keywords: [
          KeywordHit(row('m1', source: 'teams'), bm25: 8.0, coverage: 1),
        ],
        limit: 10,
      );

      expect(hits, hasLength(2));
    });

    test('honours the limit', () {
      final hits = fuseMessages(
        semantic: [
          for (var i = 0; i < 10; i++) SemanticHit(row('m$i'), 0.45),
        ],
        keywords: const [],
        limit: 3,
      );

      expect(hits, hasLength(3));
    });
  });

  group('fuseDocuments', () {
    test('one file is one answer, at its best passage', () {
      // The same PDF attached to two messages is two `attachments` rows. A
      // reader who searched for it once wants to see it once.
      final documents = fuseDocuments(
        semantic: [
          chunk(1, name: 'Pub crawl.pdf', sha: 'abc', distance: 0.60),
          chunk(2, name: 'Pub crawl.pdf', sha: 'abc', distance: 0.45),
        ],
        keywords: null,
      );

      expect(documents, hasLength(1));
      expect(documents.single.chunkId, 2);
    });

    test('a file with no bytes yet is identified by name and size', () {
      final documents = fuseDocuments(
        semantic: [
          chunk(1, name: 'Order.pdf', size: 900, distance: 0.50),
          chunk(2, name: 'Order.pdf', size: 900, distance: 0.55),
          chunk(3, name: 'Order.pdf', size: 12, distance: 0.52),
        ],
        keywords: null,
      );

      expect(
        [for (final hit in documents) hit.chunkId],
        [1, 3],
        reason: 'same name, different size, so a different file',
      );
    });

    test('a passage both passes found carries both numbers', () {
      final documents = fuseDocuments(
        semantic: [chunk(1, name: 'Lease.pdf', sha: 'a', distance: 0.60)],
        keywords: [chunk(1, name: 'Lease.pdf', sha: 'a', bm25: 5.0, coverage: 1)],
      );

      expect(documents.single.distance, 0.60);
      expect(documents.single.bm25, 5.0);
    });

    test('a file both halves found in DIFFERENT passages is scored as one', () {
      // The reason the grouping runs before the scoring. Passage 1 is a
      // moderate vector match (0.66 → 0.4) and passage 2 a moderate word match
      // (0.45 of the best, all terms → 0.45). Scored separately they are 0.20
      // and 0.225, both under the floor, and the file disappears; scored as
      // one file it is 0.425 — what a message in the identical position gets.
      final documents = fuseDocuments(
        semantic: [chunk(1, name: 'Lease.pdf', sha: 'a', distance: 0.66)],
        keywords: [
          chunk(2, name: 'Lease.pdf', sha: 'a', bm25: 4.5, coverage: 1),
          chunk(9, name: 'Other.pdf', sha: 'b', bm25: 10.0, coverage: 1),
        ],
      );

      expect(
        [for (final hit in documents) hit.chunkId],
        [9, 2],
        reason: 'the lease is kept, quoted at the passage its stronger half '
            'found',
      );
      expect(documents.last.distance, 0.66);
      expect(documents.last.bm25, 4.5);
    });

    test('the shown passage is the one the stronger half found', () {
      // The vector half wins here, so the vector passage is quoted — and it
      // still carries the word half's numbers, because they are the file's.
      final documents = fuseDocuments(
        semantic: [chunk(1, name: 'Lease.pdf', sha: 'a', distance: 0.45)],
        keywords: [chunk(2, name: 'Lease.pdf', sha: 'a', bm25: 1.0, coverage: 1)],
      );

      expect(documents.single.chunkId, 1);
      expect(documents.single.bm25, 1.0);
    });

    test('the floor applies to documents too', () {
      final documents = fuseDocuments(
        semantic: [chunk(1, name: 'Far.pdf', sha: 'a', distance: 0.79)],
        keywords: null,
      );

      expect(documents, isEmpty);
    });

    test('never more than the cap', () {
      final documents = fuseDocuments(
        semantic: [
          for (var i = 0; i < 12; i++)
            chunk(i, name: 'File $i.pdf', sha: 'sha-$i', distance: 0.45),
        ],
        keywords: null,
      );

      expect(documents, hasLength(SearchTuning.documentLimit));
    });
  });

  group('the live-mailbox ledger', () {
    // The numbers a probe measured against a real mailbox on 2026-09-08,
    // replayed as fixed inputs. Their job is to fail if anyone re-tunes the
    // constants without meaning to: before the floor, every one of these
    // queries returned the whole corpus.

    test('"lunch" keeps three of four', () {
      final hits = fuseMessages(
        semantic: [
          SemanticHit(row('checking-in-a'), 0.576),
          SemanticHit(row('checking-in-b'), 0.707),
          SemanticHit(row('proposal'), 0.770),
          SemanticHit(row('unrelated'), 0.727),
        ],
        keywords: [
          KeywordHit(row('checking-in-a'), bm25: 6.13, coverage: 1),
          KeywordHit(row('checking-in-b'), bm25: 6.32, coverage: 1),
          KeywordHit(row('proposal'), bm25: 3.50, coverage: 1),
        ],
        limit: 50,
      );

      expect(
        [for (final hit in hits) hit.row.sourceMessageId],
        ['checking-in-a', 'checking-in-b', 'proposal'],
      );
      expect(hits.first.score, closeTo(0.805, 0.001));
    });

    test('"invoice" keeps none — the answer is that nothing matches', () {
      // The mailbox contains no invoices. The nearest neighbours are the
      // least bad of a bad list, and a KNN has no way of saying so.
      final hits = fuseMessages(
        semantic: [
          for (final distance in [0.770, 0.781, 0.793, 0.800])
            SemanticHit(row('noise-$distance'), distance),
        ],
        keywords: const [],
        limit: 50,
      );

      expect(hits, isEmpty);
    });
  });
}
