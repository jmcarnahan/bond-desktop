import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'triage_intents.dart';

/// The quick switcher, in the list column's own header.
///
/// Slack opens a palette over the app for this; the house rule is that nothing
/// opens over anything, so it is a field in the column it filters. That turns
/// out to be the better shape anyway: the rows narrow under the reader's eyes
/// as they type, so "the top match" is a thing they can SEE rather than a
/// promise the app makes about a list it is hiding.
///
/// Escape is bound HERE rather than on the screen, on `HomeSearchField`'s
/// precedent: it only fires while the box holds focus, which is where the hand
/// that just typed already is, and the only place the key has an obvious
/// subject. ⌘K, which has to work from anywhere, is bound on the screen.
///
/// The text still belongs to the controller its owner holds — the box is a view
/// of it, and it can be rebuilt on every keystroke without losing a half-typed
/// needle. The one thing this widget owns is WHICH label suggestion is
/// highlighted, which is a property of the strip and of nothing outside it.
///
/// A needle that starts with `>` is a COMMAND rather than a needle, and the
/// strip under the box becomes the palette of entry 12h. Same box, same strip,
/// same arrows and same Enter: a palette is a second vocabulary for the one
/// type-ahead this app has, not a second surface — and it names the key beside
/// each command, so the way to stop needing it is written on it.
class FindField extends StatefulWidget {
  /// The typed text, owned by the screen — the box is a view of it.
  final TextEditingController controller;

  /// Owned by the screen too, because ⌘K has to be able to reach it from
  /// outside this widget's build.
  final FocusNode focusNode;

  /// Fired per keystroke. Find runs live, unlike search: it costs a list
  /// comprehension over rows already in memory, not a round trip.
  ///
  /// Also fired by a completed `label:` term, because a completion is a change
  /// to the needle and the column must narrow on it like any other.
  final ValueChanged<String> onChanged;

  /// Enter — open the first row still visible. NOT fired while a label
  /// suggestion is showing: there, Enter takes the suggestion.
  final ValueChanged<String> onSubmit;

  /// Escape, and the ×.
  final VoidCallback onClear;

  /// The owner's label names, for the strip that completes a `label:` term.
  ///
  /// Empty — the default — leaves the feature dormant: no strip, no bindings,
  /// and Enter submits as it always did. A host that has not read the
  /// vocabulary yet passes nothing and gets the box it had before labels
  /// existed.
  final List<String> labelNames;

  /// A command the reader picked out of the palette, handed up for the layer
  /// that can invoke it.
  ///
  /// Null — the default — leaves the palette dormant: `>` is an ordinary
  /// character, the strip never appears, and a host that knows
  /// nothing about intents gets the box it had before. Handed up rather than
  /// invoked here because the inbox's `Actions` map is mounted over the LIST and
  /// the detail, deliberately not over this rail, so an `Actions.invoke` from
  /// this context would find nothing.
  ///
  /// Called one frame after the box has let the cursor go, because the triage
  /// actions are gated on "the cursor is not in a box" and the focus manager
  /// applies an unfocus on a later microtask — a command invoked in the same
  /// frame would be refused by the gate, silently.
  final ValueChanged<Intent>? onCommand;

  /// What every finder in the suite reaches this box by.
  static const Key fieldKey = ValueKey('find-field');

  /// The strip, for a test that wants to assert it is absent.
  static const Key suggestionsKey = ValueKey('find-label-suggestions');

  /// The same strip carrying commands instead of label names.
  static const Key commandsKey = ValueKey('find-commands');

  /// One suggestion, by the name it offers.
  static ValueKey<String> suggestionKeyFor(String name) =>
      ValueKey('find-label-suggestion-$name');

  /// One command, by the words on it.
  static ValueKey<String> commandKeyFor(String label) =>
      ValueKey('find-command-$label');

  const FindField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmit,
    required this.onClear,
    this.labelNames = const [],
    this.onCommand,
  });

  @override
  State<FindField> createState() => _FindFieldState();
}

class _FindFieldState extends State<FindField> {
  /// Which suggestion the arrows have walked to. Never clamped when it is
  /// STORED, only when it is read: the strip changes shape on every keystroke,
  /// and an index that was out of range for one list is simply the last entry
  /// of the next rather than a state that has to be repaired.
  int _highlight = 0;

