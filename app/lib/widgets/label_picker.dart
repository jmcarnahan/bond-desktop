import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/label_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'label_chip.dart';

/// Which question an inline picker is asking, which is the only thing its two
/// mounts disagree about.
///
/// The WORDING and whether a no-label way out is offered follow from it, so a
/// host that opens the picker from a key (`l`) or from a button says which of
/// the two it meant once, rather than passing a sentence around.
enum LabelPickerMode {
  /// File this thread under a word and leave it where it is — the `l` path.
  /// Dismissing with no label makes no sense here, so the affordance is off.
  label,

  /// Dismiss the thread, with a word saying why — the `Shift+E` path. A
  /// dismissal with no label at all is still allowed: a reader who has already
  /// dealt with the thread should not have to invent a category for it.
  dismiss,
}

extension LabelPickerModePrompt on LabelPickerMode {
  /// The caption over the field. Short, because the hint line under it is where
  /// the picker says what the next keystroke does.
  String get prompt => switch (this) {
        LabelPickerMode.label => 'Label…',
        LabelPickerMode.dismiss => 'Mark done with a label…',
      };
}

/// The inline label strip: the whole dismiss-and-file flow, in place.
///
/// No dialog and no menu, which is the house rule, but also the faster shape:
/// the chips narrow under the reader's eyes as they type, so "the top match" is
/// something they can SEE rather than a promise the app makes about a list it is
/// hiding. Keyboard first — a shortcut opens it, a few letters narrow it, Enter
/// commits — and every keystroke has a mouse equivalent beside it.
///
/// **Enter is overloaded on purpose, and the hint line says which meaning is
/// live right now.** With a match, it applies the top chip; with a name nothing
/// matches, it creates that label and applies it; with an empty box on the
/// dismiss path, it dismisses with no label at all. The affordance IS the
/// documentation: nobody reads a legend, and everybody reads the line that says
/// `Enter — create 'Vendor outreach'`. A typed name that is only PART of an
/// existing word still gets a way to mint itself: a trailing `Create "…"` chip
/// after the matches, the mouse's answer to "I meant a new word, not that
/// one". A name with a quote mark in it is refused rather than created — the
/// store would refuse it anyway, and the hint line says so before Enter does.
///
/// **One create at a time.** A create hands the host a future; until it
/// settles the strip is busy and every way out of it — Enter, a chip, Escape,
/// the ✕, the no-label button — does nothing. The host has already read the
/// mode it was asked in and closed its request by then, so a second Enter
/// landing on the top chip or an Escape turning "mark done with a label" into
/// "keep with a label" mid-write is exactly what the guard is there to stop.
/// Every host in the app closes its request synchronously, before the create's
/// await, so the strip is gone a frame later; [_LabelPickerState._busy] is the
/// backstop for the same frame and for a host that keeps the strip mounted —
/// it is not a reason to drop the host-side close.
///
/// A widget with no providers and no store in it: the labels arrive ordered (the
/// host reads `use_count DESC, last_used_at DESC`), and applying, creating and
/// dismissing are callbacks. The host owns persistence, the toast, the undo and
/// whether the picker is open — which is what lets a key press open it from
/// outside and an apply collapse it.
class LabelPicker extends StatefulWidget {
  /// The owner's vocabulary, ALREADY in the order the chips should read: most
  /// used first, most recently used breaking the tie. This widget never sorts,
  /// except that the word typed EXACTLY is first — the order is a fact about
  /// the store, and a second opinion here would drift from the one the rest of
  /// the app shows, but a reader who typed `fyi` in full means `fyi`, not the
  /// more used `fyi-team` that merely contains it.
  final List<Label> labels;

  /// Applies an existing label — a chip tap, or Enter on the top match.
  final void Function(Label label) onApply;

  /// Creates the typed name and applies it, trimmed. One callback rather than
  /// two because the reader pressed Enter once: the host calls `createLabel`
  /// (idempotent on the trimmed, lowercased name) and applies what comes back.
  ///
  /// A host that hands back a [Future] holds the strip busy until it settles
  /// (see the class doc's one-create rule); a plain `void` callback leaves the
  /// strip live, which is what a host with nothing to wait on wants.
  final FutureOr<void> Function(String name) onCreate;

