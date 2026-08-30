import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'conversation_row.dart';

/// Which threads the list shows. [open] is the working view — everything not
/// yet resolved, split into what needs the LO and what is waiting on someone
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
  final void Function(String) onSelect;

  /// Sections the caller has already bucketed, rendered instead of anything
  /// this pane would compute. The rail's sections do not line up with the
  /// filter enum, and forcing them to would mean inventing filter values
  /// nothing else uses. Null leaves [filter] in charge.
  final List<(String, List<Conversation>)>? sectionsOverride;

  const ConversationListPane({
    super.key,
    required this.sources,
    required this.filter,
    required this.conversations,
    required this.selectedId,
    required this.onSelect,
    this.sectionsOverride,
  });

  List<Conversation> _inState(ConversationState state) => [
        for (final c in conversations)
          if (sources.contains(c.source) && c.state == state) c,
      ];

  /// Threads triage left an ask on, in any state but done. A CTA on a thread
  /// the LO already closed is history, not work — and `cta_text` is set only
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

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final total = sections.fold<int>(0, (n, s) => n + s.$2.length);

    if (total == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s32),
          child: Text(
            'Nothing here.',
            style: BondType.small,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: BondSpacing.s24),
      children: [
        for (final (label, rows) in sections)
          // A section with no rows says nothing worth the vertical space —
          // in the two-section `open` view an empty half just pushes the
          // other half down.
          if (rows.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BondSpacing.s4,
                BondSpacing.s16,
                BondSpacing.s4,
                BondSpacing.s8,
              ),
              child: Row(
                children: [
                  Text(label, style: BondType.label),
                  const SizedBox(width: BondSpacing.s8),
                  Text('${rows.length}', style: BondType.caption),
                ],
              ),
            ),
            for (final c in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: BondSpacing.s8),
                child: ConversationRow(
                  conversation: c,
                  selected: c.id == selectedId,
                  onTap: () => onSelect(c.id),
                ),
              ),
          ],
      ],
    );
  }
}
