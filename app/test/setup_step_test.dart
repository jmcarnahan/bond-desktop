import 'package:bond_inbox/models/setup_step.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one thing about the wizard that is PERSISTED, and therefore the one
/// thing a later build can get wrong.
///
/// A stored word must round-trip, an unknown word must land somewhere safe,
/// and the chain has to run end to end — a `next` that returned null in the
/// middle would strand somebody on step four forever.
void main() {
  test('every step round-trips through its stored name', () {
    for (final step in SetupStep.values) {
      expect(SetupStep.parse(step.name), step, reason: step.name);
    }
  });

  test('an unknown or absent word opens the wizard at the top', () {
    // A value written by another build, and a store with no row at all. Both
    // answer welcome, because the first screen costs a click and a guess
    // costs a machine that was never checked.
    expect(SetupStep.parse('sombrero'), SetupStep.welcome);
    expect(SetupStep.parse(null), SetupStep.welcome);
    expect(SetupStep.parse(''), SetupStep.welcome);
  });

  test('the chain runs from welcome to done and back', () {
    final forwards = <SetupStep>[SetupStep.welcome];
    while (forwards.last.next != null) {
      forwards.add(forwards.last.next!);
    }
    expect(forwards, SetupStep.values);
    expect(SetupStep.done.next, isNull);
    expect(SetupStep.welcome.previous, isNull);

    final backwards = <SetupStep>[SetupStep.done];
    while (backwards.last.previous != null) {
      backwards.add(backwards.last.previous!);
    }
    expect(backwards.reversed.toList(), SetupStep.values);
  });

  test('the counter reads 1 of 9 through 9 of 9', () {
    expect(SetupStep.count, 9);
    expect(SetupStep.welcome.number, 1);
    expect(SetupStep.done.number, 9);
    for (final step in SetupStep.values) {
      expect(step.number, step.index + 1);
    }
  });

  test('Where the models run sits between the device and the models steps',
      () {
    // The placement decides which models the next three steps are about, so
    // it has to be answered before the models, storage and download steps
    // size anything.
    expect(SetupStep.device.next, SetupStep.where);
    expect(SetupStep.where.next, SetupStep.models);
    expect(SetupStep.where.previous, SetupStep.device);
    expect(SetupStep.where.number, 3);
  });

  test('every step has the title the pane shows', () {
    expect(SetupStep.welcome.title, 'Welcome to Bond');
    expect(SetupStep.device.title, 'Your Mac');
    expect(SetupStep.where.title, 'Where the models run');
    expect(SetupStep.models.title, 'Models');
    expect(SetupStep.storage.title, 'Storage');
    expect(SetupStep.download.title, 'Download');
    expect(SetupStep.signIn.title, 'Sign in');
    expect(SetupStep.notifications.title, 'Notifications');
    expect(SetupStep.done.title, 'All set');
    // The persisted form is the enum's own name, and `signIn` is the one with
    // a capital in it — a step that stored a title would store a sentence.
    expect(SetupStep.signIn.name, 'signIn');
    expect(SetupStep.done.name, 'done');
  });
}
