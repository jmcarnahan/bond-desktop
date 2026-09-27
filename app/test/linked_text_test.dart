import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/linked_text.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One run, written the way the table below reads it: what gets painted, and
/// where a tap on it goes.
String _sketch(LinkedRun run) => switch (run) {
      PlainRun(:final text) => 'plain:$text',
      LinkRun(:final label, :final target) => 'link:$label → $target',
    };

List<String> _runs(String text) => linkSpansOf(text).map(_sketch).toList();

/// The same table read the way a message BODY reads it.
List<String> _bodyRuns(String text) => linkSpansOf(
      text,
      maxLabelChars: bodyMaxLabelChars,
      maxLabelWords: bodyMaxLabelWords,
    ).map(_sketch).toList();

/// What the widget actually paints — the plain text of its one paragraph.
String _painted(WidgetTester tester) {
  final text = tester.widget<Text>(find.byType(Text));
  return text.textSpan!.toPlainText();
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('linkTargetOf', () {
    test('takes web addresses and mailto, and nothing else', () {
      expect(linkTargetOf('https://metrics.example.com/a')?.host,
          'metrics.example.com');
      expect(linkTargetOf('http://metrics.example.com/a')?.scheme, 'http');
      expect(linkTargetOf('mailto:dana@example.com')?.scheme, 'mailto');
      expect(linkTargetOf('file:///Applications/Calculator.app'), isNull);
      expect(linkTargetOf('smb://198.51.100.7/share'), isNull);
      expect(linkTargetOf('javascript:alert(1)'), isNull);
      expect(linkTargetOf('https://'), isNull);
      expect(linkTargetOf('mailto:nobody'), isNull);
      expect(linkTargetOf('dana@example.com'), isNull);
      expect(linkTargetOf('  '), isNull);
    });
  });

  group('linkSpansOf', () {
    test('a canonical run paints its label and carries the address', () {
      expect(
        _runs('Open the dashboard <https://metrics.example.com/rooms/01f0> '
            'today.'),
        [
          'link:Open the dashboard → https://metrics.example.com/rooms/01f0',
          'plain: today.',
        ],
      );
    });

    test('a label stops at the sentence before it', () {
      expect(
        _runs('Sent it. Details <https://plans.example.com/q3>'),
        [
          'plain:Sent it. ',
          'link:Details → https://plans.example.com/q3',
        ],
      );
    });

    test('a run with no label in front of it paints the address', () {
      expect(
        _runs('<https://plans.example.com/q3> is the plan'),
        [
          'link:https://plans.example.com/q3 → https://plans.example.com/q3',
          'plain: is the plan',
        ],
      );
      expect(
        _runs('See (<https://plans.example.com/q3>)'),
        [
          'plain:See (',
          'link:https://plans.example.com/q3 → https://plans.example.com/q3',
          'plain:)',
        ],
      );
    });

    test('a sentence is not a label — the address paints itself', () {
      expect(
        _runs('Verify access to the tool at '
            '<https://metrics.example.com/rooms/01f0>'),
        [
          'plain:Verify access to the tool at ',
          'link:https://metrics.example.com/rooms/01f0 → '
              'https://metrics.example.com/rooms/01f0',
        ],
      );
    });

    test('a body reads longer labels than an ask line does', () {
      // Both of these are real anchor text, wrapped by a mail gateway into an
      // address nobody wants to read. Too many words for the tight pair an ask
      // line uses; a body takes them.
      const slot = 'https://links.example.net/?url=calendar.example.com'
          '%2Fslots%2F7a2c&d=05';
      const why = 'https://links.example.net/?url=support.example.com'
          '%2Fwhy-this-mail&d=05';
      expect(
        _bodyRuns('Does not suit? I want to choose another time <$slot>'),
        [
          'plain:Does not suit? ',
          'link:I want to choose another time → $slot',
        ],
      );
      expect(
        _bodyRuns('Sent by an automation. '
            'Why am I receiving this notification from Office? <$why>'),
        [
          'plain:Sent by an automation. ',
          'link:Why am I receiving this notification from Office? → $why',
        ],
      );
      // The tight pair, which the ask line and the CTA banner keep, hands the
      // same words back to the address.
      expect(
        _runs('Does not suit? I want to choose another time <$slot>'),
        [
          'plain:Does not suit? I want to choose another time ',
          'link:$slot → $slot',
        ],
      );
    });

    test('a target that is not a link leaves the whole run literal', () {
      const text = 'Run this <file:///Applications/Calculator.app> now';
      expect(_runs(text), ['plain:$text']);
      // A mail header address is not a canonical run: no scheme, no link.
      expect(_runs('Dana Ruiz <dana@example.com> asked'),
          ['plain:Dana Ruiz <dana@example.com> asked']);
    });

    test('a mailto run is a link', () {
      expect(
        _runs('Email Dana Ruiz <mailto:dana@example.com> about it'),
        [
          'link:Email Dana Ruiz → mailto:dana@example.com',
          'plain: about it',
        ],
      );
    });

    test('a bare address is a link, and the sentence keeps its full stop', () {
      expect(
        _runs('Try https://plans.example.com/q3. Then stop.'),
        [
          'plain:Try ',
          'link:https://plans.example.com/q3 → https://plans.example.com/q3',
          'plain:. Then stop.',
        ],
      );
    });

    test('two runs on one line stay two runs', () {
      expect(
        _runs('Plan <https://plans.example.com/q3>, Notes '
            '<https://notes.example.com/n1>'),
        [
          'link:Plan → https://plans.example.com/q3',
          'plain:, ',
          'link:Notes → https://notes.example.com/n1',
        ],
      );
    });

    test('a zero-width space beside a run breaks nothing', () {
      // `mail_text` leaves these in bodies as soft break points, and one can
      // land on either side of a run.
      const zw = '\u200B';
      expect(
        _runs('Docs$zw <https://plans.example.com/q3>$zw here'),
        [
          'link:Docs → https://plans.example.com/q3',
          'plain:$zw here',
        ],
      );
      expect(
        _runs('Try https://plans.example.com/q3$zw next'),
        [
          'plain:Try ',
          'link:https://plans.example.com/q3 → https://plans.example.com/q3',
          'plain:$zw next',
        ],
      );
    });

    test('text with no links in it is one untouched run', () {
      expect(_runs('Just words, <not a link> at all.'),
          ['plain:Just words, <not a link> at all.']);
      expect(_runs(''), isEmpty);
    });
  });

  group('firstLinkOf', () {
    /// What a call-to-action button would wear, and where it would go.
    String? cta(String text) {
      final run = firstLinkOf(text);
      return run == null ? null : '${run.label} → ${run.target}';
    }

    test('the first anchored link in a body', () {
      expect(
        cta('Amina left a comment.\n\n'
            'View comment <https://tracker.example.com/t/41#c9>\n\n'
            'Manage notifications <https://tracker.example.com/prefs>'),
        'View comment → https://tracker.example.com/t/41#c9',
      );
    });

    test('a body with no links at all offers nothing', () {
      expect(cta('Nothing to click here.'), isNull);
      expect(cta(''), isNull);
    });

    test('a bare address is not an anchor, so it is skipped', () {
      // A button reading `https://…%2Foverview%23comment-…` tells a reader
      // nothing and does not fit on a row.
      expect(cta('See https://tracker.example.com/t/41 for more.'), isNull);
    });

    test('a bare address is skipped and a later anchor still found', () {
      expect(
        cta('Raw https://tracker.example.com/raw first.\n'
            'Approve request <https://tracker.example.com/approve/7>'),
        'Approve request → https://tracker.example.com/approve/7',
      );
    });

    test('mailto is not an external tool', () {
      // A composer is not "the real action is over there", which is the one
      // thing this answers.
      expect(cta('Reply to us <mailto:desk@vendor.example.net> any time.'),
          isNull);
      expect(
        cta('Mail us <mailto:desk@vendor.example.net>\n'
            'Open ticket <https://tracker.example.com/t/9>'),
        'Open ticket → https://tracker.example.com/t/9',
      );
    });

    test('an anchor whose words are long still counts, up to the body caps', () {
      // The caps default to the BODY pair, because real anchor text is a
      // sentence as often as a phrase.
      const label = 'Why am I receiving this notification from the tracker?';
      expect(
        cta('$label <https://tracker.example.com/help>'),
        '$label → https://tracker.example.com/help',
      );
    });

    test('words past the caps are not a label, so that run is skipped', () {
      // Past the caps `linkSpansOf` paints the address itself, which is exactly
      // the run this refuses.
      final long = List.filled(bodyMaxLabelWords + 4, 'word').join(' ');
      expect(cta('$long <https://tracker.example.com/x>'), isNull);
    });

    test('a percent-encoded wrapper behind real words is still an anchor', () {
      // The reason the anchor test asks [linkTargetOf] about the LABEL rather
      // than comparing it against `target.toString()`: `Uri` re-normalizes
      // percent-encoding on the way back out, and a wrapper is nothing but
      // percent-encoding.
      expect(
        cta('View comment '
            '<https://links.example.com/?url=https%3A%2F%2Ftracker.example.com'
            '%2Ft%2F41%23c9>'),
        startsWith('View comment → https://links.example.com/'),
      );
    });
  });

  group('LinkedText', () {
    testWidgets('paints the label, not the address', (tester) async {
      await tester.pumpWidget(_host(LinkedText(
        'Open the dashboard <https://metrics.example.com/rooms/01f0> today.',
        onOpenLink: (_) {},
      )));

      expect(_painted(tester), 'Open the dashboard today.');
    });

    testWidgets('a tap on the label opens the WHOLE address', (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(_host(LinkedText(
        'Open the dashboard <https://metrics.example.com/rooms/01f0b5d9> '
        'today.',
        onOpenLink: opened.add,
      )));

      await tester.tapOnText(find.textRange.ofSubstring('Open the dashboard'));
      await tester.pump();

      expect(opened.map((u) => u.toString()).toList(),
          ['https://metrics.example.com/rooms/01f0b5d9']);
    });

    testWidgets('a tap on the words around a link opens nothing',
        (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(_host(LinkedText(
        'Sent it. Details <https://plans.example.com/q3>',
        onOpenLink: opened.add,
        selectable: false,
      )));

      await tester.tapOnText(find.textRange.ofSubstring('Sent it.'));
      await tester.pump();

      expect(opened, isEmpty);
    });

    testWidgets('links are drawn in the product copper, underlined',
        (tester) async {
      await tester.pumpWidget(_host(LinkedText(
        'Plan <https://plans.example.com/q3> is up',
        style: BondType.body,
        onOpenLink: (_) {},
      )));

      final span = tester.widget<Text>(find.byType(Text)).textSpan!
          as TextSpan;
      final link = span.children!.first as TextSpan;
      expect(link.text, 'Plan');
      expect(link.style?.color, BondColors.primary);
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.mouseCursor, SystemMouseCursors.click);
      expect(link.recognizer, isNotNull);
    });

    testWidgets('with nowhere to send a tap it is words, not a link',
        (tester) async {
      await tester.pumpWidget(_host(const LinkedText(
        'Plan <https://plans.example.com/q3> is up',
      )));

      final span = tester.widget<Text>(find.byType(Text)).textSpan!
          as TextSpan;
      final first = span.children!.first as TextSpan;
      expect(first.text, 'Plan');
      expect(first.recognizer, isNull);
      expect(first.style, isNull);
    });

    testWidgets('a body is selectable and an ask line is not', (tester) async {
      await tester.pumpWidget(_host(const LinkedText('Body words')));
      expect(find.byType(SelectionArea), findsOneWidget);

      await tester.pumpWidget(
        _host(const LinkedText('Ask words', selectable: false)),
      );
      expect(find.byType(SelectionArea), findsNothing);
    });

    // The hovered link's host on a caption line under the text: a line in the
    // layout, never a tooltip. The text is ONE run and centred, so the middle
    // of the paragraph is the middle of the link.
    const hoverKey = ValueKey('linked-text-hover-host');
    Widget centred(LinkedText child) => _host(Center(child: child));

    Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(1, 1));
      await gesture.moveTo(at);
      await tester.pump();
      return gesture;
    }

    testWidgets('hovering a link shows its host, and leaving hides it',
        (tester) async {
      await tester.pumpWidget(centred(LinkedText(
        'Statement <https://bank.example/s/1>',
        onOpenLink: (_) {},
      )));
      expect(find.byKey(hoverKey), findsNothing);

      final gesture =
          await mouseAt(tester, tester.getCenter(find.byType(RichText)));

      expect(find.byKey(hoverKey), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(hoverKey)).data, 'bank.example');

      await gesture.moveTo(
        tester.getBottomRight(find.byType(Scaffold)) - const Offset(4, 4),
      );
      await tester.pump();

      expect(find.byKey(hoverKey), findsNothing);
      await gesture.removePointer();
    });

    testWidgets('hovering keeps the paragraph and its selection area',
        (tester) async {
      // Only the caption comes and goes. A root that flipped between the body
      // and a column would remount both, and drop a selection mid-drag.
      await tester.pumpWidget(centred(LinkedText(
        'Statement <https://bank.example/s/1>',
        onOpenLink: (_) {},
      )));
      final area = tester.state(find.byType(SelectionArea));
      final paragraph = tester.renderObject(find.byType(RichText).first);

      final gesture =
          await mouseAt(tester, tester.getCenter(find.byType(RichText).first));

      expect(find.byKey(hoverKey), findsOneWidget);
      expect(identical(tester.state(find.byType(SelectionArea)), area), isTrue);
      expect(
        identical(tester.renderObject(find.byType(RichText).first), paragraph),
        isTrue,
      );
      await gesture.removePointer();
    });

    testWidgets('a Safe Links wrapper shows the host it carries',
        (tester) async {
      const wrapper = 'https://nam02.safelinks.protection.outlook.com/'
          '?url=https%3A%2F%2Fvendor.example%2Fdoc&data=05%7C01%7C';
      await tester.pumpWidget(centred(LinkedText(
        'Proposal <$wrapper>',
        onOpenLink: (_) {},
      )));

      final gesture =
          await mouseAt(tester, tester.getCenter(find.byType(RichText)));

      expect(tester.widget<Text>(find.byKey(hoverKey)).data, 'vendor.example');
      await gesture.removePointer();
    });

    testWidgets('a mailto link shows the address it writes to',
        (tester) async {
      await tester.pumpWidget(centred(LinkedText(
        'Write to us <mailto:help@example.com>',
        onOpenLink: (_) {},
        selectable: false,
      )));

      final gesture =
          await mouseAt(tester, tester.getCenter(find.byType(RichText)));

      expect(
        tester.widget<Text>(find.byKey(hoverKey)).data,
        'help@example.com',
      );
      await gesture.removePointer();
    });

    testWidgets('words with nowhere to send a tap never show a host',
        (tester) async {
      await tester.pumpWidget(centred(const LinkedText(
        'Statement <https://bank.example/s/1>',
      )));

      final gesture =
          await mouseAt(tester, tester.getCenter(find.byType(RichText)));

      expect(find.byKey(hoverKey), findsNothing);
      await gesture.removePointer();
    });

    testWidgets('new text gets new recognizers and the old ones go',
        (tester) async {
      final opened = <Uri>[];
      Widget at(String text) => _host(LinkedText(text, onOpenLink: opened.add));

      await tester.pumpWidget(at('Plan <https://plans.example.com/q3> is up'));
      await tester.tapOnText(find.textRange.ofSubstring('Plan'));
      await tester.pump();

      await tester.pumpWidget(at('Notes <https://notes.example.com/n1> too'));
      await tester.tapOnText(find.textRange.ofSubstring('Notes'));
      await tester.pump();

      expect(opened.map((u) => u.toString()).toList(), [
        'https://plans.example.com/q3',
        'https://notes.example.com/n1',
      ]);

      // Pumped away: the State disposes what it made, and a disposed
      // recognizer that anything still held would throw here.
      await tester.pumpWidget(_host(const SizedBox()));
      expect(tester.takeException(), isNull);
    });
  });
}
