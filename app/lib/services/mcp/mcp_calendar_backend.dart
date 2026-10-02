import 'dart:convert';

import '../../models/calendar_models.dart';
import '../backend/backend_types.dart';
import '../backend/calendar_backend.dart';
import '../backend/calendar_errors.dart';
import 'bond_mcp_client.dart';

/// The primary calendar, through the bond-mcps calendar tools.
///
/// The tool contract is bond-mcps' `docs/desktop-calendar-followups-handoff.md`
/// §3, and three of its rules shape every call here:
///
/// - Every param is a string or an int; an empty string means absent.
///   `options` is a JSON OBJECT ENCODED AS A STRING, built with [jsonEncode]
///   so a bool goes out as `true` and an int as a number — the server's
///   strict keys refuse `"true"` and `"30"`.
/// - `manage_event` refuses a key its action does not take, so each action's
///   options map is built from exactly its own keys.
/// - A refusal is data, `{"error": code, "reason": prose}`, and is routed on
///   `code` alone ([_call]); a tool error (Graph 429/5xx, an unmapped 400) is
///   [CalendarTransient].
///
/// Timed instants go out as UTC `YYYY-MM-DDTHH:MM:SSZ` everywhere, except
/// `create_calendar_event`, whose datetimes are naive wall times read in its
/// `timezone` param — so it is sent UTC wall times with `timezone: 'UTC'`,
/// which is the same instant with no second convention to get wrong.
///
/// Addresses are checked here before they are sent: the server refuses
/// `"Dana Reyes <dana@contoso.com>"` as `invalid_options`, and a refusal a
/// round trip later is a worse message than an [ArgumentError] now.
class McpCalendarBackend implements CalendarBackend {
  final BondMcpClient _mcp;

  McpCalendarBackend(this._mcp);

  @override
  Future<CalendarSyncPage> syncPage({
    String cursor = '',
    String? startUtc,
    String? endUtc,
  }) async {
    final result = await _call('sync_calendar', {
      'cursor': cursor,
      'start_date': startUtc ?? '',
      'end_date': endUtc ?? '',
    });
    final window = result['window'];
    final complete = result['complete'];
    final cursorOut = result['cursor'];
    return CalendarSyncPage(
      events: _events(result['events']),
      removed: [
        for (final id in _list(result['removed']))
          if (id is String && id.isNotEmpty) id,
      ],
      cursor: cursorOut is String ? cursorOut : '',
      // Anything but an explicit false ends the loop: a missing flag must not
      // spin the drain forever.
      complete: complete != false,
      // ...but only an explicit true licenses the sweep: a malformed page on
      // a fresh run would otherwise delete every row it did not carry.
      explicitlyComplete: complete == true,
      windowStart: window is Map ? _str(window['start']) : '',
      windowEnd: window is Map ? _str(window['end']) : '',
    );
  }

  @override
  Future<CalendarEvent> getEvent(String id) async {
    final result = await _call('get_calendar_event', {
      'event_id': id,
      'options': '',
    });
    return CalendarEvent.fromToolRow(result);
  }

  @override
  Future<MailboxSettings> mailboxSettings() async {
    final result = await _call('get_mailbox_settings', const {});
    return MailboxSettings.fromToolRow(result);
  }

