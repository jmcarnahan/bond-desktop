import 'package:flutter/material.dart';

import '../models/label_models.dart';
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'label_chip.dart';
import 'label_picker.dart' show LabelRuleOffer;
import 'settings_section.dart';
import 'settings_segments.dart';

/// The owner's vocabulary, as one section of the settings screen: the one place
/// a label can be renamed, recoloured or thrown away.
///
/// Its own widget in the context-directories section's shape rather than another
/// arm of a screen that is already two thousand lines: it owns state of its own
/// — which row is being renamed, and which is asking a second time about Remove
/// — and its collapsed summary is built from the rows it renders, so the
/// summary lives beside them.
///
/// Prop-only, reaching for no providers itself, like every other section here.
/// Every write goes back out through a callback to whatever the host has wired
/// `labelsProvider` and `labelRulesProvider` up as, so a test drives the whole
/// section with two lists and five closures.
///
/// Nothing here touches `messages.label`, which is the model's verdict about one
/// message and never a word the owner chose. See [Label].
class LabelsSection extends StatefulWidget {
  /// The section's name, as the screen's open-set, `docs/settings.md` and every
  /// test spell it.
  static const String title = 'Labels';

  /// The vocabulary, in `labelsProvider`'s order — most used first.
  final List<Label> labels;

  /// Whether the first read is still out. The rows keep rendering while it is,
  /// on the same reasoning the directories section gives: the notifier carries
  /// the previous list through a re-read, and a section that emptied itself
  /// every time a label was applied would flicker.
  final bool loading;

  /// The newest failure or refusal, verbatim from `LabelsState.error`. A refused
  /// rename lands here — there is no dialog to refuse in — so while a row is
  /// being renamed this is drawn under that row's field and nowhere else.
  final String? error;

  /// Renames one label, keeping every thread it is on. False means the name is
  /// taken and [error] now says so; the field stays open on the typed text so
  /// the reader can edit rather than retype it. Null takes Rename off every row.
  final Future<bool> Function(String id, String name)? onRename;

  /// Sets, or with a null tone clears, one label's colour word. Fired the
  /// instant a segment is pressed, the discipline every segmented control on
  /// this screen follows. Null takes the colour control off every row.
  final void Function(String id, String? tone)? onToneChanged;

  /// Deletes one label and every thread link it has. Null takes Remove off
  /// every row.
  final void Function(String id)? onDelete;

  /// Every standing rule the owner has, in any order — grouped onto their labels
  /// here by [LabelRule.labelId]. Empty, the default, is a section that reads
  /// exactly as it did before rules existed.
  ///
  /// The whole list rather than a per-label lookup, because a rule whose label
  /// has gone is a row this section must be able to NOT draw: the grouping is
  /// the filter.
  final List<LabelRule> rules;

  /// Deletes one rule, by [LabelRule.id]. The label and the threads it has
  /// already filed stay — removing a rule is "stop doing this from now on", not
  /// "undo what you did". Null takes Remove off every rule row.
  final void Function(String ruleId)? onDeleteRule;

  /// Changes what one rule DOES, to one of [LabelRule]'s dispositions. Fired the
  /// instant a segment is pressed, the discipline every segmented control on this
  /// screen follows. Null takes the control off every rule row.
  ///
  /// The host is where the retro-apply lives: changing a disposition re-files the
  /// threads the rule already matched, and this section knows nothing about
  /// threads.
  final void Function(String ruleId, String disposition)?
      onRuleDispositionChanged;

  /// Whether the screen currently has this section open. The screen owns the
  /// open-set — see the [SettingsSection] doc — so this arrives as a prop.
  final bool expanded;

  final VoidCallback onToggle;

  const LabelsSection({
    super.key,
    required this.labels,
    required this.expanded,
    required this.onToggle,
    this.loading = false,
    this.error,
    this.onRename,
    this.onToneChanged,
    this.onDelete,
    this.rules = const [],
    this.onDeleteRule,
    this.onRuleDispositionChanged,
  });

  static ValueKey<String> rowKeyFor(String id) => ValueKey('label-row-$id');

  static ValueKey<String> renameKeyFor(String id) =>
      ValueKey('label-rename-$id');

  static ValueKey<String> nameFieldKeyFor(String id) =>
      ValueKey('label-name-$id');

