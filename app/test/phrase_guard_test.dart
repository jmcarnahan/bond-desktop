import 'package:bond_inbox/services/calendar/phrase_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// The literal guard both copying readers share (the command bar's
/// `calendar_intent`, the ask's `ask_read`): a phrase is kept only when it
/// is in the text, as whole words, whatever its case or spacing.
void main() {
  test('whole words only: Dan is not in Danielle', () {
    expect(findPhrase('Lunch with Danielle on Friday', 'Dan'), isNull);
    expect(findPhrase('Lunch with Dan on Friday', 'Dan'), (11, 14));
    // A digit is a word character too: "3" is not in "13".
    expect(findPhrase('the 13th', '3'), isNull);
  });

  test('case does not matter, and the span is the text\'s own', () {
    const text = 'Could we do FRIDAY afternoon?';
    final (start, end) = findPhrase(text, 'friday afternoon')!;
    expect(text.substring(start, end), 'FRIDAY afternoon');
  });

  test('runs of whitespace collapse, in the phrase and in the text', () {
    const text = 'how about next\n  Tuesday at 3';
    final (start, end) = findPhrase(text, 'next   Tuesday')!;
    expect(text.substring(start, end), 'next\n  Tuesday');
    expect(findPhrase('next Tuesday', '  next Tuesday  '), (0, 12));
  });

  test('regex metacharacters in a phrase are taken literally', () {
    expect(findPhrase('Friday at 3pm? or later', '3pm?'), isNotNull);
    expect(findPhrase('Friday at 3pm or later', '3pm?'), isNull);
    expect(findPhrase('a call (30 min) next week', '(30 min)'), isNotNull);
    expect(findPhrase('a call 30 min next week', '(30 min)'), isNull);
    expect(findPhrase('cost 1+1', '1+1'), isNotNull);
    expect(findPhrase('cost 11', '1+1'), isNull);
  });

  test('a blank phrase is never in the text', () {
    expect(findPhrase('Friday', ''), isNull);
    expect(findPhrase('Friday', '   '), isNull);
    expect(findPhrase('', 'Friday'), isNull);
  });

  test('letters outside ASCII are word characters too', () {
    expect(findPhrase('Café mañana con José', 'mañana'), isNotNull);
    // "José" is not in "Joséphine", nor "Zoë" in "Zoëlle".
    expect(findPhrase('Lunch with Joséphine', 'José'), isNull);
    expect(findPhrase('Zoëlle can do Friday', 'Zoë'), isNull);
    expect(findPhrase('ZOË can do Friday', 'zoë'), isNotNull);
  });
}
