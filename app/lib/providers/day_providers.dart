import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar_store.dart';
import '../models/calendar_models.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart';
import '../services/calendar/overlaps.dart';
import '../services/decision/stored_decision.dart';
import 'app_providers.dart';

/// The Day stop's reads.
///
/// Every one reads the `calendar_events` MIRROR through [calendarStoreProvider]
/// and never the backend: the sync keeps the table current, and a stop that
/// asked the server on every build would be a stop that goes blank offline.
/// Each watches [calendarRevisionProvider], which the sync bumps whenever rows
/// change, so a pane left open follows the calendar without polling.
///
/// Every family argument is computed by the HOST from `DateTime.now()` on
/// each build, never a clock read here: a date for the two event reads, and
/// an "as of" instant ([invitesAsOf]) for the invites. A provider that worked
/// out "today" or "now" for itself would only re-run on a revision bump, so
/// it would keep answering yesterday after midnight, and keep listing an
/// invite that started an hour ago, until something else happened to
/// rebuild it.
///
/// Each gates on [calendarShowsMirror]: SDK mode and a grant without the
/// calendar scope answer empty, whatever stale rows the table still holds.

/// The local day [CalendarDate] in the display zone: its timed events and its
/// all-day events, all-day first, cancelled included (the pane strikes them
/// through).
final dayEventsProvider = FutureProvider.autoDispose
    .family<List<CalendarEvent>, CalendarDate>((ref, day) async {
  ref.watch(calendarRevisionProvider);
  final availability = ref.watch(calendarAvailabilityProvider);
  final store = ref.watch(calendarStoreProvider);
  if (!calendarShowsMirror(availability)) return const [];
  final zone = await ref.watch(calendarZoneProvider.future);
  return _between(store, zone, day, day.addDays(1));
});

/// Fifteen days from `today` (the family argument) — the list column's
/// horizon plus today, and what the Today section picks its meetings from.
final upcomingEventsProvider = FutureProvider.autoDispose
    .family<List<CalendarEvent>, CalendarDate>((ref, today) async {
  ref.watch(calendarRevisionProvider);
  final availability = ref.watch(calendarAvailabilityProvider);
  final store = ref.watch(calendarStoreProvider);
  if (!calendarShowsMirror(availability)) return const [];
  final zone = await ref.watch(calendarZoneProvider.future);
  return _between(store, zone, today, today.addDays(15));
});

/// The invites still owed an answer, a recurring series folded to one entry,
/// pressing ones pinned first, each with its overlaps.
///
/// "Pressing" is the decision model's reading of the invite MAIL: any linked
/// message — linked to the occurrence or to its series master — whose stored
/// decision says urgency high or urgent, or importance high. A read that
/// throws costs that invite its pin, never the list.
///
/// Overlaps come from ONE span read covering every invite (capped at the
/// mirror's 121 days) rather than a read per invite.
///
/// The family argument is the UTC instant the list is "as of" — the host's
/// `invitesAsOf(DateTime.now())`, floored to the quarter hour so the read
/// re-runs four times an hour rather than on every build. Invites that have
/// started by then are gone, and "today" is that instant's display-zone date.
final invitesOwedProvider = FutureProvider.autoDispose
    .family<List<InviteEntry>, DateTime>((ref, asOf) async {
  ref.watch(calendarRevisionProvider);
  final availability = ref.watch(calendarAvailabilityProvider);
  final store = ref.watch(calendarStoreProvider);
  final messages = ref.watch(messageStoreProvider);
  if (!calendarShowsMirror(availability)) return const [];
  final zone = await ref.watch(calendarZoneProvider.future);

  final nowUtc = asOf.toUtc();
  final today = zone.dateOf(nowUtc);
  final entries =
      collapseInvites(await store.invitesOwed(nowUtc: nowUtc, today: today));
  if (entries.isEmpty) return const [];

  // Which ones the mail says are pressing.
  final pins = <bool>[];
  for (final entry in entries) {
    final e = entry.event;
    try {
      final refs = [
        ...await store.messagesForEvent(e.id),
        if (e.seriesMasterId.isNotEmpty)
          ...await store.messagesForEvent(e.seriesMasterId),
      ];
      final decisions = <StoredDecision?>[
        for (final r in refs)
          await messages.decisionFor(r.source, r.sourceMessageId),
      ];
      pins.add(invitePinned(decisions));
    } on Object catch (err) {
      debugPrint('an invite\'s decisions could not be read: $err');
      pins.add(false);
    }
  }

  // One read covering every invite's day, for the overlaps.
  CalendarDate? from;
  CalendarDate? toExclusive;
  for (final entry in entries) {
    final e = entry.event;
    final start = inviteDate(e, zone);
    if (start == null) continue;
    final CalendarDate after;
    if (e.isAllDay) {
      final end = e.endDate;
      after = end != null && end.isAfter(start) ? end : start.addDays(1);
    } else {
      final end = e.endUtc;
      after = (end == null ? start : zone.dateOf(end)).addDays(1);
    }
    if (from == null || start.isBefore(from)) from = start;
    if (toExclusive == null || after.isAfter(toExclusive)) toExclusive = after;
  }
  var span = const <CalendarEvent>[];
  if (from != null && toExclusive != null) {
    final cap = from.addDays(121);
    final to = toExclusive.isAfter(cap) ? cap : toExclusive;
    span = await _between(store, zone, from, to);
  }

  return orderInvites([
    for (var i = 0; i < entries.length; i++)
      entries[i].withContext(
        pinned: pins[i],
        overlaps: overlapsForEvent(entries[i].event, span, zone: zone),
      ),
  ]);
});

/// `[from, toExclusive)` in the display zone: the local midnights as instants
/// for the timed half, the bare dates for the all-day half.
Future<List<CalendarEvent>> _between(
  CalendarStore store,
  CalendarZone zone,
  CalendarDate from,
  CalendarDate toExclusive,
) =>
    store.eventsBetween(
      startUtc: zone.localDateTime(from, 0, 0).toUtc(),
      endUtc: zone.localDateTime(toExclusive, 0, 0).toUtc(),
      fromDate: from,
      toDateExclusive: toExclusive,
    );
