import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/message_store.dart';
import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../providers/app_providers.dart';
import '../providers/conversations_provider.dart';
import '../providers/draft_provider.dart';
import '../providers/prefs_provider.dart';
import '../providers/storylines_provider.dart';
import '../services/activity_log.dart';
import '../services/backend/backend_types.dart';
import '../services/triage_queue.dart';
import '../theme/tokens.dart';
import '../widgets/activity_log_panel.dart';
import '../widgets/app_rail.dart';
import '../widgets/composer.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/inline_alert.dart';
import '../widgets/later_digest.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/source_filter.dart';
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
  /// reply that arrived while the LO was reading feels like it just showed
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

  /// Which member thread a storyline's composer replies to, when the user has
  /// picked one. Null means "the thread the newest message is in", which is
  /// what the dropdown shows by default — a storyline has no inbox of its own
  /// to reply to, so the composer always answers exactly one real thread.
  String? _storylineReplyKey;

  /// Narrow layouts only: whether the rail overlay is up.
  bool _railOpen = false;

  /// Which connector the list is showing: null for all, or a source name.
  String? _sourceFilter;

  /// When Teams was last pulled, by any route. Null until the first one.
  DateTime? _lastTeamsRefresh;

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
      ref.read(threadProvider(selected).notifier).load();
      // The sync deletes a draft whose thread just received new mail. The
      // composer must find that out NOW, not on the next AI progress event —
      // a stale suggestion left on screen gets sent as a reply to a message
      // that is no longer the newest one.
      ref.read(draftProvider(selected).notifier).load();
    }
    final storyline = _selectedStorylineId;
    if (storyline != null) {
      ref.read(storylineTimelineProvider(storyline).notifier).load();
    }
  }

  /// What the refresh button does: the mail refresh the timer also runs, plus
  /// the Teams pull the timer must never run.
  Future<void> _refreshAll() async {
    _refresh();
    await _refreshTeams();
  }

  /// The Teams pull, and the stamp that keeps the resume path from repeating
  /// it. Every route to Teams goes through here, so there is exactly one place
  /// the stamp can be forgotten and it is not forgotten.
  Future<void> _refreshTeams() async {
    if (!mounted) return;
    _lastTeamsRefresh = DateTime.now();
    await ref.read(conversationsProvider.notifier).refreshTeams();
  }

  Future<void> _signOut() async {
    await ref.read(authSessionProvider).signOut();
    // The keychain is not the only thing holding this account: the sqlite
    // file holds its mailbox, and the providers hold that in memory. A
    // different account signing in next must find neither — mail from two
    // mailboxes interleaved in one inbox is the bug this line rules out.
    ref.read(messageStoreProvider).wipeAll();
    ref.invalidate(conversationsProvider);
    ref.invalidate(storylinesProvider);
    ref.invalidate(threadProvider);
    ref.invalidate(draftProvider);
    ref.invalidate(storylineTimelineProvider);
    widget.onSignedOut?.call();
  }

  void _select(String id) {
    setState(() {
      _selectedId = id;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _showingActivityLog = false;
      _railOpen = false;
    });
    // The quietest signal the app collects: opening a thread is the LO saying
    // this one was worth their time. Fire-and-forget, and nothing on screen
    // reads it yet.
    ref.read(conversationsProvider.notifier).noteThreadOpened(id);
    ref.read(threadProvider(id).notifier).load();
    // Reads what the queue has already written for this thread. It never asks
    // for a new one — a draft is written by the background queue or by the
    // user's own button, never by opening a thread.
    ref.read(draftProvider(id).notifier).load();
  }

  void _selectStoryline(String id) {
    setState(() {
      _selectedStorylineId = id;
      _selectedId = null;
      _selectedLaterDay = null;
      _showingActivityLog = false;
      _railOpen = false;
      // The reply target belongs to the storyline that was open, not to this
      // one; the default below picks the newest thread in the new timeline.
      _storylineReplyKey = null;
    });
    ref.read(storylineTimelineProvider(id).notifier).load();
  }

  void _selectSection(RailSection section) {
    setState(() {
      _section = section;
      _selectedId = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _showingActivityLog = false;
      _railOpen = false;
    });
  }

  /// Opens one day's Later digest. The section moves with it, so backing out of
  /// the day lands on the whole pile rather than wherever the user was before.
  void _selectLaterDay(String dayKey) {
    setState(() {
      _section = RailSection.later;
      _selectedLaterDay = dayKey;
      _selectedId = null;
      _selectedStorylineId = null;
      _showingActivityLog = false;
      _railOpen = false;
    });
  }

  /// Opens the activity log, which is a pane and not a section: it belongs to
  /// the app rather than to the mail, so it is reached from the rail's footer
  /// and clears whatever the user was reading.
  void _openActivityLog() {
    setState(() {
      _showingActivityLog = true;
      _selectedId = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
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
  // in front of a one-click gesture the LO is going to make dozens of times;
  // an undo costs nothing when it is not used.

  /// How long the undo stays reachable. Long enough to notice the bar and
  /// react, short enough not to sit over the mail.
  static const Duration _undoDuration = Duration(seconds: 5);

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
    final previous = notifier.senderPref(address);
    final affected = await notifier.keepSenderInInbox(address, source: source);
    _toast(
      'Keeping $address in your inbox — ${_threads(affected)} moved back.',
      onUndo: () => notifier.restoreSenderPref(address, previous, source: source),
    );
  }

  Future<void> _laterSender(String address, String source) async {
    final notifier = ref.read(conversationsProvider.notifier);
    final previous = notifier.senderPref(address);
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
      selectedStorylineId: _selectedStorylineId,
      selectedLaterDay: _selectedLaterDay,
      laterCount: later.length,
      laterDays: laterDayCounts(conversations),
      attentionThreshold: ref.watch(appPrefsProvider).attentionThreshold,
      // A thread, a storyline or a Later day being open means no section
      // overview is showing, so the rail must not highlight one.
      selectedSection: (_selectedId == null &&
              _selectedStorylineId == null &&
              _selectedLaterDay == null &&
              !_showingActivityLog)
          ? _section
          : null,
      onSelectConversation: _select,
      onSelectSection: _selectSection,
      onSelectStoryline: _selectStoryline,
      onSelectLaterDay: _selectLaterDay,
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
    final label =
        relativeTime(ref.read(teamsSyncProvider).lastSyncedAt, DateTime.now());
    if (label == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s4),
      child: Text(
        'Teams updated $label',
        style: BondType.caption.copyWith(color: BondColors.onDarkMuted),
      ),
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
        onThresholdChanged: (value) {
          notifier.setAttentionThreshold(value);
          if (!mounted) return;
          ref.read(conversationsProvider.notifier).load(syncFirst: false);
        },
        onAboutMeChanged: notifier.setAboutMe,
        showActivityLog: prefs.showActivityLog,
        onShowActivityLogChanged: notifier.setShowActivityLog,
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
          notifier.setBackendMode(mode);
          _reloadAfterBackendChange();
        },
        onMcpServerUrlChanged: (url) {
          notifier.setMcpServerUrl(url);
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
            ref.read(appPrefsProvider.notifier).setAboutMe('');
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
    // Not in the FILTERED list. An explicit selection is the most specific
    // thing the user asked for and outranks the source filter — a storyline
    // seam chip can open a chat while the filter shows Mail, and landing on a
    // section overview instead would read as a broken click. The unfiltered
    // list settles whether the thread still exists at all.
    final state = ref.read(conversationsProvider);
    if (state is ConversationsLoaded) {
      for (final c in state.conversations) {
        if (c.id == _selectedId) return c;
      }
    }
    // A thread can leave the list between renders — a sync that moved it, or
    // a mark-done. The pane falls back to the overview rather than showing a
    // stale copy.
    return null;
  }

  /// Exactly one view, never two: the activity log, then the thread
  /// transcript, then the storyline timeline, then the section overview. The
  /// order is the priority — the log is first because it is the only one of
  /// the four that is not about the mail at all, so nothing under it can be
  /// what the user meant.
  ///
  /// A selected Later day is not a case here: it is a section overview with a
  /// filter on it, and [_overviewBody] reads it.
  Widget _main(List<Conversation> conversations, String? loadError) {
    if (_showingActivityLog) return _activityLog();

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

    // Chats are not reply targets — see [_replyElsewhere] for why. A storyline
    // of only chats therefore offers the caption instead of a dropdown, and a
    // mixed one offers its mail threads.
    final targets = _emailTargets(messages, keys, subjects);
    final replyKey = _replyTargetFor(messages, keys, targets);

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
          if (replyKey != null) ...[
            const SizedBox(height: BondSpacing.s12),
            _replyTargetPicker(replyKey, targets),
            const SizedBox(height: BondSpacing.s8),
            _composer(replyKey),
          ] else if (subjects.isNotEmpty) ...[
            const SizedBox(height: BondSpacing.s12),
            _replyElsewhere(),
          ],
        ],
      ),
    );
  }

  /// The member threads a reply can actually go to: the mail ones.
  ///
  /// Derived from the messages rather than from a source column on the
  /// subject map, because that is where the source lives — the timeline
  /// carries `conversation_key` and `subject` per thread and the source per
  /// message.
  Map<String, String> _emailTargets(
    List<Message> messages,
    Map<String, String> keyByMessageId,
    Map<String, String> subjectByKey,
  ) {
    final mailKeys = <String>{};
    for (final message in messages) {
      if (message.source != 'email') continue;
      final key = keyByMessageId[message.id];
      if (key != null) mailKeys.add(key);
    }
    return {
      for (final entry in subjectByKey.entries)
        if (mailKeys.contains(entry.key)) entry.key: entry.value,
    };
  }

  /// Which member thread a storyline's composer answers.
  ///
  /// The user's pick when they made one and it is still a member; otherwise the
  /// thread the newest message in the merged timeline belongs to, which is
  /// nearly always the one that is actually waiting on an answer.
  String? _replyTargetFor(
    List<Message> messages,
    Map<String, String> keyByMessageId,
    Map<String, String> subjectByKey,
  ) {
    final picked = _storylineReplyKey;
    if (picked != null && subjectByKey.containsKey(picked)) return picked;
    for (final message in messages.reversed) {
      final key = keyByMessageId[message.id];
      if (key != null && subjectByKey.containsKey(key)) return key;
    }
    return subjectByKey.keys.isEmpty ? null : subjectByKey.keys.first;
  }

  Widget _replyTargetPicker(String selected, Map<String, String> subjects) {
    return Row(
      children: [
        Text('Reply to', style: BondType.caption),
        const SizedBox(width: BondSpacing.s8),
        Expanded(
          child: DropdownButton<String>(
            value: selected,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final entry in subjects.entries)
                DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(
                    entry.value.isEmpty ? '(no subject)' : entry.value,
                    style: BondType.small,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (key) {
              if (key == null) return;
              setState(() => _storylineReplyKey = key);
            },
          ),
        ),
      ],
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
          const SizedBox(height: BondSpacing.s12),
          // Drafting and sending are EMAIL ONLY. A reply to a chat is not a
          // reply to an email: Graph builds a mail reply for this app through
          // `createReply`, which knows the recipients, the subject and the
          // threading headers, and none of that exists for a chat. A composer
          // here would be a box that cannot send.
          if (selected.source == 'email')
            _composer(selected.id)
          else
            _replyElsewhere(),
        ],
      ),
    );
  }

  /// What stands where the reply box would be on a chat thread. Quiet and
  /// one line: it is an answer to "where do I reply?", not a feature.
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
  Widget _composer(String conversationKey) {
    final draft = ref.watch(draftProvider(conversationKey));
    final notifier = ref.read(draftProvider(conversationKey).notifier);

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
      onSend: (body) => _send(conversationKey, body),
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
  Future<void> _send(String conversationKey, String body) async {
    final outcome =
        await ref.read(draftProvider(conversationKey).notifier).send(body);
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
  /// The [StreamBuilder] ticks once per recorded event, so a sync landing while
  /// the panel is open appears without a refresh. It also ticks on the events
  /// the recorder SUPPRESSED — a poll that brought nothing in emits a transient
  /// tick and writes no row — and that is what keeps the panel's relative times
  /// honest: the "last sync" tiles are read from prefs on every rebuild, so
  /// without a tick roughly once a minute they would freeze at whatever they
  /// said when the panel opened.
  ///
  /// Each tick costs two indexed reads against a synchronous database on the UI
  /// isolate, plus one pref read per tile. Even a first sync of a large mailbox
  /// records one row per drained item, not per message. If a future drain ever
  /// ticks fast enough to be felt here, the debounce in
  /// `conversations_provider` is the documented pattern to copy.
  Widget _activityLog() {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Activity', style: BondType.title),
          const SizedBox(height: BondSpacing.s16),
          Expanded(
            child: StreamBuilder<ActivityEvent>(
              stream: ref.watch(activityLogProvider).events,
              builder: (context, _) {
                final store = ref.watch(messageStoreProvider);
                final sinceIso = DateTime.now()
                    .toUtc()
                    .subtract(const Duration(days: 7))
                    .toIso8601String();
                return ActivityLogPanel(
                  stats: store.activityStats(sinceIso: sinceIso),
                  events: [
                    for (final row in store.recentActivity(limit: 300))
                      ActivityEvent.fromRow(row),
                  ],
                  now: DateTime.now(),
                  lastMailSyncIso: store.getPref(activityLastSyncMailKey),
                  lastTeamsSyncIso: store.getPref(activityLastSyncTeamsKey),
                  lastSweepIso: store.getPref(activityLastSweepKey),
                  entityLabel: (event) => _activityEntityLabel(store, event),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The subject of the thread an activity row was about, or null.
  ///
  /// Null is the common answer and not a failure: triage records a MESSAGE id,
  /// which is not a conversation key, and a thread can be deleted after the row
  /// that named it was written. Wrapped besides, because this runs inside a
  /// build and the panel is the last place in the app that should be able to
  /// throw.
  static String? _activityEntityLabel(MessageStore store, ActivityEvent event) {
    final entityId = event.entityId;
    if (entityId == null) return null;
    try {
      final row = store.getConversationRow(event.source ?? 'email', entityId);
      if (row == null) return null;
      final subject = Conversation.fromRow(row).subject;
      return subject != null && subject.isNotEmpty ? subject : null;
    } catch (_) {
      return null;
    }
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
        onOpen: _select,
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
      RailSection.conversations => [('OPEN', conversationRows(conversations))],
      RailSection.later ||
      RailSection.storylines =>
        const <(String, List<Conversation>)>[],
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
