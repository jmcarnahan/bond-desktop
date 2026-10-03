import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../../../models/calendar_models.dart';
import '../../../models/person.dart';
import '../../activity_log.dart';
import '../../backend/people_backend.dart';
import '../../llm/calendar_intent_task.dart';
import '../../llm/json_task.dart';
import '../../llm/llm_client.dart';
import '../calendar_zone.dart';
import '../when_resolver.dart';
import 'command_lexicon.dart';
import 'command_parser.dart';
import 'command_planner.dart';
import 'command_types.dart';
import 'people_matcher.dart';

/// Where a command goes on Enter (docs/pipeline/14-calendar.md "Commands"):
/// the classifiers, the parse, the model only when the rules could not
/// finish, a directory look-up for names nobody in the mail has, then the
/// planner.
///
/// **When the model is asked.** Exactly once per Enter, and only when the
/// best classifier is under [CommandRouter.confidenceBar] (0.8), or a
/// required slot is unresolved AND words remain that no resolver explained —
/// a request the rules read only part of. A clear command ("move my 3pm to
/// Thursday") never reaches a model at all, and the live preview never does.
///
/// **What the model may do.** Name the action when the rules could not, and
/// hand back COPIED phrases — when, who, which meeting, what about — that go
/// through the same Dart resolvers as typed text. Every phrase is checked
/// against the request and dropped when it is not in it, so the model can
/// neither invent a person nor slip in a normalised date. It never computes a
/// time, and a slot the rules already filled is never overwritten — except
/// the subject when the action itself was the model's, since the rules then
/// never read the leftover words as a subject at all. A move's target is
/// always the typed words after the split, so the model's `when` is not
/// merged for a move.
///
/// **A pressed choice** re-plans the parse it answered ([submit]'s
/// `resume`) with every choice pressed so far bound: no classifier, no model
/// call, no second search for a name already settled.

/// What one Enter produced.
@immutable
class CommandOutcome {
  const CommandOutcome({
    required this.plan,
    required this.path,
    this.parsed,
  });

  final CommandPlan plan;

  /// Who read the command in the end: the lexicon, the head, or the model —
  /// the model only when its answer changed the action or filled a slot.
  final CommandPath path;

  /// The parse the plan was made from, after the model's phrases and any
  /// bound choice. Null for a proposal that did not come from typed text (the
  /// asks column's slot pick).
  final ParsedCommand? parsed;
}

const String modelOffSentence = "The model isn't running; try a plainer "
    "phrasing like 'move my 3pm to Thursday'.";

const String unreadableSentence = "I couldn't read that. Try a plainer "
    "phrasing like 'move my 3pm to Thursday'.";

/// The actions whose people are invitees or the subject of the question, so
/// an unknown name is worth a directory search. A move, a cancel or an
/// answer only uses people to pick a meeting, which the mirror answers.
const Set<CommandAction> _peopleActions = {
  CommandAction.create,
  CommandAction.findTime,
  CommandAction.askPerson,
};

class CommandRouter {
  CommandRouter({
    required this.classifiers,
    required this.planner,
    required this.intentClient,
    required this.people,
    ActivityLog? activityLog,
    this.confidenceBar = 0.8,
  }) : _activity = activityLog ?? ActivityLog.disabled();

  /// Asked in order; the first answer that names an action wins. The
  /// decision model's command head first, then the lexicon
  /// (`commandRouterProvider`). A null or an `unknown` is no answer, so a
  /// head under its bar falls through: the head answers only above its bar.
  final List<CommandClassifier> classifiers;
  final CommandPlanner planner;

  /// Resolved at Enter, never held: the stage's client follows Settings
  /// (`stageLlmClientProvider('calendar_intent')`).
  final LlmClient Function() intentClient;

  /// For names the People directory does not know.
  final PeopleBackend people;
  final double confidenceBar;
  final ActivityLog _activity;

  /// The live preview: synchronous, no model, no network — the lexicon and
  /// the resolvers, on every keystroke. [guess] is a head's answer when the
  /// caller has one.
  ParsedCommand preview(
    String text, {
    required DateTime now,
    required CalendarZone zone,
    required List<KnownPerson> people,
    required List<CalendarEvent> events,
    CommandGuess? guess,
  }) =>
      parseCommand(text,
          now: now, zone: zone, people: people, events: events, guess: guess);

