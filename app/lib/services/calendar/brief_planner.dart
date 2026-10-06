import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/calendar_models.dart';
import 'brief_gatherer.dart';
import 'calendar_zone.dart';
import 'meeting_brief_handler.dart' show MeetingBriefHandler;

/// Decides, after each calendar sync, which meetings need a brief written
/// and queues them on the DRAFT lane.
///
/// Runs only while processing is on and only after a sync that completed;
/// the caller pumps the draft lane when this queued anything. Nothing here
/// calls a model: the eligibility check and the inputs hash are store reads
/// (it gathers with `passages: false`, so no passage embedding). The one
/// network call it can cost is the related search's query: a meeting on the
/// related path (`briefPathOf`) has its subject and description embedded
/// once per distinct text per app run — the gatherer caches the vector —
/// because the threads that search finds are hashed, so new mail on the
/// topic re-briefs.
///
/// **The regeneration rule.** A meeting with no brief is queued. A stored
/// brief is queued again when its inputs hash moved — at any age, so a deck
/// or its digest landing an hour after the first brief re-briefs on the
/// next pass rather than waiting out [freshFor]. A failed brief is retried
/// only once it is older than [freshFor] (unless its inputs moved). What
/// keeps a thread that is busy the morning of a meeting from buying a model
/// call per sync is [_queuedFor] and the "fresh AND unchanged" rule: one set
/// of inputs is queued once while the brief is fresh. At most [maxPerPass]
/// per pass, the soonest meetings first, so a calendar full of meetings
/// costs a few calls a sync rather than a burst — and queued so the soonest
/// drains first.
///
/// **Waiting for the files.** The handler writes a `skipped` row with the
/// reason `materials_pending` when a file sent ahead is still being read
/// and the meeting is more than [MeetingBriefHandler.pendingGrace] off. Like
/// every skipped row it is gathered on every pass, and queued when the text
/// lands and moves the hash, or when the light gather says nothing is being
/// read any more though the hash did not move (the text work gave up, or the
/// file has been read for longer than [BriefGatherer.pendingMaxAge]); and
/// once the meeting comes inside the grace it is queued on the same hash,
/// once, so it is briefed with what is read rather than waiting on a file
/// that may never finish.
///
/// **What it writes itself.** A meeting found ineligible for a reason that
/// can change while it stays on the calendar ([recorded]: no recent mail,
/// nobody else invited, too many people) gets a `skipped` row naming the
/// reason, so the panel says why rather than promising a brief after the
/// next sync. Written only when the stored row does not already say so, and
/// never over a ready brief, which stands. When the reason goes away the
/// gathered hash no longer reads `ineligible:*`, and the meeting is queued
/// like any other on the next gather.
///
/// **The recheck throttle.** Gathering is store reads, but up to twenty
/// candidate threads per meeting is not free, and the calendar syncs every
/// few minutes. So an event whose stored row is FAILED and has not moved
/// since it was gathered less than [recheck] ago is not gathered again — a
/// back-off for a brief that could not be written. That is the only row it
/// holds. A READY row is gathered on every pass: a deck sent the morning of
/// the meeting, or its text landing, should reach the brief on the next
/// sync rather than a quarter of an hour later, and [_queuedFor] with the
/// "fresh AND unchanged" rule keep an unchanged one from queueing. An event
/// with NO stored row is never throttled: that is the state after Clear AI
/// results, and the next synced tick should plan it at once. Nor is a
/// `skipped` row: its reason is the kind that goes away within seconds — a
/// Gmail invite's event syncs before its mail, which is then the meeting's
/// thread, and a file being read lands in a minute — and a quarter of an
/// hour of "No brief — no recent mail" over a thread that is there is a
/// wrong sentence. The gathers are store reads; [_queuedFor] and the
/// "already says so" check keep an unchanged reason from queueing or writing
/// anything.
///
/// **Not per-message.** `clearDerived` empties `event_briefs` (a derived
/// table) and the next sync's plan writes them again, so nothing is added to
/// `clearDerived`'s per-message loop for this stage.
class BriefPlanner {
  BriefPlanner(this._store, this._calendar, this._gatherer);

