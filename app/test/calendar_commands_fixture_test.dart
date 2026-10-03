import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/calendar/command/command_heads.dart';
import 'package:flutter_test/flutter_test.dart';

/// The labelled commands the command head is fitted and held out on
/// (`tools/calendar_heads/fit.py`, `make calendar-heads`): well formed,
/// labelled with the head's ten wire words and never `unknown`, enough of
/// each, no command twice, and fiction — every address on one of the
/// fictional domains this repo uses. The repo is public.
void main() {
  const dir = 'test/fixtures/calendar_commands';
  const fictional = {
    'contoso.com',
    'fabrikam.com',
    'northwind.com',
    // The public-hygiene hook accepts only a short list of fictional
    // domains (contoso, fabrikam, northwind, example, acme…), so the
    // roster's other companies keep their NAMES and take these addresses.
    'example.com',
    'example.org',
    'example.net',
    'acme.example',
    'fabrikam.net',
  };
  final address = RegExp(r'[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+)');

  List<Map<String, Object?>> read(String name) => [
        for (final line in File('$dir/$name').readAsLinesSync())
          if (line.trim().isNotEmpty)
            (jsonDecode(line) as Map).cast<String, Object?>(),
      ];

  // The harder held-out set is small on purpose: five of each, phrasings
  // that share no template with train, reported and never fitted on.
  final files = {
    'train.jsonl': 35,
    'heldout.jsonl': 8,
    'heldout_hard.jsonl': 5,
  };

  for (final MapEntry(key: name, value: floor) in files.entries) {
    test('$name: every line is a labelled command, $floor or more of each',
        () {
      final rows = read(name);
      final counts = <String, int>{};
      for (final r in rows) {
        expect(r.keys.toSet(), {'text', 'action'}, reason: '$r');
        final text = r['text'];
        expect(text, isA<String>());
        expect((text as String).trim(), isNotEmpty);
        final action = r['action'];
        expect(CommandHeads.expectedOptions, contains(action),
            reason: '"$action" is not one of the head\'s ten wire words');
        counts.update(action as String, (n) => n + 1, ifAbsent: () => 1);
      }
      for (final a in CommandHeads.expectedOptions) {
        expect(counts[a] ?? 0, greaterThanOrEqualTo(floor),
            reason: '$name has ${counts[a] ?? 0} of $a');
      }
    });
  }

  test('no command appears twice, within a file or across the three', () {
    final seen = <String, String>{};
    for (final name in files.keys) {
      for (final r in read(name)) {
        final key = (r['text'] as String).trim().toLowerCase();
        expect(seen[key], isNull,
            reason: '"${r['text']}" is in $name and in ${seen[key]}');
        seen[key] = name;
      }
    }
  });

  test('no held-out or hard command is a train command with its names, '
      'addresses, days and times swapped', () {
    // A held-out line that is a train line with other slots filled in
    // measures recall of a template, not reading: after masking, no
    // held-out or hard line may equal a train line.
    final train = <String>{
      for (final r in read('train.jsonl')) masked(r['text'] as String),
    };
    for (final name in ['heldout.jsonl', 'heldout_hard.jsonl']) {
      for (final r in read(name)) {
        final m = masked(r['text'] as String);
        expect(train.contains(m), isFalse,
            reason: '"${r['text']}" in $name is a train template ($m)');
      }
    }
  });

  test('the mask folds slots, and only slots', () {
    expect(masked('Call off my 3:30 with Sam Fabrikam'),
        masked('call off my 11:30 with Priya'));
    expect(masked('am I free Friday at 1pm?'),
        masked('am I free tomorrow at 2?'));
    expect(masked('when did i last see jordan@example.org'),
        masked('when did I last see Priya Northwind'));
    expect(masked('invite Dana and Priya to a retro thursday at 2'),
        masked('invite kim@fabrikam.net to a retro next week'));
    expect(masked('move my 3pm with Dana'),
        isNot(masked('cancel my 3pm with Dana')));
  });

  test('every address is on a fictional domain', () {
    for (final name in files.keys) {
      for (final r in read(name)) {
        for (final m in address.allMatches(r['text'] as String)) {
          final domain = m.group(1)!.toLowerCase();
          expect(fictional.any((d) => domain == d || domain.endsWith('.$d')),
              isTrue,
              reason: '${m.group(0)} in $name');
        }
      }
    }
  });
}

/// The fixtures' roster — the fictional first names, and the fictional
/// company words used as surnames — and the calendar words a template's
/// slots hold.
const List<String> _roster = [
  'dana', 'sam', 'priya', 'lee', 'morgan', 'jordan', 'alex', 'kim', //
  'contoso', 'fabrikam', 'northwind', 'tailspin', 'adatum', 'litware',
  'proseware', 'wingtip',
];
const List<String> _days = [
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', //
  'sunday', 'mon', 'tue', 'tues', 'wed', 'thu', 'thur', 'thurs', 'fri',
  'sat', 'sun',
];
const List<String> _months = [
  'january', 'february', 'march', 'april', 'may', 'june', 'july', //
  'august', 'september', 'october', 'november', 'december', 'jan', 'feb',
  'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
];

/// A command as a template: lowercased; every address and roster name one
/// `<name>` (a run of them joined by "and" one too); every weekday, month,
/// clock time, number, relative day and part of the day one `<when>` (a run
/// of them one too); punctuation dropped.
String masked(String text) {
  var t = text.toLowerCase();
  t = t.replaceAll(RegExp(r'[a-z0-9._%+-]+@[a-z0-9.-]+'), '<name>');
  t = t.replaceAll(RegExp("\\b(${_roster.join('|')})('s)?\\b"), '<name>');
  t = t.replaceAll(RegExp("\\b(${_days.join('|')})s?('s)?\\b"), '<when>');
  t = t.replaceAll(RegExp("\\b(${_months.join('|')})\\b"), '<when>');
  t = t.replaceAll(RegExp(r'\d+(:\d+)?\s*(am|pm)\b'), '<when>');
  t = t.replaceAll(RegExp(r'\d+(:\d+)?'), '<when>');
  t = t.replaceAll(
      RegExp(r'\b(today|tomorrow|tmrw|tonight|yesterday|noon|midnight|'
          r'morning|afternoon|evening)\b'),
      '<when>');
  t = t.replaceAll(RegExp(r'\b(this|next|last)\s+(week|month)\b'), '<when>');
  t = t.replaceAll(RegExp(r'[?!.,;"]'), ' ');
  t = t.replaceAll(RegExp(r'<name>(\s*(and|&|or)?\s*<name>)+'), '<name>');
  t = t.replaceAll(RegExp(r'<when>(\s*(at|on)?\s*<when>)+'), '<when>');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}
