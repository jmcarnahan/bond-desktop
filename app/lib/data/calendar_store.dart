import 'package:drift/drift.dart';

import '../models/calendar_models.dart';
import 'database.dart' show BondDatabase;

/// One stored message a calendar event points at: an invite, an update or a
/// cancellation whose `source_meta_json.event_id` names the event.
typedef EventMessageRef = ({
  String source,
  String conversationKey,
  String sourceMessageId,
});

/// The calendar mirror: `calendar_events`, and the one join from it into
/// `messages`.
///
/// A SECOND store over the same [BondDatabase] rather than more methods on the
/// 11,000-line `MessageStore`, because everything here is one mirrored table
/// read by a handful of shapes (a day, the invites owed, the meeting before
/// and after a person) plus one lookup into the messages that carried an
/// invite. Unlike `ContextStore` this IS mailbox data: `calendar_events` sits
/// in `MessageStore.syncedTables`, so a mailbox wipe empties it with the mail
/// and Clear AI results leaves it alone.
///
/// Raw SQL through `customSelect` / `customUpdate`, exactly as `MessageStore`
/// writes it. Instants are compared AS STRINGS: every stamp is written by
/// [calendarStamp] at one fixed width, so lexicographic order is chronological,
/// and every [DateTime] argument goes through the same function before it
/// meets a column. Dates compare as `yyyy-mm-dd` strings for the same reason.
class CalendarStore {
  CalendarStore(this.db);

  final BondDatabase db;

  static List<Variable> _args(List<Object?> values) => [
        for (final value in values) Variable(value),
      ];

  static String _placeholders(int n) => List.filled(n, '?').join(', ');

  /// The column list, read off the model's own row so the INSERT cannot drift
  /// from [CalendarEvent.toDbRow] when a field is added.
  static final List<String> _columns = const CalendarEvent(id: '')
      .toDbRow(syncRun: '', syncedAt: '')
      .keys
      .toList(growable: false);

  static final String _upsertSql = () {
    final updates = [
      for (final c in _columns)
        if (c != 'id') '$c = excluded.$c',
    ].join(', ');
    return 'INSERT INTO calendar_events (${_columns.join(', ')}) '
        'VALUES (${_placeholders(_columns.length)}) '
        'ON CONFLICT(id) DO UPDATE SET $updates';
  }();

  /// Neither a series master nor anything the sync wrote without a way to
  /// place it. A master carries the series' first occurrence's times, and
  /// every real occurrence arrives expanded, so placing the master too would
  /// show the first meeting twice.
  static const String _notMaster = "event_type <> 'seriesMaster'";

  // ── writes ───────────────────────────────────────────────────────────

  /// Upserts [events] by id, tagging each row with [syncRun] and stamping
  /// `synced_at` = now. Ids in [skipIds] are NOT written: they are events
  /// this app wrote a moment ago, and a sync page that started before the
  /// write would put the old version back (the write-sequence guard).
  /// Returns the rows written.
  Future<int> upsertEvents(
    List<CalendarEvent> events, {
    required String syncRun,
    Set<String> skipIds = const {},
  }) async {
    final keep = [
      for (final e in events)
        if (!skipIds.contains(e.id)) e,
    ];
    if (keep.isEmpty) return 0;
    final syncedAt = calendarStamp(DateTime.now());
    await db.transaction(() async {
      for (final event in keep) {
        final row = event.toDbRow(syncRun: syncRun, syncedAt: syncedAt);
        await db.customUpdate(
          _upsertSql,
          variables: _args([for (final c in _columns) row[c]]),
        );
      }
    });
    return keep.length;
  }

