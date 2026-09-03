import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../providers/activity_provider.dart';
import '../providers/app_providers.dart';
import '../providers/conversations_provider.dart';
import '../providers/draft_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/notify_routing.dart';
import '../providers/prefs_provider.dart';
import '../providers/storylines_provider.dart';
import '../services/backend/backend_types.dart';
import '../services/llm/draft_task.dart' show DraftOption;
import '../services/triage_queue.dart';
import '../theme/tokens.dart';
import '../widgets/activity_log_panel.dart';
import '../widgets/app_rail.dart';
import '../widgets/chips.dart';
import '../widgets/composer.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/inline_alert.dart';
import '../widgets/later_digest.dart';
import '../widgets/notification_ribbon.dart';
import '../widgets/quick_replies.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/source_filter.dart';
import '../widgets/storyline_pickers.dart';
import '../widgets/storyline_timeline.dart';
import '../widgets/thread_detail_panel.dart';
import '../widgets/time_format.dart';

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

class _InboxScreenState extends ConsumerState<InboxScreen>
    with WidgetsBindingObserver {
  /// Below this the rail and a readable transcript cannot share the width, so
  /// the rail becomes an overlay the hamburger opens.
  static const double _twoPaneBreakpoint = 960;

  static const List<String> _sources = inboxSources;

  /// Slow enough to be invisible on a metered connection, fast enough that a
  /// reply that arrived while the user was reading feels like it just showed
  /// up. Graph delta calls with nothing new are cheap.
  ///
  /// **Mail only.** [_refresh] is what this fires and it does not touch Teams:
  /// Microsoft's terms for the Teams messaging endpoints forbid polling them,
  /// so a chat refresh has to trace back to a button press or to the window
  /// coming back to the front.
  static const Duration _pollInterval = Duration(seconds: 60);

  /// The shortest gap between two Teams pulls the app makes on its own.
  ///
  /// A resume is the user turning their attention back to this window, which
  /// is a real signal — but alt-tabbing away and back three times in a minute
  /// is the same one signal, and answering each one would be polling with
  /// extra steps.
  static const Duration _teamsResumeInterval = Duration(minutes: 10);

  /// The section overview showing when no thread is open. Never null in
  /// practice — the type only carries the "no explicit choice yet" case.
  RailSection? _section = RailSection.needsYou;
  String? _selectedId;

  /// Which connector [_selectedId] belongs to, set only when the caller knows
  /// — a storyline card does, the rail does not. A conversation key is unique
  /// within a connector and not across them, so without this a chat and a mail
  /// thread that share a key are the same selection.
  String? _selectedSource;

  /// The open storyline. Never set at the same time as [_selectedId] — the
  /// main pane shows exactly one thing, and the three selections clear each
  /// other rather than racing to be rendered.
  String? _selectedStorylineId;

  /// The open Later day, as a `yyyy-mm-dd` key. Exclusive with the two above
  /// for the same reason they are exclusive with each other.
  String? _selectedLaterDay;

  /// Whether the main pane is showing the activity log. Exclusive with the
  /// three selections above for the same reason they are exclusive with each
  /// other: the pane shows exactly one thing, and every setter clears the rest
  /// rather than racing to be rendered.
  bool _showingActivityLog = false;

  /// The storyline the add-thread pane is picking a conversation for. An
  /// overlay on the storyline selection rather than a peer of it: back returns
  /// to the storyline underneath.
  String? _addingToStorylineId;

  /// The thread the add-to-storyline pane is filing. Same overlay contract.
  ({String source, String id})? _pickingStorylineForThread;

  /// The thread whose reply window is open, if any. Collapsed is the DEFAULT:
  /// a thread opens as something to read, and the composer appears when the
  /// user says they are writing. Cleared wherever the selection moves — a
  /// window opened on one thread must not be open on the next.
  String? _replyOpenFor;

  /// The threads a queued reply is going to, held until each send lands so the
  /// result can be announced even if the user has moved on to another thread
  /// meanwhile. Only [_queueQuickReply] adds to it, which is what keeps the
  /// composer's own send — which reports its outcome directly — from being
  /// announced twice.
  ///
  /// A SET, because the storyline spine renders an armed card per open episode
  /// and two sends can be in flight at once. One slot silenced the first send's
  /// outcome — including its failure.
  final Set<DraftTarget> _announceSendsFor = {};

  /// Which member thread a storyline's composer replies to, when the user has
  /// picked one. Null means "the thread the newest message is in", which is
  /// what the dropdown shows by default — a storyline has no inbox of its own
  /// to reply to, so the composer always answers exactly one real thread.
  ///
  /// Source and key together: a bare key names a conversation only within one
  /// connector, and a storyline can hold members from both.
  DraftTarget? _storylineReplyKey;

  /// The storyline whose reply window is open, if any. Collapsed is the
  /// DEFAULT here too: a storyline opens as a spine to read, and the box —
  /// with the pills that pick which member thread it answers — appears when
  /// the user says they are writing.
  String? _storylineReplyOpenFor;

  /// Narrow layouts only: whether the rail overlay is up.
  bool _railOpen = false;

  /// Which connector the list is showing: null for all, or a source name.
  String? _sourceFilter;

  /// When Teams was last pulled, by any route. Null until the first one.
  DateTime? _lastTeamsRefresh;

  /// The stored "Teams last synced" stamp, read once and re-read only after a
  /// pull. See [_teamsFreshness].
  Future<String?>? _teamsSyncedAt;

  Timer? _poll;

  /// Set once the sign-out route is under way, so a second notification
  /// cannot start it again mid-teardown.
  bool _leaving = false;

  late final Future<AccountInfo?> _account =
      ref.read(authSessionProvider).storedAccount;

  /// Whether the tenant granted `Chat.Read`. Read once — it is a keychain
  /// read, and the answer cannot change without a fresh sign-in, which
  /// rebuilds this screen.
  late final Future<bool> _teamsGranted =
      ref.read(authSessionProvider).hasScope('chat.read');

  @override
  void initState() {
    super.initState();
    // Built here, once, because nothing renders it: the OS dispatcher only
    // exists if something instantiates it, and the inbox is the screen whose
    // lifetime it should share.
    ref.read(desktopNotificationServiceProvider);
    WidgetsBinding.instance.addObserver(this);
    // A microtask, not a direct call: a provider must not be written to
    // while the first frame's widgets are still being built.
    //
    // Teams included, and the launch is what stamps [_lastTeamsRefresh]:
    // opening the app is the strongest form of the app-focus signal, and
    // stamping it here is what stops the resume path firing again seconds
    // later when the window takes focus.
    Future.microtask(_refreshAll);
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The app came back to the front. The one automatic path to Teams, and it
  /// is rate limited to [_teamsResumeInterval] — see that constant.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final last = _lastTeamsRefresh;
    if (last != null &&
        DateTime.now().difference(last) < _teamsResumeInterval) {
      return;
    }
    unawaited(_refreshTeams());
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
      ref
          .read(
            threadProvider(
              (
                source: _selectedSource ?? 'email',
                conversationKey: selected,
              ),
            ).notifier,
          )
          .load();
      // The sync deletes a draft whose thread just received new mail. The
      // composer must find that out NOW, not on the next AI progress event —
      // a stale suggestion left on screen gets sent as a reply to a message
      // that is no longer the newest one.
      ref
          .read(
            draftProvider(
              (
                source: _selectedSource ?? 'email',
                conversationKey: selected,
              ),
            ).notifier,
          )
          .load();
    }
    final storyline = _selectedStorylineId;
    if (storyline != null) {
      ref.read(storylineTimelineProvider(storyline).notifier).load();
    }
  }

  /// What the refresh button does: the mail refresh the timer also runs, plus
  /// the Teams pull the timer must never run.
  ///
  /// The read-acks are pumped from HERE rather than from [_refresh], for the
  /// same reason [_refreshTeams] is: the queue carries chat acks as well as
  /// mail ones, and every call on it has to trace back to something the user
  /// did. Refresh is the second way a parked ack gets another go — the first
  /// is reopening the thread.
  Future<void> _refreshAll() async {
    _refresh();
    unawaited(ref.read(readAckQueueProvider).pump());
    await _refreshTeams();
  }

  /// The Teams pull, and the stamp that keeps the resume path from repeating
  /// it. Every route to Teams goes through here, so there is exactly one place
  /// the stamp can be forgotten and it is not forgotten.
  Future<void> _refreshTeams() async {
    if (!mounted) return;
    _lastTeamsRefresh = DateTime.now();
    await ref.read(conversationsProvider.notifier).refreshTeams();
    if (!mounted) return;
    setState(() => _teamsSyncedAt = null);
  }

  Future<void> _signOut() async {
    // Before anything else: the ribbon holds one account's CTA text and the
    // intent holds a thread in a database that is about to be wiped. Neither
    // may survive into the next person's session.
    ref.read(notificationRibbonProvider.notifier).dismiss();
    ref.read(navIntentProvider.notifier).clear();
    await ref.read(authSessionProvider).signOut();
    // The keychain is not the only thing holding this account: the sqlite
    // file holds its mailbox, and the providers hold that in memory. A
    // different account signing in next must find neither — mail from two
    // mailboxes interleaved in one inbox is the bug this line rules out.
    await ref.read(messageStoreProvider).wipeAll();
    if (!mounted) return;
    ref.invalidate(conversationsProvider);
    ref.invalidate(storylinesProvider);
    ref.invalidate(threadProvider);
    ref.invalidate(draftProvider);
    ref.invalidate(storylineTimelineProvider);
    widget.onSignedOut?.call();
  }

  void _select(String id, {String? source}) {
    // The row's own source, resolved from the loaded list the way [_selected]
    // resolves it — the rail, the list pane and the digest all pass an id and
    // nothing else, and a hard-coded `'email'` would mark a chat read against
    // a thread that does not exist.
    //
    // Resolved BEFORE the selection is stored, because [_selectedSource] is
    // what the refresh path keys the open thread's transcript and draft by.
    // Left null it would key them `email` while the pane renders the row's
    // real source, and a chat opened from the rail would stop refreshing.
    final loaded = ref.read(conversationsProvider);
    var resolvedSource = source;
    Conversation? row;
    if (loaded is ConversationsLoaded) {
      for (final c in loaded.conversations) {
        if (c.id != id) continue;
        if (source != null && c.source != source) continue;
        resolvedSource = c.source;
        row = c;
        break;
      }
    }
    setState(() {
      _selectedId = id;
      _selectedSource = resolvedSource;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _showingActivityLog = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
    });
    // The quietest signal the app collects: opening a thread is the user saying
    // this one was worth their time. Fire-and-forget, and nothing on screen
    // reads it yet.
    ref.read(conversationsProvider.notifier).noteThreadOpened(id);
    // Opening it IS reading it.
    if (row != null) {
      ref.read(conversationsProvider.notifier).markRead(row.source, id);
    }
    ref
        .read(
          threadProvider(
            (source: resolvedSource ?? 'email', conversationKey: id),
          ).notifier,
        )
        .load();
    // Reads what the queue has already written for this thread. It never asks
    // for a new one — a draft is written by the background queue or by the
    // user's own button, never by opening a thread.
    ref
        .read(
          draftProvider(
            (source: resolvedSource ?? 'email', conversationKey: id),
          ).notifier,
        )
        .load();
  }

  void _selectStoryline(String id) {
    setState(() {
      _selectedStorylineId = id;
      _selectedId = null;
      _selectedSource = null;
      _selectedLaterDay = null;
      _showingActivityLog = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
      // The reply target belongs to the storyline that was open, not to this
      // one; the default below picks the newest thread in the new timeline.
      _storylineReplyKey = null;
      _storylineReplyOpenFor = null;
    });
    ref.read(storylineTimelineProvider(id).notifier).load();
  }

  void _selectSection(RailSection section) {
    setState(() {
      _section = section;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _showingActivityLog = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
    });
  }

  /// Opens one day's Later digest. The section moves with it, so backing out of
  /// the day lands on the whole pile rather than wherever the user was before.
  void _selectLaterDay(String dayKey) {
    setState(() {
      _section = RailSection.later;
      _selectedLaterDay = dayKey;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _showingActivityLog = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
    });
  }

  /// Opens the activity log, which is a pane and not a section: it belongs to
  /// the app rather than to the mail, so it is reached from the rail's footer
  /// and clears whatever the user was reading.
  void _openActivityLog() {
    setState(() {
      _showingActivityLog = true;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
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

    // A queued reply leaves on a timer, so nothing is awaiting its outcome the
    // way the composer's own send is. Listening from HERE rather than from the
    // thread pane is what lets it be announced after the user has moved on:
    // the target outlives the selection, and the notifier behind it is not
    // autoDispose.
    // One listener per queued send, and each one answers for its OWN target:
    // two episodes on a storyline can be sending at the same time, and an
    // outcome must not clear the slot the other send was waiting in.
    for (final target in _announceSendsFor.toList()) {
      ref.listen<DraftState>(draftProvider(target), (previous, next) {
        if (previous == null || !mounted) return;
        if (next.sendEpoch > previous.sendEpoch) {
          setState(() => _announceSendsFor.remove(target));
          _toast('Reply sent.');
          return;
        }
        // The reply window is closed on a quick reply, so the inline alert the
        // composer would have shown this on is not on screen. The bar is the
        // only place left to say it.
        final error = next.error;
        if (error != null && error != previous.error && !next.sending) {
          setState(() => _announceSendsFor.remove(target));
          _toast(error);
        }
      });
    }

    // Where a notification's click lands. Nothing outside this State can call
    // the three selection methods, so everything that navigates from outside
    // the tree — the ribbon today, an OS notification next — asks here.
    ref.listen<NavIntent?>(navIntentProvider, (_, intent) {
      if (intent == null || !mounted) return;
      switch (intent) {
        case OpenThreadIntent(:final source, :final conversationKey):
          _select(conversationKey, source: source);
        case OpenStorylineIntent(:final storylineId):
          _selectStoryline(storylineId);
        case OpenSectionIntent(:final section):
          _selectSection(section);
      }
      // Cleared after the frame, not inside the listener: writing to a
      // notifier while it is notifying is a re-entrant write.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(navIntentProvider.notifier).clear();
      });
    });

    final state = ref.watch(conversationsProvider);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          // Expand, or the stack takes its size from the ribbon layer — which
          // is nothing at all until something settles, and the inbox under it
          // would lay out at zero.
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _body(state)),
            // A sibling ABOVE the body rather than something inside it: the
            // pane swaps out from under every selection, and a ribbon mounted
            // in there would be unmounted mid-announcement — and the narrow
            // layout's rail overlay would cover it.
            _ribbonLayer(),
          ],
        ),
      ),
    );
  }

  /// The banner that says a processed message needs the user.
  Widget _ribbonLayer() {
    final ribbon = ref.watch(notificationRibbonProvider);
    final items = ribbon.items;
    if (items.isEmpty) return const SizedBox.shrink();

    // Announcing the thread the user is already reading is telling them what
    // is on their screen. Only when it is the whole batch — a pile that
    // happens to include it still has somewhere else to go.
    final onScreen = items.length == 1 &&
        items.single.conversationKey == _selectedId &&
        (_selectedSource == null || items.single.source == _selectedSource);

    final show = ribbon.visible && !onScreen;

    return Positioned(
      top: BondSpacing.s12,
      left: 0,
      right: 0,
      child: Center(
        // The child stays mounted while it animates out, so it must not be
        // taking clicks the whole time it is invisible.
        child: IgnorePointer(
          ignoring: !show,
          child: AnimatedSlide(
            offset: show ? Offset.zero : const Offset(0, -1.4),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: NotificationRibbon(
                severity: ribbon.anyUrgent
                    ? InlineAlertSeverity.error
                    : InlineAlertSeverity.attention,
                text: ribbon.text,
                onTap: () {
                  ref
                      .read(navIntentProvider.notifier)
                      .request(intentFor(items));
                  ref.read(notificationRibbonProvider.notifier).dismiss();
                },
                onDismiss: () =>
                    ref.read(notificationRibbonProvider.notifier).dismiss(),
              ),
            ),
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
        // Filtered ONCE, here, before anything downstream sees a list — the
        // rail's badges, the Later day rows and the overviews all derive their
        // counts from what they are handed, and filtering some of them would
        // put a badge over a section showing fewer rows than it claims.
        final rows = bySource(conversations, _sourceFilter);
        return LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth >= _twoPaneBreakpoint
                  ? _wide(rows, loadError)
                  : _narrow(rows, loadError),
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

  // ── corrections ────────────────────────────────────────────────────────
  //
  // Every explicit correction lands the same way: it happens immediately, and
  // it says so in a bar with an UNDO on it. Confirming first would put a modal
  // in front of a one-click gesture the user is going to make dozens of times;
  // an undo costs nothing when it is not used.

  /// How long the undo stays reachable. Long enough to notice the bar and
  /// react, short enough not to sit over the mail.
  ///
  /// Read FROM [DraftNotifier.undoWindow] rather than repeated as a number:
  /// one of these bars offers to cancel a send that fires on exactly that
  /// timer, and a bar that outlived its window would leave an Undo on screen
  /// that no longer undoes anything.
  static const Duration _undoDuration = DraftNotifier.undoWindow;

  void _toast(String message, {VoidCallback? onUndo}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // The previous bar goes now rather than queueing: correcting three senders
    // in a row should leave the third one's undo reachable, not the first's.
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: _undoDuration,
        action: onUndo == null
            ? null
            : SnackBarAction(label: 'Undo', onPressed: onUndo),
      ),
    );
  }

  static String _threads(int n) => n == 1 ? '1 thread' : '$n threads';

  Future<void> _keepSender(String address, String source) async {
    final notifier = ref.read(conversationsProvider.notifier);
    // Captured BEFORE the write. The undo restores this exact value, including
    // "there was no rule", which is a different state from "the rule was keep".
    final previous = await notifier.senderPref(address);
    final affected = await notifier.keepSenderInInbox(address, source: source);
    _toast(
      'Keeping $address in your inbox — ${_threads(affected)} moved back.',
      onUndo: () => notifier.restoreSenderPref(address, previous, source: source),
    );
  }

  Future<void> _laterSender(String address, String source) async {
    final notifier = ref.read(conversationsProvider.notifier);
    final previous = await notifier.senderPref(address);
    final affected = await notifier.sendSenderToLater(address, source: source);
    _toast(
      '$address goes to Later — ${_threads(affected)} moved.',
      onUndo: () => notifier.restoreSenderPref(address, previous, source: source),
    );
  }

  Future<void> _keepThread(String source, String key) async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.keepThreadInInbox(source, key);
    _toast(
      'Thread kept in your inbox.',
      onUndo: () => notifier.sendThreadToLater(source, key),
    );
  }

  Widget _rail(List<Conversation> conversations) {
    final later = laterRows(conversations);
    return AppRail(
      conversations: conversations,
      storylines: _storylines(),
      selectedId: _selectedId,
      selectedSource: _selectedSource,
      selectedStorylineId: _selectedStorylineId,
      selectedLaterDay: _selectedLaterDay,
      laterCount: later.length,
      laterDays: laterDayCounts(conversations),
      attentionThreshold: ref.watch(appPrefsProvider).attentionThreshold,
      processingSince: ref.watch(sessionStartProvider),
      // A thread, a storyline or a Later day being open means no section
      // overview is showing, so the rail must not highlight one.
      selectedSection: (_selectedId == null &&
              _selectedStorylineId == null &&
              _selectedLaterDay == null &&
              !_showingActivityLog)
          ? _section
          : null,
      onSelectConversation: (source, id) => _select(id, source: source),
      onSelectSection: _selectSection,
      onSelectStoryline: _selectStoryline,
      onSelectLaterDay: _selectLaterDay,
      onKeepSuggestion: (id) =>
          ref.read(storylinesProvider.notifier).keep(id),
      onDismissSuggestion: (id) {
        // The dismissed storyline leaves the list, so a selection pointing at
        // it would render nothing. Clearing it here returns the pane to the
        // overview in the same frame the row disappears — and the add-thread
        // overlay goes with it, since its pane belongs to the same storyline.
        if (_selectedStorylineId == id || _addingToStorylineId == id) {
          setState(() {
            _selectedStorylineId = null;
            _addingToStorylineId = null;
          });
        }
        ref.read(storylinesProvider.notifier).dismiss(id);
      },
      footer: _railFooter(),
    );
  }

  /// Account, refresh, sign-out — everything the old header row carried,
  /// parked at the foot of the rail where it stops competing with the mail.
  Widget _railFooter() {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _sourceFilterBar(),
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
              if (ref.watch(appPrefsProvider).showActivityLog)
                _railAction(
                  Icons.receipt_long,
                  'Activity log',
                  _openActivityLog,
                ),
              _railAction(Icons.settings, 'Settings', _openSettings),
              // The ONE button that pulls Teams. Every other refresh in this
              // screen — the timer, the retry links on the error banners — is
              // mail only.
              _railAction(Icons.refresh, 'Refresh', () => unawaited(_refreshAll())),
              _railAction(Icons.logout, 'Sign out', _signOut),
            ],
          ),
          _teamsFreshness(),
        ],
      ),
    );
  }

  /// The three source pills.
  ///
  /// The Teams pill goes disabled-with-a-tooltip rather than absent when the
  /// tenant refused `Chat.Read`: a user who expected Teams and finds nothing
  /// has no way to learn why, and this is the only surface that can tell them.
  /// Until the keychain read lands it is treated as available — a moment of an
  /// extra tappable pill costs nothing, while a moment of a greyed-out one
  /// reads as a refusal that has not happened.
  Widget _sourceFilterBar() {
    return FutureBuilder<bool>(
      future: _teamsGranted,
      builder: (context, snapshot) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s12),
        child: SourceFilterBar(
          selected: _sourceFilter,
          teamsAvailable: snapshot.data ?? true,
          onSelected: (source) => setState(() => _sourceFilter = source),
        ),
      ),
    );
  }

  /// How old the Teams side of the inbox is, and nothing at all before the
  /// first pull.
  ///
  /// It sits under the refresh button because that is the one control that
  /// changes it — chats do not arrive on their own here, and a caption saying
  /// so is the difference between "quiet" and "stale".
  Widget _teamsFreshness() {
    // Held rather than re-read on every build: it is a stored read and so a
    // future now, and a fresh future per build would restart the FutureBuilder
    // — blanking the caption for a frame every time anything on this screen
    // changed. [_refreshTeams] drops it, which is the only thing that can
    // change the answer.
    final future = _teamsSyncedAt ??= ref.read(teamsSyncProvider).lastSyncedAt;
    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final label = relativeTime(snapshot.data, DateTime.now());
        if (label == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: BondSpacing.s4),
          child: Text(
            'Teams updated $label',
            style: BondType.caption.copyWith(color: BondColors.onDarkMuted),
          ),
        );
      },
    );
  }

  /// The tuning controls, plus what Microsoft granted. The threshold reloads
  /// the list as it changes — the whole point of the slider is watching Needs
  /// You grow and shrink under it — while the "about me" text is only saved.
  ///
  /// It is also where SESSIONS are managed. The dialog shows whether the
  /// backend it is currently pointing at is signed in, and signs in and out of
  /// it in place — the gate above never swaps the screen for a settings change,
  /// so this is the only place that work can happen.
  ///
  /// "Sign in again" is kept wired for the SDK permissions table, where it
  /// signs OUT and lets the gate take over. It is not rendered while the
  /// session block is on screen — that block's Sign in… is the same action,
  /// beside the state it fixes.
  Future<void> _openSettings() async {
    final prefs = ref.read(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    await showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        threshold: prefs.attentionThreshold,
        aboutMe: prefs.aboutMe,
        // The prefs setters update state first and persist behind the
        // caller's back on purpose (see AppPrefsNotifier) — `unawaited` says
        // the discard is that contract, not an oversight.
        onThresholdChanged: (value) {
          unawaited(notifier.setAttentionThreshold(value));
          if (!mounted) return;
          ref.read(conversationsProvider.notifier).load(syncFirst: false);
        },
        onAboutMeChanged: (text) => unawaited(notifier.setAboutMe(text)),
        showActivityLog: prefs.showActivityLog,
        onShowActivityLogChanged: (on) =>
            unawaited(notifier.setShowActivityLog(on)),
        notifyStyle: prefs.notifyStyle,
        onNotifyStyleChanged: (style) =>
            unawaited(notifier.setNotifyStyle(style)),
        // BOTH sources are wired, and deliberately not bound to the mode the
        // dialog OPENED in: the toggle now switches backends without closing
        // the dialog, so which one answers is the dialog's live choice. Each
        // closure reads the providers at CALL time — after a switch, the
        // dialog's re-ask lands on the session the switch just built.
        //
        // Every closure that touches `ref` starts with a mounted check. The
        // dialog lives in the ROOT overlay and can outlive this screen — a
        // sign-out from the rail behind it, for one — and a dead host must
        // answer with nothing, never with "ref after dispose".
        hasScope: (scope) async {
          if (!mounted) return false;
          return ref.read(authSessionProvider).hasScope(scope);
        },
        connectionStatus: _connectionStatus,
        onConnectMicrosoft: () => unawaited(_connectMicrosoft()),
        backendMode: prefs.backendMode,
        mcpServerUrl: prefs.mcpServerUrl,
        onBackendModeChanged: (mode) {
          unawaited(notifier.setBackendMode(mode));
          _reloadAfterBackendChange();
        },
        onMcpServerUrlChanged: (url) {
          unawaited(notifier.setMcpServerUrl(url));
          _reloadAfterBackendChange();
        },
        onSignInAgain: () {
          Navigator.of(context).pop();
          _signOut();
        },
        isTargetSignedIn: () async {
          if (!mounted) return false;
          return ref.read(authSessionProvider).isSignedIn;
        },
        targetAccountLabel: () async {
          if (!mounted) return null;
          final account = await ref.read(authSessionProvider).storedAccount;
          return account?.mail ?? account?.displayName;
        },
        onSignIn: () async {
          if (!mounted) return;
          final account = await ref.read(authSessionProvider).signIn();
          if (!mounted) return;
          // Before anything syncs: if the rows in this file belong to a
          // different person, the sign-in that just succeeded is the moment
          // they stop being reachable. Two mailboxes must never be in the
          // database at once, and after the first sync is too late.
          final wiped = await ref.read(identityGuardProvider).adopt(account);
          if (!mounted) return;
          if (wiped) {
            // The same list `SignInScreen._invalidateAfterWipe` drops, and
            // duplicated for the same reason it is duplicated there: it is
            // "everything holding mail rows in memory", and a shared helper
            // would hide that from whichever screen gains a provider next.
            // Keep them in step.
            ref.invalidate(conversationsProvider);
            ref.invalidate(storylinesProvider);
            ref.invalidate(threadProvider);
            ref.invalidate(draftProvider);
            ref.invalidate(storylineTimelineProvider);
            // And the previous person's about-me text, which the notifier
            // still holds in memory — same reason SignInScreen clears it.
            unawaited(ref.read(appPrefsProvider.notifier).setAboutMe(''));
          }
          _reloadAfterBackendChange();
        },
        onSignOutOfServer: () async {
          if (!mounted) return;
          await ref.read(authSessionProvider).signOut();
          if (!mounted) return;
          // NO database wipe here, deliberately. Leaving one server is not
          // "remove this account from this machine" — the rail's Sign out is,
          // and it keeps its explicit wipe. If a different identity signs in
          // next, the IdentityGuard wipes then, which is the moment the rows
          // actually stop being this user's.
          _reloadAfterBackendChange();
        },
      ),
    );
  }

  /// Repaints the list after the backend under it was replaced.
  ///
  /// Changing the mode or the server rebuilds every provider below it, the
  /// conversations notifier included — which comes back with an empty state.
  /// This reads what is already stored, with no sync: the rows are the same
  /// mailbox either way, and asking the brand-new session for mail before the
  /// user has signed in to it would put an error where a list belongs.
  ///
  /// A target with no session is NOT a reason to take anything off screen: the
  /// gate above decides at launch only, this screen stays where it is, and the
  /// settings dialog reports "not signed in to this server" with a Sign in…
  /// beside it. The list underneath is simply empty until that happens, which
  /// is the truth about a server nobody has signed in to.
  void _reloadAfterBackendChange() {
    // The dialog outlives nothing here any more, but it can still be closed
    // and reopened around an in-flight change; a dead host must answer with
    // nothing rather than with "ref after dispose".
    if (!mounted) return;
    ref.read(conversationsProvider.notifier).load(syncFirst: false);
  }

  /// The platform's view of the workspace's Microsoft account.
  ///
  /// EVERY failure answers null rather than throwing: this is a report on a
  /// settings pane, and a server that cannot be reached is a row that says so,
  /// not an exception on its way to a banner. The catch-all covers the rest —
  /// an ask still in flight when this screen goes away must render "no answer"
  /// rather than crash on a ref whose element is gone.
  Future<Map<String, Object?>?> _connectionStatus() async {
    try {
      return await ref
          .read(mcpStackProvider)
          .client
          .callTool('connection_status', const {});
    } on Object {
      return null;
    }
  }

  Future<void> _connectMicrosoft() async {
    if (!mounted) return;
    final url = await ref.read(mcpStackProvider).auth.microsoftConnectUrl();
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
  /// annotator, not something the user waits on, and the first sync of a real
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
    // The source narrows the match only when the caller supplied one. Every
    // other route here knows an id and nothing else, and demanding a source of
    // them would match nothing at all.
    bool matches(Conversation c) =>
        c.id == _selectedId &&
        (_selectedSource == null || c.source == _selectedSource);

    for (final c in conversations) {
      if (matches(c)) return c;
    }
    // Not in the FILTERED list. An explicit selection is the most specific
    // thing the user asked for and outranks the source filter — a storyline
    // card can open a chat while the filter shows Mail, and landing on a
    // section overview instead would read as a broken click. The unfiltered
    // list settles whether the thread still exists at all.
    final state = ref.read(conversationsProvider);
    if (state is ConversationsLoaded) {
      for (final c in state.conversations) {
        if (matches(c)) return c;
      }
    }
    // A thread can leave the list between renders — a sync that moved it, or
    // a mark-done. The pane falls back to the overview rather than showing a
    // stale copy.
    return null;
  }

  /// Exactly one view, never two: the activity log, then the two picker panes,
  /// then the thread transcript, then the storyline timeline, then the section
  /// overview. The order is the priority — the log is first because it is the
  /// only one that is not about the mail at all, and a pane outranks what it
  /// was opened from because it is the newer thing the user asked for.
  ///
  /// A selected Later day is not a case here: it is a section overview with a
  /// filter on it, and [_overviewBody] reads it.
  Widget _main(List<Conversation> conversations, String? loadError) {
    if (_showingActivityLog) return _activityLog();

    final addingTo = _addingToStorylineId;
    if (addingTo != null) {
      final storyline = _storylineById(addingTo);
      if (storyline != null) return _addThreadPane(storyline);
      // Dismissed or gone from under the pane; fall through to whatever is
      // next.
    }

    final picking = _pickingStorylineForThread;
    if (picking != null) return _pickStorylinePane(picking);

    final selected = _selected(conversations);
    if (selected != null) return _thread(selected);

    final storylineId = _selectedStorylineId;
    if (storylineId != null) {
      final storyline = _storylineById(storylineId);
      if (storyline != null) return _storyline(storyline);
    }

    return _overview(conversations, loadError);
  }

  /// Which thread joins [storyline].
  ///
  /// Read from the UNFILTERED conversations, for the reason [_selected] reads
  /// them: the source pills are what the user is browsing with, and a storyline
  /// that merges mail and chats must be able to recruit from both whichever
  /// pill happens to be down.
  Widget _addThreadPane(Storyline storyline) {
    final state = ref.watch(conversationsProvider);
    final all = state is ConversationsLoaded
        ? state.conversations
        : const <Conversation>[];

    // Both reads are empty for the frame before they land, which offers a
    // thread that is already in for that one frame. Adding it again is a no-op
    // in the store, so the worst that frame can cost is a redundant write.
    final members =
        ref.watch(storylineMembersProvider(storyline.id)).valueOrNull ??
            const <StorylineMember>[];
    final taken = <String>{
      for (final member in members)
        '${member.source}\n${member.conversationKey}',
      ...?ref
          .watch(storylineBlockedThreadsProvider(storyline.id))
          .valueOrNull,
    };

    final candidates = [
      for (final c in all)
        if (!taken.contains('${c.source}\n${c.id}')) c,
    ]..sort((a, b) {
        final left = a.lastMessageAt ?? '';
        final right = b.lastMessageAt ?? '';
        // Newest first, a thread with no stamp last rather than first — and
        // the id as the tie-break, so the same mailbox always sorts the same
        // way rather than in whatever order the list read happened to return.
        if (left != right) {
          if (left.isEmpty) return 1;
          if (right.isEmpty) return -1;
          return right.compareTo(left);
        }
        return a.id.compareTo(b.id);
      });

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: AddThreadToStorylinePane(
        storylineTitle:
            storyline.title.isEmpty ? '(untitled)' : storyline.title,
        candidates: candidates,
        onBack: () => setState(() => _addingToStorylineId = null),
        onPick: (conversation) async {
          final notifier = ref.read(storylinesProvider.notifier);
          await notifier.addThread(
            storyline.id,
            conversation.source,
            conversation.id,
          );
          if (!mounted) return;
          setState(() => _addingToStorylineId = null);
          // The timeline must show the thread the user just filed, this
          // frame's sibling — the same reload onRemoveThread already does.
          ref.read(storylineTimelineProvider(storyline.id).notifier).load();
        },
      ),
    );
  }

  /// Which storyline [thread] joins, or the one it starts.
  Widget _pickStorylinePane(({String source, String id}) thread) {
    // Suggestions are offered alongside the kept ones: filing a thread into a
    // suggestion IS the user answering it, and the add promotes the group to
    // kept. Leaving them out was how a thread removed from a suggestion could
    // never be put back. The storylines this thread is already in stay out —
    // an "Add to" that does nothing reads as a broken row.
    //
    // Empty until the read lands, which leaves every storyline offered for one
    // frame. Adding a thread it is already in is a no-op in the store, so the
    // worst that frame can cost is a redundant write.
    final already = ref
            .watch(storylineThreadIdsProvider(
              (source: thread.source, conversationKey: thread.id),
            ))
            .valueOrNull ??
        const <String>{};

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: AddToStorylinePane(
        choices: [
          for (final storyline in _storylines())
            if (!already.contains(storyline.id)) storyline,
        ],
        onBack: () => setState(() => _pickingStorylineForThread = null),
        onPick: (id) {
          ref
              .read(storylinesProvider.notifier)
              .addThread(id, thread.source, thread.id);
          setState(() => _pickingStorylineForThread = null);
        },
        onCreate: (title) {
          ref.read(storylinesProvider.notifier).create(
                title,
                conversationKey: thread.id,
                source: thread.source,
              );
          setState(() => _pickingStorylineForThread = null);
        },
      ),
    );
  }

  Widget _storyline(Storyline storyline) {
    final timeline = ref.watch(storylineTimelineProvider(storyline.id));

    if (timeline is StorylineTimelineInitial ||
        timeline is StorylineTimelineLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final (List<StorylineEpisode> episodes, String? error) = switch (timeline) {
      StorylineTimelineLoaded(:final episodes, :final loadError) =>
        (episodes, loadError),
      StorylineTimelineError(:final message) => (
          const <StorylineEpisode>[],
          message,
        ),
      _ => (const <StorylineEpisode>[], null),
    };

    final notifier = ref.read(storylinesProvider.notifier);
    final newestFirst =
        ref.watch(appPrefsProvider.select((p) => p.storylineNewestFirst));
    final panel = StorylineTimelinePanel(
      key: ValueKey(storyline.id),
      storyline: storyline,
      episodes: episodes,
      // Empty for the frame before the read lands — the same thing the pane
      // shows for a storyline whose members have not been written yet.
      members:
          ref.watch(storylineMembersProvider(storyline.id)).valueOrNull ??
              const [],
      onBack: () => setState(() {
        _selectedStorylineId = null;
        _storylineReplyOpenFor = null;
      }),
      onRename: (title) => notifier.rename(storyline.id, title),
      onSetCharter: (charter) => notifier.setCharter(storyline.id, charter),
      onRemoveThread: (source, key) async {
        await notifier.removeThread(storyline.id, source, key);
        if (!mounted) return;
        ref.read(storylineTimelineProvider(storyline.id).notifier).load();
      },
      onOpenThread: (source, key) => _select(key, source: source),
      onAddThread: () =>
          setState(() => _addingToStorylineId = storyline.id),
      newestFirst: newestFirst,
      onToggleSort: () => unawaited(ref
          .read(appPrefsProvider.notifier)
          .setStorylineNewestFirst(!newestFirst)),
      onDismiss: () {
        // Same order as the rail's dismissal: the storyline leaves the list,
        // so the selection pointing at it goes first and the pane is back on
        // the overview in the frame the row disappears.
        setState(() {
          _selectedStorylineId = null;
          _addingToStorylineId = null;
          _storylineReplyOpenFor = null;
        });
        unawaited(notifier.dismiss(storyline.id));
      },
      // The suggestions ride on the episode they answer, not under the spine:
      // a storyline is several conversations, and a card offering to reply has
      // to say which one it would reply to.
      episodeFooter: (episode) => _EpisodeQuickReplies(
        target: (
          source: episode.source,
          conversationKey: episode.conversationKey,
        ),
        onOpenReply: () => _openStorylineReply(storyline.id, episode),
        onQueueSend: (body) => unawaited(_queueQuickReply(
          (source: episode.source, conversationKey: episode.conversationKey),
          body,
        )),
        onUndo: () => _cancelQueuedSend(
          (source: episode.source, conversationKey: episode.conversationKey),
        ),
      ),
      onAskTap: (episode) => _openStorylineReply(storyline.id, episode),
    );

    // A storyline replies to any of its episodes, chats included: the group is
    // the unit of work, and the answer belongs wherever the conversation
    // actually is. The pills name them all.
    final targets = _replyTargets(episodes);
    final target = _replyTargetFor(episodes, targets);

    // The same rung ladder the thread pane applies (see [_thread]): mail always
    // offers a box because it bottoms out at the clipboard, a chat only on the
    // top rung, because without `Chat.ReadWrite` there is nowhere for the text
    // to go. A storyline whose only reachable episodes are chats this build
    // cannot send to says where to reply instead.
    final canReply = target != null &&
        (target.source == 'email' ||
            ref.watch(draftProvider(target)).capability == SendCapability.send);

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            InlineAlert(
              severity: InlineAlertSeverity.error,
              text: error,
              maxLines: 2,
            ),
            const SizedBox(height: BondSpacing.s12),
          ],
          Expanded(child: panel),
          if (target != null) ...[
            const SizedBox(height: BondSpacing.s12),
            if (_storylineReplyOpenFor != storyline.id)
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => setState(
                      () => _storylineReplyOpenFor = storyline.id,
                    ),
                    icon: const Icon(Icons.reply_outlined, size: 16),
                    label: const Text('Reply…'),
                  ),
                ],
              )
            else ...[
              // The pills sit above the box rather than inside the `canReply`
              // branch: when the picked episode is a chat this build cannot
              // answer, they are exactly how the user reaches the thread it can.
              _replyHeaderForStoryline(target, targets),
              const SizedBox(height: BondSpacing.s8),
              // The target carries its own source — a picked chat is drafted and
              // sent down the chat path, a picked thread down the mail one.
              if (canReply) _composer(target) else _replyElsewhere(),
            ],
          ] else if (episodes.isNotEmpty) ...[
            const SizedBox(height: BondSpacing.s12),
            _replyElsewhere(),
          ],
        ],
      ),
    );
  }

  /// Every member conversation a reply can go to, keyed by which conversation
  /// it is, valued by the subject the picker names it with.
  ///
  /// The key carries its source because a conversation key is only unique
  /// within one: the mail and chat connectors mint keys with no knowledge of
  /// each other, so the two sets are disjoint only by accident of shape. The
  /// picker must never conflate a chat with the thread that happens to share
  /// its key — pick one and the answer would go out on the other.
  Map<DraftTarget, String> _replyTargets(
    List<StorylineEpisode> episodes,
  ) {
    return {
      for (final episode in episodes)
        (source: episode.source, conversationKey: episode.conversationKey):
            // A chat's messages carry no subject — Graph does not give them
            // one — so an episode built out of them has none either. Named by
            // who is on it instead, the way a chat is named everywhere else:
            // without this a storyline holding two chats would offer the user
            // two identical "(no subject)" rows to choose between.
            episode.subject.isEmpty
                ? episode.participants.join(', ')
                : episode.subject,
    };
  }

  /// Which member conversation a storyline's composer answers.
  ///
  /// The user's pick when they made one and it is still a member; otherwise the
  /// newest episode, which is nearly always the one actually waiting on an
  /// answer — the episodes arrive oldest first, so that is the last of them.
  DraftTarget? _replyTargetFor(
    List<StorylineEpisode> episodes,
    Map<DraftTarget, String> targets,
  ) {
    final picked = _storylineReplyKey;
    if (picked != null && targets.containsKey(picked)) return picked;
    for (final episode in episodes.reversed) {
      final key = (
        source: episode.source,
        conversationKey: episode.conversationKey,
      );
      if (targets.containsKey(key)) return key;
    }
    // Unreachable while targets is built from these episodes; null, not a
    // fake fallback, so a future divergence surfaces as "no reply bar".
    return null;
  }

  /// Opens the storyline's reply window on one episode's thread.
  ///
  /// Both halves, always: a box that opened on a different thread than the ask
  /// the user tapped would send the answer to the wrong conversation.
  void _openStorylineReply(String storylineId, StorylineEpisode episode) {
    setState(() {
      _storylineReplyKey = (
        source: episode.source,
        conversationKey: episode.conversationKey,
      );
      _storylineReplyOpenFor = storylineId;
    });
  }

  /// Which member thread the open reply window is answering, and the way out
  /// of it. The pills are the picker — every target is on screen at once, so
  /// switching threads is one click and nothing has to open over the spine.
  Widget _replyHeaderForStoryline(
    DraftTarget selected,
    Map<DraftTarget, String> targets,
  ) {
    return Row(
      children: [
        Text('Reply to', style: BondType.caption),
        const SizedBox(width: BondSpacing.s8),
        Expanded(child: _replyTargetPills(selected, targets)),
        IconButton(
          onPressed: () => setState(() => _storylineReplyOpenFor = null),
          icon: const Icon(Icons.close),
          iconSize: 16,
          tooltip: 'Close',
          padding: const EdgeInsets.all(BondSpacing.s4),
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// How much of a subject a pill carries. A pill's label does not ellipsize
  /// and the row wraps, so one long subject would take a whole line to itself.
  static const int _replyPillLabelCap = 40;

  Widget _replyTargetPills(
    DraftTarget selected,
    Map<DraftTarget, String> targets,
  ) {
    return BondFilterPillRow<DraftTarget>(
      options: targets.keys.toList(),
      selected: selected,
      labelOf: (key) {
        final subject = targets[key]!;
        final label = subject.isEmpty ? '(no subject)' : subject;
        // By grapheme cluster, not by index: `substring` cuts UTF-16 code
        // units and can split a surrogate pair or a ZWJ emoji, which renders
        // as the replacement glyph on the end of the pill.
        return label.characters.length > _replyPillLabelCap
            ? '${label.characters.take(_replyPillLabelCap)}…'
            : label;
      },
      onSelected: (key) => setState(() => _storylineReplyKey = key),
    );
  }

  Widget _thread(Conversation selected) {
    final target = (source: selected.source, conversationKey: selected.id);
    final thread = ref.watch(threadProvider(target));

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

    final draft = ref.watch(draftProvider(target));
    final pending = draft.pending;

    // Whether this pane offers to reply at all. Mail always does — the ladder
    // bottoms out at the clipboard, which needs no grant. A chat does only on
    // the top rung: there is no draft folder and no clipboard rung worth
    // showing for one, so without `Chat.ReadWrite` the pane says where to reply
    // instead of offering a box that could not send.
    final canReply = selected.source == 'email' ||
        draft.capability == SendCapability.send;

    // Computed from the STORED transcript, before the optimistic bubble is
    // appended: a queued reply must not hide the bar that is offering to take
    // it back.
    final answersSomebody = messages.isNotEmpty && messages.last.inbound;

    final shown = pending == null
        ? messages
        : [
            ...messages,
            Message(
              id: 'pending-send',
              outbound: true,
              source: selected.source,
              bodyText: pending.body,
              // UTC, like every stored timestamp: the open-ask comparison is
              // lexicographic over these strings, and a local-time stamp sorts
              // before the mail it answers for every zone west of UTC.
              receivedAt: DateTime.now().toUtc().toIso8601String(),
              pendingSend: true,
            ),
          ];

    final panel = ThreadDetailPanel(
      key: ValueKey(selected.id),
      conversation: selected,
      messages: shown,
      onMarkDone: () => ref
          .read(conversationsProvider.notifier)
          .markDone(selected.source, selected.id),
      onBack: () => setState(() {
        _selectedId = null;
        _selectedSource = null;
        _replyOpenFor = null;
      }),
      // The reply affordance rides at the end of the transcript so it reads as
      // attached to the message it answers. After the user's OWN last message
      // there is nothing to answer, and it renders nothing.
      afterTranscript: canReply && (answersSomebody || pending != null)
          ? _quickReplies(selected, target, draft)
          : null,
      // Every ask on the pane is a call to action, so every one of them opens
      // the box — the banner included. Null where there is no box to open.
      onOpenReply:
          canReply ? () => setState(() => _replyOpenFor = selected.id) : null,
      onAddToStoryline: () => setState(() => _pickingStorylineForThread =
          (source: selected.source, id: selected.id)),
      // Sender-scoped, because the screen is the layer that knows the address
      // behind the row. A thread with no address to key a rule on gets no item
      // rather than a rule keyed on the empty string, which would apply to
      // every anonymous sender at once.
      onSendToLater: selected.primaryEmail?.isNotEmpty == true
          ? () => _laterSender(selected.primaryEmail!, selected.source)
          : null,
      onKeepInInbox: () => _keepThread(selected.source, selected.id),
    );

    // The composer sits OUTSIDE the panel, in this column: the panel renders a
    // transcript and knows nothing about drafts or sending, and it stays that
    // way.
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            InlineAlert(
              severity: InlineAlertSeverity.error,
              text: error,
              maxLines: 2,
            ),
            const SizedBox(height: BondSpacing.s12),
          ],
          Expanded(child: panel),
          // Collapsed is the default: the box appears when the user says they
          // are writing, and until then the transcript has the pane to itself.
          if (canReply && _replyOpenFor == selected.id) ...[
            const SizedBox(height: BondSpacing.s12),
            _replyHeader(selected),
            const SizedBox(height: BondSpacing.s4),
            _composer(target),
          ] else if (!canReply) ...[
            const SizedBox(height: BondSpacing.s12),
            _replyElsewhere(),
          ],
        ],
      ),
    );
  }

  /// Who the open reply window is answering, and the way out of it.
  ///
  /// The sender's name where there is one, the subject where there is not:
  /// "Reply to (no subject)" is a poor line, but it is still an answer to
  /// "which thread am I typing into", which is what this row is for.
  Widget _replyHeader(Conversation selected) {
    final named = [
      for (final p in selected.participants)
        if (p.display.isNotEmpty) p.display,
    ];
    final who = named.isNotEmpty
        ? named.first
        : (selected.subject?.isNotEmpty == true
            ? selected.subject!
            : 'this thread');

    return Row(
      children: [
        Expanded(
          child: Text(
            'Reply to $who',
            style: BondType.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          onPressed: () => setState(() => _replyOpenFor = null),
          icon: const Icon(Icons.close),
          iconSize: 16,
          tooltip: 'Close',
          padding: const EdgeInsets.all(BondSpacing.s4),
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// The suggestions under the transcript, and everything a tap on one can do.
  Widget _quickReplies(
    Conversation selected,
    DraftTarget target,
    DraftState draft,
  ) {
    final notifier = ref.read(draftProvider(target).notifier);
    return QuickReplyBar(
      options: draft.options,
      armed: draft.capability == SendCapability.send,
      onPick: (option) => unawaited(_pickQuickReply(selected, option)),
      onReply: () => setState(() => _replyOpenFor = selected.id),
      onDismiss: () => unawaited(notifier.dismissOptions()),
      pending: draft.pending,
      onUndo: () => _cancelQueuedSend(target),
      // The way back from the ×, and the way in for a thread the queue never
      // drafted: `generate` deletes the row the dismissal is recorded on and
      // asks the queue for a fresh pair. Withheld where that row is the user's
      // own typing or a sent reply — see [DraftState.suggestable].
      onSuggest: draft.suggestable ? () => unawaited(notifier.generate()) : null,
      suggesting: draft.generating,
    );
  }

  /// Takes back a queued reply, from either of the two places that offer to —
  /// the snackbar and the bar under the transcript. Both have to forget the
  /// announcement as well as cancel the timer, or a send that never happened
  /// leaves a listener waiting for it.
  void _cancelQueuedSend(DraftTarget target) {
    ref.read(draftProvider(target).notifier).cancelQueuedSend();
    if (!mounted) return;
    setState(() => _announceSendsFor.remove(target));
  }

  /// A card was tapped.
  ///
  /// Under a real send grant this queues the reply and says so, with an undo
  /// for as long as the send is still cancellable. Without one it opens the
  /// reply window with the text already in it — the honest version of the same
  /// gesture, since nothing in this build could put that mail in front of
  /// anyone anyway.
  Future<void> _pickQuickReply(Conversation c, DraftOption option) async {
    final target = (source: c.source, conversationKey: c.id);
    if (ref.read(draftProvider(target)).capability != SendCapability.send) {
      setState(() => _replyOpenFor = c.id);
      await ref.read(draftProvider(target).notifier).markEdited(option.body);
      return;
    }
    await _queueQuickReply(target, option.body);
  }

  /// Arms the send a tapped card asked for, wherever the card was — under the
  /// transcript or on a storyline's episode. One helper because the two
  /// surfaces must not drift: the announcement, the undo window and the words
  /// on the snackbar are the same promise either way.
  Future<void> _queueQuickReply(DraftTarget target, String body) async {
    setState(() => _announceSendsFor.add(target));
    await ref.read(draftProvider(target).notifier).queueSend(body);
    _toast('Reply sending.', onUndo: () => _cancelQueuedSend(target));
  }

  /// What stands where the reply box would be when this build cannot send to a
  /// chat — a grant without `Chat.ReadWrite`, in the thread pane and in a
  /// storyline whose reply target is one of those chats.
  ///
  /// A statement of capability rather than a dead end now: with the grant, a
  /// chat gets the same reply surface a mail thread does. Quiet and one line
  /// either way — it is an answer to "where do I reply?", not a feature.
  Widget _replyElsewhere() => Padding(
        padding: const EdgeInsets.symmetric(vertical: BondSpacing.s8),
        child: Text('Reply in Microsoft Teams', style: BondType.caption),
      );

  // ── the reply box ──────────────────────────────────────────────────────

  /// What the provenance caption says above an untouched suggestion.
  ///
  /// A CONSTANT, and knowingly less specific than it could be. The `drafts`
  /// table stores the model's evidence sentence but no inventory of what went
  /// into the prompt, so a line naming "2 past emails with Eric" would be
  /// assembled at render time out of guesses. The evidence sentence — which IS
  /// what the model said it was doing — rides along as the tooltip instead.
  static const String _provenance =
      '✨ Suggested reply — drafted from this thread and your past mail';

  /// One conversation's reply box.
  ///
  /// Every argument that can reach a send is a callback the user's own click
  /// invokes. Nothing on this path runs on a timer or on a state change.
  Widget _composer(DraftTarget target) {
    final conversationKey = target.conversationKey;
    final draft = ref.watch(draftProvider(target));
    final notifier = ref.read(draftProvider(target).notifier);

    final composer = Composer(
      // Keyed on the conversation so switching threads builds a fresh field
      // rather than carrying one thread's typed text into another's — and on
      // the send epoch, so a COMPLETED send builds a fresh empty one instead
      // of leaving the sent text armed behind a re-enabled button.
      key: ValueKey('composer-$conversationKey-${draft.sendEpoch}'),
      suggestedBody: draft.body,
      provenance: _provenance,
      generating: draft.generating,
      sending: draft.sending,
      capability: draft.capability,
      onSend: (body) => _send(target, body),
      // Both sources, unconditionally. A chat is drafted through the same
      // queue and the same system prompt a mail is — only the channel's style
      // rules differ, and those ride in the user message — so Regenerate means
      // exactly the same thing on either kind of thread.
      onGenerate: notifier.generate,
      onDismiss: notifier.dismiss,
      onEdited: notifier.markEdited,
    );

    final evidence = draft.evidence;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (draft.error != null) ...[
          InlineAlert(
            severity: InlineAlertSeverity.error,
            text: draft.error!,
            maxLines: 2,
          ),
          const SizedBox(height: BondSpacing.s8),
        ],
        if (evidence == null)
          composer
        else
          Tooltip(message: evidence, child: composer),
      ],
    );
  }

  /// The one place a click becomes a send. It says what happened, including
  /// when what happened was a copy.
  Future<void> _send(DraftTarget target, String body) async {
    final outcome = await ref.read(draftProvider(target).notifier).send(body);
    if (!mounted) return;
    switch (outcome) {
      case SendOutcome.sent:
        _toast('Reply sent.');
      case SendOutcome.savedToOutlook:
        _toast('Saved to your Outlook drafts.');
      case SendOutcome.copied:
        _toast('Copied. Paste it into your mail app to send.');
      case SendOutcome.failed:
        // The reason is already on the inline alert above the composer, where
        // it stays put rather than timing out under the user.
        break;
    }
  }

  /// What the sync and the local model have been doing, over the last week.
  ///
  /// [activitySnapshotProvider] re-reads once per recorded event, so a sync
  /// landing while the panel is open appears without a refresh. It also
  /// re-reads on the events the recorder SUPPRESSED — a poll that brought
  /// nothing in emits a transient tick and writes no row — and that is what
  /// keeps the panel's relative times honest: the "last sync" tiles come from
  /// prefs read in that same pass, so without a tick roughly once a minute they
  /// would freeze at whatever they said when the panel opened.
  ///
  /// Each re-read is a handful of indexed queries. Even a first sync of a large
  /// mailbox records one row per drained item, not per message. If a future
  /// drain ever ticks fast enough to be felt here, the debounce in
  /// `conversations_provider` is the documented pattern to copy.
  Widget _activityLog() {
    // The previous snapshot is carried through a reload, so this is null only
    // before the very first read of the pane.
    final snapshot = ref.watch(activitySnapshotProvider).valueOrNull;
    final health = ref.watch(pipelineHealthProvider).valueOrNull;
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Activity', style: BondType.title),
          const SizedBox(height: BondSpacing.s16),
          Expanded(
            child: snapshot == null
                ? const Center(child: CircularProgressIndicator())
                : ActivityLogPanel(
                    stats: snapshot.stats,
                    events: snapshot.events,
                    now: DateTime.now(),
                    lastMailSyncIso: snapshot.lastMailSyncIso,
                    lastTeamsSyncIso: snapshot.lastTeamsSyncIso,
                    lastSweepIso: snapshot.lastSweepIso,
                    entityLabel: snapshot.labelFor,
                    deadItems:
                        health == null ? 0 : health.triageDead + health.workDead,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _overview(List<Conversation> conversations, String? loadError) {
    final section = _selectedLaterDay != null
        ? RailSection.later
        : (_section ?? RailSection.needsYou);
    final day = _selectedLaterDay;
    final title = (section == RailSection.later && day != null)
        ? 'Later · ${formatDayLabel(day) ?? day}'
        : section.label;

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: BondType.title),
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
    if (section == RailSection.later) {
      return LaterDigestPanel(
        conversations: conversations,
        dayFilter: _selectedLaterDay,
        onOpen: (source, id) => _select(id, source: source),
        onKeepSender: _keepSender,
        onKeepThread: _keepThread,
      );
    }

    final sections = switch (section) {
      // Same threshold and the same ordering as the rail, so the "+N more" row
      // opens the list it promised rather than a longer one. Anything the
      // threshold cut is still in Conversations below — that is what makes the
      // slider safe to turn all the way down.
      RailSection.needsYou => [
          (
            'NEEDS YOU',
            needsYouRows(
              conversations,
              threshold: ref.watch(appPrefsProvider).attentionThreshold,
            ),
          ),
        ],
      RailSection.conversations => [
          (
            'OPEN',
            conversationRows(
              conversations,
              threshold: ref.watch(appPrefsProvider).attentionThreshold,
            ),
          ),
        ],
      RailSection.later ||
      RailSection.storylines =>
        const <(String, List<Conversation>)>[],
    };

    return ConversationListPane(
      sources: _sources,
      filter: InboxFilter.open,
      conversations: conversations,
      selectedId: _selectedId,
      selectedSource: _selectedSource,
      onSelect: (source, id) => _select(id, source: source),
      sectionsOverride: sections,
      processingSince: ref.watch(sessionStartProvider),
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

/// One episode's suggestions, inside the card that holds the thread they
/// answer.
///
/// Its own widget because the spine renders every open card at once: watching
/// each episode's draft from the screen would rebuild the whole storyline
/// whenever any one of them changed, and the panel itself must stay
/// provider-free — it is handed a builder and never learns what comes back.
///
/// Renders NOTHING when there is nothing to offer. A card is not the place for
/// an empty state: the pane's own `Reply…` already owns that, and a row of
/// identical bare buttons down the spine would say nothing about any of them.
class _EpisodeQuickReplies extends ConsumerWidget {
  final DraftTarget target;

  /// Opens the storyline's reply window on this episode's thread.
  final VoidCallback onOpenReply;

  /// Arms a send of this text, with the undo window the screen announces.
  /// Reached only where the grant actually allows a send.
  final void Function(String body) onQueueSend;

  final VoidCallback onUndo;

  const _EpisodeQuickReplies({
    required this.target,
    required this.onOpenReply,
    required this.onQueueSend,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(draftProvider(target));
    final notifier = ref.read(draftProvider(target).notifier);
    if (draft.options.isEmpty && draft.pending == null) {
      return _suggestAgain(draft, notifier);
    }

    return Padding(
      // The card's own gap. The footer owns its spacing so that the empty case
      // above can leave no trace.
      padding: const EdgeInsets.only(top: BondSpacing.s12),
      child: QuickReplyBar(
        options: draft.options,
        armed: draft.capability == SendCapability.send,
        onPick: (option) {
          // The same honest split the thread pane makes: without a send grant
          // a tap opens the box with the words in it rather than appearing to
          // send them.
          if (draft.capability != SendCapability.send) {
            onOpenReply();
            unawaited(notifier.markEdited(option.body));
            return;
          }
          onQueueSend(option.body);
        },
        onReply: onOpenReply,
        onDismiss: () => unawaited(notifier.dismissOptions()),
        pending: draft.pending,
        onUndo: onUndo,
      ),
    );
  }

  /// The way back from a dismissal, on a card that has nothing to show.
  ///
  /// Offered only where the cards were closed rather than never written: a
  /// thread the model has not drafted for yet gets nothing, because a bare
  /// button on every card in the spine would say nothing about any of them.
  /// [DraftState.generate] deletes the row on its way to a new draft, so the
  /// `generating` arm is what keeps `Drafting…` on screen for the second the
  /// row is gone.
  Widget _suggestAgain(DraftState draft, DraftNotifier notifier) {
    // A drafted thread whose cards were closed — the one state a fresh pair
    // costs nothing. The `draft != null` half is what keeps a never-drafted
    // card rendering nothing at all.
    final hidden = draft.draft != null && draft.suggestable;
    final suggesting = draft.generating;
    if (!hidden && !suggesting) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s12),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: suggesting ? null : () => unawaited(notifier.generate()),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: Text(suggesting ? 'Drafting…' : 'Suggest a reply'),
          ),
        ],
      ),
    );
  }
}