  @override
  Widget build(BuildContext context) {
    // The whole box under the controller, not just the ×: the strip is built
    // from the typed text, and a host that rebuilt only on its own setState
    // would leave a completed term showing its old suggestions.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        // One strip, two vocabularies, and the palette wins: a needle that
        // starts with `>` is a command, so nothing in it is a label term.
        final commands = _commandsFor(value.text);
        final suggestions = commands.isEmpty
            ? labelSuggestionsFor(value.text, widget.labelNames)
            : const <String>[];
        final length = commands.isEmpty ? suggestions.length : commands.length;
        final highlight = length == 0 ? 0 : _highlight.clamp(0, length - 1);
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): widget.onClear,
            // Bound only while there is a strip to walk. A field that swallowed
            // the arrow keys the rest of the time would cost the reader the one
            // way to move the caret in a single-line box.
            if (length > 0) ...{
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  setState(() =>
                      _highlight = highlight + 1 >= length ? 0 : highlight + 1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  setState(() =>
                      _highlight = highlight == 0 ? length - 1 : highlight - 1),
            },
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(value),
              if (commands.isNotEmpty)
                _commandStrip(commands, highlight)
              else if (suggestions.isNotEmpty)
                _strip(suggestions, highlight),
            ],
          ),
        );
      },
    );
  }

  Widget _field(TextEditingValue value) => TextField(
        key: FindField.fieldKey,
        controller: widget.controller,
        focusNode: widget.focusNode,
        style: BondType.small.copyWith(color: BondColors.onDarkPrimary),
        textInputAction: TextInputAction.search,
        onChanged: _onChanged,
        onSubmitted: _onSubmitted,
        cursorColor: BondColors.onDarkPrimary,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: BondColors.onDarkFaint,
          border: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BondRadii.smAll,
            borderSide: const BorderSide(color: BondColors.onDarkBorder),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s8,
            vertical: BondSpacing.s8,
          ),
          // The shortcut is in the hint because there is nowhere else to put
          // it: a rail this narrow has no room for a legend, and a binding
          // nobody is told about is a binding nobody uses.
          hintText: 'Find… ⌘K',
          hintStyle: BondType.small.copyWith(color: BondColors.onDarkMuted),
          prefixIcon: const Icon(
            Icons.search,
            size: 16,
            color: BondColors.onDarkMuted,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
          // Only once there is something to clear. An × over an empty box is a
          // control that does nothing, sitting in the width the hint needs.
          suffixIcon: value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  color: BondColors.onDarkMuted,
                  splashRadius: 12,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Clear',
                  onPressed: widget.onClear,
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
        ),
      );

  /// The names that finish the term being typed, inline under the box.
  ///
  /// A strip and not a popup, the same house rule the field itself answers to:
  /// the rail is a column and this is one more row of it, so nothing opens over
  /// the list the reader is narrowing.
  Widget _strip(List<String> suggestions, int highlight) => Padding(
        key: FindField.suggestionsKey,
        padding: const EdgeInsets.only(top: BondSpacing.s4),
        child: Wrap(
          spacing: BondSpacing.s4,
          runSpacing: BondSpacing.s4,
          children: [
            for (var i = 0; i < suggestions.length; i++)
              _suggestion(suggestions[i], i == highlight),
          ],
        ),
      );

  Widget _suggestion(String name, bool highlighted) => _pill(
        key: FindField.suggestionKeyFor(name),
        text: name,
        highlighted: highlighted,
        onTap: () => _complete(name),
      );

  /// The palette: the same strip, one pill per command, each naming the key
  /// that does the same thing from the list.
  Widget _commandStrip(List<FindCommand> commands, int highlight) => Padding(
        key: FindField.commandsKey,
        padding: const EdgeInsets.only(top: BondSpacing.s4),
        child: Wrap(
          spacing: BondSpacing.s4,
          runSpacing: BondSpacing.s4,
          children: [
            for (var i = 0; i < commands.length; i++)
              _pill(
                key: FindField.commandKeyFor(commands[i].label),
                text: commands[i].label,
                hint: commands[i].keyHint,
                highlighted: i == highlight,
                onTap: () => _run(commands[i]),
              ),
          ],
        ),
      );

  Widget _pill({
    required Key key,
    required String text,
    required bool highlighted,
    required VoidCallback onTap,
    String? hint,
  }) =>
      Material(
        color: highlighted ? BondColors.onDarkTint : BondColors.onDarkFaint,
        borderRadius: BondRadii.fullAll,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BondRadii.fullAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Flexible, because the vocabulary is not this file's to
                // measure: the owner writes the label names and the rail is
                // 236pt, so the longest entry ellipsizes rather than painting
                // over the pill beside it.
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BondType.caption.copyWith(
                      color: highlighted
                          ? BondColors.onDarkPrimary
                          : BondColors.onDarkSecondary,
                      fontWeight:
                          highlighted ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(width: BondSpacing.s4),
                  // Dimmer than the words it follows: the key is what the pill
                  // is teaching, not what it is offering.
                  Text(
                    hint,
                    style: BondType.caption.copyWith(
                      color: BondColors.onDarkMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  /// A keystroke puts the highlight back on the first suggestion: the reader has
  /// just changed what they are asking for, and the entry they had walked to is
  /// about to be a different name.
  void _onChanged(String text) {
    if (_highlight != 0) setState(() => _highlight = 0);
    widget.onChanged(text);
  }

  /// Enter. A strip on screen means the reader is still typing a term, so Enter
  /// finishes the term rather than opening a row — the same key doing the
  /// nearer of two jobs, which is how every type-ahead in the app behaves.
  void _onSubmitted(String text) {
    final commands = _commandsFor(text);
    if (commands.isNotEmpty) {
      _run(commands[_highlight.clamp(0, commands.length - 1)]);
      return;
    }
    final suggestions = labelSuggestionsFor(text, widget.labelNames);
    if (suggestions.isEmpty) {
      widget.onSubmit(text);
      return;
    }
    _complete(suggestions[_highlight.clamp(0, suggestions.length - 1)]);
  }

  /// The commands worth offering for what has been typed, or none at all while
  /// no host is listening for one.
  List<FindCommand> _commandsFor(String text) =>
      widget.onCommand == null ? const [] : commandsFor(text);

  /// Picking a command: the box gives up the needle and the cursor, and the act
  /// happens a frame later, on the list.
  ///
  /// [FindField.onCommand] says why the wait is here rather than at the call
  /// site — the gate on the triage actions reads the focus manager, which has
  /// not caught up with this unfocus yet.
  void _run(FindCommand command) {
    final onCommand = widget.onCommand;
    if (onCommand == null) return;
    // Only when the box actually holds the cursor. A pill taken with the mouse
    // has already moved the focus to the pill, and unfocusing a node that is
    // not focused walks up and re-points its whole scope — which is a change to
    // where the cursor goes next that nobody asked for.
    if (widget.focusNode.hasFocus) widget.focusNode.unfocus();
    widget.onClear();
    setState(() => _highlight = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      onCommand(command.intent);
    });
  }

  /// Writes the chosen name into the term being typed and hands the new needle
  /// to the host. The caret lands after the trailing space, ready for the next
  /// term.
  void _complete(String name) {
    final completed = completeLabelFacet(widget.controller.text, name);
    widget.controller.value = TextEditingValue(
      text: completed,
      selection: TextSelection.collapsed(offset: completed.length),
    );
    setState(() => _highlight = 0);
    widget.onChanged(completed);
  }
}

/// Where the term the caret is in begins.
///
/// The run after the last whitespace that was not inside quotes — so
/// `label:"vendor out` is one unfinished term and not two. Text that ends in a
/// space has no term in progress, which is what stops the strip reappearing
/// under a term the reader has already finished.
int _lastTermStart(String text) {
  var start = 0;
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')) {
      start = i + 1;
    }
  }
  return start;
}

