import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/fixtures.dart';
import '../models/message_models.dart';
import '../theme/tokens.dart';
import '../widgets/chips.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/thread_detail_panel.dart';

/// The whole app, for now: a filtered thread list beside the selected
/// thread's transcript.
///
/// Phase 1 reads the hardcoded fixtures directly and keeps its own mutable
/// copy so Mark done has something to change. Phase 3 swaps this for the
/// sqlite-backed providers; nothing below the screen changes when it does.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  /// Below this the thread panel cannot hold a 560px bubble beside a
  /// readable list, so the layout stacks instead.
  static const double _twoPaneBreakpoint = 960;

  static const List<String> _sources = ['email'];

  late List<Conversation> _conversations = List.of(fixtureConversations);
  InboxFilter _filter = InboxFilter.open;
  String? _selectedId;

  Conversation? get _selected {
    for (final c in _conversations) {
      if (c.id == _selectedId) return c;
    }
    return null;
  }

  void _markDone(String id) {
    setState(() {
      _conversations = [
        for (final c in _conversations)
          if (c.id == id) c.copyWith(state: ConversationState.done) else c,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: BondSpacing.s16),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      constraints.maxWidth >= _twoPaneBreakpoint
                          ? _wide()
                          : _narrow(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('Inbox', style: BondType.title),
        const SizedBox(width: BondSpacing.s24),
        Expanded(
          child: BondFilterPillRow<InboxFilter>(
            options: InboxFilter.values,
            selected: _filter,
            labelOf: (f) => f.label,
            onSelected: (f) => setState(() => _filter = f),
          ),
        ),
        // Placeholder for the Graph sync that lands in a later phase.
        const IconButton(
          onPressed: null,
          icon: Icon(Icons.refresh),
          tooltip: 'Refresh (not connected yet)',
        ),
      ],
    );
  }

  Widget _list() => ConversationListPane(
        sources: _sources,
        filter: _filter,
        conversations: _conversations,
        selectedId: _selectedId,
        onSelect: (id) => setState(() => _selectedId = id),
      );

  Widget? _panel() {
    final selected = _selected;
    if (selected == null) return null;
    return ThreadDetailPanel(
      key: ValueKey(selected.id),
      conversation: selected,
      messages: fixtureThreads[selected.id] ?? const [],
      onMarkDone: () => _markDone(selected.id),
    );
  }

  Widget _wide() {
    final panel = _panel();
    // SEAM: a future source rail (Email / Teams channels) inserts HERE as a
    // fixed-width sibling.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _list()),
        if (panel != null) ...[
          const SizedBox(width: BondSpacing.s16),
          SizedBox(width: 420, child: panel),
        ],
      ],
    );
  }

  Widget _narrow() {
    final panel = _panel();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _list()),
        if (panel != null) ...[
          const SizedBox(height: BondSpacing.s16),
          Expanded(child: panel),
        ],
      ],
    );
  }
}
