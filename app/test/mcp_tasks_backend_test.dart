import 'dart:convert';

import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/tasks_backend.dart';
import 'package:bond_inbox/services/backend/tasks_errors.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_tasks_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// The To Do backend over MCP, with only the wire faked.
///
/// What is pinned is the WIRE: the exact tool name and args of every call,
/// with `options` decoded and compared as a map — `manage_todo_task` refuses
/// an unknown key (inside `linked_resource` too), so an extra or a `""` where
/// nothing belongs is a refusal nothing offline would notice — and the exact
/// exception each refusal code becomes, because the callers route on the
/// type.

/// A scripted client. Duplicated per test file on purpose — a shared fake is a
/// file that can break tests it is not in.
class _FakeMcp implements BondMcpClient {
  /// Per tool: the replies to give, in order. A Map is returned, anything else
  /// is thrown. The last entry is sticky.
  final Map<String, List<Object>> scripted;

  final List<({String tool, Map<String, Object?> args})> calls = [];

  _FakeMcp([this.scripted = const {}]);

  Map<String, Object?> get lastArgs => calls.last.args;

  /// The `options` arg of the last call, decoded.
  Map<String, Object?> get lastOptions =>
      (jsonDecode(lastArgs['options']! as String) as Map)
          .cast<String, Object?>();

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    calls.add((tool: name, args: args));
    final queue = scripted[name];
    if (queue == null || queue.isEmpty) return <String, dynamic>{};
    final reply = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (reply is Map<String, dynamic>) return reply;
    throw reply;
  }

  @override
  Future<void> close() async {}
}

/// A task row as `manage_todo_task` answers it (handoff §3.16).
Map<String, dynamic> _taskRow({
  String id = 'task-1',
  String status = 'notStarted',
  String reminderAtUtc = '2026-10-09T16:00:00Z',
  String dueDate = '2026-10-09',
  List<Map<String, dynamic>> links = const [],
  String webLink = '',
}) =>
    {
      'id': id,
      'list_id': 'list-1',
      'title': 'Reply to Dana: Q3 numbers',
      'status': status,
      'importance': 'normal',
      'body_text': '',
      'body_is_html': false,
      'due_date': dueDate,
      'reminder_at_utc': reminderAtUtc,
      'reminder_at': '2026-10-09T16:00:00.0000000',
      'reminder_timezone': 'UTC',
      'is_reminder_on': reminderAtUtc.isNotEmpty,
      'categories': <String>[],
      'linked_resources': links,
      'web_link': webLink,
      'created_utc': '2026-10-03T16:00:00Z',
      'last_modified_utc': '2026-10-03T16:00:00Z',
      'completed_utc': '',
    };