  final MessageStore _store;
  final CalendarStore _calendar;
  final BriefGatherer _gatherer;

  static const Duration freshFor = Duration(hours: 2);
  static const Duration recheck = Duration(minutes: 15);
  static const int maxPerPass = 6;

  static const String kind = 'meeting_brief';
  static const String source = 'calendar';

  /// The ineligibility reasons the planner records on a row. The others
  /// (past, too far, cancelled, declined) the panel says from the event
  /// itself, and they need no row.
  static const Set<BriefIneligibility> recorded = {
    BriefIneligibility.noMail,
    BriefIneligibility.noOthers,
    BriefIneligibility.tooMany,
  };

  /// When each event was last gathered, and its stored row's `generated_at`
  /// then. In memory: a restart gathers everything once, which is the cost
  /// of one pass.
  final Map<String, ({DateTime at, String generatedAt})> _lastChecked = {};

  /// The inputs hash each event was last queued for. In memory, like
  /// [_lastChecked]. A failed rewrite over a ready brief moves only its stamp
  /// (`touchBrief`), so the stored hash stays the old one; without this, the
  /// same moved inputs would buy a model call every [recheck] until the brief
  /// aged past [freshFor]. With it, one set of inputs is tried once while the
  /// brief is fresh.
  final Map<String, String> _queuedFor = {};

  /// The `generated_at` of the `materials_pending` row each event was last
  /// queued for because its wait ended. In memory, like [_queuedFor].
  final Map<String, String> _endedFor = {};

