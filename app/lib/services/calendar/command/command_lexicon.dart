import 'package:flutter/foundation.dart' show immutable;

import '../calendar_zone.dart';
import '../when_resolver.dart';
import 'command_types.dart';

/// The command bar's first reader: verb and phrase rules that name the action
/// of a calendar command (plan §1.1, docs/pipeline/14-calendar.md
/// "Commands").
///
/// The action is a closed set of ten, and people say most of them with a
/// handful of verbs, so a table of phrases answers the common case in
/// microseconds, per keystroke, with no model loaded. What it cannot read it
/// says so (a low confidence, or `unknown`), and the router asks the
/// generative model on Enter instead of this file guessing.
///
/// **How a phrase wins.** Every rule is matched case-insensitively on word
/// boundaries. A STRONG phrase (a verb: "move", "cancel", "am I free") beats
/// every weak cue (a word that is a command only sometimes: "maybe",
/// "invite", "agenda"), wherever the two sit; among phrases of one strength
/// the earliest wins, and at one position the longest — so "tentatively
/// accept" is a maybe, not an accept, and "maybe move my 3pm" is a move.
///
/// **Confidence tiers.** 0.9 for a strong phrase that leads the command
/// (after "please", "can you" and the like), 0.75 for one elsewhere, 0.6 for
/// a weak cue anywhere, 0.0 for `unknown`.

/// Confidence of a strong phrase that leads the command.
const double lexiconLeading = 0.9;

/// Confidence of a strong phrase further in.
const double lexiconInside = 0.75;

/// Confidence of a weak cue.
const double lexiconWeak = 0.6;

/// One rule: a phrase pattern, the action it names, and whether it is only a
/// weak cue.
class _Rule {
  final RegExp re;
  final CommandAction action;
  final bool weak;

  _Rule(String pattern, this.action, {this.weak = false})
      : re = RegExp('\\b(?:$pattern)', caseSensitive: false);
}

/// Apostrophes both ways: macOS turns a typed ' into ’.
const String _q = "['’]";

/// The table. "schedule" after a determiner is the noun ("what's on my
/// schedule"), never the verb; `\bbook\b` leaves "booking" alone.
final List<_Rule> _rules = [
  // ── create ──
  _Rule(r'(?<!\b(?:my|the|your|a|our)\s)schedule\b', CommandAction.create),
  _Rule(r'book\b', CommandAction.create),
  _Rule(r'set\s+up\b|setup\b', CommandAction.create),
  _Rule(r'block(?:\s+off)?\b', CommandAction.create),
  _Rule(r'put\s+in\b', CommandAction.create),
  _Rule(r'new\s+meeting\b', CommandAction.create),
  _Rule(r'add\b', CommandAction.create, weak: true),
  _Rule(r'invite\b', CommandAction.create, weak: true),
  // ── move ──
  _Rule(r'move\b|push\b|reschedule\b|shift\b|bump\b|postpone\b',
      CommandAction.move),
  // ── cancel ──
  _Rule(r'cancel\b|drop\b|delete\b|call\s+off\b|remove\b',
      CommandAction.cancel),
  // ── answers ──
  _Rule(
      'accept\\b|yes\\s+to\\b|i${_q}ll\\s+be\\s+there\\b|'
      'i\\s+will\\s+be\\s+there\\b|say\\s+yes\\b',
      CommandAction.rsvpYes),
  _Rule(
      'decline\\b|can$_q?t\\s+make\\b|cannot\\s+make\\b|'
      'can\\s+not\\s+make\\b|say\\s+no\\b|turn\\s+down\\b',
      CommandAction.rsvpNo),
  _Rule(r'tentative(?:ly)?(?:\s+accept)?\b|say\s+maybe\b',
      CommandAction.rsvpMaybe),
  _Rule(r'maybe\b', CommandAction.rsvpMaybe, weak: true),
  // ── find a time ──
  _Rule(
      r'find\s+(?:a\s+|some\s+)?(?:time|slot)\b|'
      r'find\s+(?:\d+(?:\.\d+)?\s*(?:m|min|mins|minutes?|h|hr|hrs|hours?)|'
      r'an?\s+hour|half\s+an\s+hour)\b|'
      r'when\s+can\b|good\s+time\b',
      CommandAction.findTime),
  _Rule(r'slot\s+with\b|free\s+with\b', CommandAction.findTime, weak: true),
  // ── asks ──
  _Rule(
      '(?:when\\s+)?am\\s+i\\s+free\\b(?!\\s+with\\b)|what$_q?s\\s+free\\b|'
      'what\\s+is\\s+free\\b|do\\s+i\\s+have\\s+time\\b',
      CommandAction.askFree),
  _Rule(r'any\s+time\b', CommandAction.askFree, weak: true),
  _Rule(
      'what$_q?s\\s+on\\b|what\\s+is\\s+on\\b|what\\s+do\\s+i\\s+have\\b|'
      "what$_q?s\\s+(?:my\\s+)?(?:day|schedule)\\b",
      CommandAction.askAgenda),
  _Rule(r'agenda\b|my\s+day\b|my\s+schedule\b|anything\s+on\b',
      CommandAction.askAgenda,
      weak: true),
  _Rule(
      r'when\s+did\s+i\s+last\b|last\s+(?:meet|met|meeting|saw)\s+with\b|'
      r'last\s+(?:met|saw)\b|next\s+meeting\s+with\b|'
      r'when\s+am\s+i\s+(?:seeing|meeting)\b',
      CommandAction.askPerson),
];