  /// Enter. Never throws.
  ///
  /// [binds] are the [NeedsChoice] options pressed so far for this text,
  /// every one of them: each binding wins over whatever the text matched.
  /// [resume] is the outcome the latest press answered; with it the router
  /// re-plans that outcome's parse under [binds] and asks no classifier and
  /// no model again.
  Future<CommandOutcome> submit(
    String text, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
    required List<KnownPerson> people,
    required List<CalendarEvent> events,
    List<CommandBind> binds = const [],
    CommandOutcome? resume,
  }) async {
    final outcome = await _submit(
      text,
      now: now,
      zone: zone,
      today: today,
      known: people,
      events: events,
      binds: binds,
      resume: resume,
    );
    // Counts and enum words only (gotcha 27): never the text, a name or a
    // subject.
    await _activity.record(
      'calendar_command',
      detail: {
        'action': (outcome.parsed?.action ?? CommandAction.unknown).wire,
        'path': outcome.path.name,
        'outcome': outcome.plan.outcomeWord,
      },
    );
    return outcome;
  }

  Future<CommandOutcome> _submit(
    String text, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
    required List<KnownPerson> known,
    required List<CalendarEvent> events,
    required List<CommandBind> binds,
    required CommandOutcome? resume,
  }) async {
    // An outcome with no parse (a slot picked in the asks column) has
    // nothing to resume; the text is read afresh.
    final resumed = resume?.parsed;
    if (resume != null && resumed != null) {
      final p = _bind(resumed, binds, now: now, zone: zone, events: events);
      return _finish(p, path: resume.path, now: now, zone: zone, today: today);
    }

    final guess = await _classify(text);
    var p = parseCommand(text,
        now: now, zone: zone, people: known, events: events, guess: guess);
    p = _bind(p, binds, now: now, zone: zone, events: events);
    var path = guess.path;

    final ask = guess.confidence < confidenceBar ||
        (p.unresolved.isNotEmpty && p.leftoverAfterResolvers);
    if (ask) {
      try {
        final intent = await runTask(
          intentClient(),
          const CalendarIntentTask(),
          CalendarIntentInput.at(text, now: now, zone: zone),
          temperature: CalendarIntentTask.temperature,
          maxTokens: CalendarIntentTask.maxTokens,
        );
        final (merged, contributed) = _merge(p, intent,
            known: known, now: now, zone: zone, events: events);
        p = _bind(merged, binds, now: now, zone: zone, events: events);
        // Asked is not the same as read: an answer that changed nothing
        // leaves the rules as the reader of record.
        if (contributed) path = CommandPath.generative;
      } on LlmUnavailableException {
        if (_stuck(p)) {
          return CommandOutcome(
              plan: const CannotDo(modelOffSentence), path: path, parsed: p);
        }
      } on Object catch (e) {
        // A malformed answer or a transport hiccup: the local parse stands.
        debugPrint('calendar command: the intent call failed: '
            '${e.runtimeType}');
        if (_stuck(p)) {
          return CommandOutcome(
              plan: const CannotDo(unreadableSentence), path: path, parsed: p);
        }
      }
    }

    return _finish(p, path: path, now: now, zone: zone, today: today);
  }

  /// The directory look-up for names nobody in the mail has, then the plan.
  Future<CommandOutcome> _finish(
    ParsedCommand parsed, {
    required CommandPath path,
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    var p = parsed;
    if (p.action == CommandAction.unknown) {
      return CommandOutcome(
          plan: const CannotDo(didntCatchSentence), path: path, parsed: p);
    }

    // Names nobody in the mail has: the organisation's directory, one
    // search per name (at most three), before anything is planned on them.
    if (_peopleActions.contains(p.action) && p.people.unresolved.isNotEmpty) {
      final found = await _lookUp(p);
      // The parse as far as the look-up got, so a press on its question
      // resumes from there rather than searching again.
      p = found.parsed;
      if (found.stop != null) {
        return CommandOutcome(plan: found.stop!, path: path, parsed: p);
      }
    }

    final plan = await planner.plan(p, now: now, zone: zone, today: today);
    return CommandOutcome(plan: plan, path: path, parsed: p);
  }

  /// A parse the planner cannot act on without the model: no action, or a
  /// slot missing with words left that might have filled it.
  bool _stuck(ParsedCommand p) =>
      p.action == CommandAction.unknown ||
      (p.unresolved.isNotEmpty && p.leftoverAfterResolvers);

  Future<CommandGuess> _classify(String text) async {
    for (final c in classifiers) {
      try {
        final g = await c.classify(text);
        if (g != null && g.action != CommandAction.unknown) return g;
      } on Object catch (e) {
        // A classifier that throws (a head whose server went away) is one
        // that did not answer.
        debugPrint('calendar command: a classifier failed: ${e.runtimeType}');
      }
    }
    return classifyByLexicon(text);
  }

  /// The pressed choices laid over the parse: each bound person joins the
  /// matched, and settles the ambiguity or the unknown name it answered; the
  /// latest bound event is the only candidate.
  ParsedCommand _bind(
    ParsedCommand p,
    List<CommandBind> binds, {
    required DateTime now,
    required CalendarZone zone,
    required List<CalendarEvent> events,
  }) {
    final boundPeople = <KnownPerson>[
      for (final b in binds)
        if (b.person != null) b.person!,
    ];
    CalendarEvent? boundEvent;
    for (final b in binds) {
      if (b.event != null) boundEvent = b.event;
    }
    if (boundPeople.isEmpty && boundEvent == null) return p;
    var match = p.people;
    if (boundPeople.isNotEmpty) {
      final bound = {for (final b in boundPeople) b.address};
      // A directory choice names the name it answers; a choice without one
      // (the planner's "Which Dana?") settles a name its person carries.
      bool settles(String name, CommandBind b) {
        final person = b.person;
        if (person == null) return false;
        final n = name.trim().toLowerCase();
        final said = b.answers;
        if (said != null) return said.trim().toLowerCase() == n;
        final words = person.name.toLowerCase().split(RegExp(r'\s+'));
        return n == person.name.trim().toLowerCase() ||
            words.contains(n) ||
            n.split(RegExp(r'\s+')).every(words.contains) ||
            n == person.address ||
            n == person.address.split('@').first;
      }

      match = PeopleMatch(
        matched: [
          for (final m in match.matched)
            if (!bound.contains(m.address)) m,
          ...boundPeople,
        ],
        ambiguous: [
          for (final list in match.ambiguous)
            if (!list.any((k) => bound.contains(k.address))) list,
        ],
        unresolved: [
          for (final name in match.unresolved)
            if (!binds.any((b) => settles(name, b))) name,
        ],
        spans: match.spans,
      );
    }
    final bound = p.copyWith(
      people: match,
      events: boundEvent == null ? null : [EventCandidate(boundEvent, 99)],
    );
    return settleCommand(bound,
        now: now, zone: zone, events: events, rematch: boundEvent == null);
  }

  /// The model's copied phrases, merged into what the rules found. A slot
  /// the rules filled keeps its value; a phrase not in the request is
  /// dropped. The flag says whether the answer changed anything at all.
  (ParsedCommand, bool) _merge(
    ParsedCommand p,
    CalendarIntent intent, {
    required List<KnownPerson> known,
    required DateTime now,
    required CalendarZone zone,
    required List<CalendarEvent> events,
  }) {
    final text = p.text;
    String? copied(String phrase) {
      final t = phrase.trim();
      if (t.isEmpty) return null;
      return _findPhrase(text, t) == null ? null : t;
    }

    // The action: the model's, when the rules had none or a weak one.
    var guess = p.guess;
    var contributed = false;
    final ruled = guess.action != CommandAction.unknown &&
        guess.confidence >= confidenceBar;
    if (!ruled &&
        intent.action != CommandAction.unknown &&
        intent.action != guess.action) {
      guess = CommandGuess(intent.action, confidenceBar, CommandPath.generative);
      contributed = true;
    }
    // A changed action changes the parse (the when mode, the move split),
    // so the text is read again under it before the phrases are laid on.
    var out = guess == p.guess
        ? p
        : parseCommand(text,
            now: now, zone: zone, people: known, events: events, guess: guess);

    // When: only if the rules found none, through the same resolver. Never
    // for a move: its target is the typed words after the split
    // (`ParsedCommand.targetText`), which the planner reads, so a merged
    // `when` would be drawn and never used.
    final whenPhrase = copied(intent.when);
    if (whenPhrase != null &&
        guess.action != CommandAction.move &&
        out.when.day == null &&
        out.when.time == null &&
        out.when.part == null) {
      final (at, end) = _findPhrase(text, whenPhrase)!;
      final r = _shift(
          resolveWhen(text.substring(at, end),
              now: now, zone: zone, mode: guess.mode),
          at);
      if (!r.isEmpty) {
        out = out.copyWith(
          when: r,
          eventWhen: r,
          duration: out.duration ?? r.duration,
        );
        contributed = true;
      }
    }

    // People: each copied name through the directory match; one that
    // matches nobody is a name to look up.
    if (out.people.matched.isEmpty && out.people.ambiguous.isEmpty) {
      final matched = <KnownPerson>[];
      final ambiguous = <List<KnownPerson>>[];
      final unresolved = <String>[...out.people.unresolved];
      for (final raw in intent.people) {
        final name = copied(raw);
        if (name == null) continue;
        final m = matchPeople('with $name', known);
        if (m.matched.isNotEmpty) {
          for (final k in m.matched) {
            if (!matched.contains(k)) matched.add(k);
          }
        } else if (m.ambiguous.isNotEmpty) {
          ambiguous.addAll(m.ambiguous);
        } else if (!unresolved.contains(name)) {
          unresolved.add(name);
        }
      }
      if (matched.isNotEmpty ||
          ambiguous.isNotEmpty ||
          unresolved.length != out.people.unresolved.length) {
        contributed = true;
      }
      out = out.copyWith(
        people: PeopleMatch(
          matched: matched,
          ambiguous: ambiguous,
          unresolved: unresolved,
          spans: out.people.spans,
        ),
      );
    }

    // Subject: when the rules left none, or when the action is the
    // model's — then the rules never read the leftover words as a subject,
    // they only failed to read them at all. The meeting reference feeds the
    // event match the same way.
    final subject = copied(intent.subject);
    final modelsAction = guess.path == CommandPath.generative;
    if (subject != null &&
        !out.quotedSubject &&
        (out.subject.trim().isEmpty || modelsAction) &&
        subject != out.subject.trim()) {
      out = out.copyWith(subject: subject);
      contributed = true;
    }
    final ref = copied(intent.eventRef);
    if (ref != null && out.events.isEmpty && out.action.needsEvent) {
      final refWhen = resolveWhen(ref, now: now, zone: zone, mode: guess.mode);
      out = out.copyWith(
        subject: out.subject.trim().isEmpty ? ref : '${out.subject} $ref',
        eventWhen: refWhen.isEmpty ? null : refWhen,
      );
      contributed = true;
    }

    // Length: a phrase copied from the request that the duration rules
    // read, never a number the model worked out.
    final lengthPhrase = copied(intent.duration);
    final length = lengthPhrase == null ? null : parseDuration(lengthPhrase);
    if (out.duration == null &&
        length != null &&
        length.inMinutes >= CalendarIntentTask.minDuration &&
        length.inMinutes <= CalendarIntentTask.maxDuration) {
      out = out.copyWith(duration: length);
      contributed = true;
    }
    return (
      settleCommand(out, now: now, zone: zone, events: events),
      contributed,
    );
  }

  /// Looks each unknown name up in the directory: one person with a mailbox
  /// binds, several ask (each option naming the name it answers), none
  /// gives the words back to a create's subject and leaves the name
  /// unresolved for a find-a-time or a question, whose planner says so.
  ///
  /// The parse that comes back carries every name settled so far, even
  /// when a question stops the walk, so a press resumes from there.
  Future<({ParsedCommand parsed, CommandPlan? stop})> _lookUp(
    ParsedCommand p,
  ) async {
    final matched = [...p.people.matched];
    final settled = <String>{};
    final nobody = <String>[];
    ParsedCommand sofar() => p.copyWith(
          people: PeopleMatch(
            matched: matched,
            ambiguous: p.people.ambiguous,
            unresolved: [
              for (final n in p.people.unresolved)
                if (!settled.contains(n) && !nobody.contains(n)) n,
              ...nobody,
            ],
            spans: p.people.spans,
          ),
        );
    for (final name in p.people.unresolved.take(3)) {
      List<Person> hits;
      try {
        hits = await people.searchPeople(name, top: 5);
      } on Object catch (e) {
        debugPrint('calendar command: directory search failed: '
            '${e.runtimeType}');
        return (
          parsed: sofar(),
          stop: CannotDo("Couldn't search the directory for $name."),
        );
      }
      final byAddress = <String, KnownPerson>{};
      for (final h in hits) {
        final address = directoryAddress(h);
        if (address == null) continue;
        byAddress.putIfAbsent(
            address, () => KnownPerson(name: h.displayName, address: address));
      }
      final found = byAddress.values.toList();
      if (found.isEmpty) {
        nobody.add(name);
        continue;
      }
      if (found.length > 1) {
        return (
          parsed: sofar(),
          stop: NeedsChoice('Which $name?', [
            for (final k in found)
              CommandOption(
                label: '${k.name} · ${k.address}',
                bind: (person: k, event: null, answers: name),
              ),
          ]),
        );
      }
      if (!matched.contains(found.single)) matched.add(found.single);
      settled.add(name);
    }

    var out = sofar();
    // A create whose "invitee" nobody has: the words were the subject all
    // along ("lunch with Design team"). A quoted subject is the person's
    // own title, so there the name stays unresolved and the planner says
    // so rather than dropping an invitee quietly.
    if (nobody.isNotEmpty &&
        out.action == CommandAction.create &&
        !out.quotedSubject) {
      out = out.copyWith(
        subject: subjectRestoring(out, nobody),
        people: PeopleMatch(
          matched: out.people.matched,
          ambiguous: out.people.ambiguous,
          unresolved: [
            for (final n in out.people.unresolved)
              if (!nobody.contains(n)) n,
          ],
          spans: [
            for (final s in out.people.spans)
              if (!nobody.any((n) => p.text.substring(s.$1, s.$2) == n)) s,
          ],
        ),
      );
    }
    return (parsed: out, stop: null);
  }
}

