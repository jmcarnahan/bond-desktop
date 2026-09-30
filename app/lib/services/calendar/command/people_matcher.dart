import 'command_types.dart';

/// Who a calendar command names, read by exact lookup against the People
/// directory (plan §1.1: the people slot is a KNOWN set, so it is matched,
/// never generated).
///
/// The rules, in the order they are tried at each word:
///
/// - an **address** ("dana@contoso.com") is that person, known or not — it is
///   exactly what an invite is sent to;
/// - a **full name** (two or more consecutive words equal to a directory
///   name, any case) is that person, or everyone with that name;
/// - a single word equal to the **first name** of exactly one person is that
///   person; equal to several, it is AMBIGUOUS and the planner asks which;
/// - a **capitalised** word that matched nobody is UNRESOLVED — the router
///   looks it up in the organisation's directory on Enter — but only where a
///   name is expected: after "with", "invite", "meet", "see", "cc" or "to",
///   or continuing a list of people ("with Dana, Lee and Priya"). A
///   capitalised word anywhere else is usually the subject ("book Design
///   review"), and a directory search for "Design" would be noise at best
///   and a wrong invitee at worst. A sentence's first word never counts.
///
/// Words inside [matchPeople]'s `consumed` spans — the verb phrase, the
/// when-phrases, a quoted subject — are never people: "Friday" is a day and
/// "May 3" a date, whoever is called May.

/// Where a name is expected next.
const Set<String> _nameCues = {
  'with',
  'invite',
  'invites',
  'inviting',
  'meet',
  'meeting',
  'met',
  'see',
  'seeing',
  'saw',
  'cc',
  'to',
  'plus',
};

/// Joins a list of people: "Dana, Lee and Priya".
const Set<String> _listJoins = {'and', 'or'};

/// Words that are never a person on their own, whatever their case or
/// whoever is in the directory: function words, and the handful of first
/// names that are also everyday English ("will", "may", "mark") when typed in
/// lower case. Capitalised, a first name in this list still matches — "with
/// Will" is Will.
const Set<String> _commonWords = {
  'a', 'an', 'the', 'my', 'our', 'your', 'me', 'i', 'we', 'us', 'you',
  'with', 'and', 'or', 'to', 'at', 'on', 'in', 'for', 'of', 'from', 'by',
  'meeting', 'call', 'sync', 'lunch', 'please', 'can', 'could', 'would',
  'will', 'may', 'mark', 'bill', 'pat', 'sue', 'rob', 'art', 'grace', 'rose',
  'hope', 'joy', 'june', 'april', 'august', 'jack', 'chase', 'drew', 'max',
  'dawn', 'faith', 'ray', 'frank', 'sunny', 'amber', 'ruby', 'summer', 'guy',
  'is', 'it', 'be', 'do', 'am', 'are', 'what', 'when', 'who', 'next', 'last',
};

/// Capitalised words that are never a name to look up.
const Set<String> _notNames = {
  'i', 'im', 'ill', 'ive', 'id', 'ok', 'okay', 'am', 'pm', 'eod', 'asap',
  'teams', 'zoom', 'outlook', 'meet', 'monday', 'tuesday', 'wednesday',
  'thursday', 'friday', 'saturday', 'sunday', 'mon', 'tue', 'tues', 'wed',
  'thu', 'thur', 'thurs', 'fri', 'sat', 'sun', 'january', 'february',
  'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october',
  'november', 'december', 'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug',
  'sep', 'sept', 'oct', 'nov', 'dec', 'today', 'tomorrow', 'tonight',
  'please', 'the', 'my', 'a', 'an', 'and', 'or', 'with', 'to',
};

