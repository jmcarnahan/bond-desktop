// The ask's own words: where a quoted reply starts, and how much of what is
// left each reader takes. Shared by the rules (`ask_hints.dart`) and the
// model's task (`ask_read_task.dart`), so the two read the same words and
// neither imports the other.

/// How much of an ask is read: its opening lines carry the time; a long
/// quoted history below them only adds other people's dates.
const int askHintsCap = 600;

/// How much of an ask's own words the model reads. Wider than the rules'
/// `askHintsCap` (600): the model can tell an ask from the chatter around
/// it, so a longer opening costs it nothing but tokens.
const int askReadCap = 1500;

/// A year as a reply header writes it: after a comma or a slash ("Sep 29,
/// 2026", "29/09/2026"), or opening an ISO date ("2026-09-29") — never a
/// clock time such as "at 1930".
const String _year = r'(?:(?:,\s*|/)(?:19|20)\d\d\b|\b(?:19|20)\d\d-\d\d)';

/// Where a quoted reply starts: "On Mon, Sep 28, 2026 at 3:15 PM Dana
/// (dana@…) wrote:" (which a client may wrap over two lines), an Outlook
/// "-----Original Message-----", or a header block — a "From:" line with a
/// "Sent:", "Date:" or "To:" line within the two under it, either possibly
/// quoted with ">". Everything after it is the thread's history, whose
/// dates are not this ask's.
///
/// Each form is held to what only a header has, because the cut drops
/// everything below it: an "On … wrote:" needs a [_year], a "<" or an "@"
/// in its line or two ("On second thought, Friday dinner works." above
/// somebody's "… wrote:" is the ask, not its history), and a lone "From:
/// tomorrow on I am free" line is a sentence.
final RegExp _quoteStart = RegExp(
    r'(^|\n)[ \t]*>?[ \t]*(?:'
    'On\\s[^\\n]*(?:$_year|<|@)[^\\n]*(?:\\n[^\\n]*)?wrote:'
    '|On\\s[^\\n]*\\n[^\\n]*(?:$_year|<|@)[^\\n]*wrote:'
    r'|-{2,}\s*Original Message\s*-{2,}'
    r'|From:[^\n]*\n(?:[^\n]*\n)?[ \t]*>?[ \t]*(?:Sent|Date|To):)',
    caseSensitive: false);

/// [body] up to its first quoted-reply header ([_quoteStart]): the ask's
/// own words, which both readers read.
String askOwnWords(String body) {
  final m = _quoteStart.firstMatch(body);
  return m == null ? body : body.substring(0, m.start);
}

/// [s] cut to at most [max] UTF-16 units, back to the last whitespace
/// before the cap so a word is never halved ("at 11pm" never reads "at 1"),
/// and so never through a surrogate pair either. `brief_gatherer.dart`'s
/// `capRunes` cuts mid-word, which a resolver cannot afford.
String capAtWord(String s, int max) {
  if (s.length <= max) return s;
  final space = s.lastIndexOf(RegExp(r'\s'), max);
  if (space > 0) return s.substring(0, space);
  final last = s.codeUnitAt(max - 1);
  return s.substring(0, last >= 0xD800 && last <= 0xDBFF ? max - 1 : max);
}
