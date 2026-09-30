import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, listEquals;

/// The calendar's value types: what the bond-mcps calendar tools answer, and
/// what the `calendar_events` mirror stores.
///
/// The time rules these types enforce are the round's (D13), and they exist
/// because every one of them is a bug class somebody has already shipped:
///
/// - A TIMED event is two instants, held as UTC [DateTime]s and stored in the
///   app's one stamp format ([calendarStamp]), so string comparison in SQL
///   stays chronological.
/// - An ALL-DAY event is two [CalendarDate]s with an EXCLUSIVE end, never
///   instants. An all-day event is a date on the wall, not a span of time: a
///   one-day event on Oct 1 is Oct 1 in every zone, and converting its
///   midnight to an instant and back through the viewer's zone moves it to
///   Sep 30 for everyone west of UTC.
/// - Dates are built from components, never by adding a [Duration] to a local
///   time, because a day is not always 24 hours.
///
/// Nothing here imports `lib/data/`: models are the layer below the store.
/// [calendarStamp] therefore repeats `MessageStore.isoStamp`'s algorithm, and
/// `calendar_models_test.dart` pins the two to the same output.

/// An instant in the app's stamp format: UTC, `Z`-suffixed, and exactly SIX
/// fractional digits — byte-identical to `MessageStore.isoStamp`.
///
/// The width is what makes the stamps sort as strings: `toIso8601String`
/// prints three fractional digits when the microseconds are zero and six
/// otherwise, and `Z` sorts after a digit, so mixed widths put an earlier
/// stamp after a later one. A calendar row compared against a message stamp
/// (the Day stop does) must therefore be written at the same width.
String calendarStamp(DateTime t) {
  final iso = t.toUtc().toIso8601String();
  // 'yyyy-MM-ddTHH:mm:ss.mmmZ' is 24 characters; pad the microseconds Dart
  // left off because they were zero. Anything else is already full width.
  return iso.length == 24 ? '${iso.substring(0, 23)}000Z' : iso;
}

/// A date on the wall — no time, no zone. The unit an all-day event is made
/// of, and the unit a person means by "Thursday".
///
/// A value class rather than a [DateTime] at midnight, because a midnight
/// [DateTime] is an instant and invites exactly the conversion that moves an
/// all-day event a day: pass it through `toLocal()` west of UTC and Thursday
/// becomes Wednesday. Nothing here has a zone to convert through.
@immutable
class CalendarDate implements Comparable<CalendarDate> {
  final int year;
  final int month;
  final int day;

  const CalendarDate(this.year, this.month, this.day);

  static final RegExp _iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// A `yyyy-mm-dd` string, or null for anything else — including a date that
  /// does not exist (`2026-02-30`), which would otherwise be silently rolled
  /// into March by [DateTime]'s component arithmetic.
  static CalendarDate? tryParse(String? s) {
    if (s == null) return null;
    final match = _iso.firstMatch(s.trim());
    if (match == null) return null;
    final y = int.parse(match.group(1)!);
    final m = int.parse(match.group(2)!);
    final d = int.parse(match.group(3)!);
    if (m < 1 || m > 12 || d < 1) return null;
    final check = DateTime.utc(y, m, d);
    if (check.year != y || check.month != m || check.day != d) return null;
    return CalendarDate(y, m, d);
  }

  /// The year, month and day of [t] exactly as [t] states them — no zone
  /// conversion. Hand it a `TZDateTime` in the display zone to get "the day
  /// it is there"; hand it a UTC [DateTime] to get the UTC day.
  static CalendarDate ofDateTime(DateTime t) =>
      CalendarDate(t.year, t.month, t.day);

  /// `yyyy-mm-dd`, zero-padded: the storage form and the wire form.
  String toIso() => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// The date [n] days later (earlier when negative), computed from
  /// components in UTC, where every day is 24 hours — never by adding a
  /// [Duration] to a local time, which crosses a DST change an hour short.
  CalendarDate addDays(int n) {
    final t = DateTime.utc(year, month, day + n);
    return CalendarDate(t.year, t.month, t.day);
  }

