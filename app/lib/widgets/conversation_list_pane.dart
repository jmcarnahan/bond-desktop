import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'conversation_row.dart';

/// Which threads the list shows. [open] is the working view — everything not
/// yet resolved, split into what needs the LO and what is waiting on someone
/// else; the other three are single-bucket views of one state.
///
/// It lives beside the bucketing that consumes it rather than on the screen
/// that renders the pills, so the pane does not have to import its parent.
enum InboxFilter { open, needsReply, waiting, done }

extension InboxFilterLabel on InboxFilter {
  String get label => switch (this) {
        InboxFilter.open => 'Open',
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

  const ConversationListPane({
    super.key,
    required this.sources,
    required this.filter,
    required this.conversations,
    required this.selectedId,
    required this.onSelect,
  });

  List<Conversation> _inState(ConversationState state) => [
        for (final c in conversations)
          if (sources.contains(c.source) && c.state == state) c,
      ];

  /// (label, rows) in render order. `open` is the only filter that produces
  /// two sections.
  List<(String, List<Conversation>)> get _sections => switch (filter) {
        InboxFilter.open => [
            ('NEEDS REPLY', _inState(ConversationState.needsReply)),
            ('WAITING', _inState(ConversationState.waiting)),
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
