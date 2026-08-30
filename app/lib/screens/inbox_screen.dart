import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../providers/app_providers.dart';
import '../providers/conversations_provider.dart';
import '../providers/storylines_provider.dart';
import '../services/graph_auth.dart';
import '../services/triage_queue.dart';
import '../theme/tokens.dart';
import '../widgets/app_rail.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/inline_alert.dart';
import '../widgets/storyline_timeline.dart';
import '../widgets/thread_detail_panel.dart';

/// The whole app, for now: a dark rail of sections beside one main pane that
/// shows either a section's threads or the open thread's transcript.
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
  /// Below this the rail and a readable transcript cannot share the width, so
  /// the rail becomes an overlay the hamburger opens.
  static const double _twoPaneBreakpoint = 960;

  static const List<String> _sources = ['email'];

  /// Slow enough to be invisible on a metered connection, fast enough that a
  /// reply that arrived while the LO was reading feels like it just showed
  /// up. Graph delta calls with nothing new are cheap.
  static const Duration _pollInterval = Duration(seconds: 60);

  /// The section overview showing when no thread is open. Never null in
  /// practice — the type only carries the "no explicit choice yet" case.
  RailSection? _section = RailSection.needsYou;
  String? _selectedId;

  /// The open storyline. Never set at the same time as [_selectedId] — the
  /// main pane shows exactly one thing, and the two selections clear each
  /// other rather than racing to be rendered.
  String? _selectedStorylineId;

  /// Narrow layouts only: whether the rail overlay is up.
  bool _railOpen = false;

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
    ref.read(storylinesProvider.notifier).load();
    final selected = _selectedId;
    if (selected != null) {
      ref.read(threadProvider(selected).notifier).load();
    }
    final storyline = _selectedStorylineId;
    if (storyline != null) {
      ref.read(storylineTimelineProvider(storyline).notifier).load();
    }
  }

  Future<void> _signOut() async {
    await ref.read(graphAuthProvider).signOut();
    widget.onSignedOut?.call();
  }

  void _select(String id) {
    setState(() {
      _selectedId = id;
      _selectedStorylineId = null;
      _railOpen = false;
    });
    ref.read(threadProvider(id).notifier).load();
  }

  void _selectStoryline(String id) {
    setState(() {
      _selectedStorylineId = id;
      _selectedId = null;
      _railOpen = false;
    });
    ref.read(storylineTimelineProvider(id).notifier).load();
  }

  void _selectSection(RailSection section) {
    setState(() {
      _section = section;
      _selectedId = null;
      _selectedStorylineId = null;
      _railOpen = false;
    });
  }

  /// The storylines as of this build. Empty until the first load lands, and
  /// empty on a read failure — the rail's own placeholder is the right thing
  /// to show for both.
  List<Storyline> _storylines() {
    final state = ref.watch(storylinesProvider);
    return state is StorylinesLoaded ? state.storylines : const [];
  }

  Storyline? _storylineById(String id) {
    for (final storyline in _storylines()) {
      if (storyline.id == id) return storyline;
    }
    // Kept or dismissed from under the selection, or gone in a reload. The
    // pane falls back to the overview rather than showing a stale copy.
    return null;
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

    return Scaffold(body: SafeArea(child: _body(state)));
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
        return LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth >= _twoPaneBreakpoint
                  ? _wide(conversations, loadError)
                  : _narrow(conversations, loadError),
        );
    }
  }

  Widget _wide(List<Conversation> conversations, String? loadError) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _rail(conversations),
        const SizedBox(width: 1, child: ColoredBox(color: BondColors.border)),
        Expanded(child: _main(conversations, loadError)),
      ],
    );
  }

  /// The rail lifts off the page instead of shoving it aside: at this width
  /// the main pane has nothing to spare.
  Widget _narrow(List<Conversation> conversations, String? loadError) {
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: BondSpacing.s8,
                  top: BondSpacing.s8,
                ),
                child: IconButton(
                  onPressed: () => setState(() => _railOpen = !_railOpen),
                  icon: const Icon(Icons.menu),
                  tooltip: 'Sections',
                ),
              ),
            ),
            Expanded(child: _main(conversations, loadError)),
          ],
        ),
        if (_railOpen) ...[
          // The rail covers the hamburger that opened it, so the scrim has to
          // be the way back out.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _railOpen = false),
              child: const ColoredBox(color: BondColors.inkScrim),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(boxShadow: BondShadows.overlay),
              child: _rail(conversations),
            ),
          ),
        ],
      ],
    );
  }

  Widget _rail(List<Conversation> conversations) {
    return AppRail(
      conversations: conversations,
      storylines: _storylines(),
      selectedId: _selectedId,
      selectedStorylineId: _selectedStorylineId,
      // A thread or a storyline being open means no section overview is
      // showing, so the rail must not highlight one.
      selectedSection: (_selectedId == null && _selectedStorylineId == null)
          ? _section
          : null,
      onSelectConversation: _select,
      onSelectSection: _selectSection,
      onSelectStoryline: _selectStoryline,
      onKeepSuggestion: (id) =>
          ref.read(storylinesProvider.notifier).keep(id),
      onDismissSuggestion: (id) {
        // The dismissed storyline leaves the list, so a selection pointing at
        // it would render nothing. Clearing it here returns the pane to the
        // overview in the same frame the row disappears.
        if (_selectedStorylineId == id) {
          setState(() => _selectedStorylineId = null);
        }
        ref.read(storylinesProvider.notifier).dismiss(id);
      },
      footer: _railFooter(),
    );
  }

  /// Account, refresh, sign-out — everything the old header row carried,
  /// parked at the foot of the rail where it stops competing with the mail.
  Widget _railFooter() {
    // SEAM: source filter chips land in the rail footer (phase 10).
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _triageProgress(),
          Row(
            children: [
              Expanded(
                child: FutureBuilder<AccountInfo?>(
                  future: _account,
                  builder: (context, snapshot) {
                    final name = snapshot.data?.displayName ?? '';
                    if (name.isEmpty) return const SizedBox.shrink();
                    return Text(
                      name,
                      style: BondType.caption
                          .copyWith(color: BondColors.onDarkSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                ),
              ),
              _railAction(Icons.refresh, 'Refresh', _refresh),
              _railAction(Icons.logout, 'Sign out', _signOut),
            ],
          ),
        ],
      ),
    );
  }

  Widget _railAction(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 18,
      color: BondColors.onDarkSecondary,
      tooltip: tooltip,
      padding: const EdgeInsets.all(BondSpacing.s4),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
    );
  }

  /// How much mail the local model still has to look at, and nothing when
  /// there is none. Deliberately a quiet caption: triage is a background
  /// annotator, not something the LO waits on, and the first sync of a real
  /// mailbox leaves it counting down for the better part of an hour.
  Widget _triageProgress() {
    return StreamBuilder<TriageProgress>(
      stream: ref.watch(triageQueueProvider).progress,
      builder: (context, snapshot) {
        final remaining = snapshot.data?.remaining ?? 0;
        if (remaining == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s8),
          child: Text(
            'Triaging $remaining remaining…',
            style: BondType.caption.copyWith(color: BondColors.onDarkMuted),
          ),
        );
      },
    );
  }

  Conversation? _selected(List<Conversation> conversations) {
    for (final c in conversations) {
      if (c.id == _selectedId) return c;
    }
    // A thread can leave the list between renders — a sync that moved it, or
    // a mark-done. The pane falls back to the overview rather than showing a
    // stale copy.
    return null;
  }

  /// Exactly one view, never two: the thread transcript, then the storyline
  /// timeline, then the section overview. The order is the priority — a thread
  /// selection is the most specific thing the user asked for.
  Widget _main(List<Conversation> conversations, String? loadError) {
    final selected = _selected(conversations);
    if (selected != null) return _thread(selected);

    final storylineId = _selectedStorylineId;
    if (storylineId != null) {
      final storyline = _storylineById(storylineId);
      if (storyline != null) return _storyline(storyline);
    }

    return _overview(conversations, loadError);
  }

  Widget _storyline(Storyline storyline) {
    final timeline = ref.watch(storylineTimelineProvider(storyline.id));

    if (timeline is StorylineTimelineInitial ||
        timeline is StorylineTimelineLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final (
      List<Message> messages,
      Map<String, String> keys,
      Map<String, String> subjects,
      String? error,
    ) = switch (timeline) {
      StorylineTimelineLoaded(
        :final messages,
        :final keyByMessageId,
        :final subjectByKey,
        :final loadError,
      ) =>
        (messages, keyByMessageId, subjectByKey, loadError),
      StorylineTimelineError(:final message) => (
          const <Message>[],
          const <String, String>{},
          const <String, String>{},
          message,
        ),
      _ => (
          const <Message>[],
          const <String, String>{},
          const <String, String>{},
          null,
        ),
    };

    final notifier = ref.read(storylinesProvider.notifier);
    final panel = StorylineTimelinePanel(
      key: ValueKey(storyline.id),
      storyline: storyline,
      messages: messages,
      keyByMessageId: keys,
      subjectByKey: subjects,
      members: ref.read(messageStoreProvider).membersOf(storyline.id),
      onBack: () => setState(() => _selectedStorylineId = null),
      onRename: (title) => notifier.rename(storyline.id, title),
      onRemoveThread: (source, key) async {
        await notifier.removeThread(storyline.id, source, key);
        if (!mounted) return;
        ref.read(storylineTimelineProvider(storyline.id).notifier).load();
      },
      onOpenThread: (_, key) => _select(key),
    );

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: error == null
          ? panel
          : Column(
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
            ),
    );
  }

  /// Files [conversationKey] into a storyline the user names now.
  ///
  /// A dialog rather than an inline field: it is the one storyline action that
  /// creates something, and it is reached from a thread, where there is no
  /// obvious place to put a text field that would not be mistaken for a
  /// composer.
  Future<void> _promptNewStoryline(String conversationKey) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New storyline'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name this storyline'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();

    final trimmed = (title ?? '').trim();
    if (trimmed.isEmpty || !mounted) return;
    await ref.read(storylinesProvider.notifier).create(
          trimmed,
          conversationKey: conversationKey,
        );
  }

  Widget _thread(Conversation selected) {
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
      onBack: () => setState(() => _selectedId = null),
      // Suggestions are deliberately absent: filing a thread into a group the
      // user has not accepted yet would be answering the suggestion for them.
      // So are the storylines this thread is already in — an "Add to" that
      // does nothing reads as a broken menu item.
      storylineChoices: () {
        final already = ref
            .read(messageStoreProvider)
            .storylineIdsFor(selected.source, selected.id)
            .toSet();
        return [
          for (final storyline in _storylines())
            if (!storyline.isSuggested && !already.contains(storyline.id))
              (storyline.id, storyline.title),
        ];
      }(),
      onAddToStoryline: (id) => ref
          .read(storylinesProvider.notifier)
          .addThread(id, selected.source, selected.id),
      onNewStoryline: () => _promptNewStoryline(selected.id),
    );

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: error == null
          ? panel
          : Column(
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
            ),
    );
  }

  Widget _overview(List<Conversation> conversations, String? loadError) {
    final section = _section ?? RailSection.needsYou;

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(section.label, style: BondType.title),
          const SizedBox(height: BondSpacing.s16),
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
          Expanded(child: _overviewBody(section, conversations)),
        ],
      ),
    );
  }

  Widget _overviewBody(RailSection section, List<Conversation> conversations) {
    if (section == RailSection.storylines) return _storylinesOverview();

    final sections = switch (section) {
      RailSection.needsYou => [('NEEDS YOU', needsYouRows(conversations))],
      RailSection.conversations => [('OPEN', conversationRows(conversations))],
      RailSection.later => const [('LATER', <Conversation>[])],
      RailSection.storylines => const <(String, List<Conversation>)>[],
    };

    return ConversationListPane(
      sources: _sources,
      filter: InboxFilter.open,
      conversations: conversations,
      selectedId: _selectedId,
      onSelect: _select,
      sectionsOverride: sections,
    );
  }

  /// Every storyline as a card. Suggestions carry their two answers on the
  /// row, so the whole section can be cleared without opening anything.
  Widget _storylinesOverview() {
    final storylines = storylineRows(_storylines());
    if (storylines.isEmpty) {
      return Center(
        child: Text(
          'Storylines appear once the local model has grouped enough mail.',
          style: BondType.small,
          textAlign: TextAlign.center,
        ),
      );
    }

    final notifier = ref.read(storylinesProvider.notifier);
    return ListView.separated(
      itemCount: storylines.length,
      separatorBuilder: (_, _) => const SizedBox(height: BondSpacing.s8),
      itemBuilder: (context, index) {
        final storyline = storylines[index];
        final summary = storyline.summary ?? '';
        return Material(
          color: BondColors.surface,
          borderRadius: BondRadii.mdAll,
          child: InkWell(
            onTap: () => _selectStoryline(storyline.id),
            borderRadius: BondRadii.mdAll,
            child: Container(
              padding: const EdgeInsets.all(BondSpacing.s12),
              decoration: BoxDecoration(
                borderRadius: BondRadii.mdAll,
                border: Border.all(color: BondColors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          storyline.title.isEmpty
                              ? '(untitled)'
                              : storyline.title,
                          style: BondType.body
                              .copyWith(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (summary.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            summary,
                            style: BondType.caption,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 2),
                        Text(
                          '${storyline.memberCount} threads · '
                          '${storyline.openCount} open',
                          style: BondType.caption,
                        ),
                      ],
                    ),
                  ),
                  if (storyline.isSuggested) ...[
                    const SizedBox(width: BondSpacing.s8),
                    TextButton(
                      onPressed: () => notifier.keep(storyline.id),
                      child: const Text('Keep'),
                    ),
                    TextButton(
                      onPressed: () => notifier.dismiss(storyline.id),
                      child: const Text('Dismiss'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
