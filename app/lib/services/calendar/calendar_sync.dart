import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/calendar_models.dart';
import '../activity_log.dart';
import '../backend/backend_types.dart' show NotSignedIn, ReconsentRequired;
import '../backend/calendar_backend.dart';
import '../backend/calendar_errors.dart';

/// How one [CalendarSync.syncNow] ended.
enum CalendarSyncStatus {
  /// The page loop ran — complete or not — without an error.
  synced,

  /// Throttled, so nothing was asked of the backend; or superseded — a wipe
  /// or a newer run replaced the run this tick was writing, and it wrote
  /// nothing (the generation check).
  skipped,

  /// The grant lacks the calendar scope; reconnecting would fix it.
  scopeMissing,

  /// SDK mode, which has no calendar (D11).
  sdkMode,

  /// No calendar right now: signed out, reconsent owed, or the backend has
  /// none.
  unavailable,

  /// Anything else — a transport drop, a Graph 5xx. Retried next tick.
  failed,
}

/// What the Day stop and the Today section say about the calendar as a whole.
enum CalendarAvailability { unknown, available, scopeMissing, sdkMode, unavailable }

@immutable
class CalendarSyncOutcome {
  const CalendarSyncOutcome(
    this.status, {
    this.upserts = 0,
    this.removed = 0,
    this.swept = 0,
    this.pages = 0,
    this.newRun = false,
    this.complete = false,
    this.settingsRefreshed = false,
    this.message,
  });

  final CalendarSyncStatus status;

  /// Rows written from `events`.
  final int upserts;

  /// Rows deleted from `removed` (unknown ids are not counted).
  final int removed;

  /// Rows the completing run's sweep deleted.
  final int swept;

  /// `sync_calendar` pages read this tick.
  final int pages;

  /// Whether this tick started a run (no cursor, a rolled window, or a
  /// cursor that expired).
  final bool newRun;

  /// Whether the run reached `complete: true` this tick.
  final bool complete;

  /// Whether this tick wrote the mailbox-settings cache. The zone's readers
  /// watch the same revision as the mirror's, so a first fetch after a quiet
  /// tick still reaches them.
  final bool settingsRefreshed;

  /// The failure's type name, for `failed` only — never its text, which can
  /// carry an endpoint.
  final String? message;

  /// Whether a reader of the mirror has anything new to read.
  bool get changed => upserts > 0 || removed > 0 || swept > 0;

  CalendarSyncOutcome _withSettingsRefreshed() => CalendarSyncOutcome(
        status,
        upserts: upserts,
        removed: removed,
        swept: swept,
        pages: pages,
        newRun: newRun,
        complete: complete,
        settingsRefreshed: true,
        message: message,
      );

  @override
  String toString() => 'CalendarSyncOutcome(${status.name}, upserts: '
      '$upserts, removed: $removed, swept: $swept, pages: $pages)';
}

/// What a sync's precheck answers before any backend call: [sdkMode] has no
/// calendar (D11), a grant holding `calendars.read` goes on (null), and a
/// grant without it is `scopeMissing` only when the session can still answer
/// `mail.read`.
///
/// The `read_ack_queue` idiom (`_resolveGate`): `hasScope` answers false both
/// when the grant lacks the scope and when the probe could not reach the
/// server, and only the first is fixed by reconnecting. `mail.read` is the
/// baseline every usable session carries, so a session that cannot answer it
/// cannot answer anything, and its calendar is `unavailable` for now rather
/// than a permission to ask for. A throw reads the same way.
Future<CalendarSyncStatus?> calendarPrecheck(
  bool sdkMode,
  Future<bool> Function(String scope) hasScope,
) async {
  if (sdkMode) return CalendarSyncStatus.sdkMode;
  try {
    if (await hasScope('calendars.read')) return null;
    return await hasScope('mail.read')
        ? CalendarSyncStatus.scopeMissing
        : CalendarSyncStatus.unavailable;
  } on Object {
    return CalendarSyncStatus.unavailable;
  }
}

