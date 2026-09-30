import '../../../models/calendar_models.dart';
import '../calendar_zone.dart';
import '../when_resolver.dart';
import '../write_rules.dart' show moveShiftOf;
import 'command_lexicon.dart';
import 'command_types.dart';
import 'event_matcher.dart';
import 'people_matcher.dart';

/// One calendar command read into its slots, synchronously, with no model
/// and no network (plan §1.1, docs/pipeline/14-calendar.md "Commands").
///
/// The live preview runs this on every keystroke, and Enter runs it again
/// before anything else, so it composes only pure lookups: the lexicon names
/// the action, [resolveWhen] the when and the duration, [matchPeople] the
/// people, [matchEvents] the meeting. What is left over is the subject.
///
/// **The leftover rule.** Take away the verb phrase, every when-phrase, every
/// person, and the filler ("my", "the", "with", "meeting", "please", "in my
/// calendar"…), and the words that remain are the subject. Quoted text
/// ("…") is the subject verbatim instead, and is never read as a when or a
/// person, so `book "Friday retro" Thu 3pm` books Thursday.
///
/// **The move split.** "move my 3pm to Thursday" names two times: which
/// meeting, and where it goes. The words before the last "to" / "until"
/// that is followed by a when-phrase say which meeting
/// ([ParsedCommand.eventWhen]); the rest is the target
/// ([ParsedCommand.targetText]). With no such "to", a when-phrase marked as
/// a reference ("my 3pm", "Monday's", "the 10am") is the meeting and the rest
/// is the target; with neither, the whole text is the target.

/// Words that carry no subject. Lower case, possessive already dropped.
const Set<String> _filler = {
  'my', 'the', 'a', 'an', 'with', 'to', 'at', 'on', 'for', 'meeting',
  'meetings', 'call', 'and', 'or', 'please', 'me', 'in', 'calendar', 'i',
  'can', 'you', 'could', 'would', 'will', 'what', 'whats', 'when', 'do',
  'did', 'have', 'is', 'are', 'am', 'it', 'of', 'from', 'by', 'up', 'off',
  'our', 'we', 'us', 'about', 'meet', 'met', 'see', 'seeing', 'talk',
  'talked', 'spoke', 'last', 'next', 'some', 'any', 'hey', 'ok', 'okay',
  'also', 'then', 'let', 'lets', 'just', 'that', 'this', 'there', 'be',
  'slot', 'time', 'free', 'thanks', 'thank', 'go', 'ahead', 'want', 'need',
  'like', 'id', 'invite', 'event', 'pls', 'plz', 'w',
};

final RegExp _word = RegExp(r"[A-Za-z0-9][A-Za-z0-9'’:&+.\-]*");

final RegExp _quoted = RegExp(r'["“”]([^"“”]+)["“”]');

final RegExp _moveMarker =
    RegExp(r'\b(?:to|until|till|til|into)\b', caseSensitive: false);

/// A when-phrase that says WHICH meeting: after "my", "the", "our", "this",
/// "that", "your", or followed by a possessive.
final RegExp _referenceBefore =
    RegExp(r'\b(?:my|the|our|your|that)\s+$', caseSensitive: false);
final RegExp _possessiveAfter = RegExp(r"^['’]s?\b");

bool _inside(int s, int e, Iterable<(int, int)> spans) {
  for (final (a, b) in spans) {
    if (s < b && a < e) return true;
  }
  return false;
}

String _stripWord(String w) => w
    .replaceAll(RegExp(r"['’]s?$"), '')
    .replaceAll(RegExp(r'[.:\-]+$'), '');

