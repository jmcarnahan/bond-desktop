import 'package:intl/intl.dart' show DateFormat;

import '../../models/calendar_models.dart' show CalendarDate;
import '../../models/message_models.dart' show Conversation, Message;
import '../calendar/calendar_zone.dart';
import '../calendar/day_items.dart' show formatEventTime, shortDate;
import '../calendar/when_resolver.dart';
import '../deadline_parse.dart';

/// One way to set a reminder, worked out by the host: what the button says,
/// and the instant it means. [id] names it for a key.
typedef RemindChoice = ({String id, String label, DateTime atUtc});

/// The thread bar's Remind me choices for a thread, from [now] on [zone]'s
/// wall: in two hours, 5 pm today (only while it is more than ten minutes
/// off), tomorrow at 9, next Monday at 9 (strictly after today; dropped on a
/// Sunday, when it is tomorrow), and the deadline's day at 9 when
/// [deadlineDay] names a day whose 09:00 has not passed.
///
/// Every wall time is built from components ([CalendarZone.localDateTime]),
/// never by adding a [Duration] across midnight, except "in 2 hours", which
/// IS a duration.
List<RemindChoice> remindChoices({
  required DateTime now,
  required CalendarZone zone,
  CalendarDate? deadlineDay,
}) {
  final nowUtc = now.toUtc();
  final today = zone.dateOf(nowUtc);
  DateTime at(CalendarDate d, int hour) =>
      zone.localDateTime(d, hour, 0).toUtc();

  final out = <RemindChoice>[
    (
      id: 'in-2-hours',
      label: 'In 2 hours',
      atUtc: nowUtc.add(const Duration(hours: 2)),
    ),
  ];
  final fivePm = at(today, 17);
  if (fivePm.isAfter(nowUtc.add(const Duration(minutes: 10)))) {
    out.add((id: 'five-pm', label: '5 pm today', atUtc: fivePm));
  }
  final tomorrow = at(today.addDays(1), 9);
  out.add((id: 'tomorrow', label: 'Tomorrow 9 am', atUtc: tomorrow));
  var toMonday = (DateTime.monday - today.weekday) % 7;
  if (toMonday == 0) toMonday = 7;
  final monday = at(today.addDays(toMonday), 9);
  if (!monday.isAtSameMomentAs(tomorrow)) {
    out.add((id: 'next-monday', label: 'Next Monday 9 am', atUtc: monday));
  }
  if (deadlineDay != null && !deadlineDay.isBefore(today)) {
    final due = at(deadlineDay, 9);
    if (due.isAfter(nowUtc)) {
      out.add((
        id: 'deadline',
        label: 'On the deadline · ${shortDate(deadlineDay)}',
        atUtc: due,
      ));
    }
  }
  return out;
}

/// The day [c]'s deadline names, read the way the Day timeline and the
/// deadline planner read it: anchored to the inbound mail that named it,
/// dropped when it is not a showable deadline or does not parse to a day.
CalendarDate? remindDeadlineDay(Conversation c, DateTime now) {
  final raw = c.latestDeadline;
  if (raw == null) return null;
  final anchor = DateTime.tryParse(c.lastInboundAt ?? '')?.toLocal() ?? now;
  if (showableDeadline(raw, now: anchor) == null) return null;
  final at = parseDeadline(raw, now: anchor);
  return at == null ? null : CalendarDate(at.year, at.month, at.day);
}

/// Who a reply reminder names — the bar's Remind me and the deadline
/// planner both: the name the thread's participants give [newest]'s sender
/// (matched by address), else the message's own from-name, else the
/// address, else "them".
String replyToName(Conversation thread, Message? newest) {
  final address =
      (thread.latestInboundFrom ?? newest?.fromAddress ?? '').trim();
  for (final p in thread.participants) {
    final name = p.name?.trim() ?? '';
    if (name.isNotEmpty &&
        address.isNotEmpty &&
        p.email?.trim().toLowerCase() == address.toLowerCase()) {
      return name;
    }
  }
  final fromName = newest?.fromName?.trim() ?? '';
  if (fromName.isNotEmpty) return fromName;
  return address.isEmpty ? 'them' : address;
}

/// A typed time ("Thu 3pm", "tomorrow", "at 4") as a reminder, or null when
/// it names no time that is still ahead.
///
/// Read in booking mode ([resolveWhen]): a day and a time are that instant;
/// a day alone is 09:00 on it; a time or a part of the day alone is today; a
/// part of the day with no time is its start. A day the words could not
/// place ("this Monday" once it has passed), a duration alone, or an instant
/// at or before [now] is null — never rolled forward.
RemindChoice? resolveRemindText(
  String text, {
  required DateTime now,
  required CalendarZone zone,
}) {
  if (text.trim().isEmpty) return null;
  final r = resolveWhen(text, now: now, zone: zone, mode: WhenMode.booking);
  if (r.isEmpty || r.unresolvedReason != null) return null;
  final day = r.day ?? (r.time != null || r.part != null ? r.today : null);
  if (day == null) return null;
  final (hour, minute) = r.time ?? r.part?.start ?? (9, 0);
  final at = zone.localDateTime(day, hour, minute).toUtc();
  if (!at.isAfter(now.toUtc())) return null;
  return (
    id: 'typed',
    label: '${shortDate(day)}, ${formatEventTime(zone, at)}',
    atUtc: at,
  );
}

/// A follow-up's instant as the send toast says it: "Thu 9:00 AM", on
/// [zone]'s wall.
String followUpWhen(DateTime atUtc, CalendarZone zone) {
  final l = zone.toLocal(atUtc);
  final day = DateFormat('EEE').format(DateTime.utc(l.year, l.month, l.day));
  return '$day ${formatEventTime(zone, atUtc)}';
}