  /// ISO weekday, Monday = 1 … Sunday = 7, as [DateTime.weekday] numbers it.
  int get weekday => DateTime.utc(year, month, day).weekday;

  bool isBefore(CalendarDate other) => compareTo(other) < 0;

  bool isAfter(CalendarDate other) => compareTo(other) > 0;

  @override
  int compareTo(CalendarDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => toIso();
}

/// One invitee of an event, as the tool rows list them:
/// `{name, address, type, response}`.
@immutable
class Attendee {
  final String name;

  /// Lowercased on the way in, so two spellings of one mailbox are one
  /// person and an address compares against `notifies` (which the server
  /// lowercases) without a second normalisation.
  final String address;

  /// `required`, `optional` or `resource`; `''` when the row did not say.
  final String type;

  /// Their RSVP: `none`, `accepted`, `tentativelyAccepted`, `declined`, …
  /// The server defaults it to `none`, and so does this.
  final String response;

  const Attendee({
    required this.name,
    required this.address,
    this.type = '',
    this.response = 'none',
  });

  factory Attendee.fromJson(Map<String, dynamic> json) => Attendee(
        name: _str(json['name']),
        address: _str(json['address']).toLowerCase(),
        type: _str(json['type']),
        response: _str(json['response'], fallback: 'none'),
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'address': address,
        'type': type,
        'response': response,
      };

  @override
  bool operator ==(Object other) =>
      other is Attendee &&
      other.name == name &&
      other.address == address &&
      other.type == type &&
      other.response == response;

  @override
  int get hashCode => Object.hash(name, address, type, response);
}

/// One event on the primary calendar, as `sync_calendar` /
/// `get_calendar_event` / a write ack describe it, and as the
/// `calendar_events` table stores it.
///
/// Exactly one pair of the time fields is set, and [isAllDay] says which:
/// a timed event has [startUtc]/[endUtc] and null dates; an all-day event has
/// [startDate]/[endDate] (end EXCLUSIVE) and null instants. A timed row whose
/// instants could not be read has both null, and the caller skips it — it
/// cannot be placed on a day, and guessing would place it on the wrong one.
@immutable
class CalendarEvent {
  final String id;

  /// The series master's id for an `occurrence` or `exception`, else `''`.
  final String seriesMasterId;

  final String icalUid;

  /// `singleInstance`, `occurrence`, `exception`, `seriesMaster`, or `''`.
  final String eventType;

  final String subject;
  final String location;
  final String organizerName;
  final String organizerAddress;
  final bool isOrganizer;
  final bool isAllDay;
  final bool isCancelled;

  /// Timed events only; UTC ([DateTime.isUtc] is true).
  final DateTime? startUtc;
  final DateTime? endUtc;

  /// All-day events only; [endDate] is EXCLUSIVE.
  final CalendarDate? startDate;
  final CalendarDate? endDate;

  /// `free`, `tentative`, `busy`, `oof`, `workingElsewhere`, `unknown`, or
  /// `''`.
  final String showAs;

  /// The signed-in user's own RSVP; `none` when unknown.
  final String responseStatus;

  /// Null when Graph sent none — which is NOT the same claim as false: only
  /// an explicit false means the organiser asked for no reply.
  final bool? responseRequested;

  /// Null when Graph sent none; only an explicit false forbids proposing a
  /// new time.
  final bool? allowNewTimeProposals;

  final String sensitivity;

  /// The Teams (or other online-meeting) join link — `join_url`, never the
  /// legacy `online_url`, which is null for Teams.
  final String joinUrl;

  final String webLink;

  /// What `manage_event update` must send as `if_match`. Replaced by the one
  /// every successful update returns.
  final String changeKey;

  final List<Attendee> attendees;
  final List<String> categories;
  final bool? isReminderOn;
  final int? reminderMinutes;

