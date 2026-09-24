import 'dart:typed_data';

import 'package:bond_inbox/widgets/preview/html_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// The card a web page previews as: a picture of it if one was drawn, the words
/// below it, and one door to the browser that only exists when there is
/// somewhere for it to go.
///
/// Nothing here renders HTML and nothing here can: the widget takes PNG bytes
/// and a body widget, so there is no WebKit, no channel and no browser behind
/// any of it.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    Uint8List? snapshot,
    String? name = 'security-report.html',
    VoidCallback? onOpenInBrowser,
    Widget? body,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          height: 520,
          child: HtmlPreview(
            glyph: '🌐',
            name: name,
            snapshot: snapshot,
            onOpenInBrowser: onOpenInBrowser,
            body: body ??
                const Text('Two accounts need a password change.'),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('the picture', () {
    testWidgets('bytes that decode are the rendering', (tester) async {
      await pump(tester, snapshot: Uint8List.fromList(onePixelPng));

      expect(find.byKey(HtmlPreview.snapshotKey), findsOneWidget);
      expect(find.byKey(HtmlPreview.glyphKey), findsNothing);
    });

    testWidgets('no snapshot is the glyph card, named', (tester) async {
      await pump(tester);

      expect(find.byKey(HtmlPreview.glyphKey), findsOneWidget);
      expect(find.byKey(HtmlPreview.snapshotKey), findsNothing);
      expect(find.text('🌐'), findsOneWidget);
      expect(find.text('security-report.html'), findsOneWidget);
    });

    testWidgets('a file nobody named draws the glyph alone', (tester) async {
      await pump(tester, name: null);

      expect(find.byKey(HtmlPreview.glyphKey), findsOneWidget);
      expect(find.text('🌐'), findsOneWidget);
    });

    testWidgets('bytes that will not decode take nothing with them',
        (tester) async {
      // What the channel would hand back if a snapshot were ever truncated.
      // Without the `errorBuilder` this throws into the tree and the panel
      // around it goes with it.
      await pump(tester, snapshot: Uint8List.fromList([1, 2, 3]));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(tester.takeException(), isNull);
      expect(find.byKey(HtmlPreview.cardKey), findsOneWidget);
      expect(find.text('Two accounts need a password change.'), findsOneWidget);
    });
  });

  group('the door to the browser', () {
    testWidgets('the whole card is the tap target', (tester) async {
      var opened = 0;
      await pump(
        tester,
        snapshot: Uint8List.fromList(onePixelPng),
        onOpenInBrowser: () => opened++,
      );

      await tester.tap(find.byKey(HtmlPreview.cardKey));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('the glyph card opens too', (tester) async {
      var opened = 0;
      await pump(tester, onOpenInBrowser: () => opened++);

      // On the glyph itself, which is as far from the Open line as a press
      // inside this card can land.
      await tester.tap(find.text('🌐'));
      await tester.pump();

      expect(opened, 1);
    });

    testWidgets('it says where it goes and what to think about first',
        (tester) async {
      await pump(tester, onOpenInBrowser: () {});

      expect(find.text('Open in browser'), findsOneWidget);
      expect(find.byKey(HtmlPreview.cautionKey), findsOneWidget);
      expect(
        find.text(HtmlPreview.caution),
        findsOneWidget,
        reason: 'the caution is read before the press, not after',
      );
    });

    testWidgets('with nowhere to open it there is no control at all',
        (tester) async {
      await pump(tester, snapshot: Uint8List.fromList(onePixelPng));

      // A dead control is worse than no control, and a caution about a browser
      // nothing can reach is worse still.
      expect(find.text('Open in browser'), findsNothing);
      expect(find.byKey(HtmlPreview.cautionKey), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byKey(HtmlPreview.cardKey), findsOneWidget);
    });
  });

  group('the words', () {
    testWidgets('they are under the card either way', (tester) async {
      await pump(
        tester,
        body: const Text('The review lists two accounts.'),
        onOpenInBrowser: () {},
      );
      expect(find.text('The review lists two accounts.'), findsOneWidget);

      await pump(
        tester,
        snapshot: Uint8List.fromList(onePixelPng),
        body: const Text('The review lists two accounts.'),
      );
      expect(find.text('The review lists two accounts.'), findsOneWidget);
    });
  });
}
