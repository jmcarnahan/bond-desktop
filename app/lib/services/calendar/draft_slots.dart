import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../../data/calendar_store.dart';
import '../../data/message_store.dart';
import '../../models/calendar_models.dart';
import '../../models/message_models.dart' show Conversation;
import '../activity_log.dart';
import '../backend/backend_types.dart' show NotSignedIn, ReconsentRequired;
import '../backend/calendar_backend.dart';
import '../backend/calendar_errors.dart';
import 'ask_hints.dart';
import 'ask_reader.dart';
import 'calendar_zone.dart';
import 'find_time.dart';
import 'overlaps.dart' show FreeSlot, Overlaps, findOverlaps;
import 'scheduling_ask.dart';

/// The owner's real free times at the end of a draft that answers a
/// scheduling ask (docs/pipeline/07-replies.md "Times in a draft").
///
/// The draft prompt is untouched: the model writes its reply, and THEN Dart
/// searches the calendar and the draft handler appends [findTimeReplyLine] —
/// the line Put in reply writes — to the body and every option. The model
/// never sees a slot, so a cloud draft target never sees the calendar.

/// What the draft handler needs to offer times; null in the handler is a
/// draft with no calendar at all, as before.
///
/// Every getter is read at the call, never at build, so a zone that resolves
/// after the first sync, a mailbox read or an availability tick rebuilds
/// nothing on the draft lane.
class DraftCalendar {
  DraftCalendar({
    required this.store,
    required this.backend,
    required this.mailbox,
    required this.zone,
    required this.reader,
    required this.ownerAddresses,
    required this.available,
  });

  /// The mirror: the owner's own free time when nobody else is on the
  /// thread, and the busy events a Graph slot is checked against.
  final CalendarStore store;

  /// `findMeetingTimes`, when somebody else is on the thread.
  final CalendarBackend backend;

  /// The mailbox's working hours, or null before the first sync.
  final Future<MailboxSettings?> Function() mailbox;

  /// The display zone.
  final Future<CalendarZone> Function() zone;

  /// The model's reading of the ask (`ask_read`), cached per message — the
  /// draft lane is what pre-warms it (D9).
  final AskReader reader;

  /// The owner's addresses, lowercased: mail, and the UPN when it differs.
  final Future<Set<String>> Function() ownerAddresses;

  /// Whether the mirror may be read at all ([calendarShowsMirror]).
  final bool Function() available;
}

/// The times one draft offers: the [slots], the [line] appended to the body
/// and each option, and the [record] stored as `context_json`'s `calendar`
/// key, which the stale-times redraft reads back.
@immutable
class DraftSlots {
  final List<FreeSlot> slots;
  final String line;

  /// `{slots: [{start_utc, end_utc}], source, window, graph_calls, read,
  /// minutes}`; an Improve adds `improved: true`.
  final Map<String, Object?> record;

  const DraftSlots({
    required this.slots,
    required this.line,
    required this.record,
  });
}

