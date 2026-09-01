import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/triage_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The grammar guarantees the answer's SHAPE. These are the cases where the
/// shape was fine and the content was not, which is the only thing standing
/// between a confused model and a row that renders wrong.
void main() {
  const task = TriageTask();

  test('a well-formed answer passes through, trimmed', () {
    final result = task.validate(const {
      'urgency': 'high',
      'category': 'work',
      'label': '  launch date  ',
      'summary': '  The launch date is Thursday.  ',
      'needs_action': true,
      'action_items': ['  Call Marisa  ', 'Send the copy'],
    });

    expect(result.urgency, 'high');
    expect(result.category, 'work');
    expect(result.label, 'launch date');
    expect(result.summary, 'The launch date is Thursday.');
    expect(result.needsAction, isTrue);
    expect(result.actionItems, ['Call Marisa', 'Send the copy']);
  });

  test('an unknown urgency falls back to the quiet middle', () {
    for (final value in const [
      'critical',
      'HIGH',
      '',
      Object(),
      42,
      null,
      ['high'],
    ]) {
      expect(
        task.validate({'urgency': value}).urgency,
        'normal',
        reason: 'urgency $value',
      );
    }
  });

  test('every enum member survives validation', () {
    for (final value in const ['low', 'normal', 'high', 'urgent']) {
      expect(task.validate({'urgency': value}).urgency, value);
    }
    for (final value in const [
      'work',
      'personal',
      'notification',
      'other',
    ]) {
      expect(task.validate({'category': value}).category, value);
    }
  });

  test('an unknown category falls back to other', () {
    expect(task.validate({'category': 'errand'}).category, 'other');
    expect(task.validate({'category': 7}).category, 'other');
  });

  test('a runaway label is capped at 40 characters', () {
    final result = task.validate({'label': 'w' * 90});
    expect(result.label.length, 40);
  });

  test('a missing label is empty, not a guess', () {
    expect(task.validate(const {}).label, isEmpty);
  });

  test('a non-string label is dropped rather than stringified', () {
    // The one free-text field, so there is no enum to catch a model that got
    // the type wrong — and "Instance of ..." is not what a message is about.
    for (final value in const [42, true, null, ['dinner'], {'a': 1}]) {
      expect(
        task.validate({'label': value}).label,
        isEmpty,
        reason: 'label $value',
      );
    }
  });

  test('a runaway summary is capped at 500 characters', () {
    final result = task.validate({'summary': 'x' * 900});
    expect(result.summary.length, 500);
  });

  test('a non-string summary is stringified rather than dropped', () {
    expect(task.validate({'summary': 12}).summary, '12');
  });

  test('needs_action is true only when it is literally true', () {
    expect(task.validate({'needs_action': true}).needsAction, isTrue);
    for (final value in const ['true', 1, 'yes', null, {}]) {
      expect(
        task.validate({'needs_action': value}).needsAction,
        isFalse,
        reason: 'needs_action $value',
      );
    }
  });

  test('action items: non-strings and blanks are dropped', () {
    final result = task.validate(const {
      'action_items': ['Call Sarah', 42, '', '   ', null, 'Send the LE'],
    });
    expect(result.actionItems, ['Call Sarah', 'Send the LE']);
  });

  test('action items are capped at three, keeping the first three', () {
    final result = task.validate(const {
      'action_items': ['one', 'two', 'three', 'four', 'five'],
    });
    expect(result.actionItems, ['one', 'two', 'three']);
  });

  test('a runaway action item is capped at 200 characters', () {
    final result = task.validate({
      'action_items': ['y' * 250],
    });
    expect(result.actionItems.single.length, 200);
  });

  test('a non-list action_items is read as none', () {
    expect(task.validate(const {'action_items': 'Call Sarah'}).actionItems,
        isEmpty);
  });

  test('an empty answer degrades to the fallback, field by field', () {
    final result = task.validate(const {});
    final fallback = TriageResult.fallback();
    expect(result.urgency, fallback.urgency);
    expect(result.category, fallback.category);
    expect(result.label, fallback.label);
    expect(result.summary, fallback.summary);
    expect(result.needsAction, fallback.needsAction);
    expect(result.actionItems, fallback.actionItems);
  });

  test('one bad field does not cost the others', () {
    final result = task.validate(const {
      'urgency': 'nonsense',
      'category': 'work',
      'label': 'shared doc',
      'summary': 'The notes are attached.',
      'needs_action': true,
      'action_items': ['Review the notes'],
    });
    expect(result.urgency, 'normal');
    expect(result.category, 'work');
    expect(result.label, 'shared doc');
    expect(result.summary, 'The notes are attached.');
    expect(result.actionItems, ['Review the notes']);
  });
}
