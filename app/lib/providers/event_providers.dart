import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/calendar_models.dart' show EventBriefView;
import '../services/backend/calendar_errors.dart';
import '../services/calendar/calendar_sync.dart' show CalendarAvailability;
import '../services/calendar/day_items.dart' show calendarShowsMirror;
import '../services/calendar/event_view.dart';
import 'app_providers.dart';

/// The reads behind one meeting: the event panel, the meeting card under an
/// invite, and the line at the top of a person's room.
///
/// The Day providers' rules hold here too (`day_providers.dart`): every one
/// watches [calendarRevisionProvider], so a panel left open follows the
/// calendar; none reads the clock — the one that needs an instant takes it as
/// its family argument, computed by the host on each build; and each gates on
/// [calendarShowsMirror], so SDK mode and a grant without the calendar scope
/// never see the stale rows the table may still hold.

/// One event by its Graph id: the mirror first, then a live read.
///
/// The live read is for the events the mirror's window does not hold — an
/// invite from last spring, a meeting four months out — and its answer is
/// kept in memory only. It is NEVER written to the store: a row written
/// outside `CalendarSync` carries no run tag, and the next sweep would delete
/// it, which is a bug with a fuse on it rather than a cache.
///
/// Every failure is an answer rather than an error, because each one is
/// something the panel draws: gone, blocked, or unreachable. What is logged
/// is the error's TYPE only — an exception's sentence can carry a subject.
final eventByIdProvider = FutureProvider.autoDispose
    .family<EventLookup, String>((ref, id) async {
  ref.watch(calendarRevisionProvider);
  final availability = ref.watch(calendarAvailabilityProvider);
  if (!calendarShowsMirror(availability)) {
    return EventLookup.blocked(availability);
  }
  final store = ref.watch(calendarStoreProvider);
  // The mirror half answers too: a store read that throws must end the
  // panel's "Reading…" with a sentence, not leave it waiting on a failed
  // future.
  try {
    final stored = await store.event(id);
    if (stored != null) {
      return EventLookup.found(
        stored,
        occurrences:
            stored.isSeriesMaster ? await store.occurrencesOf(id) : const [],
        fromMirror: true,
        availability: availability,
      );
    }
  } on Object catch (e) {
    debugPrint('an event could not be read from the mirror: ${e.runtimeType}');
    return EventLookup.unreachable(availability: availability);
  }
  try {
    final live = await ref.read(calendarBackendProvider).getEvent(id);
    // The mirror is built from calendarView, which holds a series'
    // occurrences (keyed by their master) but seldom the master row itself,
    // so an invite naming the master is read here — and its occurrences are
    // still the mirror's to give.
    return EventLookup.found(
      live,
      occurrences:
          live.isSeriesMaster ? await store.occurrencesOf(id) : const [],
      fromMirror: false,
      availability: availability,
    );
  } on CalendarEventGone {
    return EventLookup.gone(availability: availability);
  } on CalendarScopeMissing {
    return const EventLookup.blocked(CalendarAvailability.scopeMissing);
  } on CalendarUnavailable {
    // SDK mode's backend throws this for every call; anywhere else it is a
    // server that could not answer, which is worth trying again.
    return availability == CalendarAvailability.sdkMode
        ? const EventLookup.blocked(CalendarAvailability.sdkMode)
        : EventLookup.unreachable(availability: availability);
  } on Object catch (e) {
    debugPrint('an event could not be read live: ${e.runtimeType}');
    return EventLookup.unreachable(availability: availability);
  }
});