  static ValueKey<String> saveKeyFor(String id) => ValueKey('label-save-$id');

  static ValueKey<String> cancelKeyFor(String id) =>
      ValueKey('label-cancel-$id');

  static ValueKey<String> toneKeyFor(String id) => ValueKey('label-tone-$id');

  static ValueKey<String> removeKeyFor(String id) =>
      ValueKey('label-remove-$id');

  static ValueKey<String> confirmRemoveKeyFor(String id) =>
      ValueKey('label-remove-confirm-$id');

  static ValueKey<String> keepKeyFor(String id) => ValueKey('label-keep-$id');

  /// One standing rule under its label, and its three controls. Keyed by the
  /// RULE's id, not the label's: a label can carry more than one.
  static ValueKey<String> ruleRowKeyFor(String ruleId) =>
      ValueKey('label-rule-$ruleId');

  static ValueKey<String> ruleChangeKeyFor(String ruleId) =>
      ValueKey('label-rule-change-$ruleId');

  static ValueKey<String> ruleDispositionKeyFor(String ruleId) =>
      ValueKey('label-rule-disposition-$ruleId');

  static ValueKey<String> ruleRemoveKeyFor(String ruleId) =>
      ValueKey('label-rule-remove-$ruleId');

  static ValueKey<String> ruleConfirmRemoveKeyFor(String ruleId) =>
      ValueKey('label-rule-remove-confirm-$ruleId');

  static ValueKey<String> ruleKeepKeyFor(String ruleId) =>
      ValueKey('label-rule-keep-$ruleId');

  /// `No labels yet` / `1 label` / `3 labels · 12 uses` / `3 labels · 12 uses ·
  /// 1 rule`.
  ///
  /// The use count joins only once something has been filed: a vocabulary
  /// nobody has applied yet would otherwise read `3 labels · 0 uses`, which
  /// says the same thing twice and one of them gloomily. The rule count joins on
  /// the same rule, and it is on the collapsed line at all because a standing
  /// rule acts on mail the owner never sees — the count is the one place a
  /// closed section can admit that.
  ///
  /// Static on the widget rather than on its state, because the collapsed line
  /// is pinned by `settings_screen_test.dart` and by the table in
  /// `docs/settings.md`, and a test has to be able to ask for it without
  /// building a section.
  static String summaryOf(List<Label> labels, {int rules = 0}) {
    if (labels.isEmpty) return 'No labels yet';
    final uses = labels.fold<int>(0, (sum, label) => sum + label.useCount);
    final parts = [
      plural(labels.length, 'label'),
      if (uses > 0) plural(uses, 'use'),
      if (rules > 0) plural(rules, 'rule'),
    ];
    return parts.join(' · ');
  }

  static String plural(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

  /// One rule as a sentence a reader can judge: what it does, what it is about,
  /// and what it has done so far.
  ///
  /// `Hide from Needs You · this sender · hid 41 threads`. Three facts and two
  /// separators, because a rule the owner cannot audit is a rule they will turn
  /// the feature off over. The scope words come from [LabelRuleOffer], which is
  /// the same sentence the picker offered when this rule was written — one
  /// spelling, so the offer and the record cannot read differently.
  static String ruleWords(LabelRule rule) {
    final scope =
        LabelRuleOffer(scopeKind: rule.scopeKind, scopeValue: rule.scopeValue)
            .words;
    return '${dispositionWords(rule.disposition)} · $scope · '
        '${filedWords(rule)}';
  }

  /// What a disposition DOES, in the words the rest of the app uses for the same
  /// three places mail can go. An unknown disposition — a rule written by a later
  /// build — reads as itself rather than as nothing.
  static String dispositionWords(String disposition) => switch (disposition) {
        LabelRule.hideNeedsYou => 'Hide from Needs You',
        LabelRule.sendToLater => 'Send to Later',
        LabelRule.dropAtGate => 'Drop before reading',
        _ => disposition.replaceAll('_', ' '),
      };

  /// What the rule has done, in the past tense of its own disposition. A rule
  /// that has not fired yet says so rather than reading `hid 0 threads`.
  static String filedWords(LabelRule rule) {
    if (rule.hiddenCount == 0) return 'nothing yet';
    final threads = plural(rule.hiddenCount, 'thread');
    return switch (rule.disposition) {
      LabelRule.sendToLater => 'moved $threads',
      LabelRule.dropAtGate => 'dropped $threads',
      _ => 'hid $threads',
    };
  }

  @override
  State<LabelsSection> createState() => _LabelsSectionState();
}

/// The dispositions this build can draw a segment for.
const Set<String> _knownDispositions = {
  LabelRule.hideNeedsYou,
  LabelRule.sendToLater,
  LabelRule.dropAtGate,
};

class _LabelsSectionState extends State<LabelsSection> {
  /// Which row has its name field open, by label id — never an index, which
  /// moves the moment the vocabulary is re-read.
  String? _editing;

