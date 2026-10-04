import 'package:bond_inbox/models/calendar_models.dart';
import 'package:bond_inbox/services/calendar/calendar_sync.dart'
    show CalendarAvailability;
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/day_items.dart'
    show offlineCaption;
import 'package:bond_inbox/services/calendar/event_view.dart';
import 'package:bond_inbox/services/calendar/overlaps.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/day_pane.dart';
import 'package:bond_inbox/widgets/event_panel.dart';
import 'package:bond_inbox/widgets/event_standing_style.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The event panel's body, prop-only: a pinned clock, a named zone, and
/// everything found by key or by its words. Bare pumps only — the Join row
/// holds a periodic timer.
void main() {
  setUpAll(initCalendarZones);

  // Tuesday Sep 29 2026, 9:00 AM in Los Angeles.
  final now = DateTime.utc(2026, 9, 29, 16);
  const today = CalendarDate(2026, 9, 29);
  const join = 'https://teams.example.com/l/meetup-join/fictional';
  const outlook = 'https://outlook.example.com/calendar/item/fictional';

  CalendarEvent meeting({
    String id = 'e1',
    DateTime? start,
    String joinUrl = join,
    String webLink = '',
    bool isCancelled = false,
    List<Attendee> attendees = const [],
    String bodyPreview = '',
    String eventType = 'singleInstance',
    String seriesMasterId = '',
    String responseStatus = 'accepted',
    bool isOrganizer = false,
  }) {
    final s = start ?? DateTime.utc(2026, 9, 29, 17);
    return CalendarEvent(
      id: id,
      subject: 'Design review',
      eventType: eventType,
      seriesMasterId: seriesMasterId,
      startUtc: s,
      endUtc: s.add(const Duration(minutes: 30)),
      joinUrl: joinUrl,
      webLink: webLink,
      isCancelled: isCancelled,
      attendees: attendees,
      bodyPreview: bodyPreview,
      organizerName: 'Dana Ortiz',
      organizerAddress: 'dana.ortiz@contoso.com',
      location: 'Room 4B',
      responseStatus: responseStatus,
      isOrganizer: isOrganizer,
    );
  }

  Future<void> pumpBody(
    WidgetTester tester,
    EventLookup? lookup, {
    DateTime? at,
    Overlaps? overlaps,
    List<EventLink> links = const [],
    void Function(String)? onOpenLink,
    void Function(String, String)? onOpenThread,
    void Function(String)? onOpenStoryline,
    VoidCallback? onOpenSettings,
    void Function(String)? onOpenEvent,
    VoidCallback? onRetry,
    Widget? brief,
    Widget? actions,
    CalendarAvailability availability = CalendarAvailability.available,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EventPanelBody(
          lookup: lookup,
          zone: CalendarZone.tryNamed('America/Los_Angeles')!,
          now: at ?? now,
          today: today,
          overlaps: overlaps,
          links: links,
          onOpenLink: onOpenLink ?? (_) {},
          onOpenThread: onOpenThread ?? (_, _) {},
          onOpenStoryline: onOpenStoryline,
          onOpenSettings: onOpenSettings,
          onOpenEvent: onOpenEvent,
          onRetry: onRetry,
          brief: brief,
          actions: actions,
          availability: availability,
        ),
      ),
    ));
    await tester.pump();
  }

  String textOf(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).data!;

  testWidgets('offline, a found event says it is the saved copy',
      (tester) async {
    await pumpBody(tester, EventLookup.found(meeting()),
        availability: CalendarAvailability.unavailable);
    expect(find.text(offlineCaption), findsOneWidget);
    expect(find.byKey(EventPanelBody.whenKey), findsOneWidget);

    await pumpBody(tester, EventLookup.found(meeting()));
    expect(find.text(offlineCaption), findsNothing);
  });

  testWidgets('the when line, standing, tally and the clash list: one row per '
      'overlapping meeting, hard first, tapping one opens it', (tester) async {
    final opened = <String>[];
    await pumpBody(
      tester,
      EventLookup.found(meeting(attendees: const [
        Attendee(name: 'Sam Lee', address: 'sam@contoso.com',
            response: 'accepted'),
        Attendee(name: 'Ana Ruiz', address: 'ana@contoso.com',
            response: 'declined'),
      ])),
      overlaps: Overlaps(hard: [
        CalendarEvent(
          id: 'b',
          subject: 'Budget review',
          startUtc: DateTime.utc(2026, 9, 29, 17),
          endUtc: DateTime.utc(2026, 9, 29, 18),
        ),
      ], soft: [
        CalendarEvent(
          id: 'm',
          subject: 'Fabrikam review',
          startUtc: DateTime.utc(2026, 9, 29, 16, 45),
          endUtc: DateTime.utc(2026, 9, 29, 17, 15),
          responseStatus: 'tentativelyAccepted',
        ),
      ]),
      onOpenEvent: opened.add,
    );

    expect(textOf(tester, EventPanelBody.whenKey),
        'Today · Tuesday, Sep 29 · 10:00–10:30 AM');
    expect(textOf(tester, EventPanelBody.responseKey), 'You accepted');
    // The line wears the standing's colour, as the agenda bar does.
    expect(
        tester.widget<Text>(find.byKey(EventPanelBody.responseKey)).style!.color,
        bondToneColors[toneOfStanding(EventStanding.accepted)]!.foreground);
    // An attendee's copy: definite answers only, no "of N".
    expect(textOf(tester, EventPanelBody.tallyKey), '1 accepted · Ana declined');
    expect(textOf(tester, EventPanelBody.overlapKey), '⚠ overlaps');
    String rowText(int i) => tester
        .widget<Text>(find.descendant(
            of: find.byKey(EventPanelBody.overlapRowKeyFor(i)),
            matching: find.byType(Text)))
        .data!;
    expect(rowText(0), 'Budget review · 10:00–11:00 AM');
    expect(rowText(1), 'Fabrikam review · 9:45–10:15 AM · maybe');
    expect(find.byKey(EventPanelBody.overlapRowKeyFor(2)), findsNothing);
    await tester.tap(find.byKey(EventPanelBody.overlapRowKeyFor(1)));
    await tester.tap(find.byKey(EventPanelBody.overlapRowKeyFor(0)));
    expect(opened, ['m', 'b']);
    expect(find.text('Room 4B'), findsOneWidget);
    expect(find.text('Organised by Dana Ortiz'), findsOneWidget);
  });

  testWidgets("the organiser's copy counts everyone, no-replies included",
      (tester) async {
    await pumpBody(
      tester,
      EventLookup.found(meeting(isOrganizer: true, attendees: const [
        Attendee(name: 'Sam Lee', address: 'sam@contoso.com',
            response: 'accepted'),
        Attendee(name: 'Ana Ruiz', address: 'ana@contoso.com',
            response: 'declined'),
        Attendee(name: 'Bo Kim', address: 'bo@contoso.com', response: 'none'),
      ])),
    );
    expect(textOf(tester, EventPanelBody.tallyKey),
        '1 of 3 accepted · Ana declined · 1 no reply');
    expect(find.text('You organised this'), findsWidgets);
    expect(find.byTooltip('No reply'), findsOneWidget);
    expect(find.byTooltip('Not known'), findsNothing);
  });

  testWidgets("an attendee's copy with nobody answering shows no tally",
      (tester) async {
    await pumpBody(
      tester,
      EventLookup.found(meeting(attendees: const [
        Attendee(name: 'Sam Lee', address: 'sam@contoso.com', response: 'none'),
        Attendee(name: 'Ana Ruiz', address: 'ana@contoso.com', response: 'none'),
      ])),
    );
    expect(find.text('People'), findsOneWidget);
    expect(find.byKey(EventPanelBody.tallyKey), findsNothing);
    // Nor does any row claim nobody answered: the copy cannot know.
    expect(find.byTooltip('No reply'), findsNothing);
    expect(find.byTooltip('Not known'), findsNWidgets(2));
  });

  group('Join', () {
    testWidgets('an upcoming meeting offers it quietly', (tester) async {
      final opened = <String>[];
      await pumpBody(tester, EventLookup.found(meeting()),
          onOpenLink: opened.add);
      expect(find.byKey(EventPanelBody.joinKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(OutlinedButton),
          matching: find.text('Join'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(EventPanelBody.joinKey));
      await tester.pump();
      expect(opened, [join]);
    });

    testWidgets('fifteen minutes out it is the thing to press',
        (tester) async {
      await pumpBody(tester, EventLookup.found(meeting()),
          at: DateTime.utc(2026, 9, 29, 16, 50));
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.text('Join'),
        ),
        findsOneWidget,
      );
      expect(find.text('in 10m'), findsOneWidget);
    });

    testWidgets('no link, past, or cancelled: no Join', (tester) async {
      await pumpBody(tester, EventLookup.found(meeting(joinUrl: '')));
      expect(find.byKey(EventPanelBody.joinKey), findsNothing);

      await pumpBody(tester, EventLookup.found(meeting(
        start: DateTime.utc(2026, 9, 28, 17),
      )));
      expect(find.byKey(EventPanelBody.joinKey), findsNothing);

      await pumpBody(tester, EventLookup.found(meeting(isCancelled: true)));
      expect(find.byKey(EventPanelBody.joinKey), findsNothing);
      expect(find.text('Cancelled'), findsWidgets);
    });
  });

  testWidgets('Open in Outlook only with a web link, and it opens it',
      (tester) async {
    await pumpBody(tester, EventLookup.found(meeting()));
    expect(find.byKey(EventPanelBody.openInOutlookKey), findsNothing);

    final opened = <String>[];
    await pumpBody(tester, EventLookup.found(meeting(webLink: outlook)),
        onOpenLink: opened.add);
    await tester.tap(find.byKey(EventPanelBody.openInOutlookKey));
    await tester.pump();
    expect(opened, [outlook]);
  });

  group('the other answers', () {
    testWidgets('still reading', (tester) async {
      await pumpBody(tester, null);
      expect(find.text(DayPane.readingText), findsOneWidget);
    });

    testWidgets('gone and unreachable', (tester) async {
      await pumpBody(tester, const EventLookup.gone());
      expect(find.text(EventPanelBody.goneText), findsOneWidget);
      await pumpBody(tester, const EventLookup.unreachable());
      expect(find.text(EventPanelBody.unreachableText), findsOneWidget);
      // No retry wired, no button.
      expect(find.byKey(EventPanelBody.retryKey), findsNothing);
    });

    testWidgets('unreachable offers Retry when the host can read again',
        (tester) async {
      var retries = 0;
      await pumpBody(
        tester,
        const EventLookup.unreachable(),
        onRetry: () => retries++,
      );
      expect(find.text(EventPanelBody.unreachableText), findsOneWidget);
      expect(find.byKey(EventPanelBody.retryKey), findsOneWidget);
      await tester.tap(find.byKey(EventPanelBody.retryKey));
      await tester.pump();
      expect(retries, 1);

      // Only the unreachable answer offers it.
      await pumpBody(tester, const EventLookup.gone(), onRetry: () {});
      expect(find.byKey(EventPanelBody.retryKey), findsNothing);
    });

    testWidgets('no scope says where to fix it', (tester) async {
      var settings = 0;
      await pumpBody(
        tester,
        const EventLookup.blocked(CalendarAvailability.scopeMissing),
        onOpenSettings: () => settings++,
      );
      expect(find.text(DayPane.scopeMissingText), findsOneWidget);
      await tester.tap(find.text('Open Settings'));
      await tester.pump();
      expect(settings, 1);
    });

    testWidgets('SDK mode says so', (tester) async {
      await pumpBody(
          tester, const EventLookup.blocked(CalendarAvailability.sdkMode));
      expect(find.text(DayPane.sdkModeText), findsOneWidget);
      expect(find.text('Open Settings'), findsNothing);
    });
  });

  testWidgets('attendee rows, with optional and room marked', (tester) async {
    await pumpBody(
      tester,
      EventLookup.found(meeting(attendees: const [
        Attendee(name: 'Sam Lee', address: 'sam@contoso.com',
            type: 'required', response: 'accepted'),
        Attendee(name: '', address: 'ana@fabrikam.com',
            type: 'optional', response: 'tentativelyAccepted'),
        Attendee(name: 'Room 4B', address: 'room4b@contoso.com',
            type: 'resource', response: 'accepted'),
      ])),
    );
    expect(find.text('People'), findsOneWidget);
    Finder inRow(String address, String text) => find.descendant(
          of: find.byKey(EventPanelBody.attendeeKeyFor(address)),
          matching: find.textContaining(text, findRichText: true),
        );
    expect(inRow('sam@contoso.com', 'Sam Lee'), findsOneWidget);
    expect(inRow('sam@contoso.com', '·'), findsNothing);
    expect(inRow('ana@fabrikam.com', 'ana@fabrikam.com · optional'),
        findsOneWidget);
    expect(inRow('room4b@contoso.com', 'Room 4B · room'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(2));
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
  });

  testWidgets('no attendees, no People section', (tester) async {
    await pumpBody(tester, EventLookup.found(meeting()));
    expect(find.text('People'), findsNothing);
    expect(find.byKey(EventPanelBody.tallyKey), findsNothing);
  });

  testWidgets('conversation rows open their thread and their storyline',
      (tester) async {
    final threads = <String>[];
    final storylines = <String>[];
    await pumpBody(
      tester,
      EventLookup.found(meeting()),
      links: const [
        EventLink(
          source: 'email',
          conversationKey: 'conv-a',
          title: 'Invitation: Design review',
          storylineId: 'sl-1',
          storylineTitle: 'Contoso launch',
        ),
        EventLink(
          source: 'teams',
          conversationKey: '19:meeting_x@thread.v2',
          title: 'Meeting chat',
          isMeetingChat: true,
        ),
      ],
      onOpenThread: (s, k) => threads.add('$s/$k'),
      onOpenStoryline: storylines.add,
    );
    expect(find.text('Conversations'), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(find.byIcon(Icons.mail_outline), findsOneWidget);

    await tester.tap(find.text('Contoso launch'));
    await tester.pump();
    expect(storylines, ['sl-1']);
    expect(threads, isEmpty);

    await tester.tap(
        find.byKey(EventPanelBody.linkKeyFor('teams', '19:meeting_x@thread.v2')));
    await tester.pump();
    await tester.tap(find.text('Invitation: Design review'));
    await tester.pump();
    expect(threads, ['teams/19:meeting_x@thread.v2', 'email/conv-a']);
  });

  /// The spans of the drawn invite body that carry a tap recognizer.
  List<TextSpan> linkedSpansOfBody(WidgetTester tester) {
    final paragraph = tester.widget<RichText>(find
        .descendant(
          of: find.byKey(EventPanelBody.bodyPreviewKey),
          matching: find.byType(RichText),
        )
        .first);
    final linked = <TextSpan>[];
    paragraph.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) linked.add(span);
      return true;
    });
    return linked;
  }

  testWidgets("the invite body's web addresses open through the host",
      (tester) async {
    // A Teams invite's "Join:" line is a bare URL in the body text; it must
    // be a link, and only the host's guarded launcher opens it.
    const url = 'https://teams.example.com/l/meetup-join/fictional';
    const body = 'Join: $url\nMeeting ID: 221 756 307';
    final opened = <String>[];
    await pumpBody(tester, EventLookup.found(meeting(bodyPreview: body)),
        onOpenLink: opened.add);
    expect(find.text('From the invite'), findsOneWidget);

    // The rendered span, not the widget's callback: a Join line drawn with
    // no recognizer would be the dead text this test exists to catch.
    final linked = linkedSpansOfBody(tester);
    expect(linked, hasLength(1));
    (linked.single.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, [url]);
  });

  testWidgets('the invite body never opens a non-web scheme', (tester) async {
    const body = 'Dial msteams://l/meetup-join/fictional or javascript:void(0)';
    final opened = <String>[];
    await pumpBody(tester, EventLookup.found(meeting(bodyPreview: body)),
        onOpenLink: opened.add);
    expect(find.textContaining('msteams://l/meetup-join/fictional',
            findRichText: true),
        findsOneWidget);
    expect(linkedSpansOfBody(tester), isEmpty);
  });

  testWidgets('the brief and actions slots render only when given',
      (tester) async {
    await pumpBody(tester, EventLookup.found(meeting()));
    expect(find.text('Brief'), findsNothing);

    await pumpBody(
      tester,
      EventLookup.found(meeting()),
      brief: const Text('what it is about'),
      actions: const Text('the RSVP row'),
    );
    expect(find.text('Brief'), findsOneWidget);
    expect(find.text('what it is about'), findsOneWidget);
    expect(find.text('the RSVP row'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('the RSVP row')).dy,
      greaterThan(
          tester.getTopLeft(find.byKey(EventPanelBody.responseKey)).dy),
    );
  });

  testWidgets('a series master shows its next occurrence', (tester) async {
    final master = meeting(
      id: 'm',
      eventType: 'seriesMaster',
      start: DateTime.utc(2026, 7, 7, 17),
    );
    await pumpBody(
      tester,
      EventLookup.found(master, occurrences: [
        meeting(
          id: 'o-past',
          eventType: 'occurrence',
          seriesMasterId: 'm',
          start: DateTime.utc(2026, 9, 22, 17),
        ),
        meeting(
          id: 'o-next',
          eventType: 'occurrence',
          seriesMasterId: 'm',
          start: DateTime.utc(2026, 9, 30, 17),
        ),
      ]),
    );
    expect(textOf(tester, EventPanelBody.whenKey),
        'Tomorrow · Wednesday, Sep 30 · 10:00–10:30 AM · series');
  });
}