  /// Queues what needs writing and returns how many it queued. [now] and
  /// [zone] are the caller's: the planner reads no clock.
  ///
  /// Returns 0 before reading anything else while the owner's address is
  /// unknown (the keychain has not answered yet): without it the owner counts
  /// among the people in every meeting, so a meeting with nobody else would
  /// be gathered, hashed and queued as though it were a meeting with someone.
  Future<int> plan({required DateTime now, required CalendarZone zone}) async {
    final owner = await _gatherer.owner();
    if (owner == null) return 0;
    final nowUtc = now.toUtc();
    final stamp = calendarStamp(nowUtc);
    final today = zone.dateOf(nowUtc);
    final end = briefHorizonEnd(nowUtc, zone);
    // Every event touching today and tomorrow, a meeting already under way
    // included (nothing new is planned for it, but it is in the window).
    final events = await _calendar.eventsBetween(
      startUtc: nowUtc,
      endUtc: end,
      fromDate: today,
      toDateExclusive: today.addDays(2),
    );
    final ids = {for (final e in events) e.id};
    // The window is where briefs are WRITTEN, not where they may live: only
    // the briefs of meetings that have ended or are gone are deleted, so a
    // brief read during its meeting stays, and one a person asked for a
    // meeting next week survives this pass (D2/D3). A ready brief whose
    // meeting moved out of the window stays as written until the meeting
    // comes back in; its start is in the hash, so it is rewritten then.
    await _calendar.deleteBriefsOfEndedEvents(nowUtc: nowUtc, today: today);
    _lastChecked.removeWhere((id, _) => !ids.contains(id));
    _queuedFor.removeWhere((id, _) => !ids.contains(id));
    _endedFor.removeWhere((id, _) => !ids.contains(id));

    // Soonest first, and timed meetings before all-day ones: an all-day event
    // is a holiday or a deadline far more often than a meeting, and should
    // not take a slot from the 10 AM call.
    final ordered = [...events]..sort((a, b) {
        if (a.isAllDay != b.isAllDay) return a.isAllDay ? 1 : -1;
        final sa = briefStartOf(a, zone);
        final sb = briefStartOf(b, zone);
        final byStart = sa == null || sb == null
            ? (sa == null ? 1 : 0) - (sb == null ? 1 : 0)
            : sa.compareTo(sb);
        return byStart != 0 ? byStart : a.id.compareTo(b.id);
      });

    final briefs = await _calendar.briefsFor(ids);
    final due = <({String id, String hash})>[];
    for (final e in ordered) {
      if (due.length >= maxPerPass) break;
      // `eventsBetween` never returns a master; the check is the rule said
      // out loud, because a master's times are the series' first meeting.
      if (e.isSeriesMaster) continue;
      final stored = briefs[e.id];
      final quick = briefQuickCheck(e, owner: owner, now: nowUtc, zone: zone);
      if (quick != null) {
        if (recorded.contains(quick)) await _record(e.id, quick, stored, stamp);
        continue;
      }
      // Fresh no longer skips the gather: a young brief whose inputs moved is
      // written again. Only a failed row is throttled, as a back-off.
      final generated = stored?.generatedAtUtc;
      final fresh =
          generated != null && nowUtc.difference(generated) < freshFor;
      final checked = _lastChecked[e.id];
      if (stored != null &&
          stored.status == EventBrief.failed &&
          checked != null &&
          nowUtc.difference(checked.at) < recheck &&
          checked.generatedAt == stored.generatedAt) {
        continue;
      }

      // Without passages: they are not hashed, and finding them costs an
      // embedding call per meeting — the handler's gather finds them. (The
      // related search's query is hashed, and cached in the gatherer.)
      final gathered =
          await _gatherer.gather(e, now: nowUtc, passages: false);
      _lastChecked[e.id] = (at: nowUtc, generatedAt: stored?.generatedAt ?? '');
      final String hash;
      switch (gathered) {
        case BriefIneligible(:final why):
          if (recorded.contains(why) &&
              await _record(e.id, why, stored, stamp)) {
            _lastChecked[e.id] = (at: nowUtc, generatedAt: stamp);
          }
          continue;
        case BriefEligible(:final input):
          hash = input.inputsHash;
          final moved = stored == null || stored.inputsHash != hash;
          // Fresh and unchanged is the one skip; a failed brief waits out
          // [freshFor] before it is tried again on the same inputs; a
          // meeting waiting on its files is briefed once it is inside the
          // grace, on whatever is read — or once nothing is being read any
          // more, which can happen without the hash moving (the text work
          // gave up, or the file has been read past the wait).
          final start = briefStartOf(e, zone);
          final waiting = stored?.skipReason ==
              BriefIneligibility.materialsPending.wire;
          final waitedEnough = waiting &&
              start != null &&
              !start.isAfter(nowUtc.add(MeetingBriefHandler.pendingGrace));
          // Once per stored row: a handler that throws before it writes
          // leaves the same row, and must not buy a queue every pass.
          final waitEnded = waiting &&
              !input.materialsPending &&
              _endedFor[e.id] != stored?.generatedAt;
          if (waitEnded) _endedFor[e.id] = stored?.generatedAt ?? '';
          final changed = (moved && !(fresh && _queuedFor[e.id] == hash)) ||
              (!fresh && stored?.status == EventBrief.failed) ||
              waitedEnough ||
              waitEnded;
          if (!changed) continue;
      }

      // A row already waiting or at the server is not queued twice, and is
      // not counted as this pass's work.
      final status = await _store.workStatusOf(kind, source, e.id);
      if (status == 'pending' || status == 'processing') continue;
      due.add((id: e.id, hash: hash));
    }

    // Queued in REVERSE and re-stamped, so the soonest meeting carries the
    // newest `created_at`: the drain claims newest first, so the soonest
    // drains first. Re-stamped because most of these rows are revivals of a
    // `done` row, whose old stamp would order it by when its first brief was
    // written; the lane claims one kind at a time, so the stamps order briefs
    // only among themselves and jump no mail.
    for (final (:id, :hash) in due.reversed) {
      await _store.requeueWork(kind, source, id, refreshCreatedAt: true);
      _lastChecked.remove(id);
      _queuedFor[id] = hash;
    }
    return due.length;
  }

  /// Writes a `skipped` row naming [why], unless the stored row already says
  /// so or holds a ready brief (which stands). Returns whether it wrote.
  Future<bool> _record(
    String eventId,
    BriefIneligibility why,
    EventBrief? stored,
    String stamp,
  ) async {
    final hash = '${EventBrief.ineligiblePrefix}${why.wire}';
    if (stored != null && (stored.isReady || stored.inputsHash == hash)) {
      return false;
    }
    await _calendar.putBrief(
      eventId: eventId,
      inputsHash: hash,
      status: EventBrief.skipped,
      generatedAt: stamp,
    );
    return true;
  }
}
