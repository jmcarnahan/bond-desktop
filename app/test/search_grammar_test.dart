import 'package:bond_inbox/models/home_models.dart';
import 'package:bond_inbox/services/search_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

/// The search box's facets: what comes out of a typed line, and which hits
/// survive it.
///
/// The through-line of the whole file is that an unrecognised facet STAYS
/// TEXT. There is no error channel between the box and the reader, so the only
/// honest thing a parser can do with `re:` or `in:junk` is search for it.

HomeFeedRow _row({
  String id = 'm1',
  String receivedAt = '2026-09-03T09:00:00Z',
  String? fromName = 'Dana Whitfield',
  String? fromAddress = 'dana@example.com',
  bool hasAttachments = false,
}) =>
    HomeFeedRow(
      source: 'email',
      sourceMessageId: id,
      conversationKey: 'c-$id',
      receivedAt: receivedAt,
      triageState: 'done',
      extractState: 'done',
      storylineState: 'done',
      draftState: 'done',
      settleState: 'done',
      outcome: 'done',
      dropped: false,
      subject: 'Launch date',
      fromName: fromName,
      fromAddress: fromAddress,
      hasAttachments: hasAttachments,
    );

List<SearchHit> _hits(List<HomeFeedRow> rows) => [
      for (final row in rows)
        SearchHit(row: row, score: 0.5, matchedBy: MatchedBy.meaning),
    ];

List<String> _idsOf(List<SearchHit> hits) =>
    [for (final hit in hits) hit.row.sourceMessageId];