/// The address a directory hit can be invited at: its `mail`, else a
/// user principal name that is an address and not a guest's `#EXT#`
/// placeholder (which no invite reaches); null when it has neither, and
/// such a hit cannot be bound.
String? directoryAddress(Person h) {
  final mail = (h.mail ?? '').trim().toLowerCase();
  if (mail.contains('@')) return mail;
  final upn = (h.userPrincipalName ?? '').trim().toLowerCase();
  if (upn.contains('@') && !upn.contains('#ext#')) return upn;
  return null;
}

/// Where [phrase] sits in [text] as `[start, end)`, ignoring case and runs
/// of whitespace, and only as whole words — "Dan" is not in "Danielle" —
/// or null when it is not there. The check that keeps a model to copying.
(int, int)? _findPhrase(String text, String phrase) {
  final words = phrase.trim().split(RegExp(r'\s+')).map(RegExp.escape);
  final m = RegExp(
    '(?<![\\p{L}\\p{N}])${words.join(r'\s+')}(?![\\p{L}\\p{N}])',
    caseSensitive: false,
    unicode: true,
  ).firstMatch(text);
  return m == null ? null : (m.start, m.end);
}

/// [r] with its spans moved [by] characters: a phrase resolved on its own
/// reports offsets into itself, and the bar highlights spans in the text.
WhenResolution _shift(WhenResolution r, int by) => WhenResolution(
      today: r.today,
      zone: r.zone,
      spans: [for (final s in r.spans) WhenSpan(s.start + by, s.end + by, s.kind)],
      day: r.day,
      rangeEnd: r.rangeEnd,
      time: r.time,
      endTime: r.endTime,
      part: r.part,
      duration: r.duration,
      explicitTime: r.explicitTime,
      unresolvedReason: r.unresolvedReason,
    );
