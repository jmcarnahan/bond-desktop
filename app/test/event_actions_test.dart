import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_writes.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/widgets/event_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(initCalendarZones);

  late CalendarZone la;
  late List<({CalendarWrite write, String summary, String done})> started;

  // Monday Oct 5 2026, 08:00 in Los Angeles; a test moves it on to show the
  // widget reads the clock at the moment it resolves, not when it was built.
  late DateTime now;

  setUp(() {
    la = CalendarZone.tryNamed('America/Los_Angeles')!;
    started = [];
    now = DateTime.utc(2026, 10, 5, 15);
  });

  const dana = Attendee(name: 'Dana Contoso', address: 'dana@contoso.com');
  const today = CalendarDate(2026, 10, 5);

  // Wednesday Oct 7, 10:00–11:00 PDT.
  CalendarEvent meeting({
    String id = 'e1',
    bool isOrganizer = false,
    List<Attendee> attendees = const [dana],
    bool isCancelled = false,
    String eventType = '',
    bool? allowNewTimeProposals,
    String responseStatus = 'none',
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Design review',
        isOrganizer: isOrganizer,
        attendees: attendees,
        isCancelled: isCancelled,
        eventType: eventType,
        allowNewTimeProposals: allowNewTimeProposals,
        responseStatus: responseStatus,
        startUtc: DateTime.utc(2026, 10, 7, 17),
        endUtc: DateTime.utc(2026, 10, 7, 18),
      );

  Future<void> pump(
    WidgetTester tester, {
    required CalendarEvent target,
    CalendarEvent? shown,
    bool compact = false,
    bool busy = false,
    String? respondId,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EventActions(
            target: target,
            shown: shown ?? target,
            zone: la,
            clock: () => now,
            today: today,
            busy: busy,
            compact: compact,
            respondId: respondId,
            start: (write, {required summary, required doneMessage}) =>
                started.add((write: write, summary: summary, done: doneMessage)),
          ),
        ),
      ));

  bool enabled(WidgetTester tester, Key key) =>
      tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

  group('buttons per role', () {
    testWidgets('an attendee answers, adds a note and proposes',
        (tester) async {
      await pump(tester, target: meeting());
      for (final key in [
        EventActions.yesKey,
        EventActions.maybeKey,
        EventActions.noKey,
        EventActions.addNoteKey,
        EventActions.proposeKey,
      ]) {
        expect(find.byKey(key), findsOneWidget);
      }
      expect(find.byKey(EventActions.moveKey), findsNothing);
      expect(find.byKey(EventActions.cancelKey), findsNothing);
      expect(find.byKey(EventActions.deleteKey), findsNothing);
    });

    testWidgets('proposals disallowed hide Propose', (tester) async {
      await pump(tester, target: meeting(allowNewTimeProposals: false));
      expect(find.byKey(EventActions.yesKey), findsOneWidget);
      expect(find.byKey(EventActions.proposeKey), findsNothing);
    });

    testWidgets('an organiser with guests moves and cancels, never answers',
        (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      expect(find.byKey(EventActions.moveKey), findsOneWidget);
      expect(find.byKey(EventActions.cancelKey), findsOneWidget);
      expect(find.byKey(EventActions.yesKey), findsNothing);
      expect(find.byKey(EventActions.deleteKey), findsNothing);
    });

    testWidgets('an own event moves and deletes', (tester) async {
      await pump(tester,
          target: meeting(isOrganizer: true, attendees: const []));
      expect(find.byKey(EventActions.moveKey), findsOneWidget);
      expect(find.byKey(EventActions.deleteKey), findsOneWidget);
      expect(find.byKey(EventActions.cancelKey), findsNothing);
      expect(find.byKey(EventActions.yesKey), findsNothing);

      await tester.tap(find.byKey(EventActions.deleteKey));
      expect(started.single.write, isA<DeleteEvent>());
      expect(started.single.summary, startsWith('Delete "Design review" · '));
    });

    testWidgets('a cancelled meeting an attendee holds is only removed',
        (tester) async {
      await pump(tester, target: meeting(isCancelled: true));
      expect(find.byKey(EventActions.yesKey), findsNothing);
      await tester.tap(find.byKey(EventActions.removeKey));
      expect((started.single.write as DeleteEvent).eventId, 'e1');
    });

    testWidgets('compact is RSVP only, and nothing for an organiser',
        (tester) async {
      await pump(tester, target: meeting(), compact: true);
      expect(find.byKey(EventActions.yesKey), findsOneWidget);
      expect(find.byKey(EventActions.addNoteKey), findsNothing);
      expect(find.byKey(EventActions.proposeKey), findsNothing);

      await pump(tester, target: meeting(isOrganizer: true), compact: true);
      expect(find.byKey(EventActions.moveKey), findsNothing);
      expect(find.byKey(EventActions.cancelKey), findsNothing);
      expect(find.byKey(EventActions.yesKey), findsNothing);
    });

    testWidgets('the current answer is chosen and not pressable',
        (tester) async {
      await pump(tester, target: meeting(responseStatus: 'accepted'));
      expect(enabled(tester, EventActions.yesKey), isFalse);
      expect(enabled(tester, EventActions.maybeKey), isTrue);
      expect(enabled(tester, EventActions.noKey), isTrue);
    });

    testWidgets('busy turns every button off', (tester) async {
      await pump(tester, target: meeting(), busy: true);
      expect(enabled(tester, EventActions.yesKey), isFalse);
      expect(enabled(tester, EventActions.noKey), isFalse);
    });
  });

  group('writes', () {
    testWidgets('a note rides the answer', (tester) async {
      await pump(tester, target: meeting());
      await tester.tap(find.byKey(EventActions.addNoteKey));
      await tester.pump();
      await tester.enterText(
          find.byKey(EventActions.noteFieldKey), 'Running late');
      await tester.tap(find.byKey(EventActions.noKey));

      final write = started.single.write as RespondToEvent;
      expect(write.response, RsvpResponse.decline);
      expect(write.comment, 'Running late');
      expect(write.eventId, 'e1');
      expect(started.single.summary, endsWith(' with your note'));
      expect(started.single.done, 'Declined "Design review".');
    });

    testWidgets('a series master answers every meeting', (tester) async {
      final master = meeting(id: 'master', eventType: 'seriesMaster');
      final occurrence = meeting(id: 'occ-1');
      await pump(tester, target: master, shown: occurrence);
      await tester.tap(find.byKey(EventActions.yesKey));
      expect(started.single.write.eventId, 'master');
      expect(started.single.summary,
          'Accept every meeting in "Design review"');
      expect(started.single.done,
          'Accepted every meeting in "Design review".');
    });

    testWidgets('a folded invite row answers through its respond id',
        (tester) async {
      final occurrence = meeting(id: 'occ-1');
      await pump(tester,
          target: occurrence, respondId: 'master', compact: true);
      await tester.tap(find.byKey(EventActions.maybeKey));
      expect(started.single.write.eventId, 'master');
      expect(started.single.summary, contains('every meeting in'));
    });

    testWidgets('the when field shows the absolute time, or the problem',
        (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      await tester.tap(find.byKey(EventActions.moveKey));
      await tester.pump();
      expect(find.byKey(EventActions.whenPreviewKey), findsNothing);

      await tester.enterText(find.byKey(EventActions.whenFieldKey), 'Thu 3pm');
      await tester.pump();
      expect(find.text('Thu Oct 8 · 3:00–4:00 PM'), findsOneWidget);
      expect(enabled(tester, EventActions.moveGoKey), isTrue);

      await tester.enterText(
          find.byKey(EventActions.whenFieldKey), 'tomorrow morning');
      await tester.pump();
      expect(find.text("Add a time — e.g. 'tomorrow 10am'."), findsOneWidget);
      expect(enabled(tester, EventActions.moveGoKey), isFalse);
    });

    testWidgets('Enter on a resolved move starts it, in UTC', (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      await tester.tap(find.byKey(EventActions.moveKey));
      await tester.pump();
      await tester.enterText(find.byKey(EventActions.whenFieldKey), 'Thu 3pm');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      final write = started.single.write as MoveEvent;
      expect(write.eventId, 'e1');
      expect(write.startUtc, DateTime.utc(2026, 10, 8, 22));
      expect(write.endUtc, DateTime.utc(2026, 10, 8, 23));
      expect(started.single.summary,
          'Move "Design review" to Thu Oct 8 · 3:00–4:00 PM');
    });

    testWidgets('Enter on an unresolved move starts nothing', (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      await tester.tap(find.byKey(EventActions.moveKey));
      await tester.pump();
      await tester.enterText(find.byKey(EventActions.whenFieldKey), 'soonish');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(started, isEmpty);
    });

    testWidgets('a proposal goes to the shown occurrence', (tester) async {
      final master = meeting(id: 'master', eventType: 'seriesMaster');
      final occurrence = meeting(id: 'occ-1');
      await pump(tester, target: master, shown: occurrence);
      await tester.tap(find.byKey(EventActions.proposeKey));
      await tester.pump();
      expect(enabled(tester, EventActions.proposeNoKey), isFalse);
      await tester.enterText(find.byKey(EventActions.whenFieldKey), 'Thu 3pm');
      await tester.pump();
      await tester.tap(find.byKey(EventActions.proposeNoKey));

      final write = started.single.write as RespondToEvent;
      expect(write.eventId, 'occ-1');
      expect(write.response, RsvpResponse.decline);
      expect(write.proposeStartUtc, DateTime.utc(2026, 10, 8, 22));
      expect(started.single.summary, contains(', proposing Thu Oct 8'));
      expect(started.single.summary, isNot(contains('every meeting')));
    });

    testWidgets('a time is resolved against the clock when it is sent, not '
        'when the panel was drawn', (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      await tester.tap(find.byKey(EventActions.moveKey));
      await tester.pump();
      await tester.enterText(find.byKey(EventActions.whenFieldKey), 'today 9am');
      await tester.pump();
      expect(enabled(tester, EventActions.moveGoKey), isTrue);

      // An hour and a half later, with the panel still standing: 9am has
      // passed, and the press that was live when drawn sends nothing.
      now = DateTime.utc(2026, 10, 5, 16, 30);
      await tester.tap(find.byKey(EventActions.moveGoKey));
      expect(started, isEmpty);
      // And the live preview reads the same clock on its next build.
      await tester.enterText(find.byKey(EventActions.whenFieldKey), 'today 9 am');
      await tester.pump();
      expect(find.text('That time has passed.'), findsOneWidget);
      expect(enabled(tester, EventActions.moveGoKey), isFalse);
    });

    testWidgets('Escape in the when field closes it and drops what was typed',
        (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      await tester.tap(find.byKey(EventActions.moveKey));
      await tester.pump();
      await tester.enterText(find.byKey(EventActions.whenFieldKey), 'Thu 3pm');
      await tester.pump();
      expect(find.byKey(EventActions.whenFieldKey), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(EventActions.whenFieldKey), findsNothing);
      expect(started, isEmpty);

      await tester.tap(find.byKey(EventActions.moveKey));
      await tester.pump();
      expect(find.text('Thu 3pm'), findsNothing);
    });

    testWidgets('Escape in a note field closes it too', (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      await tester.tap(find.byKey(EventActions.cancelKey));
      await tester.pump();
      await tester.enterText(
          find.byKey(EventActions.cancelNoteKey), 'Moving to next week');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(EventActions.cancelNoteKey), findsNothing);
      expect(find.byKey(EventActions.cancelGoKey), findsNothing);
    });

    testWidgets('cancel carries its note to everyone', (tester) async {
      await pump(tester, target: meeting(isOrganizer: true));
      await tester.tap(find.byKey(EventActions.cancelKey));
      await tester.pump();
      await tester.enterText(
          find.byKey(EventActions.cancelNoteKey), 'Moving to next week');
      await tester.tap(find.byKey(EventActions.cancelGoKey));

      final write = started.single.write as CancelMeeting;
      expect(write.eventId, 'e1');
      expect(write.comment, 'Moving to next week');
    });
  });
}
