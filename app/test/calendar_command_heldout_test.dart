import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/calendar/command/command_heads.dart';
import 'package:bond_inbox/services/calendar/command/command_lexicon.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// The LEXICON's held-out accuracy on the command set, the Dart half of
/// `make calendar-heads`: `tools/calendar_heads/fit.py` prints the head's
/// number, this prints the one it is compared with and the ADOPTION LINE
/// (plan §1.1: the head ships only at ≥ 0.90 AND ≥ the lexicon + 0.05) —
/// `adoption: go`, or `adoption: no-go (…)` naming the bar it missed. The
/// owner reads it before `make calendar-heads-adopt` copies the head into the
/// app. The hard set's two numbers are printed beside it and decide nothing.
///
/// The fitted head is read from `--dart-define=CALHEADS_JSON=<path>` (the
/// Makefile passes `CALHEADS_OUT`, under tmp/) when that file exists, else
/// from the shipped asset; with neither there is no head line and no verdict.
///
/// Prints only, and asserts SHAPE only — never a threshold (the live-bench
/// rule in docs/model-bakeoff.md): a lexicon change moves this number, and
/// that is a finding for the ledger, not a failure; the verdict is printed,
/// never asserted. Fast and serverless, so it also runs in the gate. Counts,
/// accuracies and enum words only.
///
/// The name is `calendar command heldout` because `--plain-name` is a
/// substring filter and must not catch another target's test.
void main() {
  test('calendar command heldout', () {
    /// The lexicon's accuracy on one held-out file, printed with its
    /// per-action recall; the row count and the accuracy come back for the
    /// shape checks.
    (int, double) report(String file, String name) {
      final rows = [
        for (final line in File('test/fixtures/calendar_commands/$file')
            .readAsLinesSync())
          if (line.trim().isNotEmpty)
            (jsonDecode(line) as Map).cast<String, Object?>(),
      ];
      final total = <String, int>{};
      final right = <String, int>{};
      var correct = 0;
      for (final r in rows) {
        final gold = r['action'] as String;
        final said = classifyByLexicon(r['text'] as String).action.wire;
        total.update(gold, (n) => n + 1, ifAbsent: () => 1);
        if (said == gold) {
          correct++;
          right.update(gold, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      final n = rows.length;
      final accuracy = n == 0 ? 0.0 : correct / n;
      // ignore: avoid_print
      print('lexicon $name accuracy = ${accuracy.toStringAsFixed(3)} (n=$n)');
      for (final a in CommandAction.values) {
        final t = total[a.wire];
        if (t == null) continue;
        final k = right[a.wire] ?? 0;
        // ignore: avoid_print
        print('  ${a.wire.padRight(11)} ${(k / t).toStringAsFixed(3)} ($k/$t)');
      }
      return (n, accuracy);
    }

    final (n, accuracy) = report('heldout.jsonl', 'heldout');
    // The harder set: indirect phrasings and typos, reported beside it.
    final (hardN, hardAccuracy) = report('heldout_hard.jsonl', 'heldout_hard');

    // The fitted head beside it: the fit's own output when the Makefile
    // named one and it is there, else the shipped asset.
    const fitted = String.fromEnvironment('CALHEADS_JSON');
    final fromFit = fitted.isNotEmpty && File(fitted).existsSync();
    final file = File(fromFit ? fitted : commandHeadsAsset);
    if (file.existsSync()) {
      // ignore: avoid_print
      print('head file: ${fromFit ? 'the fit (CALHEADS_JSON)' : 'the '
          'shipped asset'}');
      try {
        final text = file.readAsStringSync();
        final head = CommandHeads.load(text);
        // ignore: avoid_print
        print('head heldout accuracy = '
            '${head.heldoutAcc.toStringAsFixed(3)} (n=${head.nHeldout}, '
            'from the fit; encoder ${head.encoderModel})');
        // The harder set's number, when the fit was given it: read off the
        // file's own record, which the loader leaves to its readers.
        final record = (jsonDecode(text) as Map)['fitted'];
        final hard = record is Map ? record['heldout_hard_acc'] : null;
        final hardHead = hard is num ? hard.toStringAsFixed(3) : 'n/a';
        // ignore: avoid_print
        print('hard set: head $hardHead, lexicon '
            '${hardAccuracy.toStringAsFixed(3)} (reported; decides nothing)');
        // ignore: avoid_print
        print(adoptionLine(head.heldoutAcc, accuracy));
      } on CommandHeadsRefused catch (e) {
        // ignore: avoid_print
        print('head: the file was refused — ${e.reason}');
      }
    } else {
      // ignore: avoid_print
      print('head: none fitted, so no adoption line');
    }

    expect(n, greaterThan(0));
    expect(accuracy, inInclusiveRange(0.0, 1.0));
    expect(hardN, greaterThan(0));
    expect(hardAccuracy, inInclusiveRange(0.0, 1.0));
  });

  test('the adoption line names the bar a head missed', () {
    expect(adoptionLine(0.95, 0.80), 'adoption: go');
    expect(adoptionLine(0.95, 0.90), 'adoption: go',
        reason: 'exactly the lexicon + 0.05 clears it');
    expect(adoptionLine(0.89, 0.50), 'adoption: no-go (head 0.89 < 0.90)');
    expect(adoptionLine(0.92, 0.90),
        'adoption: no-go (head 0.92 < lexicon 0.90 + 0.05)');
  });
}

/// The adoption verdict for a head at [head] held-out accuracy against the
/// lexicon's [lexicon] (plan §1.1): go at ≥ 0.90 AND ≥ the lexicon + 0.05,
/// otherwise no-go naming the first bar missed. A printed verdict — the
/// owner's to act on — never an assertion on a measured number.
String adoptionLine(double head, double lexicon) {
  String f(double v) => v.toStringAsFixed(2);
  if (head < 0.90) return 'adoption: no-go (head ${f(head)} < 0.90)';
  // Compared at a thousandth, so a head exactly 0.05 over is not a no-go by
  // a floating-point hair.
  if (((head - lexicon) * 1000).round() < 50) {
    return 'adoption: no-go (head ${f(head)} < lexicon ${f(lexicon)} + 0.05)';
  }
  return 'adoption: go';
}