/// Thrown inside a page's transaction when the stored run is no longer the
/// tick's: a wipe deleted it, or a newer tick replaced it. Nothing was written
/// yet (the check is the transaction's first statement), and the tick ends
/// `skipped`.
class _Superseded implements Exception {
  const _Superseded();
}

/// The calendar mirror's run: the window it covers, the id rows are marked
/// with, and whether the completed run has been swept.
@immutable
class _RunState {
  const _RunState({
    required this.start,
    required this.end,
    required this.run,
    required this.swept,
  });

  /// Wire strings (`YYYY-MM-DDT00:00:00Z`), kept verbatim so a restart after
  /// an expired cursor sends the server exactly the window it fixed.
  final String start;
  final String end;
  final String run;
  final bool swept;

  static _RunState? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final start = json['start'];
      final end = json['end'];
      final run = json['run'];
      if (start is! String || end is! String || run is! String) return null;
      if (DateTime.tryParse(start) == null || DateTime.tryParse(end) == null) {
        return null;
      }
      if (run.isEmpty) return null;
      return _RunState(
        start: start,
        end: end,
        run: run,
        swept: json['swept'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  DateTime get startInstant => DateTime.parse(start).toUtc();

  _RunState copyWith({String? start, String? end, String? run, bool? swept}) =>
      _RunState(
        start: start ?? this.start,
        end: end ?? this.end,
        run: run ?? this.run,
        swept: swept ?? this.swept,
      );

  String toJson() =>
      jsonEncode({'start': start, 'end': end, 'run': run, 'swept': swept});
}

/// Keeps `calendar_events` a mirror of the primary calendar over a rolling
/// window, through bond-mcps `sync_calendar` (docs/pipeline/14-calendar.md).
///
/// **The run.** A run is one full read of a fixed window — 30 days back to
/// 120 ahead at UTC midnights — followed by delta pages for as long as its
/// cursor lives. Every row a run returns is tagged with the run's id, so when
/// a FIRST read completes, everything not tagged is something the calendar no
/// longer holds, and the sweep deletes it. The window is fixed by the first
/// call and the server echoes it only then, so it lives in `app_prefs`
/// ([calendarRunKey]) with the run id; the cursor lives in `sync_state`
/// beside the mail cursors, which is what makes `wipeAll` and a forget clear
/// it with them. The window rolls weekly: a run whose start is more than
/// [pastDays] + [rollDays] back is abandoned for a new one.
///
/// **One tick** reads at most [maxPagesPerTick] pages and persists the cursor
/// after every one, so a failure keeps what was read and a big first read
/// spreads across ticks. A page whose cursor is the one just sent, not
/// complete, is the server saying a later Graph page failed — stop and try
/// that link next tick.
///
/// **Never throws, never blocks mail.** Every failure becomes an outcome. The
/// inbox runs this fire-and-forget after the mail load, throttled to
/// [throttle] after ANY answer — a failure, a missing scope and SDK mode
/// included, so a broken calendar is not asked every poll — unless forced,
/// single-flight so an overlapping refresh joins
/// the tick already running.
///
/// **The write guard.** A write this app makes (Phase 5) calls [noteWrite]
/// and stores the server's answer itself; a sync page that was requested
/// before the write landed would put the old version back, so ids noted at or
/// after that page's request are not upserted. Their stored rows are re-tagged
/// with the run instead, so the sweep never deletes the app's own write; ids
/// noted within [writeGuardSpan] are also kept by a sweep, as a belt.
///
/// **The generation check.** Every write a page makes — events, cursor, run
/// state, sweep — is ONE transaction whose first statement re-reads
/// [calendarRunKey] and abandons the tick, writing nothing, unless it still
/// names this tick's run. `wipeAll` deletes that pref inside its own
/// transaction, so the two serialize: a tick in flight across a wipe (or
/// across a rebuild of the provider, whose fresh sync starts its own run)
/// cannot write the old account's rows back.
class CalendarSync {
  CalendarSync(
    this._backend,
    this._store,
    this._calendar, {
    ActivityLog? activityLog,
    DateTime Function()? clock,
    this._precheck,
    this.onOutcome,
  })  : _activity = activityLog ?? ActivityLog.disabled(),
        _clock = clock ?? DateTime.now;

  final CalendarBackend _backend;
  final MessageStore _store;
  final CalendarStore _calendar;
  final ActivityLog _activity;
  final DateTime Function() _clock;

  /// Answers a status before any backend call when there is no calendar to
  /// ask (SDK mode, a grant without the scope), so those cost no request.
  final Future<CalendarSyncStatus?> Function()? _precheck;

  /// Told what every tick that reached an answer found, after [lastOutcome]
  /// and [availability] hold it; never for a `skipped` one. This is how a
  /// tick nobody on screen awaited — the forced read after a write — still
  /// reaches the mirror's readers. A throw from it is traced and dropped: the
  /// sync never throws.
  final void Function(CalendarSyncOutcome outcome)? onOutcome;

  /// The unforced minimum between two syncs. The inbox's poll is 60 s; the
  /// calendar moves far less than mail and every tick is a Graph call.
  static const Duration throttle = Duration(seconds: 120);

  /// Pages per tick. A first read of a busy calendar is a few pages; a cap
  /// keeps one tick from holding the backend for minutes on a huge one.
  static const int maxPagesPerTick = 10;

  static const int pastDays = 30;
  static const int futureDays = 120;

  /// How stale a window's start may get before the run is replaced.
  static const int rollDays = 7;

  static const Duration mailboxRefresh = Duration(hours: 24);
  static const Duration writeGuardSpan = Duration(minutes: 10);

  /// `sync_state`'s key for the one calendar this mirrors.
  static const String _source = 'calendar';
  static const String _folder = 'primary';

  Future<CalendarSyncOutcome>? _inFlight;

  /// When the last tick that reached an answer ended — any answer, so a
  /// failing or permissionless calendar is asked no more often than a working
  /// one.
  DateTime? _lastAttemptAt;

  /// The run the last `synced` tick ended on, for the mailbox-settings
  /// write's generation check.
  String? _tickRun;
  CalendarSyncOutcome? _lastOutcome;
  CalendarAvailability _availability = CalendarAvailability.unknown;
  final List<(String, DateTime)> _writes = [];

  /// The last outcome that was not `skipped`.
  CalendarSyncOutcome? get lastOutcome => _lastOutcome;

  CalendarAvailability get availability => _availability;

  /// One tick. A call while one runs returns that tick's future, [force] or
  /// not. Never throws.
  Future<CalendarSyncOutcome> syncNow({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    final last = _lastAttemptAt;
    if (!force && last != null && _clock().difference(last) < throttle) {
      return Future.value(
        const CalendarSyncOutcome(CalendarSyncStatus.skipped),
      );
    }
    final tick = () async {
      try {
        return await _tick();
      } finally {
        _inFlight = null;
      }
    }();
    _inFlight = tick;
    return tick;
  }

  /// Records that this app just wrote [eventId], so a sync page read before
  /// the write cannot overwrite it and a sweep cannot delete it.
  void noteWrite(String eventId) {
    final now = _clock();
    _prune(now);
    _writes.add((eventId, now));
  }

  /// Stores an event this app just wrote, as the server answered it: notes the
  /// write (the guard) and tags the row with the CURRENT run, so neither a page
  /// read before the write nor the next sweep undoes it (gotcha 36).
  ///
  /// The tag matters as much as the note: the note lapses after
  /// [writeGuardSpan], and a row tagged with anything but the run the next
  /// completed read sweeps under would be deleted by that sweep as something
  /// the calendar no longer holds. With no run stored yet (nothing has synced)
  /// the row carries an empty tag, and the first run's own read re-marks it.
  Future<void> storeWritten(CalendarEvent event) async {
    noteWrite(event.id);
    final run =
        _RunState.tryParse(await _store.getPref(calendarRunKey))?.run ?? '';
    await _calendar.upsertEvents([event], syncRun: run);
  }

  void _prune(DateTime now) {
    final floor = now.subtract(writeGuardSpan);
    _writes.removeWhere((w) => w.$2.isBefore(floor));
  }

  /// Throws [_Superseded] unless the stored run is still [run]. Called first
  /// inside every write transaction of a tick.
  Future<void> _checkRun(String run) async {
    final current = _RunState.tryParse(await _store.getPref(calendarRunKey));
    if (current?.run != run) throw const _Superseded();
  }

  Set<String> _writtenSince(DateTime since) => {
        for (final w in _writes)
          if (!w.$2.isBefore(since)) w.$1,
      };

  /// The cached mailbox settings, or null when none are stored, the stored
  /// value is unreadable, or the last fetch found the scope missing.
  static Future<MailboxSettings?> readMailboxSettings(MessageStore store) async {
    try {
      final raw = await store.getPref(calendarMailboxKey);
      final json = _decodeMap(raw);
      final settings = json?['settings'];
      if (settings is! Map) return null;
      return MailboxSettings.fromJson(Map<String, dynamic>.from(settings));
    } on Object catch (e) {
      debugPrint('calendar: the mailbox settings could not be read: $e');
      return null;
    }
  }

  static Map<String, dynamic>? _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map ? Map<String, dynamic>.from(json) : null;
    } on FormatException {
      return null;
    }
  }

  Future<CalendarSyncOutcome> _tick() async {
    final started = _clock();
    final watch = Stopwatch()..start();
    _prune(started);
    CalendarSyncOutcome outcome;
    try {
      final pre = await _precheck?.call();
      outcome = pre != null
          ? CalendarSyncOutcome(pre)
          : await _pages(started);
    } on _Superseded {
      // The run this tick was writing is gone. Nothing was written, and
      // nothing was learned about the calendar either: no availability, no
      // backoff, so whoever replaced the run syncs at once.
      return const CalendarSyncOutcome(CalendarSyncStatus.skipped);
    } on CalendarScopeMissing {
      outcome = const CalendarSyncOutcome(CalendarSyncStatus.scopeMissing);
    } on CalendarUnavailable {
      outcome = const CalendarSyncOutcome(CalendarSyncStatus.unavailable);
    } on ReconsentRequired {
      outcome = const CalendarSyncOutcome(CalendarSyncStatus.unavailable);
    } on NotSignedIn {
      outcome = const CalendarSyncOutcome(CalendarSyncStatus.unavailable);
    } on Object catch (e) {
      // The type only, as the meeting backfill prints it: an exception's text
      // can carry the endpoint.
      debugPrint('calendar sync failed: ${e.runtimeType}');
      outcome = CalendarSyncOutcome(
        CalendarSyncStatus.failed,
        message: '${e.runtimeType}',
      );
    }
    watch.stop();
    _lastAttemptAt = _clock();

    final before = _availability;
    _lastOutcome = outcome;
    _availability = switch (outcome.status) {
      CalendarSyncStatus.synced => CalendarAvailability.available,
      CalendarSyncStatus.scopeMissing => CalendarAvailability.scopeMissing,
      CalendarSyncStatus.sdkMode => CalendarAvailability.sdkMode,
      CalendarSyncStatus.unavailable => CalendarAvailability.unavailable,
      // A failure says nothing about whether there IS a calendar; keep the
      // last answer rather than flicker the Day stop on a dropped request.
      CalendarSyncStatus.failed ||
      CalendarSyncStatus.skipped =>
        _availability,
    };

    if (outcome.status == CalendarSyncStatus.synced) {
      final run = _tickRun;
      if (run != null && await _refreshMailboxSettings(run)) {
        outcome = outcome._withSettingsRefreshed();
        _lastOutcome = outcome;
      }
      if (outcome.changed || (outcome.newRun && outcome.complete)) {
        await _activity.record(
          'sync_calendar',
          count: outcome.upserts,
          durationMs: watch.elapsedMilliseconds,
          detail: {
            'removed': outcome.removed,
            'swept': outcome.swept,
            'pages': outcome.pages,
            'run': outcome.newRun ? 'new' : 'delta',
          },
        );
      }
    } else if (outcome.status == CalendarSyncStatus.scopeMissing &&
        before != CalendarAvailability.scopeMissing) {
      // Once on the way in, not every tick: the state is what the Day stop
      // shows, and a row a minute would bury the log.
      await _activity.record(
        'sync_calendar',
        status: 'error',
        detail: const {'outcome': 'scope_missing'},
      );
    }
    if (outcome.status != CalendarSyncStatus.skipped) {
      try {
        onOutcome?.call(outcome);
      } on Object catch (e) {
        debugPrint('calendar: an outcome was not published: ${e.runtimeType}');
      }
    }
    return outcome;
  }

  /// The page loop. Throws what the backend throws, except a continuation's
  /// [CalendarCursorExpired], which restarts the run once, and throws
  /// [_Superseded] when the run it writes under is gone.
  Future<CalendarSyncOutcome> _pages(DateTime started) async {
    final db = _store.db;
    final today = DateTime.utc(started.toUtc().year, started.toUtc().month,
        started.toUtc().day);
    final rollFloor =
        DateTime.utc(today.year, today.month, today.day - (pastDays + rollDays));

    // Read, decide and (for a new run) write in ONE transaction: the cursor
    // is cleared and the new state written together or not at all, so a
    // crash can never leave an old cursor under a new, unswept run id — which
    // would let the next completed delta page sweep nearly the whole mirror.
    final (initial, initialCursor, fresh) = await db.transaction(() async {
      final stored = _RunState.tryParse(await _store.getPref(calendarRunKey));
      final cursor = await _store.getDeltaLink(_folder, source: _source) ?? '';
      if (cursor.isNotEmpty &&
          stored != null &&
          !stored.startInstant.isBefore(rollFloor)) {
        return (stored, cursor, false);
      }
      final state = _RunState(
        start:
            _wire(DateTime.utc(today.year, today.month, today.day - pastDays)),
        end: _wire(
            DateTime.utc(today.year, today.month, today.day + futureDays + 1)),
        run: calendarStamp(started),
        swept: false,
      );
      await _store.setDeltaLink(_folder, null, source: _source);
      await _store.setPref(calendarRunKey, state.toJson());
      return (state, '', true);
    });
    var state = initial;
    var cursor = initialCursor;
    var newRun = fresh;

    var upserts = 0;
    var removed = 0;
    var swept = 0;
    var pages = 0;
    var complete = false;
    var restarted = false;
    while (pages < maxPagesPerTick) {
      final sent = cursor;
      // Stamped per request, not per tick: a write noted before THIS request
      // went out is already in what the server answers, so only a write noted
      // while the request was in the air can be newer than the page.
      final requested = _clock();
      final CalendarSyncPage page;
      try {
        page = await _backend.syncPage(
          cursor: sent,
          startUtc: sent.isEmpty ? state.start : null,
          endUtc: sent.isEmpty ? state.end : null,
        );
      } on CalendarCursorExpired {
        if (sent.isEmpty || restarted) rethrow;
        // Same window, fresh run id: the rows the dead cursor had brought in
        // carry the old id, and are re-marked as the new run returns them.
        // One transaction for the reason the new-run branch above gives.
        restarted = true;
        newRun = true;
        final prior = state.run;
        final next = state.copyWith(run: calendarStamp(_clock()), swept: false);
        await db.transaction(() async {
          await _checkRun(prior);
          await _store.setDeltaLink(_folder, null, source: _source);
          await _store.setPref(calendarRunKey, next.toJson());
        });
        state = next;
        cursor = '';
        continue;
      }
      pages += 1;

      final guarded = _writtenSince(requested);
      final held = {
        for (final e in page.events)
          if (guarded.contains(e.id)) e.id,
      };
      // The whole page is one transaction behind the generation check, the
      // sweep included. `upsertEvents` opens its own transaction inside this
      // one, which drift runs as a savepoint.
      final applied = await db.transaction(() async {
        await _checkRun(state.run);
        var next = state;
        if (sent.isEmpty &&
            DateTime.tryParse(page.windowStart) != null &&
            DateTime.tryParse(page.windowEnd) != null) {
          next = next.copyWith(start: page.windowStart, end: page.windowEnd);
          await _store.setPref(calendarRunKey, next.toJson());
        }
        final written = await _calendar.upsertEvents(
          page.events,
          syncRun: next.run,
          skipIds: guarded,
        );
        // The app's own write is not overwritten, but it IS in this run: the
        // re-tag is what keeps a sweep long after the guard's span from
        // deleting it.
        await _calendar.retagRun(held, next.run);
        final gone = await _calendar.deleteEvents(page.removed);
        if (page.cursor.isNotEmpty) {
          await _store.setDeltaLink(_folder, page.cursor, source: _source);
        }
        var sweptNow = 0;
        if (page.complete) {
          if (!next.swept) {
            _prune(_clock());
            sweptNow = await _calendar.sweepRun(
              next.run,
              keepIds: {for (final w in _writes) w.$1},
            );
            next = next.copyWith(swept: true);
            await _store.setPref(calendarRunKey, next.toJson());
          }
          // Empty and complete: the server's "start a new run next time".
          if (page.cursor.isEmpty) {
            await _store.setDeltaLink(_folder, null, source: _source);
          }
        }
        return (next, written, gone, sweptNow);
      });
      state = applied.$1;
      upserts += applied.$2;
      removed += applied.$3;
      swept += applied.$4;

      if (page.complete) {
        complete = true;
        break;
      }
      // Not complete and no way forward: a later Graph page failed and the
      // server handed back the link it could not follow. Try it next tick.
      if (page.cursor.isEmpty || page.cursor == sent) break;
      cursor = page.cursor;
    }

    _tickRun = state.run;
    return CalendarSyncOutcome(
      CalendarSyncStatus.synced,
      upserts: upserts,
      removed: removed,
      swept: swept,
      pages: pages,
      newRun: newRun,
      complete: complete,
    );
  }

  static String _wire(DateTime utcMidnight) =>
      '${CalendarDate.ofDateTime(utcMidnight).toIso()}T00:00:00Z';

  /// Fetches the mailbox settings when the cache is missing, unreadable or a
  /// day old. A missing scope is cached as `settings: null` so it is asked
  /// again in a day rather than every tick; any other failure caches nothing
  /// and is asked again next tick. Never changes the outcome's status; answers
  /// whether it wrote the cache.
  ///
  /// The write sits behind [run]'s generation check, as a page's writes do:
  /// the fetch is a network call a wipe can overtake, and the old account's
  /// zone must not land in the next one's cache.
  Future<bool> _refreshMailboxSettings(String run) async {
    try {
      final cached = _decodeMap(await _store.getPref(calendarMailboxKey));
      final fetchedAt = cached == null
          ? null
          : DateTime.tryParse(cached['fetched_at'] as String? ?? '');
      if (fetchedAt != null &&
          _clock().difference(fetchedAt) < mailboxRefresh) {
        return false;
      }
      MailboxSettings? settings;
      try {
        settings = await _backend.mailboxSettings();
      } on CalendarScopeMissing {
        settings = null;
      }
      final value = jsonEncode({
        'settings': settings?.toJson(),
        'fetched_at': calendarStamp(_clock()),
      });
      await _store.db.transaction(() async {
        await _checkRun(run);
        await _store.setPref(calendarMailboxKey, value);
      });
      return true;
    } on _Superseded {
      return false;
    } on Object catch (e) {
      debugPrint('calendar: the mailbox settings were not refreshed: '
          '${e.runtimeType}');
      return false;
    }
  }
}
