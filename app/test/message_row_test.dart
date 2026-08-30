import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/time_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A local, timezone-free ISO string — parsed as local time, so the day-key
/// and day-label assertions below do not move with the runner's TZ.
String _localIso(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}-'
    '${when.month.toString().padLeft(2, '0')}-'
    '${when.day.toString().padLeft(2, '0')}T'
    '${when.hour.toString().padLeft(2, '0')}:'
    '${when.minute.toString().padLeft(2, '0')}:00';

Message _msg({
  String id = 'm1',
  bool outbound = false,
  String? fromName = 'Eric Nolan',
  String? fromAddress = 'eric@example.com',
  String? receivedAt = '2026-08-25T09:00:00',
  String? bodyText = 'Hello there.',
  String? bodyPreview,
  String? summary,
  String triageStatus = 'done',
  bool pendingSend = false,
}) {
  return Message(
    id: id,
    outbound: outbound,
    fromName: fromName,
    fromAddress: fromAddress,
    receivedAt: receivedAt,
    bodyText: bodyText,
    bodyPreview: bodyPreview,
    summary: summary,
    triageStatus: triageStatus,
    pendingSend: pendingSend,
  );
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );

void main() {
  group('initialsFor', () {
    test('takes first and last initial of a display name', () {
      expect(initialsFor('Eric Nolan', 'eric@example.com'), 'EN');
      expect(initialsFor('  ana   maria  reyes ', null), 'AR');
    });

    test('single-word names give one letter', () {
      expect(initialsFor('Cher', null), 'C');
    });

    test('falls back to the address when there is no name', () {
      expect(initialsFor(null, 'bob@example.com'), 'B');
      expect(initialsFor('', 'bob@example.com'), 'B');
    });

    test('is a question mark when there is nothing at all', () {
      expect(initialsFor(null, null), '?');
      expect(initialsFor('', ''), '?');
      expect(initialsFor('   ', '  '), '?');
    });
  });

  group('avatarColorFor', () {
    test('outbound is always the product primary', () {
      final a = avatarColorFor('a@example.com', outbound: true);
      final b = avatarColorFor('b@example.com', outbound: true);
      expect(a, b);
    });

    test('inbound is stable per address and case-insensitive', () {
      expect(
        avatarColorFor('Eric@Example.com', outbound: false),
        avatarColorFor('eric@example.com', outbound: false),
      );
    });

    test('a null address still resolves to a color', () {
      expect(avatarColorFor(null, outbound: false), isA<Color>());
    });
  });

  group('sameRun', () {
    final base = _msg(receivedAt: '2026-08-25T09:00:00');

    test('same sender within five minutes collapses', () {
      final next = _msg(id: 'm2', receivedAt: '2026-08-25T09:04:00');
      expect(sameRun(base, next), isTrue);
    });

    test('more than five minutes apart does not', () {
      final next = _msg(id: 'm2', receivedAt: '2026-08-25T09:06:00');
      expect(sameRun(base, next), isFalse);
    });

    test('a different sender does not', () {
      final next = _msg(
        id: 'm2',
        fromAddress: 'other@example.com',
        receivedAt: '2026-08-25T09:01:00',
      );
      expect(sameRun(base, next), isFalse);
    });

    test('a different direction does not', () {
      final next = _msg(
        id: 'm2',
        outbound: true,
        receivedAt: '2026-08-25T09:01:00',
      );
      expect(sameRun(base, next), isFalse);
    });

    test('an unparseable timestamp breaks the run', () {
      final next = _msg(id: 'm2', receivedAt: 'not a date');
      expect(sameRun(base, next), isFalse);
    });
  });

  group('dayKeyOf', () {
    test('is the local calendar day', () {
      expect(dayKeyOf(_msg(receivedAt: '2026-08-25T09:00:00')), '2026-08-25');
      expect(dayKeyOf(_msg(receivedAt: '2026-01-05T23:30:00')), '2026-01-05');
    });

    test('is null when the timestamp does not parse', () {
      expect(dayKeyOf(_msg(receivedAt: 'garbage')), isNull);
      expect(dayKeyOf(_msg(receivedAt: null)), isNull);
    });
  });

  group('formatDayLabel', () {
    test('names today and yesterday', () {
      final now = DateTime.now();
      final noonToday = DateTime(now.year, now.month, now.day, 12);
      expect(formatDayLabel(_localIso(noonToday)), 'Today');
      expect(
        formatDayLabel(_localIso(noonToday.subtract(const Duration(days: 1)))),
        'Yesterday',
      );
    });

    test('older days get a weekday-qualified date', () {
      final now = DateTime.now();
      final noonToday = DateTime(now.year, now.month, now.day, 12);
      final label =
          formatDayLabel(_localIso(noonToday.subtract(const Duration(days: 9))));
      expect(label, isNotNull);
      expect(label, isNot('Today'));
      expect(label, isNot('Yesterday'));
      expect(label, contains(','));
    });

    test('is null for junk', () {
      expect(formatDayLabel('nope'), isNull);
      expect(formatDayLabel(null), isNull);
      expect(formatDayLabel(''), isNull);
    });
  });

  group('MessageRow', () {
    testWidgets('a header row shows the sender and the time', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(message: _msg())));

      expect(find.text('Eric Nolan'), findsOneWidget);
      expect(find.text(formatTimestamp('2026-08-25T09:00:00')!), findsOneWidget);
      expect(find.text('EN'), findsOneWidget);
    });

    testWidgets('a continuation row drops the avatar and the name',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(MessageRow(message: _msg(), showHeader: false)),
      );

      expect(find.text('Eric Nolan'), findsNothing);
      expect(find.text('EN'), findsNothing);
      expect(find.text(formatTimestamp('2026-08-25T09:00:00')!), findsNothing);
    });

    testWidgets('a long body collapses behind Show more', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final long = List.filled(40, 'line').join('\n');
      await tester.pumpWidget(_host(MessageRow(message: _msg(bodyText: long))));

      expect(find.text('Show more'), findsOneWidget);
      await tester.tap(find.text('Show more'));
      await tester.pump();
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('an optimistic outbound row says it is still sending',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(MessageRow(
          message: _msg(outbound: true, fromName: null, pendingSend: true),
        )),
      );

      expect(find.text('Sending…'), findsOneWidget);
    });

    testWidgets('a triaging inbound row marks its timestamp', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(MessageRow(message: _msg(triageStatus: 'pending'))),
      );

      final when = formatTimestamp('2026-08-25T09:00:00')!;
      expect(find.text('$when · triaging'), findsOneWidget);
    });

    testWidgets('a summary renders as the model speaking', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(MessageRow(message: _msg(summary: 'Wants the rate sheet.'))),
      );

      expect(find.text('AI: Wants the rate sheet.'), findsOneWidget);
    });

    testWidgets('outbound stays left-aligned — no bubbles, no right column',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _host(MessageRow(message: _msg(outbound: true))),
      );

      final rows = tester.widgetList<Row>(
        find.descendant(
          of: find.byType(MessageRow),
          matching: find.byType(Row),
        ),
      );
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row.mainAxisAlignment, isNot(MainAxisAlignment.end));
      }

      // The avatar leads the row; the body follows it.
      final avatar = tester.getTopLeft(find.text('EN'));
      final body = tester.getTopLeft(find.text('Hello there.'));
      expect(avatar.dx, lessThan(body.dx));
    });
  });

  group('DayDivider', () {
    testWidgets('renders its label between two rules', (tester) async {
      await tester.pumpWidget(_host(const DayDivider(label: 'Yesterday')));

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.byType(Divider), findsNWidgets(2));
    });
  });
}
