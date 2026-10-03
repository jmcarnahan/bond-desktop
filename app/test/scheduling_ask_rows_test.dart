import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/find_time.dart';
import 'package:bond_inbox/widgets/scheduling_ask_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a screen reader hears from one scheduling ask: the length pills say
/// minutes, a pill says whether it is the chosen one without reading as
/// disabled, and the × is a named button. Fictional thread.
void main() {
  late CalendarZone la;

  setUpAll(() async {
    await initCalendarZones();
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
  });

  late List<String> dismissed;
  late List<int> minutes;

  setUp(() {
    dismissed = [];
    minutes = [];
  });

  Future<void> pumpTile(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          child: SchedulingAskTile(
            row: const SchedulingAskRow(
              source: 'email',
              key: 'c-ask',
              subject: 'Coffee next week?',
              askedBy: 'Dana Reyes',
              expanded: true,
            ),
            zone: la,
            callbacks: SchedulingAskCallbacks(
              onToggle: (_, _) {},
              onMinutes: (_, _, m) => minutes.add(m),
              onWindow: (_, _, _) {},
              onPickSlot: (_, _, _) {},
              onPutInReply: (_, _) {},
              onOpen: (_, _) {},
              onDismiss: (s, k) => dismissed.add('$s|$k'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('a length pill says minutes, not a bare number', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpTile(tester);
    expect(
      tester.getSemantics(
          find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 45))),
      isSemantics(label: '45 minutes', isButton: true),
    );
    handle.dispose();
  });

  testWidgets('the chosen pill reads selected and not disabled; the others '
      'read unselected and still tap', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpTile(tester);
    expect(
      tester.getSemantics(
          find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 30))),
      isSemantics(
        isButton: true,
        isSelected: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: false,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(SchedulingAskTile.windowKeyFor(
          'email', 'c-ask', FindTimeWindow.thisWeek))),
      isSemantics(isButton: true, isSelected: true, isEnabled: true),
    );
    expect(
      tester.getSemantics(
          find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 60))),
      isSemantics(
        isButton: true,
        isSelected: false,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(
        find.byKey(SchedulingAskTile.minutesKeyFor('email', 'c-ask', 60)));
    expect(minutes, [60]);
    handle.dispose();
  });

  testWidgets('the × is a button named for what it does', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpTile(tester);
    final dismiss = find.byKey(SchedulingAskTile.dismissKeyFor('email', 'c-ask'));
    expect(
      tester.getSemantics(dismiss),
      isSemantics(
          label: 'Dismiss ask', isButton: true, hasTapAction: true),
    );
    await tester.tap(dismiss);
    expect(dismissed, ['email|c-ask']);
    handle.dispose();
  });
}
