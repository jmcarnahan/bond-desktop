import 'dart:typed_data';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/attachment_card.dart';
import 'package:bond_inbox/widgets/attachment_format.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// The file card: what a file is, what it looks like, and the one line the
/// model wrote about it.
///
/// The rules pinned here are the ones a reader would notice going wrong: the
/// `AI:` line appears only when a model actually read the document, a card
/// with nowhere to go is a statement rather than a control, and Use in reply
/// is an accelerator under the pointer that never becomes the only way in.

void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    required AttachmentRef attachment,
    bool selected = false,
    ImageProvider? image,
    VoidCallback? onTap,
    VoidCallback? onUseInReply,
    bool compact = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AttachmentCard(
            attachment: attachment,
            selected: selected,
            image: image,
            onTap: onTap,
            onUseInReply: onUseInReply,
            compact: compact,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// A picture that decodes without touching a disk.
  final ImageProvider memoryImage =
      MemoryImage(Uint8List.fromList(onePixelPng));

  /// Puts a MOUSE over the card. Touch never enters a `MouseRegion`, which is
  /// what keeps the hover strip an accelerator.
  Future<TestGesture> hoverCard(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(AttachmentCard)));
    await tester.pump();
    return gesture;
  }

  group('what the card says about a file', () {
    testWidgets('the name, the size and the kind ride on one caption',
        (tester) async {
      await pumpCard(
        tester,
        attachment: ref(name: 'Contract.pdf', size: 240 * 1024),
      );

      expect(find.text('Contract.pdf'), findsOneWidget);
      expect(find.text('240 KB · PDF'), findsOneWidget);
    });

    testWidgets("the model's word for the document beats the extension",
        (tester) async {
      await pumpCard(
        tester,
        attachment: ref(
          name: 'Contract.pdf',
          size: 240 * 1024,
          digest: const AttachmentDigest(kind: 'quote', summary: ''),
        ),
      );

      expect(find.text('240 KB · Quote'), findsOneWidget);
    });

    testWidgets("a digest that could not say what it is falls back to the "
        'extension', (tester) async {
      await pumpCard(
        tester,
        attachment: ref(
          name: 'Contract.pdf',
          size: 240 * 1024,
          digest: const AttachmentDigest(kind: 'other', summary: ''),
        ),
      );

      expect(find.text('240 KB · PDF'), findsOneWidget);
    });

    testWidgets('a 300-character name is cut on graphemes, not code units',
        (tester) async {
      final long = '👍' * 300;
      await pumpCard(tester, attachment: ref(name: '$long.pdf'));

      // The cut happened, and it left whole emoji rather than half a surrogate
      // pair — a broken pair renders as the replacement box.
      final text = tester.widget<Text>(
        find.textContaining('👍', findRichText: false).first,
      );
      expect(text.data, contains('…'));
      expect(text.data!.contains('�'), isFalse);
    });

    testWidgets('a file with no name still has a card', (tester) async {
      await pumpCard(tester, attachment: ref(name: null, contentType: null));

      expect(find.text('(unnamed)'), findsOneWidget);
    });
  });

  group("the model's line", () {
    testWidgets('a summary is drawn under the AI label, keyed by its file',
        (tester) async {
      final quote = ref(
        digest: const AttachmentDigest(
          kind: 'quote',
          summary: 'Two options, both due Friday.',
        ),
      );
      await pumpCard(tester, attachment: quote);

      expect(find.text('AI: Two options, both due Friday.'), findsOneWidget);
      expect(find.byKey(attachmentKey('digest', quote)), findsOneWidget);
    });

    testWidgets('no digest is no line at all', (tester) async {
      final plain = ref();
      await pumpCard(tester, attachment: plain);

      expect(find.byKey(attachmentKey('digest', plain)), findsNothing);
      expect(find.textContaining('AI:'), findsNothing);
    });

    testWidgets('an empty summary is not a line either', (tester) async {
      final empty = ref(digest: const AttachmentDigest(kind: 'quote'));
      await pumpCard(tester, attachment: empty);

      expect(find.byKey(attachmentKey('digest', empty)), findsNothing);
    });

    testWidgets('words in and no answer yet reads as reading…', (tester) async {
      await pumpCard(
        tester,
        attachment: ref(textStatus: 'done', digestStatus: 'pending'),
      );

      expect(find.text('reading…'), findsOneWidget);
    });

    testWidgets('a file whose words never landed promises nothing',
        (tester) async {
      // Pending on both counts is a freshly synced attachment, and a card that
      // said "reading…" on every file the policy will never read would be a
      // promise the pipeline does not keep.
      await pumpCard(
        tester,
        attachment: ref(textStatus: 'pending', digestStatus: 'pending'),
      );

      expect(find.text('reading…'), findsNothing);
    });
  });

  group('the picture', () {
    testWidgets('a rendering is drawn where the glyph would be',
        (tester) async {
      final page = ref();
      await pumpCard(tester, attachment: page, image: memoryImage);

      expect(find.byKey(AttachmentCard.imageKeyFor(page)), findsOneWidget);
    });

    testWidgets('no rendering is the glyph, never an empty frame',
        (tester) async {
      final page = ref(name: 'Contract.pdf');
      await pumpCard(tester, attachment: page);

      expect(find.byKey(AttachmentCard.imageKeyFor(page)), findsNothing);
      expect(find.text('📕'), findsOneWidget);
    });
  });

  group('selection and tapping', () {
    testWidgets('a selected card changes its fill and its border',
        (tester) async {
      await pumpCard(tester, attachment: ref(), selected: true);

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(AttachmentCard),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, BondColors.previewGround);
      expect(
        (decoration.border! as Border).top.color,
        BondColors.primary,
      );
    });

    testWidgets('an unselected card is plain surface inside the hairline',
        (tester) async {
      await pumpCard(tester, attachment: ref());

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(AttachmentCard),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, BondColors.surface);
      expect((decoration.border! as Border).top.color, BondColors.border);
    });

    testWidgets('nowhere to open one leaves the card a statement',
        (tester) async {
      await pumpCard(tester, attachment: ref());

      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('a tap reaches the host', (tester) async {
      var taps = 0;
      await pumpCard(tester, attachment: ref(), onTap: () => taps++);

      await tester.tap(find.byType(AttachmentCard));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('use in reply', () {
    testWidgets('a host that cannot reply gets no strip, hover or not',
        (tester) async {
      final quote = ref();
      await pumpCard(tester, attachment: quote);

      await hoverCard(tester);

      expect(find.byKey(AttachmentCard.useInReplyKeyFor(quote)), findsNothing);
    });

    testWidgets('the pointer brings it up, and it hands back this file',
        (tester) async {
      final quote = ref();
      var used = 0;
      await pumpCard(
        tester,
        attachment: quote,
        onUseInReply: () => used++,
      );

      // Absent until a mouse is over the card: nothing may live only here.
      expect(find.byKey(AttachmentCard.useInReplyKeyFor(quote)), findsNothing);

      await hoverCard(tester);
      expect(
        find.byKey(AttachmentCard.useInReplyKeyFor(quote)),
        findsOneWidget,
      );

      await tester.tap(find.byKey(AttachmentCard.useInReplyKeyFor(quote)));
      await tester.pump();

      expect(used, 1);
    });
  });

  group('the bookmark shape', () {
    testWidgets('compact says it is pinned, on one line, with no picture',
        (tester) async {
      final quote = ref(name: 'Quote.pdf');
      await pumpCard(
        tester,
        attachment: quote,
        image: memoryImage,
        compact: true,
      );

      expect(find.text('📌 📕 Quote.pdf'), findsOneWidget);
      expect(find.byKey(AttachmentCard.imageKeyFor(quote)), findsNothing);
    });

    testWidgets('compact keeps the digest line — it is why a file is pinned',
        (tester) async {
      final quote = ref(
        name: 'Quote.pdf',
        digest: const AttachmentDigest(
          kind: 'quote',
          summary: 'Two options, both due Friday.',
        ),
      );
      await pumpCard(tester, attachment: quote, compact: true);

      expect(find.byKey(attachmentKey('digest', quote)), findsOneWidget);
    });

    testWidgets('compact draws no hover strip even when one was offered',
        (tester) async {
      final quote = ref(name: 'Quote.pdf');
      await pumpCard(
        tester,
        attachment: quote,
        compact: true,
        onUseInReply: () {},
      );

      await hoverCard(tester);

      expect(find.byKey(AttachmentCard.useInReplyKeyFor(quote)), findsNothing);
    });
  });
}
