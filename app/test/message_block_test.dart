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

      // The header's own count is rewritten to what survived: it said the
      // packer quoted 12, and a reader here gets 2.
      const requoted = '(thread has 40 earlier messages; 2 quoted below)';
      expect(fitted, '$requoted\n${'b' * 50}\n${'c' * 50}');
      expect(fitted.length, lessThanOrEqualTo(header.length + 2 * 51));
    });

    test('a header whose lines all survive keeps its count', () {
      // Exactly at the cap is the identity, header and all. Above the cap
      // with a header, every line surviving is unreachable by construction:
      // the fit's total is the digest's own length, so something always goes.
      final digest = '$header\n${'a' * 30}\n${'b' * 30}';
      expect(fitThreadDigest(digest, digest.length), same(digest));
    });

    test('a header that does not match its own lines is not made longer', () {
      // The packer writes one line per quoted message, so M never has fewer
      // digits than the survivor count. A header that lies about that would
      // get a LONGER rewrite, and a longer header could push the join past
      // the cap the lines were fitted under — so it is left as it came.
      const liar = '(thread has 40 earlier messages; 5 quoted below)';
      final digest = [
        liar,
        // Fixed-width labels, so every line is 22 characters.
        for (var i = 0; i < 12; i++) 'w${i.toString().padLeft(2, '0')}${'.' * 19}',
      ].join('\n');
      final cap = liar.length + 10 * 23; // room for ten of the twelve lines
      final fitted = fitThreadDigest(digest, cap);

      expect(fitted.split('\n').first, liar);
      expect(fitted.split('\n').length, 11);
      expect(fitted.length, lessThanOrEqualTo(cap));
    });

    test('the synthesized count survives crossing a digit boundary', () {
      // Twenty lines of sixty. Silently, eleven fit (nine dropped); under the
      // one-digit header only ten do, which makes it ten dropped and a
      // two-digit header — the re-fit has to settle on a header that names
      // the lines actually missing.
      final digest = [for (var i = 0; i < 20; i++) 'k$i${'.' * 57}'].join('\n');
      final fitted = fitThreadDigest(digest, 700);
      final lines = fitted.split('\n');

      expect(lines.first,
          '(thread digest trimmed to fit; 10 older lines omitted)');
      expect(lines.length, 11);
      expect(lines[1], startsWith('k10'));
      expect(fitted.length, lessThanOrEqualTo(700));
    });

    test('one omitted line is announced in the singular', () {
      // Two long lines and a short one: the oldest long line goes, the
      // announcement fits, and it says "line", not "lines".
      final digest = ['o${'.' * 119}', 'p${'.' * 119}', 'q${'.' * 59}'].join('\n');
      final fitted = fitThreadDigest(digest, 250);

      expect(fitted.split('\n').first,
          '(thread digest trimmed to fit; 1 older line omitted)');
    });

    test('without a header the newest lines are still what is kept', () {
      // Too tight to announce the trim as well: the two newest whole lines
      // beat a header over a stub of one.
      final digest = ['x' * 40, 'y' * 40, 'z' * 40].join('\n');
      final fitted = fitThreadDigest(digest, 81);

      expect(fitted, '${'y' * 40}\n${'z' * 40}');
    });

    test('a trimmed digest with no header of its own gets one that counts',
        () {
      // Ten lines of a hundred, a budget of six hundred: five fit on their
      // own, and still fit under the line that says five went — so the
      // reader is told, the way the packer's own header tells them.
      final digest = [for (var i = 0; i < 10; i++) 'l$i${'.' * 97}'].join('\n');
      final fitted = fitThreadDigest(digest, 600);
      final lines = fitted.split('\n');

      expect(lines.first,
          '(thread digest trimmed to fit; 5 older lines omitted)');
      expect(lines.skip(1).map((l) => l.substring(0, 2)),
          ['l5', 'l6', 'l7', 'l8', 'l9']);
      expect(fitted.length, lessThanOrEqualTo(600));
    });

    test('the synthesized header gives way when it would cost the last whole line',
        () {
      // One line fits, but not one line plus the announcement — the
      // announcement is dropped rather than the line, and the count it would
      // have carried is never wrong because it is never shown.
      final digest = [for (var i = 0; i < 4; i++) 'r$i${'-' * 58}'].join('\n');
      final fitted = fitThreadDigest(digest, 100);

      expect(fitted, 'r3${'-' * 58}');
    });

    test('the announcement outranks a second whole line when one still fits',
        () {
      // Two lines would fit in silence; the header plus the newest line fits
      // too, and that is what the reader gets — being told that history is
      // missing is worth one older line at any budget that can afford it.
      final digest = [for (var i = 0; i < 4; i++) 'r$i${'-' * 58}'].join('\n');
      final fitted = fitThreadDigest(digest, 121);

      expect(fitted,
          '(thread digest trimmed to fit; 3 older lines omitted)\nr3${'-' * 58}');
    });

    test('a single over-long line is clipped from its END, under the header',
        () {
      // Nothing but the header fits, so the newest line fills what is left —
      // half of the latest turn beats none of it.
      final digest = '$header\n${'q' * 500}';
      final fitted = fitThreadDigest(digest, header.length + 20);

      // The count is rewritten to the one (clipped) line the reader gets,
      // which is a character shorter than "12" — so one more character of
      // the line fits and the result still lands exactly on the cap.
      const requoted = '(thread has 40 earlier messages; 1 quoted below)';
      expect(fitted, '$requoted\n${'q' * 20}');
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