/// The free times to offer in a draft answering [messageId], or null — and
/// the draft stands without times — when the calendar cannot be read, the
/// message is not a scheduling ask, nothing is free, or anything fails.
///
/// In order: the mirror shown ([DraftCalendar.available]); THE ONE RULE
/// ([schedulingAskMessageIds] names [messageId] as [thread]'s newest inbound
/// message — keyed by source and thread, so an older message of an ask
/// thread offers nothing; an asked-for draft included); the ask's hints —
/// the model's reading when it has one (`readAskHintsFromRead`, no timeout:
/// this runs on a lane), else the rules' ([readAskHints]); the window the
/// Day column seeds on a first read ([askWindowFor]: their day when one was
/// read, else this week) and the hinted length, else 30 minutes; the
/// thread's other people ([otherAddresses]); then [searchFindTime], the Day
/// column's own search (one Graph call per hinted day). A slot [slotGone]
/// names — begun, or blocked on the mirror the search already read — is
/// dropped here: that is the stale rule the redraft applies
/// (`DraftSlotRefresher`), and offering one would only queue a redraft.
///
/// [log] gets one `find_time` row: `{action: draft, source, slots, people,
/// window, graph_calls, read}` when times are offered, or `skipped` with the
/// error's enum word when the calendar failed — counts and enum words only.
/// An auth failure ([ReconsentRequired], [NotSignedIn]) is rethrown, from
/// the search's [FindTimeResult.error] too: it parks the drain, as the mail
/// side's do.
Future<DraftSlots?> draftSlotsFor({
  required DraftCalendar calendar,
  required MessageStore store,
  required String source,
  required String messageId,
  required Conversation thread,
  required DateTime now,
  DateTime? sentAt,
  required String subject,
  required String body,
  ActivityLog? log,
}) async {
  if (!calendar.available()) return null;
  try {
    final asks = await schedulingAskMessageIds(store);
    if (asks[schedulingAskKey(source, thread.id)] != messageId) return null;
    final reading = await calendar.reader.readFor(source, messageId);
    final zone = await calendar.zone();
    final byModel = reading != null && reading.status == 'ready';
    final hints = byModel
        ? readAskHintsFromRead(
            read: reading.read,
            subject: subject,
            body: body,
            now: now,
            zone: zone,
            sentAt: sentAt)
        : readAskHints(
            subject: subject,
            body: body,
            now: now,
            zone: zone,
            sentAt: sentAt);
    final readVia = byModel ? 'model' : 'rules';
    final window = askWindowFor(
        hints.day != null ? FindTimeWindow.theirs : FindTimeWindow.thisWeek,
        hints);
    final minutes = hints.minutes ?? 30;
    final addresses =
        otherAddresses(thread, owner: await calendar.ownerAddresses());

    final result = await searchFindTime(
      backend: calendar.backend,
      calendar: calendar.store,
      hours: await calendar.mailbox(),
      addresses: addresses,
      durationMinutes: minutes,
      window: window,
      now: now,
      zone: zone,
      hints: hints,
    );
    final error = result.error;
    if (error is ReconsentRequired || error is NotSignedIn) throw error!;
    if (result.failed) {
      await log?.record('find_time',
          status: 'skipped',
          source: source,
          detail: {'action': 'draft', 'reason': _reasonOf(error)});
      return null;
    }
    // The mirror the search read already says what each slot runs into: no
    // second query.
    final slots = [
      for (final s in result.slots)
        if (!slotGone(s, result.overlaps[s] ?? const Overlaps(), now: now)) s,
    ];
    if (slots.isEmpty) return null;

    await log?.record('find_time',
        source: source,
        detail: {
          'action': 'draft',
          'source': result.source,
          'slots': slots.length,
          'people': addresses.length,
          'window': window.wire,
          'graph_calls': result.graphCalls,
          'read': readVia,
        });
    return DraftSlots(
      slots: slots,
      line: findTimeReplyLine(slots, zone),
      record: {
        'slots': [
          for (final s in slots)
            {
              'start_utc': MessageStore.isoStamp(s.startUtc),
              'end_utc': MessageStore.isoStamp(s.endUtc),
            },
        ],
        'source': result.source,
        'window': window.wire,
        'graph_calls': result.graphCalls,
        'read': readVia,
        'minutes': minutes,
      },
    );
  } on ReconsentRequired {
    rethrow;
  } on NotSignedIn {
    rethrow;
  } on Object catch (e) {
    debugPrint('draft times: not offered: ${e.runtimeType}');
    try {
      await log?.record('find_time',
          status: 'skipped',
          source: source,
          detail: {'action': 'draft', 'reason': _reasonOf(e)});
    } on Object catch (_) {}
    return null;
  }
}

/// The slots a stored `calendar` record ([DraftSlots.record]) offered, in
/// its order; an entry that does not read as two instants is left out, and
/// anything that is not a record is none.
List<FreeSlot> draftSlotsOf(Object? calendar) {
  if (calendar is! Map) return const [];
  final raw = calendar['slots'];
  if (raw is! List) return const [];
  final slots = <FreeSlot>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final start = DateTime.tryParse('${entry['start_utc']}');
    final end = DateTime.tryParse('${entry['end_utc']}');
    if (start == null || end == null) continue;
    slots.add(FreeSlot(start.toUtc(), end.toUtc()));
  }
  return slots;
}

/// Whether [slot] can no longer be offered: it has begun by [now], or its
/// [overlaps] with the mirror ([findOverlaps]) hold a `hard` one — a timed
/// event, not cancelled, not declined, shown busy, out of office or with no
/// word at all. A `tentative` event is the Day column's soft overlap — said,
/// never refused — so it blocks nothing here; nor do `free` and
/// `workingElsewhere`.
///
/// ONE rule for both ends: a draft never offers such a slot
/// ([draftSlotsFor], on the overlaps its search computed), and a draft
/// offering one is redrafted (`DraftSlotRefresher`, on one mirror read per
/// pass) — so a fresh draft cannot be stale on arrival.
bool slotGone(FreeSlot slot, Overlaps overlaps, {required DateTime now}) =>
    !slot.startUtc.isAfter(now.toUtc()) || overlaps.hard.isNotEmpty;

/// [slots] less those [slotGone] names, on one mirror read over their span:
/// what an Improve keeps of a stored draft's times.
Future<List<FreeSlot>> liveSlots(
  CalendarStore calendar,
  List<FreeSlot> slots, {
  required DateTime now,
  required CalendarZone zone,
}) async {
  if (slots.isEmpty) return const [];
  var first = slots.first.startUtc;
  var last = slots.first.endUtc;
  for (final s in slots) {
    if (s.startUtc.isBefore(first)) first = s.startUtc;
    if (s.endUtc.isAfter(last)) last = s.endUtc;
  }
  final events = await calendar.eventsBetween(
    startUtc: first,
    endUtc: last,
    fromDate: zone.dateOf(first),
    toDateExclusive: zone.dateOf(last).addDays(1),
  );
  return [
    for (final s in slots)
      if (!slotGone(s, findOverlaps(events, s.startUtc, s.endUtc, zone: zone),
          now: now))
        s,
  ];
}

/// The activity row's word for what the calendar threw.
String _reasonOf(Object? e) => switch (e) {
      CalendarUnavailable() => 'unavailable',
      CalendarScopeMissing() => 'scope_missing',
      CalendarTransient() => 'transient',
      CalendarRefused() => 'refused',
      _ => 'other',
    };
