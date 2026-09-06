import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'time_format.dart' show absoluteDay;

/// How far back one connector reaches, as a picker over the day counts worth
/// a preset and a field for anything else.
///
/// The control the user actually reads is the line under it: a number of days
/// is a span, and the question somebody asking for "three months" is really
/// asking is which morning the mailbox starts on. So the resolved day is
/// rendered in every mode, from the same arithmetic the sync uses — UTC
/// midnight minus the day count.
///
/// Prop-only, like everything else on the settings screen: it holds the day
/// count it is showing and the text being typed, and reports every commit
/// upward. The host owns the preference.
class LookbackField extends StatefulWidget {
  /// Which connector this is — 'Mail' or 'Teams'. It is the dropdown's label,
  /// so the two fields are told apart by the thing they configure.
  final String label;

  /// The stored lookback, in days.
  final int days;

  /// The clock the resolved day is measured from. A value rather than a
  /// closure because the screen already resolves `now` once per build, so
  /// every date on the pane is measured against the same instant.
  final DateTime now;

  /// Fired on every commit — a preset pick, or a custom date that parsed.
  /// Never per keystroke: each call is a preference write and a wider window
  /// re-drains history at the next sync.
  final void Function(int days) onChanged;

  /// The key base. The dropdown is `ValueKey(fieldKey)` and the custom field
  /// `ValueKey('$fieldKey-custom')`: two of these sit on one screen with
  /// identical control labels, so a test has to name the side it means.
  final String fieldKey;

  const LookbackField({
    super.key,
    required this.label,
    required this.days,
    required this.now,
    required this.onChanged,
    required this.fieldKey,
  });

  /// The day counts worth a click. Not a scale of anything — they are the
  /// spans people ask for out loud, a week through a quarter.
  static const List<int> presets = [7, 14, 30, 60, 90];

  /// The dropdown value that means "none of the presets": a sentinel rather
  /// than a null entry, because a null selection renders as an empty row and
  /// reads as a control that has not been set.
  static const int customSentinel = -1;

  @override
  LookbackFieldState createState() => LookbackFieldState();
}

/// Public, not private, for exactly one reason: the screen has to reach
/// [commitPending] through a [GlobalKey] from Back, Home and the section's own
/// Collapse — the same three clicks that take the custom server URL off the
/// screen, and for the same reason — see `commitPendingServerUrl` in
/// `settings_connection_section.dart`, which holds the long version of why a
/// field that is about to be unmounted has to be asked for its text first.
class LookbackFieldState extends State<LookbackField> {
  /// The day count the control is showing. Local like the screen's other
  /// instant controls: the resolved line under the field has to move with the
  /// pick, and the host's rebuild is not what the user is waiting on.
  late int _days = widget.days;

  /// Which of the choices is showing. Computed defensively — a stored value
  /// outside [LookbackField.presets] opens on Custom…, because handing the
  /// dropdown a value none of its items carries is an assertion failure, not a
  /// blank row. Held rather than derived per build so that picking Custom…
  /// keeps the field open while the typed date still matches a preset, exactly
  /// as the server picker does.
  late int _preset = LookbackField.presets.contains(widget.days)
      ? widget.days
      : LookbackField.customSentinel;

  /// Prefilled with the day the current count resolves to, so Custom… opens on
  /// the window that is in force rather than on an empty field.
  late final TextEditingController _custom = TextEditingController(
    text: _dateTextFor(_days),
  );

  /// The last count actually handed to the host. Pressing Enter both submits
  /// and drops focus, so without this one keystroke would commit twice.
  late int _committedDays = widget.days;

  /// What is wrong with what is in the field, shown as its `errorText` and
  /// cleared by the next commit that parses.
  String? _error;

