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
/// **Save is the only thing that commits.** This is the body of a settings
/// section rather than a pane of its own, so there is nowhere to go back to:
/// Cancel puts the last saved text back in the field and stays, and Save
/// writes and stays. Being disposed still discards. The strictness is
/// deliberate — these rules change how every message is judged, so a
/// half-typed thought abandoned by scrolling away or closing the section must
/// not quietly become the rule.
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
class NeedsYouRulesEditor extends StatefulWidget {
  /// The stored rules, verbatim. Empty means the defaults are in force, which
  /// is what the field is prefilled with.
  final String value;

  /// The app's own needs-you rules: the prefill, and what Reset restores. A
  /// prop rather than an import so the editor has no opinion about which
  /// prompt it is editing for, and a test can pass a string it can recognise.
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

  const NeedsYouRulesEditor({
    super.key,
    required this.value,
    required this.defaultRules,
    required this.fixedTail,
    required this.maxLength,
    required this.onSave,
  });

  @override
  State<NeedsYouRulesEditor> createState() => _NeedsYouRulesEditorState();
}

class _NeedsYouRulesEditorState extends State<NeedsYouRulesEditor> {
  /// The last text this editor either opened on or saved. Held rather than
  /// recomputed because it is what "dirty" is measured against and what Cancel
  /// restores, and an empty stored value opens on the defaults rather than on
  /// nothing. It moves on every Save, so a second edit is dirty against the
  /// first save rather than against the original.
  late String _initial;

  late final TextEditingController _rules;

  /// Collapsed to start: the tail is reference material for the minority of
  /// visits that are checking what survives an edit, and expanded by default it
  /// would push the field the editor exists for off the screen.
  bool _showTail = false;

  /// Roughly eight lines at a time. Tall enough to read the contract in
  /// context, short enough that the field above stays in view.
  static const double _tailMaxHeight = 220;

  @override
  void initState() {
    super.initState();
    _initial = widget.value.isEmpty ? widget.defaultRules : widget.value;
    _rules = TextEditingController(text: _initial);
    // Save and Reset are both enabled by what is in the field, so the buttons
    // have to hear every keystroke — nothing else here redraws.
    _rules.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(NeedsYouRulesEditor old) {
    super.didUpdateWidget(old);
    // The stored rules changing underneath us — a sign-in inside Settings
    // wipes the previous person's rules to '' — is not an edit of ours. An
    // unsaved edit is the user's and is never overwritten; a clean field
    // adopts what the host now says.
    if (old.value != widget.value && _rules.text == _initial) {
      _initial = widget.value.isEmpty ? widget.defaultRules : widget.value;
      _rules.text = _initial;
    }
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

  /// Whether the field says something other than what it last opened on or
  /// saved. The comparison is against the raw text rather than a trimmed one so
  /// that Save lights up for a change the user can see themselves having made.
  bool get _dirty => _rules.text != _initial;

  void _save() {
    final text = _rules.text.trim();
    // A body equal to the defaults is stored as the empty preference, so the
    // default path keeps serving the one const prompt every judgement shares.
    // The trim happens here and nowhere else — the store keeps what it is
    // handed, verbatim.
    widget.onSave(text == widget.defaultRules.trim() ? '' : text);
    // The saved text becomes the new baseline: Save disables again, and a
    // later Cancel reverts to what was actually saved rather than to whatever
    // the section opened on.
    setState(() => _initial = _rules.text);
  }

  /// Puts the last saved text back and stays. There is no pane to leave — the
  /// section around this is still open, and the summary above it still says
  /// what is in force.
  void _cancel() => setState(() => _rules.text = _initial);

  @override
  Widget build(BuildContext context) {
    // A plain Column, deliberately unbounded: this sits inside the settings
    // screen's SingleChildScrollView, where an Expanded would be an
    // unbounded-height error rather than a scroll region.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'These are the rules the model reads for every message Bond cannot '
          'settle on its own. Edit them freely — they replace the defaults '
          'entirely. Bond adds the answer format automatically.',
          style: BondType.small,
        ),
        const SizedBox(height: BondSpacing.s16),
        TextField(
          controller: _rules,
          minLines: 6,
          maxLines: 12,
          maxLength: widget.maxLength,
        ),
        Align(
          alignment: Alignment.centerLeft,
          // Local until Save, like every other edit here: the button puts the
          // defaults back in the field and nothing more, and Cancel still
          // reverts.
          child: TextButton(
            onPressed: _rules.text == widget.defaultRules
                ? null
                : () => _rules.text = widget.defaultRules,
            child: const Text('Reset to default'),
          ),
        ),
        const SizedBox(height: BondSpacing.s16),
        ..._tailDisclosure(),
        const SizedBox(height: BondSpacing.s16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            // Greyed when there is nothing to revert, the same rule Save
            // follows — and the same rule the about-me section beside this
            // one uses, so the two footers read as one control.
            TextButton(
              onPressed: _dirty ? _cancel : null,
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
