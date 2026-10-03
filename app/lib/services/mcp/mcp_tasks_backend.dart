import 'dart:convert';

import '../../models/calendar_models.dart' show CalendarDate;
import '../backend/backend_types.dart';
import '../backend/tasks_backend.dart';
import '../backend/tasks_errors.dart';
import 'bond_mcp_client.dart';
import 'mcp_calendar_backend.dart' show McpCalendarBackend;

/// Microsoft To Do and the mail flag, through bond-mcps' `manage_todo_task`
/// and `mark_mail_flag`.
///
/// The tool contract is bond-mcps' `docs/desktop-calendar-followups-handoff.md`
/// §3.14 and §3.16, and the calendar backend's rules hold here too:
///
/// - Every param is a string or an int; `options` is a JSON OBJECT ENCODED AS
///   A STRING, built with [jsonEncode].
/// - `manage_todo_task` refuses a key its action does not take (and an
///   unknown key inside `linked_resource`), so each action's options map is
///   built from exactly its own keys, and a null value is OMITTED rather than
///   sent as `""` — on a create `""` reads as absent, but the same key on an
///   update means "clear", and the habit is cheaper than the distinction.
/// - A refusal is data, `{"error": code, "reason": prose}`, routed on `code`
///   alone ([_call]); a tool error (Graph 429/5xx) is [TasksTransient].
///
/// Instants go out as UTC `YYYY-MM-DDTHH:MM:SSZ` ([McpCalendarBackend.utcWire]):
/// whole seconds, the form handoff §4.1 names for every new instant — never
/// the store's six-digit `isoStamp`.
class McpTasksBackend implements TasksBackend {
  final BondMcpClient _mcp;

  McpTasksBackend(this._mcp);

  @override
  Future<TodoList> ensureList({String name = 'Bond follow-ups'}) async {
    final result = await _call('manage_todo_task', {
      'action': 'ensure_list',
      'options': jsonEncode({'name': name}),
    });
    final id = _str(result['list_id']);
    if (id.isEmpty) {
      throw const TasksTransient('To Do answered no list id.');
    }
    return TodoList(
      id: id,
      name: _str(result['name']),
      created: result['created'] == true,
    );
  }

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
  }) async {
    final result = await _call('manage_todo_task', {
      'action': 'create',
      'list_id': listId,
      'options': jsonEncode({
        'title': title,
        if (bodyText != null && bodyText.isNotEmpty) 'body_text': bodyText,
        if (dueDate != null) 'due_date': dueDate.toIso(),
        // Only with a due date: the server reads the zone as that date's.
        if (dueDate != null && dueTimeZone != null && dueTimeZone.isNotEmpty)
          'due_timezone': dueTimeZone,
        if (reminderAtUtc != null)
          'reminder_at': McpCalendarBackend.utcWire(reminderAtUtc),
        'status': status,
        'importance': importance,
        if (link != null)
          'linked_resource': {
            'web_url': link.webUrl,
            'display_name': ?link.displayName,
            'external_id': ?link.externalId,
          },
      }),
    });
    return _task(result);
  }

  @override
  Future<TodoTask> completeTask({
    required String listId,
    required String taskId,
  }) async {
    final result = await _call('manage_todo_task', {
      'action': 'complete',
      'list_id': listId,
      'task_id': taskId,
    });
    return _task(result);
  }

  @override
  Future<void> deleteTask({
    required String listId,
    required String taskId,
  }) async {
    await _call('manage_todo_task', {
      'action': 'delete',
      'list_id': listId,
      'task_id': taskId,
    });
  }

  @override
  Future<List<TodoTask>> listTasks({
    required String listId,
    String? status,
    String? externalId,
  }) async {
    final options = {
      'status': ?status,
      'external_id': ?externalId,
    };
    final result = await _call('manage_todo_task', {
      'action': 'list',
      'list_id': listId,
      if (options.isNotEmpty) 'options': jsonEncode(options),
    });
    return [
      for (final raw in _list(result['tasks']))
        if (raw is Map) _task(Map<String, dynamic>.from(raw)),
    ];
  }

  @override
  Future<FlagOutcome> flagMessages(
    List<String> messageIds, {
    required String status,
    DateTime? dueUtc,
  }) async {
    final result = await _call('mark_mail_flag', {
      'message_ids': jsonEncode(messageIds),
      'status': status,
      // A `due` without a `start` makes start = due (handoff §3.14), as
      // Outlook's own flags do, so only the due is sent.
      if (dueUtc != null)
        'options': jsonEncode({'due': McpCalendarBackend.utcWire(dueUtc)}),
    });
    final updated = result['updated'];
    return FlagOutcome(
      updated: updated is int ? updated : 0,
      failed: [
        for (final raw in _list(result['failed']))
          if (raw is Map) (id: _str(raw['id']), error: _str(raw['error'])),
      ],
    );
  }

  // ── decoding ───────────────────────────────────────────────────────────

  static TodoTask _task(Map<String, dynamic> row) {
    final id = _str(row['id']);
    if (id.isEmpty) {
      throw const TasksTransient('To Do answered no task id.');
    }
    return TodoTask(
      id: id,
      listId: _str(row['list_id']),
      title: _str(row['title']),
      status: _str(row['status']),
      reminderAtUtc: _orNull(row['reminder_at_utc']),
      dueDate: _orNull(row['due_date']),
      isReminderOn: row['is_reminder_on'] == true,
      links: [
        for (final raw in _list(row['linked_resources']))
          if (raw is Map && _str(raw['web_url']).isNotEmpty)
            TodoLink(
              webUrl: _str(raw['web_url']),
              displayName: _orNull(raw['display_name']),
              externalId: _orNull(raw['external_id']),
            ),
      ],
      webLink: _orNull(row['web_link']),
    );
  }

  static List<Object?> _list(Object? raw) => raw is List ? raw : const [];

  static String _str(Object? raw) => raw is String ? raw : '';

  static String? _orNull(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;

  // ── the one call site ──────────────────────────────────────────────────

  /// Calls [tool] and routes its refusal, if any, to the matching type.
  ///
  /// Keyed on `error` only — `reason` is prose and may change. A tool error or
  /// a transport failure is [TasksTransient] (retry later); `not_connected`
  /// is [ReconsentRequired] and passes through unwrapped with the other auth
  /// failures the client throws; `tasks_scope_missing` is the feature being
  /// off until the consent round, never an error to retry.
  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, Object?> args,
  ) async {
    final Map<String, dynamic> result;
    try {
      result = await _mcp.callTool(tool, args);
    } on McpToolException catch (e) {
      throw TasksTransient(e.message);
    } on McpTransportException catch (e) {
      throw TasksTransient(e.message, statusCode: e.statusCode);
    }
    final error = result['error'];
    if (error is! String || error.isEmpty) return result;
    final reason = _str(result['reason']);
    switch (error) {
      case 'not_connected':
        throw const ReconsentRequired();
      case 'tasks_scope_missing':
        throw const TasksScopeMissing();
      case 'not_found':
        throw const TasksGone();
      default:
        // `external_sender`, `invalid_options`, `invalid_arguments`,
        // `invalid_action` and anything newer: permanent, for a person.
        throw TasksRefused(error, reason);
    }
  }
}
