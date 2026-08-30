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
