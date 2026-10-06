import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/providers/activity_provider.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The activity tick on its own: the one count eleven read models follow.
///
/// Widget tests, for the timer: the tick's window is a [Timer], and a widget
/// test fails when one is still pending as its body ends — which is the
/// assertion the dispose case below rests on.
void main() {
  late BondDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = testDb();
    container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
  });

  tearDown(() => db.close());

  Future<void> record(String entity) => container
      .read(activityLogProvider)
      .record('sync_mail', count: 1, entityId: entity);

  testWidgets('a burst inside one window moves the tick once', (tester) async {
    final seen = <int>[];
    final sub = container.listen<int>(
      activityTickProvider,
      (_, next) => seen.add(next),
    );

    await record('a');
    await record('b');
    await record('c');
    await tester.pump(const Duration(milliseconds: 100));
    expect(seen, isEmpty, reason: 'the window is still open');

    await tester.pump(activityTickWindow);
    expect(seen, [1]);

    await record('d');
    await tester.pump(activityTickWindow);
    expect(seen, [1, 2]);

    // The autoDispose check runs on a timer of its own, and a bare `pump()`
    // does not advance the clock a timer waits on.
    sub.close();
    await tester.pump(const Duration(milliseconds: 1));
    container.dispose();
  });

  testWidgets('nothing recorded, nothing ticks', (tester) async {
    final seen = <int>[];
    final sub = container.listen<int>(
      activityTickProvider,
      (_, next) => seen.add(next),
    );

    await tester.pump(const Duration(seconds: 2));
    expect(seen, isEmpty);

    // The autoDispose check runs on a timer of its own, and a bare `pump()`
    // does not advance the clock a timer waits on.
    sub.close();
    await tester.pump(const Duration(milliseconds: 1));
    container.dispose();
  });

  testWidgets('a tick let go mid-window leaves no timer and hears no more',
      (tester) async {
    // A pane opened and closed between two syncs: its provider goes away
    // before any tick reached it, with a window open. The subscription and
    // the window's timer have to go with it — a pending timer as this body
    // ends fails the test.
    final log = container.read(activityLogProvider);
    final seen = <int>[];
    final sub = container.listen<int>(
      activityTickProvider,
      (_, next) => seen.add(next),
    );

    await record('a');
    await tester.pump(const Duration(milliseconds: 100));
    sub.close();
    // An autoDispose provider is disposed by a timer of its own, just after
    // its last listener leaves — well inside the window still open.
    await tester.pump(const Duration(milliseconds: 1));

    // The recorder lives on and keeps recording; nothing is listening.
    await log.record('sync_mail', count: 1, entityId: 'b');
    await tester.pump(const Duration(seconds: 1));
    expect(seen, isEmpty);

    container.dispose();
  });
}
