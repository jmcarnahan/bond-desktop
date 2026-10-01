/// The texts the decision model reads for the three storyline questions —
/// `bond-state/2`'s thread, pair, membership and charter renderers.
///
/// A byte-for-byte port of jev-prototype's
/// `distill/eval_questions/renderers.py`, which rendered the training data of
/// the storyline heads. As with the message state (`decision_state.dart`), a
/// harmless-looking tidy-up here is a silent accuracy loss: the model learned
/// THESE bytes. `test/storyline_state_test.dart` checks every case of
/// `render_cases_v2.json`, which the Python wrote.
///
/// Three Python semantics the port keeps, each a trap for idiomatic Dart:
///
/// - caps count Unicode CODE POINTS (a Python slice), never UTF-16 units, so
///   an emoji counts once and a cut may still split a grapheme on purpose;
/// - whitespace is Python's `str.isspace()` set ([storylineWhitespace]), not
///   Dart's `trim()` or `\s`: U+001C–U+001F are whitespace, U+FEFF, U+180E
///   and U+200B are not;
/// - the people de-dup compares Python's `str.lower()` ([pyLower]), which is
///   not Dart's `toLowerCase` for `İ` or a final sigma.
library;

import 'package:flutter/foundation.dart' show immutable;

/// How many of a thread's messages the thread text keeps, newest last.
const int storylineThreadMessages = 3;

/// Code points kept of each message's text, of its `who`, of the subject, of
/// each participant name, of a storyline title and of its charter.
const int storylineMessageCap = 300;
const int storylineWhoCap = 60;
const int storylineSubjectCap = 150;
const int storylinePeopleNameCap = 40;
const int storylineTitleCap = 150;
const int storylineCharterCap = 1000;

/// At most this many names on the People line.
const int storylinePeopleMax = 6;

/// Between two messages of a thread: `state.TAIL_SEP`, the message state's.
const String storylineMessageSep = '\n---\n';

/// Python's `str.isspace()` code points, copied from the fixture's
/// `whitespace_code_points` (Python 3.12, Unicode 15.0). Every one is in the
/// Basic Multilingual Plane.
const Set<int> storylineWhitespace = {
  0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0,
  0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
  0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
};

/// One message of a thread as the thread text shows it.
@immutable
class StorylineMessage {
  /// `You` for the owner's own message, else the sender's name or address.
  final String? who;
  final String? text;

  const StorylineMessage({this.who, this.text});
}

/// `renderers.collapse`: every whitespace run to one space, the ends trimmed,
/// then cut to [cap] code points and the end trimmed again. A cut never adds
/// an ellipsis.
String storylineCollapse(String? text, int cap) {
  final out = _joinWords(text);
  final runes = out.runes;
  if (runes.length <= cap) return out;
  final cut = String.fromCharCodes(runes.take(cap));
  // After the collapse the only whitespace left is U+0020, so this is the
  // `rstrip()` Python runs.
  var end = cut.length;
  while (end > 0 && storylineWhitespace.contains(cut.codeUnitAt(end - 1))) {
    end--;
  }
  return cut.substring(0, end);
}

/// `" ".join(text.split())`: split on runs of [storylineWhitespace], drop the
/// empty pieces, join with one space.
String _joinWords(String? text) {
  if (text == null || text.isEmpty) return '';
  final words = <String>[];
  final word = StringBuffer();
  for (final rune in text.runes) {
    if (storylineWhitespace.contains(rune)) {
      if (word.isNotEmpty) {
        words.add(word.toString());
        word.clear();
      }
    } else {
      word.writeCharCode(rune);
    }
  }
  if (word.isNotEmpty) words.add(word.toString());
  return words.join(' ');
}

/// `renderers._REFW` over a COLLAPSED subject, where the only whitespace left
/// is U+0020, so Python's `\s` is a literal space here. Case-insensitive on
/// ASCII letters only, which is all the pattern names.
final RegExp _reFw = RegExp(r'^(?:(?:re|fw|fwd) *: *)+', caseSensitive: false);

/// `renderers.clean_subject`: collapsed FIRST, then every leading
/// `Re:`/`Fw:`/`Fwd:` removed, then collapsed and capped; empty reads
/// `(no subject)`. Collapsing first is what lets a marker hidden behind a
/// newline or U+0085 be seen.
String storylineCleanSubject(String? subject) {
  final s = storylineCollapse(
    _joinWords(subject).replaceFirst(_reFw, ''),
    storylineSubjectCap,
  );
  return s.isEmpty ? '(no subject)' : s;
}

/// `renderers.people_line`: first-seen, case-insensitively de-duplicated
/// names, each collapsed and capped before it is compared, empties dropped,
/// at most [storylinePeopleMax]; none reads `(none)`.
String storylinePeopleLine(List<String?>? participants) {
  final seen = <String>{};
  final names = <String>[];
  for (final p in participants ?? const <String?>[]) {
    final name = storylineCollapse(p, storylinePeopleNameCap);
    if (name.isEmpty || !seen.add(pyLower(name))) continue;
    names.add(name);
    if (names.length == storylinePeopleMax) break;
  }
  return names.isEmpty ? '(none)' : names.join(', ');
}