  /// UNTRUSTED text written by whoever organised the meeting: shown as plain
  /// text only, and fenced with `wrapUntrusted` before any model reads it.
  final String bodyPreview;

  const CalendarEvent({
    required this.id,
    this.seriesMasterId = '',
    this.icalUid = '',
    this.eventType = '',
    this.subject = '',
    this.location = '',
    this.organizerName = '',
    this.organizerAddress = '',
    this.isOrganizer = false,
    this.isAllDay = false,
    this.isCancelled = false,
    this.startUtc,
    this.endUtc,
    this.startDate,
    this.endDate,
    this.showAs = '',
    this.responseStatus = 'none',
    this.responseRequested,
    this.allowNewTimeProposals,
    this.sensitivity = '',
    this.joinUrl = '',
    this.webLink = '',
    this.changeKey = '',
    this.attendees = const [],
    this.categories = const [],
    this.isReminderOn,
    this.reminderMinutes,
    this.bodyPreview = '',
  });

  /// An event row from any calendar tool (handoff §3.1's "event row").
  ///
  /// Instants come from `start_utc`/`end_utc` only. When one is `""` (Graph
  /// answered in another zone, a write's UTC re-read failed) the timed row
  /// stays unplaced — null instants — and the next sync brings it. The
  /// legacy naive `start`/`end` are never read: they are UTC on a read but
  /// echo the REQUEST zone on a create, and a row cannot say which it is.
  ///
  /// A missing optional key is its empty default; only a missing or empty
  /// `id` is a [FormatException], because a row with no id cannot be stored,
  /// updated or removed.
  factory CalendarEvent.fromToolRow(Map<String, dynamic> row) {
    final id = _str(row['id']);
    if (id.isEmpty) {
      throw const FormatException('A calendar event row has no id.');
    }
    final isAllDay = _bool(row['is_all_day']);
    final organizer = row['organizer'];
    final organizerName = organizer is String && organizer.isNotEmpty
        ? organizer
        : _str(row['organizer_name']);
    return CalendarEvent(
      id: id,
      seriesMasterId: _str(row['series_master_id']),
      icalUid: _str(row['ical_uid']),
      eventType: _str(row['type']),
      subject: _str(row['subject']),
      location: _str(row['location']),
      organizerName: organizerName,
      organizerAddress: _str(row['organizer_address']).toLowerCase(),
      isOrganizer: _bool(row['is_organizer']),
      isAllDay: isAllDay,
      isCancelled: _bool(row['is_cancelled']),
      startUtc: isAllDay ? null : _instant(row['start_utc']),
      endUtc: isAllDay ? null : _instant(row['end_utc']),
      startDate: isAllDay ? CalendarDate.tryParse(_str(row['start_date'])) : null,
      endDate: isAllDay ? CalendarDate.tryParse(_str(row['end_date'])) : null,
      showAs: _str(row['show_as']),
      responseStatus: _str(row['response_status'], fallback: 'none'),
      responseRequested: _nullableBool(row['response_requested']),
      allowNewTimeProposals: _nullableBool(row['allow_new_time_proposals']),
      sensitivity: _str(row['sensitivity']),
      joinUrl: _str(row['join_url']),
      webLink: _str(row['web_link']),
      changeKey: _str(row['change_key']),
      attendees: _attendees(row['attendees']),
      categories: _strings(row['categories']),
      isReminderOn: _nullableBool(row['is_reminder_on']),
      reminderMinutes: _nullableInt(row['reminder_minutes']),
      bodyPreview: _str(row['body_preview']),
    );
  }