/// What may precede a leading verb and still leave it leading.
final RegExp _politePrefix = RegExp(
  r'^[\s,]*(?:(?:please|pls|hey|ok|okay|and|also|then|can\s+you|could\s+you|'
  r'would\s+you|will\s+you|i\s+want\s+to|i\s+need\s+to|i\s+wanna|'
  "i${_q}d\\s+like\\s+to|let$_q?s|help\\s+me|go\\s+ahead\\s+and)"
  r'\b[\s,]*)*',
  caseSensitive: false,
);

/// The winning phrase: its action, confidence and character span.
@immutable
class LexiconHit {
  final CommandAction action;
  final double confidence;
  final int start;
  final int end;

  const LexiconHit(this.action, this.confidence, this.start, this.end);

  CommandGuess get guess => CommandGuess(action, confidence, CommandPath.lexicon);
}

/// The phrase that names [text]'s action, or null when no rule matched.
LexiconHit? lexiconHit(String text) {
  final lead = _politePrefix.firstMatch(text)?.end ?? 0;
  ({int start, int end, _Rule rule})? best;
  for (final rule in _rules) {
    for (final m in rule.re.allMatches(text)) {
      final c = (start: m.start, end: m.end, rule: rule);
      if (best == null) {
        best = c;
        continue;
      }
      final b = best;
      // Strong beats weak; then earliest; then longest.
      if (b.rule.weak != rule.weak) {
        if (b.rule.weak) best = c;
        continue;
      }
      if (c.start < b.start ||
          (c.start == b.start && c.end - c.start > b.end - b.start)) {
        best = c;
      }
    }
  }
  final b = best;
  if (b == null) return null;
  final confidence = b.rule.weak
      ? lexiconWeak
      : (b.start <= lead ? lexiconLeading : lexiconInside);
  return LexiconHit(b.rule.action, confidence, b.start, b.end);
}

/// The lexicon's guess for [text]: `unknown` at 0.0 when nothing matched.
CommandGuess classifyByLexicon(String text) =>
    lexiconHit(text)?.guess ?? CommandGuess.none;

/// The winning verb phrase's span, so the parser can take it out of the
/// leftover words. Empty when nothing matched.
Set<(int, int)> lexiconSpans(String text) {
  final hit = lexiconHit(text);
  return hit == null ? const {} : {(hit.start, hit.end)};
}

