import 'dart:async';

import 'dart:typed_data';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_bytes.dart';
import 'package:bond_inbox/services/attachments/xlsx_reader.dart';
import 'package:bond_inbox/services/backend/attachment_backend.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/inline_alert.dart';
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart';
import 'package:bond_inbox/widgets/preview/eml_preview.dart';
import 'package:bond_inbox/widgets/preview/image_preview.dart';
import 'package:bond_inbox/widgets/preview/pdf_preview.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:bond_inbox/widgets/preview/sheet_preview.dart';
import 'package:bond_inbox/widgets/preview/text_preview.dart';
import 'package:bond_inbox/widgets/preview/unsupported_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';
import 'fixtures/fake_attachment_bytes.dart';
import 'fixtures/fake_pdf_renderer.dart';

/// The ladder of refusals that comes before any preview, and the three
/// segments that always render whatever is behind them.
///
/// Nothing here reaches pdfium, a socket or a disk: the panel takes an
/// [AttachmentBytes] and a [PreviewEngines], and both are fakes.

const _quote = WorkbookTables([
  SheetTable(
    name: 'Quote',
    header: ['Item', 'Amount'],
    rows: [
      ['Survey', '1,200'],
    ],
    totalRows: 1,
  ),
]);

/// A workbook decoder that answers without a zip. [failing] is how a corrupt
/// file is scripted.
WorkbookDecoder _decoder({bool failing = false}) => (bytes) async {
      if (failing) throw const FormatException('not a workbook');
      return _quote;
    };

