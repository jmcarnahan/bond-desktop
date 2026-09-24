import 'package:bond_inbox/widgets/triage_intents.dart';
import 'package:flutter/widgets.dart' show Intent;
import 'package:flutter_test/flutter_test.dart';

/// The row arithmetic behind auto-advance, read as a table.
///
/// `neighbourRow` is what `j`/`k` ride: it STOPS at the edge, because a cursor
/// that wraps from the last row to the first is a cursor the reader has lost.
/// `nextRowAfter`/`previousRowBefore` are what a DISMISS rides: the row going
/// away takes its place with it, so the edge falls back inwards rather than
/// leaving the reader on an empty pane.
void main() {
  const rows = ['a', 'b', 'c'];

  group('neighbourRow', () {
    test('a middle row has a neighbour each way', () {
      expect(neighbourRow(rows, 'b', forward: true), 'c');
      expect(neighbourRow(rows, 'b', forward: false), 'a');
    });

    test('the first and last rows stop at their edge', () {
      expect(neighbourRow(rows, 'a', forward: false), isNull);
      expect(neighbourRow(rows, 'c', forward: true), isNull);
    });

    test('standing on no row starts at the end it walks from', () {
      expect(neighbourRow(rows, null, forward: true), 'a');
      expect(neighbourRow(rows, null, forward: false), 'c');
      expect(neighbourRow(rows, 'gone', forward: true), 'a');
      expect(neighbourRow(rows, 'gone', forward: false), 'c');
    });

    test('one row has no neighbour and an empty list has nothing', () {
      expect(neighbourRow(const ['only'], 'only', forward: true), isNull);
      expect(neighbourRow(const ['only'], 'only', forward: false), isNull);
      expect(neighbourRow(const [], null, forward: true), isNull);
      expect(neighbourRow(const [], 'a', forward: false), isNull);
    });
  });

  group('nextRowAfter', () {
    test('a middle row hands the reader the one under it', () {
      expect(nextRowAfter(rows, 'b'), 'c');
    });

    test('the first row hands the reader the one under it too', () {
      expect(nextRowAfter(rows, 'a'), 'b');
    });

    test('the last row falls back to the one above, not to nothing', () {
      expect(nextRowAfter(rows, 'c'), 'b');
    });

    test('no current row lands on the first', () {
      expect(nextRowAfter(rows, null), 'a');
      expect(nextRowAfter(rows, 'gone'), 'a');
    });

    test('a list of only the row going away leaves nothing to stand on', () {
      expect(nextRowAfter(const ['only'], 'only'), isNull);
    });

    test('an empty list is null rather than a throw', () {
      expect(nextRowAfter(const [], 'a'), isNull);
      expect(nextRowAfter(const [], null), isNull);
    });
  });

  group('previousRowBefore', () {
    test('a middle row hands the reader the one above it', () {
      expect(previousRowBefore(rows, 'b'), 'a');
    });

    test('the last row hands the reader the one above it too', () {
      expect(previousRowBefore(rows, 'c'), 'b');
    });

    test('the first row falls back to the one under it', () {
      expect(previousRowBefore(rows, 'a'), 'b');
    });

    test('no current row lands on the last', () {
      expect(previousRowBefore(rows, null), 'c');
      expect(previousRowBefore(rows, 'gone'), 'c');
    });

    test('a single row and an empty list have nowhere to go', () {
      expect(previousRowBefore(const ['only'], 'only'), isNull);
      expect(previousRowBefore(const [], null), isNull);
    });
  });

  test('every triage intent is const, so a key map can hold one instance', () {
    const intents = <Intent>[
      DismissThreadIntent(),
      DismissWithLabelIntent(),
      LabelThreadIntent(),
      LaterThreadIntent(),
      DropSenderIntent(),
      NextThreadIntent(),
      PreviousThreadIntent(),
      FocusReplyIntent(),
      UndoLastIntent(),
    ];
    expect(intents.map((i) => i.runtimeType).toSet(), hasLength(9));
  });
}
