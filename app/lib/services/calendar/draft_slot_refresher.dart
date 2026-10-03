import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/draft_provenance.dart';
import '../activity_log.dart';
import 'calendar_zone.dart';
import 'draft_slots.dart' show draftSlotsOf, slotGone;
import 'overlaps.dart' show FreeSlot, findOverlaps;

/// Redrafts a reply whose offered times are gone (docs/pipeline/07-replies.md
/// "Times in a draft"; the round's D4).
///
/// A draft is written once (the handler's `already_drafted`), so the times
/// it appended would sit there after they passed or the owner booked over
/// them. After each calendar sync the inbox ran (processing on, beside the
/// brief planner), the 50 newest `suggested` drafts that offer times are
/// checked: a slot that has begun, or one a mirror event now blocks
/// ([slotGone], a tentative event blocking nothing), makes the whole draft
/// stale — it is deleted and its `draft` work row re-queued with the
/// payload it had, and the handler re-gates and drafts again with fresh
/// times. A draft the owner edited, sent or dismissed is never touched, nor
/// one they improved (`improved` in its record): that press may have been a
/// cloud call on the day's ledger.
class DraftSlotRefresher {
  DraftSlotRefresher({
    required this._store,
    required this._calendar,
    required this._log,
  });

  final MessageStore _store;
  final CalendarStore _calendar;
  final ActivityLog _log;

  /// At most this many redrafts per pass: each is a model call on the draft
  /// lane, and the rest are found again after the next sync.
  static const int maxPerPass = 5;

  /// Re-queues every `suggested` draft whose offered times are gone, up to
  /// [maxPerPass]; returns how many. One mirror read per pass, over the span
  /// of every candidate's slots. One `draft` activity row (`requeued`, the
  /// count, `reason: slots_stale`) when any were.
  Future<int> refresh({required DateTime now, required CalendarZone zone}) async {
    final candidates = <({String source, String id, List<FreeSlot> slots})>[];
    for (final row in await _store.draftsWithCalendarSlots()) {
      final source = row['source'] as String? ?? '';
      final id = row['reply_to_message_id'] as String? ?? '';
      final calendar =
          DraftProvenance.decode(row['context_json'] as String?)?.calendar;
      final slots = draftSlotsOf(calendar);
      if (source.isEmpty || id.isEmpty || slots.isEmpty) continue;
      candidates.add((source: source, id: id, slots: slots));
    }
    if (candidates.isEmpty) return 0;

    var first = candidates.first.slots.first.startUtc;
    var last = candidates.first.slots.first.endUtc;
    for (final c in candidates) {
      for (final s in c.slots) {
        if (s.startUtc.isBefore(first)) first = s.startUtc;
        if (s.endUtc.isAfter(last)) last = s.endUtc;
      }
    }
    final events = await _calendar.eventsBetween(
      startUtc: first,
      endUtc: last,
      fromDate: zone.dateOf(first),
      toDateExclusive: zone.dateOf(last).addDays(1),
    );

    var requeued = 0;
    for (final c in candidates) {
      if (requeued >= maxPerPass) break;
      final stale = c.slots.any((s) => slotGone(
          s, findOverlaps(events, s.startUtc, s.endUtc, zone: zone),
          now: now));
      if (!stale) continue;
      // What the draft was queued with — an asked-for press and its pinned
      // ids — read before the row is revived: a re-queue that passes no
      // payload over a done row clears it, and an asked-for draft would then
      // be skipped by the gates the press overruled.
      final payload = await _store.workPayload('draft', c.source, c.id);
      // Gone only while still untouched: an owner who started typing since
      // the read keeps their words, and nothing is re-queued.
      if (!await _store.deleteSuggestedDraft(c.source, c.id)) continue;
      await _store.requeueWork('draft', c.source, c.id, payloadJson: payload);
      requeued += 1;
    }
    if (requeued > 0) {
      await _log.record('draft',
          status: 'requeued',
          count: requeued,
          detail: const {'reason': 'slots_stale'});
    }
    return requeued;
  }
}
