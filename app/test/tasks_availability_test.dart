import 'package:bond_inbox/services/reminders/tasks_availability.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether To Do can carry a reminder, answered before any To Do call: the
/// `calendarPrecheck` shape, with one "not yet" for everything short of the
/// grant.
void main() {
  test('SDK mode has no To Do and asks nothing', () async {
    final asked = <String>[];
    final answer = await tasksPrecheck(true, (scope) async {
      asked.add(scope);
      return true;
    });
    expect(answer, TasksAvailability.sdkMode);
    expect(asked, isEmpty);
  });

  test('a grant holding tasks.readwrite is available', () async {
    final asked = <String>[];
    final answer = await tasksPrecheck(false, (scope) async {
      asked.add(scope);
      return true;
    });
    expect(answer, TasksAvailability.available);
    expect(asked, ['tasks.readwrite']);
  });

  test('a grant without it is the missing permission', () async {
    expect(await tasksPrecheck(false, (_) async => false),
        TasksAvailability.scopeMissing);
  });

  test('a probe that throws reads as missing, never as available', () async {
    expect(
      await tasksPrecheck(false, (_) async => throw StateError('offline')),
      TasksAvailability.scopeMissing,
    );
  });

  test('each state has its sentence, and available has none', () {
    expect(tasksUnavailableSentence(TasksAvailability.available), isNull);
    expect(tasksUnavailableSentence(TasksAvailability.scopeMissing),
        'Reminders need the To Do permission — Settings › Connection');
    expect(tasksUnavailableSentence(TasksAvailability.sdkMode),
        'Reminders need the Bond server connection (Settings › Connection).');
  });
}
