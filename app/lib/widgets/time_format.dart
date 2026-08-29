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
