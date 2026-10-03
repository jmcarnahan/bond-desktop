/// Whether reminders can be carried by To Do right now, answered before any
/// To Do call.
enum TasksAvailability {
  /// The grant holds Tasks.ReadWrite: To Do calls go ahead.
  available,

  /// MCP mode without Tasks.ReadWrite — every install until the owner's
  /// consent round (bond-mcps handoff §6). Unavailable, never an error.
  scopeMissing,

  /// SDK mode or the sample sandbox: there is no To Do on this backend.
  sdkMode,
}

/// The `calendarPrecheck` shape for To Do: [sdkMode] has no To Do, a grant
/// holding `tasks.readwrite` is [TasksAvailability.available], and anything
/// else — a grant without it, or a probe that could not answer or threw — is
/// [TasksAvailability.scopeMissing]. Unlike the calendar there is no separate
/// "the server is down" state: either way nothing is written, and the owner's
/// one way forward is the same sentence.
Future<TasksAvailability> tasksPrecheck(
  bool sdkMode,
  Future<bool> Function(String scope) hasScope,
) async {
  if (sdkMode) return TasksAvailability.sdkMode;
  try {
    return await hasScope('tasks.readwrite')
        ? TasksAvailability.available
        : TasksAvailability.scopeMissing;
  } on Object {
    return TasksAvailability.scopeMissing;
  }
}

/// What a surface says when reminders cannot be set; null when they can.
String? tasksUnavailableSentence(TasksAvailability availability) =>
    switch (availability) {
      TasksAvailability.available => null,
      TasksAvailability.scopeMissing =>
        'Reminders need the To Do permission — Settings › Connection',
      TasksAvailability.sdkMode =>
        'Reminders need the Bond server connection (Settings › Connection).',
    };
