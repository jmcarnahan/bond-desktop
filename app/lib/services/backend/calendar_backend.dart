import '../../models/calendar_models.dart';
import 'backend_types.dart';
import 'calendar_errors.dart';

/// The primary Outlook calendar: read it, sync it, write to it.
///
/// MCP mode only (D11). The MCP implementation speaks the bond-mcps calendar
/// tools; SDK mode gets `UnavailableCalendarBackend`, whose every method
/// throws [CalendarUnavailable]. Nothing here touches sqlite — the calendar
/// mirror owns the writes.
///
/// Time crosses this seam in exactly two shapes (D13): UTC [DateTime]s for
/// timed events, and [CalendarDate]s for all-day ones. The implementation
/// formats them for the wire; callers never build a wire string, except the
/// sync window (see [syncPage]).
///
/// Every write takes `dryRun`. A dry run answers a [WritePreview] — the method,
/// the path, the payload and `notifies`, the addresses the real write would
/// email — and a real write answers an [EventWriteAck]. A `manage_event` dry
/// run still reads the event and needs a connection, so a refusal shows up in
/// the preview exactly as it would for real.
///
/// Failures are the types in `calendar_errors.dart`. Auth failures —
/// [NotSignedIn], [ReconsentRequired] — pass through UNWRAPPED, exactly as
/// from the other backends.
abstract class CalendarBackend {
  /// One page of the calendar delta (`sync_calendar`).
  ///
  /// An empty [cursor] starts a run over [startUtc]..[endUtc], which are
  /// `YYYY-MM-DDTHH:MM:SSZ` strings (null = the server's default window, now
  /// − 30 days to + 180 days). A non-empty [cursor] continues a run and the
  /// window is ignored — it lives in the cursor. Loop while
  /// [CalendarSyncPage.complete] is false; persist the first page's window.
  ///
  /// Throws [CalendarCursorExpired] when the cursor is stale or not one this
  /// method returned: start a new run and sweep once it completes.
  Future<CalendarSyncPage> syncPage({
    String cursor = '',
    String? startUtc,
    String? endUtc,
  });

  /// The event [id] as it stands now. Throws [CalendarEventGone] when it no
  /// longer exists.
  Future<CalendarEvent> getEvent(String id);

  /// The mailbox's zone, working hours and auto-reply state.
  Future<MailboxSettings> mailboxSettings();

  /// RSVP to the invite [id]. [response] is one of `accept`, `tentative`,
  /// `decline`.
  ///
  /// [comment] only with [sendResponse] true (Graph refuses it otherwise). A
  /// proposal — [proposedStartUtc] and [proposedEndUtc], together — only with
  /// `tentative` or `decline`, only when sending, and only when the event's
  /// `allowNewTimeProposals` is not false. Never on your own event. `notifies`
  /// is the organiser when sending, else empty.
  Future<CalendarWriteResult> respond(
    String id, {
    required String response,
    String? comment,
    bool sendResponse = true,
    DateTime? proposedStartUtc,
    DateTime? proposedEndUtc,
    bool dryRun = false,
  });

  /// Edit the event [id]. [ifMatch] is REQUIRED: the stored `change_key`.
  /// A mismatch is [CalendarEventChanged] with nothing written; a success
  /// answers the row with the NEW change key, which the caller stores.
  ///
  /// A timed move sends [startUtc] and [endUtc] together. An all-day move
  /// sends [startDate] and [endDate] (end exclusive) together, with
  /// [allDayZone] = the mailbox's `time_zone` — required whenever dates are
  /// given. Instants and dates are never sent together. An attendee may change
  /// only [showAs]; anything else on a meeting is [CalendarNotOrganizer].
  Future<CalendarWriteResult> update(
    String id, {
    required String ifMatch,
    DateTime? startUtc,
    DateTime? endUtc,
    CalendarDate? startDate,
    CalendarDate? endDate,
    String? allDayZone,
    String? subject,
    String? location,
    String? showAs,
    bool dryRun = false,
  });

  /// Cancel a meeting you organise, emailing every attendee [comment]. A
  /// meeting with no attendees cannot be cancelled — [delete] it.
  Future<CalendarWriteResult> cancel(
    String id, {
    String? comment,
    bool dryRun = false,
  });

  /// Delete the event [id]. An organiser's delete of a meeting sends
  /// cancellations; an attendee may delete only a CANCELLED meeting (else
  /// [CalendarNotOrganizer] — decline instead).
  Future<CalendarWriteResult> delete(String id, {bool dryRun = false});

  /// Create an event on the primary calendar, [startUtc]..[endUtc], inviting
  /// [attendees] (bare lowercase `local@domain` addresses).
  ///
  /// [transactionId] makes the create idempotent: generate one per
  /// user-intended create, persist it before calling, and reuse it on every
  /// retry of that same proposal — a second call with it answers the same
  /// event id and creates no duplicate. The dry run is pre-token and works
  /// while disconnected.
  Future<CalendarWriteResult> create({
    required String subject,
    required DateTime startUtc,
    required DateTime endUtc,
    List<String> attendees = const [],
    bool isOnlineMeeting = false,
    String? body,
    required String transactionId,
    bool dryRun = false,
  });

  /// Up to [maxCandidates] slots of [durationMinutes] in
  /// [windowStartUtc]..[windowEndUtc] when [attendees] and you are free,
  /// within working hours. No suggestions is an answer, not a failure, and
  /// carries Graph's reason ([MeetingTimes.emptyReason]). A personal account
  /// is `unsupported_account` ([CalendarRefused]).
  ///
  /// [attendees] (bare addresses) must be NON-EMPTY — an empty list is an
  /// [ArgumentError], because the server refuses it. A search of only your
  /// own calendar is local, over the mirror: `freeSlotsOnDay` or
  /// `freeSlotsInRange` in `services/calendar/overlaps.dart`.
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
  });
}
