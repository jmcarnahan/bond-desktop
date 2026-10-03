import 'package:flutter/foundation.dart' show immutable;

import '../../../models/calendar_models.dart';
import '../../../models/message_models.dart' show Participant;
import '../when_resolver.dart';

/// The shared vocabulary of the Day command bar (plan §1.1,
/// docs/pipeline/14-calendar.md "Commands").
///
/// A calendar command is short text over FINITE, KNOWN sets — ten actions, a
/// time grammar, the people in the owner's mail, the meetings in the mirror —
/// so reading one is mostly lookup. These types carry what each lookup found
/// from the lexicon, the resolvers and the matchers to the planner and the
/// router, and on to the bar that draws the preview chips.

/// What the person asked the calendar to do. The wire words
/// ([CommandActionWire.wire]) are the `calendar_intent` schema's enum and the
/// activity row's `action`.
enum CommandAction {
  create,
  move,
  cancel,
  rsvpYes,
  rsvpNo,
  rsvpMaybe,
  findTime,
  askFree,
  askAgenda,
  askPerson,
  unknown,
}

extension CommandActionWire on CommandAction {
  /// The snake_case word the model and the activity log use.
  String get wire => switch (this) {
        CommandAction.create => 'create',
        CommandAction.move => 'move',
        CommandAction.cancel => 'cancel',
        CommandAction.rsvpYes => 'rsvp_yes',
        CommandAction.rsvpNo => 'rsvp_no',
        CommandAction.rsvpMaybe => 'rsvp_maybe',
        CommandAction.findTime => 'find_time',
        CommandAction.askFree => 'ask_free',
        CommandAction.askAgenda => 'ask_agenda',
        CommandAction.askPerson => 'ask_person',
        CommandAction.unknown => 'unknown',
      };

  /// [raw] read back; anything that is not one of the eleven words is
  /// [CommandAction.unknown], because a model's answer is a shape the grammar
  /// promised and nothing more.
  static CommandAction parse(String raw) {
    final w = raw.trim().toLowerCase();
    for (final a in CommandAction.values) {
      if (a.wire == w) return a;
    }
    return CommandAction.unknown;
  }

  /// A question about the calendar rather than a change to it. It decides the
  /// resolver's [WhenMode]: "am I free Wednesday?" on a Wednesday means today,
  /// "book Wednesday" means next week's.
  bool get isQuestion =>
      this == CommandAction.askFree ||
      this == CommandAction.askAgenda ||
      this == CommandAction.askPerson;

  /// The actions that act on one existing meeting, so need an event.
  bool get needsEvent =>
      this == CommandAction.move ||
      this == CommandAction.cancel ||
      this == CommandAction.rsvpYes ||
      this == CommandAction.rsvpNo ||
      this == CommandAction.rsvpMaybe;

  bool get isRsvp =>
      this == CommandAction.rsvpYes ||
      this == CommandAction.rsvpNo ||
      this == CommandAction.rsvpMaybe;
}

/// Which reader named the action: the lexicon's rules, the decision model's
/// command head (Phase 9), or the generative model on Enter.
enum CommandPath { lexicon, head, generative }

/// One classifier's answer: the action and how sure it is.
@immutable
class CommandGuess {
  final CommandAction action;

  /// 0..1. The router asks the generative model below its bar (0.8).
  final double confidence;
  final CommandPath path;

  const CommandGuess(this.action, this.confidence, this.path);

  static const CommandGuess none =
      CommandGuess(CommandAction.unknown, 0, CommandPath.lexicon);

  /// Question for the three asks, booking otherwise — derived rather than
  /// stored, so a guess can never carry a mode that disagrees with its
  /// action.
  WhenMode get mode => action.isQuestion ? WhenMode.question : WhenMode.booking;

  @override
  bool operator ==(Object other) =>
      other is CommandGuess &&
      other.action == action &&
      other.confidence == confidence &&
      other.path == path;

  @override
  int get hashCode => Object.hash(action, confidence, path);

  @override
  String toString() =>
      'CommandGuess(${action.wire}, $confidence, ${path.name})';
}

