import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../../../data/calendar_store.dart';
import '../../../models/calendar_models.dart';
import '../../backend/calendar_backend.dart';
import '../../backend/calendar_errors.dart';
import '../calendar_writes.dart';
import '../calendar_zone.dart';
import '../day_items.dart' show formatEventRange, formatEventTime, shortDate;
import '../event_view.dart' show lastMetLabel, nextMeetingLabel;
import '../overlaps.dart';
import '../when_resolver.dart';
import '../write_rules.dart';
import 'command_types.dart';
import 'event_matcher.dart';

/// Turns a parsed command into ONE thing the bar can show: a write to
/// confirm, times to pick from, an answer, a question, or a sentence saying
/// why not (docs/pipeline/14-calendar.md "Commands").
///
/// **It never invents a time.** A create or a move with no clock time is a
/// [SlotChoice] of real openings — the person's own free slots, or the
/// organisation's `find_meeting_times` when other people must be free too —
/// never 9:00 because 9:00 is when mornings start. A time with no day is
/// today's; a day with no time keeps a moved meeting's wall time
/// ([resolveNewTime]); a part of the day is a window to offer openings in.
///
/// **Every write goes through the dry run** ([CalendarWriter.preview]) before
/// it is offered, so the proposal already says who it would email and
/// whether it needs a confirm (gotcha 49), exactly as the Day stop's own
/// buttons do. Nothing here commits; the bar does, on the person's press.

/// What the planner decided.
sealed class CommandPlan {
  const CommandPlan();

  /// The activity row's `outcome` word.
  String get outcomeWord;
}

/// A write, dry-run, ready to confirm.
final class CalendarProposal extends CommandPlan {
  const CalendarProposal({
    required this.write,
    required this.preview,
    required this.summary,
    required this.doneMessage,
    required this.needsConfirm,
    this.startUtc,
    this.endUtc,
    this.overlaps,
    this.targetEvent,
    this.notifies = const [],
    this.series = false,
  });

  final CalendarWrite write;

  /// The dry run, which the commit takes back (`commit(write, preview:)`):
  /// no preview, no Undo.
  final WritePreview preview;

  /// The confirm line (`writeSummary`), plus a lead-in when the command
  /// could not be done as asked ("you can't cancel it, but you can decline").
  final String summary;

  /// The toast after the write (`writeDoneMessage`).
  final String doneMessage;

  /// Where a create or a timed move LANDS — the grid's ghost tile. Null for
  /// an answer, a cancel, a delete and an all-day move.
  final DateTime? startUtc;
  final DateTime? endUtc;

  /// What the landing slot runs into, for a create or a timed move.
  final Overlaps? overlaps;

  /// The meeting written to; null for a create.
  final CalendarEvent? targetEvent;

  /// Who the write emails, as the dry run said.
  final List<String> notifies;
  final bool needsConfirm;

  /// The write answers, cancels or deletes every meeting in a series.
  final bool series;

  @override
  String get outcomeWord => 'proposal';
}

/// Up to three real openings to pick from.
final class SlotChoice extends CommandPlan {
  const SlotChoice({
    required this.slots,
    required this.buildWrite,
    required this.title,
    required this.source,
    this.targetEvent,
  });

  final List<FreeSlot> slots;

  /// The write a press makes; hand it to [CommandPlanner.propose] for its
  /// dry run.
  final CalendarWrite Function(FreeSlot slot) buildWrite;

  /// 'Pick a time for "Design sync" with Dana'.
  final String title;

  /// `local` (the person's own free slots, read from the mirror) or `graph`
  /// (`find_meeting_times`, everyone's).
  final String source;

  /// The meeting being moved, for a move; null for a create.
  final CalendarEvent? targetEvent;

  @override
  String get outcomeWord => 'slots';
}

/// One event an [Answer] mentions, so its line can open it.
typedef AnswerLink = ({String label, String eventId});

/// A question answered: free time, the agenda, next or last met.
final class Answer extends CommandPlan {
  const Answer(this.text, {this.links = const []});

  final String text;
  final List<AnswerLink> links;

  @override
  String get outcomeWord => 'answer';
}

