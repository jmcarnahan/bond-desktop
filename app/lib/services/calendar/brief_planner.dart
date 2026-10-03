import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/calendar_models.dart';
import 'brief_gatherer.dart';
import 'calendar_zone.dart';

/// Decides, after each calendar sync, which meetings need a brief written
/// and queues them on the DRAFT lane.
///
/// Runs only while processing is on and only after a sync that completed;
/// the caller pumps the draft lane when this queued anything. Nothing here
/// calls a model: the eligibility check and the inputs hash are store reads.
///
/// **The regeneration rule.** A meeting with no brief is queued. A stored
/// brief is left alone for [freshFor] after it was written, whatever changed
/// — a thread that is busy the morning of a meeting would otherwise buy a
/// model call per sync. Past that, it is queued again only when its inputs
/// hash moved (or it had failed). At most [maxPerPass] per pass, the soonest
/// meetings first, so a calendar full of meetings costs a few calls a sync
/// rather than a burst — and queued so the soonest drains first.
///
/// **What it writes itself.** A meeting found ineligible for a reason that
/// can change while it stays on the calendar ([recorded]: no recent mail,
/// nobody else invited, too many people) gets a `skipped` row naming the
/// reason, so the panel says why rather than promising a brief after the
/// next sync. Written only when the stored row does not already say so, and
/// never over a ready brief, which stands. When the reason goes away the
/// gathered hash no longer reads `ineligible:*`, and the meeting is queued
/// like any other once the row is past [freshFor].
///
/// **The recheck throttle.** Gathering is store reads, but up to twenty
/// candidate threads per meeting is not free, and the calendar syncs every
/// few minutes. So an event whose stored row has not moved since it was
/// gathered less than [recheck] ago is not gathered again. An event with NO
/// stored row is never throttled: that is the state after Clear AI results,
/// and the next synced tick should plan it at once.
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
    final end = nowUtc.add(briefHorizon);
    // Every event touching the window, a meeting already under way included:
    // its brief is still worth reading while it runs, so the housekeeping
    // below keeps it, even though nothing new is planned for it.
    final events = await _calendar.eventsBetween(
      startUtc: nowUtc,
      endUtc: end,
      fromDate: zone.dateOf(nowUtc),
      toDateExclusive: zone.dateOf(end).addDays(1),
    );
    final ids = {for (final e in events) e.id};
    await _calendar.deleteBriefsExcept(ids);
    _lastChecked.removeWhere((id, _) => !ids.contains(id));

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
    final due = <String>[];
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
      final generated = stored?.generatedAtUtc;
      final fresh =
          generated != null && nowUtc.difference(generated) < freshFor;
      if (stored != null && fresh) continue;
      final checked = _lastChecked[e.id];
      if (stored != null &&
          checked != null &&
          nowUtc.difference(checked.at) < recheck &&
          checked.generatedAt == stored.generatedAt) {
        continue;
      }

      final gathered = await _gatherer.gather(e, now: nowUtc);
      _lastChecked[e.id] = (at: nowUtc, generatedAt: stored?.generatedAt ?? '');
      switch (gathered) {
        case BriefIneligible(:final why):
          if (recorded.contains(why) &&
              await _record(e.id, why, stored, stamp)) {
            _lastChecked[e.id] = (at: nowUtc, generatedAt: stamp);
          }
          continue;
        case BriefEligible(:final input):
          final changed = stored == null ||
              stored.status == EventBrief.failed ||
              stored.inputsHash != input.inputsHash;
          if (!changed) continue;
      }

      // A row already waiting or at the server is not queued twice, and is
      // not counted as this pass's work.
      final status = await _store.workStatusOf(kind, source, e.id);
      if (status == 'pending' || status == 'processing') continue;
      due.add(e.id);
    }

    // Queued in REVERSE and re-stamped, so the soonest meeting carries the
    // newest `created_at`: the drain claims newest first, so the soonest
    // drains first. Re-stamped because most of these rows are revivals of a
    // `done` row, whose old stamp would order it by when its first brief was
    // written; the lane claims one kind at a time, so the stamps order briefs
    // only among themselves and jump no mail.
    for (final id in due.reversed) {
      await _store.requeueWork(kind, source, id, refreshCreatedAt: true);
      _lastChecked.remove(id);
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