/// The two spellings a label term takes. `-label:` first, because `label:` is
/// its own tail.
const List<String> _labelPrefixes = ['-label:', 'label:'];

/// The half-typed label name the caret is inside, or null when the caret is not
/// in a label term at all.
///
/// An EMPTY string is a real answer and means the reader has typed `label:` and
/// nothing after it — which is exactly when the whole vocabulary is worth
/// offering. Null is the answer everywhere else.
String? labelFacetPrefixOf(String text) {
  final term = text.substring(_lastTermStart(text)).toLowerCase();
  for (final prefix in _labelPrefixes) {
    if (term.startsWith(prefix)) {
      final value = term.substring(prefix.length);
      // An opening quote is a grouping gesture, not part of the name.
      return value.startsWith('"') ? value.substring(1) : value;
    }
  }
  return null;
}

/// The label names worth offering for what has been typed, most useful first.
///
/// Names that START with what was typed lead, because that is what the reader
/// is spelling; the ones that merely contain it follow, because a vocabulary
/// the owner wrote is full of second words (`waiting on legal`) and a reader
/// typing `legal` means that one. Capped at [max]: this is a strip in a rail
/// 236pt wide, not a list.
///
/// Empty whenever the feature is dormant — no names, or a caret that is not in
/// a label term.
List<String> labelSuggestionsFor(
  String text,
  List<String> names, {
  int max = 6,
}) {
  if (names.isEmpty) return const [];
  final typed = labelFacetPrefixOf(text);
  if (typed == null) return const [];
  final leading = <String>[];
  final rest = <String>[];
  for (final name in names) {
    final lower = name.toLowerCase();
    if (lower.startsWith(typed)) {
      leading.add(name);
    } else if (typed.isNotEmpty && lower.contains(typed)) {
      rest.add(name);
    }
  }
  final out = [...leading, ...rest];
  return out.length <= max ? out : out.sublist(0, max);
}