/// The conversations linked to one event, newest first: every thread holding
/// a message that names it (or, for an occurrence, names its series), and the
/// Teams meeting chat when this mailbox has it.
///
/// One thread appears once however many of its messages name the event — an
/// invite and two updates are one conversation. A link whose conversation
/// row is missing (a message stored before its thread was, a thread wiped
/// since) is skipped, and a read that throws costs that link only.
final eventLinksProvider = FutureProvider.autoDispose
    .family<List<EventLink>, String>((ref, id) async {
  ref.watch(calendarRevisionProvider);
  final lookup = await ref.watch(eventByIdProvider(id).future);
  final event = lookup.event;
  if (!lookup.isFound || event == null) return const [];
  final store = ref.watch(calendarStoreProvider);
  final messages = ref.watch(messageStoreProvider);

  final seen = <String>{};
  final keys = <(String, String)>[];
  void note(String source, String key) {
    if (seen.add('$source\u0000$key')) keys.add((source, key));
  }

  try {
    for (final r in await store.messagesForEvent(id)) {
      note(r.source, r.conversationKey);
    }
    final master = event.seriesMasterId.trim();
    if (!event.isSeriesMaster && master.isNotEmpty) {
      for (final r in await store.messagesForEvent(master)) {
        note(r.source, r.conversationKey);
      }
    }
  } on Object catch (e) {
    debugPrint('an event\'s messages could not be read: ${e.runtimeType}');
  }

  Future<EventLink?> linkFor(
    String source,
    String key, {
    bool meetingChat = false,
  }) async {
    try {
      final row = await messages.getConversationRow(source, key);
      if (row == null) return null;
      final subject = (row['subject'] as String? ?? '').trim();
      final storylines = await messages.storylineIdsFor(source, key);
      return EventLink(
        source: source,
        conversationKey: key,
        isMeetingChat: meetingChat,
        title: subject.isNotEmpty
            ? subject
            : (meetingChat ? 'Meeting chat' : '(no subject)'),
        storylineId: storylines.isEmpty || storylines.first.isEmpty
            ? null
            : storylines.first,
      );
    } on Object catch (e) {
      debugPrint('an event link could not be read: ${e.runtimeType}');
      return null;
    }
  }

  final links = <EventLink>[];
  for (final (source, key) in keys) {
    final link = await linkFor(source, key);
    if (link != null) links.add(link);
  }

  // The meeting chat, read out of the join link. Only one this mailbox has
  // synced: a chat nobody here was in is a chat there is nothing to open.
  final chat = event.teamsThreadId;
  if (chat != null && !seen.contains('teams\u0000$chat')) {
    final link = await linkFor('teams', chat, meetingChat: true);
    if (link != null) links.add(link);
  }
  return links;
});

/// The family key for [personMeetingsProvider]'s addresses: lowercased,
/// trimmed, de-duplicated, sorted and comma-joined, so one room asks one
/// question however its people are ordered on this build.
String personMeetingsKey(Iterable<String?> emails) {
  final set = <String>{
    for (final e in emails)
      if (e != null && e.trim().isNotEmpty) e.trim().toLowerCase(),
  };
  return (set.toList()..sort()).join(',');
}

/// The next meeting with a person and the last one that ended, for the line
/// at the top of their room.
///
/// Keyed by [personMeetingsKey]'s string and an "as of" instant the host
/// computes as `invitesAsOf(DateTime.now())` — floored to the quarter hour,
/// so the read re-runs four times an hour and a meeting that has started
/// moves from next to last without anything else happening.
final personMeetingsProvider = FutureProvider.autoDispose
    .family<PersonMeetings, ({String addresses, DateTime asOf})>(
        (ref, key) async {
  ref.watch(calendarRevisionProvider);
  final availability = ref.watch(calendarAvailabilityProvider);
  if (!calendarShowsMirror(availability)) return const PersonMeetings();
  final list = [
    for (final a in key.addresses.split(','))
      if (a.trim().isNotEmpty) a.trim(),
  ];
  if (list.isEmpty) return const PersonMeetings();
  final store = ref.watch(calendarStoreProvider);
  final nowUtc = key.asOf.toUtc();
  return PersonMeetings(
    next: await store.nextMeetingWith(list, nowUtc: nowUtc),
    last: await store.lastMetWith(list, nowUtc: nowUtc),
  );
});

/// The Brief section of one event's panel: the stored `event_briefs` row for
/// the family's id (the SHOWN occurrence's — briefs are keyed by
/// occurrence), whether a brief for it is queued or being written, and
/// whether processing is on.
///
/// Re-reads on a calendar change, on every brief the handler stores or a
/// Regenerate asks for ([briefRevisionProvider]), and when the draft lane
/// reports on `meeting_brief` work ([briefWorkTickProvider]). A failed read
/// is an empty view, never an error: the section then says a brief is coming.
final eventBriefProvider =
    FutureProvider.autoDispose.family<EventBriefView, String>((ref, id) async {
  ref.watch(calendarRevisionProvider);
  ref.watch(briefRevisionProvider);
  ref.watch(briefWorkTickProvider);
  final processingOn = ref.watch(processingProvider);
  try {
    final brief = await ref.watch(calendarStoreProvider).brief(id);
    final status = await ref
        .watch(messageStoreProvider)
        .workStatusOf('meeting_brief', 'calendar', id);
    return EventBriefView(
      brief: brief,
      queued: status == 'pending' || status == 'processing',
      processingOn: processingOn,
    );
  } on Object catch (e) {
    debugPrint('a brief could not be read: ${e.runtimeType}');
    return EventBriefView(processingOn: processingOn);
  }
});
