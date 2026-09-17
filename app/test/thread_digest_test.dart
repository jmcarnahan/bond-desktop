import 'package:bond_inbox/models/message_models.dart';
import 'fixtures/thread_digest.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart port of the golden packer's `compress_thread`, held to the Python
/// byte for byte.
///
/// **Every expected string below was GENERATED from
/// `golden/tools/pack_items.py`'s `compress_thread`**, run on the fictional
/// rows this file builds — not written by hand and not read off a real thread.
/// That is the whole point of the test: the golden set's digests were produced
/// by that Python, so a port that renders one character differently would be
/// measuring a prompt the set never priced.
///
/// To regenerate after a deliberate change to either side, run the script in
/// this session's scratchpad (`gen_digest.py`), which does
/// `sys.path.insert(0, '<repo>/golden/tools')`, imports `compress_thread`, and
/// prints each digest as JSON. Never run `pack_items.py` itself — its `main()`
/// opens the private message database.
///
/// The rows are fictional people and invented subjects, like every fixture in
/// this public repo.

/// One earlier message, in the shape `loadThread` hands over. The day doubles
/// as the id so a failure names the turn it is about.
Message row(
  int day, {
  String? name = 'Priya Anand',
  String text = '',
  bool outbound = false,
  String? preview,
}) =>
    Message(
      id: 'm$day',
      source: 'email',
      outbound: outbound,
      fromName: name,
      bodyText: text,
      bodyPreview: preview,
      receivedAt: '2026-08-${day.toString().padLeft(2, '0')}T09:00:00Z',
    );

/// The body every over-budget row carries, long enough that the 2,000-character
/// total cap bites after the recent six.
const String longBody = 'The loading dock survey needs a second visit because '
    'the measurements taken on the first pass disagree with the plans filed '
    'with the borough office and nobody can tell which of the two is right '
    'without standing there again. ';

