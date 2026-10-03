import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar_store.dart';
import '../models/calendar_models.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart';
import '../services/calendar/overlaps.dart';
import '../services/calendar/scheduling_ask.dart';
import '../services/decision/stored_decision.dart';
import 'app_providers.dart';
import 'conversations_provider.dart';

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

/// The day's written briefs, by event id — the agenda draws each one's glance
/// under its meeting and opens the rest inline, and the Today section draws
/// the glances. Ready briefs only, and only those with a glance: a skipped or
/// failed row has nothing to show, and the panel is where those say why.
final dayBriefsProvider = FutureProvider.autoDispose
    .family<Map<String, MeetingBrief>, CalendarDate>((ref, day) async {
  // Not the work tick: the agenda draws no "Writing…" state, and a stored
  // brief bumps briefRevisionProvider (the handler's onStored).
  ref.watch(briefRevisionProvider);
  final events = await ref.watch(dayEventsProvider(day).future);
  if (events.isEmpty) return const {};
  final briefs = await ref
      .watch(calendarStoreProvider)
      .briefsFor([for (final e in events) e.id]);
  return {
    for (final MapEntry(:key, :value) in briefs.entries)
      if (value.brief case final brief? when brief.headline.isNotEmpty)
        key: brief,
  };
});

/// The seven days from `monday` (the family argument — the host passes
/// [mondayOf] the day it shows, so every day of one week shares one read):
/// the week grid's events, timed and all-day, cancelled included.
///
/// The local midnights bound it, so a Sunday-night meeting that is already
/// Monday in UTC stays in the week whose Sunday it is on.
final weekEventsProvider = FutureProvider.autoDispose
    .family<List<CalendarEvent>, CalendarDate>((ref, monday) async {
  ref.watch(calendarRevisionProvider);
  final availability = ref.watch(calendarAvailabilityProvider);
  final store = ref.watch(calendarStoreProvider);
  if (!calendarShowsMirror(availability)) return const [];
  final zone = await ref.watch(calendarZoneProvider.future);
  return _between(store, zone, monday, monday.addDays(7));
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
      debugPrint(
          'an invite\'s decisions could not be read: ${err.runtimeType}');
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

/// The threads asking for a time: the thread header's Find a time and the
/// Day column's Scheduling asks read the same map.
///
/// Re-read whenever the list reloads — which is what follows a triage pass
/// writing new decisions, a reply going out, or a thread changing state. A
/// calendar revision changes none of that, so it is not watched. One query
/// ([MessageStore.schedulingAskConversations]). No clock: the rule is about
/// the thread's state and its newest message, not the time.
///
/// Keyed by the ask, valued by its newest inbound message's id
/// ([schedulingAskMessageIds]): the keys are what the thread bar and the
/// column test, and the id is what the inbox labels when the owner closes an
/// ask. Invalidated by the inbox after such a label, so the row goes at once.
final schedulingAsksProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final state = ref.watch(conversationsProvider);
  if (state is! ConversationsLoaded) return const {};
  try {
    return await schedulingAskMessageIds(ref.watch(messageStoreProvider));
  } on Object catch (err) {
    debugPrint('scheduling asks could not be read: ${err.runtimeType}');
    return const {};
  }
});
