import 'package:bond_inbox/services/calendar/ask_words.dart';
import 'package:flutter_test/flutter_test.dart';

/// `capAtWord`: back to a word when one ends near the cap, hard at the cap
/// when none does, never through a surrogate pair.
void main() {
  test('a cut goes back to the last word near the cap', () {
    expect(capAtWord('meet at 11pm tonight', 14), 'meet at 11pm');
  });

  test('a short string is returned whole', () {
    expect(capAtWord('at 11pm', 20), 'at 11pm');
  });

  test('a long run with its only space near the start is cut hard', () {
    final sheet = 'Q3 ${'1234;' * 1200}';
    expect(sheet.length, greaterThan(6000));
    final cut = capAtWord(sheet, 6000);
    expect(cut.length, 6000);
    expect(cut, sheet.substring(0, 6000));
  });

  test('a hard cut never ends on half a surrogate pair', () {
    final s = '${'x' * 9}\u{1F600}yz';
    expect(capAtWord(s, 10), 'x' * 9);
  });
}