  @override
  Future<CalendarWriteResult> respond(
    String id, {
    required String response,
    String? comment,
    bool sendResponse = true,
    DateTime? proposedStartUtc,
    DateTime? proposedEndUtc,
    bool dryRun = false,
  }) async {
    if (!const {'accept', 'tentative', 'decline'}.contains(response)) {
      throw ArgumentError.value(
          response, 'response', 'must be accept, tentative or decline');
    }
    if ((proposedStartUtc == null) != (proposedEndUtc == null)) {
      throw ArgumentError('A proposed new time needs both a start and an end.');
    }
    final proposed = proposedStartUtc != null;
    // The interface's rules, refused here rather than a round trip later: the
    // server refuses each of these too, as a code no caller routes on.
    if (comment != null && !sendResponse) {
      throw ArgumentError('A comment goes only with a response that is sent.');
    }
    if (proposed && response == 'accept') {
      throw ArgumentError(
          'A proposed new time goes with tentative or decline, never accept.');
    }
    if (proposed && !sendResponse) {
      throw ArgumentError(
          'A proposed new time goes only with a response that is sent.');
    }
    final result = await _call('manage_event', {
      'action': 'respond',
      'event_id': id,
      'options': jsonEncode({
        'response': response,
        'comment': ?comment,
        'send_response': sendResponse,
        if (proposed)
          'proposed_new_time': {
            'start': utcWire(proposedStartUtc),
            'end': utcWire(proposedEndUtc!),
          },
        if (dryRun) 'dry_run': true,
      }),
    });
    return _writeResult(result, id, withEvent: false);
  }