void main() {
  group('parsing', () {
    test('a plain sentence is all text and no facets', () {
      final query = parseSearchQuery('  where is the launch date  ');

      expect(query.text, 'where is the launch date');
      expect(query.hasFacets, isFalse);
      expect(query.sources, ['email', 'teams']);
    });

    test('from: lifts a sender out, lowercased', () {
      final query = parseSearchQuery('launch from:Dana');

      expect(query.text, 'launch');
      expect(query.from, 'dana');
      expect(query.hasFacets, isTrue);
    });

    test('quotes group a from: value into one token', () {
      final query = parseSearchQuery('from:"Dana Whitfield" launch');

      expect(query.from, 'dana whitfield');
      expect(query.text, 'launch');
    });

    test('a bare quoted phrase stays text, without its quotes', () {
      final query = parseSearchQuery('"launch date"');

      expect(query.text, 'launch date');
      expect(query.hasFacets, isFalse);
    });

    test('in: names one connector, however it is spelled', () {
      for (final spelling in const ['mail', 'email', 'outlook', 'MAIL']) {
        expect(parseSearchQuery('x in:$spelling').source, 'email',
            reason: spelling);
      }
      for (final spelling in const ['teams', 'chat', 'Teams']) {
        expect(parseSearchQuery('x in:$spelling').source, 'teams',
            reason: spelling);
      }
    });

    test('in: is what narrows the store, and both connectors is the default',
        () {
      expect(parseSearchQuery('x in:teams').sources, ['teams']);
      expect(parseSearchQuery('x').sources, ['email', 'teams']);
    });

    test('a connector nobody has stays text', () {
      final query = parseSearchQuery('in:junk launch');

      expect(query.source, isNull);
      expect(query.text, 'in:junk launch');
      expect(query.hasFacets, isFalse);
    });

    test('has: takes the four spellings of a file', () {
      for (final spelling in const [
        'file',
        'files',
        'attachment',
        'attachments',
      ]) {
        final query = parseSearchQuery('x has:$spelling');
        expect(query.hasFile, isTrue, reason: spelling);
        expect(query.text, 'x', reason: spelling);
      }
    });

    test('any other has: stays text', () {
      final query = parseSearchQuery('has:pictures launch');

      expect(query.hasFile, isFalse);
      expect(query.text, 'has:pictures launch');
    });

    test('the date facets are UTC midnight of the day named', () {
      final query = parseSearchQuery('x before:2026-09-07 after:2026-09-01');

      expect(query.before, DateTime.utc(2026, 9, 7));
      expect(query.after, DateTime.utc(2026, 9, 1));
      expect(query.text, 'x');
    });

    test('a date the reader spelled another way stays text', () {
      // A bare year would otherwise parse as the first of January, which is a
      // filter the reader never asked for.
      for (final bad in const ['2026', '7 Sept', '2026-09-07T10:00:00Z']) {
        final query = parseSearchQuery('x before:$bad');
        expect(query.before, isNull, reason: bad);
        expect(query.text, 'x before:$bad', reason: bad);
      }
    });

    test('an unknown facet stays text', () {
      final query = parseSearchQuery('re: the launch subject:x');

      expect(query.hasFacets, isFalse);
      expect(query.text, 're: the launch subject:x');
    });

    test('an empty facet value stays text', () {
      final query = parseSearchQuery('from: launch');

      expect(query.from, isNull);
      expect(query.text, 'from: launch');
    });

    test('every facet at once, and the sentence underneath them', () {
      final query = parseSearchQuery(
        'hero copy from:"Dana Whitfield" in:teams has:file '
        'before:2026-09-07 after:2026-09-01',
      );

      expect(query.text, 'hero copy');
      expect(query.from, 'dana whitfield');
      expect(query.source, 'teams');
      expect(query.hasFile, isTrue);
      expect(query.before, DateTime.utc(2026, 9, 7));
      expect(query.after, DateTime.utc(2026, 9, 1));
    });

    test('facets alone leave nothing to ask, and say so', () {
      final query = parseSearchQuery('from:dana has:file');

      // The caller's cue to refuse the search rather than embed the empty
      // string, which would rank the whole mailbox by its distance from
      // nothing.
      expect(query.text, isEmpty);
      expect(query.hasFacets, isTrue);
    });
  });

  group('filtering hits', () {
    test('no facets is the list untouched, identically', () {
      final hits = _hits([_row(id: 'a'), _row(id: 'b')]);

      expect(filterHits(parseSearchQuery('launch'), hits), same(hits));
    });

    test('from: matches the name or the address', () {
      final hits = _hits([
        _row(id: 'dana'),
        _row(id: 'eric', fromName: 'Eric Vance', fromAddress: 'eric@example.com'),
      ]);

      expect(_idsOf(filterHits(parseSearchQuery('x from:dana'), hits)), ['dana']);
      expect(
        _idsOf(filterHits(parseSearchQuery('x from:eric@example'), hits)),
        ['eric'],
      );
    });

    test('a row with no sender at all fails a from:', () {
      final hits = _hits([_row(id: 'a', fromName: null, fromAddress: null)]);

      expect(filterHits(parseSearchQuery('x from:dana'), hits), isEmpty);
    });

    test('has:file keeps only the rows carrying something', () {
      final hits = _hits([
        _row(id: 'plain'),
        _row(id: 'attached', hasAttachments: true),
      ]);

      expect(
        _idsOf(filterHits(parseSearchQuery('x has:file'), hits)),
        ['attached'],
      );
    });

    test('before: is strictly earlier, after: includes the day itself', () {
      final hits = _hits([
        _row(id: 'sixth', receivedAt: '2026-09-06T23:00:00Z'),
        _row(id: 'midnight', receivedAt: '2026-09-07T00:00:00Z'),
        _row(id: 'seventh', receivedAt: '2026-09-07T09:00:00Z'),
      ]);

      expect(
        _idsOf(filterHits(parseSearchQuery('x before:2026-09-07'), hits)),
        ['sixth'],
      );
      expect(
        _idsOf(filterHits(parseSearchQuery('x after:2026-09-07'), hits)),
        ['midnight', 'seventh'],
      );
    });

    test('a row with no stamp fails any date facet', () {
      final hits = _hits([_row(id: 'undated', receivedAt: '')]);

      expect(filterHits(parseSearchQuery('x before:2026-09-07'), hits), isEmpty);
      expect(filterHits(parseSearchQuery('x after:2026-09-01'), hits), isEmpty);
    });

    test('the surviving hits keep the index order they arrived in', () {
      final hits = _hits([
        _row(id: 'a', hasAttachments: true),
        _row(id: 'b'),
        _row(id: 'c', hasAttachments: true),
      ]);

      expect(
        _idsOf(filterHits(parseSearchQuery('x has:file'), hits)),
        ['a', 'c'],
      );
    });
  });
}