  /// Dismisses with no label. Null takes the affordance away AND takes the
  /// meaning off an empty-box Enter — which is what the label-only mount wants,
  /// where there is nothing to dismiss.
  final VoidCallback? onDismissWithoutLabel;

  /// Escape, and the collapse affordance. The host owns the open state, so this
  /// is a request rather than a local toggle.
  final VoidCallback onClose;

  /// True — the default — because the picker only exists when somebody asked
  /// for it, and the next thing they will do is type.
  final bool autofocus;

  /// The caption over the field; [LabelPickerModePrompt.prompt] is where the two
  /// mounts get theirs.
  final String prompt;

  /// The ids already on the thread. Their chips carry a ✓, because a picker
  /// that drew the owner's whole vocabulary the same way read as the thread's
  /// own labels — "jira" in the list looked like "this is labelled jira".
  final Set<String> appliedIds;

  const LabelPicker({
    super.key,
    required this.labels,
    required this.onApply,
    required this.onCreate,
    required this.onClose,
    required this.prompt,
    this.onDismissWithoutLabel,
    this.autofocus = true,
    this.appliedIds = const {},
  });

  /// The type-ahead box.
  static const Key fieldKey = ValueKey('label-picker-field');

  /// The chip row, so a test can scope a search to the chips rather than to the
  /// whole strip.
  static const Key chipRowKey = ValueKey('label-picker-chips');

  /// The line that says what Enter does right now.
  static const Key hintKey = ValueKey('label-picker-hint');

  /// The no-label way out, drawn only on the dismiss path.
  static const Key noLabelKey = ValueKey('label-picker-no-label');

  /// One chip, keyed by the LABEL rather than by its place in the filtered row:
  /// a keystroke reorders that row, and a moving key throws away the chip the
  /// reader was aiming at.
  static Key keyFor(Label label) => ValueKey('label-picker-chip-${label.id}');

  /// The trailing `Create "…"` chip: drawn after the matches whenever the typed
  /// name is not already a word and could be one.
  static const Key createChipKey = ValueKey('label-picker-create');

  /// How many chips the row shows. A cap rather than a scroll: the keyboard
  /// flow is the point, and a reader with more words than this narrows them by
  /// typing instead of by hunting.
  static const int visibleChips = 8;

  @override
  State<LabelPicker> createState() => _LabelPickerState();
}

class _LabelPickerState extends State<LabelPicker> {
  /// The needle, owned HERE unlike every other field in the app: it is worth
  /// nothing the moment the strip collapses, and a host keeping it would have to
  /// remember to clear it before the next thread.
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// True while a create the host handed back as a future is still in flight.
  /// Every way out of the strip reads it and does nothing meanwhile — see the
  /// class doc's one-create rule. Local rather than the host's, because the
  /// host has already closed its request by the time the write is running and
  /// so has nothing left to hold.
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _needle => _controller.text.trim();

  /// Case-insensitive substring on the name, in the order the host handed them
  /// over, capped — except that a name equal to the needle (case-insensitive)
  /// moves to the front BEFORE the cap, so the word typed in full is the one
  /// Enter applies and is never the chip the cap cut off.
  List<Label> get _filtered {
    final needle = _needle.toLowerCase();
    final List<Label> matches;
    if (needle.isEmpty) {
      matches = widget.labels;
    } else {
      final exact = <Label>[];
      final rest = <Label>[];
      for (final label in widget.labels) {
        final name = label.name.toLowerCase();
        if (name == needle) {
          exact.add(label);
        } else if (name.contains(needle)) {
          rest.add(label);
        }
      }
      matches = [...exact, ...rest];
    }
    return matches.length <= LabelPicker.visibleChips
        ? matches
        : matches.sublist(0, LabelPicker.visibleChips);
  }

