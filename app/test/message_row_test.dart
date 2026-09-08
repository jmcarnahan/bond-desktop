import 'dart:typed_data';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/attachment_chip.dart';
import 'package:bond_inbox/widgets/attachment_chip_row.dart';
import 'package:bond_inbox/widgets/attachment_format.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/inline_image_thumb.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/time_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

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
  bool? needsAction,
  List<String> actionItems = const [],
  String? deadline,
  List<AttachmentRef> attachments = const [],
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
    needsAction: needsAction,
    actionItems: actionItems,
    deadline: deadline,
    attachments: attachments,
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

    testWidgets('an open ask renders its action item and deadline',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(
          needsAction: true,
          actionItems: const ['Send the deck'],
          deadline: 'Friday',
        ),
        openAsk: true,
      )));

      expect(find.text('Send the deck'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BondChip),
          matching: find.text('Friday'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an open ask with no action item still says one is owed',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(needsAction: true),
        openAsk: true,
      )));

      expect(find.text('Reply expected'), findsOneWidget);
    });

    testWidgets('the row does not work the rule out for itself', (tester) async {
      // needsAction on the message is not enough — only the host, which can
      // see the whole thread, knows whether a reply already answered it.
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(
          needsAction: true,
          actionItems: const ['Send the deck'],
          deadline: 'Friday',
        ),
      )));

      expect(find.text('Send the deck'), findsNothing);
      expect(find.text('Reply expected'), findsNothing);
      expect(find.text('Friday'), findsNothing);
    });

    testWidgets('an open ask without a deadline renders no chip',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(needsAction: true, actionItems: const ['Send the deck']),
        openAsk: true,
      )));

      expect(find.text('Send the deck'), findsOneWidget);
      expect(find.byType(BondChip), findsNothing);
    });

    testWidgets('an open ask is the way into the reply', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var taps = 0;
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(needsAction: true, actionItems: const ['Send the deck']),
        openAsk: true,
        onAskTap: () => taps++,
      )));

      await tester.tap(find.text('Send the deck'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('and stays a statement where the host offers nowhere to go',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(needsAction: true, actionItems: const ['Send the deck']),
        openAsk: true,
      )));

      expect(
        find.ancestor(
          of: find.text('Send the deck'),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
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

  group('layOutBody', () {
    test('the documents worth a picture are a subset of the chips', () {
      final layout = layOutBody('', [
        ref(attachmentId: 'a1', name: 'Terms.pdf'),
        ref(attachmentId: 'a2', name: 'Letter.docx', contentType: null),
        ref(attachmentId: 'a3', name: 'Quote.xlsx', contentType: null),
        ref(attachmentId: 'a4', kind: 'reference', name: 'Budget.xlsx'),
      ]);

      expect(
        layout.chips.map((a) => a.attachmentId),
        ['a1', 'a2', 'a3', 'a4'],
      );
      expect(layout.thumbnailable.map((a) => a.attachmentId), ['a1', 'a2']);
      // Four files, counted four times — never five.
      expect(displayableCountOf(layout), 4);
    });

    test('an inline document is never a candidate', () {
      final layout = layOutBody('', [
        ref(attachmentId: 'a1', name: 'Terms.pdf', isInline: true),
      ]);

      expect(layout.thumbnailable, isEmpty);
      expect(layout.chips, hasLength(1));
    });

    test('a picture is a picture, not a document with a picture', () {
      final layout = layOutBody('', [imageRef(isInline: false)]);

      expect(layout.thumbnailable, isEmpty);
      expect(layout.trailingImages, hasLength(1));
    });

    test('a marker puts the file where the sender put it', () {
      final file = ref(attachmentId: 'a1', name: 'Terms.pdf');
      final layout = layOutBody('Here it is [[att:a1]] have a look', [file]);

      expect(layout.segments.length, 3);
      expect((layout.segments[0] as BodyTextSegment).text, 'Here it is');
      final placed = layout.segments[1] as BodyAttachmentSegment;
      expect(placed.attachment.attachmentId, 'a1');
      expect(placed.asImage, isFalse);
      expect((layout.segments[2] as BodyTextSegment).text, 'have a look');
      expect(layout.chips, isEmpty);
      expect(layout.plainText, 'Here it is have a look');
    });

    test('a link marker places the chip in the sentence', () {
      // A file attached as a link has no connector id to key on — the sync
      // mints `link-<hash>` and writes the marker where the link sat, so the
      // chip lands mid-sentence exactly the way a chat's file does.
      final linked = ref(
        attachmentId: 'link-abc',
        kind: 'reference',
        name: 'HARBORLIGHT TALENT AGREEMENT.pdf',
        contentType: null,
        size: 0,
        sourceUrl: 'https://southbayequity2-my.sharepoint.com/:b:/g/personal/'
            'jane_southbayequity2_onmicrosoft_com/EaBcDeFgHiJkLmNoPqRsTuVwXyZ',
      );
      final layout = layOutBody('Please review [[att:link-abc]] today.', [
        linked,
      ]);

      expect(layout.segments.length, 3);
      expect((layout.segments[0] as BodyTextSegment).text, 'Please review');
      final placed = layout.segments[1] as BodyAttachmentSegment;
      expect(placed.attachment.attachmentId, 'link-abc');
      expect(placed.attachment.name, 'HARBORLIGHT TALENT AGREEMENT.pdf');
      expect(placed.asImage, isFalse);
      expect((layout.segments[2] as BodyTextSegment).text, 'today.');
      expect(layout.chips, isEmpty);
      expect(layout.plainText, 'Please review today.');
    });

    test('a marker naming nothing leaves nothing behind', () {
      final layout = layOutBody('Sent it over [[att:gone]]', const []);

      expect(layout.plainText, 'Sent it over');
      expect(layout.segments.single, isA<BodyTextSegment>());
    });

    test('a marker-only chat message is the file and no words', () {
      final file = ref(source: 'teams', attachmentId: 'a1');
      final layout = layOutBody('[[att:a1]]', [file]);

      expect(layout.plainText, '');
      expect(layout.segments.single, isA<BodyAttachmentSegment>());
    });

    test('a pasted picture is drawn in place', () {
      final shot = imageRef(
        attachmentId: 'i1',
        contentId: 'shot@example',
        size: 90 * 1024,
      );
      final layout = layOutBody('Look at this [cid:shot@example] — see?', [shot]);

      final placed =
          layout.segments.whereType<BodyAttachmentSegment>().single;
      expect(placed.attachment.attachmentId, 'i1');
      expect(placed.asImage, isTrue);
      expect(layout.plainText, 'Look at this — see?');
      expect(layout.trailingImages, isEmpty);
    });

    test('a signature logo is stripped and is not a file anybody sent', () {
      final logo = imageRef(
        attachmentId: 'i1',
        name: 'logo.png',
        contentId: 'logo@example',
        size: 4 * 1024,
      );
      final layout = layOutBody('Thanks,\nDana [cid:logo@example]', [logo]);

      expect(layout.plainText, 'Thanks,\nDana');
      expect(layout.segments.whereType<BodyAttachmentSegment>(), isEmpty);
      expect(layout.chips, isEmpty);
      expect(layout.trailingImages, isEmpty);
    });

    test('what the body never mentioned falls to the bottom, in order', () {
      final files = [
        imageRef(attachmentId: 'i1', ordinal: 2, isInline: false),
        ref(attachmentId: 'a1', ordinal: 1, name: 'Second.pdf'),
        ref(attachmentId: 'a0', ordinal: 0, name: 'First.pdf'),
      ];
      final layout = layOutBody('See attached.', files);

      expect(layout.chips.map((a) => a.name), ['First.pdf', 'Second.pdf']);
      expect(layout.trailingImages.map((a) => a.attachmentId), ['i1']);
    });

    test('plain text is what the clamp measures, pictures and all', () {
      final shot = imageRef(
        attachmentId: 'i1',
        contentId: 'shot@example',
        size: 90 * 1024,
      );
      final long = List.filled(40, 'line').join('\n');
      final layout = layOutBody('$long\n[cid:shot@example]', [shot]);

      expect(layout.plainText.split('\n').length, 40);
    });

    test('a body with no tokens is returned exactly as it was', () {
      const body = 'Two  spaces and\n\n\n\nfour newlines.  ';
      final layout = layOutBody(body, const []);

      expect(layout.plainText, body);
    });

    test('the same file named twice is drawn once', () {
      final file = ref(attachmentId: 'a1');
      final layout = layOutBody('[[att:a1]] and again [[att:a1]]', [file]);

      expect(layout.segments.whereType<BodyAttachmentSegment>().length, 1);
      expect(layout.chips, isEmpty);
      expect(layout.plainText, 'and again');
    });
  });

  group('displayableAttachmentCount', () {
    test('counts what a reader would call a file', () {
      final message = _msg(
        bodyText: 'Thanks, Dana [cid:logo@example]',
        attachments: [
          ref(attachmentId: 'a1'),
          imageRef(
            attachmentId: 'i1',
            contentId: 'logo@example',
            size: 4 * 1024,
          ),
        ],
      );

      expect(displayableAttachmentCount(message), 1);
    });

    test('a message with nothing on it counts nothing', () {
      expect(displayableAttachmentCount(_msg()), 0);
    });

    test('an inline logo nothing pointed at is furniture too', () {
      final message = _msg(attachments: [
        imageRef(attachmentId: 'i1', name: 'logo.png', size: 3 * 1024),
      ]);

      expect(displayableAttachmentCount(message), 0);
    });

    test('an image whose size nobody stated is a picture, not furniture', () {
      final message = _msg(attachments: [
        imageRef(attachmentId: 'i1', size: 0, isInline: true),
      ]);

      expect(displayableAttachmentCount(message), 1);
    });
  });

  group('MessageRow attachments', () {
    testWidgets('the files a message carried are named under it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [
          ref(attachmentId: 'a1', name: 'Terms.pdf'),
          ref(attachmentId: 'a2', name: 'Schedule.xlsx', size: 12 * 1024),
        ]),
      )));

      expect(find.byKey(AttachmentChipRow.rowKey), findsOneWidget);
      expect(find.byType(AttachmentChip), findsNWidgets(2));
      expect(find.text('Terms.pdf'), findsOneWidget);
      expect(find.text('Schedule.xlsx'), findsOneWidget);
    });

    testWidgets('a marker draws the file inside the sentence, not below it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(
          bodyText: 'Signed copy [[att:a1]] let me know',
          attachments: [ref(attachmentId: 'a1', name: 'Terms.pdf')],
        ),
      )));

      expect(find.byKey(AttachmentChipRow.rowKey), findsNothing);
      expect(find.byType(AttachmentChip), findsOneWidget);
      expect(find.text('Signed copy'), findsOneWidget);
      expect(find.text('let me know'), findsOneWidget);
      expect(find.textContaining('[[att:'), findsNothing);
    });

    testWidgets('a clamped body draws no pictures in it but still names them',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final long = List.filled(40, 'line').join('\n');
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(
          bodyText: '$long\n[[att:a1]]',
          attachments: [ref(attachmentId: 'a1', name: 'Terms.pdf')],
        ),
      )));

      expect(find.text('Show more'), findsOneWidget);
      expect(find.byType(AttachmentChip), findsNothing);

      await tester.tap(find.text('Show more'));
      await tester.pump();
      expect(find.byType(AttachmentChip), findsOneWidget);
    });

    testWidgets('a picture is drawn with whatever the host could give it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final shot = imageRef(attachmentId: 'i1', name: 'Board.png');
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [shot]),
      )));

      expect(find.byKey(InlineImageThumb.keyFor(shot)), findsOneWidget);
      // No bytes yet, so the frame stands in — and it is not a chip.
      expect(
        find.byKey(InlineImageThumb.placeholderKeyFor(shot)),
        findsOneWidget,
      );
      expect(find.byType(AttachmentChip), findsNothing);
    });

    testWidgets('a folded row keeps the paperclip and nothing else',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [
          ref(attachmentId: 'a1', name: 'Terms.pdf'),
          ref(attachmentId: 'a2', name: 'Schedule.xlsx'),
        ]),
        collapsible: true,
        initiallyCollapsed: true,
      )));

      expect(find.byKey(MessageRow.collapsedAttachmentHintKey), findsOneWidget);
      expect(find.text('📎 2 files'), findsOneWidget);
      expect(find.byType(AttachmentChip), findsNothing);

      await tester.tap(find.text('Eric Nolan'));
      await tester.pump();
      expect(find.byKey(MessageRow.collapsedAttachmentHintKey), findsNothing);
      expect(find.byType(AttachmentChip), findsNWidgets(2));
    });

    testWidgets('one file says one file', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [ref(attachmentId: 'a1')]),
        collapsible: true,
        initiallyCollapsed: true,
      )));

      expect(find.text('📎 1 file'), findsOneWidget);
    });

    testWidgets('a row with nowhere to open a file offers no tap',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [ref(attachmentId: 'a1')]),
      )));

      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('and one that does hands the host the file it was asked for',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      AttachmentRef? opened;
      final file = ref(attachmentId: 'a1', name: 'Terms.pdf');
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [file]),
        onOpenAttachment: (attachment) => opened = attachment,
        selectedAttachment: file,
      )));

      expect(
        tester.widget<AttachmentChip>(find.byType(AttachmentChip)).selected,
        isTrue,
      );
      await tester.tap(find.text('Terms.pdf'));
      expect(opened?.attachmentId, 'a1');
    });
  });

  group('what the model made of a file', () {
    AttachmentDigest digest(String summary) =>
        AttachmentDigest(kind: 'quote', summary: summary);

    testWidgets('a digested file says what the model read in it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final file = ref(
        attachmentId: 'a1',
        name: 'Terms.pdf',
        digest: digest('Fixed 4.25% for sixty months.'),
      );
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [file]),
      )));

      expect(
        find.text('AI: Terms.pdf: Fixed 4.25% for sixty months.'),
        findsOneWidget,
      );
      expect(find.byKey(attachmentKey('digest', file)), findsOneWidget);
    });

    testWidgets('a file still being read says nothing extra', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final file = ref(
        attachmentId: 'a1',
        name: 'Terms.pdf',
        digestStatus: 'pending',
      );
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [file]),
      )));

      // The chip's own hint is the whole signal while the digest is pending.
      expect(find.byKey(attachmentKey('digest', file)), findsNothing);
      expect(find.textContaining('AI:'), findsNothing);
      expect(find.text('reading…'), findsOneWidget);
    });

    testWidgets('a digest with nothing in it is not a line', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final file = ref(
        attachmentId: 'a1',
        name: 'Terms.pdf',
        digest: digest(''),
      );
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [file]),
      )));

      expect(find.byKey(attachmentKey('digest', file)), findsNothing);
    });

    testWidgets('one line per digested file, and only for those',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [
          ref(
            attachmentId: 'a1',
            name: 'Terms.pdf',
            digest: digest('The renewal terms.'),
          ),
          ref(
            attachmentId: 'a2',
            name: 'Schedule.xlsx',
            digestStatus: 'skipped',
          ),
        ]),
      )));

      expect(find.textContaining('AI: '), findsOneWidget);
      expect(find.text('AI: Terms.pdf: The renewal terms.'), findsOneWidget);
    });

    testWidgets('a long digest never outgrows two lines', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final file = ref(
        attachmentId: 'a1',
        name: 'Terms.pdf',
        digest: digest(List.filled(120, 'renewal').join(' ')),
      );
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [file]),
      )));

      final line = tester.widget<Text>(
        find.byKey(attachmentKey('digest', file)),
      );
      expect(line.maxLines, 2);
      expect(line.overflow, TextOverflow.ellipsis);
    });

    testWidgets("a folded row keeps its files' digests folded too",
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final file = ref(
        attachmentId: 'a1',
        name: 'Terms.pdf',
        digest: digest('The renewal terms.'),
      );
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(attachments: [file]),
        collapsible: true,
        initiallyCollapsed: true,
      )));

      expect(find.byKey(attachmentKey('digest', file)), findsNothing);
      expect(
        find.byKey(MessageRow.collapsedAttachmentHintKey),
        findsOneWidget,
      );
    });
  });

  group('a document with a picture', () {
    testWidgets('a document with a picture shows it above its chip',
        (tester) async {
      final document = ref(name: 'Terms.pdf');
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(bodyText: 'The terms.', attachments: [document]),
        thumbnailFor: (a) => MemoryImage(Uint8List.fromList(onePixelPng)),
        onOpenAttachment: (_) {},
      )));

      expect(find.byKey(InlineImageThumb.keyFor(document)), findsOneWidget);
      // The chip is still what names it: the picture carries no size and no
      // file name.
      expect(find.byType(AttachmentChip), findsOneWidget);
      expect(find.text('Terms.pdf'), findsOneWidget);
    });

    testWidgets('a document with no picture is just its chip', (tester) async {
      final document = ref(name: 'Terms.pdf');
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(bodyText: 'The terms.', attachments: [document]),
        thumbnailFor: (a) => null,
      )));

      // No frame, no dashed placeholder — the chip below IS the file.
      expect(find.byType(InlineImageThumb), findsNothing);
      expect(find.byType(AttachmentChip), findsOneWidget);
    });

    testWidgets('a link never asks for a picture', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(
          bodyText: 'The budget.',
          attachments: [
            ref(kind: 'reference', name: 'Budget.xlsx', sourceUrl: 'https://x'),
          ],
        ),
        thumbnailFor: (a) {
          asked.add(a.attachmentId);
          return null;
        },
      )));

      expect(asked, isEmpty);
      expect(find.byType(AttachmentChip), findsOneWidget);
    });

    testWidgets('a spreadsheet is a chip and nothing more', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(
          bodyText: 'The quote.',
          attachments: [ref(name: 'Quote.xlsx', contentType: null)],
        ),
        thumbnailFor: (a) {
          asked.add(a.attachmentId);
          return MemoryImage(Uint8List.fromList(onePixelPng));
        },
      )));

      expect(asked, isEmpty);
      expect(find.byType(InlineImageThumb), findsNothing);
    });

    testWidgets('a folded row still counts it once', (tester) async {
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(
          bodyText: 'The terms.',
          attachments: [ref(name: 'Terms.pdf')],
        ),
        collapsible: true,
        initiallyCollapsed: true,
        thumbnailFor: (a) => MemoryImage(Uint8List.fromList(onePixelPng)),
      )));

      expect(find.text('📎 1 file'), findsOneWidget);
    });
  });

  group('what happened', () {
    testWidgets('the link rides on the header and never folds the row',
        (tester) async {
      var asked = 0;
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(),
        collapsible: true,
        onWhatHappened: () => asked++,
      )));

      expect(find.text('What happened'), findsOneWidget);
      expect(find.text('Hello there.'), findsOneWidget);

      await tester.tap(find.byKey(MessageRow.whatHappenedKey));
      await tester.pump();

      expect(asked, 1);
      expect(
        find.text('Hello there.'),
        findsOneWidget,
        reason: 'asking why must not collapse the message being asked about',
      );
    });

    testWidgets('no link without a handler', (tester) async {
      await tester.pumpWidget(_host(MessageRow(message: _msg())));

      expect(find.text('What happened'), findsNothing);
    });

    testWidgets('a continuation row carries no link of its own',
        (tester) async {
      // The run's header already has one, and the message it names is the
      // same message.
      await tester.pumpWidget(_host(MessageRow(
        message: _msg(),
        showHeader: false,
        onWhatHappened: () {},
      )));

      expect(find.text('What happened'), findsNothing);
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
