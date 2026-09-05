import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The owner's own criteria for what counts as needing them, edited in one
/// place.
///
/// What this text IS: the `needs_you_rules` preference, fenced into every
/// below-the-floor needs-you judgement as additional criteria on top of the
/// rules the app already asks. It is not a note to self and it is not a filter
/// — every word typed here is read by a model, which is why the editor caps
/// its length at the same number the prompt clamps to, and why it shows the
/// defaults it refines.
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
/// The defaults disclosure shows [defaultRules] VERBATIM rather than a summary
/// of them. This is the exact text the model reads before it reads the owner's
/// additions; a paraphrase would make the pane lie about the prompt, and
/// somebody writing a rule to override one of the defaults would be aiming at
/// words that are not there.
///
/// A plain [StatefulWidget] over values and callbacks, reaching for no
/// providers itself — the screen owns the wiring, and a test can drive this
/// with nothing but closures.
class NeedsYouRulesPane extends StatefulWidget {
  /// The stored rules, verbatim.
  final String value;

  /// The app's own needs-you rules, shown in the disclosure. A prop rather
  /// than an import so the pane has no opinion about which prompt it is
  /// editing for, and a test can pass a string it can recognise.
  final String defaultRules;

  /// The cap the prompt clamps to, enforced on the field. A cap the editor did
  /// not show would silently drop the end of what somebody typed.
  final int maxLength;

  /// Fired by Save and by nothing else — never on dispose. Handed the trimmed
  /// text.
  final void Function(String value) onSave;

  /// Leaves the pane. Called by Cancel, by the back arrow, and by Save once it
  /// has saved.
  final VoidCallback onBack;

  const NeedsYouRulesPane({
    super.key,
    required this.value,
    required this.defaultRules,
    required this.maxLength,
    required this.onSave,
    required this.onBack,
  });

  @override
  State<NeedsYouRulesPane> createState() => _NeedsYouRulesPaneState();
}

class _NeedsYouRulesPaneState extends State<NeedsYouRulesPane> {
  late final TextEditingController _rules = TextEditingController(
    text: widget.value,
  );

  /// Collapsed to start: the defaults are reference material for the minority
  /// of visits that are writing a rule against one of them, and expanded by
  /// default they would push the field the pane exists for off the screen.
  bool _showDefaults = false;

  /// Roughly eight lines of the defaults at a time. Tall enough to read a rule
  /// in context, short enough that the field above stays in view.
  static const double _defaultsMaxHeight = 220;

  @override
  void initState() {
    super.initState();
    // Save and Clear are both enabled by what is in the field, so the buttons
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

  /// Whether the field says something other than what is stored. The comparison
  /// is against the raw stored text rather than a trimmed one so that Save
  /// lights up for a change the user can see themselves having made.
  bool get _dirty => _rules.text != widget.value;

  void _save() {
    widget.onSave(_rules.text.trim());
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
            'Your own criteria, applied to every message on top of what Bond '
            'already asks. Write them the way you would explain them to a new '
            'assistant.',
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
                    decoration: const InputDecoration(
                      hintText:
                          'e.g. Invoices and anything about money always need '
                          'me. Messages that only share a status report do not.',
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    // "Clear my rules", not "Reset to default": there is no
                    // text to restore. Clearing removes the owner's additions
                    // so the defaults below stand on their own again.
                    child: TextButton(
                      onPressed: _rules.text.isEmpty
                          ? null
                          : () => _rules.clear(),
                      child: const Text('Clear my rules'),
                    ),
                  ),
                  const SizedBox(height: BondSpacing.s16),
                  ..._defaultsDisclosure(),
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

  /// The rules the app asks by itself, exactly as the model receives them.
  List<Widget> _defaultsDisclosure() {
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _showDefaults = !_showDefaults),
          icon: Icon(
            _showDefaults ? Icons.expand_less : Icons.expand_more,
            size: 20,
          ),
          label: const Text('What Bond already asks'),
        ),
      ),
      if (_showDefaults) ...[
        const SizedBox(height: BondSpacing.s8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _defaultsMaxHeight),
          child: Container(
            decoration: BoxDecoration(
              color: BondColors.faintGround,
              border: Border.all(color: BondColors.border),
              borderRadius: BondRadii.mdAll,
            ),
            padding: const EdgeInsets.all(BondSpacing.s12),
            child: SingleChildScrollView(
              // Selectable so a rule can be copied out and argued with in the
              // field above.
              child: SelectableText(
                widget.defaultRules,
                style: BondType.small,
              ),
            ),
          ),
        ),
      ],
    ];
  }
}
