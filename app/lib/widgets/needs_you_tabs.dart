import 'package:flutter/material.dart';

import '../models/label_models.dart';
import '../models/message_models.dart';
import '../services/deadline_parse.dart' show showableDeadline;
import '../theme/tokens.dart';
import 'app_rail.dart' show isWaitingRow;
import 'chips.dart';

/// The pile's ORDER travels with its lenses: everything that draws Needs You
/// already imports this file, and the enum lives in `models/` only so the
/// preference that stores it need not import a widget.
export '../models/needs_you_sort.dart';

/// The five ways to read the Needs You pile.
///
/// [all] leads and is the default, so arriving at the stop shows exactly what
/// it always showed — the ranked list. The other four are lenses on that same
/// list and never on a different one: each answers a question the ranking
/// cannot ("what is somebody waiting on ME for", "what has a date on it"), and
/// a tab that went back to the store for its own rows would eventually
/// disagree with the badge over the section.
enum NeedsYouTab { all, askedOfMe, waitingOnOthers, deadlines, suggestedDrafts }

extension NeedsYouTabLabel on NeedsYouTab {
  String get label => switch (this) {
        NeedsYouTab.all => 'All',
        NeedsYouTab.askedOfMe => 'Asked of me',
        NeedsYouTab.waitingOnOthers => 'Waiting on others',
        NeedsYouTab.deadlines => 'Deadlines',
        NeedsYouTab.suggestedDrafts => 'Suggested drafts',
      };

  /// What an empty tab says. A sentence per lens rather than one "Nothing
  /// here." for all five, because an empty Deadlines tab and an empty Asked
  /// of me tab are different pieces of good news, and the reader picked the
  /// tab to hear that piece.
  String get emptyText => switch (this) {
        NeedsYouTab.all => 'Nothing needs you right now.',
        NeedsYouTab.askedOfMe => 'Nobody has asked you for anything.',
        NeedsYouTab.waitingOnOthers => 'You are not waiting on anyone.',
        NeedsYouTab.deadlines => 'Nothing here names a deadline.',
        NeedsYouTab.suggestedDrafts => 'No drafts waiting to be sent.',
      };
}

/// One tab's rows, out of the Needs You list the rail and the overview share.
///
/// The input is [needsYouRows]' output — already filtered by the attention
/// threshold and already ranked — and the ORDER SURVIVES. That is the contract
/// that makes these tabs cheap: they are filters over a ranking that was
/// decided once, so the third row on Deadlines is the same thread it was on
/// All, and a reader who switches tabs is not re-reading a reshuffled pile.
///
/// The two halves are complements of one predicate, as Needs You itself is:
/// [NeedsYouTab.askedOfMe] is everything [isWaitingRow] denies, and
/// [NeedsYouTab.waitingOnOthers] is everything it claims — so every row is on
/// exactly one of the two and the counts add up to [NeedsYouTab.all].
List<Conversation> needsYouTabRows(NeedsYouTab tab, List<Conversation> rows,
        {DateTime? now}) =>
    switch (tab) {
      NeedsYouTab.all => rows,
      NeedsYouTab.askedOfMe => [
          for (final c in rows)
            if (!isWaitingRow(c)) c,
        ],
      NeedsYouTab.waitingOnOthers => [
          for (final c in rows)
            if (isWaitingRow(c)) c,
        ],
      // Through [showableDeadline]: a plan-relative phrase the extractor
      // repeated ("Day 1") is not a date, and a tab the reader picked
      // BECAUSE every row has a date on it must not seat rows that don't.
      // The caption over these rows prints `latestDeadline` raw, which is
      // safe exactly because membership and caption read the same field.
      NeedsYouTab.deadlines => [
          for (final c in rows)
            if (showableDeadline(c.latestDeadline, now: now ?? DateTime.now())
                != null)
              c,
        ],
      NeedsYouTab.suggestedDrafts => [
          for (final c in rows)
            if (c.pendingDraftCount > 0) c,
        ],
    };

/// The rows of the pile filed under one label, or the pile itself when nothing
/// is picked.
///
/// A SIXTH filter over the same ranking and not a sixth tab: a label answers a
/// different question from the five lenses ("what is this about" rather than
/// "who is waiting"), so it narrows whichever lens the reader is already on
/// rather than replacing it. The order survives, for the reason every function
/// above keeps it: the ranking was decided once.
///
/// A null [labelId] is the identity, which is what makes an unpicked filter row
/// the unfiltered pile. So is an id no row carries — a label the owner deleted
/// while the pill was pressed narrows to nothing rather than throwing, and the
/// tab's own empty sentence is what the reader sees.
List<Conversation> needsYouLabelRows(String? labelId, List<Conversation> rows) {
  if (labelId == null || labelId.isEmpty) return rows;
  return [
    for (final c in rows)
      if (c.labels.any((l) => l.id == labelId)) c,
  ];
}

/// The owner's words as a second pill row under the five tabs.
///
/// Additive in the strict sense: an owner who has never made a label passes an
/// empty list and this draws NOTHING — not an empty row, not a gap — so the
/// Needs You header is exactly what it was before labels existed.
///
/// Single-select and self-clearing, unlike [BondFilterPillRow] above it: the
/// tabs partition the pile so one of them is always on, while a label filter's
/// resting state is off. Pressing the pressed pill is how it goes back off,
/// which is why [onLabelSelected] takes a nullable id.
class NeedsYouLabelFilter extends StatelessWidget {
  /// The vocabulary, in `labelsProvider`'s order — most used first, so the
  /// words the owner actually files under lead the row.
  final List<Label> labels;

  /// Which label is narrowing the pile, or null for the whole pile.
  final String? selectedLabelId;

  /// Fired with the pressed label's id, or with null when the press was on the
  /// already-selected pill. Null leaves every pill inert, the house discipline
  /// for a control whose host cannot act on it.
  final ValueChanged<String?>? onLabelSelected;

  const NeedsYouLabelFilter({
    super.key,
    this.labels = const [],
    this.selectedLabelId,
    this.onLabelSelected,
  });

  /// The row itself, for a test that wants to assert it is absent.
  static const Key rowKey = ValueKey('needs-you-label-filter');

  static ValueKey<String> pillKeyFor(String id) =>
      ValueKey('needs-you-label-$id');

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final onSelected = onLabelSelected;
    return Padding(
      key: rowKey,
      padding: const EdgeInsets.only(top: BondSpacing.s8),
      child: Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s8,
        children: [
          for (final label in labels)
            BondFilterPill(
              key: pillKeyFor(label.id),
              label: label.name,
              selected: label.id == selectedLabelId,
              onTap: onSelected == null
                  ? null
                  : () => onSelected(
                        label.id == selectedLabelId ? null : label.id,
                      ),
            ),
        ],
      ),
    );
  }
}
