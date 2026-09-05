import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The rules the needs-you judgement reads, edited in one place — the WHOLE of
/// them, not a note appended to somebody else's.
///
/// What this text IS: the body of the system prompt for every below-the-floor
/// needs-you judgement. The `needs_you_rules` preference holds it, and an empty
/// preference means the app's own [defaultRules] are in force. So the field is
/// prefilled with those defaults rather than left blank: what the owner edits
/// is the real text, and "Reset to default" puts the real text back.
///
/// Saving a body identical to the defaults stores the EMPTY string. The default
/// path builds a const prompt that every judgement shares, and a stored copy of
/// the same words would fork it into an equal-but-not-identical string for no
/// change in what is asked.
///
/// **Save is the only thing that commits.** Cancel, the back arrow, and being
/// disposed all discard — unlike the settings dialog, which saves its about-me
/// text on the way out however the dialog was dismissed. The difference is
/// deliberate: about-me is a description of a person that costs nothing to
/// keep, while these rules change how every message is judged, so a half-typed
/// thought abandoned by clicking Back must not quietly become the rule.
///
/// The trim on Save is the one place stray whitespace is dropped. The store
/// keeps whatever it is handed, verbatim, so the editor is where "text with a
/// trailing newline" becomes "text".
///
/// The disclosure shows [fixedTail] VERBATIM rather than a summary of it. The
/// owner may replace every word above it and not one word of it; a person owed
/// that much control is owed the sight of what is appended to what they wrote.
///
/// A plain [StatefulWidget] over values and callbacks, reaching for no
/// providers itself — the screen owns the wiring, and a test can drive this
/// with nothing but closures.
class NeedsYouRulesPane extends StatefulWidget {
  /// The stored rules, verbatim. Empty means the defaults are in force, which
  /// is what the field is prefilled with.
  final String value;

  /// The app's own needs-you rules: the prefill, and what Reset restores. A
  /// prop rather than an import so the pane has no opinion about which prompt
  /// it is editing for, and a test can pass a string it can recognise.
  final String defaultRules;

  /// The output contract appended after whatever body is in force, shown in
  /// the disclosure. Not editable from here, and not editable from the field
  /// either — that is the point of showing it.
  final String fixedTail;

  /// The cap the prompt clamps to, enforced on the field. A cap the editor did
  /// not show would silently drop the end of what somebody typed.
  final int maxLength;

  /// Fired by Save and by nothing else — never on dispose. Handed the trimmed
  /// text, or the empty string where that text is the defaults.
  final void Function(String value) onSave;

  /// Leaves the pane. Called by Cancel, by the back arrow, and by Save once it
  /// has saved.
  final VoidCallback onBack;

  const NeedsYouRulesPane({
    super.key,
    required this.value,
    required this.defaultRules,
    required this.fixedTail,
    required this.maxLength,
    required this.onSave,
    required this.onBack,
  });

  @override
  State<NeedsYouRulesPane> createState() => _NeedsYouRulesPaneState();
}

class _NeedsYouRulesPaneState extends State<NeedsYouRulesPane> {
  /// What the field showed when the pane opened. Held rather than recomputed
  /// because it is what "dirty" is measured against, and an empty stored value
  /// opens on the defaults rather than on nothing.
  late final String _initial =
      widget.value.isEmpty ? widget.defaultRules : widget.value;

  late final TextEditingController _rules = TextEditingController(
    text: _initial,
  );

  /// Collapsed to start: the tail is reference material for the minority of
  /// visits that are checking what survives an edit, and expanded by default it
  /// would push the field the pane exists for off the screen.
  bool _showTail = false;

  /// Roughly eight lines at a time. Tall enough to read the contract in
  /// context, short enough that the field above stays in view.
  static const double _tailMaxHeight = 220;

  @override
  void initState() {
    super.initState();
    // Save and Reset are both enabled by what is in the field, so the buttons
    // have to hear every keystroke — nothing else on the pane redraws.
    _rules.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _rules.removeListener(_onChanged);
    // Nothing is saved here, on purpose. See the class doc: an explicit Save
    // is the whole contract, and a dispose that wrote would make Cancel a lie.
    _rules.dispose();
    super.dispose();
  }

  /// Whether the field says something other than what it opened on. The
  /// comparison is against the raw opening text rather than a trimmed one so
  /// that Save lights up for a change the user can see themselves having made.
  bool get _dirty => _rules.text != _initial;

  void _save() {
    final text = _rules.text.trim();
    // A body equal to the defaults is stored as the empty preference, so the
    // default path keeps serving the one const prompt every judgement shares.
    // The trim happens here and nowhere else — the store keeps what it is
    // handed, verbatim.
    widget.onSave(text == widget.defaultRules.trim() ? '' : text);
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
                iconSize: 20,
                tooltip: 'Back',
              ),
              const SizedBox(width: BondSpacing.s4),
              Expanded(
                child: Text(
                  'Needs You rules',
                  style: BondType.titleSm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: BondSpacing.s8),
          Text(
            'These are the rules the model reads for every message Bond cannot '
            'settle on its own. Edit them freely — they replace the defaults '
            'entirely. Bond adds the answer format automatically.',
            style: BondType.small,
          ),
          const SizedBox(height: BondSpacing.s16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _rules,
                    minLines: 6,
                    maxLines: 12,
                    maxLength: widget.maxLength,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    // Local until Save, like every other edit on this pane: the
                    // button puts the defaults back in the field and nothing
                    // more, and Cancel still discards.
                    child: TextButton(
                      onPressed: _rules.text == widget.defaultRules
                          ? null
                          : () => _rules.text = widget.defaultRules,
                      child: const Text('Reset to default'),
                    ),
                  ),
                  const SizedBox(height: BondSpacing.s16),
                  ..._tailDisclosure(),
                ],
              ),
            ),
          ),
          const SizedBox(height: BondSpacing.s16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: widget.onBack,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: BondSpacing.s8),
              FilledButton(
                onPressed: _dirty ? _save : null,
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// What is appended after the owner's rules, exactly as the model receives
  /// it.
  List<Widget> _tailDisclosure() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _showTail = !_showTail),
          icon: Icon(
            _showTail ? Icons.expand_less : Icons.expand_more,
            size: 20,
          ),
          label: const Text('What Bond adds after your rules'),
        ),
      ),
      if (_showTail) ...[
        const SizedBox(height: BondSpacing.s8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _tailMaxHeight),
          child: Container(
            decoration: BoxDecoration(
              color: BondColors.faintGround,
              border: Border.all(color: BondColors.border),
              borderRadius: BondRadii.mdAll,
            ),
            padding: const EdgeInsets.all(BondSpacing.s12),
            child: SingleChildScrollView(
              // Selectable so a line can be copied out and written around in
              // the field above. Left-trimmed only: the tail opens with a blank
              // line that is a concatenation separator rather than prose, and
              // trimming the left alone leaves every word of it intact.
              child: SelectableText(
                widget.fixedTail.trimLeft(),
                style: BondType.small,
              ),
            ),
          ),
        ),
      ],
    ];
  }
}