/// Something that can name the action of a command: the decision model's
/// command head (`DecisionCommandClassifier`), then the lexicon. A classifier
/// that cannot answer (a head that is not loaded) returns null, and one that
/// is unsure returns `unknown`; either way the router asks the next one.
abstract interface class CommandClassifier {
  Future<CommandGuess?> classify(String text);
}

/// The slots a command fills. [CommandSlot.action] is unresolved when no
/// classifier named one; the others by the per-action rules in
/// `command_parser.dart`.
enum CommandSlot { action, when, people, event, subject, duration }

/// One person the owner has mail with, as the People directory knows them.
@immutable
class KnownPerson {
  /// The best display name the directory had; `''` when it had none, in
  /// which case only the address matches.
  final String name;

  /// Lowercased.
  final String address;

  /// The People room this person heads (`PersonRoom.key`), so a chip can
  /// open it; `''` for a person found by a directory search.
  final String roomKey;

  const KnownPerson({
    required this.name,
    required this.address,
    this.roomKey = '',
  });

  /// The first word of [name], or `''`.
  String get firstName {
    final words = name.trim().split(RegExp(r'\s+'));
    return words.isEmpty ? '' : words.first;
  }

  @override
  bool operator ==(Object other) =>
      other is KnownPerson &&
      other.name == name &&
      other.address == address &&
      other.roomKey == roomKey;

  @override
  int get hashCode => Object.hash(name, address, roomKey);

  @override
  String toString() => 'KnownPerson($name, $address)';
}

/// One People room as the matcher needs it: its key and its people. A record
/// rather than `PersonRoom` itself because that class lives in `widgets/`,
/// which `services/` never imports; `knownPeopleOfRooms` in
/// `people_rooms.dart` is the one-line adapter the screen calls.
typedef KnownRoom = ({String key, List<Participant> people});

/// The directory's people, one per ADDRESS with the best name any room gave
/// them.
///
/// People with no mailbox address are skipped: a Teams roster entry is
/// `teams:<id>`, which no invite can be sent to and no attendee list will
/// ever name, so matching "Dana" to it would build a command the calendar
/// cannot carry out. The best name is the one with the most words (a full
/// name beats a first name beats none), then the longest, then the first
/// seen — so a room titled by an address does not hide the name another
/// room knew.
List<KnownPerson> knownPeopleFrom(Iterable<KnownRoom> rooms) {
  final byAddress = <String, KnownPerson>{};
  int words(String n) =>
      n.trim().isEmpty ? 0 : n.trim().split(RegExp(r'\s+')).length;
  for (final room in rooms) {
    for (final p in room.people) {
      final address = (p.email ?? '').trim().toLowerCase();
      if (!_mailbox.hasMatch(address)) continue;
      var name = (p.name ?? '').trim();
      // A "name" that is only the address again is no name at all.
      if (name.toLowerCase() == address) name = '';
      final seen = byAddress[address];
      if (seen == null) {
        byAddress[address] =
            KnownPerson(name: name, address: address, roomKey: room.key);
        continue;
      }
      final better = words(name) > words(seen.name) ||
          (words(name) == words(seen.name) &&
              name.length > seen.name.length);
      if (better) {
        byAddress[address] =
            KnownPerson(name: name, address: address, roomKey: seen.roomKey);
      }
    }
  }
  return List.unmodifiable(byAddress.values);
}

final RegExp _mailbox = RegExp(r'^[^\s@:]+@[^\s@]+\.[^\s@]+$');

/// What [matchPeople] found in a command.
@immutable
class PeopleMatch {
  /// Every person named exactly: a full name, a unique first name, an
  /// address. De-duplicated, in text order.
  final List<KnownPerson> matched;

  /// One list per token that names several people ("Dana" when there are
  /// two Danas). The planner asks which.
  final List<List<KnownPerson>> ambiguous;

  /// Capitalised names that matched nobody ("with Priya" when no Priya is in
  /// the mail). The router looks them up in the directory on Enter.
  final List<String> unresolved;

  /// The character ranges `[start, end)` every hit above consumed, so the
  /// parser can take the leftover words as the subject.
  final List<(int, int)> spans;