  @override
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
  }) async {
    final hasInstants = startUtc != null || endUtc != null;
    final hasDates = startDate != null || endDate != null;
    if (hasInstants && hasDates) {
      throw ArgumentError('An update sends instants or dates, never both.');
    }
    if (hasInstants && (startUtc == null || endUtc == null)) {
      throw ArgumentError('A timed move needs both a start and an end.');
    }
    if (hasDates && (startDate == null || endDate == null)) {
      throw ArgumentError('An all-day move needs both a start and an end date.');
    }
    if (hasDates && (allDayZone == null || allDayZone.isEmpty)) {
      throw ArgumentError(
          'An all-day move needs allDayZone, the mailbox time_zone.');
    }
    final result = await _call('manage_event', {
      'action': 'update',
      'event_id': id,
      'options': jsonEncode({
        'if_match': ifMatch,
        if (hasInstants) ...{
          'start': utcWire(startUtc!),
          'end': utcWire(endUtc!),
        },
        if (hasDates) ...{
          'start': startDate!.toIso(),
          'end': endDate!.toIso(),
          'start_timezone': allDayZone,
          'end_timezone': allDayZone,
        },
        'subject': ?subject,
        'location': ?location,
        'show_as': ?showAs,
        if (dryRun) 'dry_run': true,
      }),
    });
    // Placed by its `start_utc`/`end_utc` alone, as every row is; an ack
    // whose UTC pair is empty is unplaced, the write notes the id, and the
    // forced sync brings the moved row.
    return _writeResult(result, id, withEvent: true);
  }

  @override
  Future<CalendarWriteResult> cancel(
    String id, {
    String? comment,
    bool dryRun = false,
  }) async {
    final result = await _call('manage_event', {
      'action': 'cancel',
      'event_id': id,
      'options': jsonEncode({
        'comment': ?comment,
        if (dryRun) 'dry_run': true,
      }),
    });
    return _writeResult(result, id, withEvent: false);
  }

  @override
  Future<CalendarWriteResult> delete(String id, {bool dryRun = false}) async {
    final result = await _call('manage_event', {
      'action': 'delete',
      'event_id': id,
      'options': jsonEncode({
        if (dryRun) 'dry_run': true,
      }),
    });
    return _writeResult(result, id, withEvent: false);
  }

  @override
  Future<CalendarWriteResult> create({
    required String subject,
    required DateTime startUtc,
    required DateTime endUtc,
    List<String> attendees = const [],
    bool isOnlineMeeting = false,
    String? body,
    required String transactionId,
    bool dryRun = false,
  }) async {
    final invitees = bareAddresses(attendees);
    final result = await _call('create_calendar_event', {
      'subject': subject,
      'start_datetime': _naiveUtc(startUtc),
      'end_datetime': _naiveUtc(endUtc),
      'timezone': 'UTC',
      'options': jsonEncode({
        if (invitees.isNotEmpty) 'attendees': invitees,
        if (isOnlineMeeting) 'is_online_meeting': true,
        'body': ?body,
        'transaction_id': transactionId,
        if (dryRun) 'dry_run': true,
      }),
    });
    // Only its `start_utc`/`end_utc` place it (the legacy start/end echo the
    // REQUEST zone); when the UTC re-read failed those are "" and the event
    // arrives with the next sync instead.
    return _writeResult(result, '', withEvent: true);
  }

  @override
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
    String activityDomain = 'work',
  }) async {
    // The server refuses an empty CSV as `invalid_arguments`; a self-only
    // search is local, over the mirror (`freeSlotsOnDay`/`freeSlotsInRange`).
    if (attendees.isEmpty) {
      throw ArgumentError.value(attendees, 'attendees',
          'must name at least one attendee; search your own calendar locally');
    }
    final invitees = bareAddresses(attendees);
    final result = await _call('find_meeting_times', {
      'attendees': invitees.join(','),
      'duration_minutes': durationMinutes,
      // Both bounds carry an offset (the `Z`), which is what the server
      // reads them in; its zone, when one is needed, is `options.timezone`
      // (default UTC) and NOT a top-level parameter as the handoff's §3.5
      // signature says — the deployed tool refused a top-level `timezone`
      // as an unexpected keyword on the first live press (2026-10-02).
      'window_start': utcWire(windowStartUtc),
      'window_end': utcWire(windowEndUtc),
      // `work` is the server's default, so it is said only when it is not.
      'options': jsonEncode({
        'max_candidates': maxCandidates,
        if (activityDomain != 'work') 'activity_domain': activityDomain,
      }),
    });
    final reason = result['empty_reason'];
    return MeetingTimes(
      suggestions: [
        for (final raw in _list(result['suggestions']))
          if (raw is Map) ?_suggestion(Map<String, dynamic>.from(raw)),
      ],
      // Lowercased: Graph spells it `AttendeesUnavailable`, and the rule
      // that reads it should not care.
      emptyReason: reason is String ? reason.trim().toLowerCase() : '',
    );
  }

  // ── wire formats ───────────────────────────────────────────────────────

  /// [t] as the tools' UTC instant: `YYYY-MM-DDTHH:MM:SSZ`, whole seconds.
  static String utcWire(DateTime t) => '${_naiveUtc(t)}Z';

  /// [t]'s UTC wall time with no zone suffix: `YYYY-MM-DDTHH:MM:SS`.
  static String _naiveUtc(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-'
        '${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
  }

  static final RegExp _bareAddress = RegExp(r'^[^\s<>@,]+@[^\s<>@,]+$');

  /// [addresses] checked and lowercased, as the tools' address lists want
  /// them: bare `local@domain`, no display name, no whitespace, no angle
  /// brackets. Throws [ArgumentError] naming the first that is not.
  static List<String> bareAddresses(List<String> addresses) => [
        for (final address in addresses)
          if (_bareAddress.hasMatch(address))
            address.toLowerCase()
          else
            throw ArgumentError.value(
                address, 'attendees', 'must be a bare local@domain address'),
      ];

  // ── result shapes ──────────────────────────────────────────────────────

  static List<CalendarEvent> _events(Object? raw) {
    final events = <CalendarEvent>[];
    for (final row in _list(raw)) {
      if (row is! Map) continue;
      try {
        events.add(CalendarEvent.fromToolRow(Map<String, dynamic>.from(row)));
      } on FormatException {
        // A row with no id cannot be stored or removed; skipping it loses
        // nothing a later sync would not bring back.
      }
    }
    return events;
  }

  /// A dry run's preview, or the real write's ack. [id] is the event the
  /// write was about; a create has none until the server answers one.
  static CalendarWriteResult _writeResult(
    Map<String, dynamic> result,
    String id, {
    required bool withEvent,
  }) {
    if (result['dry_run'] == true) {
      final payload = result['payload'];
      final ifMatch = result['if_match'];
      return WritePreview(
        method: _str(result['method']),
        path: _str(result['path']),
        payload: payload is Map ? Map<String, Object?>.from(payload) : null,
        notifies: [
          for (final a in _list(result['notifies']))
            if (a is String && a.isNotEmpty) a.toLowerCase(),
        ],
        ifMatch: ifMatch is String && ifMatch.isNotEmpty ? ifMatch : null,
      );
    }
    final answered = _str(result['id']);
    final ackId = answered.isNotEmpty ? answered : id;
    if (ackId.isEmpty) {
      throw const CalendarTransient(
          'The calendar did not say which event it wrote.');
    }
    return EventWriteAck(
      id: ackId,
      event: withEvent ? _placeable(result) : null,
    );
  }

  /// The event row inside a write's answer, when it can be put on a day: an
  /// all-day row with both dates, or a timed row with both `start_utc` and
  /// `end_utc` (the only instants [CalendarEvent.fromToolRow] reads).
  static CalendarEvent? _placeable(Map<String, dynamic> result) {
    final CalendarEvent event;
    try {
      event = CalendarEvent.fromToolRow(result);
    } on FormatException {
      return null;
    }
    final placed = event.isAllDay
        ? event.startDate != null && event.endDate != null
        : event.startUtc != null && event.endUtc != null;
    return placed ? event : null;
  }

  static MeetingTimeSuggestion? _suggestion(Map<String, dynamic> raw) {
    final start = DateTime.tryParse(_str(raw['start_utc']))?.toUtc();
    final end = DateTime.tryParse(_str(raw['end_utc']))?.toUtc();
    if (start == null || end == null) return null;
    final confidence = raw['confidence'];
    return MeetingTimeSuggestion(
      startUtc: start,
      endUtc: end,
      confidence: confidence is num ? confidence.toDouble() : 0,
      organizerAvailability: _str(raw['organizer_availability']),
      attendeeAvailability: {
        for (final a in _list(raw['attendees']))
          if (a is Map && _str(a['address']).isNotEmpty)
            _str(a['address']).toLowerCase(): _str(a['availability']),
      },
      reason: _str(raw['suggestion_reason']),
    );
  }

  static List<Object?> _list(Object? raw) => raw is List ? raw : const [];

  static String _str(Object? raw) => raw is String ? raw : '';

  // ── the one call site ──────────────────────────────────────────────────

  /// Calls [tool] and routes its refusal, if any, to the matching type.
  ///
  /// Keyed on `error` only — `reason` is prose and may change. A tool error or
  /// a transport failure is [CalendarTransient] (retry later); `not_connected`
  /// is [ReconsentRequired], exactly as in the mail backend, and passes
  /// through unwrapped with the other auth failures the client throws.
  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, Object?> args,
  ) async {
    final Map<String, dynamic> result;
    try {
      result = await _mcp.callTool(tool, args);
    } on McpToolException catch (e) {
      throw CalendarTransient(e.message);
    } on McpTransportException catch (e) {
      throw CalendarTransient(e.message, statusCode: e.statusCode);
    }
    final error = result['error'];
    if (error is! String || error.isEmpty) return result;
    final reason = _str(result['reason']);
    switch (error) {
      case 'not_connected':
        throw const ReconsentRequired();
      case 'calendar_scope_missing':
        throw const CalendarScopeMissing();
      case 'mailbox_settings_scope_missing':
        throw const CalendarScopeMissing(CalendarScopeMissing.mailboxSettings);
      case 'cursor_expired' || 'invalid_cursor':
        throw const CalendarCursorExpired();
      case 'event_changed':
        throw const CalendarEventChanged();
      case 'not_organizer':
        throw const CalendarNotOrganizer();
      case 'not_found':
        throw const CalendarEventGone();
      default:
        throw CalendarRefused(error, reason);
    }
  }
}
