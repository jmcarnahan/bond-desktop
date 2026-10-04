import '../../models/calendar_models.dart';

/// Where the owner stands on a meeting — the ONE reader of Graph's
/// `responseStatus` string, and of `showAs` for the tentative hold, for
/// display and for the overlap maths. The agenda row, the grid tile, the
/// panel line, the Today row, the answer buttons and the overlap walk all ask
/// here, so no two faces can disagree about what "maybe" or "declined" means.
/// Never compare the strings anywhere else — the one other `showAs` read is
/// `overlaps.dart` dropping `free` and `workingElsewhere` time, which is about
/// blocking, not standing.
///
/// Its own file because the overlap maths (`overlaps.dart`) and the day
/// (`day_items.dart`) both read it, and `event_view.dart` — which re-exports
/// it — imports the day.

/// Whether [e] is the owner's own event — they organised it. Graph marks
/// the owner's copy `isOrganizer`, and its response `organizer`; either says
/// it. The one organiser rule: the role a write takes (`eventRoleOf`), the
/// tally (`attendeeTally`), the response line and [standingOf] all read it
/// here, so no two of them can disagree about whose meeting it is.
bool isOwnersEvent(CalendarEvent e) =>
    e.isOrganizer || e.responseStatus.trim().toLowerCase() == 'organizer';

/// What the owner ANSWERED, and nothing else: the panel's "You said maybe"
/// and the answer button drawn as chosen follow this, because both are claims
/// about what the owner pressed — not about how the calendar shows the slot.
enum EventAnswer { none, accepted, tentative, declined }

EventAnswer answerOf(CalendarEvent e) =>
    switch (e.responseStatus.trim().toLowerCase()) {
      'accepted' => EventAnswer.accepted,
      'tentativelyaccepted' => EventAnswer.tentative,
      'declined' => EventAnswer.declined,
      _ => EventAnswer.none,
    };

/// Where the owner stands on a meeting, read ONCE here for every face
/// (agenda row, grid tile, panel line, Today row) and for the overlap
/// maths — never compare `responseStatus` or `showAs` strings elsewhere.
enum EventStanding {
  cancelled,
  organizer,
  accepted,
  tentative,
  unanswered,
  declined,
  noAnswerNeeded,
}

/// [e]'s standing. Cancelled wins over any answer, then the owner's own
/// meeting, then the answer. A Maybe is a tentative answer OR an accepted
/// meeting the owner shows as `tentative`. An invite still owed an answer is
/// [EventStanding.unanswered] even though Outlook pencils every new invite in
/// as `showAs: tentative` — the owner has not said maybe, they have said
/// nothing; only an unanswered meeting that asks for no answer and is shown
/// tentative reads as a Maybe.
EventStanding standingOf(CalendarEvent e) {
  if (e.isCancelled) return EventStanding.cancelled;
  if (isOwnersEvent(e)) return EventStanding.organizer;
  final shownTentative = e.showAs.trim().toLowerCase() == 'tentative';
  switch (answerOf(e)) {
    case EventAnswer.accepted:
      return shownTentative ? EventStanding.tentative : EventStanding.accepted;
    case EventAnswer.tentative:
      return EventStanding.tentative;
    case EventAnswer.declined:
      return EventStanding.declined;
    case EventAnswer.none:
      if (e.needsResponse) return EventStanding.unanswered;
      return shownTentative
          ? EventStanding.tentative
          : EventStanding.noAnswerNeeded;
  }
}

/// The standing as one short word for a caption: 'Cancelled', 'Yours',
/// 'Accepted', 'Maybe', 'Not answered', 'Declined', or '' when no answer is
/// needed and there is nothing to say.
String standingWord(EventStanding s) => switch (s) {
      EventStanding.cancelled => 'Cancelled',
      EventStanding.organizer => 'Yours',
      EventStanding.accepted => 'Accepted',
      EventStanding.tentative => 'Maybe',
      EventStanding.unanswered => 'Not answered',
      EventStanding.declined => 'Declined',
      EventStanding.noAnswerNeeded => '',
    };

/// Whether a clash with [e] is only a SOFT overlap — worth saying, not worth
/// refusing over: a Maybe ([EventStanding.tentative]) or any slot the
/// calendar shows `tentative`, which is how an invite still owed an answer
/// sits there. The overlap walk and the free-slot walk's `tentativeBlocks`
/// both read it.
bool isTentativeHold(CalendarEvent e) =>
    standingOf(e) == EventStanding.tentative ||
    e.showAs.trim().toLowerCase() == 'tentative';