  /// A `calendar_events` row. The column names are the table's, exactly.
  factory CalendarEvent.fromDbRow(Map<String, Object?> row) {
    return CalendarEvent(
      id: _str(row['id']),
      seriesMasterId: _str(row['series_master_id']),
      icalUid: _str(row['ical_uid']),
      eventType: _str(row['event_type']),
      subject: _str(row['subject']),
      location: _str(row['location']),
      organizerName: _str(row['organizer_name']),
      organizerAddress: _str(row['organizer_address']),
      isOrganizer: _bool(row['is_organizer']),
      isAllDay: _bool(row['is_all_day']),
      isCancelled: _bool(row['is_cancelled']),
      startUtc: _stampOrNull(row['start_utc']),
      endUtc: _stampOrNull(row['end_utc']),
      startDate: CalendarDate.tryParse(row['start_date'] as String?),
      endDate: CalendarDate.tryParse(row['end_date'] as String?),
      showAs: _str(row['show_as']),
      responseStatus: _str(row['response_status'], fallback: 'none'),
      responseRequested: _nullableBool(row['response_requested']),
      allowNewTimeProposals: _nullableBool(row['allow_new_time_proposals']),
      sensitivity: _str(row['sensitivity']),
      joinUrl: _str(row['join_url']),
      webLink: _str(row['web_link']),
      changeKey: _str(row['change_key']),
      attendees: _attendees(_decodeJson(row['attendees_json'])),
      categories: _strings(_decodeJson(row['categories_json'])),
      isReminderOn: _nullableBool(row['is_reminder_on']),
      reminderMinutes: _nullableInt(row['reminder_minutes']),
      bodyPreview: _str(row['body_preview']),
    );
  }

  /// The `calendar_events` row for this event. [syncRun] tags the sync run
  /// that last saw it (the mark in mark-and-sweep); [syncedAt] is a stamp.
  Map<String, Object?> toDbRow({
    required String syncRun,
    required String syncedAt,
  }) =>
      {
        'id': id,
        'series_master_id': seriesMasterId,
        'ical_uid': icalUid,
        'event_type': eventType,
        'subject': subject,
        'location': location,
        'organizer_name': organizerName,
        'organizer_address': organizerAddress,
        'is_organizer': isOrganizer ? 1 : 0,
        'is_all_day': isAllDay ? 1 : 0,
        'is_cancelled': isCancelled ? 1 : 0,
        'start_utc': startUtc == null ? null : calendarStamp(startUtc!),
        'end_utc': endUtc == null ? null : calendarStamp(endUtc!),
        'start_date': startDate?.toIso(),
        'end_date': endDate?.toIso(),
        'show_as': showAs,
        'response_status': responseStatus,
        'response_requested': _boolColumn(responseRequested),
        'allow_new_time_proposals': _boolColumn(allowNewTimeProposals),
        'sensitivity': sensitivity,
        'join_url': joinUrl,
        'web_link': webLink,
        'change_key': changeKey,
        'attendees_json': jsonEncode([for (final a in attendees) a.toJson()]),
        'categories_json': jsonEncode(categories),
        'is_reminder_on': _boolColumn(isReminderOn),
        'reminder_minutes': reminderMinutes,
        'body_preview': bodyPreview,
        'sync_run': syncRun,
        'synced_at': syncedAt,
      };

  bool get isTimed => !isAllDay;

  bool get isSeriesMaster => eventType == 'seriesMaster';

  /// The Teams meeting chat's thread id (`19:meeting_…@thread.v2`), read out
  /// of [joinUrl] — or null.
  ///
  /// Parsed ONLY when the URL-encoded form `19%3ameeting_…%40thread.v2` is in
  /// the link: a short link (`teams.microsoft.com/meet/…`) carries no thread
  /// id, and anything guessed from one would open the wrong chat.
  String? get teamsThreadId {
    final match = _teamsThread.firstMatch(joinUrl);
    if (match == null) return null;
    try {
      return Uri.decodeComponent(match.group(0)!);
    } on ArgumentError {
      return null;
    }
  }

  static final RegExp _teamsThread =
      RegExp(r'19%3ameeting_[A-Za-z0-9_\-%]+?%40thread\.v2', caseSensitive: false);

