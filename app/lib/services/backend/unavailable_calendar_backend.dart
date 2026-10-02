import '../../models/calendar_models.dart';
import 'calendar_backend.dart';
import 'calendar_errors.dart';

/// The calendar in SDK mode: there is none (D11).
///
/// The direct-Graph sign-in asks for no Calendars scope and this app carries
/// no Graph-SDK calendar code — the calendar is a bond-mcps feature, and SDK
/// mode is the minority path. So every method throws the same
/// [CalendarUnavailable], whose sentence says what would give one, rather
/// than answering an empty calendar that would read as "you have no
/// meetings".
class UnavailableCalendarBackend implements CalendarBackend {
  const UnavailableCalendarBackend();

  static const CalendarUnavailable _why = CalendarUnavailable(
    'The calendar needs the Bond server connection (Settings › Connection).',
  );

  @override
  Future<CalendarSyncPage> syncPage({
    String cursor = '',
    String? startUtc,
    String? endUtc,
  }) async =>
      throw _why;

  @override
  Future<CalendarEvent> getEvent(String id) async => throw _why;

  @override
  Future<MailboxSettings> mailboxSettings() async => throw _why;

  @override
  Future<CalendarWriteResult> respond(
    String id, {
    required String response,
    String? comment,
    bool sendResponse = true,
    DateTime? proposedStartUtc,
    DateTime? proposedEndUtc,
    bool dryRun = false,
  }) async =>
      throw _why;

  @override
  Future<CalendarWriteResult> update(
    String id, {
    required String ifMatch,
    DateTime? startUtc,
    DateTime? endUtc,
    CalendarDate? startDate,
    CalendarDate? endDate,
    String? allDayZone,
    String? subject,
    String? location,
    String? showAs,
    bool dryRun = false,
  }) async =>
      throw _why;

  @override
  Future<CalendarWriteResult> cancel(
    String id, {
    String? comment,
    bool dryRun = false,
  }) async =>
      throw _why;

  @override
  Future<CalendarWriteResult> delete(String id, {bool dryRun = false}) async =>
      throw _why;

  @override
  Future<CalendarWriteResult> create({
    required String subject,
    required DateTime startUtc,
    required DateTime endUtc,
    List<String> attendees = const [],
    bool isOnlineMeeting = false,
    String? body,
    required String transactionId,
    bool dryRun = false,
  }) async =>
      throw _why;

  @override
  Future<MeetingTimes> findMeetingTimes({
    required List<String> attendees,
    required int durationMinutes,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    int maxCandidates = 5,
  }) async =>
      throw _why;
}