/// What pressing a [CommandOption] settles: a person, a meeting, and —
/// for a person found by a directory search — the unresolved NAME they
/// answer, so the bind settles exactly that name even when the person's
/// display name does not contain it ("Bob" → Robert Smith).
typedef CommandBind = ({
  KnownPerson? person,
  CalendarEvent? event,
  String? answers,
});

/// One button of a [NeedsChoice].
@immutable
class CommandOption {
  const CommandOption({required this.label, required this.bind});

  final String label;
  final CommandBind bind;
}

/// The command named something twice over — two Danas, two 3pm meetings —
/// and a press decides. The host re-plans the same parse with every choice
/// pressed so far bound (`CommandRouter.submit(binds:, resume:)`), with no
/// second model call.
final class NeedsChoice extends CommandPlan {
  const NeedsChoice(this.question, this.options);

  final String question;
  final List<CommandOption> options;

  @override
  String get outcomeWord => 'choice';
}

/// Why the command cannot be done, in a sentence that says what to type
/// instead where it can.
final class CannotDo extends CommandPlan {
  const CannotDo(this.reason);

  final String reason;

  @override
  String get outcomeWord => 'cannot';
}

const String didntCatchSentence = "I didn't catch what to do. Try 'move my "
    "3pm to Thursday' or 'what's on tomorrow'.";

const String whoWithSentence = 'Who with? Name someone from your mail.';

/// A move whose words say no day, time, part of day or shift.
const String sayWhenSentence =
    "Say when it moves to — e.g. 'to 4pm' or 'by an hour'.";

/// A move to a bare hour ("to 4"): no guess at which 4.
const String addAmPmSentence = "Add am or pm — e.g. 'to 4pm'.";

/// A name nobody in the mail or the directory has, for a question about
/// them or a time with them.
String unknownPersonSentence(String name) =>
    "I don't know who $name is — name someone from your mail.";

const String noCommonTimeSentence =
    'No time when everyone is free in that window.';

/// The default length of a meeting nobody gave a length for.
const Duration defaultMeetingLength = Duration(minutes: 30);

DateTime _utc(DateTime t) =>
    DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