  /// Whether the signed-in user still owes this invite an answer.
  ///
  /// `responseRequested` null counts as requested — only an explicit false
  /// means the organiser asked for none. Your own meetings and cancelled ones
  /// never need a reply.
  bool get needsResponse =>
      responseRequested != false &&
      (responseStatus == 'none' || responseStatus == 'notResponded') &&
      !isOrganizer &&
      !isCancelled;

  List<Object?> get _props => [
        id,
        seriesMasterId,
        icalUid,
        eventType,
        subject,
        location,
        organizerName,
        organizerAddress,
        isOrganizer,
        isAllDay,
        isCancelled,
        startUtc,
        endUtc,
        startDate,
        endDate,
        showAs,
        responseStatus,
        responseRequested,
        allowNewTimeProposals,
        sensitivity,
        joinUrl,
        webLink,
        changeKey,
        isReminderOn,
        reminderMinutes,
        bodyPreview,
      ];

  @override
  bool operator ==(Object other) =>
      other is CalendarEvent &&
      listEquals(other._props, _props) &&
      listEquals(other.attendees, attendees) &&
      listEquals(other.categories, categories);

  @override
  int get hashCode => Object.hashAll([
        ..._props,
        Object.hashAll(attendees),
        Object.hashAll(categories),
      ]);

  @override
  String toString() => 'CalendarEvent($id)';
}

/// `get_mailbox_settings`, the parts the calendar reads: the zone, the working
/// hours and whether an auto-reply is on.
@immutable
class MailboxSettings {
  /// The mailbox zone's Windows name ("Pacific Standard Time"). This, not the
  /// IANA name, is what an all-day write sends as `start_timezone`.
  final String timeZone;

  /// Its CLDR mapping ("America/Los_Angeles"), or `''` when the server had no
  /// mapping — in which case nothing guesses one.
  final String timeZoneIana;

  /// Graph's lowercase day names (`monday`, …).
  final List<String> workingDays;

  /// `HH:MM:SS` on the working zone's wall clock, or `''` when unknown.
  final String workingStart;
  final String workingEnd;

  final String workingZoneIana;

  /// `disabled`, `alwaysEnabled` or `scheduled`.
  final String autoReplyStatus;

  const MailboxSettings({
    this.timeZone = '',
    this.timeZoneIana = '',
    this.workingDays = const [],
    this.workingStart = '',
    this.workingEnd = '',
    this.workingZoneIana = '',
    this.autoReplyStatus = 'disabled',
  });

  /// The tool's answer (handoff §3.9).
  factory MailboxSettings.fromToolRow(Map<String, dynamic> row) {
    final hours = _map(row['working_hours']);
    final replies = _map(row['automatic_replies']);
    return MailboxSettings(
      timeZone: _str(row['time_zone']),
      timeZoneIana: _str(row['time_zone_iana']),
      workingDays: _strings(hours['days_of_week']),
      workingStart: _str(hours['start_time']),
      workingEnd: _str(hours['end_time']),
      workingZoneIana: _str(hours['time_zone_iana']),
      autoReplyStatus: _str(replies['status'], fallback: 'disabled'),
    );
  }

  /// The cached form (an `app_prefs` value). Its own keys, not the tool's,
  /// so a server rename cannot corrupt what is already stored.
  factory MailboxSettings.fromJson(Map<String, dynamic> json) =>
      MailboxSettings(
        timeZone: _str(json['timeZone']),
        timeZoneIana: _str(json['timeZoneIana']),
        workingDays: _strings(json['workingDays']),
        workingStart: _str(json['workingStart']),
        workingEnd: _str(json['workingEnd']),
        workingZoneIana: _str(json['workingZoneIana']),
        autoReplyStatus: _str(json['autoReplyStatus'], fallback: 'disabled'),
      );