  const PeopleMatch({
    this.matched = const [],
    this.ambiguous = const [],
    this.unresolved = const [],
    this.spans = const [],
  });

  static const PeopleMatch empty = PeopleMatch();

  bool get isEmpty =>
      matched.isEmpty && ambiguous.isEmpty && unresolved.isEmpty;

  @override
  String toString() => 'PeopleMatch(matched: $matched, '
      'ambiguous: $ambiguous, unresolved: $unresolved)';
}

/// One meeting the command may mean, and how well it matched.
@immutable
class EventCandidate {
  final CalendarEvent event;
  final double score;

  const EventCandidate(this.event, this.score);

  @override
  String toString() => 'EventCandidate(${event.id}, $score)';
}

/// Everything the synchronous parse read out of one command.
@immutable
class ParsedCommand {
  final String text;
  final CommandGuess guess;

  /// The whole text through the resolver. Its spans are what the subject is
  /// taken around; for a move its day and time are the TARGET's by the
  /// resolver's last-mention rule.
  final WhenResolution when;

  /// The when that says WHICH meeting: for a move, the words before the
  /// target ("my 3pm" in "move my 3pm to Thursday"); for everything else the
  /// same as [when].
  final WhenResolution eventWhen;

  /// Where a move's target begins in [text] (0 when the whole text is the
  /// target, [text]'s length when there is none). Only a move reads it.
  final int targetStart;

  final Duration? duration;
  final PeopleMatch people;

  /// Best first; a tie at the top is the planner's cue to ask.
  final List<EventCandidate> events;

  /// The leftover words (or the quoted text, verbatim), trimmed.
  final String subject;

  /// Whether [subject] came from quotes, and so is the person's own words.
  final bool quotedSubject;

  /// The non-filler words no resolver consumed, in text order (quoted text
  /// excluded). For a create they are the subject.
  final List<String> leftoverWords;

  final Set<CommandSlot> unresolved;

  /// Words remain that no resolver explained AND a required slot is
  /// unresolved: a compound request the lexicon cannot finish, which is one
  /// of the two reasons the router asks the model.
  final bool leftoverAfterResolvers;

  const ParsedCommand({
    required this.text,
    required this.guess,
    required this.when,
    required this.eventWhen,
    this.targetStart = 0,
    this.duration,
    this.people = PeopleMatch.empty,
    this.events = const [],
    this.subject = '',
    this.quotedSubject = false,
    this.leftoverWords = const [],
    this.unresolved = const {},
    this.leftoverAfterResolvers = false,
  });

  CommandAction get action => guess.action;

  /// A move's target words: what [targetStart] marks off.
  String get targetText =>
      targetStart >= text.length ? '' : text.substring(targetStart);

  ParsedCommand copyWith({
    CommandGuess? guess,
    WhenResolution? when,
    WhenResolution? eventWhen,
    int? targetStart,
    Duration? duration,
    PeopleMatch? people,
    List<EventCandidate>? events,
    String? subject,
    bool? quotedSubject,
    List<String>? leftoverWords,
    Set<CommandSlot>? unresolved,
    bool? leftoverAfterResolvers,
  }) =>
      ParsedCommand(
        text: text,
        guess: guess ?? this.guess,
        when: when ?? this.when,
        eventWhen: eventWhen ?? this.eventWhen,
        targetStart: targetStart ?? this.targetStart,
        duration: duration ?? this.duration,
        people: people ?? this.people,
        events: events ?? this.events,
        subject: subject ?? this.subject,
        quotedSubject: quotedSubject ?? this.quotedSubject,
        leftoverWords: leftoverWords ?? this.leftoverWords,
        unresolved: unresolved ?? this.unresolved,
        leftoverAfterResolvers:
            leftoverAfterResolvers ?? this.leftoverAfterResolvers,
      );

  @override
  String toString() => 'ParsedCommand(${guess.action.wire}, when: $when, '
      'people: $people, events: $events, subject: "$subject", '
      'unresolved: $unresolved, leftover: $leftoverAfterResolvers)';
}