/// "Dana Whitfield", "Dana Whitfield and Lee Park", "Dana, Lee and Priya".
String peopleNames(List<KnownPerson> people) {
  final names = [
    for (final p in people) p.name.trim().isEmpty ? p.address : p.name.trim(),
  ];
  if (names.length <= 1) return names.join();
  if (names.length == 2) return '${names[0]} and ${names[1]}';
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

class CommandPlanner {
  CommandPlanner({
    required this.calendar,
    required this.backend,
    required this.writer,
    required this.mailbox,
  });

  /// The mirror: a day's events, next and last met.
  final CalendarStore calendar;

  /// For `find_meeting_times` only; writes go through [writer].
  final CalendarBackend backend;
  final CalendarWriter writer;

  /// The cached mailbox settings (working hours and days), or null.
  final Future<MailboxSettings?> Function() mailbox;

  /// The one plan for [p]. Never throws: a store, backend or dry-run failure
  /// is a [CannotDo] with the sentence the Day stop would have shown.
  Future<CommandPlan> plan(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    try {
      return await _plan(p, now: now.toUtc(), zone: zone, today: today);
    } on Object catch (e) {
      // The type only: a message can carry an endpoint.
      debugPrint('calendar command: planning failed: ${e.runtimeType}');
      return const CannotDo("Couldn't read the calendar. Nothing was changed.");
    }
  }

  Future<CommandPlan> _plan(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final action = p.action;
    if (action == CommandAction.unknown) return const CannotDo(didntCatchSentence);

    // Two people behind one name: ask before anything is built on either.
    // A command about one meeting skips this — its people only score
    // candidates, and a tie between those is asked about below instead.
    final ambiguous = p.people.ambiguous;
    if (ambiguous.isNotEmpty && !action.needsEvent) {
      final first = ambiguous.first;
      final who = first.first.firstName.isEmpty
          ? 'one'
          : first.first.firstName;
      return NeedsChoice('Which $who?', [
        for (final person in first)
          CommandOption(
            label: person.name.trim().isEmpty
                ? person.address
                : '${person.name.trim()} · ${person.address}',
            bind: (person: person, event: null, answers: null),
          ),
      ]);
    }

    switch (action) {
      case CommandAction.create:
        return _create(p, now: now, zone: zone, today: today);
      case CommandAction.move:
        return _move(p, now: now, zone: zone, today: today);
      case CommandAction.cancel:
        return _cancel(p, now: now, zone: zone, today: today);
      case CommandAction.rsvpYes:
      case CommandAction.rsvpNo:
      case CommandAction.rsvpMaybe:
        return _rsvp(p, now: now, zone: zone, today: today);
      case CommandAction.findTime:
        return _findTime(p, now: now, zone: zone, today: today);
      case CommandAction.askFree:
        return _askFree(p, now: now, zone: zone, today: today);
      case CommandAction.askAgenda:
        return _askAgenda(p, now: now, zone: zone, today: today);
      case CommandAction.askPerson:
        return _askPerson(p, now: now, zone: zone, today: today);
      case CommandAction.unknown:
        return const CannotDo(didntCatchSentence);
    }
  }

  // ── writes ─────────────────────────────────────────────────────────────

  /// [write]'s dry run as a proposal: the bar calls this for a pressed
  /// [SlotChoice] slot, and the planner for every write it builds itself.
  ///
  /// [target] is the meeting written to (null for a create); [series] says
  /// the write reaches every meeting in a series; [lead] is a sentence put
  /// before the confirm line.
  Future<CommandPlan> propose(
    CalendarWrite write, {
    CalendarEvent? target,
    bool series = false,
    String lead = '',
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final result = await writer.preview(write);
    switch (result) {
      case PreviewFailed(:final message):
        return CannotDo(message);
      case PreviewReady(:final preview, :final needsConfirm):
        final shown = target ?? const CalendarEvent(id: '');
        final line = writeSummary(write,
            shown: shown, series: series, zone: zone, today: today);
        DateTime? start;
        DateTime? end;
        switch (write) {
          case CreateEvent():
            start = write.startUtc;
            end = write.endUtc;
          case MoveEvent(:final startUtc?, :final endUtc?):
            start = startUtc;
            end = endUtc;
          default:
            break;
        }
        Overlaps? overlaps;
        if (start != null && end != null) {
          final around = await _eventsOn(
              zone.dateOf(start), zone.dateOf(end), zone);
          overlaps = findOverlaps(around, start, end,
              ignoreEventId: target?.id, zone: zone);
        }
        return CalendarProposal(
          write: write,
          preview: preview,
          summary: lead.isEmpty ? line : '$lead $line',
          doneMessage: writeDoneMessage(write,
              shown: target, series: series, zone: zone),
          needsConfirm: needsConfirm,
          startUtc: start,
          endUtc: end,
          overlaps: overlaps,
          targetEvent: target,
          notifies: preview.notifies,
          series: series,
        );
    }
  }

  Future<CommandPlan> _create(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    // A name still unknown here is one the router could not give back to
    // the subject (a quoted title) or did not reach (past its third search):
    // an invite never goes out a guest short without saying so.
    if (p.people.unresolved.isNotEmpty) {
      return CannotDo(unknownPersonSentence(p.people.unresolved.first));
    }
    final w = p.when;
    final reason = w.unresolvedReason;
    if (reason != null) return CannotDo(reason);
    final length = p.duration ?? defaultMeetingLength;
    final attendees = [for (final m in p.people.matched) m.address];
    final subject = p.subject.trim().isNotEmpty
        ? p.subject.trim()
        : attendees.isEmpty
            ? 'Meeting'
            : 'Meeting with ${peopleNames(p.people.matched)}';

    CalendarWrite build(DateTime start, DateTime end) => CreateEvent.propose(
          subject: subject,
          startUtc: start,
          endUtc: end,
          attendees: attendees,
          isOnlineMeeting: attendees.isNotEmpty,
        );

    final time = w.time;
    if (time != null && w.rangeEnd == null) {
      // A time with no day is today's: anchoring, not inventing — the
      // person named the time, and "at 3" said now means this afternoon.
      final day = w.day ?? today;
      final (start, end) = WhenResolution(
        today: w.today,
        zone: zone,
        day: day,
        time: time,
        endTime: w.endTime,
        duration: length,
        explicitTime: true,
      ).windowUtc!;
      if (start.isBefore(now)) {
        return CannotDo(w.day == null
            ? '${formatEventTime(zone, start)} has passed today — say which '
                'day.'
            : 'That time has passed.');
      }
      return propose(build(start, end), zone: zone, today: today);
    }

    final names = peopleNames(p.people.matched);
    return _slots(
      p,
      now: now,
      zone: zone,
      today: today,
      minutes: length.inMinutes,
      attendees: attendees,
      title: 'Pick a time for "$subject"${names.isEmpty ? '' : ' with $names'}',
      build: (s) => build(s.startUtc, s.endUtc),
    );
  }

  Future<CommandPlan> _move(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    // Where it goes is read before which meeting: a target that cannot be
    // read is the same sentence whichever meeting was meant.
    final targetText = p.targetText;
    if (bareHourAfterTo(targetText)) return const CannotDo(addAmPmSentence);
    final shift = moveShiftOf(targetText, now: now, zone: zone);
    if (shift == null) {
      final t = resolveWhen(targetText,
          now: now, zone: zone, mode: WhenMode.booking);
      // Nothing that says where: never handed to [resolveNewTime], which
      // would read a lone length ("an hour") as the meeting's new length.
      if (t.day == null &&
          t.time == null &&
          t.part == null &&
          t.unresolvedReason == null) {
        return const CannotDo(sayWhenSentence);
      }
    }

    final (:event, :stop) = _pickEvent(p, zone: zone, today: today);
    if (stop != null) return stop;
    final e = event!;
    if (!canMove(e)) {
      return CannotDo(eventRoleOf(e) == EventRole.attendee
          ? 'Only the organiser can move that meeting.'
          : "That meeting can't be moved.");
    }
    // "by an hour", "back 30 min": start and end move together, so the
    // meeting keeps its length.
    final next = shift != null
        ? shiftedTime(e, shift, now: now)
        : resolveNewTime(targetText, shown: e, now: now, zone: zone);
    switch (next) {
      case NewTimeTimed(:final startUtc, :final endUtc):
        return propose(MoveEvent.timed(e.id, startUtc: startUtc, endUtc: endUtc),
            target: e, zone: zone, today: today);
      case NewTimeAllDay(:final startDate, :final endDate):
        return propose(
            MoveEvent.allDay(e.id, startDate: startDate, endDate: endDate),
            target: e,
            zone: zone,
            today: today);
      case NewTimeProblem(:final reason):
        // "to tomorrow morning": a window, not a time. Offer the openings in
        // it for the meeting's own length rather than refusing — or picking
        // 9:00, which is the one thing never done here.
        final target = resolveWhen(p.targetText,
            now: now, zone: zone, mode: WhenMode.booking);
        final s = e.startUtc;
        final end = e.endUtc;
        if (target.part != null &&
            target.time == null &&
            target.rangeEnd == null &&
            target.unresolvedReason == null &&
            e.isTimed &&
            s != null &&
            end != null) {
          final day = target.day ?? zone.dateOf(s);
          final window = WhenResolution(
                  today: target.today, zone: zone, day: day, part: target.part)
              .windowUtc!;
          final slots = await _localSlots(
            first: day,
            last: day,
            window: window,
            minutes: end.difference(s).inMinutes,
            now: now,
            zone: zone,
            ignoreId: e.id,
          );
          if (slots.isEmpty) {
            return CannotDo('No free slot for "${_subjectOf(e)}" in that '
                'window.');
          }
          return SlotChoice(
            slots: slots,
            buildWrite: (slot) => MoveEvent.timed(e.id,
                startUtc: slot.startUtc, endUtc: slot.endUtc),
            title: 'Move "${_subjectOf(e)}" to…',
            source: 'local',
            targetEvent: e,
          );
        }
        return CannotDo(reason);
    }
  }

  Future<CommandPlan> _cancel(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final (:event, :stop) = _pickEvent(p, zone: zone, today: today);
    if (stop != null) return stop;
    final e = event!;
    final series = e.isSeriesMaster;
    switch (eventRoleOf(e)) {
      case EventRole.organiserWithGuests:
        return propose(CancelMeeting(e.id),
            target: e, series: series, zone: zone, today: today);
      case EventRole.ownEvent:
        return propose(DeleteEvent(e.id),
            target: e, series: series, zone: zone, today: today);
      case EventRole.attendee:
        if (!canRespond(e)) {
          return const CannotDo('That meeting is already cancelled.');
        }
        return propose(
          RespondToEvent(e.id, RsvpResponse.decline),
          target: e,
          series: series,
          lead: "You can't cancel it — it isn't yours — but you can decline:",
          zone: zone,
          today: today,
        );
    }
  }

  Future<CommandPlan> _rsvp(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final (:event, :stop) = _pickEvent(p, zone: zone, today: today);
    if (stop != null) return stop;
    final e = event!;
    if (!canRespond(e)) {
      return CannotDo(eventRoleOf(e) == EventRole.attendee
          ? 'That meeting is cancelled.'
          : "That's your own meeting — there's nothing to answer.");
    }
    final response = switch (p.action) {
      CommandAction.rsvpYes => RsvpResponse.accept,
      CommandAction.rsvpNo => RsvpResponse.decline,
      _ => RsvpResponse.tentative,
    };
    return propose(RespondToEvent(e.id, response),
        target: e, series: e.isSeriesMaster, zone: zone, today: today);
  }

  Future<CommandPlan> _findTime(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final matched = p.people.matched;
    // Names that matched nobody, even in the directory (the router looked):
    // searching without them would answer a different question.
    if (p.people.unresolved.isNotEmpty) {
      return CannotDo(unknownPersonSentence(p.people.unresolved.first));
    }
    final reason = p.when.unresolvedReason;
    if (reason != null) return CannotDo(reason);
    final attendees = [for (final m in matched) m.address];
    final names = peopleNames(matched);
    final subject = p.subject.trim().isNotEmpty
        ? p.subject.trim()
        : names.isEmpty
            ? 'Meeting'
            : 'Meeting with $names';
    final length = p.duration ?? defaultMeetingLength;
    return _slots(
      p,
      now: now,
      zone: zone,
      today: today,
      minutes: length.inMinutes,
      attendees: attendees,
      title: names.isEmpty
          ? 'Pick a time for "$subject"'
          : 'Pick a time with $names',
      build: (s) => CreateEvent.propose(
        subject: subject,
        startUtc: s.startUtc,
        endUtc: s.endUtc,
        attendees: attendees,
        isOnlineMeeting: attendees.isNotEmpty,
      ),
    );
  }

  // ── questions ──────────────────────────────────────────────────────────

  Future<CommandPlan> _askFree(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final w = p.when;
    final reason = w.unresolvedReason;
    if (reason != null) return CannotDo(reason);
    final length = p.duration ?? defaultMeetingLength;
    final day = w.day ?? today;

    // "Am I free Thursday at 3?" — a yes or a no, not a list.
    final time = w.time;
    if (time != null && w.rangeEnd == null) {
      final (start, end) = WhenResolution(
        today: w.today,
        zone: zone,
        day: day,
        time: time,
        endTime: w.endTime,
        duration: length,
        explicitTime: true,
      ).windowUtc!;
      final around = await _eventsOn(day, zone.dateOf(end), zone);
      final o = findOverlaps(around, start, end, zone: zone);
      final at = '${_onDay(day, today)} at ${formatEventTime(zone, start)}';
      if (o.hard.isEmpty) {
        final soft = o.soft.isEmpty
            ? ''
            : ' (tentatively: ${_subjectOf(o.soft.first)})';
        return Answer('Yes — you’re free $at$soft.',
            links: [for (final e in o.soft) _link(e)]);
      }
      final first = o.hard.first;
      final more = o.hard.length > 1 ? ' +${o.hard.length - 1}' : '';
      return Answer('No — $at you have ${_subjectOf(first)}$more.',
          links: [for (final e in o.hard) _link(e)]);
    }

    final last = w.rangeEnd ?? day;
    (DateTime, DateTime)? window;
    if (w.day != null) {
      window = w.windowUtc;
    } else if (w.part != null) {
      window = WhenResolution(today: w.today, zone: zone, day: day, part: w.part)
          .windowUtc;
    }
    final slots = await _localSlots(
      first: day,
      last: last,
      window: window,
      minutes: length.inMinutes,
      now: now,
      zone: zone,
      limit: 5,
    );
    final span = day == last ? _onDay(day, today) : 'in that window';
    if (slots.isEmpty) {
      return Answer('No free ${length.inMinutes} min slot $span.');
    }
    final labels = [
      for (final s in slots)
        day == last
            ? formatEventRange(zone, s.startUtc, s.endUtc)
            : '${shortDate(zone.dateOf(s.startUtc))} '
                '${formatEventRange(zone, s.startUtc, s.endUtc)}',
    ];
    final head = day == last ? 'Free $span' : 'Free';
    return Answer('$head: ${labels.join(', ')}.');
  }

  Future<CommandPlan> _askAgenda(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final w = p.when;
    final reason = w.unresolvedReason;
    if (reason != null) return CannotDo(reason);
    final day = w.day ?? today;
    var last = w.rangeEnd ?? day;
    // A week is the widest agenda a sentence can carry.
    if (last.isAfter(day.addDays(6))) last = day.addDays(6);
    var events = [
      for (final e in await _eventsOn(day, last, zone))
        if (!e.isCancelled && e.responseStatus != 'declined') e,
    ];
    // "What's on tomorrow afternoon": the part narrows the timed rows.
    if (w.part != null && w.rangeEnd == null && w.time == null) {
      final (from, to) = WhenResolution(
              today: w.today, zone: zone, day: day, part: w.part)
          .windowUtc!;
      events = [
        for (final e in events)
          if (e.isAllDay ||
              (e.startUtc != null &&
                  e.endUtc != null &&
                  instantsOverlap(e.startUtc!, e.endUtc!, from, to)))
            e,
      ];
    }
    final heading = day == last ? _dayHeading(day, today) : null;
    if (events.isEmpty) {
      return Answer(heading == null
          ? 'Nothing in that window.'
          : 'Nothing ${_onDay(day, today)}.');
    }
    String line(CalendarEvent e) {
      final prefix = heading == null
          ? '${shortDate(e.isAllDay ? e.startDate! : zone.dateOf(e.startUtc!))} '
          : '';
      if (e.isAllDay) return '${prefix}All day ${_subjectOf(e)}';
      return '$prefix${formatEventRange(zone, e.startUtc!, e.endUtc!)} '
          '${_subjectOf(e)}';
    }

    final lines = [for (final e in events) line(e)];
    return Answer(
      heading == null ? lines.join(' · ') : '$heading: ${lines.join(' · ')}',
      links: [for (final e in events) _link(e)],
    );
  }

  Future<CommandPlan> _askPerson(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final matched = p.people.matched;
    if (p.people.unresolved.isNotEmpty) {
      return CannotDo(unknownPersonSentence(p.people.unresolved.first));
    }
    if (matched.isEmpty) return const CannotDo(whoWithSentence);
    final addresses = [for (final m in matched) m.address];
    final names = peopleNames(matched);
    final lower = p.text.toLowerCase();
    final asksLast = lower.contains('last') || lower.contains('when did');
    final asksNext = lower.contains('next') ||
        lower.contains('seeing') ||
        lower.contains('when am i') ||
        lower.contains('upcoming');
    final both = asksLast == asksNext;

    final lines = <String>[];
    final links = <AnswerLink>[];
    if (both || asksNext) {
      final next = await calendar.nextMeetingWith(addresses, nowUtc: now);
      if (next == null) {
        lines.add('Nothing coming up with $names.');
      } else {
        lines.add(nextMeetingLabel(next, zone: zone, today: today));
        links.add(_link(next));
      }
    }
    if (both || asksLast) {
      final last = await calendar.lastMetWith(addresses, nowUtc: now);
      if (last == null) {
        lines.add('No past meeting with $names on your calendar.');
      } else {
        lines.add('${lastMetLabel(last, zone: zone, today: today)} · '
            '${_subjectOf(last)}');
        links.add(_link(last));
      }
    }
    return Answer('$names — ${lines.join(' · ')}', links: links);
  }

  // ── shared ─────────────────────────────────────────────────────────────

  /// The one meeting [p] means, or the plan that stops short of one: none
  /// found, or several tied at the top.
  ({CalendarEvent? event, CommandPlan? stop}) _pickEvent(
    ParsedCommand p, {
    required CalendarZone zone,
    required CalendarDate today,
  }) {
    final tops = topCandidates(p.events);
    if (tops.isEmpty) {
      final day = p.eventWhen.day;
      return (
        event: null,
        stop: CannotDo(day == null
            ? "I couldn't find that meeting in the next two weeks."
            : "I couldn't find that meeting ${_onDay(day, today)}."),
      );
    }
    if (tops.length > 1) {
      return (
        event: null,
        stop: NeedsChoice('Which meeting?', [
          for (final c in tops.take(4))
            CommandOption(
              label: eventChoiceLabel(c.event, zone, today),
              bind: (person: null, event: c.event, answers: null),
            ),
        ]),
      );
    }
    return (event: tops.single.event, stop: null);
  }

  /// Openings for a create or a find-a-time: the person's own when nobody
  /// else is invited, everyone's (`find_meeting_times`) when somebody is.
  Future<CommandPlan> _slots(
    ParsedCommand p, {
    required DateTime now,
    required CalendarZone zone,
    required CalendarDate today,
    required int minutes,
    required List<String> attendees,
    required String title,
    required CalendarWrite Function(FreeSlot) build,
  }) async {
    final w = p.when;
    final mailbox = await _readMailbox();
    final CalendarDate first;
    final CalendarDate last;
    (DateTime, DateTime)? window;
    if (w.day != null) {
      first = w.day!;
      last = w.rangeEnd ?? first;
      window = w.windowUtc;
    } else if (w.part != null) {
      // "this afternoon" sets a day; a bare "afternoon" is today's.
      first = today;
      last = today;
      window = WhenResolution(today: w.today, zone: zone, day: today, part: w.part)
          .windowUtc;
    } else {
      // No when at all: the next five working days, from now.
      first = today;
      last = _workingDaysAhead(today, 5, mailbox);
      window = null;
    }

    Future<CommandPlan> local(String note) async {
      final slots = await _localSlots(
        first: first,
        last: last,
        window: window,
        minutes: minutes,
        now: now,
        zone: zone,
        mailbox: mailbox,
      );
      if (slots.isEmpty) {
        return CannotDo(first == last
            ? 'No free $minutes min slot ${_onDay(first, today)}.'
            : 'No free $minutes min slot in that window.');
      }
      return SlotChoice(
        slots: slots,
        buildWrite: build,
        title: '$title$note',
        source: 'local',
      );
    }

    // `find_meeting_times` refuses an empty list; a self-only search is the
    // mirror's (gotcha 28).
    if (attendees.isEmpty) return local('');

    var start = window?.$1 ?? now;
    if (start.isBefore(now)) start = now;
    final end = window?.$2 ??
        _utc(zone.localDateTime(last.addDays(1), 0, 0));
    if (!end.isAfter(start)) return const CannotDo('That time has passed.');
    try {
      final found = await backend.findMeetingTimes(
        attendees: attendees,
        durationMinutes: minutes,
        windowStartUtc: start,
        windowEndUtc: end,
        maxCandidates: 3,
      );
      if (found.isEmpty) return const CannotDo(noCommonTimeSentence);
      return SlotChoice(
        slots: [
          for (final s in found.take(3)) FreeSlot(s.startUtc, s.endUtc),
        ],
        buildWrite: build,
        title: title,
        source: 'graph',
      );
    } on CalendarRefused catch (e) {
      if (e.code == 'unsupported_account') {
        // A personal account has no free/busy for others: offer the
        // owner's own openings, and say that is all they are.
        return local(' (only your calendar could be checked)');
      }
      final sentence = firstSentence(e.reason);
      return CannotDo(sentence.isEmpty ? e.message : sentence);
    } on CalendarScopeMissing {
      return const CannotDo(
          'Calendar permission missing — reconnect in Settings.');
    } on CalendarUnavailable catch (e) {
      return CannotDo(e.sentence);
    } on Object catch (e) {
      debugPrint('calendar command: find_meeting_times failed: '
          '${e.runtimeType}');
      return const CannotDo("Couldn't reach the calendar to find a time.");
    }
  }

  /// The owner's own openings over [first]..[last] (inclusive), clamped to
  /// [window]. One day never skips a weekend — a person who names a
  /// Saturday means it; a range does.
  Future<List<FreeSlot>> _localSlots({
    required CalendarDate first,
    required CalendarDate last,
    required (DateTime, DateTime)? window,
    required int minutes,
    required DateTime now,
    required CalendarZone zone,
    MailboxSettings? mailbox,
    int limit = 3,
    String? ignoreId,
  }) async {
    final hours = mailbox ?? await _readMailbox();
    var events = await _eventsOn(first, last, zone);
    if (ignoreId != null) {
      events = [for (final e in events) if (e.id != ignoreId) e];
    }
    if (first == last) {
      return freeSlotsOnDay(
        events: events,
        day: first,
        durationMinutes: minutes,
        zone: zone,
        hours: hours,
        limit: limit,
        nowUtc: now,
        windowStartUtc: window?.$1,
        windowEndUtc: window?.$2,
      );
    }
    return freeSlotsInRange(
      events: events,
      firstDay: first,
      lastDay: last,
      durationMinutes: minutes,
      zone: zone,
      hours: hours,
      limit: limit,
      nowUtc: now,
      windowStartUtc: window?.$1,
      windowEndUtc: window?.$2,
    );
  }

  /// The mirror's events over local [first]..[last] (inclusive).
  Future<List<CalendarEvent>> _eventsOn(
    CalendarDate first,
    CalendarDate last,
    CalendarZone zone,
  ) =>
      calendar.eventsBetween(
        startUtc: _utc(zone.localDateTime(first, 0, 0)),
        endUtc: _utc(zone.localDateTime(last.addDays(1), 0, 0)),
        fromDate: first,
        toDateExclusive: last.addDays(1),
      );

  Future<MailboxSettings?> _readMailbox() async {
    try {
      return await mailbox();
    } on Object catch (e) {
      debugPrint('calendar command: mailbox settings unread: ${e.runtimeType}');
      return null;
    }
  }
}

/// The day [n] working days on from [today], counting today when it is one:
/// the mailbox's working days when it names any, else Monday to Friday.
CalendarDate _workingDaysAhead(
  CalendarDate today,
  int n,
  MailboxSettings? mailbox,
) {
  const names = {
    'monday': 1,
    'tuesday': 2,
    'wednesday': 3,
    'thursday': 4,
    'friday': 5,
    'saturday': 6,
    'sunday': 7,
  };
  final named = {
    for (final d in mailbox?.workingDays ?? const <String>[])
      if (names[d.trim().toLowerCase()] != null) names[d.trim().toLowerCase()]!,
  };
  final working = named.isEmpty ? {1, 2, 3, 4, 5} : named;
  var day = today;
  var counted = 0;
  // Bounded: a mailbox with no working day at all still ends the walk.
  for (var i = 0; i < 21; i++) {
    if (working.contains(day.weekday)) counted++;
    if (counted >= n) return day;
    day = day.addDays(1);
  }
  return today.addDays(n);
}

String _subjectOf(CalendarEvent e) =>
    e.subject.trim().isEmpty ? '(no subject)' : e.subject.trim();

AnswerLink _link(CalendarEvent e) => (label: _subjectOf(e), eventId: e.id);

/// "today", "tomorrow", "on Thu Oct 8".
String _onDay(CalendarDate day, CalendarDate today) {
  if (day == today) return 'today';
  if (day == today.addDays(1)) return 'tomorrow';
  return 'on ${shortDate(day)}';
}

/// "Today", "Tomorrow", "Thu Oct 8".
String _dayHeading(CalendarDate day, CalendarDate today) {
  if (day == today) return 'Today';
  if (day == today.addDays(1)) return 'Tomorrow';
  return shortDate(day);
}
