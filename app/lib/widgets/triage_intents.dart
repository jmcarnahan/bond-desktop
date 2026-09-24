import 'package:flutter/widgets.dart';

/// One intent layer so keys, buttons and (later) a palette share one code path.
///
/// Every triage gesture — the keys over the list and detail, the buttons on a
/// row, the items in the thread's own menu — names an [Intent] here and lets
/// the inbox's single `Actions` map decide what it does. Two copies of "dismiss
/// this thread" is how a key and a button come to dismiss it differently, and
/// how the command palette (12h) would end up with a third.
///
/// The intents carry NO payload: every one of them means "do this to the thread
/// the reader is on", and the screen is the layer that knows which thread that
/// is. An intent holding a conversation key would make the palette and the
/// keyboard pass one, and both of them would be guessing.
///
/// The row arithmetic below lives here rather than on the screen because it is
/// the part worth pinning: auto-advance is the whole reason keyboard triage
/// feels fast, and "which row do I land on" is a question with edges.

/// Clear the thread from the inbox (`done`), then advance.
class DismissThreadIntent extends Intent {
  const DismissThreadIntent();
}

/// Ask for the label picker, and dismiss the thread when a label is applied.
class DismissWithLabelIntent extends Intent {
  const DismissWithLabelIntent();
}

/// Ask for the label picker, keeping the thread where it is.
class LabelThreadIntent extends Intent {
  const LabelThreadIntent();
}

/// Defer the thread — the per-thread Later, not the sender's.
class LaterThreadIntent extends Intent {
  const LaterThreadIntent();
}

/// Stop hearing from whoever sent the newest inbound message.
///
/// The ninth intent, beside the eight the plan names: `m` is in the key map and
/// a key with no intent behind it would need a second `Shortcuts` map, which is
/// the one thing this file exists to prevent.
class DropSenderIntent extends Intent {
  const DropSenderIntent();
}

/// The row under this one, with the detail pane following.
class NextThreadIntent extends Intent {
  const NextThreadIntent();
}

/// The row above this one, with the detail pane following.
class PreviousThreadIntent extends Intent {
  const PreviousThreadIntent();
}

/// Put the cursor in the reply box.
class FocusReplyIntent extends Intent {
  const FocusReplyIntent();
}

/// Take back the last thing an undo toast offered to take back.
class UndoLastIntent extends Intent {
  const UndoLastIntent();
}

/// The row [currentId]'s neighbour in the drawn order, or null at the edge.
///
/// [rowIds] is the list AS RENDERED — filtered, sorted, in the order the reader
/// is looking at — because that is the only order in which "the next one" means
/// anything to them.
///
/// A null or absent [currentId] means the reader is not standing on any row in
/// this list, so the walk starts at the end it is walking from: the first row
/// going forwards, the last row coming back.
String? neighbourRow(
  List<String> rowIds,
  String? currentId, {
  required bool forward,
}) {
  if (rowIds.isEmpty) return null;
  final index = currentId == null ? -1 : rowIds.indexOf(currentId);
  if (index < 0) return forward ? rowIds.first : rowIds.last;
  final next = forward ? index + 1 : index - 1;
  if (next < 0 || next >= rowIds.length) return null;
  return rowIds[next];
}

/// Where the reader lands when the row they are on LEAVES the drawn list.
///
/// The row now occupying its place — the one under it — else the new last one,
/// because a dismissed bottom row leaves the reader at the bottom rather than
/// on an empty pane. Null only when nothing would be left to stand on: an empty
/// list, or a list of exactly the row that is going away.
///
/// Computed BEFORE the action that mutates the list, which is why it takes the
/// pre-action order: afterwards the row is already gone and its place with it.
String? nextRowAfter(List<String> rowIds, String? currentId) =>
    neighbourRow(rowIds, currentId, forward: true) ??
    neighbourRow(rowIds, currentId, forward: false);

/// [nextRowAfter] run backwards: the row above, else the new first one.
String? previousRowBefore(List<String> rowIds, String? currentId) =>
    neighbourRow(rowIds, currentId, forward: false) ??
    neighbourRow(rowIds, currentId, forward: true);
