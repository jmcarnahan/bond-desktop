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

/// One scope a rule could be written on, offered beside a label the owner has
/// just filed a thread under — requirement 11b's inline offer.
///
/// A candidate, not a rule: it names WHAT a rule would be about and nothing
/// about what the rule would do. The host computes these from the thread (the
/// sender's address, its domain, the thread's classification, a subject prefix),
/// the picker draws them, and pressing one hands the pair straight back. No rule
/// exists until the host writes one.
///
/// Defined here rather than in `models/` because it is a fact about this
/// widget's offer line and nothing stores it: [LabelRule] is the stored shape,
/// and it carries a disposition, an id and a count this has no opinion about.
@immutable
class LabelRuleOffer {
  /// One of [LabelRule]'s scope kinds. An open set there and an open set here:
  /// a kind this build has no words for reads as `this <kind>` rather than as
  /// nothing, so a later build's offer is legible instead of blank.
  final String scopeKind;

  /// What the rule would be about — the address, the domain, the classification
  /// or the subject prefix. Shown only as a tooltip: the chip says which KIND
  /// of rule, and the thread on screen is where the reader sees the value.
  final String scopeValue;

  const LabelRuleOffer({required this.scopeKind, required this.scopeValue});

  /// The chip's words. Second person and no jargon, because a chip is the whole
  /// explanation a reader gets before they press it.
  String get words => switch (scopeKind) {
        LabelRule.scopeSender => 'this sender',
        LabelRule.scopeDomain => 'this domain',
        LabelRule.scopeClassification => 'this kind of mail',
        LabelRule.scopeSubject => 'subjects like "$scopeValue"',
        _ => 'this ${scopeKind.replaceAll('_', ' ')}',
      };

  @override
  bool operator ==(Object other) =>
      other is LabelRuleOffer &&
      other.scopeKind == scopeKind &&
      other.scopeValue == scopeValue;

  @override
  int get hashCode => Object.hash(scopeKind, scopeValue);

  @override
  String toString() => 'LabelRuleOffer($scopeKind=$scopeValue)';
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
/// `Enter — create 'Vendor outreach'`.
///
/// A widget with no providers and no store in it: the labels arrive ordered (the
/// host reads `use_count DESC, last_used_at DESC`), and applying, creating and
/// dismissing are callbacks. The host owns persistence, the toast, the undo and
/// whether the picker is open — which is what lets a key press open it from
/// outside and an apply collapse it.
class LabelPicker extends StatefulWidget {
  /// The owner's vocabulary, ALREADY in the order the chips should read: most
  /// used first, most recently used breaking the tie. This widget never sorts —
  /// the order is a fact about the store, and a second opinion here would drift
  /// from the one the rest of the app shows.
  final List<Label> labels;

  /// Applies an existing label — a chip tap, or Enter on the top match.
  final void Function(Label label) onApply;

  /// Creates the typed name and applies it, trimmed. One callback rather than
  /// two because the reader pressed Enter once: the host calls `createLabel`
  /// (idempotent on the trimmed, lowercased name) and applies what comes back.
  final void Function(String name) onCreate;

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

  /// The scopes a rule could be written on for this thread. Empty — the default
  /// — draws no offer line at all, which is every mount that has not asked for
  /// one.
  ///
  /// The host decides WHEN there is anything to offer, and that is deliberate:
  /// the offer belongs to the dismiss path, and this widget knows which question
  /// it is asking only by the words it was handed.
  final List<LabelRuleOffer> ruleOffers;

  /// The label a rule written here would carry — in practice the label the
  /// thread ALREADY wears, since the host's dismiss path unmounts this strip
  /// the moment a label is applied. Null — the default — draws no offer line,
  /// which is a first-ever dismissal's natural state: the recurring thread
  /// that came back wearing its word is the one a rule is for, and the
  /// recurring CLASS is the suggestion row's job.
  ///
  /// It arrives from OUTSIDE rather than being remembered here because the
  /// create path mints the label in the store: the picker knows the name the
  /// reader typed and not the [Label] it became, and offering a rule for a
  /// label nobody can name yet would be offering to write a row with a hole in
  /// it. One source of truth, and it is the host's.
  final Label? ruleOfferLabel;

