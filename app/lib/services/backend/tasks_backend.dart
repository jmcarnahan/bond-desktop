import 'package:flutter/foundation.dart' show immutable;

import '../../models/calendar_models.dart' show CalendarDate;
import 'backend_types.dart';
import 'tasks_errors.dart';

/// Microsoft To Do and the mail flag: the carrier for the reminders the app
/// decides on (the calendar-automation round's D1/D7). To Do raises the
/// notification on every device, so the app raises none of its own.
///
/// MCP mode only. The MCP implementation speaks bond-mcps' `manage_todo_task`
/// and `mark_mail_flag` (handoff §3.14, §3.16); SDK mode and the sample
/// sandbox get [UnavailableTasksBackend], whose every method throws
/// [TasksUnavailable].
///
/// Time crosses this seam as UTC [DateTime]s (the reminder, the flag's due)
/// and a [CalendarDate] (the task's due date, a wall date with its zone named
/// beside it). The implementation formats them for the wire.
///
/// Failures are the types in `tasks_errors.dart`; until the owner's consent
/// round every call answers [TasksScopeMissing]. Auth failures —
/// [NotSignedIn], [ReconsentRequired] — pass through UNWRAPPED.
abstract class TasksBackend {
  /// The app's own list, found by name or created (`ensure_list`). Called
  /// once per account: the caller persists [TodoList.id], because the tool
  /// is find-then-create, not atomic.
  Future<TodoList> ensureList({String name = 'Bond follow-ups'});

  /// A new task on [listId]. [reminderAtUtc] turns its reminder on;
  /// [dueDate] is read in [dueTimeZone] (the IANA name of the zone the date
  /// was worked out in — the default UTC can show the date a day early in a
  /// western To Do app).
  /// [link] ties the task back to the mail and to the app's own row (its
  /// `externalId`).
  Future<TodoTask> createTask({
    required String listId,
    required String title,
    String? bodyText,
    CalendarDate? dueDate,
    String? dueTimeZone,
    DateTime? reminderAtUtc,
    String status = 'notStarted',
    String importance = 'normal',
    TodoLink? link,
  });

  /// Marks the task completed. [TasksGone] when it was deleted in To Do.
  Future<TodoTask> completeTask({
    required String listId,
    required String taskId,
  });

  /// Deletes the task. [TasksGone] when it was already deleted.
  Future<void> deleteTask({required String listId, required String taskId});

  /// The list's tasks, optionally only those of [status] or those linked to
  /// [externalId] (how a lost create is found again before retrying it).
  Future<List<TodoTask>> listTasks({
    required String listId,
    String? status,
    String? externalId,
  });

  /// Flags (or completes, or clears the flag on) up to 100 messages, best
  /// effort per message. [status] is `flagged`, `complete` or `notflagged`;
  /// [dueUtc] goes only with `flagged`.
  Future<FlagOutcome> flagMessages(
    List<String> messageIds, {
    required String status,
    DateTime? dueUtc,
  });
}

/// The app's To Do list, as `ensure_list` answers it.
@immutable
class TodoList {
  final String id;

  /// The list's own display name.
  final String name;

  /// True when this call created it.
  final bool created;

  const TodoList({required this.id, required this.name, this.created = false});
}

/// A linked resource on a task: the way back from To Do to the mail.
@immutable
class TodoLink {
  /// An http(s) address; the server refuses any other scheme.
  final String webUrl;
  final String? displayName;

  /// The app's own id for what the task carries (a reminder's id).
  final String? externalId;

  const TodoLink({required this.webUrl, this.displayName, this.externalId});
}

/// A task row as the tool answers it, the parts the app reads.
@immutable
class TodoTask {
  final String id;
  final String listId;
  final String title;

  /// `notStarted`, `inProgress`, `completed`, `waitingOnOthers`, `deferred`.
  final String status;

  /// The reminder as the tool sends it (`YYYY-MM-DDTHH:MM:SSZ`), or null when
  /// unset or not in UTC.
  final String? reminderAtUtc;

  /// `yyyy-MM-dd`, or null when unset.
  final String? dueDate;
  final bool isReminderOn;
  final List<TodoLink> links;

  /// Graph's `webLink` for the task; probably absent in v1.0 (handoff §7), so
  /// expect null.
  final String? webLink;

  const TodoTask({
    required this.id,
    required this.listId,
    required this.title,
    required this.status,
    this.reminderAtUtc,
    this.dueDate,
    this.isReminderOn = false,
    this.links = const [],
    this.webLink,
  });
}

/// `mark_mail_flag`'s answer: how many messages took the flag, and the ones
/// that did not with Graph's error for each.
@immutable
class FlagOutcome {
  final int updated;
  final List<({String id, String error})> failed;

  const FlagOutcome({required this.updated, this.failed = const []});
}

/// To Do where there is none: SDK mode (the direct-Graph sign-in asks for no
/// Tasks scope) and the sample sandbox. Every method throws the same
/// [TasksUnavailable], whose sentence says what would give one.
class UnavailableTasksBackend implements TasksBackend {
  const UnavailableTasksBackend();

  static const TasksUnavailable _why = TasksUnavailable(
    'Reminders need the Bond server connection (Settings › Connection).',
  );

  @override
  Future<TodoList> ensureList({String name = 'Bond follow-ups'}) async =>
      throw _why;

  @override
  Future<TodoTask> createTask({
    required String listId,
    required String title,
    String? bodyText,
    CalendarDate? dueDate,
    String? dueTimeZone,
    DateTime? reminderAtUtc,
    String status = 'notStarted',
    String importance = 'normal',
    TodoLink? link,
  }) async =>
      throw _why;

  @override
  Future<TodoTask> completeTask({
    required String listId,
    required String taskId,
  }) async =>
      throw _why;

  @override
  Future<void> deleteTask({
    required String listId,
    required String taskId,
  }) async =>
      throw _why;

  @override
  Future<List<TodoTask>> listTasks({
    required String listId,
    String? status,
    String? externalId,
  }) async =>
      throw _why;

  @override
  Future<FlagOutcome> flagMessages(
    List<String> messageIds, {
    required String status,
    DateTime? dueUtc,
  }) async =>
      throw _why;
}
