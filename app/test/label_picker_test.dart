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

  setUp(() {
    applied = [];
    created = [];
    dismissedWithout = 0;
    closed = 0;
  });

  Future<void> pump(
    WidgetTester tester, {
    required List<Label> labels,
    bool withoutLabel = true,
    String prompt = 'Mark done with a label…',
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
