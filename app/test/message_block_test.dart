import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/message_block.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two budget-and-render helpers every prompt builder shares.
///
/// `buildMessageBlock` itself is pinned through the tasks that render it
/// (`triage_task_test.dart`, `extract_task_test.dart`); what is here is the
/// pair that arrived with the thread digest — the fitter that decides which
/// LINES of a digest a prompt reads, and the tail renderer three tasks now
/// share.
Message row({
  String id = 'm1',
  String? fromName = 'Priya Anand',
  String? bodyText,
  String? bodyPreview,
  bool outbound = false,
}) =>
    Message(
      id: id,
      source: 'email',
      outbound: outbound,
      fromName: fromName,
      bodyText: bodyText,
      bodyPreview: bodyPreview,
      receivedAt: '2026-08-29T16:05:00Z',
    );

void main() {
  group('fitThreadDigest', () {
    const header = '(thread has 40 earlier messages; 12 quoted below)';

    test('a digest under the cap comes back byte for byte', () {
      const digest = 'one\ntwo\nthree';
      expect(fitThreadDigest(digest, 900), same(digest));
      // The boundary is inclusive: exactly the cap is under it.
      expect(fitThreadDigest(digest, digest.length), same(digest));
    });

    test('the header survives and the OLDEST lines are the ones dropped', () {
      final digest = [
        header,
        'a' * 50,
        'b' * 50,
        'c' * 50,
      ].join('\n');
      // Room for the header and two of the three lines.
      final fitted = fitThreadDigest(digest, header.length + 2 * 51);

      expect(fitted, '$header\n${'b' * 50}\n${'c' * 50}');
      expect(fitted.length, lessThanOrEqualTo(header.length + 2 * 51));
    });

    test('without a header the newest lines are still what is kept', () {
      final digest = ['x' * 40, 'y' * 40, 'z' * 40].join('\n');
      final fitted = fitThreadDigest(digest, 81);

      expect(fitted, '${'y' * 40}\n${'z' * 40}');
    });

    test('a single over-long line is clipped from its END, under the header',
        () {
      // Nothing but the header fits, so the newest line fills what is left —
      // half of the latest turn beats none of it.
      final digest = '$header\n${'q' * 500}';
      final fitted = fitThreadDigest(digest, header.length + 20);

      expect(fitted, '$header\n${'q' * 19}');
      expect(fitted.length, header.length + 20);
    });

    test('a header longer than the whole budget is clipped to it', () {
      final fitted = fitThreadDigest('$header\nsomething', 20);

      expect(fitted, header.substring(0, 20));
    });

    test('with no header at all an over-long line is clipped to the cap', () {
      expect(fitThreadDigest('w' * 500, 30), 'w' * 30);
    });

    test('the result never exceeds the cap, whatever the shape', () {
      final shapes = <String>[
        'short',
        '$header\n${'a' * 2000}',
        ['m' * 300, 'n' * 300, 'o' * 300, 'p' * 300].join('\n'),
        [header, for (var i = 0; i < 40; i++) 'line $i ${'z' * i}'].join('\n'),
      ];
      // The header's own length and its neighbours are the boundary that
      // bit once: a header one character short of the cap has no room for a
      // newline, and clipping it to the cap would read past its end.
      final caps = [
        1,
        10,
        60,
        120,
        900,
        for (var d = -2; d <= 2; d++) header.length + d,
      ];
      for (final shape in shapes) {
        for (final cap in caps) {
          expect(
            fitThreadDigest(shape, cap).length,
            lessThanOrEqualTo(cap),
            reason: 'cap $cap',
          );
        }
      }
    });

    test('the app-wide budget is 900 characters', () {
      expect(threadDigestCap, 900);
    });
  });

  group('buildThreadTailText', () {
    test('the last three, oldest first, separated by a rule', () {
      final text = buildThreadTailText([
        row(id: 't1', bodyText: 'The oldest question.'),
        row(id: 't2', fromName: 'Jordan Feld', bodyText: 'A follow up.'),
        row(id: 't3', bodyText: 'Sure, on it.', outbound: true),
        row(id: 't4', fromName: 'Jordan Feld', bodyText: 'Any word yet?'),
      ]);

      expect(
        text,
        'Jordan Feld: A follow up.\n---\n'
        'You: Sure, on it.\n---\n'
        'Jordan Feld: Any word yet?',
      );
    });

    test('the reader is "You" and a nameless sender renders as nothing', () {
      expect(
        buildThreadTailText([row(fromName: null, bodyText: 'Who sent this?')]),
        ': Who sent this?',
      );
      expect(
        buildThreadTailText([row(bodyText: 'Mine.', outbound: true)]),
        'You: Mine.',
      );
    });

    test('a quoted message is clipped at 300 characters', () {
      final text = buildThreadTailText([row(bodyText: 'z' * 900)]);

      expect('z'.allMatches(text).length, 300);
    });

    test('both windows are overridable, for a caller with other numbers', () {
      final text = buildThreadTailText(
        [
          row(id: 't1', bodyText: 'one'),
          row(id: 't2', bodyText: 'two'),
          row(id: 't3', bodyText: 'three'),
        ],
        max: 2,
        cap: 2,
      );

      expect(text, 'Priya Anand: tw\n---\nPriya Anand: th');
    });

    test('no thread is an empty string, not a stray separator', () {
      expect(buildThreadTailText(const []), '');
    });

    test('the preview stands in when no body has been fetched', () {
      expect(
        buildThreadTailText([row(bodyText: null, bodyPreview: 'A snippet.')]),
        'Priya Anand: A snippet.',
      );
    });

    test('an attachment marker is taken out — nobody typed that token', () {
      expect(
        buildThreadTailText([row(bodyText: 'See [[att:abc]] for the numbers.')]),
        'Priya Anand: See for the numbers.',
      );
    });
  });
}
