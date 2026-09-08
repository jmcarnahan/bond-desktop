import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/attachment_models.dart';
import '../models/message_models.dart';
import '../models/open_asks.dart' show latestOutboundAt;
import '../models/person.dart';
import '../models/storyline_models.dart';
import '../providers/activity_provider.dart';
import '../providers/app_providers.dart';
import '../providers/archive_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/draft_provider.dart';
import '../providers/home_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/notify_routing.dart';
import '../providers/prefs_provider.dart';
import '../providers/recipient_search_provider.dart';
import '../providers/storylines_provider.dart';
import '../services/attachments/attachment_bytes.dart';
import '../services/attachments/file_dialogs.dart';
import '../services/attachments/xlsx_reader.dart';
import '../services/backend/backend_types.dart';
import '../services/llm/draft_task.dart' show DraftOption;
import '../services/llm/model_probe.dart';
// [ModelSlot] arrives with `prefs_provider.dart`, which re-exports it — a
// second import of `model_slots.dart` for the same declaration is redundant.
import '../services/llm/needs_you_task.dart'
    show needsYouDefaultRules, needsYouOutputContract, needsYouRulesCap;
import '../services/triage_queue.dart';
import '../theme/tokens.dart';
import '../widgets/activity_log_panel.dart';
import '../widgets/app_rail.dart';
import '../widgets/archive_pane.dart';
import '../widgets/attachment_format.dart';
import '../widgets/chips.dart';
import '../widgets/composer.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/home_pane.dart';
import '../widgets/inline_alert.dart';
import '../widgets/message_history_host.dart';
import '../widgets/notification_ribbon.dart';
import '../widgets/preview/attachment_preview_panel.dart';
import '../widgets/preview/attachment_viewer_pane.dart';
import '../widgets/preview/pdf_preview.dart';
import '../widgets/preview/preview_engines.dart';
import '../widgets/preview/preview_kind.dart' show openRefused;
import '../widgets/quick_replies.dart';
import '../widgets/settings_screen.dart';
import '../widgets/source_filter.dart';
import '../widgets/storyline_pickers.dart';
import '../widgets/storyline_timeline.dart';
import '../widgets/thread_detail_panel.dart';
import '../widgets/time_format.dart';
import 'new_message_screen.dart';

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

  /// The three attachment collaborators, injectable for one reason: under
  /// `flutter test` the real pair must never be built. [PreviewEngines] holds
  /// the pdfrx renderer (a native library a test process cannot load), and
  /// [FileDialogs] and [AttachmentBytes] each reach a platform channel or a
  /// socket. Null in the app, which builds the real ones — see
  /// [_previewEngines].
  final PreviewEngines? previewEngines;
  final AttachmentBytes? attachmentBytes;
  final FileDialogs? fileDialogs;

  const InboxScreen({
    super.key,
    this.onSignedOut,
    this.previewEngines,
    this.attachmentBytes,
    this.fileDialogs,
  });

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
  ///
  /// Seeded from [initialSectionProvider] in [initState] rather than here: the
  /// pane the app lands on is a product decision, and a test that predates it
  /// overrides that provider instead of being rewritten around a new landing.
  RailSection? _section;
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

  /// Which pile Archive is showing. Kept here rather than in the pane so the
  /// tab survives every rebuild the sixty-second poll causes.
  ArchiveTab _archiveTab = ArchiveTab.later;

  /// Whether the main pane is showing the activity log. Exclusive with the
  /// three selections above for the same reason they are exclusive with each
  /// other: the pane shows exactly one thing, and every setter clears the rest
  /// rather than racing to be rendered.
  bool _showingActivityLog = false;

  /// Whether the main pane is showing Settings. It joins the same exclusive
  /// set as [_showingActivityLog] and the three selections above: one thing
  /// in the pane, and every setter clears the rest.
  bool _showingSettings = false;

  /// Whether the main pane is showing the New message screen. The same
  /// exclusive set again: composing is not a section, and it clears whatever
  /// was being read exactly as Settings and the log do.
  bool _showingCompose = false;

  /// The message whose history is open, as `(source, sourceMessageId)`. It
  /// joins the same exclusive set — every selector that clears Settings clears
  /// this too — but with one difference that is the whole point of it: opening
  /// it does NOT clear the selection underneath, so Back lands back on the
  /// thread or the section the question was asked from.
  ({String source, String id})? _showingHistory;

  /// Who or what compose was opened on, when something asked for it
  /// pre-filled. Null is the rail's own button — a blank message.
  OpenComposeIntent? _composePrefill;

  /// One HTTP client for every server check the settings screen makes, closed
  /// with the screen. Held here rather than built per check because a client
  /// per button press leaks a connection pool per press, and the probe is
  /// diagnostics that a user can hammer.
  final ModelServerProbe _probe = ModelServerProbe();

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

  /// The file the preview is showing, if any. An overlay ON the open thread
  /// rather than a peer of it: the transcript stays beside it, because a
  /// preview is read against the message that carried it. Cleared wherever the
  /// selection moves, exactly like [_replyOpenFor].
  AttachmentRef? _previewing;

  /// Whether that preview has the whole pane. Only meaningful with
  /// [_previewing], and cleared with it.
  bool _viewerFull = false;

  /// Built on first use and never under `flutter test` — see
  /// [InboxScreen.previewEngines]. Constructing [PdfrxRenderer] is what loads
  /// pdfium, so it happens when somebody opens a file and not when the screen
  /// is built.
  PreviewEngines? _engines;

  /// The picture for each attachment the rows have asked about, by attachment
  /// key. The provider IDENTITY is what Flutter's image cache keys on, so a
  /// new `MemoryImage` per build would restart the decode on every poll tick.
  final Map<String, ImageProvider> _thumbs = {};

  /// Which ones have been asked for, so a row rebuilding does not queue a
  /// second fetch for a picture that is already on its way — or ask again,
  /// forever, for one that came back null.
  final Set<String> _thumbRequested = {};

  /// The documents pinned in THIS session, by attachment key.
  ///
  /// The [AttachmentRef] a preview panel holds is a snapshot taken when the
  /// row was read: its `pinnedStorylineId` does not change when the store row
  /// does, so without this the button would still read 'Pin to storyline'
  /// after the pin landed. The shelf's own refs come back fresh from the
  /// store, so an unpin only has to drop the key.
  final Set<String> _pinnedKeys = {};

  /// The real engines, built once, on the first file anybody opens.
  PreviewEngines get _previewEngines =>
      widget.previewEngines ??
      (_engines ??= const PreviewEngines(
        pdf: PdfrxRenderer(),
        workbook: xlsxWorkbookDecoder,
      ));

  AttachmentBytes get _attachmentBytes =>
      widget.attachmentBytes ?? ref.read(attachmentBytesProvider);

  FileDialogs get _fileDialogs => widget.fileDialogs ?? const SystemFileDialogs();

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

  /// Whether the Storylines pane's own Sync is running. Local to this screen
  /// on purpose: it says nothing about the pipeline that the rail's counters
  /// do not already say — it is one button's label, and one button's label is
  /// not worth a provider.
  bool _syncing = false;

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
    _section = ref.read(initialSectionProvider);
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
    // The home feed reads sqlite alone, so it does not wait on the sync above
    // it: whatever is already stored is on screen in the first frames, and the
    // sync's arrivals land on the next read.
    Future.microtask(() {
      if (!mounted) return;
      ref.read(homeFeedProvider.notifier).load();
    });
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _probe.close();
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
  ///
  /// The ordering is load bearing. The list load starts FIRST, so the rail is
  /// never a tick behind. Everything the open thread shows is reloaded AFTER
  /// that sync has finished, because the rows this tick pulled in — a reply
  /// the user sent from Outlook, the Sent Items copy that takes an echo's
  /// place — must be on screen on THIS tick, not the next one. Reading the
  /// transcript beside the sync, as this did, meant a message could sit
  /// stored-but-unshown for a full minute.
  ///
  /// The returned future covers the whole pass — the sync and the reads behind
  /// it. Nothing on the timer path awaits it; [_syncNow] does, because it has
  /// a "Syncing…" label to hold up until the screen is actually showing what
  /// the pull brought in.
  Future<void> _refresh() async {
    if (!mounted) return;
    final mail = ref.read(conversationsProvider.notifier).load();
    ref.read(storylinesProvider.notifier).load();
    // The tiles otherwise re-read only behind a pipeline tick, and a row
    // crosses the stalled threshold by NOT ticking. This poll is the clock
    // that lets the In flight tile catch up with the rows under it, which
    // re-evaluate on every rebuild. A no-op when nobody is watching them.
    ref.invalidate(homeMetricsProvider);
    await mail;
    if (!mounted) return;
    final selected = _selectedId;
    if (selected != null) {
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
    await _reloadOpenThread();
  }

  /// Re-reads whatever transcript is open: the selected thread, or the
  /// selected storyline's timeline.
  ///
  /// Called after a send and after every pull, and it is the ONLY thing that
  /// puts a newly stored message on screen — the thread providers are one-shot
  /// reads, not watches. Bodies are not fetched: everything this reload is for
  /// is already stored, and a fetch here would put a network call on the timer
  /// path.
  Future<void> _reloadOpenThread() async {
    if (!mounted) return;
    final selected = _selectedId;
    if (selected != null) {
      await ref
          .read(
            threadProvider(
              (
                source: _selectedSource ?? 'email',
                conversationKey: selected,
              ),
            ).notifier,
          )
          .load(fetchBodies: false);
    }
    if (!mounted) return;
    final storyline = _selectedStorylineId;
    if (storyline != null) {
      await ref.read(storylineTimelineProvider(storyline).notifier).load();
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
    final mail = _refresh();
    unawaited(ref.read(readAckQueueProvider).pump());
    await _refreshTeams();
    // Held to the end rather than awaited first: the two pulls go out
    // together, as they always have, and this future is only here so a caller
    // that wants to know when the whole thing is done can find out.
    await mail;
  }

  /// The Storylines pane's Sync: [_refreshAll] and nothing else.
  ///
  /// There is no second, storyline-shaped sync to build. The ordinary pull
  /// ends by requeueing the sweep, and the sweep's catch-ups drain the
  /// refreshes and recaps that were owed — so asking for mail is already
  /// asking for the storylines to be brought up to date.
  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await _refreshAll();
    } catch (e) {
      // Every leg of the sync turns its own failure into the banner this pane
      // already shows. Anything arriving here is a bug worth a trace, and
      // never worth leaving the button saying "Syncing…" for the rest of the
      // session — which is what the `finally` is for.
      debugPrint('manual sync failed: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
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
    // The chat the user is looking at is the one they most want a pull they
    // asked for to have refreshed, and the list reload above does not touch
    // the transcript. No network: everything the pull found is already stored.
    await _reloadOpenThread();
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
    // The mail is gone from the file; the files have to go from the disk. The
    // cache is content-addressed and outside the database, so nothing above
    // would have taken it.
    await ref.read(attachmentCacheProvider).clear();
    _forgetThumbnails();
    _pinnedKeys.clear();
    // The preview holds an [AttachmentRef] out of the mailbox that was just
    // wiped, and the viewer rung would keep drawing it over the next person's
    // empty inbox. Cleared here rather than left to the next selection,
    // because signing out is not a selection.
    _previewing = null;
    _viewerFull = false;
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
      _showingSettings = false;
      _showingHistory = null;
      _showingCompose = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
      _previewing = null;
      _viewerFull = false;
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
      _showingSettings = false;
      _showingHistory = null;
      _showingCompose = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
      _previewing = null;
      _viewerFull = false;
      // The reply target belongs to the storyline that was open, not to this
      // one; the default below picks the newest thread in the new timeline.
      _storylineReplyKey = null;
      _storylineReplyOpenFor = null;
    });
    ref.read(storylineTimelineProvider(id).notifier).load();
  }

  void _selectSection(RailSection section) {
    // Arriving at Archive with the Dropped pile already picked re-reads it,
    // exactly as picking the pile does: the list has no bus behind it, so
    // arrival is its only chance to be current. The tab itself survives the
    // trip away on purpose — coming back lands on the pile the user left.
    if (section == RailSection.archive && _archiveTab == ArchiveTab.dropped) {
      ref.read(archiveProvider.notifier).refreshDropped();
    }
    setState(() {
      _section = section;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _showingActivityLog = false;
      _showingSettings = false;
      _showingHistory = null;
      _showingCompose = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
      _previewing = null;
      _viewerFull = false;
    });
  }

  /// Opens one day's Later digest. The section moves with it, so backing out of
  /// the day lands on the whole pile rather than wherever the user was before —
  /// and the tab moves with it too, since a day only means anything in Later.
  void _selectLaterDay(String dayKey) {
    setState(() {
      _section = RailSection.archive;
      _archiveTab = ArchiveTab.later;
      _selectedLaterDay = dayKey;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _showingActivityLog = false;
      _showingSettings = false;
      _showingHistory = null;
      _showingCompose = false;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
      _previewing = null;
      _viewerFull = false;
    });
  }

  /// Opens the activity log, which is a pane and not a section: it belongs to
  /// the app rather than to the mail, so it is reached from the rail's footer
  /// and clears whatever the user was reading.
  void _openActivityLog() {
    setState(() {
      _showingActivityLog = true;
      _showingSettings = false;
      _showingHistory = null;
      _showingCompose = false;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      _railOpen = false;
      _replyOpenFor = null;
      _previewing = null;
      _viewerFull = false;
    });
  }

  /// The storylines as of this build. Empty until the first load lands, and
  /// empty on a read failure — the rail's own placeholder is the right thing
  /// to show for both.
  List<Storyline> _storylines() {
    final state = ref.watch(storylinesProvider);
    return state is StorylinesLoaded ? state.storylines : const [];
  }

  /// The storylines the user said no to. Read from the same state as
  /// [_storylines] and never mixed into it: the rail folds these away under a
  /// heading of their own.
  List<Storyline> _dismissedStorylines() {
    final state = ref.watch(storylinesProvider);
    return state is StorylinesLoaded ? state.dismissed : const [];
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

    // The open thread's own sends, whoever started them. Both arms store the
    // reply BEFORE the epoch moves and before `onSent`'s list sync, which can
    // take seconds — so the row is sitting in sqlite, unread, for as long as
    // that sync runs. This is what reads it.
    //
    // Registered in `build` rather than in `initState` because the target is
    // the SELECTION: `ref.listen` re-registers on every build, so it follows
    // the user from thread to thread with no bookkeeping.
    final open = _selectedId;
    if (open != null) {
      ref.listen<DraftState>(
        draftProvider(
          (source: _selectedSource ?? 'email', conversationKey: open),
        ),
        (previous, next) {
          if (previous == null || !mounted) return;
          if (next.sendEpoch > previous.sendEpoch) {
            unawaited(_reloadOpenThread());
          }
        },
      );
    }

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
        case OpenComposeIntent():
          _openCompose(prefill: intent);
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
      dismissed: _dismissedStorylines(),
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
              !_showingActivityLog &&
              !_showingSettings &&
              !_showingCompose)
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
      // Back to a suggestion, which is where the row came from — so it leaves
      // the fold and re-joins the live list asking the same question.
      onRestoreStoryline: (id) =>
          ref.read(storylinesProvider.notifier).undismiss(id),
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
              // First of the actions: writing to somebody is the one thing
              // here that starts something rather than adjusting the app.
              _railAction(
                Icons.edit_outlined,
                'New message',
                () => _openCompose(),
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

  /// Opens Settings, which is a pane and not a section — it belongs to the
  /// app rather than to the mail, so it is reached from the rail's footer and
  /// clears whatever the user was reading, exactly as the activity log does.
  void _openSettings() {
    setState(() {
      _showingSettings = true;
      _showingHistory = null;
      _showingActivityLog = false;
      _showingCompose = false;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      // At narrow widths the rail is an overlay: leaving it open would put the
      // pane the gear just opened behind a scrim.
      _railOpen = false;
      _replyOpenFor = null;
      _previewing = null;
      _viewerFull = false;
    });
  }

  void _closeSettings() => setState(() => _showingSettings = false);

  /// Opens one message's history over whatever is on screen.
  ///
  /// Deliberately NOT a selector: it clears nothing but the rail, because the
  /// question "why did this happen" is always asked about something the reader
  /// is already looking at, and Back has to put them back where they were.
  /// [_main]'s rung order is what makes that true.
  void _openHistory(String source, String id) {
    setState(() {
      _showingHistory = (source: source, id: id);
      // At narrow widths the rail is an overlay: leaving it open would put the
      // pane behind a scrim.
      _railOpen = false;
    });
  }

  /// Saves the Needs You rules and re-asks the recent window under them.
  ///
  /// The editor replaces the WHOLE prompt body, so a Save changes how every
  /// message is judged — and every verdict already on disk was written under
  /// the words the owner has just replaced. The last week is re-asked so the
  /// chip and the tile follow what the new rules say (the needs-you handler's
  /// tail rewrites the flag when a verdict moves); anything older is history
  /// rather than a mistake, because those rules were the rules at the time.
  ///
  /// It lives here rather than on [AppPrefsNotifier] because the notifier
  /// holds a store and nothing else: the activity log and the worker pump are
  /// this host's, and a pref writer that reached for them would be a pref
  /// writer that could not be tested without them.
  Future<void> _saveNeedsYouRules(String text) async {
    // The editor already stores default-equal text as the empty string, so the
    // two strings compared here are in the same normal form and an unchanged
    // Save re-judges nothing.
    final before = ref.read(appPrefsProvider).needsYouRules;
    final notifier = ref.read(appPrefsProvider.notifier);
    unawaited(notifier.setNeedsYouRules(text));
    if (text == before) return;

    // Everything the rest of this needs is read BEFORE the first await, so a
    // Settings pane closed while the requeue is on disk still gets its log
    // row and its wake — the work is queued by then, and a queue nobody
    // pumped would sit until the next sync. Nothing below touches `ref`.
    final store = ref.read(messageStoreProvider);
    final log = ref.read(activityLogProvider);
    final worker = ref.read(aiWorkerProvider);
    final since = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 7))
        .toIso8601String();
    final queued = await store.requeueNeedsYouRejudge(
      sinceIso: since,
      sources: inboxSources,
    );
    if (queued == 0) return;
    await log.record(
      'needs_you_rejudge',
      count: queued,
      detail: {'since': since},
    );
    // The same wake the attachment digest's requeue relies on: on a running
    // drain this only sets the re-pump flag, and the future it returns is that
    // drain's.
    unawaited(worker.pump());
  }

  /// Opens the New message screen. A pane and not a section, like Settings and
  /// the log, and it clears the same things they do — including the reply
  /// window, which belongs to a thread that is no longer on screen.
  void _openCompose({OpenComposeIntent? prefill}) {
    setState(() {
      _showingCompose = true;
      _composePrefill = prefill;
      _showingSettings = false;
      _showingHistory = null;
      _showingActivityLog = false;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _addingToStorylineId = null;
      _pickingStorylineForThread = null;
      // At narrow widths the rail is an overlay: leaving it open would put the
      // pane the button just opened behind a scrim.
      _railOpen = false;
      _replyOpenFor = null;
      // The file being previewed belonged to that thread too. The ladder
      // would not show it without a selection, but a pane leaves the same
      // state behind whichever pane it was — Settings clears these, so does
      // this.
      _previewing = null;
      _viewerFull = false;
    });
  }

  /// Leaves compose. The prefill goes with it, so the rail's own button opens
  /// a blank message next time rather than whoever was addressed last.
  void _closeCompose() => setState(() {
        _showingCompose = false;
        _composePrefill = null;
      });

  Widget _compose() => NewMessageScreen(
        onBack: _closeCompose,
        onHome: () => _selectSection(RailSection.home),
        prefill: _composePrefill,
      );

  /// The tuning controls, the two owner texts, and what Microsoft granted. The
  /// threshold reloads the list as it changes — the whole point of the slider
  /// is watching Needs You grow and shrink under it — while about me and the
  /// Needs You rules are each saved by their own Save.
  ///
  /// It is also where SESSIONS are managed. The screen shows whether the
  /// backend it is currently pointing at is signed in, and signs in and out of
  /// it in place — the gate above never swaps the screen for a settings change,
  /// so this is the only place that work can happen.
  ///
  /// "Sign in again" is kept wired for the SDK permissions table, where it
  /// signs OUT and lets the gate take over. It is not rendered while the
  /// session block is on screen — that block's Sign in… is the same action,
  /// beside the state it fixes.
  ///
  /// `ref.watch` rather than the `ref.read` the dialog used: this is a build
  /// method now, and the Needs You summary reads the STORED rules to say
  /// whether they are custom — a Save from inside the screen only moves that
  /// line because this host rebuilds. Do not "optimise" it to `ref.read`.
  Widget _settings() {
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    // `watch` is legal here because this runs inside `build`, and it is what
    // keeps the three sync stamps live while the pane is open: the stamps
    // re-read on every recorded event, so a sync that lands behind Settings
    // moves the numbers in it. The stamps alone, not the activity snapshot —
    // that one re-reads the whole pane's table per event, and this pane wants
    // three preferences. The two below answer null in a widget test, where
    // there is no platform on the other end of the channel — the About
    // section then says 'Version unknown' rather than throwing.
    final stamps = ref.watch(syncStampsProvider).valueOrNull;
    final appInfo = ref.watch(appInfoProvider).valueOrNull;
    final databasePath = ref.watch(databasePathProvider).valueOrNull;
    return SettingsScreen(
      onBack: _closeSettings,
      onHome: () => _selectSection(RailSection.home),
      threshold: prefs.attentionThreshold,
      aboutMe: prefs.aboutMe,
      // The prefs setters update state first and persist behind the caller's
      // back on purpose (see AppPrefsNotifier) — `unawaited` says the discard
      // is that contract, not an oversight.
      onThresholdChanged: (value) {
        unawaited(notifier.setAttentionThreshold(value));
        if (!mounted) return;
        ref.read(conversationsProvider.notifier).load(syncFirst: false);
      },
      onAboutMeChanged: (text) => unawaited(notifier.setAboutMe(text)),
      needsYouRules: prefs.needsYouRules,
      needsYouDefaultRules: needsYouDefaultRules,
      needsYouFixedTail: needsYouOutputContract,
      needsYouRulesMaxLength: needsYouRulesCap,
      onNeedsYouRulesSaved: (text) => unawaited(_saveNeedsYouRules(text)),
      needsYouRejudging: ref.watch(needsYouPendingProvider).valueOrNull ?? 0,
      showActivityLog: prefs.showActivityLog,
      onShowActivityLogChanged: (on) =>
          unawaited(notifier.setShowActivityLog(on)),
      onOpenActivityLog: _openActivityLog,
      notifyStyle: prefs.notifyStyle,
      onNotifyStyleChanged: (style) => unawaited(notifier.setNotifyStyle(style)),
      homeShowDropped: prefs.homeShowDropped,
      onHomeShowDroppedChanged: (on) {
        unawaited(notifier.setHomeShowDropped(on));
        if (!mounted) return;
        // The feed reads this preference ONCE, when its notifier is built, so
        // the pref alone would not move the list until the next launch. This is
        // the same call HomePane's own toggle makes — the preference is what
        // the next launch reads, this is what the user sees now.
        ref.read(homeFeedProvider.notifier).setIncludeDropped(on);
      },
      storylineNewestFirst: prefs.storylineNewestFirst,
      onStorylineNewestFirstChanged: (on) =>
          unawaited(notifier.setStorylineNewestFirst(on)),
      // BOTH sources are wired, and deliberately not bound to the mode the
      // screen OPENED in: the toggle switches backends in place, so which one
      // answers is the screen's live choice. Each closure reads the providers
      // at CALL time — after a switch, the re-ask lands on the session the
      // switch just built.
      //
      // Every closure that touches `ref` starts with a mounted check. The work
      // behind them outlives the pane — a sign-in still out in the browser, a
      // sign-out from the rail — and a dead host must answer with nothing,
      // never with "ref after dispose".
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
        _closeSettings();
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
          // And the previous person's about-me text and needs-you rules,
          // which the notifier still holds in memory — same reason
          // SignInScreen clears them. Both editors adopt the wipe only if
          // their own field is clean, so an unsaved edit survives it.
          unawaited(ref.read(appPrefsProvider.notifier).setAboutMe(''));
          unawaited(ref.read(appPrefsProvider.notifier).setNeedsYouRules(''));
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
      // The effective targets, defaults already resolved: the editors open on
      // real values rather than on the empty strings that mean "follow the
      // build" in the database.
      slotTargets: {
        for (final slot in ModelSlot.values) slot: prefs.targetFor(slot),
      },
      slotIsDefault: {
        for (final slot in ModelSlot.values) slot: prefs.isSlotDefault(slot),
      },
      probeServer: _probe.probe,
      onSlotTargetChanged: (slot, {required url, required model}) =>
          unawaited(switch (slot) {
            ModelSlot.fast => notifier.setFastLlmTarget(url: url, model: model),
            ModelSlot.prose => notifier.setProseLlmTarget(
              url: url,
              model: model,
            ),
            // Display only — the screen offers no editor for it, and a write
            // that arrived here anyway must not invent one.
            ModelSlot.embed => Future<void>.value(),
          }),
      onSlotReset: (slot) => unawaited(notifier.clearSlotTarget(slot)),
      lastMailSyncIso: stamps?.mailIso,
      lastTeamsSyncIso: stamps?.teamsIso,
      lastSweepIso: stamps?.sweepIso,
      lastReconcileIso: stamps?.reconcileIso,
      // Handed over as the future it is, so the section's button can hold
      // 'Refreshing…' until both pulls are back.
      onRefreshNow: _refreshAll,
      mailLookbackDays: prefs.mailLookbackDays,
      teamsLookbackDays: prefs.teamsLookbackDays,
      // No sync is kicked here: the next sync — the sixty-second poll at the
      // latest — is what applies the new window.
      onMailLookbackChanged: (days) =>
          unawaited(notifier.setMailLookbackDays(days)),
      onTeamsLookbackChanged: (days) =>
          unawaited(notifier.setTeamsLookbackDays(days)),
      // The rail's Sign out, the whole wipe — deliberately NOT
      // [onSignOutOfServer] above, which leaves one server's session and
      // keeps the mail on this device.
      onSignOutAndClear: _signOut,
      // Measured on the way in, so the section says how much is actually
      // there rather than what the store thinks it wrote.
      attachmentCacheBytes: () =>
          ref.read(attachmentCacheProvider).sizeBytes(),
      // Both halves, always: the files on disk AND the columns pointing at
      // them. A row left holding a `blob_path` to a file that no longer exists
      // is how a preview shows an empty pane instead of re-downloading.
      onClearAttachmentCache: () async {
        await ref.read(attachmentCacheProvider).clear();
        await ref.read(messageStoreProvider).clearAttachmentBlobs();
        if (!mounted) return;
        // The providers this screen handed the rows point at files that no
        // longer exist; forgetting them lets the next open ask again.
        _forgetThumbnails();
        ref.invalidate(threadProvider);
      },
      appVersion: appInfo == null
          ? null
          : '${appInfo.version} (${appInfo.build})',
      databasePath: databasePath,
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
  /// settings screen reports "not signed in to this server" with a Sign in…
  /// beside it. The list underneath is simply empty until that happens, which
  /// is the truth about a server nobody has signed in to.
  void _reloadAfterBackendChange() {
    // Settings can be left, and the whole screen torn down, around an
    // in-flight change; a dead host must answer with nothing rather than with
    // "ref after dispose".
    if (!mounted) return;
    // The session just changed, so a "this account has no directory" verdict
    // about the old one is not evidence about the new one; take it back and
    // let the next search ask the server that is actually connected now.
    ref.read(recipientSearchProvider).resetScope();
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
    // The user is on their way to fix exactly the thing the cached verdict is
    // about, so it stops being worth believing the moment they leave. The next
    // search asks once and re-remembers if the grant is still refused.
    ref.read(recipientSearchProvider).resetScope();
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

  /// Exactly one view, never two: compose, then Settings, then the activity
  /// log, then the two picker panes, then the history screen, then the full
  /// attachment viewer, then the thread transcript, then the storyline
  /// timeline, then the section overview. The order is the priority — compose,
  /// Settings and the log come first because they are the three that are not
  /// about the mail already on screen, and a pane outranks what it was opened
  /// from because it is the newer thing the user asked for.
  ///
  /// The viewer sits directly above the transcript because that is what it was
  /// opened from and what Back returns to — and above the storyline too, since
  /// a chip in the spine opens the same pane and Back lands back on it.
  ///
  /// A selected Later day is not a case here: it is a section overview with a
  /// filter on it, and [_overviewBody] reads it.
  Widget _main(List<Conversation> conversations, String? loadError) {
    if (_showingCompose) return _compose();
    if (_showingSettings) return _settings();
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

    // Under the storyline picker and over everything else: the picker is
    // opened FROM the history screen's Add to storyline…, so it has to overlay
    // this, and its own Back lands back here. Everything below is what the
    // history was opened from, which is what Back off this pane returns to.
    final showing = _showingHistory;
    if (showing != null) return _history(showing);

    final viewing = _previewing;
    // A viewer whose thread vanished falls through — never setState in build;
    // the next selection clears it.
    final viewerStorylineId = _selectedStorylineId;
    if (viewing != null &&
        _viewerFull &&
        (_selected(conversations) != null ||
            (viewerStorylineId != null &&
                _storylineById(viewerStorylineId) != null))) {
      return _attachmentViewer(viewing);
    }

    final selected = _selected(conversations);
    if (selected != null) return _thread(selected);

    final storylineId = _selectedStorylineId;
    if (storylineId != null) {
      final storyline = _storylineById(storylineId);
      if (storyline != null) return _storyline(storyline);
    }

    // The last rung before the section overviews, so every selection above
    // still outranks it: a thread opened from the feed shows the thread, and
    // Home is what is left when nothing else is selected. A Later day is not a
    // section here — it is an overview with a filter — so it is checked too.
    if ((_section ?? RailSection.home) == RailSection.home &&
        _selectedLaterDay == null) {
      return _home();
    }

    return _overview(conversations, loadError);
  }

  /// The pipeline, as a table. Everything it renders is a prop — see
  /// [HomePane] — so this is the only place the home providers are read.
  Widget _home() {
    final feed = ref.watch(homeFeedProvider);
    return HomePane(
      rows: feed.rows,
      // The previous value is carried through a re-read, so this is null only
      // before the very first one lands.
      metrics: ref.watch(homeMetricsProvider).valueOrNull,
      hotStorylines: ref.watch(hotStorylinesProvider).valueOrNull ?? const [],
      includeDropped: feed.includeDropped,
      loaded: feed.loaded,
      loadingMore: feed.loadingMore,
      atEnd: feed.atEnd,
      loadError: feed.loadError,
      pendingNewCount: feed.pendingNewCount,
      entering: feed.entering,
      fading: feed.fading,
      collapsing: feed.collapsing,
      search: feed.search,
      searching: feed.searching,
      searchNotice: feed.searchNotice,
      now: DateTime.now(),
      // The same door a notification's OpenThreadIntent goes through: one
      // selector resolves the row's source, marks it read and loads the
      // transcript, and a second path into that would eventually disagree
      // with this one.
      onOpenThread: (source, key) => _select(key, source: source),
      onOpenStoryline: _selectStoryline,
      onLoadMore: () => ref.read(homeFeedProvider.notifier).loadMore(),
      onReleasePending: () =>
          ref.read(homeFeedProvider.notifier).releasePending(),
      onAnchoredChanged: (anchored) =>
          ref.read(homeFeedProvider.notifier).setAnchored(anchored),
      onToggleDropped: () => ref
          .read(homeFeedProvider.notifier)
          .setIncludeDropped(!feed.includeDropped),
      onSearch: (query) =>
          ref.read(homeFeedProvider.notifier).submitSearch(query),
      onExitSearch: () => ref.read(homeFeedProvider.notifier).exitSearch(),
      // Fire-and-forget, like Restore: the service swallows its own failures
      // and the row's next re-read is what reports whether anything moved.
      onRetry: (source, id) => unawaited(
        ref.read(pipelineRepairServiceProvider).retryOwed(source, id),
      ),
      // Two doors on every row — the stage bar and the Result cell — because
      // those are the two places a reader looks when the sentence is not the
      // one they expected.
      onOpenHistory: _openHistory,
    );
  }

  /// One message's whole story, and every lever beside it.
  ///
  /// The story itself, and every provider behind it, live in
  /// [MessageHistoryHost]; what is left here is what only this screen can
  /// answer — where Back goes, and where the storyline picker is drawn.
  Widget _history(({String source, String id}) target) {
    return MessageHistoryHost(
      target: target,
      // Back only leaves the pane. Whatever was underneath — the thread, the
      // archive, the home table — was never cleared, so it is still there.
      onBack: () => setState(() => _showingHistory = null),
      onHome: () => _selectSection(RailSection.home),
      onOpenThread: (threadSource, conversationKey) =>
          _select(conversationKey, source: threadSource),
      onOpenStoryline: _selectStoryline,
      // The picker overlays this pane rather than replacing it — see [_main] —
      // so filing from here comes back to the story it was filed from.
      onAddToStoryline: (source, threadKey) => setState(
        () => _pickingStorylineForThread = (source: source, id: threadKey),
      ),
      onKeepInInbox: _keepThread,
      onEditRules: _openSettings,
    );
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
        // Both awaited, and both reload the storyline they filed into — the
        // same ending `_addThreadPane.onPick` has. Fired and forgotten, the
        // pane closed over a write that had not landed, and the storyline's
        // spine showed the thread only when the next debounce happened to
        // come round.
        onPick: (id) async {
          await ref
              .read(storylinesProvider.notifier)
              .addThread(id, thread.source, thread.id);
          if (!mounted) return;
          setState(() => _pickingStorylineForThread = null);
          ref.read(storylineTimelineProvider(id).notifier).load();
        },
        onCreate: (title) async {
          final id = await ref.read(storylinesProvider.notifier).create(
                title,
                conversationKey: thread.id,
                source: thread.source,
              );
          if (!mounted) return;
          setState(() => _pickingStorylineForThread = null);
          ref.read(storylineTimelineProvider(id).notifier).load();
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
      onAcceptSuggestion: (charter) =>
          notifier.acceptCharterSuggestion(storyline.id, charter),
      onDismissSuggestion: () =>
          notifier.dismissCharterSuggestion(storyline.id),
      onRemoveThread: (source, key) async {
        await notifier.removeThread(storyline.id, source, key);
        if (!mounted) return;
        ref.read(storylineTimelineProvider(storyline.id).notifier).load();
      },
      // Empty for the frame before the read lands, like the members above.
      blocks: ref.watch(storylineBlocksProvider(storyline.id)).valueOrNull ??
          const [],
      onUnblockThread: (source, key) =>
          notifier.unblockThread(storyline.id, source, key),
      // The spine gains a card, so it reloads with the list — the same pair of
      // reads the remove above does, in the other direction.
      onAddBackThread: (source, key) async {
        await notifier.addThread(storyline.id, source, key);
        if (!mounted) return;
        ref.read(storylineTimelineProvider(storyline.id).notifier).load();
      },
      onAudit: () => notifier.auditNow(storyline.id),
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
          _previewing = null;
          _viewerFull = false;
        });
        unawaited(notifier.dismiss(storyline.id));
      },
      // The overview's Sync, on the screen you land on when you open one of
      // its cards. Same call, same flag: the pane is built from this screen's
      // build path, so the label follows _syncing without the panel holding
      // any state of its own.
      onSync: _syncNow,
      syncing: _syncing,
      // Empty for the frame before the read lands, like the members above.
      documents: ref
              .watch(storylineDocumentsProvider(storyline.id))
              .valueOrNull ??
          const [],
      // There is no split on this pane, so a file opens the whole thing. Both
      // routes in — the shelf and a chip in the spine — land on the same pane
      // for the same reason.
      onOpenDocument: (attachment) => setState(() {
        _previewing = attachment;
        _viewerFull = true;
      }),
      onOpenAttachment: (attachment) => setState(() {
        _previewing = attachment;
        _viewerFull = true;
      }),
      selectedAttachment: _previewing,
      thumbnailFor: _thumbnailFor,
      onPinDocument: (attachment) =>
          unawaited(_pinAttachment(attachment, storyline.id)),
      onUnpinDocument: (attachment) =>
          unawaited(_unpinDocument(storyline.id, attachment)),
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

  /// Compose to the people on [thread]. A chat is addressed as ITSELF — the
  /// message goes into it — while a mail thread yields its participants as To,
  /// minus the user, who is on every thread they have ever replied on.
  Future<void> _composeFrom(Conversation thread) async {
    if (thread.source == 'teams') {
      _openCompose(
        prefill: OpenComposeIntent(
          channel: RecipientChannel.teams,
          chat: thread,
        ),
      );
      return;
    }

    // A stored account is a keychain read, and a session that cannot answer is
    // no reason to refuse the compose: without an owner the only thing lost is
    // the filter that drops the user from their own To line.
    AccountInfo? owner;
    try {
      owner = await _account;
    } catch (_) {
      owner = null;
    }
    if (!mounted) return;

    final ownerKey = (owner?.mail ?? owner?.userPrincipalName)
        ?.trim()
        .toLowerCase();
    final seen = <String>{};
    final to = <Person>[];
    for (final p in thread.participants) {
      final email = p.email?.trim() ?? '';
      // A Teams roster entry stored on a mail row has no address to send to,
      // and the same person can appear on several messages of one thread.
      if (email.isEmpty || email.startsWith('teams:')) continue;
      final key = email.toLowerCase();
      if (key == ownerKey || !seen.add(key)) continue;
      to.add(Person(
        id: 'mail:$key',
        displayName: (p.name?.trim().isNotEmpty ?? false)
            ? p.name!.trim()
            : email,
        mail: email,
        // The SAME id `MessageStore.recentPeople` gives this person, so the
        // typeahead's own row for them collapses into the chip rather than
        // offering a duplicate — `Person` compares on the id.
        source: PersonSource.recent,
      ));
    }
    _openCompose(prefill: OpenComposeIntent(to: to));
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
    // The undo window's text, or the text of a send that has left it and whose
    // row is not in this transcript yet. One unbroken bubble from the click to
    // the stored row, and never both at once — see [DraftState.bubbleBody].
    final pendingBody = draft.bubbleBody(messages);

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

    final shown = pendingBody == null
        ? messages
        : [
            ...messages,
            Message(
              id: 'pending-send',
              outbound: true,
              source: selected.source,
              bodyText: pendingBody,
              // UTC, like every stored timestamp: the open-ask comparison is
              // lexicographic over these strings, and a local-time stamp sorts
              // before the mail it answers for every zone west of UTC.
              receivedAt: DateTime.now().toUtc().toIso8601String(),
              pendingSend: true,
            ),
          ];

    // Over the SHOWN transcript, optimistic bubble included: an outbound after
    // a message answered it, and the reply the user just queued counts. That is
    // what makes every card in the thread close at once the moment a send is
    // armed, rather than leaving older ones tappable behind a reply already on
    // its way.
    final lastOut = latestOutboundAt(shown);
    final notifier = ref.read(draftProvider(target).notifier);

    /// The suggestion offered under one message, or null where there is none
    /// left to offer.
    ///
    /// Every guard here is about honesty rather than tidiness: a card that can
    /// still be tapped is a card that can still send, so it goes the moment its
    /// message has been answered — by a synced reply or by a queued one.
    Widget? cardFor(Message m) {
      if (!m.inbound) return null;
      final row = draft.threadDrafts[m.id];
      if (row == null) return null;
      // 'edited' is the user's own words and belongs in the composer; 'sent'
      // and 'dismissed' are over.
      if ((row['status'] as String?) != 'suggested') return null;
      final options = draftOptionsOf(row);
      // Covers the closed-cards case too: `options_dismissed` reads as none.
      if (options.isEmpty) return null;
      // Strict, mirroring `hasOpenAsk`: an outbound at the same instant did not
      // answer this one.
      if (lastOut != null && lastOut.compareTo(m.receivedAt ?? '') > 0) {
        return null;
      }
      final armed = draft.capability == SendCapability.send;
      return QuickReplyBar(
        showReplyRow: false,
        options: options,
        armed: armed,
        onPick: (option) {
          // The same honest split `_pickQuickReply` makes: without a send grant
          // a tap opens the box with the words in it rather than appearing to
          // send them.
          if (!armed) {
            setState(() => _replyOpenFor = selected.id);
            unawaited(notifier.markEdited(option.body));
            return;
          }
          unawaited(_queueQuickReply(target, option.body, replyTo: m.id));
        },
        onReply: () => setState(() => _replyOpenFor = selected.id),
        onDismiss: () => unawaited(notifier.dismissOptionsFor(m.id)),
      );
    }

    final panel = ThreadDetailPanel(
      key: ValueKey(selected.id),
      conversation: selected,
      messages: shown,
      // The suggestions sit with the messages they answer. The panel places
      // them and never learns what they are.
      suggestionFor: cardFor,
      onMarkDone: () => ref
          .read(conversationsProvider.notifier)
          .markDone(selected.source, selected.id),
      onReopen: () => ref
          .read(conversationsProvider.notifier)
          .reopenThread(selected.source, selected.id),
      onBack: () => setState(() {
        _selectedId = null;
        _selectedSource = null;
        _replyOpenFor = null;
        _previewing = null;
        _viewerFull = false;
      }),
      // The reply affordance rides at the end of the transcript so it reads as
      // attached to the message it answers. After the user's OWN last message
      // there is nothing to answer, and it renders nothing.
      afterTranscript: canReply && (answersSomebody || pendingBody != null)
          ? _quickReplies(selected, target, draft)
          : null,
      // Every ask on the pane is a call to action, so every one of them opens
      // the box — the banner included. Null where there is no box to open.
      onOpenReply:
          canReply ? () => setState(() => _replyOpenFor = selected.id) : null,
      onAddToStoryline: () => setState(() {
        _pickingStorylineForThread = (source: selected.source, id: selected.id);
        _previewing = null;
        _viewerFull = false;
      }),
      // Sender-scoped, because the screen is the layer that knows the address
      // behind the row. A thread with no address to key a rule on gets no item
      // rather than a rule keyed on the empty string, which would apply to
      // every anonymous sender at once.
      onSendToLater: selected.primaryEmail?.isNotEmpty == true
          ? () => _laterSender(selected.primaryEmail!, selected.source)
          : null,
      onKeepInInbox: () => _keepThread(selected.source, selected.id),
      onCompose: () => unawaited(_composeFrom(selected)),
      // Opening a file is a selection like any other: it replaces whatever was
      // being previewed and always lands on the split, never on the full pane
      // the user may have left open for the last one.
      onOpenAttachment: (attachment) => setState(() {
        _previewing = attachment;
        _viewerFull = false;
      }),
      selectedAttachment: _previewing,
      thumbnailFor: _thumbnailFor,
      // Per MESSAGE, not per thread: the pipeline decides one message at a
      // time, and the row's own header is where the question is asked.
      onWhatHappened: (message) => _openHistory(message.source, message.id),
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
          // The target rides in only where there is a box to write into: a
          // chat with no send grant has no composer on this pane, and a draft
          // written for one would be spent on words nobody ever sees.
          Expanded(child: _threadBody(panel, target: canReply ? target : null)),
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

  /// How much of the thread pane a preview takes, and the two widths that stop
  /// it taking too much: below [_previewMinWidth] a preview is a column of
  /// clipped words, and below [_transcriptMinWidth] the transcript beside it is
  /// unreadable. When both cannot be had, the preview REPLACES the transcript
  /// rather than squeezing it — the same call the rail makes at
  /// [_twoPaneBreakpoint].
  static const double _previewFraction = 0.45;
  static const double _previewMinWidth = 360;
  static const double _previewMaxWidth = 640;
  static const double _transcriptMinWidth = 420;

  /// The transcript, and the file beside it when one is open.
  Widget _threadBody(Widget panel, {DraftTarget? target}) {
    final previewing = _previewing;
    if (previewing == null) return panel;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The thread rides in so the preview can offer 'Use in reply': the
        // draft is keyed by the conversation, not by the file. Null where
        // `canReply` is false — there is no composer to write into.
        final preview = _previewPanel(previewing, target: target);
        final available = constraints.maxWidth - BondSpacing.s16;
        // Narrow: one thing at a time. The composer below stays either way, so
        // a reply is still possible with the file on screen.
        if (constraints.maxWidth < _twoPaneBreakpoint) return preview;

        var width = (available * _previewFraction)
            .clamp(_previewMinWidth, _previewMaxWidth)
            .toDouble();
        if (available - width < _transcriptMinWidth) {
          width = available - _transcriptMinWidth;
        }
        if (width < _previewMinWidth) return preview;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: panel),
            const SizedBox(width: BondSpacing.s16),
            SizedBox(width: width, child: preview),
          ],
        );
      },
    );
  }

  /// Keyed by the file, so moving from one attachment to another builds a new
  /// panel — and its memoised fetches — rather than reusing the last one's.
  Widget _previewPanel(AttachmentRef attachment, {DraftTarget? target}) {
    // Read here rather than in the closure: this is the build path, and the
    // control has to appear the frame the thread's membership lands.
    final pinTo = _pinTargetFor(attachment);
    return AttachmentPreviewPanel(
      key: attachmentKey('preview', attachment),
      attachment: attachment,
      bytes: _attachmentBytes,
      engines: _previewEngines,
      onExpand: () => setState(() => _viewerFull = true),
      onClose: () => setState(() {
        _previewing = null;
        _viewerFull = false;
      }),
      onOpen: () => unawaited(_openAttachmentInOs(attachment)),
      onSave: () => unawaited(_saveAttachment(attachment)),
      // Only where there is a composer to write into — the caller passes a
      // null target when `canReply` is false. Opening the box is what makes
      // the new draft visible; the spinner in it is the notifier's own
      // `generating`, so nothing here waits.
      onUseInReply: target == null
          ? null
          : () {
              setState(() => _replyOpenFor = target.conversationKey);
              unawaited(ref.read(draftProvider(target).notifier).generate(
                    pinnedAttachmentIds: [attachment.attachmentId],
                  ));
            },
      // Nowhere to pin is not a disabled button, it is no button: a thread in
      // no storyline has nothing to offer here.
      onPinToStoryline:
          pinTo == null ? null : () => unawaited(_pinAttachment(attachment, pinTo)),
      pinned: _isPinned(attachment),
      onOpenLink: (url) => unawaited(_launchExternal(url)),
    );
  }

  /// The same panel with the pane to itself. Back returns to the split — the
  /// thread is still selected underneath — and Home clears everything.
  Widget _attachmentViewer(AttachmentRef attachment) {
    final pinTo = _pinTargetFor(attachment);
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: AttachmentViewerPane(
        key: attachmentKey('viewer', attachment),
        attachment: attachment,
        bytes: _attachmentBytes,
        engines: _previewEngines,
        // From a thread, Back drops to the split and the transcript is there
        // again. From a storyline there is no split to drop to, so the preview
        // goes with it and the pane underneath is the storyline.
        onBack: () => setState(() {
          _viewerFull = false;
          if (_selectedId == null) _previewing = null;
        }),
        onHome: () => _selectSection(RailSection.home),
        onOpen: () => unawaited(_openAttachmentInOs(attachment)),
        onSave: () => unawaited(_saveAttachment(attachment)),
        // No 'Use in reply' here: there is no composer on the full pane, and
        // an action whose result is off screen is not an action.
        onPinToStoryline:
            pinTo == null ? null : () => unawaited(_pinAttachment(attachment, pinTo)),
        pinned: _isPinned(attachment),
        onOpenLink: (url) => unawaited(_launchExternal(url)),
      ),
    );
  }

  /// Whether this file is already on a storyline's shelf.
  ///
  /// Two sources because the ref is a snapshot: the column it was read with,
  /// and [_pinnedKeys] for a pin this session made after that read.
  bool _isPinned(AttachmentRef attachment) =>
      attachment.pinnedStorylineId != null ||
      _pinnedKeys.contains(attachmentKey('pin', attachment).value);

  /// Which storyline a pin from this pane would go to, or null when there is
  /// nowhere to pin — which is what hides the control.
  ///
  /// From a thread: the oldest storyline that thread is live in. The set comes
  /// back in join order, so `.first` is the one it was filed under first,
  /// which is the one a person means by "this storyline" when the thread is in
  /// two. From the storyline pane there is no guessing: it is the storyline
  /// on screen.
  ///
  /// Watched, not read: this runs from a build path, and a thread joining a
  /// storyline has to make the control appear without a second selection.
  String? _pinTargetFor(AttachmentRef attachment) {
    final threadId = _selectedId;
    if (threadId == null) return _selectedStorylineId;
    final ids = ref
        .watch(storylineThreadIdsProvider(
          (source: attachment.source, conversationKey: threadId),
        ))
        .valueOrNull;
    if (ids == null || ids.isEmpty) return null;
    return ids.first;
  }

  /// Pins one file to a storyline and says which one it landed on.
  ///
  /// The title is read AFTER the write rather than carried in, because the
  /// caller is a build-path closure and the panel only ever holds the id.
  Future<void> _pinAttachment(
    AttachmentRef attachment,
    String storylineId,
  ) async {
    final store = ref.read(messageStoreProvider);
    await store.setAttachmentPinned(
      attachment.source,
      attachment.messageId,
      attachment.attachmentId,
      storylineId,
    );
    if (!mounted) return;
    setState(() =>
        _pinnedKeys.add(attachmentKey('pin', attachment).value));
    ref.invalidate(storylineDocumentsProvider(storylineId));
    final title = (await store.getStoryline(storylineId))?.title;
    if (!mounted) return;
    _toast(
      'Pinned ${attachment.name ?? 'the file'} to '
      '${title ?? 'the storyline'}.',
    );
  }

  /// Takes one file's PIN off a storyline. The file itself stays on the shelf
  /// whenever its thread is still a member — which is the ordinary case, and
  /// why the bar says 'Unpinned' rather than 'Removed'. What actually changes
  /// is the order: it stops floating at the top.
  ///
  /// The row the shelf hands back was read fresh from the store, so dropping
  /// the session key is enough to put the panel's button back to 'Pin to
  /// storyline'.
  Future<void> _unpinDocument(
    String storylineId,
    AttachmentRef attachment,
  ) async {
    await ref.read(messageStoreProvider).setAttachmentPinned(
          attachment.source,
          attachment.messageId,
          attachment.attachmentId,
          null,
        );
    if (!mounted) return;
    setState(() => _pinnedKeys.remove(attachmentKey('pin', attachment).value));
    ref.invalidate(storylineDocumentsProvider(storylineId));
    _toast('Unpinned ${attachment.name ?? 'the file'}.');
  }

  /// The picture for one attachment, or null while there is not one yet.
  ///
  /// Called from a row BUILDING, which is why nothing here awaits: the answer
  /// is whatever is already in hand, and the fetch that fills it in comes back
  /// through `setState`. The fetch itself traces to the user opening this
  /// thread, which is the only reason it is allowed to touch a chat's files at
  /// all (Microsoft's Teams terms — nothing on that connector may run from a
  /// timer).
  ImageProvider? _thumbnailFor(AttachmentRef attachment) {
    final key = attachmentKey('thumb', attachment).value;
    final cached = _thumbs[key];
    if (cached != null) return cached;

    // Already on disk from an earlier pass: no request, and a `FileImage`
    // whose identity is stable for as long as the map holds it.
    final path = attachment.thumbPath;
    if (path != null && path.isNotEmpty) {
      return _thumbs[key] = FileImage(File(path));
    }

    if (_thumbRequested.add(key)) unawaited(_loadThumb(key, attachment));
    return null;
  }

  void _forgetThumbnails() {
    _thumbs.clear();
    _thumbRequested.clear();
  }

  Future<void> _loadThumb(String key, AttachmentRef attachment) async {
    // Never throws, by contract — a picture that could not be made must not be
    // able to take out the transcript it was being drawn into.
    final png = await _attachmentBytes.thumbnailFor(attachment);
    if (!mounted || png == null) return;
    setState(() => _thumbs[key] = MemoryImage(png));
  }

  /// Hands the cached file to the operating system and lets it decide what
  /// opening means. Nothing here ever executes anything itself.
  ///
  /// Which is exactly why [openRefused] is checked again here: for a script or
  /// a macro document, the operating system's idea of opening IS executing,
  /// and a stranger's mail is where those arrive. The panel already hides the
  /// button; this is the guard behind it, so a second caller cannot get past
  /// the rule by not knowing about it.
  Future<void> _openAttachmentInOs(AttachmentRef attachment) async {
    if (openRefused(attachment)) {
      _toast('This file can run, so it is Save only.');
      return;
    }
    try {
      final path = await _attachmentBytes.pathFor(attachment);
      await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
    } on Object {
      // The exception itself never reaches the bar: it is a path, a socket
      // error or a plugin's own words, and none of those tell the reader
      // anything they can act on.
      _toast('Could not open ${attachment.name ?? 'the file'}.');
    }
  }

  /// The save panel first, the bytes second: a cancelled save must not cost a
  /// download.
  ///
  /// The suggested name is clamped — see [safeSuggestedName]. It comes off the
  /// wire, and a name carrying separators reads as a path in the one field the
  /// user is about to accept without looking.
  Future<void> _saveAttachment(AttachmentRef attachment) async {
    final target = await _fileDialogs.chooseSaveLocation(
      suggestedName: safeSuggestedName(attachment.name),
    );
    if (target == null) return;
    try {
      final bytes = await _attachmentBytes.bytesFor(attachment);
      await File(target).writeAsBytes(bytes, flush: true);
      _toast('Saved ${attachment.name ?? 'the file'}.');
    } on Object {
      _toast('Could not save ${attachment.name ?? 'the file'}.');
    }
  }

  /// A file this app cannot fetch, opened where it actually lives.
  ///
  /// Web addresses only. The url is the SENDER's string — a Teams card or a
  /// reference attachment carries whatever the connector posted, verbatim —
  /// so handing it straight to the operating system would let a message
  /// launch a local application or mount a share behind a button that says
  /// 'Open in Teams'. The panel already refuses to draw that button; this is
  /// the guard behind it.
  Future<void> _launchExternal(String url) async {
    final uri = webUriOf(url);
    if (uri == null) {
      _toast('That link is not a web address.');
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      _toast('Could not open that link.');
    }
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

  /// The bar under the transcript: the composer's doorway, the way to ask for a
  /// suggestion, and the undo row while a send is queued.
  ///
  /// It carries no cards any more — a suggestion answers one message, and it is
  /// drawn under that message. What is left here is what belongs to the THREAD
  /// rather than to any message in it.
  Widget _quickReplies(
    Conversation selected,
    DraftTarget target,
    DraftState draft,
  ) {
    final notifier = ref.read(draftProvider(target).notifier);
    return QuickReplyBar(
      options: const [],
      armed: draft.capability == SendCapability.send,
      onPick: (option) => unawaited(_pickQuickReply(selected, option)),
      onReply: () => setState(() => _replyOpenFor = selected.id),
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

  /// Arms the send a tapped card asked for, wherever the card was — inline
  /// under a message, or on a storyline's episode. One helper because the two
  /// surfaces must not drift: the announcement, the undo window and the words
  /// on the snackbar are the same promise either way.
  ///
  /// [replyTo] is the message an inline card belongs to. Omitted, the send
  /// resolves its own target the way it always did — the thread's stored draft,
  /// then its newest inbound message.
  Future<void> _queueQuickReply(
    DraftTarget target,
    String body, {
    String? replyTo,
  }) async {
    setState(() => _announceSendsFor.add(target));
    await ref
        .read(draftProvider(target).notifier)
        .queueSend(body, replyTo: replyTo);
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
        // A second read, after the sync `send` runs on its way out. The epoch
        // listener already put the echo on screen; by now the Sent Items copy
        // may have replaced it, and this is what shows that swap.
        await _reloadOpenThread();
        if (!mounted) return;
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
        ? RailSection.archive
        : (_section ?? RailSection.needsYou);
    final day = _selectedLaterDay;
    final title = (section == RailSection.archive && day != null)
        ? 'Archive · ${formatDayLabel(day) ?? day}'
        : section.label;

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: BondType.title)),
              // Here and on the storyline screen, and nowhere else. Every
              // other pane is a view of the mailbox the sixty-second poll
              // already keeps current; a storyline is rewritten by a sweep,
              // and this is how the user asks for the pass that runs one.
              if (section == RailSection.storylines) _syncButton(),
            ],
          ),
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
    if (section == RailSection.archive) {
      final archive = ref.watch(archiveProvider);
      return ArchivePane(
        conversations: conversations,
        sources: _sources,
        // A day row is a Later row, so opening one puts the pane on the tab
        // that can show it whatever the user last picked.
        tab: _selectedLaterDay == null ? _archiveTab : ArchiveTab.later,
        // Picking a pile leaves the day narrowing: while a day is selected
        // the ternary above pins the pane to Later, so a tap that kept the
        // day would leave the other two pills dead under the user's finger.
        onTab: (tab) {
          // Entering the pile re-reads its first page. The dropped list has no
          // bus behind it — a sweep can add to it while the user is elsewhere
          // — so arriving is the moment it is worth being current.
          if (tab == ArchiveTab.dropped) {
            ref.read(archiveProvider.notifier).refreshDropped();
          }
          setState(() {
            _archiveTab = tab;
            _selectedLaterDay = null;
          });
        },
        dayFilter: _selectedLaterDay,
        onOpen: (source, id) => _select(id, source: source),
        onKeepSender: _keepSender,
        onKeepThread: _keepThread,
        onReopen: (source, key) => ref
            .read(conversationsProvider.notifier)
            .reopenThread(source, key),
        droppedRows: archive.droppedRows,
        droppedLoaded: archive.droppedLoaded,
        droppedLoadingMore: archive.droppedLoadingMore,
        droppedError: archive.droppedError,
        onLoadMoreDropped: () =>
            ref.read(archiveProvider.notifier).loadMoreDropped(),
        onOpenStoryline: _selectStoryline,
        // The pane sheds the row first and the pipeline catches up: the
        // service's own writes are what make it true, and its two pumps are
        // fire-and-forget by contract.
        onRestore: (source, id) {
          ref.read(archiveProvider.notifier).noteRestored(source, id);
          unawaited(ref.read(restoreServiceProvider).restore(source, id));
        },
        // The same door the home feed opens: a dropped row is exactly the one
        // somebody wants the reason for.
        onOpenHistory: _openHistory,
        search: archive.search,
        searching: archive.searching,
        searchNotice: archive.searchNotice,
        onSearch: (query) =>
            ref.read(archiveProvider.notifier).submitSearch(query),
        onExitSearch: () => ref.read(archiveProvider.notifier).exitSearch(),
        now: DateTime.now(),
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
      // Unreachable: [_main] routes Home to its own pane, and the two above
      // return before this switch. The arms exist so the analyzer keeps this
      // exhaustive when a stop is added.
      RailSection.home ||
      RailSection.archive ||
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

  /// The Sync action beside the Storylines heading. Quiet — a text button in
  /// the pane's own idiom, the same one the cards keep/dismiss with — because
  /// it is an offer, not the thing the pane is for.
  ///
  /// Inert while it runs, and saying so: a second pull started on top of the
  /// first would race the same connectors for nothing.
  Widget _syncButton() {
    return TextButton(
      onPressed: _syncing ? null : _syncNow,
      child: Text(_syncing ? 'Syncing…' : 'Sync'),
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
        // The recap in place of the one-line summary, exactly as the
        // storyline's own header does it: the two answer the same question at
        // different lengths, and the longer answer is the better card. The
        // paragraph ONLY — what is open and what was decided stay on the
        // storyline screen, where there is room to read them.
        final recap = storyline.recapText ?? '';
        final blurb = recap.isNotEmpty ? recap : (storyline.summary ?? '');
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
                        if (blurb.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            blurb,
                            style: BondType.caption,
                            maxLines: 4,
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