  /// Which row is asking a second time about Remove. Its own field rather than
  /// a mode shared with [_editing]: both can be armed on the same row, and a
  /// rename in progress must not disarm a confirmation the reader set.
  String? _confirming;

  /// The open field's text. One controller for the section rather than one per
  /// row: exactly one row is ever being renamed.
  final TextEditingController _name = TextEditingController();

  /// True while a rename is out. Save goes inert — it is a write and a database
  /// read, and a second press would be a race over the same row.
  bool _saving = false;

  /// Which rule has its disposition control open, and which is asking a second
  /// time about Remove — by rule id, for [_editing]'s reason.
  String? _changingRule;
  String? _confirmingRule;

  /// The rules this section will draw, under the label each belongs to.
  ///
  /// A rule whose label is not in the list is dropped rather than drawn under a
  /// heading of its own: a rule with no word on it is a row the owner cannot act
  /// on, and the label list is the section's whole subject.
  Map<String, List<LabelRule>> get _rulesByLabel {
    final byLabel = <String, List<LabelRule>>{};
    final known = {for (final label in widget.labels) label.id};
    for (final rule in widget.rules) {
      if (!known.contains(rule.labelId)) continue;
      byLabel.putIfAbsent(rule.labelId, () => []).add(rule);
    }
    // Oldest first, so a second rule on one label appears UNDER the one that was
    // there yesterday instead of moving it.
    for (final rules in byLabel.values) {
      rules.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    return byLabel;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LabelsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A label that has gone — deleted here, or by a rule elsewhere — must not
    // leave the section holding an open field or an armed confirmation for an id
    // nothing renders. The next Remove would then arrive already confirmed.
    bool gone(String? id) =>
        id != null && !widget.labels.any((label) => label.id == id);
    if (gone(_editing)) _editing = null;
    if (gone(_confirming)) _confirming = null;
    // The same rule for rules: one removed here, or by the label going with it.
    bool ruleGone(String? id) =>
        id != null && !widget.rules.any((rule) => rule.id == id);
    if (ruleGone(_changingRule)) _changingRule = null;
    if (ruleGone(_confirmingRule)) _confirmingRule = null;
  }

  @override
  Widget build(BuildContext context) => SettingsSection(
        title: LabelsSection.title,
        summary: LabelsSection.summaryOf(
          widget.labels,
          rules: _rulesByLabel.values.fold(0, (n, rules) => n + rules.length),
        ),
        expanded: widget.expanded,
        onToggle: widget.onToggle,
        body: _body(),
      );

  Widget _body() {
    final error = widget.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The words you file threads under. Labels are yours — nothing the '
          'model decides appears here — and renaming one keeps it on every '
          'thread it is already on.',
          style: BondType.caption.copyWith(color: BondColors.inkSecondary),
        ),
        // Under the row being renamed when there is one, because that is where
        // a refused name has to be read; at the top otherwise, where a failed
        // re-read belongs.
        if (error != null && _editing == null) ...[
          const SizedBox(height: BondSpacing.s12),
          InlineAlert(severity: InlineAlertSeverity.error, text: error),
        ],
        if (widget.loading) ...[
          const SizedBox(height: BondSpacing.s12),
          Text(
            'Loading…',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        ],
        if (widget.labels.isEmpty && !widget.loading) ...[
          const SizedBox(height: BondSpacing.s12),
          Text(
            'Nothing filed yet. Dismiss a thread with a word and it turns up '
            'here.',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        ],
        for (final label in widget.labels)
          _row(label, _rulesByLabel[label.id] ?? const []),
      ],
    );
  }

