/// Microsoft To Do's failures, one type per thing a caller does differently.
///
/// The bond-mcps `manage_todo_task` and `mark_mail_flag` tools answer a
/// refusal as data (`{"error": code, "reason": prose}`), and the codes are the
/// contract: the reason strings are prose and may change. The calendar's
/// errors (`calendar_errors.dart`) are the model; these are their To Do twins.
///
/// Auth failures are NOT here: [NotSignedIn] and [ReconsentRequired] (from
/// `backend_types.dart`) pass through UNWRAPPED, exactly as they do from every
/// other backend, because the session routing keys on them.
///
/// Every [message] is written for a person and is what `toString` gives, so a
/// strip or a toast can show the exception as it stands.
library;

/// `tasks_scope_missing`: the grant lacks Tasks.ReadWrite. Until the owner's
/// consent round every To Do call answers this, so it means "the feature is
/// not on yet" and is never retried as an error.
class TasksScopeMissing implements Exception {
  final String message;

  const TasksScopeMissing([
    this.message = 'Reminders need the To Do permission. Reconnect Microsoft '
        'for this workspace to grant it (Settings › Connection).',
  ]);

  @override
  String toString() => message;
}

/// `not_found`: the task or the list is gone (deleted in To Do, or its id is
/// malformed). On `ensure_list` it means To Do is not available for the
/// account. Retrying the same call cannot help.
class TasksGone implements Exception {
  final String message;

  const TasksGone([this.message = 'This To Do task no longer exists.']);

  @override
  String toString() => message;
}

/// Any other permanent refusal: `invalid_arguments`, `invalid_options`,
/// `invalid_action`, `external_sender`, … [code] is the server's, for routing
/// and the activity log; [reason] is the server's prose and is for a person
/// only.
class TasksRefused implements Exception {
  final String code;
  final String reason;

  const TasksRefused(this.code, this.reason);

  String get message => reason.isEmpty
      ? 'To Do refused this ($code).'
      : 'To Do refused this: $reason';

  @override
  String toString() => message;
}

/// There is no To Do on this backend at all (SDK mode, the sample sandbox).
/// [sentence] says what would give one.
class TasksUnavailable implements Exception {
  final String sentence;

  const TasksUnavailable(this.sentence);

  String get message => sentence;

  @override
  String toString() => sentence;
}

/// A failure worth retrying later: the transport dropped, or the tool itself
/// failed (a Graph 429, a 5xx). [statusCode] is the transport's HTTP status
/// when it had one.
class TasksTransient implements Exception {
  final String message;
  final int? statusCode;

  const TasksTransient(this.message, {this.statusCode});

  @override
  String toString() => message;
}
