import 'package:intl/intl.dart';

/// The inbox's one timestamp format, shared by the list rows and the message
/// bubbles so a thread never reads two ways. Null for anything unparseable —
/// a bad timestamp renders as nothing, never as an exception or a raw ISO
/// string.
String? formatTimestamp(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;
  return DateFormat('MMM d, h:mm a').format(parsed.toLocal());
}

/// The Inbox table's stamp: `h:mm a` for something that arrived today,
/// `MMM d, h:mm a` for anything else. Null for anything unparseable, exactly as
/// [formatTimestamp] is.
///
/// [formatTimestamp]'s neighbour rather than a flag on it, because they answer
/// different questions. That one is the stamp on a message in a thread, where
/// the day is always worth stating; this one is a column in a table a reader
/// scans, and the day is dropped ONLY when it is today's — which is the one day
/// they can infer without being told.
///
/// The comparison is on the LOCAL calendar day for [dayKeyOfIso]'s reason: the
/// day a message belongs to is the day the reader was living in when it
/// arrived, and a UTC comparison would print this evening's mail with
/// tomorrow's date on it for anyone west of Greenwich.
String? feedStamp(String? iso, DateTime now) {
  if (iso == null || iso.isEmpty) return null;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;
  final local = parsed.toLocal();
  final today = now.toLocal();
  final sameDay = local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  return DateFormat(sameDay ? 'h:mm a' : 'MMM d, h:mm a').format(local);
}

/// How long ago [iso] was, in the one unit that matters at that distance —
/// "just now", "4m ago", "3h ago", "2d ago". Null for null and for anything
/// unparseable, which reads as "never" upstream.
///
/// One unit, never two: this is a caption under a refresh button, and its
/// whole job is to answer "is what I am looking at current?". "1h 24m ago"
/// answers that no better than "1h ago" and takes twice the width.
///
/// A timestamp in the future — a clock skewed between this machine and
/// Microsoft's — reads as "just now" rather than as a negative age.
///
/// [now] is passed rather than read from the clock so a test can pin it.
String? relativeTime(String? iso, DateTime now) {
  if (iso == null || iso.isEmpty) return null;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;

  // Both sides are absolute instants, so this is correct whichever zone
  // either one is expressed in.
  final elapsed = now.difference(parsed);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}

/// The calendar day a lookback window reaches, as `Aug 22, 2026`.
///
/// Formatted from the components exactly as given, with deliberately no
/// `toLocal()`: the caller passes a UTC-midnight day it computed itself, and a
/// zone conversion would render it as the previous local day for anyone west
/// of Greenwich — which would name a day the sync does not actually reach.
String absoluteDay(DateTime day) => DateFormat('MMM d, yyyy').format(day);

/// The local calendar day an ISO timestamp falls on, as `yyyy-mm-dd`. Null
/// when it does not parse, which reads as "no day" upstream — a transcript
/// drops the divider, a digest drops the group.
///
/// Local, not UTC: the day a message belongs to is the day the reader was
/// living in when it arrived, and grouping by UTC puts an evening's mail under
/// tomorrow for anyone west of Greenwich.
String? dayKeyOfIso(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;
  final local = parsed.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// The day-divider label for a transcript: "Today" and "Yesterday" for the
/// two days a reader thinks of by name, a weekday-qualified date for the rest.
/// Null for anything unparseable, so a bad timestamp drops the divider rather
/// than drawing an empty one.
String? formatDayLabel(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;

  final local = parsed.toLocal();
  final now = DateTime.now();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);

  // Whole calendar days apart, not elapsed hours: "yesterday at 11pm" is
  // yesterday even when it was ninety minutes ago.
  final delta = today.difference(day).inDays;
  if (delta == 0) return 'Today';
  if (delta == 1) return 'Yesterday';
  return DateFormat('EEE, MMM d').format(local);
}

/// How far ahead [iso] is, in the words a reminder is read in — "tomorrow",
/// "in 3 days", "in 2 weeks" — and the absolute day once it is far enough out
/// that a count of days stops meaning anything.
///
/// [relativeTime]'s mirror, and a separate function rather than a sign flip on
/// it: that one answers "is what I am looking at current?" in units of hours,
/// while this one answers "when does this come back?" in units of days, and no
/// reminder is ever usefully "in 14h".
///
/// A date already past reads as "today" rather than as a negative age. Such a
/// row is on its way back on the next list load anyway, and a countdown into
/// the negative would be a number nobody can act on. Null for null and for
/// anything unparseable, which drops the caption upstream.
String? untilLabel(String? iso, DateTime now) {
  if (iso == null || iso.isEmpty) return null;
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;

  // Whole calendar days apart, not elapsed hours: something due at nine
  // tomorrow morning is "tomorrow" whether it is now midnight or now noon.
  final local = parsed.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final delta = day.difference(today).inDays;

  if (delta <= 0) return 'today';
  if (delta == 1) return 'tomorrow';
  if (delta < 7) return 'in $delta days';
  if (delta < 28) {
    final weeks = delta ~/ 7;
    return weeks == 1 ? 'in 1 week' : 'in $weeks weeks';
  }
  return absoluteDay(day);
}