  static const String _errorText =
      'Use YYYY-MM-DD, a past date within the last year';

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  /// Today at UTC midnight. Everything here is done on that instant so the
  /// date and the day count round-trip exactly, and so the day this control
  /// names is the same day the sync's own truncation reaches.
  DateTime get _todayUtc {
    final utc = widget.now.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day);
  }

  DateTime _dateFor(int days) => _todayUtc.subtract(Duration(days: days));

  String _dateTextFor(int days) {
    final date = _dateFor(days);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  /// The day count [text] names, or null when it names none.
  ///
  /// Strict on purpose: `DateTime.parse` accepts times and offsets, and
  /// `DateTime.utc` silently rolls 2026-02-31 forward into March. So the shape
  /// is matched first and the components are checked to have survived the
  /// construction. A date today or later, or further back than a year, is not
  /// a window this app will sync and is refused here rather than clamped —
  /// silently syncing a different span than the one on screen is worse than
  /// saying no.
  int? _daysFor(String text) {
    final trimmed = text.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) return null;
    final year = int.parse(trimmed.substring(0, 4));
    final month = int.parse(trimmed.substring(5, 7));
    final day = int.parse(trimmed.substring(8, 10));
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    final days = _todayUtc.difference(date).inDays;
    if (days < 1 || days > 365) return null;
    return days;
  }

  /// Commits whatever is in the custom field, if that field is on screen at
  /// all.
  ///
  /// [Focus.onFocusChange] covers a user who moves to another control. It does
  /// NOT cover the field being removed from the tree — Back, Home and
  /// collapsing the section all do that without ever moving focus, and Flutter
  /// fires no unfocus on dispose. Those three call this while they are still
  /// ordinary event handlers, so the provider write happens outside the frame
  /// that is unmounting the tree.
  void commitPending() {
    if (_preset != LookbackField.customSentinel) return;
    _commitCustom(_custom.text);
  }

  void _commitCustom(String text) {
    final days = _daysFor(text);
    if (days == null) {
      setState(() => _error = _errorText);
      return;
    }
    if (days == _committedDays) {
      // Already the window in force — the field was left as it was found, or
      // Enter fired the submit and the blur behind it.
      if (_error != null) setState(() => _error = null);
      return;
    }
    _committedDays = days;
    setState(() {
      _days = days;
      _error = null;
    });
    widget.onChanged(days);
  }

  void _pick(int value) {
    setState(() {
      _preset = value;
      // Custom… only reveals the field. What is in it is the window already in
      // force, so there is nothing to commit until somebody types.
      if (value == LookbackField.customSentinel) return;
      _days = value;
      _custom.text = _dateTextFor(value);
      _error = null;
    });
    if (value == LookbackField.customSentinel) return;
    if (value == _committedDays) return;
    _committedDays = value;
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey(widget.fieldKey),
          initialValue: _preset,
          decoration: InputDecoration(labelText: widget.label),
          items: [
            for (final preset in LookbackField.presets)
              DropdownMenuItem(value: preset, child: Text('$preset days')),
            const DropdownMenuItem(
              value: LookbackField.customSentinel,
              child: Text('Custom…'),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            _pick(value);
          },
        ),
        if (_preset == LookbackField.customSentinel) ...[
          const SizedBox(height: BondSpacing.s8),
          // Committed on Enter or on the way out of the field, never per
          // keystroke: a half-typed date is not a window, and 2026-08 is a
          // year and a month with nothing to sync between them.
          //
          // Keep the Focus node. onTapOutside would not cover leaving by the
          // back arrow, which is the way out that loses the most typing.
          Focus(
            onFocusChange: (hasFocus) {
              if (!hasFocus) _commitCustom(_custom.text);
            },
            child: TextField(
              key: ValueKey('${widget.fieldKey}-custom'),
              controller: _custom,
              onSubmitted: _commitCustom,
              decoration: InputDecoration(
                labelText: 'Since date',
                hintText: 'YYYY-MM-DD',
                errorText: _error,
              ),
            ),
          ),
        ],
        const SizedBox(height: BondSpacing.s4),
        // Rendered in every mode, preset included: the span is what was
        // chosen, but the day is what the user is actually asking about.
        Text(
          'Last $_days days · since ${absoluteDay(_dateFor(_days))}',
          style: BondType.caption,
        ),
      ],
    );
  }
}