  /// The reader chose a scope. The pair is everything a caller needs to write
  /// the rule; nothing here writes one, and the disposition is the host's to
  /// decide (Settings is where it is changed afterwards).
  ///
  /// Null — the default — draws no offer line, so a host that cannot persist a
  /// rule never shows one.
  final void Function(Label label, LabelRuleOffer offer)? onRuleChosen;

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
    this.ruleOffers = const [],
    this.ruleOfferLabel,
    this.onRuleChosen,
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

  /// The offer line's own row, so a test can scope to it rather than to the
  /// label chips above it.
  static const Key ruleRowKey = ValueKey('label-picker-rules');

  /// One scope chip, keyed by its KIND: the line holds at most one chip per
  /// kind, and the kind is what the reader is choosing between.
  static Key ruleKeyFor(LabelRuleOffer offer) =>
      ValueKey('label-picker-rule-${offer.scopeKind}');

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

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _needle => _controller.text.trim();

  /// Case-insensitive substring on the name, in the order the host handed them
  /// over, capped.
  List<Label> get _filtered {
    final needle = _needle.toLowerCase();
    final matches = needle.isEmpty
        ? widget.labels
        : [
            for (final label in widget.labels)
              if (label.name.toLowerCase().contains(needle)) label,
          ];
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

  /// What Enter means right now — the one rule, read by both the hint line and
  /// the submit handler so the two can never disagree.
  _EnterMeaning get _enter {
    final filtered = _filtered;
    if (filtered.isNotEmpty) return _EnterMeaning.apply(filtered.first);
    if (_needle.isNotEmpty) return _EnterMeaning.create(_needle);
    if (widget.onDismissWithoutLabel != null) return const _EnterMeaning.none();
    return const _EnterMeaning.inert();
  }

  void _submit() {
    switch (_enter) {
      case _Apply(label: final label):
        _apply(label);
      case _Create(name: final name):
        _controller.clear();
        widget.onCreate(name);
      case _NoLabel():
        widget.onDismissWithoutLabel?.call();
      case _Inert():
        break;
    }
  }

  void _apply(Label label) {
    _controller.clear();
    widget.onApply(label);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final hidden = _matchCount - filtered.length;
    final dismiss = widget.onDismissWithoutLabel;

    // Escape is bound HERE rather than on the screen, on `FindField`'s
    // precedent: it only fires while the strip holds focus, which is where the
    // hand that just typed already is.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
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
                  onPressed: widget.onClose,
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
            if (filtered.isNotEmpty) ...[
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
                  onPressed: dismiss,
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
            ?_ruleOffer(),
          ],
        ),
      ),
    );
  }

  /// "And every future one of these": the offer line, under everything else
  /// because it is about the mail that has not arrived yet and the reader has
  /// already dealt with the thread in front of them.
  ///
  /// Null unless all three parts are present — a label to file under, scopes to
  /// offer, and somewhere for the answer to go — so every mount that has not
  /// asked for the line draws exactly the strip it drew before it existed.
  ///
  /// The chips are ordinary focusable buttons and nothing binds Enter here: the
  /// type-ahead keeps the focus it was given, so Enter still means what the hint
  /// line says it means, and Tab is how a hand that never leaves the keyboard
  /// reaches a scope.
  Widget? _ruleOffer() {
    final label = widget.ruleOfferLabel;
    final chosen = widget.onRuleChosen;
    if (label == null || chosen == null || widget.ruleOffers.isEmpty) {
      return null;
    }
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Also file future mail under '${label.name}':",
            style: BondType.caption,
          ),
          const SizedBox(height: BondSpacing.s8),
          Wrap(
            key: LabelPicker.ruleRowKey,
            spacing: BondSpacing.s8,
            runSpacing: BondSpacing.s8,
            children: [
              for (final offer in widget.ruleOffers)
                Material(
                  key: LabelPicker.ruleKeyFor(offer),
                  type: MaterialType.transparency,
                  // The value the rule would be about, a hover away. It is not
                  // in the chip because the chip has to stay four words wide,
                  // and the thread the reader is looking at is the value.
                  child: Tooltip(
                    message: offer.scopeValue,
                    child: InkWell(
                      onTap: () => chosen(label, offer),
                      borderRadius: BondRadii.fullAll,
                      child: BondChip.metric(offer.words),
                    ),
                  ),
                ),
            ],
          ),
        ],
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

class _Inert extends _EnterMeaning {
  const _Inert();
}