  Map<String, Object?> toJson() => {
        'timeZone': timeZone,
        'timeZoneIana': timeZoneIana,
        'workingDays': workingDays,
        'workingStart': workingStart,
        'workingEnd': workingEnd,
        'workingZoneIana': workingZoneIana,
        'autoReplyStatus': autoReplyStatus,
      };

  @override
  bool operator ==(Object other) =>
      other is MailboxSettings &&
      other.timeZone == timeZone &&
      other.timeZoneIana == timeZoneIana &&
      listEquals(other.workingDays, workingDays) &&
      other.workingStart == workingStart &&
      other.workingEnd == workingEnd &&
      other.workingZoneIana == workingZoneIana &&
      other.autoReplyStatus == autoReplyStatus;

  @override
  int get hashCode => Object.hash(timeZone, timeZoneIana,
      Object.hashAll(workingDays), workingStart, workingEnd, workingZoneIana,
      autoReplyStatus);
}

/// One `sync_calendar` answer.
@immutable
class CalendarSyncPage {
  /// Added or changed rows, one per id.
  final List<CalendarEvent> events;

  /// Ids deleted or moved out of the window. May name ids never seen locally;
  /// the caller ignores those.
  final List<String> removed;

  /// Pass back verbatim. `''` together with [complete] means "start a new
  /// run".
  final String cursor;

  /// False means "call again NOW with [cursor]".
  final bool complete;

  /// The run's window as UTC `…Z` instants — reported on a FIRST call only,
  /// `''` on every continuation, so the caller persists the first answer.
  final String windowStart;
  final String windowEnd;

  const CalendarSyncPage({
    this.events = const [],
    this.removed = const [],
    this.cursor = '',
    this.complete = true,
    this.windowStart = '',
    this.windowEnd = '',
  });
}

/// One `find_meeting_times` suggestion.
@immutable
class MeetingTimeSuggestion {
  final DateTime startUtc;
  final DateTime endUtc;

  /// 0..100, Graph's own.
  final double confidence;

  final String organizerAvailability;

  /// Lowercased address → Graph's availability word. Empty when you are the
  /// only attendee.
  final Map<String, String> attendeeAvailability;

  final String reason;

  const MeetingTimeSuggestion({
    required this.startUtc,
    required this.endUtc,
    this.confidence = 0,
    this.organizerAvailability = '',
    this.attendeeAvailability = const {},
    this.reason = '',
  });
}

/// What a calendar write answered: a [WritePreview] for a dry run, an
/// [EventWriteAck] for the real thing.
sealed class CalendarWriteResult {
  const CalendarWriteResult();
}

/// A dry run's answer: what WOULD be sent, and who would be emailed.
///
/// [notifies] is the list the inline confirm shows — "this emails Dana and
/// Sam" — so a write that emails anybody is never a surprise (D5).
final class WritePreview extends CalendarWriteResult {
  final String method;
  final String path;
  final Map<String, Object?>? payload;

  /// Lowercased, de-duplicated addresses Graph would email.
  final List<String> notifies;

  /// `update` only: the etag the real write would send.
  final String? ifMatch;

  const WritePreview({
    required this.method,
    required this.path,
    this.payload,
    this.notifies = const [],
    this.ifMatch,
  });
}

/// A real write's answer.
final class EventWriteAck extends CalendarWriteResult {
  final String id;

  /// The event as it now stands — set for `update` and `create` when the
  /// answer carried a placeable row (an instant, or dates for an all-day
  /// event); null for `respond`, `cancel`, `delete`, and a create whose UTC
  /// re-read failed (the next sync brings it).
  final CalendarEvent? event;

  const EventWriteAck({required this.id, this.event});
}

// ── pre-meeting briefs ───────────────────────────────────────────────────

/// One thread a brief can point at, stored INSIDE the brief so the panel can
/// link a point to its thread without gathering the inputs again.
///
/// [subject] is the sender's text and is shown as plain text only.
@immutable
class BriefThreadRef {
  final String source;
  final String conversationKey;
  final String subject;