  Widget _row(Label label, List<LabelRule> rules) {
    final editing = _editing == label.id;
    return Padding(
      key: LabelsSection.rowKeyFor(label.id),
      padding: const EdgeInsets.only(top: BondSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LabelToneSwatch(tone: labelToneOf(label.tone)),
              const SizedBox(width: BondSpacing.s8),
              Expanded(
                child: Text(
                  label.name,
                  style: BondType.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            label.useCount == 0
                ? 'Not used yet'
                : 'Used ${LabelsSection.plural(label.useCount, 'time')}',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
          if (editing) _renameField(label),
          const SizedBox(height: BondSpacing.s4),
          _controls(label, editing),
          for (final rule in rules) _ruleRow(rule),
        ],
      ),
    );
  }

  /// One standing rule under the label it files under, indented so it reads as
  /// something the label DOES rather than as another label.
  ///
  /// The sentence is [LabelsSection.ruleWords] and the two answers are the two
  /// things a reader can want: change what it does, or stop it. Nothing here
  /// edits the SCOPE — a rule about a different sender is a different rule, and
  /// the place to write one is the thread it is about, where the reader can see
  /// what they are deciding from.
  Widget _ruleRow(LabelRule rule) {
    // A disposition this build has no segment for — a rule a later one wrote —
    // reads in words and cannot be edited here: `SegmentedButton` asserts on a
    // selected value that is not among its segments, so the control is absent
    // rather than fatal. Remove still works, which is the way out.
    final onChanged = _knownDispositions.contains(rule.disposition)
        ? widget.onRuleDispositionChanged
        : null;
    final changing = _changingRule == rule.id;
    return Padding(
      key: LabelsSection.ruleRowKeyFor(rule.id),
      padding: const EdgeInsets.only(left: BondSpacing.s16, top: BondSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            LabelsSection.ruleWords(rule),
            style: BondType.caption.copyWith(color: BondColors.inkSecondary),
          ),
          Wrap(
            spacing: BondSpacing.s12,
            runSpacing: BondSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (onChanged != null)
                TextButton(
                  key: LabelsSection.ruleChangeKeyFor(rule.id),
                  onPressed: () => setState(
                    () => _changingRule = changing ? null : rule.id,
                  ),
                  child: Text(changing ? 'Done' : 'Change'),
                ),
              if (widget.onDeleteRule != null) _ruleRemoveControls(rule),
            ],
          ),
          if (onChanged != null && changing)
            SettingsSegments<String>(
              key: LabelsSection.ruleDispositionKeyFor(rule.id),
              segments: const [
                (value: LabelRule.hideNeedsYou, label: 'Hide'),
                (value: LabelRule.sendToLater, label: 'Later'),
                (value: LabelRule.dropAtGate, label: 'Drop'),
              ],
              selected: rule.disposition,
              onChanged: (disposition) {
                setState(() => _changingRule = null);
                onChanged(rule.id, disposition);
              },
              caption: 'Drop is the only one that costs a message its reading; '
                  'the other two move a thread the app has already read.',
            ),
        ],
      ),
    );
  }

  /// The label row's own two-tap Remove, for a rule.
  Widget _ruleRemoveControls(LabelRule rule) {
    final onDeleteRule = widget.onDeleteRule!;
    if (_confirmingRule != rule.id) {
      return TextButton(
        key: LabelsSection.ruleRemoveKeyFor(rule.id),
        onPressed: () => setState(() => _confirmingRule = rule.id),
        child: const Text('Remove rule'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: BondSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              key: LabelsSection.ruleConfirmRemoveKeyFor(rule.id),
              style: TextButton.styleFrom(foregroundColor: BondColors.error),
              onPressed: () {
                setState(() {
                  _confirmingRule = null;
                  if (_changingRule == rule.id) _changingRule = null;
                });
                onDeleteRule(rule.id);
              },
              child: const Text('Stop this rule'),
            ),
            TextButton(
              key: LabelsSection.ruleKeepKeyFor(rule.id),
              onPressed: () => setState(() => _confirmingRule = null),
              child: const Text('Keep'),
            ),
          ],
        ),
        Text(
          'Stops it filing anything new. The word stays, and so do the threads '
          'it has already filed.',
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      ],
    );
  }

  Widget _renameField(Label label) {
    final error = widget.error;
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: LabelsSection.nameFieldKeyFor(label.id),
            controller: _name,
            autofocus: true,
            style: BondType.body,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Label name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(label),
          ),
          if (error != null) ...[
            const SizedBox(height: BondSpacing.s4),
            InlineAlert(severity: InlineAlertSeverity.error, text: error),
          ],
        ],
      ),
    );
  }

  Widget _controls(Label label, bool editing) {
    final onRename = widget.onRename;
    final onToneChanged = widget.onToneChanged;
    // A Wrap, not a Row: a long label name plus three controls is wider than
    // the settings column at a large text scale, and a control row that
    // overflows its own section is a Remove nobody can reach.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: BondSpacing.s12,
          runSpacing: BondSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (onRename != null && !editing)
              TextButton(
                key: LabelsSection.renameKeyFor(label.id),
                onPressed: () => setState(() {
                  _editing = label.id;
                  _name.text = label.name;
                }),
                child: const Text('Rename'),
              ),
            if (onRename != null && editing) ...[
              TextButton(
                key: LabelsSection.saveKeyFor(label.id),
                onPressed: _saving ? null : () => _save(label),
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
              TextButton(
                key: LabelsSection.cancelKeyFor(label.id),
                onPressed: _saving ? null : () => setState(() => _editing = null),
                child: const Text('Cancel'),
              ),
            ],
            if (widget.onDelete != null) _removeControls(label),
          ],
        ),
        // Only on the row being renamed: five segments per row would be five
        // rows of buttons on a vocabulary of five words, and the swatch beside
        // the name is what a reader needs the rest of the time.
        if (onToneChanged != null && editing) ...[
          const SizedBox(height: BondSpacing.s4),
          SettingsSegments<BondTone>(
            key: LabelsSection.toneKeyFor(label.id),
            segments: [
              for (final tone in labelTones)
                (value: tone, label: toneLabel(tone)),
            ],
            selected: labelToneOf(label.tone),
            // Stone is the default rather than a colour, so choosing it CLEARS
            // the stored word — a label with no tone and a label the owner set
            // back to plain must not be two different rows in the table.
            onChanged: (tone) => onToneChanged(
              label.id,
              tone == BondTone.neutral ? null : tone.name,
            ),
            caption: 'The tint this label wears on a thread.',
          ),
        ],
      ],
    );
  }

  /// The two-tap Remove the rest of this screen uses: there is no confirmation
  /// dialog, so the protection is that the second click lands on a DIFFERENT
  /// button, in a different place, that did not exist a moment ago.
  Widget _removeControls(Label label) {
    final onDelete = widget.onDelete!;
    if (_confirming != label.id) {
      return TextButton(
        key: LabelsSection.removeKeyFor(label.id),
        onPressed: () => setState(() => _confirming = label.id),
        child: const Text('Remove'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: BondSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              key: LabelsSection.confirmRemoveKeyFor(label.id),
              style: TextButton.styleFrom(foregroundColor: BondColors.error),
              onPressed: () {
                setState(() {
                  _confirming = null;
                  if (_editing == label.id) _editing = null;
                });
                onDelete(label.id);
              },
              child: const Text('Remove label'),
            ),
            TextButton(
              key: LabelsSection.keepKeyFor(label.id),
              onPressed: () => setState(() => _confirming = null),
              child: const Text('Keep'),
            ),
          ],
        ),
        Text(
          'Removes the word and takes it off every thread it is on. The '
          'threads themselves are untouched.',
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      ],
    );
  }

  /// Hands the typed name to the host and closes the field only if it was
  /// taken. A refusal keeps the field open on what was typed, with the host's
  /// own sentence under it — retyping a name to find out it is still taken is
  /// the one thing an inline refusal exists to avoid.
  Future<void> _save(Label label) async {
    final onRename = widget.onRename;
    if (onRename == null || _saving) return;
    final typed = _name.text.trim();
    if (typed.isEmpty || typed == label.name) {
      setState(() => _editing = null);
      return;
    }
    setState(() => _saving = true);
    final renamed = await onRename(label.id, typed);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (renamed) _editing = null;
    });
  }
}