/// Reads [text] into its slots.
///
/// [guess] is a classifier's answer the caller already has (Phase 9's
/// command head); without one the lexicon names the action. [people] is the
/// directory ([knownPeopleFrom]); [events] the cached meetings to match
/// against — the caller hands the mirror's next weeks, and this never reads a
/// store.
ParsedCommand parseCommand(
  String text, {
  required DateTime now,
  required CalendarZone zone,
  required List<KnownPerson> people,
  required List<CalendarEvent> events,
  CommandGuess? guess,
}) {
  final hit = lexiconHit(text);
  final g = guess ?? hit?.guess ?? CommandGuess.none;

  // A quoted subject is masked (same length, so every offset still holds)
  // before the resolver sees the text: "Friday retro" is a title.
  final q = _quoted.firstMatch(text);
  final masked = q == null
      ? text
      : text.replaceRange(q.start, q.end, ' ' * (q.end - q.start));

  final when = resolveWhen(masked, now: now, zone: zone, mode: g.mode);

  final consumed = <(int, int)>{
    if (hit != null) (hit.start, hit.end),
    for (final s in when.spans) (s.start, s.end),
    if (q != null) (q.start, q.end),
  };
  final match = matchPeople(text, people, consumed: consumed);

  // ── the move split ──
  var targetStart = 0;
  var eventWhen = when;
  if (g.action == CommandAction.move) {
    final placed = [
      for (final s in when.spans)
        if (s.kind != WhenKind.duration) s,
    ];
    RegExpMatch? cut;
    for (final m in _moveMarker.allMatches(masked).toList().reversed) {
      if (placed.any((s) => s.start >= m.end)) {
        cut = m;
        break;
      }
    }
    if (cut != null) {
      targetStart = cut.start;
    } else {
      final refs = [
        for (final s in placed)
          if (_referenceBefore.hasMatch(masked.substring(0, s.start)) ||
              _possessiveAfter.hasMatch(masked.substring(s.end)))
            s,
      ];
      if (refs.isNotEmpty) {
        final end = refs.last.end;
        // Past the possessive too: "tomorrow's" is all reference.
        final s = _possessiveAfter.firstMatch(masked.substring(end));
        targetStart = end + (s?.end ?? 0);
      }
    }
    eventWhen = targetStart == 0
        ? WhenResolution(today: when.today, zone: zone)
        : resolveWhen(masked.substring(0, targetStart),
            now: now, zone: zone, mode: g.mode);
  }

  // ── the leftover words ──
  final taken = {...consumed, ...match.spans};
  final leftover = <String>[];
  for (final m in _word.allMatches(text)) {
    if (_inside(m.start, m.end, taken)) continue;
    final w = _stripWord(m.group(0)!);
    if (w.isEmpty) continue;
    final lower = w.toLowerCase().replaceAll(RegExp("['’]"), '');
    if (_filler.contains(lower)) continue;
    leftover.add(w);
  }
  final quoted = q?.group(1)?.trim() ?? '';
  final subject = quoted.isNotEmpty ? quoted : leftover.join(' ');

  final parsed = ParsedCommand(
    text: text,
    guess: g,
    when: when,
    eventWhen: eventWhen,
    targetStart: targetStart,
    duration: when.duration,
    people: match,
    subject: subject,
    quotedSubject: quoted.isNotEmpty,
    leftoverWords: List.unmodifiable(leftover),
  );
  return settleCommand(parsed, now: now, zone: zone, events: events);
}

