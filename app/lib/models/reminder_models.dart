import 'package:flutter/foundation.dart' show immutable;

/// Why a reminder exists. The wire word is what the `reminders.kind` column
/// and every activity row hold.
enum ReminderKind {
  /// The owner's own "Remind me" on a thread they owe an answer.
  replyBy,

  /// "Follow up if no reply", set at send: the owner is waiting on someone.
  followUp,

  /// The deadline planner's: a Needs You thread with a deadline, reminded at
  /// 09:00 on its day.
  deadline,

  /// Anything else the owner set by hand.
  custom;

  /// An unknown word reads as [custom], the kind with no completion rule of
  /// its own beyond the thread being answered or done.
  static ReminderKind fromWire(String? value) => switch (value) {
        'reply_by' => ReminderKind.replyBy,
        'follow_up' => ReminderKind.followUp,
        'deadline' => ReminderKind.deadline,
        _ => ReminderKind.custom,
      };

  String get wire => switch (this) {
        ReminderKind.replyBy => 'reply_by',
        ReminderKind.followUp => 'follow_up',
        ReminderKind.deadline => 'deadline',
        ReminderKind.custom => 'custom',
      };
}

/// Where a reminder is in its life. Only [active] ones are reconciled, drawn
/// or counted as "a reminder on this thread".
enum ReminderStatus {
  active,
  done,
  cancelled;

  /// An unknown word reads as [cancelled]: a row nobody can read is not one
  /// to act on or to complete a task for.
  static ReminderStatus fromWire(String? value) => switch (value) {
        'active' => ReminderStatus.active,
        'done' => ReminderStatus.done,
        _ => ReminderStatus.cancelled,
      };

  String get wire => name;
}

/// Which door a reminder came in by: the thread bar, the composer's Send, or
/// the deadline planner.
enum ReminderOrigin {
  bar,
  send,
  auto;

  /// An unknown word reads as [auto], the one origin no person chose.
  static ReminderOrigin fromWire(String? value) => switch (value) {
        'bar' => ReminderOrigin.bar,
        'send' => ReminderOrigin.send,
        _ => ReminderOrigin.auto,
      };

  String get wire => name;
}

/// One row of `reminders`: a reminder the app placed in Microsoft To Do, and
/// the task that carries it. Every column, typed; the stamps stay strings in
/// the store's `isoStamp` width, so SQL string order is chronological.
@immutable
class Reminder {
  /// 32 hex characters; also the task's `external_id` when the task carries
  /// a link (`external_id` rides inside `linked_resource`).
  final String id;
  final ReminderKind kind;
  final String source;
  final String conversationKey;

  /// The message the reminder is about: the newest inbound for a reply or a
  /// deadline, the sent reply for a follow-up (a `local:` echo id until the
  /// Sent Items copy lands). Empty when none is known.
  final String anchorMessageId;
  final String title;

  /// When To Do raises the reminder, `isoStamp` UTC.
  final String remindAt;

  /// The task's due date, `yyyy-mm-dd` on the owner's wall; empty when none.
  final String dueDate;
  final ReminderStatus status;
  final ReminderOrigin createdFrom;
  final String todoListId;
  final String todoTaskId;

  /// The Graph id of the message flagged for a follow-up; empty when nothing
  /// was flagged (yet).
  final String flagMessageId;
  final String createdAt;
  final String updatedAt;
  final String? doneAt;

  const Reminder({
    required this.id,
    required this.kind,
    required this.source,
    required this.conversationKey,
    this.anchorMessageId = '',
    required this.title,
    required this.remindAt,
    this.dueDate = '',
    required this.status,
    required this.createdFrom,
    this.todoListId = '',
    this.todoTaskId = '',
    this.flagMessageId = '',
    required this.createdAt,
    required this.updatedAt,
    this.doneAt,
  });

  /// [remindAt] as an instant.
  DateTime get remindAtUtc => DateTime.parse(remindAt).toUtc();

  bool get isActive => status == ReminderStatus.active;

  /// A row as `SELECT * FROM reminders` gives it.
  factory Reminder.fromRow(Map<String, Object?> row) => Reminder(
        id: row['id']! as String,
        kind: ReminderKind.fromWire(row['kind'] as String?),
        source: row['source']! as String,
        conversationKey: row['conversation_key']! as String,
        anchorMessageId: row['anchor_message_id'] as String? ?? '',
        title: row['title']! as String,
        remindAt: row['remind_at']! as String,
        dueDate: row['due_date'] as String? ?? '',
        status: ReminderStatus.fromWire(row['status'] as String?),
        createdFrom: ReminderOrigin.fromWire(row['created_from'] as String?),
        todoListId: row['todo_list_id'] as String? ?? '',
        todoTaskId: row['todo_task_id'] as String? ?? '',
        flagMessageId: row['flag_message_id'] as String? ?? '',
        createdAt: row['created_at']! as String,
        updatedAt: row['updated_at']! as String,
        doneAt: row['done_at'] as String?,
      );

  /// The columns, keyed as the table names them.
  Map<String, Object?> toRow() => {
        'id': id,
        'kind': kind.wire,
        'source': source,
        'conversation_key': conversationKey,
        'anchor_message_id': anchorMessageId,
        'title': title,
        'remind_at': remindAt,
        'due_date': dueDate,
        'status': status.wire,
        'created_from': createdFrom.wire,
        'todo_list_id': todoListId,
        'todo_task_id': todoTaskId,
        'flag_message_id': flagMessageId,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'done_at': doneAt,
      };

  @override
  String toString() => 'Reminder($id, ${kind.wire}, ${status.wire})';
}
