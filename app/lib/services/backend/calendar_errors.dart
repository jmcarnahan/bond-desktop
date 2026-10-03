/// The calendar's failures, one type per thing a caller does differently.
///
/// The bond-mcps calendar tools answer a refusal as data (`{"error": code,
/// "reason": prose}`), and the codes are the contract: the reason strings are
/// prose and may change. Each type below is a code, or a family of codes, that
/// leads somewhere different — re-read and retry, start a new sync run, drop
/// the row, say "only the organiser can move this", say "the permission is
/// missing". A code that leads nowhere special is [CalendarRefused].
///
/// Auth failures are NOT here: [NotSignedIn] and [ReconsentRequired] (from
/// `backend_types.dart`) pass through UNWRAPPED, exactly as they do from the
/// mail, Teams and people backends, because the session routing keys on them.
///
/// Every [message] is written for a person and is what `toString` gives, so a
/// banner can show the exception as it stands.
library;

/// `calendar_scope_missing` or `mailbox_settings_scope_missing`: the grant
/// lacks Calendars.ReadWrite (or MailboxSettings.Read). On a write it may also
/// mean a read-only calendar — the server cannot tell the two apart — but this
/// app writes only to the primary calendar, so it reads as the permission.
class CalendarScopeMissing implements Exception {
  final String message;

  const CalendarScopeMissing([
    this.message = 'The calendar permission is missing. Reconnect Microsoft '
        'for this workspace to grant it (Settings › Connection).',
  ]);

  /// The message for `mailbox_settings_scope_missing`: the missing grant is
  /// MailboxSettings.Read, and a sentence naming the calendar would send the
  /// person looking for the wrong permission.
  static const String mailboxSettings = 'The mailbox settings permission is '
      'missing. Reconnect Microsoft for this workspace to grant it '
      '(Settings › Connection).';

  @override
  String toString() => message;
}

/// `cursor_expired` or `invalid_cursor`: the stored sync cursor is no good.
/// Drop it, start a new run over the same window, and mark-and-sweep once the
/// run completes.
class CalendarCursorExpired implements Exception {
  final String message;

  const CalendarCursorExpired([
    this.message = 'The calendar sync position expired; the calendar is being '
        'read again from the start.',
  ]);

  @override
  String toString() => message;
}

/// `event_changed`: the event changed since it was read (the If-Match did not
/// match, or Graph answered 412). Nothing was written. Re-read it, show what
/// changed if it matters, and retry with the new change key.
class CalendarEventChanged implements Exception {
  final String message;

  const CalendarEventChanged([
    this.message = 'This event changed since it was loaded. Check the new '
        'details and try again.',
  ]);

  @override
  String toString() => message;
}

/// `not_organizer`: an attendee asked for an organiser's write — moving,
/// renaming or cancelling a meeting, or deleting one that is not cancelled.
class CalendarNotOrganizer implements Exception {
  final String message;

  const CalendarNotOrganizer([
    this.message = 'Only the organizer can change this meeting. Decline it '
        'instead, or propose a new time.',
  ]);

  @override
  String toString() => message;
}

/// `not_found`: the event is gone (or its id is malformed). Drop it locally,
/// as for an id in `sync_calendar`'s `removed`; retrying cannot help.
class CalendarEventGone implements Exception {
  final String message;

  const CalendarEventGone([
    this.message = 'This event no longer exists.',
  ]);

  @override
  String toString() => message;
}

/// Any other permanent refusal: `invalid_arguments`, `invalid_options`,
/// `invalid_date`, `invalid_action`, `html_body_readonly`,
/// `unsupported_account`, … [code] is the server's, for routing and the
/// activity log; [reason] is the server's prose and is for a person only.
class CalendarRefused implements Exception {
  final String code;
  final String reason;

  const CalendarRefused(this.code, this.reason);

  String get message => reason.isEmpty
      ? 'The calendar refused this ($code).'
      : 'The calendar refused this: $reason';

  @override
  String toString() => message;
}

/// There is no calendar on this backend at all (SDK mode, D11). [sentence]
/// says what would give one.
class CalendarUnavailable implements Exception {
  final String sentence;

  const CalendarUnavailable(this.sentence);

  String get message => sentence;

  @override
  String toString() => sentence;
}

/// A failure worth retrying later: the transport dropped, or the tool itself
/// failed (a Graph 429, a 5xx, an unmapped 400 such as an unknown zone name).
/// [statusCode] is the transport's HTTP status when it had one.
class CalendarTransient implements Exception {
  final String message;
  final int? statusCode;

  const CalendarTransient(this.message, {this.statusCode});

  @override
  String toString() => message;
}