void main() {
  group('manage_todo_task', () {
    test('ensure_list sends the name and reads the id back', () async {
      final mcp = _FakeMcp({
        'manage_todo_task': [
          {'list_id': 'list-1', 'name': 'Bond follow-ups', 'created': true},
        ],
      });

      final list = await McpTasksBackend(mcp).ensureList();

      expect(mcp.calls.single.tool, 'manage_todo_task');
      expect(mcp.lastArgs['action'], 'ensure_list');
      expect(mcp.lastArgs.containsKey('list_id'), isFalse);
      expect(mcp.lastOptions, {'name': 'Bond follow-ups'});
      expect(list.id, 'list-1');
      expect(list.name, 'Bond follow-ups');
      expect(list.created, isTrue);
    });

    test('create sends every key the action takes, with the right shapes',
        () async {
      final mcp = _FakeMcp({
        'manage_todo_task': [
          _taskRow(links: [
            {
              'web_url': 'https://outlook.office365.com/owa/?ItemID=m1',
              'external_id': 'r1',
              'display_name': 'Reply to Dana: Q3 numbers',
              'application_name': 'Bond',
              'id': 'lr-1',
            },
          ]),
        ],
      });

      final task = await McpTasksBackend(mcp).createTask(
        listId: 'list-1',
        title: 'Reply to Dana: Q3 numbers',
        bodyText: 'Can you send the Q3 numbers by Friday?',
        dueDate: const CalendarDate(2026, 10, 9),
        dueTimeZone: 'Pacific Standard Time',
        // Microseconds on purpose: the wire carries whole seconds only.
        reminderAtUtc: DateTime.utc(2026, 10, 9, 16, 0, 0, 0, 123),
        status: 'waitingOnOthers',
        importance: 'high',
        link: const TodoLink(
          webUrl: 'https://outlook.office365.com/owa/?ItemID=m1',
          displayName: 'Reply to Dana: Q3 numbers',
          externalId: 'r1',
        ),
      );

      expect(mcp.lastArgs['action'], 'create');
      expect(mcp.lastArgs['list_id'], 'list-1');
      expect(mcp.lastOptions, {
        'title': 'Reply to Dana: Q3 numbers',
        'body_text': 'Can you send the Q3 numbers by Friday?',
        'due_date': '2026-10-09',
        'due_timezone': 'Pacific Standard Time',
        'reminder_at': '2026-10-09T16:00:00Z',
        'status': 'waitingOnOthers',
        'importance': 'high',
        'linked_resource': {
          'web_url': 'https://outlook.office365.com/owa/?ItemID=m1',
          'display_name': 'Reply to Dana: Q3 numbers',
          'external_id': 'r1',
        },
      });
      expect(task.id, 'task-1');
      expect(task.listId, 'list-1');
      expect(task.status, 'notStarted');
      expect(task.reminderAtUtc, '2026-10-09T16:00:00Z');
      expect(task.dueDate, '2026-10-09');
      expect(task.isReminderOn, isTrue);
      expect(task.links.single.externalId, 'r1');
      expect(task.links.single.webUrl,
          'https://outlook.office365.com/owa/?ItemID=m1');
      // Graph probably gives To Do tasks no webLink; "" reads as none.
      expect(task.webLink, isNull);
    });

    test('create omits every null rather than sending ""', () async {
      final mcp = _FakeMcp({
        'manage_todo_task': [_taskRow(reminderAtUtc: '', dueDate: '')],
      });

      final task = await McpTasksBackend(mcp).createTask(
        listId: 'list-1',
        title: 'Reply to Dana',
        // A zone with no date is meaningless to the server and is dropped.
        dueTimeZone: 'Pacific Standard Time',
      );

      expect(mcp.lastOptions, {
        'title': 'Reply to Dana',
        'status': 'notStarted',
        'importance': 'normal',
      });
      expect(task.reminderAtUtc, isNull);
      expect(task.dueDate, isNull);
      expect(task.isReminderOn, isFalse);
    });

    test('a link with no name or id sends only its address', () async {
      final mcp = _FakeMcp({'manage_todo_task': [_taskRow()]});

      await McpTasksBackend(mcp).createTask(
        listId: 'list-1',
        title: 'Reply to Dana',
        link: const TodoLink(webUrl: 'https://outlook.office365.com/x'),
      );

      expect(mcp.lastOptions['linked_resource'],
          {'web_url': 'https://outlook.office365.com/x'});
    });

    test('complete and delete name the task and send no options', () async {
      final mcp = _FakeMcp({
        'manage_todo_task': [
          _taskRow(status: 'completed'),
          {'ok': true, 'id': 'task-1', 'action': 'delete'},
        ],
      });
      final backend = McpTasksBackend(mcp);

      final done =
          await backend.completeTask(listId: 'list-1', taskId: 'task-1');
      expect(mcp.lastArgs,
          {'action': 'complete', 'list_id': 'list-1', 'task_id': 'task-1'});
      expect(done.status, 'completed');

      await backend.deleteTask(listId: 'list-1', taskId: 'task-1');
      expect(mcp.lastArgs,
          {'action': 'delete', 'list_id': 'list-1', 'task_id': 'task-1'});
    });

    test('list filters by external id and decodes every row', () async {
      final mcp = _FakeMcp({
        'manage_todo_task': [
          {
            'tasks': [
              _taskRow(links: [
                {'web_url': 'https://outlook.office365.com/x',
                    'external_id': 'r1'},
              ]),
              'not a row',
            ],
            'count': 1,
            'truncated': false,
          },
        ],
      });

      final tasks = await McpTasksBackend(mcp)
          .listTasks(listId: 'list-1', externalId: 'r1');

      expect(mcp.lastArgs['action'], 'list');
      expect(mcp.lastArgs['list_id'], 'list-1');
      expect(mcp.lastOptions, {'external_id': 'r1'});
      expect(tasks.single.id, 'task-1');
      expect(tasks.single.links.single.externalId, 'r1');
    });

    test('list with no filter sends no options at all', () async {
      final mcp = _FakeMcp({
        'manage_todo_task': [
          {'tasks': <Object>[], 'count': 0, 'truncated': false},
        ],
      });

      await McpTasksBackend(mcp).listTasks(listId: 'list-1');

      expect(mcp.lastArgs, {'action': 'list', 'list_id': 'list-1'});
    });
  });

  group('mark_mail_flag', () {
    test('sends the ids as a JSON array string and the due in Z', () async {
      final mcp = _FakeMcp({
        'mark_mail_flag': [
          {
            'updated': 1,
            'failed': [
              {'id': 'm2', 'error': 'not found', 'status': 404,
                  'code': 'ErrorItemNotFound'},
            ],
          },
        ],
      });

      final outcome = await McpTasksBackend(mcp).flagMessages(
        ['m1', 'm2'],
        status: 'flagged',
        dueUtc: DateTime.utc(2026, 10, 7, 16, 0, 0, 500),
      );

      expect(mcp.calls.single.tool, 'mark_mail_flag');
      expect(mcp.lastArgs['message_ids'], '["m1","m2"]');
      expect(mcp.lastArgs['status'], 'flagged');
      // A due without a start makes start = due (handoff §3.14): only the due.
      expect(mcp.lastOptions, {'due': '2026-10-07T16:00:00Z'});
      expect(outcome.updated, 1);
      expect(outcome.failed.single.id, 'm2');
      expect(outcome.failed.single.error, 'not found');
    });

    test('complete and notflagged send no options', () async {
      final mcp = _FakeMcp({
        'mark_mail_flag': [
          {'updated': 1, 'failed': <Object>[]},
        ],
      });

      await McpTasksBackend(mcp).flagMessages(['m1'], status: 'complete');

      expect(mcp.lastArgs, {'message_ids': '["m1"]', 'status': 'complete'});
    });
  });

  group('every refusal becomes the type its caller routes on', () {
    Future<Object> refusal(Map<String, dynamic> answer) async {
      final mcp = _FakeMcp({
        'manage_todo_task': [answer],
      });
      try {
        await McpTasksBackend(mcp).ensureList();
      } catch (e) {
        return e;
      }
      fail('no exception for $answer');
    }

    test('tasks_scope_missing is the feature being off', () async {
      final e = await refusal(
          {'error': 'tasks_scope_missing', 'reason': 'Graph 403'});
      expect(e, isA<TasksScopeMissing>());
      expect(e.toString(), contains('To Do permission'));
    });

    test('not_connected is a reconsent, unwrapped', () async {
      expect(
        await refusal({'error': 'not_connected', 'connect_url': 'x'}),
        isA<ReconsentRequired>(),
      );
    });

    test('not_found is gone', () async {
      expect(await refusal({'error': 'not_found', 'reason': '404'}),
          isA<TasksGone>());
    });

    test('the permanent codes are refusals carrying the code', () async {
      for (final code in [
        'external_sender',
        'invalid_options',
        'invalid_arguments',
        'invalid_action',
        'something_newer',
      ]) {
        final e = await refusal({'error': code, 'reason': 'prose'});
        expect(e, isA<TasksRefused>(), reason: code);
        expect((e as TasksRefused).code, code);
        expect(e.reason, 'prose');
      }
    });

    test('a tool error or a transport failure is transient', () async {
      for (final thrown in <Object>[
        const McpToolException('Graph 429'),
        const McpTransportException('reset', statusCode: 502),
      ]) {
        final mcp = _FakeMcp({
          'mark_mail_flag': [thrown],
        });
        await expectLater(
          McpTasksBackend(mcp).flagMessages(['m1'], status: 'complete'),
          throwsA(isA<TasksTransient>()),
        );
      }
    });

    test('a create answer with no task id is not a task', () async {
      final mcp = _FakeMcp({
        'manage_todo_task': [<String, dynamic>{}],
      });
      await expectLater(
        McpTasksBackend(mcp).createTask(listId: 'list-1', title: 'x'),
        throwsA(isA<TasksTransient>()),
      );
    });
  });

  test('the unavailable backend says what would give one, on every call',
      () async {
    const backend = UnavailableTasksBackend();
    final calls = <Future<Object?> Function()>[
      () => backend.ensureList(),
      () => backend.createTask(listId: 'l', title: 't'),
      () => backend.completeTask(listId: 'l', taskId: 't'),
      () => backend.deleteTask(listId: 'l', taskId: 't'),
      () => backend.listTasks(listId: 'l'),
      () => backend.flagMessages(['m'], status: 'flagged'),
    ];
    for (final call in calls) {
      await expectLater(
        call(),
        throwsA(isA<TasksUnavailable>().having((e) => e.sentence, 'sentence',
            'Reminders need the Bond server connection (Settings › Connection).')),
      );
    }
  });
}