  const BriefThreadRef({
    required this.source,
    required this.conversationKey,
    required this.subject,
  });

  Map<String, Object?> toJson() => {
        'source': source,
        'conversation_key': conversationKey,
        'subject': subject,
      };

  static BriefThreadRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['conversation_key'];
    if (key is! String || key.isEmpty) return null;
    return BriefThreadRef(
      source: _str(raw['source'], fallback: 'email'),
      conversationKey: key,
      subject: _str(raw['subject']),
    );
  }
}

/// One line of a brief. [thread] is a 0-based index into
/// [MeetingBrief.threads], or -1 when the line names no thread.
@immutable
class BriefPoint {
  final String text;
  final int thread;

  const BriefPoint({required this.text, this.thread = -1});

  Map<String, Object?> toJson() => {'text': text, 'thread': thread};
}

/// Something an attendee asked the owner that is still open. [thread] is
/// 0-based, or -1.
@immutable
class BriefAskOut {
  final String person;
  final String ask;
  final int thread;

  const BriefAskOut({required this.person, required this.ask, this.thread = -1});

  Map<String, Object?> toJson() => {
        'person': person,
        'ask': ask,
        'thread': thread,
      };
}

/// A written pre-meeting brief: what the generative model said, validated,
/// plus the thread list its indices point into.
///
/// Lives with the calendar models rather than beside its task because the
/// stored row decodes into it ([EventBrief.brief]) and models may not import
/// upward into `services/`. The task file builds it; everything that draws it
/// reads it from here.
@immutable
class MeetingBrief {
  final String headline;
  final List<BriefPoint> points;
  final List<BriefAskOut> openAsks;
  final List<String> prep;

  /// The numbered threads the model was shown, in the order it was shown
  /// them. Empty on what the task returns; the handler attaches the list
  /// before storing, because only it holds the gathered input.
  final List<BriefThreadRef> threads;

  const MeetingBrief({
    required this.headline,
    this.points = const [],
    this.openAsks = const [],
    this.prep = const [],
    this.threads = const [],
  });

  MeetingBrief withThreads(List<BriefThreadRef> threads) => MeetingBrief(
        headline: headline,
        points: points,
        openAsks: openAsks,
        prep: prep,
        threads: threads,
      );

  /// The thread [index] names, or null for -1 or an index the stored list
  /// does not hold (a row written by an older build).
  BriefThreadRef? threadAt(int index) =>
      index >= 0 && index < threads.length ? threads[index] : null;

  Map<String, Object?> toJson() => {
        'headline': headline,
        'points': [for (final p in points) p.toJson()],
        'open_asks': [for (final a in openAsks) a.toJson()],
        'prep': prep,
        'threads': [for (final t in threads) t.toJson()],
      };

  /// Tolerant: a stored blob is this app's own writing, but a row from an
  /// older build or a hand-edited database must still draw something rather
  /// than throw inside a panel.
  factory MeetingBrief.fromJson(Map<String, dynamic> json) {
    int index(Object? raw) => raw is int ? raw : (raw is num ? raw.toInt() : -1);
    return MeetingBrief(
      headline: _str(json['headline']),
      points: [
        for (final p in json['points'] is List ? json['points'] as List : const [])
          if (p is Map && _str(p['text']).isNotEmpty)
            BriefPoint(text: _str(p['text']), thread: index(p['thread'])),
      ],
      openAsks: [
        for (final a
            in json['open_asks'] is List ? json['open_asks'] as List : const [])
          if (a is Map && _str(a['ask']).isNotEmpty)
            BriefAskOut(
              person: _str(a['person']),
              ask: _str(a['ask']),
              thread: index(a['thread']),
            ),
      ],
      prep: _strings(json['prep']),
      threads: [
        for (final t
            in json['threads'] is List ? json['threads'] as List : const [])
          ?BriefThreadRef.fromJson(t),
      ],
    );
  }

