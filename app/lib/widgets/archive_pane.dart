import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'conversation_list_pane.dart';
import 'later_digest.dart';

/// The three piles Archive holds, in the order they are offered.
enum ArchiveTab { later, done, dropped }

extension ArchiveTabLabel on ArchiveTab {
  String get label => switch (this) {
        ArchiveTab.later => 'Later',
        ArchiveTab.done => 'Done',
        ArchiveTab.dropped => 'Dropped',
      };
}

/// Everything that left the working inbox, and where it went: deferred to a
/// quieter moment, closed, or dropped before it ever asked for anything.
///
/// One section rather than three, because the question a user brings here is
/// "where did that thread go" and they do not know which pile answered it. The
/// tabs are how they look in each without leaving the question.
///
/// The piles do not overlap on screen even though the states do: a thread that
/// was deferred and then closed appears under Done ONLY. `laterRows` — the
/// predicate the Later tab and the rail's day rows share — excludes done
/// threads on purpose, so the same thread is never two answers to the same
/// question. Later is what is still waiting for a quieter moment; a closed
/// thread is not waiting for anything.
///
/// Dumb by construction: props and callbacks only, no `ref` and no provider
/// reads. The screen owns the tab, the selection and every write.
class ArchivePane extends StatelessWidget {
  /// The whole inbox. Each tab picks its own rows out, so the caller never has
  /// to keep three filters in agreement.
  final List<Conversation> conversations;

  /// Which connectors the Done list shows, handed straight to
  /// [ConversationListPane]. The Later tab needs none — its digest re-derives
  /// from what it is given.
  final List<String> sources;

  final ArchiveTab tab;
  final ValueChanged<ArchiveTab> onTab;

  /// A `yyyy-mm-dd` key narrowing the Later tab to one day, or null for every
  /// day. Only the Later tab reads it — a day is a deferral, not a closure.
  final String? dayFilter;

  /// The row's source travels with its id: the host cannot resolve one from
  /// the other, because both connectors mint keys with no knowledge of each
  /// other and a shared key would otherwise open whichever thread the host
  /// happened to scan first.
  final void Function(String source, String conversationId) onOpen;

  /// "This sender belongs in my inbox", by address — the standing correction.
  final void Function(String address, String source) onKeepSender;

  /// "This one thread belongs in my inbox", by `(source, key)`.
  final void Function(String source, String conversationKey) onKeepThread;

  /// Puts a closed thread back into the working inbox.
  final void Function(String source, String conversationKey) onReopen;

  const ArchivePane({
    super.key,
    required this.conversations,
    required this.sources,
    required this.tab,
    required this.onTab,
    required this.dayFilter,
    required this.onOpen,
    required this.onKeepSender,
    required this.onKeepThread,
    required this.onReopen,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final option in ArchiveTab.values) ...[
              BondFilterPill(
                label: option.label,
                selected: option == tab,
                onTap: () => onTab(option),
              ),
              const SizedBox(width: BondSpacing.s8),
            ],
          ],
        ),
        const SizedBox(height: BondSpacing.s16),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() => switch (tab) {
        ArchiveTab.later => LaterDigestPanel(
            conversations: conversations,
            dayFilter: dayFilter,
            onOpen: onOpen,
            onKeepSender: onKeepSender,
            onKeepThread: onKeepThread,
          ),
        ArchiveTab.done => ConversationListPane(
            sources: sources,
            filter: InboxFilter.done,
            conversations: conversations,
            selectedId: null,
            onSelect: onOpen,
            onReopen: onReopen,
          ),
        ArchiveTab.dropped => Center(
            child: Padding(
              padding: const EdgeInsets.all(BondSpacing.s32),
              child: Text(
                'Dropped messages arrive here later this round.',
                style: BondType.small,
                textAlign: TextAlign.center,
              ),
            ),
          ),
      };
}
