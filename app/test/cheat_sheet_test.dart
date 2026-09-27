import 'package:bond_inbox/screens/inbox_screen.dart' show triageKeys;
import 'package:bond_inbox/widgets/triage_intents.dart';
import 'package:bond_inbox/widgets/cheat_sheet_panel.dart';
import 'package:bond_inbox/widgets/find_field.dart' show findCommands;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sheet is held against the two things it describes: the inbox's key
/// map and the palette's key hints. Asserted on the const table rather than on
/// the rendered panel, because the table is what the panel draws and a test
/// that read pixels would pass a sheet the table had already lied in.

/// What the sheet calls one activator — its own glyphs, so the lookup is
/// exact. The control twin of a ⌘ binding is the same key to a Mac reader and
/// is taught as ⌘.
String keyLabel(ShortcutActivator any) {
  if (any is CharacterActivator) return any.character;
  final activator = any as SingleActivator;
  final key = activator.trigger;
  final named = {
    LogicalKeyboardKey.arrowDown: '↓',
    LogicalKeyboardKey.arrowUp: '↑',
    LogicalKeyboardKey.bracketRight: ']',
    LogicalKeyboardKey.bracketLeft: '[',
    LogicalKeyboardKey.escape: 'Esc',
  }[key];
  if (named != null) return named;
  final letter = key.keyLabel;
  if (activator.meta || activator.control) return '⌘${letter.toUpperCase()}';
  if (activator.shift) return '⇧${letter.toUpperCase()}';
  return letter.toLowerCase();
}

void main() {
  test('every binding in the key map has a line on the sheet', () {
    for (final MapEntry(key: activator, value: intent) in triageKeys.entries) {
      final label = keyLabel(activator);
      final lines = [
        for (final e in cheatSheetEntries)
          if (e.intents.contains(intent.runtimeType) && e.keys.contains(label))
            e,
      ];
      expect(lines, isNotEmpty,
          reason: '$label → ${intent.runtimeType} is bound but not taught');
    }
  });

  test('and no line teaches an intent the map does not bind', () {
    final bound = {for (final i in triageKeys.values) i.runtimeType};
    for (final entry in cheatSheetEntries) {
      for (final intent in entry.intents) {
        expect(bound, contains(intent), reason: entry.description);
      }
    }
  });

  test('every key the palette hints at is on the sheet', () {
    final taught = {for (final e in cheatSheetEntries) ...e.keys};
    for (final command in findCommands) {
      expect(taught, contains(command.keyHint), reason: command.label);
    }
  });

  test('the selection rule and the tick key are both said', () {
    // WP6-A's `x`, and what the triage letters do once it has been used —
    // the one place a key means two things, which is why it is written down.
    expect(
      cheatSheetEntries.where((e) => e.keys.contains('x')),
      isNotEmpty,
    );
    final rule = cheatSheetEntries.singleWhere(
      (e) => e.description.contains('selection'),
    );
    expect(rule.keys, containsAll(['e', 's', 'm', 'l', '⇧E']));
  });

  test('the keys that act on a thread fire once per press', () {
    // The one-act latch does not absorb a key repeat, so the flag is the only
    // thing between a held `m` and a run of dropped senders down the pile.
    const acting = {
      DismissThreadIntent,
      DismissWithLabelIntent,
      LabelThreadIntent,
      LaterThreadIntent,
      QuickReplyIntent,
      DropSenderIntent,
      ToggleCheckedIntent,
    };
    final seen = <Type>{};
    for (final MapEntry(key: activator, value: intent) in triageKeys.entries) {
      if (!acting.contains(intent.runtimeType)) continue;
      seen.add(intent.runtimeType);
      expect((activator as SingleActivator).includeRepeats, isFalse,
          reason: '${keyLabel(activator)} → ${intent.runtimeType} repeats');
    }
    // Every acting intent is bound, so the loop above checked each of them.
    expect(seen, acting);
  });

  test('and the movement keys still repeat', () {
    final moving = {
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
    };
    final found = <LogicalKeyboardKey>{};
    for (final activator in triageKeys.keys) {
      if (activator is! SingleActivator) continue;
      if (!moving.contains(activator.trigger)) continue;
      found.add(activator.trigger);
      expect(activator.includeRepeats, isTrue,
          reason: '${keyLabel(activator)} should repeat when held');
    }
    expect(found, moving);
  });

  test('every group has something under it', () {
    for (final group in CheatSheetGroup.values) {
      expect(cheatSheetEntries.where((e) => e.group == group), isNotEmpty,
          reason: group.title);
    }
  });

  testWidgets('the body draws the five headings in order', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CheatSheetBody())),
    );

    final tops = [
      for (final group in CheatSheetGroup.values)
        tester.getTopLeft(find.byKey(CheatSheetBody.groupKeyFor(group))).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Find'), findsOneWidget);
    expect(find.text('Tick the row for a bulk act'), findsOneWidget);
  });
}