  static MeetingBrief? tryDecode(String? raw) {
    final decoded = _decodeJson(raw);
    if (decoded is! Map) return null;
    return MeetingBrief.fromJson(Map<String, dynamic>.from(decoded));
  }
}

/// One `event_briefs` row: the brief for one event (an occurrence id, never a
/// series master's), or why there is none.
///
/// [status] is `ready`, `failed` or `skipped`. A skipped row's [inputsHash] is
/// `ineligible:<why>` ([skipReason]), so the panel can say which rule kept the
/// meeting out without gathering again. A DERIVED table: Clear AI results
/// empties it and the next calendar sync plans the briefs again.
@immutable
class EventBrief {
  static const String ready = 'ready';
  static const String failed = 'failed';
  static const String skipped = 'skipped';

  /// The prefix a skipped row's hash carries before the reason word.
  static const String ineligiblePrefix = 'ineligible:';

  final String eventId;
  final String inputsHash;
  final String status;
  final String? briefJson;
  final String model;

  /// A [calendarStamp].
  final String generatedAt;

  const EventBrief({
    required this.eventId,
    required this.inputsHash,
    required this.status,
    this.briefJson,
    this.model = '',
    required this.generatedAt,
  });

  factory EventBrief.fromDbRow(Map<String, Object?> row) => EventBrief(
        eventId: _str(row['event_id']),
        inputsHash: _str(row['inputs_hash']),
        status: _str(row['status']),
        briefJson: row['brief_json'] as String?,
        model: _str(row['model']),
        generatedAt: _str(row['generated_at']),
      );

  bool get isReady => status == ready;

  /// The decoded brief, for a ready row only.
  MeetingBrief? get brief => isReady ? MeetingBrief.tryDecode(briefJson) : null;

  DateTime? get generatedAtUtc => _stampOrNull(generatedAt);

  /// The reason word of a skipped row (`no_mail`, `no_others`, …), else null.
  String? get skipReason => status == skipped &&
          inputsHash.startsWith(ineligiblePrefix)
      ? inputsHash.substring(ineligiblePrefix.length)
      : null;
}

/// What the event panel's Brief section draws from: the stored row (null when
/// none), whether a brief is queued or being written, and whether the
/// processing switch is on.
@immutable
class EventBriefView {
  final EventBrief? brief;
  final bool queued;
  final bool processingOn;

  const EventBriefView({
    this.brief,
    this.queued = false,
    this.processingOn = true,
  });
}

// ── tolerant readers ─────────────────────────────────────────────────────

String _str(Object? raw, {String fallback = ''}) =>
    raw is String && raw.isNotEmpty ? raw : fallback;

bool _bool(Object? raw) => raw == true || raw == 1;

bool? _nullableBool(Object? raw) {
  if (raw is bool) return raw;
  if (raw is int) return raw != 0;
  return null;
}

int? _nullableInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return null;
}

int? _boolColumn(bool? value) => value == null ? null : (value ? 1 : 0);

Map<String, dynamic> _map(Object? raw) =>
    raw is Map ? Map<String, dynamic>.from(raw) : const {};

List<String> _strings(Object? raw) => [
      for (final item in raw is List ? raw : const [])
        if (item is String && item.isNotEmpty) item,
    ];

List<Attendee> _attendees(Object? raw) => [
      for (final item in raw is List ? raw : const [])
        if (item is Map) Attendee.fromJson(Map<String, dynamic>.from(item)),
    ];

Object? _decodeJson(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

/// A stored stamp, back to a UTC instant.
DateTime? _stampOrNull(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// A tool instant: the `…Z` [utc] the server gave, or null when it gave
/// none (never the legacy naive `start`/`end`; see
/// [CalendarEvent.fromToolRow]).
DateTime? _instant(Object? utc) {
  if (utc is String && utc.isNotEmpty) {
    final parsed = DateTime.tryParse(utc);
    if (parsed != null) return parsed.toUtc();
  }
  return null;
}