void main() {
  test('a short thread is quoted whole, with no header line', () {
    final digest = buildThreadDigest([
      row(1, name: 'Priya Anand', text: 'Can we move the walkthrough to Tuesday?'),
      row(2, name: 'Jordan Feld', text: 'Tuesday works for me.'),
      row(3, name: 'Priya Anand', text: 'Booked it for ten.'),
    ]);

    expect(digest, '2026-08-01 · Priya Anand: Can we move the walkthrough to Tuesday?\n2026-08-02 · Jordan Feld: Tuesday works for me.\n2026-08-03 · Priya Anand: Booked it for ten.');
    // Nothing was left out, so nothing claims anything was.
    expect(digest, isNot(contains('thread has')));
  });

  test('a thirty-message thread is sampled: the head, a spread, the newest six',
      () {
    final digest = buildThreadDigest([
      for (var i = 0; i < 30; i++)
        row(
          1 + i,
          name: i.isOdd ? 'Priya Anand' : 'Jordan Feld',
          text: 'Turn number $i about the loading dock survey.',
        ),
    ]);

    expect(digest, '(thread has 30 earlier messages; 14 quoted below)\n2026-08-01 · Jordan Feld: Turn number 0 about the loading dock survey.\n2026-08-02 · Priya Anand: Turn number 1 about the loading dock survey.\n2026-08-03 · Jordan Feld: Turn number 2 about the loading dock survey.\n2026-08-06 · [+2 omitted] Priya Anand: Turn number 5 about the loading dock survey.\n2026-08-09 · [+2 omitted] Jordan Feld: Turn number 8 about the loading dock survey.\n2026-08-12 · [+2 omitted] Priya Anand: Turn number 11 about the loading dock survey.\n2026-08-15 · [+2 omitted] Jordan Feld: Turn number 14 about the loading dock survey.\n2026-08-18 · [+2 omitted] Priya Anand: Turn number 17 about the loading dock survey.\n2026-08-25 · [+6 omitted] Jordan Feld: Turn number 24 about the loading dock survey.\n2026-08-26 · Priya Anand: Turn number 25 about the loading dock survey.\n2026-08-27 · Jordan Feld: Turn number 26 about the loading dock survey.\n2026-08-28 · Priya Anand: Turn number 27 about the loading dock survey.\n2026-08-29 · Jordan Feld: Turn number 28 about the loading dock survey.\n2026-08-30 · Priya Anand: Turn number 29 about the loading dock survey.');
    // The header states what was never quoted, and the prefixes say where the
    // gaps fell.
    expect(digest, startsWith('(thread has 30 earlier messages; 14 quoted below)\n'));
    expect(digest, contains('[+6 omitted] Jordan Feld: Turn number 24'));
    expect(digest, isNot(contains('Turn number 3 ')));
  });

  test('the reader\'s own turn is named "You", never attributed to a sender',
      () {
    final digest = buildThreadDigest([
      row(4, name: 'Priya Anand', text: 'Did the survey come back?'),
      row(5, name: 'Jordan Feld', text: 'Sending it over now.', outbound: true),
    ]);

    expect(digest, '2026-08-04 · Priya Anand: Did the survey come back?\n2026-08-05 · You: Sending it over now.');
    expect(digest, contains('You: Sending it over now.'));
  });

  test('a message with no words says so rather than rendering blank', () {
    final digest = buildThreadDigest([
      row(6, name: 'Priya Anand'),
      row(7, name: 'Jordan Feld', text: 'Thanks for the file.'),
    ]);

    // Two ASCII hyphens, as the Python writes it: the set's digests carry that
    // exact sentence and the port must not tidy it into an em dash.
    expect(digest, '2026-08-06 · Priya Anand: (no text -- attachment or system notice)\n2026-08-07 · Jordan Feld: Thanks for the file.');
    expect(digest, contains('(no text -- attachment or system notice)'));
  });

  test('an attachment marker is taken out before the line is rendered', () {
    final digest = buildThreadDigest([
      row(8, name: 'Priya Anand', text: 'See [[att:abc]] for the numbers.'),
    ]);

    expect(digest, '2026-08-08 · Priya Anand: See for the numbers.');
    expect(digest, isNot(contains('att:')));
  });

  test('over the 2,000-character budget the OLDEST kept line goes first', () {
    final digest = buildThreadDigest([
      for (var i = 0; i < 14; i++)
        row(
          1 + i,
          name: i.isOdd ? 'Priya Anand' : 'Jordan Feld',
          text: 'Message $i. $longBody',
        ),
    ]);

    expect(digest, '(thread has 14 earlier messages; 9 quoted below)\n2026-08-06 · Priya Anand: Message 5. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with \n2026-08-07 · Jordan Feld: Message 6. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with \n2026-08-08 · Priya Anand: Message 7. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with \n2026-08-09 · Jordan Feld: Message 8. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with the borough office and nobody can tell which of the two is r\n2026-08-10 · Priya Anand: Message 9. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with the borough office and nobody can tell which of the two is r\n2026-08-11 · Jordan Feld: Message 10. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with the borough office and nobody can tell which of the two is \n2026-08-12 · Priya Anand: Message 11. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with the borough office and nobody can tell which of the two is \n2026-08-13 · Jordan Feld: Message 12. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with the borough office and nobody can tell which of the two is \n2026-08-14 · Priya Anand: Message 13. The loading dock survey needs a second visit because the measurements taken on the first pass disagree with the plans filed with the borough office and nobody can tell which of the two is ');
    // Nine of fourteen survived: the newest six, which are never sacrificed,
    // plus the three older lines the budget still had room for.
    expect(digest, startsWith('(thread has 14 earlier messages; 9 quoted below)\n'));
    expect(digest, contains('Message 13.'));
    expect(digest, isNot(contains('Message 0.')));
    expect(digest!.length, lessThanOrEqualTo(2000));
  });

  test('a sender nobody named reads as (unknown)', () {
    final digest = buildThreadDigest([
      row(9, name: null, text: 'No name on this one.'),
      row(10, name: 'Jordan Feld', text: 'Who was that?'),
    ]);

    expect(digest, '2026-08-09 · (unknown): No name on this one.\n2026-08-10 · Jordan Feld: Who was that?');
  });

  test('nothing earlier is null, not an empty digest', () {
    // Null and not '': the callers write a fence only for a digest that exists,
    // and an empty string would be an empty fence claiming there was history.
    expect(buildThreadDigest(const []), isNull);
  });
}