  /// Every match, for the count the chip row cannot show.
  int get _matchCount {
    final needle = _needle.toLowerCase();
    if (needle.isEmpty) return widget.labels.length;
    var n = 0;
    for (final label in widget.labels) {
      if (label.name.toLowerCase().contains(needle)) n++;
    }
    return n;
  }

  /// Whether the typed name could be minted: something typed, no quote mark
  /// in it (the store refuses one), and not already a word — a create of an
  /// existing name would only re-apply it.
  bool get _creatable {
    final needle = _needle;
    if (needle.isEmpty || needle.contains('"')) return false;
    final lower = needle.toLowerCase();
    return !widget.labels.any((l) => l.name.toLowerCase() == lower);
  }

  /// What Enter means right now — the one rule, read by both the hint line and
  /// the submit handler so the two can never disagree. A quote-marked name
  /// nothing matches is refused here, so the hint says why before the store
  /// would.
  _EnterMeaning get _enter {
    final filtered = _filtered;
    if (filtered.isNotEmpty) return _EnterMeaning.apply(filtered.first);
    if (_needle.contains('"')) return const _EnterMeaning.refused();
    if (_needle.isNotEmpty) return _EnterMeaning.create(_needle);
    if (widget.onDismissWithoutLabel != null) return const _EnterMeaning.none();
    return const _EnterMeaning.inert();
  }

  /// Enter. Inert while a create is in flight — see [_busy].
  void _submit() {
    if (_busy) return;
    switch (_enter) {
      case _Apply(label: final label):
        _apply(label);
      case _Create(name: final name):
        _create(name);
      case _NoLabel():
        widget.onDismissWithoutLabel?.call();
      case _Refused():
      case _Inert():
        break;
    }
  }

  void _apply(Label label) {
    if (_busy) return;
    _controller.clear();
    widget.onApply(label);
  }

  /// The one create path, for Enter's Create meaning and the trailing chip
  /// alike: clears the box, hands the name over, and holds the strip busy
  /// until a future the host returned settles.
  void _create(String name) {
    if (_busy) return;
    _controller.clear();
    final pending = widget.onCreate(name);
    if (pending is Future) {
      setState(() => _busy = true);
      // `.ignore()` on the derived future: it re-throws a host error nobody
      // else listens to, and the host owns saying what went wrong.
      pending.whenComplete(() {
        if (mounted) setState(() => _busy = false);
      }).ignore();
    }
  }

  /// Escape and the ✕, refused mid-create for [_busy]'s reason.
  void _close() {
    if (_busy) return;
    widget.onClose();
  }