/// The lexicon as a [CommandClassifier]: always answers, never waits.
class LexiconClassifier implements CommandClassifier {
  const LexiconClassifier();

  CommandGuess classifySync(String text) => classifyByLexicon(text);

  @override
  Future<CommandGuess?> classify(String text) async => classifySync(text);
}

/// Nouns that make a verb or a when-phrase a calendar matter: "cancel the
/// standup" is, "cancel subscription" is not; "tomorrow's meeting" is,
/// "tomorrow's invoice" is not.
final RegExp _calendarNoun = RegExp(
  r'\b(?:meetings?|calls?|invites?|invitations?|calendar|sync|standup|'
  r'stand-up|1:1s?|1-1|one-on-one|lunch|appointments?|events?)\b',
  caseSensitive: false,
);

/// A Find facet (`label:invoices`, `from:dana`, `-label:ops`): the names
/// both of Find's grammar (`widgets/find_filter.dart`, which `services/`
/// cannot import) and of search's (`search_grammar.dart`), plus `to:`. A
/// needle carrying one is a search being built, whatever else it says.
final RegExp _findFacet = RegExp(
  r'(?<!\S)-?(?:label|from|to|is|has|in|before|after):\S',
  caseSensitive: false,
);

/// The polite lead ⌘K strips once before asking whether a verb leads.
final RegExp _askLead = RegExp(
  r'^(?:please|hey|ok|okay|can\s+you|could\s+you|would\s+you)[,\s]+',
  caseSensitive: false,
);

/// A find-a-time names who it is for with this word.
final RegExp _with = RegExp(r'\bwith\b', caseSensitive: false);

/// Whether ⌘K's Find text reads as something to hand the Day stop.
///
/// The row that answers true takes Enter away from the search, so the test
/// is narrow: a calendar verb or ask must LEAD the text (after "please",
/// "can you" and the like), and then
///
/// - a person ask stands alone ("when did I last meet Sam");
/// - a find-a-time stands alone only with a "with" after it ("find time
///   with Dana");
/// - every other phrase needs a day or clock time, or a calendar noun, after
///   it ("move my 3pm to Thursday", "cancel the standup", "what's on
///   tomorrow").
///
/// A phrase further in is a search ("had a good time at the offsite", "notes
/// from Monday's meeting"), as is a day beside a noun with no verb ("Friday
/// call recap") and any needle carrying a Find facet. A verb alone is not
/// enough either, however strong: "push notifications", "cancel
/// subscription", "book club" and "delete account" are searches for mail.
/// A false negative costs the person one click on the Day stop; a false
/// positive loses what they typed.
///
/// [now] and [zone] only feed the resolver, whose question here — is there a
/// when-phrase at all — does not depend on either; they default to the clock
/// and UTC so ⌘K can call this with the text alone.
bool looksLikeCalendarCommand(
  String text, {
  DateTime? now,
  CalendarZone? zone,
}) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (_findFacet.hasMatch(t)) return false;
  final lead = _askLead.firstMatch(t)?.end ?? 0;
  final body = t.substring(lead);
  final hit = lexiconHit(body);
  if (hit == null || hit.start != 0) return false;
  final rest = body.substring(hit.end);
  if (hit.action == CommandAction.askPerson) return true;
  if (hit.action == CommandAction.findTime && _with.hasMatch(rest)) {
    return true;
  }
  if (_calendarNoun.hasMatch(rest)) return true;
  final when = resolveWhen(
    rest,
    now: now ?? DateTime.now().toUtc(),
    zone: zone ?? CalendarZone.utc(),
    mode: WhenMode.booking,
  );
  // Only a day or a clock time counts: a bare duration ("30 min") or part of
  // day ("lunch") says nothing about a calendar on its own.
  return when.spans.any((s) =>
      s.kind != WhenKind.duration && s.kind != WhenKind.part);
}
