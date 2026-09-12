import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'conversation_row.dart';

/// Which threads the list shows. [open] is the working view — everything not
/// yet resolved, split into what needs the user and what is waiting on someone
/// else; the rest are single-bucket views.
///
/// [needsAction] is the model's view rather than the thread state machine's:
/// it cuts across `needs_reply` and `waiting` and shows only what triage left
/// an ask on.
///
/// It lives beside the bucketing that consumes it rather than on the screen
/// that renders the pills, so the pane does not have to import its parent.
enum InboxFilter { open, needsAction, needsReply, waiting, done }

extension InboxFilterLabel on InboxFilter {
  String get label => switch (this) {
        InboxFilter.open => 'Open',
        InboxFilter.needsAction => 'Needs action',
        InboxFilter.needsReply => 'Needs reply',
        InboxFilter.waiting => 'Waiting',
        InboxFilter.done => 'Done',
      };
}

/// The left pane: section headers and thread rows in one flat scroll.
class ConversationListPane extends StatelessWidget {
  /// Which connectors to show. Email-only today; the source rail will pass a
  /// wider set without this widget changing.
  final List<String> sources;

  final InboxFilter filter;
  final List<Conversation> conversations;
  final String? selectedId;

  /// The open thread's connector. A conversation key is unique only within one
  /// source, so a bare [selectedId] can match a row from the other connector
  /// and highlight it too. Null keeps the id-only comparison, which is what a
  /// host with a single connector wants.
  final String? selectedSource;

  /// The row's source travels with its id: the host cannot resolve one from
  /// the other, because both connectors mint keys with no knowledge of each
  /// other and a shared key would otherwise open whichever thread the host
  /// happened to scan first.
  final void Function(String source, String conversationId) onSelect;

  /// Sections the caller has already bucketed, rendered instead of anything
  /// this pane would compute. The rail's sections do not line up with the
  /// filter enum, and forcing them to would mean inventing filter values
  /// nothing else uses. Null leaves [filter] in charge.
  final List<(String, List<Conversation>)>? sectionsOverride;

  /// When this session started, handed down to every row. Null shows no
  /// processing hints at all.
  final DateTime? processingSince;

  /// Puts a closed thread back into the working inbox. Offered on the DONE
  /// section only, and only when a host passed one — a Reopen beside a live
  /// thread is an action with nothing to undo.
  final void Function(String source, String conversationKey)? onReopen;

  /// A second line for one row, in place of the one it would draw for itself —
  /// see [ConversationRow.caption]. Null, the default, leaves every row saying
  /// what it always says; a builder that answers null for a given row does the
  /// same for that one.
  final String? Function(Conversation)? captionFor;

  /// What an empty pane says. The default is the plain fact; a host with a
  /// narrower list to draw — one tab of Needs You — says what that tab's
  /// emptiness means.
  final String emptyText;

  /// Drawn under [emptyText] when the pane is empty — the host's line about
  /// WHY it might be, and the way out. Null draws nothing. Here rather than
  /// in the sentence because the reason is the host's (a source filter it
  /// owns) and the pane must not pretend to know it.
  final Widget? emptyNotice;

  const ConversationListPane({
    super.key,
    required this.sources,
    required this.filter,
    required this.conversations,
    required this.selectedId,
    required this.onSelect,
    this.selectedSource,
    this.sectionsOverride,
    this.processingSince,
    this.onReopen,
    this.captionFor,
    this.emptyText = 'Nothing here.',
    this.emptyNotice,
  });

  List<Conversation> _inState(ConversationState state) => [
        for (final c in conversations)
          if (sources.contains(c.source) && c.state == state) c,
      ];

  /// Threads triage left an ask on, in any state but done. A CTA on a thread
  /// the user already closed is history, not work — and `cta_text` is set only
  /// from a result that either named an action item or said the message needs
  /// one, so its presence IS the model's needs-action answer folded up.
  List<Conversation> get _needsAction => [
        for (final c in conversations)
          if (sources.contains(c.source) &&
              c.state != ConversationState.done &&
              c.ctaText?.isNotEmpty == true)
            c,
      ];

