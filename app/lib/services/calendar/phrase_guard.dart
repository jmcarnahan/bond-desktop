// The literal guard shared by every reader that lets a model COPY phrases
// (docs/pipeline/14-calendar.md): the command bar's `calendar_intent` and
// the scheduling ask's `ask_read`. A phrase the model hands back is kept
// only when it is in the text it read.

/// Where [phrase] sits in [text] as `[start, end)`, ignoring case and runs
/// of whitespace, and only as whole words — "Dan" is not in "Danielle" —
/// or null when it is not there (and for a blank [phrase]). The check that
/// keeps a model to copying.
(int, int)? findPhrase(String text, String phrase) {
  final t = phrase.trim();
  if (t.isEmpty) return null;
  final words = t.split(RegExp(r'\s+')).map(RegExp.escape);
  final m = RegExp(
    '(?<![\\p{L}\\p{N}])${words.join(r'\s+')}(?![\\p{L}\\p{N}])',
    caseSensitive: false,
    unicode: true,
  ).firstMatch(text);
  return m == null ? null : (m.start, m.end);
}