/// `renderers.render_thread`: one thread, [messages] OLDEST first, of which
/// the newest [storylineThreadMessages] are kept.
String renderStorylineThread({
  String? subject,
  List<String?>? participants,
  List<StorylineMessage>? messages,
}) {
  final all = messages ?? const <StorylineMessage>[];
  final kept = all.length > storylineThreadMessages
      ? all.sublist(all.length - storylineThreadMessages)
      : all;
  final lines = [
    for (final m in kept)
      '${_orElse(storylineCollapse(m.who, storylineWhoCap), '(unknown)')}: '
          '${storylineCollapse(m.text, storylineMessageCap)}',
  ];
  final body = lines.isEmpty ? '(none)' : lines.join(storylineMessageSep);
  return 'Subject: ${storylineCleanSubject(subject)}\n'
      'People: ${storylinePeopleLine(participants)}\n'
      'Newest messages, oldest first:\n$body';
}

/// `renderers.render_pair`. The same pair is asked in both orders and the two
/// answers averaged (`DecisionClient.askPairs`).
String renderStorylinePair(String a, String b) =>
    'Thread A:\n$a\n\nThread B:\n$b';

/// `renderers.render_charter`.
String renderStorylineCharter({String? title, String? charter}) =>
    'Storyline title: '
    '${_orElse(storylineCollapse(title, storylineTitleCap), '(untitled)')}\n'
    'Charter: '
    '${_orElse(storylineCollapse(charter, storylineCharterCap), '(none)')}';

/// `renderers.render_membership`: the charter, then [threadText] as
/// [renderStorylineThread] rendered it.
String renderStorylineMembership({
  String? title,
  String? charter,
  required String threadText,
}) =>
    '${renderStorylineCharter(title: title, charter: charter)}\n\n'
    'The thread:\n$threadText';

String _orElse(String value, String fallback) =>
    value.isEmpty ? fallback : value;

/// Python's `str.lower()`, as far as the people de-dup needs it.
///
/// Dart's `toLowerCase` is the simple per-character mapping, which Python's
/// is too except in two places, both handled here:
///
/// - `İ` (U+0130) lowers to `i` + U+0307 COMBINING DOT ABOVE (SpecialCasing),
///   where Dart gives a bare `i`. So `İpek` and `i̇pek` merge and `IPEK` does
///   not.
/// - `Σ` (U+03A3) lowers to final `ς` (U+03C2) when it ends a word, which
///   Python decides by its Final_Sigma rule: a cased letter before it and no
///   cased letter after it, skipping case-ignorable characters both ways.
///   Dart always gives medial `σ`.
///
/// Every other rune is lowered by Dart one at a time. The Final_Sigma context
/// uses approximations of two Unicode properties ([_isCased],
/// [_isCaseIgnorable]) that are exact for letters with a case mapping,
/// combining marks, the common apostrophes and dots, and format characters;
/// a rare cased letter with no mapping of its own (`ª`, a modifier letter)
/// beside a `Σ` is the one place they could disagree with Python.
String pyLower(String text) {
  final runes = text.runes.toList();
  final out = StringBuffer();
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (r == 0x130) {
      out.write('i\u0307');
    } else if (r == 0x3A3) {
      out.writeCharCode(_finalSigma(runes, i) ? 0x3C2 : 0x3C3);
    } else {
      out.write(String.fromCharCode(r).toLowerCase());
    }
  }
  return out.toString();
}

/// Python's `handle_capital_sigma`: a cased letter before [at] and none after
/// it, case-ignorable characters skipped both ways.
bool _finalSigma(List<int> runes, int at) {
  var j = at - 1;
  while (j >= 0 && _isCaseIgnorable(runes[j])) {
    j--;
  }
  if (j < 0 || !_isCased(runes[j])) return false;
  j = at + 1;
  while (j < runes.length && _isCaseIgnorable(runes[j])) {
    j++;
  }
  return j == runes.length || !_isCased(runes[j]);
}

/// A letter with a case: one that an upper- or lower-case mapping moves.
bool _isCased(int rune) {
  final s = String.fromCharCode(rune);
  return s.toLowerCase() != s || s.toUpperCase() != s;
}

/// The Case_Ignorable characters a name can plausibly carry: the
/// apostrophes, dots and colons of Word_Break MidLetter/MidNumLet, the
/// spacing accents, the soft hyphen and format characters, and the combining
/// mark blocks.
bool _isCaseIgnorable(int r) =>
    r == 0x27 ||
    r == 0x2E ||
    r == 0x3A ||
    r == 0x5E ||
    r == 0x60 ||
    r == 0xA8 ||
    r == 0xAD ||
    r == 0xAF ||
    r == 0xB4 ||
    r == 0xB7 ||
    r == 0xB8 ||
    r == 0x2018 ||
    r == 0x2019 ||
    r == 0x2024 ||
    r == 0x2027 ||
    r == 0xFEFF ||
    (r >= 0x200B && r <= 0x200F) ||
    (r >= 0x202A && r <= 0x202E) ||
    (r >= 0x2060 && r <= 0x2064) ||
    (r >= 0x300 && r <= 0x36F) ||
    (r >= 0x483 && r <= 0x489) ||
    (r >= 0x1AB0 && r <= 0x1AFF) ||
    (r >= 0x1DC0 && r <= 0x1DFF) ||
    (r >= 0x20D0 && r <= 0x20FF) ||
    (r >= 0xFE00 && r <= 0xFE0F) ||
    (r >= 0xFE20 && r <= 0xFE2F);