void main() {
  late FakeAttachmentBytes bytes;
  late FakePdfRenderer pdf;

  setUp(() {
    bytes = FakeAttachmentBytes();
    pdf = FakePdfRenderer();
  });

  Future<void> pump(
    WidgetTester tester,
    AttachmentRef attachment, {
    bool showHeader = true,
    VoidCallback? onExpand,
    VoidCallback? onOpen,
    VoidCallback? onSave,
    VoidCallback? onUseInReply,
    VoidCallback? onPinToStoryline,
    bool pinned = false,
    void Function(String url)? onOpenLink,
    VoidCallback? onClose,
    bool failingWorkbook = false,
    int pumps = 3,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 700,
          child: AttachmentPreviewPanel(
            attachment: attachment,
            bytes: bytes,
            engines: PreviewEngines(
              pdf: pdf,
              workbook: _decoder(failing: failingWorkbook),
            ),
            showHeader: showHeader,
            onExpand: onExpand,
            onClose: onClose ?? () {},
            onOpen: onOpen,
            onSave: onSave,
            onUseInReply: onUseInReply,
            onPinToStoryline: onPinToStoryline,
            pinned: pinned,
            onOpenLink: onOpenLink,
          ),
        ),
      ),
    ));
    for (var i = 0; i < pumps; i++) {
      await tester.pump();
    }
  }

  Future<void> tapSegment(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(BondFilterPill, label));
    await tester.pump();
    await tester.pump();
  }

  group('the frame', () {
    testWidgets('the header names the file, its size and the way out',
        (tester) async {
      await pump(
        tester,
        ref(name: 'Terms.pdf', size: 240 * 1024),
        onExpand: () {},
      );

      expect(find.text('Terms.pdf'), findsOneWidget);
      expect(find.text('240 KB'), findsOneWidget);
      expect(find.byKey(AttachmentPreviewPanel.expandKey), findsOneWidget);
      expect(find.byKey(AttachmentPreviewPanel.closeKey), findsOneWidget);
    });

    testWidgets('a file nobody named still has a header', (tester) async {
      await pump(tester, ref(name: null, contentType: 'application/pdf'));

      expect(find.text('(unnamed attachment)'), findsOneWidget);
    });

    testWidgets('all three segments always render', (tester) async {
      await pump(tester, ref(kind: 'reference', sourceUrl: 'https://x/y'));

      expect(find.byKey(AttachmentPreviewPanel.segmentsKey), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Text'), findsOneWidget);
      expect(find.text('AI'), findsOneWidget);
    });

    testWidgets('Expand is absent where there is nowhere to expand',
        (tester) async {
      await pump(tester, ref());

      expect(find.byKey(AttachmentPreviewPanel.expandKey), findsNothing);
    });

    testWidgets('without a header there is no close control', (tester) async {
      await pump(tester, ref(), showHeader: false);

      expect(find.byKey(AttachmentPreviewPanel.closeKey), findsNothing);
      expect(find.text('Terms.pdf'), findsNothing);
    });

    testWidgets('closing says so once', (tester) async {
      var closed = 0;
      await pump(tester, ref(), onClose: () => closed++);
      await tester.tap(find.byKey(AttachmentPreviewPanel.closeKey));

      expect(closed, 1);
    });
  });

  group('the fetch', () {
    testWidgets('a spinner while the bytes are coming', (tester) async {
      final never = Completer<Uint8List>();
      addTearDown(() => never.complete(Uint8List(0)));
      bytes = _SlowBytes(never.future);
      await pump(tester, ref(), pumps: 1);

      expect(find.byKey(AttachmentPreviewPanel.loadingKey), findsOneWidget);
    });

    testWidgets('a failure says so, and Try again asks again', (tester) async {
      bytes.throwOnBytes = const AttachmentUnavailable('gone');
      await pump(tester, ref(name: 'Terms.pdf'));

      expect(find.byKey(AttachmentPreviewPanel.errorKey), findsOneWidget);
      expect(find.text('Could not load Terms.pdf.'), findsOneWidget);
      expect(bytes.bytesCalls, 1);

      await tester.tap(find.byKey(AttachmentPreviewPanel.retryKey));
      await tester.pump();
      await tester.pump();

      expect(bytes.bytesCalls, 2);
    });

    testWidgets('Try again that works shows the file', (tester) async {
      final attachment = ref(name: 'Page.png', contentType: 'image/png');
      bytes.throwOnBytes = const AttachmentUnavailable('gone');
      await pump(tester, attachment);

      bytes.throwOnBytes = null;
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList(onePixelPng);
      await tester.tap(find.byKey(AttachmentPreviewPanel.retryKey));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(AttachmentPreviewPanel.errorKey), findsNothing);
      expect(find.byKey(ImagePreview.imageKey), findsOneWidget);
    });
  });

  group('what is never fetched', () {
    testWidgets('a file over the connector cap is never asked for',
        (tester) async {
      await pump(
        tester,
        ref(name: 'Scan.pdf', size: 12 * 1024 * 1024, sourceUrl: 'https://o/1'),
        onOpen: () {},
        onSave: () {},
        onOpenLink: (_) {},
      );

      expect(bytes.bytesCalls, 0);
      expect(find.byKey(AttachmentPreviewPanel.tooLargeKey), findsOneWidget);
      expect(
        find.text('This file is 12 MB — too large to preview here.'),
        findsOneWidget,
      );
      expect(find.text('Open in Outlook'), findsOneWidget);
      // Nothing this app can fetch means nothing it can hand over.
      expect(find.byKey(AttachmentPreviewPanel.openKey), findsNothing);
      expect(find.byKey(AttachmentPreviewPanel.saveKey), findsNothing);
    });

    testWidgets('the Text segment still reads a file too large to fetch',
        (tester) async {
      final attachment = ref(
        name: 'Scan.pdf',
        size: 12 * 1024 * 1024,
        sourceUrl: 'https://o/1',
      );
      // The server read this one already, so its words cost no download —
      // which is exactly why the cap must not stand in front of them.
      bytes.textByKey[FakeAttachmentBytes.keyOf(attachment)] =
          'Survey booked for the fourteenth.';
      await pump(tester, attachment, onOpenLink: (_) {});

      await tapSegment(tester, 'Text');

      expect(find.text('Survey booked for the fourteenth.'), findsOneWidget);
      expect(bytes.bytesCalls, 0);
    });

    testWidgets('a mail file over the cap says where to get it',
        (tester) async {
      // Graph gives a mail attachment no sharing url, so without this sentence
      // the panel is a card and a dead end.
      await pump(
        tester,
        ref(name: 'Scan.pdf', size: 12 * 1024 * 1024),
        onOpenLink: (_) {},
      );

      expect(find.byKey(AttachmentPreviewPanel.sourceLinkKey), findsNothing);
      expect(
        find.textContaining('over what this connection can hand over'),
        findsOneWidget,
      );
      expect(find.textContaining('Open the message in your mail app'),
          findsOneWidget);
      expect(find.textContaining('is under Text'), findsOneWidget);
    });

    testWidgets('the same file under a wider cap is fetched', (tester) async {
      final attachment = ref(name: 'Scan.pdf', size: 12 * 1024 * 1024);
      bytes.maxPreviewBytes = 25 * 1024 * 1024;
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1, 2, 3]);
      await pump(tester, attachment, onOpen: () {}, onSave: () {});

      expect(bytes.bytesCalls, 1);
      expect(find.byKey(AttachmentPreviewPanel.tooLargeKey), findsNothing);
      expect(find.byKey(AttachmentPreviewPanel.openKey), findsOneWidget);
    });

    testWidgets('a chat file over the cap points at Teams', (tester) async {
      await pump(
        tester,
        ref(
          source: 'teams',
          name: 'Deck.pptx',
          size: 40 * 1024 * 1024,
          sourceUrl: 'https://teams/1',
        ),
        onOpenLink: (_) {},
      );

      expect(find.text('Open in Teams'), findsOneWidget);
      expect(bytes.bytesCalls, 0);
    });

    testWidgets('a reference opens its link and asks for no bytes',
        (tester) async {
      var opened = '';
      await pump(
        tester,
        ref(
          kind: 'reference',
          name: 'Budget.xlsx',
          sourceUrl: 'https://drive/budget',
        ),
        onOpen: () {},
        onSave: () {},
        onOpenLink: (url) => opened = url,
      );

      expect(bytes.bytesCalls, 0);
      expect(find.text('This is a link, not a file.'), findsOneWidget);
      expect(find.byKey(AttachmentPreviewPanel.openKey), findsNothing);
      expect(find.byKey(AttachmentPreviewPanel.saveKey), findsNothing);

      await tester.tap(find.byKey(AttachmentPreviewPanel.sourceLinkKey));
      expect(opened, 'https://drive/budget');
    });

    testWidgets('a link that is not a web address gets no button',
        (tester) async {
      var opened = 0;
      await pump(
        tester,
        ref(
          kind: 'reference',
          name: 'Budget.xlsx',
          // The connector stores the sender's string verbatim; this one would
          // launch a local application under a button saying 'Open in
          // Outlook'.
          sourceUrl: 'file:///Applications/Calculator.app',
        ),
        onOpenLink: (_) => opened++,
      );

      // No button rather than a disabled one: there is nothing safe to do
      // with this, and a greyed-out control invites a second look.
      expect(find.byKey(AttachmentPreviewPanel.sourceLinkKey), findsNothing);
      expect(opened, 0);
    });

    testWidgets('a link with no url offers nothing to press', (tester) async {
      await pump(
        tester,
        ref(kind: 'card', name: null, cardText: 'Approve the quote'),
        onOpenLink: (_) {},
      );

      expect(find.byKey(AttachmentPreviewPanel.sourceLinkKey), findsNothing);
      expect(find.text('Approve the quote'), findsOneWidget);
    });

    testWidgets('a Word file is read from the store, never downloaded',
        (tester) async {
      final attachment = ref(name: 'Letter.docx', contentType: null);
      bytes.textByKey[FakeAttachmentBytes.keyOf(attachment)] =
          'Dear Dana, the survey is booked.';
      await pump(tester, attachment);

      expect(bytes.bytesCalls, 0);
      expect(find.text('Dear Dana, the survey is booked.'), findsOneWidget);
    });

    testWidgets('a document thumbnail that will not decode is simply absent',
        (tester) async {
      final attachment = ref(
        source: 'teams',
        name: 'Letter.docx',
        contentType: null,
      );
      bytes.textByKey[FakeAttachmentBytes.keyOf(attachment)] =
          'Dear Dana, the survey is booked.';
      // What OneDrive answers with when the session has drifted: an HTML
      // sign-in page, not a picture. Without an `errorBuilder` this throws
      // into the tree and takes the panel with it.
      bytes.thumbnailsByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1, 2, 3]);
      await pump(tester, attachment, pumps: 6);

      // The panel really did ask for, and receive, the undecodable bytes —
      // otherwise this test would pass for the wrong reason.
      expect(bytes.thumbnailCalls, 1);
      expect(tester.takeException(), isNull);
      expect(find.text('Dear Dana, the survey is booked.'), findsOneWidget);
    });
  });

  group('the Preview segment', () {
    testWidgets('an image sits on the preview ground', (tester) async {
      final attachment = imageRef(name: 'Screenshot.png');
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList(onePixelPng);
      await pump(tester, attachment);

      expect(find.byKey(ImagePreview.imageKey), findsOneWidget);
      final ground = tester.widget<ColoredBox>(find
          .descendant(
            of: find.byType(ImagePreview),
            matching: find.byType(ColoredBox),
          )
          .first);
      expect(ground.color, BondColors.previewGround);
    });

    testWidgets('a PDF goes through the renderer and never pdfium',
        (tester) async {
      final attachment = ref(name: 'Terms.pdf');
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1, 2, 3]);
      await pump(tester, attachment);

      expect(find.byKey(PdfPreview.viewerKey), findsOneWidget);
      expect(find.byKey(FakePdfRenderer.viewerKey), findsOneWidget);
      expect(pdf.lastViewerSourceName, 'Terms.pdf');
    });

    testWidgets('a sheet renders through the decoder', (tester) async {
      final attachment = ref(name: 'Quote.xlsx', contentType: null);
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1, 2, 3]);
      await pump(tester, attachment);

      expect(find.byType(SheetPreview), findsOneWidget);
      expect(find.text('Survey'), findsOneWidget);
    });

    testWidgets('a workbook that will not read says so', (tester) async {
      final attachment = ref(name: 'Quote.xlsx', contentType: null);
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1, 2, 3]);
      await pump(tester, attachment, failingWorkbook: true);

      expect(find.text('This workbook could not be read.'), findsOneWidget);
    });

    testWidgets('a text file is decoded even when its bytes are ragged',
        (tester) async {
      final attachment = ref(name: 'Rows.csv', contentType: null);
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([0x61, 0x2c, 0x62, 0xff]);
      await pump(tester, attachment);

      final body = tester.widget<SelectableText>(
        find.byKey(TextPreview.bodyKey),
      );
      expect(body.data, startsWith('a,b'));
      // A csv reads in columns.
      expect(body.style?.fontFamily, BondType.mono.fontFamily);
    });

    testWidgets('a forwarded message reads as a row', (tester) async {
      final attachment = ref(kind: 'item', name: 'Forwarded');
      bytes.textByKey[FakeAttachmentBytes.keyOf(attachment)] = 'Tuesday works.';
      await pump(tester, attachment);

      expect(find.byType(EmlPreview), findsOneWidget);
      expect(find.text('Tuesday works.'), findsOneWidget);
      expect(bytes.bytesCalls, 0);
    });

    testWidgets('a file nothing can draw is named, not drawn', (tester) async {
      await pump(tester, ref(name: 'Photo.heic', contentType: null));

      expect(find.byType(UnsupportedPreview), findsOneWidget);
      expect(bytes.bytesCalls, 0);
    });
  });

  group('the Text segment', () {
    testWidgets('a PDF is its pages joined', (tester) async {
      final attachment = ref(name: 'Terms.pdf');
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1, 2, 3]);
      pdf = FakePdfRenderer(pages: ['page one', 'page two']);
      await pump(tester, attachment);
      await tapSegment(tester, 'Text');

      final body = tester.widget<SelectableText>(
        find.byKey(TextPreview.bodyKey),
      );
      expect(body.data, 'page one\n\npage two');
      // Opened once, and closed again.
      expect(pdf.openCalls, 1);
      expect(pdf.disposeCalls, 1);
    });

    testWidgets('a DOCX is the words the server extracted', (tester) async {
      final attachment = ref(name: 'Letter.docx', contentType: null);
      bytes.textByKey[FakeAttachmentBytes.keyOf(attachment)] = 'The letter.';
      await pump(tester, attachment);
      await tapSegment(tester, 'Text');

      expect(find.text('The letter.'), findsOneWidget);
    });

    testWidgets('a sheet is its first sheet as tab-separated rows',
        (tester) async {
      final attachment = ref(name: 'Quote.xlsx', contentType: null);
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1, 2, 3]);
      await pump(tester, attachment);
      await tapSegment(tester, 'Text');

      final body = tester.widget<SelectableText>(
        find.byKey(TextPreview.bodyKey),
      );
      expect(body.data, 'Item\tAmount\nSurvey\t1,200');
    });

    testWidgets('a file still being read says so', (tester) async {
      await pump(tester, ref(name: 'Letter.docx', textStatus: 'pending'));
      await tapSegment(tester, 'Text');

      expect(find.text('Still reading this file…'), findsOneWidget);
    });

    testWidgets('a file the policy refused says why', (tester) async {
      await pump(tester, ref(
        name: 'Letter.docx',
        textStatus: 'skipped',
        textReason: 'no_extractor',
      ));
      await tapSegment(tester, 'Text');

      expect(
        find.text('This connection cannot extract text from this kind of file.'),
        findsOneWidget,
      );
    });

    testWidgets('a file refused as gated explains the message', (tester) async {
      await pump(tester, ref(
        // A document, not a pdf: a pdf fetches its bytes, and the fake has
        // none, so the panel's own load error would stand in front of the
        // segments this test is about.
        name: 'Order.docx',
        textStatus: 'skipped',
        textReason: 'gated',
        digestStatus: 'skipped',
      ));
      await tapSegment(tester, 'Text');

      expect(
        find.text(
          'This message was not sent to the model, so its files were not read.',
        ),
        findsOneWidget,
      );

      await tapSegment(tester, 'AI');
      expect(
        find.text('This file was not sent to the model.'),
        findsOneWidget,
      );
    });

    testWidgets('a truncated text says where it was cut', (tester) async {
      final attachment = AttachmentRef(
        source: 'email',
        messageId: 'm1',
        attachmentId: 'a1',
        name: 'Long.docx',
        textStatus: 'done',
        textTruncated: true,
        textChars: 20000,
      );
      bytes.textByKey[FakeAttachmentBytes.keyOf(attachment)] = 'the beginning';
      await pump(tester, attachment);
      await tapSegment(tester, 'Text');

      expect(find.text('Text was cut at 20000 characters.'), findsOneWidget);
    });
  });

  group('the AI segment', () {
    testWidgets('it speaks as the model, with its facts and its asks',
        (tester) async {
      await pump(tester, ref(
        digest: const AttachmentDigest(
          summary: 'A quote for the survey work.',
          facts: ['Total 1,200'],
          asks: ['Confirm the date'],
        ),
      ));
      await tapSegment(tester, 'AI');

      expect(find.text('AI: A quote for the survey work.'), findsOneWidget);
      expect(find.text('Facts'), findsOneWidget);
      expect(find.text('• Total 1,200'), findsOneWidget);
      expect(find.text('Asks'), findsOneWidget);
      expect(find.text('• Confirm the date'), findsOneWidget);
    });

    testWidgets('a digest with nothing to list lists nothing', (tester) async {
      await pump(tester, ref(
        digest: const AttachmentDigest(summary: 'A cover letter.'),
      ));
      await tapSegment(tester, 'AI');

      expect(find.text('Facts'), findsNothing);
      expect(find.text('Asks'), findsNothing);
    });

    testWidgets('a digest still running says so', (tester) async {
      await pump(tester, ref(digestStatus: 'pending', digest: null));
      await tapSegment(tester, 'AI');

      expect(find.text('Still reading this file…'), findsOneWidget);
    });

    testWidgets('a digest that failed says the model could not', (tester) async {
      await pump(tester, ref(digestStatus: 'error', digest: null));
      await tapSegment(tester, 'AI');

      expect(find.text('The model could not read this file.'), findsOneWidget);
      expect(find.byType(InlineAlert), findsOneWidget);
    });

    testWidgets('a file the model never saw says so', (tester) async {
      await pump(tester, ref(digestStatus: 'skipped', digest: null));
      await tapSegment(tester, 'AI');

      expect(find.text('This file was not sent to the model.'), findsOneWidget);
    });

    testWidgets('the model can be asked about a file nothing fetched',
        (tester) async {
      await pump(tester, ref(
        kind: 'reference',
        sourceUrl: 'https://drive/x',
        digest: const AttachmentDigest(summary: 'A shared budget.'),
      ));
      await tapSegment(tester, 'AI');

      expect(find.text('AI: A shared budget.'), findsOneWidget);
      expect(bytes.bytesCalls, 0);
    });
  });

  group('the actions', () {
    testWidgets('Open and Save ask the host, once each', (tester) async {
      var opened = 0;
      var saved = 0;
      final attachment = ref();
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1]);
      await pump(
        tester,
        attachment,
        onOpen: () => opened++,
        onSave: () => saved++,
      );

      await tester.tap(find.byKey(AttachmentPreviewPanel.openKey));
      await tester.tap(find.byKey(AttachmentPreviewPanel.saveKey));

      expect(opened, 1);
      expect(saved, 1);
    });

    testWidgets('a file that can run gets Save but not Open', (tester) async {
      var opened = 0;
      final attachment = ref(name: 'invoice.command', contentType: null);
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(attachment)] =
          Uint8List.fromList([1]);
      await pump(
        tester,
        attachment,
        onOpen: () => opened++,
        onSave: () {},
      );

      // The OS "opens" this by running it in Terminal, so Save — which writes
      // the bytes somewhere the user picked — is the only thing on offer.
      expect(find.byKey(AttachmentPreviewPanel.saveKey), findsOneWidget);
      expect(find.byKey(AttachmentPreviewPanel.openKey), findsNothing);
      expect(find.byKey(AttachmentPreviewPanel.openRefusedKey), findsOneWidget);
      expect(opened, 0);
    });

    testWidgets('a host with nowhere to send them renders neither',
        (tester) async {
      await pump(tester, ref());

      expect(find.byKey(AttachmentPreviewPanel.openKey), findsNothing);
      expect(find.byKey(AttachmentPreviewPanel.saveKey), findsNothing);
    });

    testWidgets('Use in reply and Pin are absent until they are wired',
        (tester) async {
      await pump(tester, ref());

      expect(find.byKey(AttachmentPreviewPanel.useInReplyKey), findsNothing);
      expect(find.byKey(AttachmentPreviewPanel.pinKey), findsNothing);
    });

    testWidgets('a pinned document says Pinned and stops answering',
        (tester) async {
      await pump(tester, ref(), onPinToStoryline: () {}, pinned: true);

      expect(find.text('Pinned'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.byKey(AttachmentPreviewPanel.pinKey),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('changing the file', () {
    testWidgets('a new attachment is fetched, the same one is not',
        (tester) async {
      final first = ref(name: 'One.pdf', attachmentId: 'a1');
      final second = ref(name: 'Two.pdf', attachmentId: 'a2');
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(first)] =
          Uint8List.fromList([1]);
      bytes.bytesByKey[FakeAttachmentBytes.keyOf(second)] =
          Uint8List.fromList([2]);

      await pump(tester, first);
      expect(bytes.bytesCalls, 1);

      // The same file with a digest that landed since — a rebuild, not a new
      // file, and it must not spend a second download.
      await pump(
        tester,
        ref(
          name: 'One.pdf',
          attachmentId: 'a1',
          digest: const AttachmentDigest(summary: 'A quote.'),
        ),
      );
      expect(bytes.bytesCalls, 1);

      await pump(tester, second);
      expect(bytes.bytesCalls, 2);
    });
  });
}

/// Bytes that never arrive, for the one test about the spinner.
class _SlowBytes extends FakeAttachmentBytes {
  final Future<Uint8List> pending;

  _SlowBytes(this.pending);

  @override
  Future<Uint8List> bytesFor(AttachmentRef ref) {
    bytesCalls++;
    return pending;
  }
}