  /// Deletes by id. Unknown ids are ignored: `sync_calendar`'s `removed` may
  /// name events this mirror never saw. Returns rows deleted.
  Future<int> deleteEvents(Iterable<String> ids) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return 0;
    var deleted = 0;
    // Chunked well under sqlite's variable limit; `removed` is unbounded.
    for (var i = 0; i < list.length; i += 500) {
      final end = i + 500 > list.length ? list.length : i + 500;
      final chunk = list.sublist(i, end);
      deleted += await db.customUpdate(
        'DELETE FROM calendar_events '
        'WHERE id IN (${_placeholders(chunk.length)})',
        variables: _args(chunk),
      );
    }
    return deleted;
  }

  /// Re-tags the stored rows of [ids] with [runId] without touching anything
  /// else. The write guard's other half: a page that returned an event this
  /// app just wrote does not overwrite it, but the event IS in that run, and
  /// without the tag a sweep long after the guard's span would delete it.
  /// Ids never stored are ignored. Returns rows re-tagged.
  Future<int> retagRun(Iterable<String> ids, String runId) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return 0;
    var tagged = 0;
    // Chunked as [deleteEvents] is, under sqlite's variable limit.
    for (var i = 0; i < list.length; i += 500) {
      final end = i + 500 > list.length ? list.length : i + 500;
      final chunk = list.sublist(i, end);
      tagged += await db.customUpdate(
        'UPDATE calendar_events SET sync_run = ? '
        'WHERE id IN (${_placeholders(chunk.length)})',
        variables: _args([runId, ...chunk]),
      );
    }
    return tagged;
  }

  /// The sweep half of mark-and-sweep: deletes every row a completed run
  /// [runId] did not return, except [keepIds] (rows this app wrote while the
  /// run was in flight, which the run may simply have read too early).
  /// Returns rows deleted.
  Future<int> sweepRun(String runId, {Set<String> keepIds = const {}}) async {
    final keep = keepIds.toList();
    return db.customUpdate(
      'DELETE FROM calendar_events WHERE sync_run <> ?'
      '${keep.isEmpty ? '' : ' AND id NOT IN (${_placeholders(keep.length)})'}',
      variables: _args([runId, ...keep]),
    );
  }

  // ── reads ────────────────────────────────────────────────────────────

  Future<CalendarEvent?> event(String id) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM calendar_events WHERE id = ?',
          variables: _args([id]),
        )
        .get();
    return rows.isEmpty ? null : CalendarEvent.fromDbRow(rows.first.data);
  }

  /// The mirrored occurrences (and exceptions) of the series [seriesMasterId],
  /// by start — what the event panel picks the next one out of when it is
  /// handed a master, whose own times are the series' FIRST meeting.
  ///
  /// Ordered on `COALESCE(start_utc, start_date)`, the key [eventsBetween]
  /// sorts on, so an all-day series and a timed one both come out in date
  /// order. Only what the mirror's window holds: an occurrence months out is
  /// simply not here. An empty id is no series at all.
  Future<List<CalendarEvent>> occurrencesOf(String seriesMasterId) async {
    if (seriesMasterId.isEmpty) return const [];
    final rows = await db
        .customSelect(
          'SELECT * FROM calendar_events WHERE series_master_id = ? '
          'AND $_notMaster '
          'ORDER BY COALESCE(start_utc, start_date), id',
          variables: _args([seriesMasterId]),
        )
        .get();
    return [for (final r in rows) CalendarEvent.fromDbRow(r.data)];
  }

  /// What a span of the display zone holds: timed events overlapping
  /// [startUtc, endUtc) and all-day events overlapping
  /// [fromDate, toDateExclusive).
  ///
  /// Two ranges rather than one because the two kinds of event are two kinds
  /// of value (D13): the caller turns its local midnights into instants for
  /// the timed half and hands the bare dates for the all-day half, so an
  /// all-day event is never converted through a zone and moved a day.
  ///
  /// A zero-length timed event (start == end, a reminder-style block) is
  /// included when its start falls in the span; half-open overlap alone
  /// would drop it. Cancelled events are INCLUDED — the Day stop shows them
  /// struck through and the overlap maths skips them, which is each caller's
  /// call. Series masters are not. All-day first, then by start.
  Future<List<CalendarEvent>> eventsBetween({
    required DateTime startUtc,
    required DateTime endUtc,
    required CalendarDate fromDate,
    required CalendarDate toDateExclusive,
  }) async {
    final start = calendarStamp(startUtc);
    final end = calendarStamp(endUtc);
    final rows = await db
        .customSelect(
          'SELECT * FROM calendar_events WHERE $_notMaster AND ('
          '  (is_all_day = 0 AND start_utc IS NOT NULL AND end_utc IS NOT NULL'
          '   AND ((start_utc < ? AND end_utc > ?)'
          '        OR (start_utc = end_utc AND start_utc >= ? AND start_utc < ?)))'
          '  OR (is_all_day = 1 AND start_date IS NOT NULL AND end_date IS NOT NULL'
          '   AND start_date < ? AND end_date > ?)'
          ') ORDER BY is_all_day DESC, COALESCE(start_utc, start_date), id',
          variables: _args([
            end,
            start,
            start,
            end,
            toDateExclusive.toIso(),
            fromDate.toIso(),
          ]),
        )
        .get();
    return [for (final r in rows) CalendarEvent.fromDbRow(r.data)];
  }

  /// The invites the owner still owes an answer, soonest first.
  ///
  /// [CalendarEvent.needsResponse] spelled in SQL — a null
  /// `response_requested` counts as asked — plus not a series master, and
  /// only what is still ahead: a timed event starting after [nowUtc], or an
  /// all-day one starting [today] or later (today's all-day invite can still
  /// be answered).
  Future<List<CalendarEvent>> invitesOwed({
    required DateTime nowUtc,
    required CalendarDate today,
  }) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM calendar_events WHERE $_notMaster'
          ' AND (response_requested IS NULL OR response_requested = 1)'
          " AND response_status IN ('none', 'notResponded')"
          ' AND is_organizer = 0 AND is_cancelled = 0'
          ' AND ((is_all_day = 0 AND start_utc > ?)'
          '      OR (is_all_day = 1 AND start_date >= ?))',
          variables: _args([calendarStamp(nowUtc), today.toIso()]),
        )
        .get();
    final events = [for (final r in rows) CalendarEvent.fromDbRow(r.data)];
    // Sorted here, not in SQL: an all-day event's key is its date's UTC
    // midnight, and mixing that with a stamp in ORDER BY would compare a
    // 10-character string against a 27-character one.
    DateTime key(CalendarEvent e) =>
        e.startUtc ??
        DateTime.utc(e.startDate!.year, e.startDate!.month, e.startDate!.day);
    events.sort((a, b) {
      final byStart = key(a).compareTo(key(b));
      return byStart != 0 ? byStart : a.id.compareTo(b.id);
    });
    return events;
  }

  /// The next timed meeting with any of [addresses], starting after [nowUtc]:
  /// not cancelled, not declined, and they are an attendee or the organiser.
  Future<CalendarEvent?> nextMeetingWith(
    Iterable<String> addresses, {
    required DateTime nowUtc,
  }) =>
      _meetingWith(
        addresses,
        where: 'start_utc > ?',
        order: 'start_utc ASC',
        nowUtc: nowUtc,
      );

  /// The latest such meeting that ENDED at or before [nowUtc] — "last met".
  Future<CalendarEvent?> lastMetWith(
    Iterable<String> addresses, {
    required DateTime nowUtc,
  }) =>
      _meetingWith(
        addresses,
        where: 'end_utc <= ?',
        order: 'end_utc DESC',
        nowUtc: nowUtc,
      );

  Future<CalendarEvent?> _meetingWith(
    Iterable<String> addresses, {
    required String where,
    required String order,
    required DateTime nowUtc,
  }) async {
    final wanted = {
      for (final a in addresses)
        if (a.trim().isNotEmpty) a.trim().toLowerCase(),
    }.toList();
    if (wanted.isEmpty) return null;
    final places = _placeholders(wanted.length);
    final rows = await db
        .customSelect(
          'SELECT * FROM calendar_events WHERE $_notMaster'
          ' AND is_all_day = 0 AND start_utc IS NOT NULL AND end_utc IS NOT NULL'
          " AND is_cancelled = 0 AND response_status <> 'declined'"
          ' AND $where'
          ' AND (lower(organizer_address) IN ($places)'
          '      OR EXISTS (SELECT 1 FROM json_each(calendar_events.attendees_json)'
          "                 WHERE lower(json_extract(value, '\$.address')) IN ($places)))"
          ' ORDER BY $order, id LIMIT 1',
          variables: _args([calendarStamp(nowUtc), ...wanted, ...wanted]),
        )
        .get();
    return rows.isEmpty ? null : CalendarEvent.fromDbRow(rows.first.data);
  }

  /// The stored messages linked to [eventId] through
  /// `source_meta_json.event_id`, newest first.
  ///
  /// `json_extract` sits inside a CASE on `json_valid`, as
  /// `MessageStore.regateMeetingResponseIds` writes it, because a single
  /// malformed meta blob would otherwise fail the whole statement. A plain
  /// LIKE on the key's quoted name runs first, so the JSON functions only see
  /// the handful of rows that could hold one rather than the whole mailbox.
  Future<List<EventMessageRef>> messagesForEvent(String eventId) async {
    final rows = await db
        .customSelect(
          'SELECT source, conversation_key, source_message_id FROM messages '
          'WHERE source_meta_json LIKE \'%"event_id"%\' '
          'AND (CASE WHEN json_valid(source_meta_json) '
          "THEN json_extract(source_meta_json, '\$.event_id') END) = ? "
          'ORDER BY received_at DESC, source_message_id DESC',
          variables: _args([eventId]),
        )
        .get();
    return [
      for (final r in rows)
        (
          source: r.data['source'] as String,
          conversationKey: r.data['conversation_key'] as String,
          sourceMessageId: r.data['source_message_id'] as String,
        ),
    ];
  }
}