  /// (label, rows) in render order. `open` is the only filter that produces
  /// two sections.
  List<(String, List<Conversation>)> get _sections =>
      sectionsOverride ?? _byFilter;

  List<(String, List<Conversation>)> get _byFilter => switch (filter) {
        InboxFilter.open => [
            ('NEEDS REPLY', _inState(ConversationState.needsReply)),
            ('WAITING', _inState(ConversationState.waiting)),
          ],
        InboxFilter.needsAction => [
            ('NEEDS ACTION', _needsAction),
          ],
        InboxFilter.needsReply => [
            ('NEEDS REPLY', _inState(ConversationState.needsReply)),
          ],
        InboxFilter.waiting => [
            ('WAITING', _inState(ConversationState.waiting)),
          ],
        InboxFilter.done => [
            ('DONE', _inState(ConversationState.done)),
          ],
      };

  /// Whether rows carry a Reopen. The done section as THIS pane bucketed it,
  /// never a section a host labelled 'DONE' through [sectionsOverride] — the
  /// rows under an override are the caller's own, and reopening a live thread
  /// does nothing anyone asked for.
  bool get _showReopen =>
      onReopen != null && sectionsOverride == null && filter == InboxFilter.done;

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final total = sections.fold<int>(0, (n, s) => n + s.$2.length);

    if (total == 0) {
      final notice = emptyNotice;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                emptyText,
                style: BondType.small,
                textAlign: TextAlign.center,
              ),
              if (notice != null) ...[
                const SizedBox(height: BondSpacing.s8),
                notice,
              ],
            ],
          ),
        ),
      );
    }

    // Flattened to one index of header/row entries, then built lazily. A
    // section with no rows contributes nothing — in the two-section `open` view
    // an empty half just pushes the other half down. Building the entry list is
    // cheap (records, not widgets); the win is `ListView.builder` materialising
    // only the rows on screen. The eager `ListView(children:)` this replaced
    // built a widget for every thread up front, which on a mailbox with
    // thousands of "Done" threads exhausted the GPU and crashed the app.
    final entries = <_PaneEntry>[];
    for (final (label, rows) in sections) {
      if (rows.isEmpty) continue;
      entries.add(_HeaderEntry(label, rows.length));
      for (final c in rows) {
        entries.add(_RowEntry(c));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: BondSpacing.s24),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        if (entry is _HeaderEntry) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              BondSpacing.s4,
              BondSpacing.s16,
              BondSpacing.s4,
              BondSpacing.s8,
            ),
            child: Row(
              children: [
                Text(entry.label, style: BondType.label),
                const SizedBox(width: BondSpacing.s8),
                Text('${entry.count}', style: BondType.caption),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s8),
          child: _row((entry as _RowEntry).conversation),
        );
      },
    );
  }

  /// One thread's card, with Reopen beside it where the section offers one.
  /// The button sits outside the card rather than in it: [ConversationRow] is
  /// the same row everywhere it appears, and a card that grows an action in
  /// one list is a card that reads differently in the others.
  Widget _row(Conversation c) {
    final row = ConversationRow(
      conversation: c,
      selected: c.id == selectedId &&
          (selectedSource == null || selectedSource == c.source),
      onTap: () => onSelect(c.source, c.id),
      processingSince: processingSince,
      caption: captionFor?.call(c),
    );
    if (!_showReopen) return row;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: row),
        const SizedBox(width: BondSpacing.s8),
        TextButton(
          onPressed: () => onReopen!(c.source, c.id),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Reopen'),
        ),
      ],
    );
  }
}

/// One line in the pane's flattened, lazily-built list: a section header or a
/// thread row. Flattening is what lets a `ListView.builder` render only the
/// entries on screen instead of a widget per thread.
sealed class _PaneEntry {
  const _PaneEntry();
}

class _HeaderEntry extends _PaneEntry {
  final String label;
  final int count;
  const _HeaderEntry(this.label, this.count);
}

class _RowEntry extends _PaneEntry {
  final Conversation conversation;
  const _RowEntry(this.conversation);
}
