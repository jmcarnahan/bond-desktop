import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'triage_intents.dart';

/// The five headings the sheet is read under, in the order it draws them.
enum CheatSheetGroup {
  move('Move'),
  triage('Triage'),
  reply('Reply'),
  navigate('Navigate'),
  find('Find');

  const CheatSheetGroup(this.title);

  final String title;
}

/// One line of the sheet: the keys, and what they do.
///
/// [keys] is a list rather than one string because two keys doing one thing
/// (`j` and `↓`) are two keys to find, and the honesty test looks each one up
/// by itself. [intents] names what the line is ABOUT, where there is an
/// intent: it is how the test checks that every binding in the inbox's key
/// map has a line here, and that no line teaches an intent the map does not
/// bind. A line about a key some other widget owns — ⌘K, the box's ⌘Enter —
/// or about a rule rather than a key leaves it empty.
class CheatSheetEntry {
  final CheatSheetGroup group;
  final List<String> keys;
  final String description;
  final List<Type> intents;

  const CheatSheetEntry(
    this.group,
    this.keys,
    this.description, {
    this.intents = const [],
  });
}

/// Every key the sheet teaches, as one table.
///
/// One const table rather than words written into the widget, so that
/// `cheat_sheet_test` can hold it against the key map and the palette: a sheet
/// that drifted from the keys would be the one place in the app that teaches a
/// shortcut which does nothing.
const List<CheatSheetEntry> cheatSheetEntries = [
  CheatSheetEntry(
    CheatSheetGroup.move,
    ['j', '↓'],
    'The row under this one',
    intents: [NextThreadIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.move,
    ['k', '↑'],
    'The row above',
    intents: [PreviousThreadIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.move,
    ['Esc'],
    'Back to the list; from inside a panel, closes it',
    intents: [DismissIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['e'],
    'Mark done, then move to the next row',
    intents: [DismissThreadIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['⇧E'],
    'Mark done with a label',
    intents: [DismissWithLabelIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['l'],
    'Label, keeping the thread',
    intents: [LabelThreadIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['s'],
    'Later, for this thread',
    intents: [LaterThreadIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['m'],
    'Drop the sender',
    intents: [DropSenderIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['x'],
    'Tick the row for a bulk act',
    intents: [ToggleCheckedIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['e', 's', 'm', 'l', '⇧E'],
    'While rows are ticked, these act on the selection',
  ),
  CheatSheetEntry(
    CheatSheetGroup.triage,
    ['z', '⌘Z'],
    'Undo the last action',
    intents: [UndoLastIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.reply,
    ['r'],
    'Quick reply under the row, without opening it',
    intents: [QuickReplyIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.reply,
    ['⌘Enter'],
    'Send from the quick reply box',
  ),
  CheatSheetEntry(
    CheatSheetGroup.navigate,
    [']'],
    'The next place the open thread names you',
    intents: [NextMentionIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.navigate,
    ['['],
    'The one before it',
    intents: [PreviousMentionIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.navigate,
    ['?'],
    'This sheet',
    intents: [ShowCheatSheetIntent],
  ),
  CheatSheetEntry(
    CheatSheetGroup.find,
    ['⌘K'],
    'Put the cursor in Find',
  ),
  CheatSheetEntry(
    CheatSheetGroup.find,
    ['>'],
    'Typed first in Find, turns it into the command palette',
  ),
];

/// The sheet's body, under the side panel's own header.
///
/// A list to read and nothing to press: every line is a key, and the reader
/// learns it by pressing the key rather than by clicking the line.
class CheatSheetBody extends StatelessWidget {
  const CheatSheetBody({super.key});

  /// One heading per group, for a test that reads the sheet by its words.
  static Key groupKeyFor(CheatSheetGroup group) =>
      ValueKey('cheat-sheet-${group.name}');

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(BondSpacing.s16),
      children: [
        for (final group in CheatSheetGroup.values) ...[
          Padding(
            key: groupKeyFor(group),
            padding: const EdgeInsets.only(
              top: BondSpacing.s8,
              bottom: BondSpacing.s4,
            ),
            child: Text(group.title, style: BondType.label),
          ),
          for (final entry in cheatSheetEntries)
            if (entry.group == group) _line(entry),
        ],
      ],
    );
  }

  Widget _line(CheatSheetEntry entry) => Padding(
        padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A fixed column, so the descriptions line up down the sheet and
            // the eye can run down the keys alone.
            SizedBox(
              width: 120,
              child: Wrap(
                spacing: BondSpacing.s4,
                runSpacing: BondSpacing.s4,
                children: [for (final key in entry.keys) _keyCap(key)],
              ),
            ),
            const SizedBox(width: BondSpacing.s8),
            Expanded(child: Text(entry.description, style: BondType.small)),
          ],
        ),
      );

  Widget _keyCap(String key) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: BondColors.faintGround,
          borderRadius: BondRadii.smAll,
          border: Border.all(color: BondColors.border),
        ),
        child: Text(key, style: BondType.mono),
      );
}
