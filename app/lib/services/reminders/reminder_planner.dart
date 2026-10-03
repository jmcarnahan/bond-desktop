import '../../data/message_store.dart';
import '../backend/tasks_errors.dart' show TasksRefused;
import '../../models/message_models.dart' show Conversation, Message;
import '../../models/reminder_models.dart';
import '../calendar/ask_words.dart' show askOwnWords;
import '../calendar/calendar_zone.dart';
import '../decision/needs_you_predicate.dart' show isNeedsYou;
import 'remind_choices.dart' show remindDeadlineDay, replyToName;
import 'reminder_service.dart';
import 'tasks_availability.dart';

/// The deadline reminders (D7): a Needs You thread whose newest inbound
/// message named a deadline gets ONE To Do reminder at 09:00 on that day.
///
/// Run on the poll after [ReminderService.reconcile], over the conversation
/// list the inbox already holds. Plans nothing while the owner's switch
/// (`remind_deadlines`) is off or To Do is unavailable, never a second
/// reminder for a thread that has an active one of any kind, never a 09:00
/// that has already passed, and at most [perPass] a pass.
///
/// A thread whose task To Do refuses ([TasksRefused]) is skipped and
/// remembered for the life of the planner, so one bad thread neither wedges
/// the pass nor is offered to To Do again every poll; any other failure ends
/// the pass.
class ReminderPlanner {
  final MessageStore _store;
  final ReminderService _service;
  final bool Function() _enabled;
  final Future<TasksAvailability> Function() _availability;
  final DateTime Function() _clock;

  ReminderPlanner({
    required this._store,
    required this._service,
    required this._enabled,
    required this._availability,
    this._clock = DateTime.now,
  });

  /// `'<source>|<conversation key>'` of the threads To Do refused, kept in
  /// memory only: an app restart offers them once more.
  final Set<String> _refused = {};

  /// The most reminders one pass creates; the rest wait a poll.
  static const int perPass = 5;

  /// The hour on the deadline's day the reminder fires, on the owner's wall.
  static const int remindHour = 9;

  /// Plans the deadline reminders owed over [conversations]; returns how
  /// many were created. A create that throws ends the pass and propagates,
  /// so a missing permission or a lost connection is not met five times —
  /// except [TasksRefused], which is about that one thread: it is skipped,
  /// remembered, and the pass goes on.
  Future<int> plan({
    required CalendarZone zone,
    required double needsYouThreshold,
    required List<Conversation> conversations,
  }) async {
    if (!_enabled()) return 0;
    if (await _availability() != TasksAvailability.available) return 0;
    final now = _clock();
    final today = zone.dateOf(now);
    var created = 0;
    for (final c in conversations) {
      if (created >= perPass) break;
      if (!isNeedsYou(c, threshold: needsYouThreshold)) continue;
      final key = '${c.source}|${c.id}';
      if (_refused.contains(key)) continue;
      final day = remindDeadlineDay(c, now);
      if (day == null || day.isBefore(today)) continue;
      final remindAt = zone.localDateTime(day, remindHour, 0).toUtc();
      if (!remindAt.isAfter(now)) continue;
      if (await _store.hasActiveReminder(c.source, c.id)) continue;
      final newest = await _newestInbound(c);
      final subject = c.subject?.trim() ?? '';
      try {
        await _service.create(ReminderRequest(
          kind: ReminderKind.deadline,
          source: c.source,
          conversationKey: c.id,
          anchorMessageId: newest?.id ?? '',
          title: 'Reply to ${replyToName(c, newest)}: '
              '${subject.isEmpty ? '(no subject)' : subject}',
          remindAtUtc: remindAt,
          createdFrom: ReminderOrigin.auto,
          bodyText: _bodyOf(newest),
          anchorWebLink: newest?.webLink,
        ));
      } on TasksRefused {
        _refused.add(key);
        continue;
      }
      created++;
    }
    return created;
  }

  Future<Message?> _newestInbound(Conversation c) async {
    final thread = await _store.loadThread(c.id, sources: [c.source]);
    for (final m in thread.reversed) {
      if (!m.outbound) return m;
    }
    return null;
  }

  /// The ask's own words (above any quoted reply), for the task body; the
  /// service caps it.
  static String? _bodyOf(Message? m) {
    final text = m?.bodyText ?? m?.bodyPreview;
    if (text == null) return null;
    final own = askOwnWords(text).trim();
    return own.isEmpty ? null : own;
  }
}
