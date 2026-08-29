import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message_models.dart';
import '../providers/app_providers.dart';
import '../providers/conversations_provider.dart';
import '../services/graph_auth.dart';
import '../theme/tokens.dart';
import '../widgets/chips.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/inline_alert.dart';
import '../widgets/thread_detail_panel.dart';

/// The whole app, for now: a filtered thread list beside the selected
/// thread's transcript.
///
/// Every row on screen comes from sqlite, which the Graph delta sync fills in
/// behind it. The screen never waits on the network to render: it reads what
/// is stored, asks for a refresh, and shows a banner if that refresh did not
/// land.
class InboxScreen extends ConsumerStatefulWidget {
  /// Fired after the stored credentials are cleared, so the gate above can
  /// swap back to the sign-in screen.
  final VoidCallback? onSignedOut;

  const InboxScreen({super.key, this.onSignedOut});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  /// Below this the thread panel cannot hold a 560px bubble beside a
  /// readable list, so the layout stacks instead.
  static const double _twoPaneBreakpoint = 960;

  static const List<String> _sources = ['email'];

  /// Slow enough to be invisible on a metered connection, fast enough that a
  /// reply that arrived while the LO was reading feels like it just showed
  /// up. Graph delta calls with nothing new are cheap.
  static const Duration _pollInterval = Duration(seconds: 60);

  InboxFilter _filter = InboxFilter.open;
  String? _selectedId;
  Timer? _poll;

  /// Set once the sign-out route is under way, so a second notification
  /// cannot start it again mid-teardown.
  bool _leaving = false;

  late final Future<AccountInfo?> _account =
      ref.read(graphAuthProvider).storedAccount;

  @override
  void initState() {
    super.initState();
    // A microtask, not a direct call: a provider must not be written to
    // while the first frame's widgets are still being built.
    Future.microtask(_refresh);
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// The list AND whatever thread is open. Refreshing only the list is the
  /// bug that reads as "the app is broken": the row updates, the transcript
  /// beside it does not, and the two disagree on screen.
  void _refresh() {
    if (!mounted) return;
    ref.read(conversationsProvider.notifier).load();
    final selected = _selectedId;
    if (selected != null) {
      ref.read(threadProvider(selected).notifier).load();
    }
  }

  Future<void> _signOut() async {
    await ref.read(graphAuthProvider).signOut();
    widget.onSignedOut?.call();
  }

  void _select(String id) {
    setState(() => _selectedId = id);
    ref.read(threadProvider(id).notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    // The one failure the user can act on. Routed from a listener rather
    // than from build so the parent's setState never lands mid-build.
    //
    // It signs out rather than merely notifying: the gate above decides what
    // to show by reading stored credentials, and a missing CONSENT leaves a
    // perfectly valid refresh token behind. Notifying without clearing it
    // would bounce the user straight back here and loop.
    ref.listen<ConversationsState>(conversationsProvider, (_, next) {
      if (next is ConversationsError && next.signedOut && !_leaving) {
        _leaving = true;
        _signOut();
      }
    });

    final state = ref.watch(conversationsProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: BondSpacing.s16),
              Expanded(child: _body(state)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ConversationsState state) {
    switch (state) {
      case ConversationsInitial():
      case ConversationsLoading():
        return const Center(child: CircularProgressIndicator());

      case ConversationsError(:final message):
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, style: BondType.small, textAlign: TextAlign.center),
                const SizedBox(height: BondSpacing.s12),
                TextButton(onPressed: _refresh, child: const Text('Retry')),
              ],
            ),
          ),
        );

      case ConversationsLoaded(:final conversations, :final loadError):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (loadError != null) ...[
              InlineAlert(
                severity: InlineAlertSeverity.error,
                text: loadError,
                maxLines: 2,
                action: TextButton(
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              ),
              const SizedBox(height: BondSpacing.s12),
            ],
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    constraints.maxWidth >= _twoPaneBreakpoint
                        ? _wide(conversations)
                        : _narrow(conversations),
              ),
            ),
          ],
        );
    }
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
        IconButton(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
        ),
        FutureBuilder<AccountInfo?>(
          future: _account,
          builder: (context, snapshot) {
            final name = snapshot.data?.displayName ?? '';
            if (name.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(left: BondSpacing.s8),
              child: Text(name, style: BondType.caption),
            );
          },
        ),
        const SizedBox(width: BondSpacing.s8),
        TextButton(
          onPressed: _signOut,
          child: Text('Sign out', style: BondType.caption),
        ),
      ],
    );
  }

  Widget _list(List<Conversation> conversations) => ConversationListPane(
        sources: _sources,
        filter: _filter,
        conversations: conversations,
        selectedId: _selectedId,
        onSelect: _select,
      );

  Conversation? _selected(List<Conversation> conversations) {
    for (final c in conversations) {
      if (c.id == _selectedId) return c;
    }
    // A thread can leave the list between renders — a filter change, or a
    // sync that moved it. The panel closes rather than showing a stale copy.
    return null;
  }

  Widget? _panel(List<Conversation> conversations) {
    final selected = _selected(conversations);
    if (selected == null) return null;

    final thread = ref.watch(threadProvider(selected.id));

    // The transcript is a sqlite read, so it is only ever genuinely absent
    // on the very first open of a thread, while its bodies are fetched.
    if (thread is ThreadInitial || thread is ThreadLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final (List<Message> messages, String? error) = switch (thread) {
      ThreadLoaded(:final messages, :final loadError) => (messages, loadError),
      ThreadError(:final message) => (const <Message>[], message),
      _ => (const <Message>[], null),
    };

    final panel = ThreadDetailPanel(
      key: ValueKey(selected.id),
      conversation: selected,
      messages: messages,
      onMarkDone: () =>
          ref.read(conversationsProvider.notifier).markDone(selected.id),
    );

    if (error == null) return panel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InlineAlert(
          severity: InlineAlertSeverity.error,
          text: error,
          maxLines: 2,
        ),
        const SizedBox(height: BondSpacing.s12),
        Expanded(child: panel),
      ],
    );
  }

  Widget _wide(List<Conversation> conversations) {
    final panel = _panel(conversations);
    // SEAM: a future source rail (Email / Teams channels) inserts HERE as a
    // fixed-width sibling.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _list(conversations)),
        if (panel != null) ...[
          const SizedBox(width: BondSpacing.s16),
          SizedBox(width: 420, child: panel),
        ],
      ],
    );
  }

  Widget _narrow(List<Conversation> conversations) {
    final panel = _panel(conversations);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _list(conversations)),
        if (panel != null) ...[
          const SizedBox(height: BondSpacing.s16),
          Expanded(child: panel),
        ],
      ],
    );
  }
}