final RegExp _token = RegExp(
  r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|[A-Za-z][A-Za-z'’-]*",
);

final RegExp _possessive = RegExp(r"['’]s?$");

class _Tok {
  final int start;
  final int end;
  final String raw;

  /// Lower case, possessive dropped ("Dana's" → "dana").
  final String base;
  final bool consumed;

  _Tok(this.start, this.end, this.raw, this.consumed)
      : base = raw.toLowerCase().replaceFirst(_possessive, '');

  bool get isAddress => raw.contains('@');
  bool get capitalised {
    final c = raw.codeUnitAt(0);
    return c >= 0x41 && c <= 0x5A;
  }
}

bool _overlaps(int s, int e, Iterable<(int, int)> spans) {
  for (final (a, b) in spans) {
    if (s < b && a < e) return true;
  }
  return false;
}

/// The people [text] names, looked up in [people].
///
/// Pure: the same text and directory always give the same answer, which is
/// what lets the command bar run it on every keystroke.
PeopleMatch matchPeople(
  String text,
  List<KnownPerson> people, {
  Set<(int, int)> consumed = const {},
}) {
  final byAddress = <String, KnownPerson>{};
  final byFullName = <String, List<KnownPerson>>{};
  final byFirstName = <String, List<KnownPerson>>{};
  var longestName = 1;
  for (final p in people) {
    byAddress[p.address] = p;
    final words = p.name
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) continue;
    if (words.length > longestName) longestName = words.length;
    if (words.length > 1) {
      (byFullName[words.join(' ')] ??= []).add(p);
    }
    (byFirstName[words.first] ??= []).add(p);
  }

  final toks = [
    for (final m in _token.allMatches(text))
      _Tok(m.start, m.end, m.group(0)!, _overlaps(m.start, m.end, consumed)),
  ];

  final matched = <KnownPerson>[];
  final ambiguous = <List<KnownPerson>>[];
  final unresolved = <String>[];
  final spans = <(int, int)>[];

  void hit(List<KnownPerson> found, int start, int end) {
    spans.add((start, end));
    if (found.length == 1) {
      if (!matched.contains(found.single)) matched.add(found.single);
    } else {
      ambiguous.add(List.unmodifiable(found));
    }
  }

  /// Only whitespace between two tokens: they can be one name.
  bool adjacent(_Tok a, _Tok b) =>
      text.substring(a.end, b.start).trim().isEmpty;

  /// Only list punctuation between two tokens: a list of people goes on.
  bool listGap(_Tok a, _Tok b) =>
      RegExp(r'^[\s,&+/]*$').hasMatch(text.substring(a.end, b.start));

  bool sentenceStart(int i) {
    if (i == 0) return true;
    final before = text.substring(0, toks[i].start).trimRight();
    return before.isEmpty ||
        before.endsWith('.') ||
        before.endsWith('!') ||
        before.endsWith('?');
  }

  // Whether a name is expected at the next token: after a cue, or while a
  // list of people is still going.
  var expecting = false;
  var i = 0;
  while (i < toks.length) {
    final t = toks[i];
    final prev = i > 0 ? toks[i - 1] : null;
    if (prev != null && !listGap(prev, t)) expecting = false;
    if (t.consumed) {
      // The verb ("invite") and the like are consumed, yet still say a name
      // comes next.
      expecting = _nameCues.contains(t.base);
      i++;
      continue;
    }

    if (t.isAddress) {
      final address = t.raw.toLowerCase();
      hit([byAddress[address] ?? KnownPerson(name: '', address: address)],
          t.start, t.end);
      expecting = true;
      i++;
      continue;
    }

    // The longest full name starting here, over unconsumed adjacent words.
    var took = 0;
    for (var n = longestName; n >= 2 && took == 0; n--) {
      if (i + n > toks.length) continue;
      final run = toks.sublist(i, i + n);
      var ok = true;
      for (var k = 0; k < n; k++) {
        if (run[k].consumed || run[k].isAddress) ok = false;
        if (k > 0 && !adjacent(run[k - 1], run[k])) ok = false;
      }
      if (!ok) continue;
      final found = byFullName[run.map((r) => r.base).join(' ')];
      if (found == null) continue;
      hit(found, run.first.start, run.last.end);
      took = n;
    }
    if (took > 0) {
      expecting = true;
      i += took;
      continue;
    }

    final first = byFirstName[t.base];
    if (first != null && (t.capitalised || !_commonWords.contains(t.base))) {
      hit(first, t.start, t.end);
      expecting = true;
      i++;
      continue;
    }

    if (expecting &&
        t.capitalised &&
        !sentenceStart(i) &&
        !_notNames.contains(t.base)) {
      // "Pat Kim": capitalised neighbours are one unknown name.
      var j = i;
      while (j + 1 < toks.length &&
          !toks[j + 1].consumed &&
          !toks[j + 1].isAddress &&
          toks[j + 1].capitalised &&
          !_notNames.contains(toks[j + 1].base) &&
          adjacent(toks[j], toks[j + 1])) {
        j++;
      }
      final end = toks[j].end;
      final name = text
          .substring(t.start, end)
          .replaceFirst(_possessive, '')
          .trim();
      spans.add((t.start, end));
      if (!unresolved.contains(name)) unresolved.add(name);
      expecting = true;
      i = j + 1;
      continue;
    }

    // "and"/"or" keep a list of people open; a cue opens one; any other
    // word closes it.
    if (_listJoins.contains(t.base)) {
      // Unchanged: open only if it already was.
    } else {
      expecting = _nameCues.contains(t.base);
    }
    i++;
  }

  return PeopleMatch(
    matched: List.unmodifiable(matched),
    ambiguous: List.unmodifiable(ambiguous),
    unresolved: List.unmodifiable(unresolved),
    spans: List.unmodifiable(spans),
  );
}