/// Re-derives what follows from [p]'s slots: the event candidates (when the
/// action is about one meeting, or not yet known), the unresolved set and
/// the leftover flag. The router calls it after merging the model's copied
/// phrases or a choice the person pressed, so those rules live once.
///
/// [rematch] false keeps [p]'s candidates as they are — a pressed choice
/// binds its event and must not be scored away again.
ParsedCommand settleCommand(
  ParsedCommand p, {
  required DateTime now,
  required CalendarZone zone,
  required List<CalendarEvent> events,
  bool rematch = true,
}) {
  final action = p.action;
  var candidates = p.events;
  if (rematch) {
    candidates = action.needsEvent || action == CommandAction.unknown
        ? matchEvents(
            subjectWords: p.subject,
            when: p.eventWhen,
            people: p.people,
            events: events,
            zone: zone,
            now: now,
          )
        : const <EventCandidate>[];
  }

  final unresolved = <CommandSlot>{};
  if (action == CommandAction.unknown) unresolved.add(CommandSlot.action);

  bool placed(WhenResolution w) => w.day != null || w.time != null;
  switch (action) {
    case CommandAction.create:
    case CommandAction.askFree:
      if (!placed(p.when)) unresolved.add(CommandSlot.when);
    case CommandAction.move:
      final target = p.targetText.trim().isEmpty
          ? WhenResolution(today: p.when.today, zone: zone)
          : resolveWhen(p.targetText,
              now: now, zone: zone, mode: WhenMode.booking);
      // "by an hour" places it as surely as "to 4pm" does.
      final shifted =
          moveShiftOf(p.targetText, now: now, zone: zone) != null;
      if (!placed(target) && !shifted) unresolved.add(CommandSlot.when);
    default:
      break;
  }
  if ((action == CommandAction.findTime ||
          action == CommandAction.askPerson) &&
      p.people.matched.isEmpty &&
      p.people.ambiguous.isEmpty) {
    unresolved.add(CommandSlot.people);
  }
  if (action.needsEvent && candidates.isEmpty) {
    unresolved.add(CommandSlot.event);
  }
  if (action == CommandAction.create && p.subject.trim().isEmpty) {
    unresolved.add(CommandSlot.subject);
  }

  // For a create or a find-a-time the leftover words ARE the subject, so
  // they are explained; everywhere else a word nothing consumed is a sign
  // the lexicon read only part of the request.
  final explainedBySubject =
      action == CommandAction.create || action == CommandAction.findTime;
  final leftover = !p.quotedSubject &&
      !explainedBySubject &&
      p.leftoverWords.isNotEmpty;

  return p.copyWith(
    events: candidates,
    unresolved: Set.unmodifiable(unresolved),
    leftoverAfterResolvers: unresolved.isNotEmpty && leftover,
  );
}

/// [p]'s subject with [names] put back into it: the words a create took
/// for invitees, given back when the directory knew none of them, so "book
/// lunch with Design team Friday" is a meeting called "lunch with Design
/// team" rather than a refusal.
///
/// The subject becomes the stretch of the text from its first subject word
/// (or returned name) to its last, with the verb, every when-phrase and
/// every person still bound taken out — which keeps the "with" between
/// them, as it was typed. A quoted subject is the person's own words and is
/// returned unchanged.
String subjectRestoring(ParsedCommand p, Iterable<String> names) {
  if (p.quotedSubject) return p.subject;
  final text = p.text;
  final restored = <(int, int)>[];
  for (final name in names) {
    final m = RegExp(
      '(?<![\\p{L}\\p{N}])${RegExp.escape(name)}(?![\\p{L}\\p{N}])',
      unicode: true,
    ).firstMatch(text);
    if (m != null) restored.add((m.start, m.end));
  }
  if (restored.isEmpty) return p.subject;
  final hit = lexiconHit(text);
  final taken = <(int, int)>[
    if (hit != null) (hit.start, hit.end),
    // "lunch" is a part of the day to the resolver and a meal to the person:
    // in a title it is the title's word ("lunch with Design team").
    for (final s in p.when.spans)
      if (s.kind != WhenKind.part ||
          !text.substring(s.start, s.end).toLowerCase().contains('lunch'))
        (s.start, s.end),
    for (final s in p.people.spans)
      if (!restored.any((r) => r.$1 < s.$2 && s.$1 < r.$2)) s,
  ];
  // Where the subject runs: its own words and the names given back.
  var from = text.length;
  var to = 0;
  for (final (a, b) in restored) {
    if (a < from) from = a;
    if (b > to) to = b;
  }
  for (final m in _word.allMatches(text)) {
    if (_inside(m.start, m.end, taken)) continue;
    final w = _stripWord(m.group(0)!);
    final lower = w.toLowerCase().replaceAll(RegExp("['’]"), '');
    if (w.isEmpty || _filler.contains(lower)) continue;
    if (m.start < from) from = m.start;
    if (m.end > to) to = m.end;
  }
  final chars = text.substring(from, to).split('');
  for (final (a, b) in taken) {
    for (var i = a; i < b; i++) {
      if (i >= from && i < to) chars[i - from] = ' ';
    }
  }
  return chars.join().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The action's own day for an agenda, or today: the one slot that is never
/// unresolved, because "what's on" means today.
CalendarDate agendaDay(ParsedCommand p) => p.when.day ?? p.when.today;