/// The needle once a suggestion has been taken: the term being typed, finished
/// with [name], and a space after it.
///
/// A name with whitespace in it comes back quoted, because that is the only
/// spelling the Find parser reads as one value — completing `vendor outreach`
/// bare would hand the parser a label and a stray word.
///
/// Returns [text] untouched when the caret is not in a label term, so a caller
/// that asks at the wrong moment changes nothing.
String completeLabelFacet(String text, String name) {
  if (labelFacetPrefixOf(text) == null) return text;
  final start = _lastTermStart(text);
  final term = text.substring(start).toLowerCase();
  final prefix = _labelPrefixes.firstWhere(term.startsWith);
  final value = name.contains(RegExp(r'\s')) ? '"$name"' : name;
  return '${text.substring(0, start)}$prefix$value ';
}

/// One entry in the palette: words a reader can search for, the key that does
/// the same thing, and the intent both of them mean.
///
/// The intent is the point. A palette that called a handler would be the third
/// copy of "dismiss this thread" that `triage_intents.dart` exists to prevent,
/// and it would be the copy that drifted — nobody presses it often enough to
/// notice.
class FindCommand {
  /// What the pill says. Also what the needle is matched against, so the words
  /// have to be the words a reader would reach for rather than a code name.
  final String label;

  /// The key that does this from the list, drawn beside the words. Null for a
  /// command no key reaches.
  final String? keyHint;

  final Intent intent;

  const FindCommand(this.label, this.intent, {this.keyHint});
}

/// The prefix that turns the Find box into the palette.
///
/// `>` rather than a second binding, because ⌘K already puts the cursor here
/// and a reader who has to remember TWO ways in has one too many. Nothing else
/// in the Find grammar begins with it, so no needle loses its meaning.
const String commandPrefix = '>';

/// Every command the palette offers, in the order it offers them.
///
/// Acts only. `j`/`k` are in the key map and not here: typing five characters
/// to move down one row is slower than the thing it replaces, and a palette
/// full of entries nobody would use is a palette nobody reads. Entry 12h also
/// asks for "Open attachment" and "Reply with template…", which are left out
/// because neither has an intent behind it yet — templates are deferred by
/// design, and an entry that did nothing would be worse than an absent one.
///
/// Every [keyHint] here is a key the inbox's own map binds today. A hint for a
/// key some later round intends to bind would be this file teaching a
/// shortcut that does nothing.
const List<FindCommand> findCommands = [
  FindCommand('Dismiss', DismissThreadIntent(), keyHint: 'e'),
  FindCommand('Dismiss with label…', DismissWithLabelIntent(), keyHint: '⇧E'),
  FindCommand('Label…', LabelThreadIntent(), keyHint: 'l'),
  FindCommand('Later', LaterThreadIntent(), keyHint: 's'),
  FindCommand('Drop sender', DropSenderIntent(), keyHint: 'm'),
  FindCommand('Next mention', NextMentionIntent(), keyHint: ']'),
  FindCommand('Previous mention', PreviousMentionIntent(), keyHint: '['),
  FindCommand('Undo', UndoLastIntent(), keyHint: 'z'),
];

/// Whether what has been typed is a command rather than a needle.
///
/// The host reads this to leave its rows alone while the palette is open: `>dis`
/// matches no thread, and a column that emptied itself under a reader choosing
/// a command would take away the row they are choosing it FOR.
bool isCommandNeedle(String text) => text.trimLeft().startsWith(commandPrefix);

/// The commands worth offering for what has been typed, most useful first.
///
/// `>` alone is the whole palette. [max] is the vocabulary's own length rather
/// than the label strip's six, because this list is FIXED and short: a palette
/// that hid two of its eight entries would be one a reader has to already know,
/// which is the opposite of what entry 12h asked for. The pills wrap over three
/// rows of a 236pt rail, under a box the reader opened on purpose.
///
/// After the `>`, the words narrow the list the way the label strip narrows:
/// entries that START with what was typed lead, and the ones that merely
/// contain it follow, so `>l` offers Label before Later and `>sender` still
/// finds Drop sender.
///
/// Empty for text that is not a command at all, which is what keeps the strip
/// out of an ordinary needle's way.
List<FindCommand> commandsFor(String text, {int max = 8}) {
  if (!isCommandNeedle(text)) return const [];
  final typed =
      text.trimLeft().substring(commandPrefix.length).trim().toLowerCase();
  if (typed.isEmpty) {
    return findCommands.length <= max
        ? findCommands
        : findCommands.sublist(0, max);
  }
  final leading = <FindCommand>[];
  final rest = <FindCommand>[];
  for (final command in findCommands) {
    final lower = command.label.toLowerCase();
    if (lower.startsWith(typed)) {
      leading.add(command);
    } else if (lower.contains(typed)) {
      rest.add(command);
    }
  }
  final out = [...leading, ...rest];
  return out.length <= max ? out : out.sublist(0, max);
}