  /// The no-label button, refused mid-create for [_busy]'s reason.
  void _dismissWithoutLabel() {
    if (_busy) return;
    widget.onDismissWithoutLabel?.call();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final hidden = _matchCount - filtered.length;
    final dismiss = widget.onDismissWithoutLabel;
    final needle = _needle;
    final creatable = _creatable;

    // Escape is bound HERE rather than on the screen, on `FindField`'s
    // precedent: it only fires while the strip holds focus, which is where the
    // hand that just typed already is.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Container(
        padding: const EdgeInsets.all(BondSpacing.s12),
        decoration: BoxDecoration(
          color: BondColors.faintGround,
          borderRadius: BondRadii.smAll,
          border: Border.all(color: BondColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.prompt, style: BondType.label)),
                IconButton(
                  onPressed: _close,
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(BondSpacing.s4),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: BondSpacing.s8),
            TextField(
              key: LabelPicker.fieldKey,
              controller: _controller,
              focusNode: _focus,
              autofocus: widget.autofocus,
              style: BondType.small,
              textInputAction: TextInputAction.done,
              // Live, unlike the search box next door: filtering costs a walk
              // over a list already in memory, not a round trip.
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Type to filter, or a new name',
              ),
            ),
            if (filtered.isNotEmpty || creatable) ...[
              const SizedBox(height: BondSpacing.s8),
              Wrap(
                key: LabelPicker.chipRowKey,
                spacing: BondSpacing.s8,
                runSpacing: BondSpacing.s8,
                children: [
                  for (final label in filtered)
                    // A chip is a button here, so it carries its own ink rather
                    // than borrowing the pane's. The chip inside is drawn the
                    // way a row draws the same label — `label_chip.dart` owns
                    // both the tone word and the chip — and the tap target
                    // around it carries the picker's own key, so a row's chip
                    // and this one never answer the same finder.
                    Material(
                      key: LabelPicker.keyFor(label),
                      type: MaterialType.transparency,
                      child: Tooltip(
                        message: _chipTip(label),
                        child: InkWell(
                          onTap: () => _apply(label),
                          borderRadius: BondRadii.fullAll,
                          child: BondChip.semantic(
                            widget.appliedIds.contains(label.id)
                                ? '✓ ${label.name}'
                                : label.name,
                            labelToneOf(label.tone),
                          ),
                        ),
                      ),
                    ),
                  if (hidden > 0)
                    Text(
                      '+$hidden more — keep typing',
                      style: BondType.caption,
                    ),
                  // The mouse twin of Enter's Create meaning — and, beside
                  // matches, the only way to mint a word that is part of one
                  // already there, since Enter applies the top match then.
                  if (creatable)
                    Material(
                      key: LabelPicker.createChipKey,
                      type: MaterialType.transparency,
                      child: InkWell(
                        onTap: () => _create(needle),
                        borderRadius: BondRadii.fullAll,
                        child: BondChip.semantic(
                          'Create "$needle"',
                          labelToneOf(null),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: BondSpacing.s8),
            Text(
              key: LabelPicker.hintKey,
              _hintText(),
              style: BondType.caption,
            ),
            if (dismiss != null) ...[
              const SizedBox(height: BondSpacing.s4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: LabelPicker.noLabelKey,
                  onPressed: _dismissWithoutLabel,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BondSpacing.s8,
                    ),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: BondType.caption,
                  ),
                  child: const Text('Mark done with no label'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// What a chip's press will do, said the way the strip's mode means it:
  /// in the dismiss mode a chip closes the thread under the word, and "Add"
  /// would promise a label and nothing more.
  String _chipTip(Label label) {
    final applied = widget.appliedIds.contains(label.id);
    if (widget.onDismissWithoutLabel != null) {
      return applied
          ? 'Mark done — already labeled ${label.name}'
          : 'Mark done under ${label.name}';
    }
    return applied ? 'Already on this thread' : 'Add ${label.name}';
  }

  String _hintText() => switch (_enter) {
        _Apply(label: final label) => "Enter — apply '${label.name}'",
        _Create(name: final name) => "Enter — create '$name'",
        _NoLabel() => 'Enter — mark done with no label',
        _Refused() => "A label can't contain a quote mark.",
        _Inert() => 'Type a name and press Enter to create it',
      };
}

/// What the next Enter does. A closed set rather than a pair of booleans,
/// because the hint line and the submit handler read the SAME answer and a
/// second copy of the rule is how the two come to disagree.
sealed class _EnterMeaning {
  const _EnterMeaning();

  const factory _EnterMeaning.apply(Label label) = _Apply;
  const factory _EnterMeaning.create(String name) = _Create;

  /// Dismiss with nothing on it.
  const factory _EnterMeaning.none() = _NoLabel;

  /// A name with a quote mark in it and nothing matching: not a word the store
  /// will keep, so Enter does nothing and the hint says why.
  const factory _EnterMeaning.refused() = _Refused;

  /// Nothing typed and nowhere to go: an empty vocabulary on the label-only
  /// path.
  const factory _EnterMeaning.inert() = _Inert;
}

class _Apply extends _EnterMeaning {
  final Label label;
  const _Apply(this.label);
}

class _Create extends _EnterMeaning {
  final String name;
  const _Create(this.name);
}

class _NoLabel extends _EnterMeaning {
  const _NoLabel();
}

class _Refused extends _EnterMeaning {
  const _Refused();
}

class _Inert extends _EnterMeaning {
  const _Inert();
}
