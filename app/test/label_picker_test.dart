import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/label_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The inline strip that does the whole dismiss-and-file flow: which chips it
/// draws, what the type-ahead does to them, and the four meanings of Enter.
Label _label(String id, String name, {String? tone}) =>
    Label(id: id, name: name, tone: tone);

void main() {
  late List<Label> applied;
  late List<String> created;
  late int dismissedWithout;
  late int closed;
  late List<(Label, LabelRuleOffer)> rules;

  setUp(() {
    applied = [];
    created = [];
    dismissedWithout = 0;
    closed = 0;
    rules = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    required List<Label> labels,
    bool withoutLabel = true,
    String prompt = 'Mark done with a label…',
    List<LabelRuleOffer> offers = const [],
    Label? offerLabel,
    bool onRule = false,
    Set<String> appliedIds = const {},
  }) async {
    await tester.binding.setSurfaceSize(const Size(600, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LabelPicker(
          labels: labels,
          prompt: prompt,
          onApply: applied.add,
          onCreate: created.add,
          onDismissWithoutLabel: withoutLabel ? () => dismissedWithout++ : null,
          onClose: () => closed++,
          ruleOffers: offers,
          ruleOfferLabel: offerLabel,
          onRuleChosen:
              onRule ? (label, offer) => rules.add((label, offer)) : null,
          appliedIds: appliedIds,
        ),
      ),
    ));
    await tester.pump();
  }

  /// What the hint line says right now.
  String hint(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(LabelPicker.hintKey)).data!;

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(LabelPicker.fieldKey), text);
    await tester.pump();
  }

  final fyi = _label('fyi', 'FYI only');
  final handled = _label('handled', 'Handled elsewhere');
  final vendor = _label('vendor', 'Vendor outreach', tone: 'attention');

  testWidgets('chips read in the order the host handed over', (tester) async {
    await pump(tester, labels: [fyi, handled, vendor]);

    final chips = tester
        .widgetList<BondChip>(find.descendant(
          of: find.byKey(LabelPicker.chipRowKey),
          matching: find.byType(BondChip),
        ))
        .map((chip) => chip.label)
        .toList();

    expect(chips, ['FYI only', 'Handled elsewhere', 'Vendor outreach']);
  });

  testWidgets('the prompt is the mount\'s own words', (tester) async {
    await pump(tester, labels: [fyi], prompt: LabelPickerMode.label.prompt);

    expect(find.text('Label…'), findsOneWidget);
    expect(find.text('Mark done with a label…'), findsNothing);
  });

  testWidgets('a tone word tints the chip through the tone map',
      (tester) async {
    await pump(tester, labels: [fyi, vendor]);

    final toned = tester.widget<BondChip>(find.descendant(
      of: find.byKey(LabelPicker.keyFor(vendor)),
      matching: find.byType(BondChip),
    ));
    final plain = tester.widget<BondChip>(find.descendant(
      of: find.byKey(LabelPicker.keyFor(fyi)),
      matching: find.byType(BondChip),
    ));

    expect(toned.tone, BondTone.attention);
    expect(plain.tone, BondTone.neutral);
  });

  testWidgets('typing filters the chips, case-insensitively', (tester) async {
    await pump(tester, labels: [fyi, handled, vendor]);

    await type(tester, 'else');

    expect(find.text('Handled elsewhere'), findsOneWidget);
    expect(find.text('FYI only'), findsNothing);
    expect(find.text('Vendor outreach'), findsNothing);
  });

  testWidgets('a tap applies that label', (tester) async {
    await pump(tester, labels: [fyi, handled]);

    await tester.tap(find.byKey(LabelPicker.keyFor(handled)));
    await tester.pump();

    expect(applied.map((l) => l.id), ['handled']);
    expect(created, isEmpty);
  });

  testWidgets('Enter applies the top filtered match', (tester) async {
    await pump(tester, labels: [fyi, handled, vendor]);

    await type(tester, 'ven');
    expect(hint(tester), "Enter — apply 'Vendor outreach'");

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(applied.map((l) => l.id), ['vendor']);
    expect(created, isEmpty);
  });

  testWidgets('Enter on a name nothing matches creates it, trimmed',
      (tester) async {
    await pump(tester, labels: [fyi]);

    await type(tester, '  Vendor outreach  ');
    expect(hint(tester), "Enter — create 'Vendor outreach'");

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(created, ['Vendor outreach']);
    expect(applied, isEmpty);
  });

  testWidgets('an empty box marks done with no label where that is wired',
      (tester) async {
    // An empty box with labels in the list still means "apply the top chip";
    // the no-label meaning is the one with nothing to apply either.
    await pump(tester, labels: const []);

    expect(hint(tester), 'Enter — mark done with no label');
    expect(find.byKey(LabelPicker.noLabelKey), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(dismissedWithout, 1);
    expect(applied, isEmpty);
    expect(created, isEmpty);
  });

  testWidgets('and is inert on the label-only mount', (tester) async {
    await pump(tester, labels: const [], withoutLabel: false);

    expect(hint(tester), 'Type a name and press Enter to create it');
    expect(find.byKey(LabelPicker.noLabelKey), findsNothing);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(dismissedWithout, 0);
    expect(applied, isEmpty);
    expect(created, isEmpty);
  });

  testWidgets('the no-label button marks done too', (tester) async {
    await pump(tester, labels: [fyi]);

    await tester.tap(find.byKey(LabelPicker.noLabelKey));
    await tester.pump();

    expect(dismissedWithout, 1);
  });

  testWidgets('Escape asks the host to collapse', (tester) async {
    await pump(tester, labels: [fyi]);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(closed, 1);
  });

  testWidgets('the chip row is capped and says how many it hid',
      (tester) async {
    final many = [
      for (var i = 0; i < LabelPicker.visibleChips + 3; i++)
        _label('l$i', 'Label $i'),
    ];
    await pump(tester, labels: many);

    // By label, either end of the cap: the first label the host handed over is
    // drawn and the one past the cap is not.
    expect(find.text('Label 0'), findsOneWidget);
    expect(find.text('Label ${LabelPicker.visibleChips - 1}'), findsOneWidget);
    expect(find.text('Label ${LabelPicker.visibleChips}'), findsNothing);
    expect(find.text('+3 more — keep typing'), findsOneWidget);
  });

  group('the rule offer', () {
    const sender =
        LabelRuleOffer(scopeKind: 'sender', scopeValue: 'noreply@jira.example.com');
    const domain =
        LabelRuleOffer(scopeKind: 'domain', scopeValue: 'jira.example.com');
    const kind = LabelRuleOffer(
        scopeKind: 'classification', scopeValue: 'tracker_notification');
    const subject =
        LabelRuleOffer(scopeKind: 'subject', scopeValue: '[JIRA] BOND-');

    /// Every widget the strip draws, which is how this file pins "off costs the
    /// strip nothing" without reading a pixel.
    int widgetCount(WidgetTester tester) => tester
        .widgetList(find.descendant(
          of: find.byType(LabelPicker),
          matching: find.byWidgetPredicate((_) => true),
        ))
        .length;

    testWidgets('the four scopes read as words a reader can judge',
        (tester) async {
      await pump(
        tester,
        labels: [fyi],
        offers: const [sender, domain, kind, subject],
        offerLabel: vendor,
        onRule: true,
      );

      expect(find.text("Also file future mail under 'Vendor outreach':"),
          findsOneWidget);
      expect(find.text('this sender'), findsOneWidget);
      expect(find.text('this domain'), findsOneWidget);
      expect(find.text('this kind of mail'), findsOneWidget);
      expect(find.text('subjects like "[JIRA] BOND-"'), findsOneWidget);
      // Never the stored token: `classification` and `tracker_notification`
      // are column values, not words.
      expect(find.textContaining('tracker_notification'), findsNothing);
    });

    testWidgets('pressing one hands back the label and the scope',
        (tester) async {
      await pump(
        tester,
        labels: [fyi],
        offers: const [sender, domain],
        offerLabel: vendor,
        onRule: true,
      );

      await tester.tap(find.byKey(LabelPicker.ruleKeyFor(domain)));
      await tester.pump();

      expect(rules, [(vendor, domain)]);
      // And it writes nothing itself, including nothing to the thread.
      expect(applied, isEmpty);
      expect(created, isEmpty);
      expect(dismissedWithout, 0);
    });

    testWidgets('a kind this build never heard of is still legible',
        (tester) async {
      const later = LabelRuleOffer(scopeKind: 'room', scopeValue: 'Design');
      await pump(
        tester,
        labels: [fyi],
        offers: const [later],
        offerLabel: vendor,
        onRule: true,
      );

      expect(find.text('this room'), findsOneWidget);
    });

    testWidgets('it never takes Enter off the type-ahead', (tester) async {
      await pump(
        tester,
        labels: [fyi, vendor],
        offers: const [sender],
        offerLabel: vendor,
        onRule: true,
      );

      // The hint line still says what it said, and Enter still does it.
      expect(hint(tester), "Enter — apply 'FYI only'");
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(applied, [fyi]);
      expect(rules, isEmpty);
    });

    testWidgets('and Escape still collapses the strip', (tester) async {
      await pump(
        tester,
        labels: [fyi],
        offers: const [sender],
        offerLabel: vendor,
        onRule: true,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(closed, 1);
    });

    testWidgets('off, the strip is the strip it was before rules existed',
        (tester) async {
      await pump(tester, labels: [fyi, handled]);
      final baseline = widgetCount(tester);

      // Each of the three parts alone is not an offer, and none of them costs
      // the strip a single widget.
      await pump(tester,
          labels: [fyi, handled], offers: const [sender, domain]);
      expect(widgetCount(tester), baseline);
      expect(find.byKey(LabelPicker.ruleRowKey), findsNothing);

      await pump(tester, labels: [fyi, handled], onRule: true);
      expect(widgetCount(tester), baseline);
      expect(find.byKey(LabelPicker.ruleRowKey), findsNothing);

      await pump(tester,
          labels: [fyi, handled], offers: const [sender], onRule: true);
      expect(widgetCount(tester), baseline);
      expect(find.byKey(LabelPicker.ruleRowKey), findsNothing);

      await pump(tester,
          labels: [fyi, handled], offerLabel: vendor, onRule: true);
      expect(widgetCount(tester), baseline);
      expect(find.byKey(LabelPicker.ruleRowKey), findsNothing);

      // And with all three, it costs something — otherwise the count above
      // would pin nothing at all.
      await pump(tester,
          labels: [fyi, handled],
          offers: const [sender],
          offerLabel: vendor,
          onRule: true);
      expect(widgetCount(tester), greaterThan(baseline));
      expect(find.byKey(LabelPicker.ruleRowKey), findsOneWidget);
    });
  });

  group('what is already on the thread', () {
    testWidgets('carries a ✓ and says so, and the rest do not', (tester) async {
      // The label mode: no way out with no label, so a chip only adds.
      await pump(
        tester,
        labels: [fyi, handled],
        appliedIds: {'fyi'},
        withoutLabel: false,
      );

      expect(find.text('✓ FYI only'), findsOneWidget);
      expect(find.text('Handled elsewhere'), findsOneWidget);
      expect(find.byTooltip('Already on this thread'), findsOneWidget);
      expect(find.byTooltip('Add Handled elsewhere'), findsOneWidget);
    });

    testWidgets('in the dismiss mode a chip says it closes the thread',
        (tester) async {
      await pump(
        tester,
        labels: [fyi, handled],
        appliedIds: {'fyi'},
        withoutLabel: true,
      );

      expect(find.byTooltip('Mark done under Handled elsewhere'),
          findsOneWidget);
      expect(find.byTooltip('Mark done — already labeled FYI only'),
          findsOneWidget);
      expect(find.byTooltip('Add Handled elsewhere'), findsNothing);
    });

    testWidgets('a tap still reaches the host, which decides', (tester) async {
      // The picker does not second-guess: in the dismiss mode a label already
      // on the thread is a legitimate reason to close it with.
      await pump(tester, labels: [fyi], appliedIds: {'fyi'});
      await tester.tap(find.byKey(LabelPicker.keyFor(fyi)));

      expect(applied, [fyi]);
    });
  });
}
