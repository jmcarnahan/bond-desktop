import 'package:flutter/material.dart';

import '../models/label_models.dart';
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'label_chip.dart';
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
/// `labelsProvider` up as, so a test drives the whole section with a list of
/// labels and three closures.
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

  /// `No labels yet` / `1 label` / `3 labels · 12 uses`.
  ///
  /// The use count joins only once something has been filed: a vocabulary
  /// nobody has applied yet would otherwise read `3 labels · 0 uses`, which
  /// says the same thing twice and one of them gloomily.
  ///
  /// Static on the widget rather than on its state, because the collapsed line
  /// is pinned by `settings_screen_test.dart` and by the table in
  /// `docs/settings.md`, and a test has to be able to ask for it without
  /// building a section.
  static String summaryOf(List<Label> labels) {
    if (labels.isEmpty) return 'No labels yet';
    final uses = labels.fold<int>(0, (sum, label) => sum + label.useCount);
    final count = plural(labels.length, 'label');
    return uses == 0 ? count : '$count · ${plural(uses, 'use')}';
  }

  static String plural(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

  @override
  State<LabelsSection> createState() => _LabelsSectionState();
}

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
  }

  @override
  Widget build(BuildContext context) => SettingsSection(
        title: LabelsSection.title,
        summary: LabelsSection.summaryOf(widget.labels),
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
            'Nothing filed yet. Label a thread, or mark it done with a label, '
            'and the word turns up here.',
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
          ),
        ],
        for (final label in widget.labels) _row(label),
      ],
    );
  }

  Widget _row(Label label) {
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
        ],
      ),
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
