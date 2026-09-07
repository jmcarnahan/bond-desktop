import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/widgets/message_row.dart';
import 'package:bond_inbox/widgets/preview/eml_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// A message that came attached to a message, read the way messages are read.
Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(height: 400, child: child)));

AttachmentRef _item() => AttachmentRef(
      source: 'email',
      messageId: 'm1',
      attachmentId: 'a1',
      kind: 'item',
      name: 'Forwarded message',
      itemSubject: 'Re: survey window',
      itemFrom: 'Dana Whitfield',
      itemReceived: '2026-05-04T14:00:00Z',
    );

void main() {
  testWidgets('it reads as a row, under the subject', (tester) async {
    await tester.pumpWidget(_host(EmlPreview(
      attachment: _item(),
      bodyText: 'Tuesday works for the survey.',
    )));

    expect(find.text('Re: survey window'), findsOneWidget);
    expect(find.byKey(EmlPreview.rowKey), findsOneWidget);
    expect(find.text('Dana Whitfield'), findsOneWidget);
    expect(find.text('Tuesday works for the survey.'), findsOneWidget);
  });

  testWidgets('a message with no body cached says so', (tester) async {
    await tester.pumpWidget(_host(EmlPreview(attachment: _item())));

    expect(find.byKey(EmlPreview.noBodyKey), findsOneWidget);
    expect(find.byKey(EmlPreview.rowKey), findsNothing);
  });

  testWidgets('a whitespace body is no body', (tester) async {
    await tester.pumpWidget(_host(EmlPreview(
      attachment: _item(),
      bodyText: '   \n ',
    )));

    expect(find.byKey(EmlPreview.noBodyKey), findsOneWidget);
  });

  testWidgets('nothing inside the nested row takes a tap', (tester) async {
    await tester.pumpWidget(_host(EmlPreview(
      attachment: _item(),
      bodyText: 'Body.',
    )));

    final row = tester.widget<MessageRow>(find.byKey(EmlPreview.rowKey));
    expect(row.onOpenAttachment, isNull);
    expect(row.message.attachments, isEmpty);
  });

  testWidgets('a file with no subject of its own wears its name',
      (tester) async {
    await tester.pumpWidget(_host(EmlPreview(
      attachment: ref(name: 'Thread.eml', kind: 'item'),
      bodyText: 'Body.',
    )));

    expect(find.text('Thread.eml'), findsOneWidget);
  });

  group('messageForItem', () {
    test('the attached message is quiet: read, and never triaged', () {
      final message = messageForItem(_item(), 'Body.');

      expect(message.id, 'att-m1-a1');
      expect(message.outbound, isFalse);
      expect(message.isRead, isTrue);
      expect(message.triageStatus, 'skipped');
      expect(message.fromName, 'Dana Whitfield');
      expect(message.receivedAt, '2026-05-04T14:00:00Z');
      expect(message.subject, 'Re: survey window');
      expect(message.attachments, isEmpty);
    });
  });
}
