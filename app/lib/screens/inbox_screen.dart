import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/message_store.dart' show MessageStore;
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
import '../providers/drafts_inbox_provider.dart';
import '../providers/files_provider.dart';
import '../providers/home_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/person_facts_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/notify_routing.dart';
import '../providers/prefs_provider.dart';
import '../providers/message_history_provider.dart';
import '../providers/recipient_search_provider.dart';
import '../providers/storylines_provider.dart';
import '../providers/why_provider.dart';
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
import '../services/profile_photos.dart' show photoKeyFor;
import '../services/triage_queue.dart';
import '../theme/tokens.dart';
import '../widgets/activity_log_panel.dart';
import '../widgets/app_rail.dart';
import '../widgets/archive_pane.dart';
import '../widgets/attachment_format.dart';
import '../widgets/chips.dart';
import '../widgets/composer.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/drafts_pane.dart';
import '../widgets/files_pane.dart';
import '../widgets/find_field.dart';
import '../widgets/find_filter.dart';
import '../widgets/bond_avatar.dart' show BondAvatar;
import '../widgets/home_pane.dart';
import '../widgets/icon_rail.dart';
import '../widgets/inline_alert.dart';
import '../widgets/message_history_host.dart';
import '../widgets/needs_you_tabs.dart';
import '../widgets/notification_ribbon.dart';
import '../widgets/people_rooms.dart';
import '../widgets/person_panel.dart';
import '../widgets/person_room_pane.dart';
import '../widgets/preview/attachment_preview_panel.dart';
import '../widgets/preview/attachment_viewer_pane.dart';
import '../widgets/preview/pdf_preview.dart';
import '../widgets/preview/preview_engines.dart';
import '../widgets/preview/preview_kind.dart' show openRefused;
import '../widgets/quick_replies.dart';
import '../widgets/room_header.dart';
import '../widgets/settings_screen.dart';
import '../widgets/side_panel.dart';
import '../widgets/source_filter.dart';
import '../widgets/storyline_pickers.dart';
import '../widgets/storyline_timeline.dart';
import '../widgets/thread_detail_panel.dart';
import '../widgets/time_format.dart';
import '../widgets/why_panel.dart';
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

  /// The `Show all` under an empty pane while a source pill is down.
  static const Key showAllSourcesKey = ValueKey('show-all-sources');

  /// The one-line hint above an empty box when a suggestion is waiting on its
  /// card — and the `Use it` that puts it in the box.
  static const Key useSuggestionKey = ValueKey('use-suggestion');

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

  /// The connectors every pane is scoped to right now.
  ///
  /// The source chips in the list column's header are the ONE control that
  /// says which mailbox halves are in play, so a pane that took its own would
  /// be a second answer to a question already on screen. Panes built from the
  /// conversations list get this narrowing for free through `bySource`; the
  /// ones that read the store themselves — the Files stop — ask here.
  List<String> get _activeSources =>
      _sourceFilter == null ? _sources : [_sourceFilter!];

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

  /// The open People room, as the key [roomKeyFor] minted for it. Exclusive
  /// with the three selections above, and a SELECTION rather than an overlay —
  /// so [_clearOverlays] does not touch it, and every selection setter nulls
  /// it by hand exactly as they null [_selectedStorylineId].
  ///
  /// A key and not a [PersonRoom]: rooms are derived from the conversation
  /// list on every build, so holding one would be holding a snapshot that
  /// stops agreeing with the rail the moment mail arrives.
  String? _selectedRoomKey;

  /// Which pile Archive is showing. Kept here rather than in the pane so the
  /// tab survives every rebuild the sixty-second poll causes.
  ArchiveTab _archiveTab = ArchiveTab.later;

  /// Which lens the Needs You overview is showing. Here for [_archiveTab]'s
  /// reason, and it survives a trip into a thread and back for the same one:
  /// coming back lands on the tab the reader left.
  NeedsYouTab _needsYouTab = NeedsYouTab.all;

  /// The Find field's text, and the two objects behind it.
  ///
  /// The controller and the node live on the SCREEN rather than in
  /// [FindField]: ⌘K has to reach the node from a binding wrapped around
  /// the whole `Scaffold`, and a field rebuilt on every keystroke could not
  /// own either without losing the cursor.
  final TextEditingController _findText = TextEditingController();
  final FocusNode _findFocus = FocusNode(debugLabel: 'find');
  String _find = '';

  /// The Files stop's own query box. Held here rather than in [FilesPane] for
  /// the reason every other pane's controller is: the pane is rebuilt on every
  /// answer, and a controller it owned would lose a half-typed query each time.
  final TextEditingController _filesSearchText = TextEditingController();

  /// Whether the list column is showing only rows with something unread.
  /// Never touches a badge — see [AppRail.unreadOnly].
  bool _unreadOnly = false;

  /// The rows and rooms THIS build handed the rail, so Enter in the Find field
  /// can walk exactly what the reader is looking at.
  ///
  /// Plain fields written during `build` rather than state: they are derived
  /// from the conversation list every frame, and setState-ing them would be
  /// setState-ing inside build. Nothing renders them — [_submitFind] reads
  /// them, once, in response to a keystroke.
  List<Conversation> _rows = const [];
  List<PersonRoom> _rooms = const [];

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

  /// The message the docked composer is answering, if the user named one.
  ///
  /// Unnamed is the DEFAULT and the ordinary case: a send with no target
  /// resolves its own the way it always did — the stored draft's row, then the
  /// thread's newest inbound. This is the override the hover **Reply** writes,
  /// and it carries the [DraftTarget] with it because a thread can be open in
  /// the main pane and ANOTHER one beside it: each box compares this against
  /// its own target, and one message id could not say which of the two is
  /// being answered.
  ///
  /// `who` is stored rather than looked up: the caption names the sender of a
  /// message that may have scrolled away, and re-deriving it every frame would
  /// mean holding the transcript to draw one line.
  ({DraftTarget target, String messageId, String who})? _replyTo;

  /// Which threads have a suggestion IN their box, and which text.
  ///
  /// A suggestion the pipeline wrote stays on its card in the transcript until
  /// the reader asks for it, so the box under a thread starts empty and one
  /// line tall. Putting text into it — "staging" — is what a card tap, a
  /// Suggest / Draft reply / Regenerate, a Use in reply, or the `Use it` hint
  /// does.
  ///
  /// The value is an explicit body (a tapped card's option) or null for "the
  /// draft's own body" (a generate the reader asked for), keyed by
  /// `'$source|$conversationKey'`. Screen state and not provider state: it is a
  /// fact about a box on this screen, not about the stored draft, and the same
  /// draft read on another screen has nothing in any box.
  final Map<String, String?> _staged = {};

  String _stageKey(DraftTarget t) => '${t.source}|${t.conversationKey}';

  void _stage(DraftTarget t, {String? body}) =>
      setState(() => _staged[_stageKey(t)] = body);

  void _unstage(DraftTarget t) => setState(() => _staged.remove(_stageKey(t)));

  /// The text the box should hold for [target], or null for an empty box.
  ///
  /// Absent from the map means nothing was staged; present with null means the
  /// reader asked for the draft itself, which is read live so the words appear
  /// the moment a generate lands.
  String? _stagedBodyFor(DraftTarget target, DraftState draft) {
    final key = _stageKey(target);
    if (!_staged.containsKey(key)) return null;
    final explicit = _staged[key];
    return explicit ?? draft.body;
  }

  /// Where each pane's composer takes its cursor from. The nodes live HERE and
  /// not in the composers: a `Composer` is rebuilt with a new key on every send
  /// epoch and on every change of thread, so a node it owned would be disposed
  /// exactly when the focus is meant to survive.
  final FocusNode _mainComposerFocus = FocusNode(debugLabel: 'main composer');
  final FocusNode _sideComposerFocus = FocusNode(debugLabel: 'side composer');

  /// What is open beside the main pane, if anything: a file, or a thread
  /// reached from inside a storyline. An overlay ON what the main pane is
  /// showing rather than a peer of it — a file is read against the message
  /// that carried it, and a thread against the storyline it belongs to.
  /// Cleared wherever the selection moves, exactly like [_replyTo].
  SidePanel? _side;

  /// Whether that panel has the whole main pane. Only ever true of a
  /// [FilePanel] — ⤢ on a thread hands it to the main pane proper, which
  /// clears [_side] — and cleared with it.
  bool _sideFull = false;

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
  /// meanwhile. Nothing on this screen queues a send any more — a card stages
  /// its words rather than sending them — so this stands empty; the listener
  /// and the undo path stay because the provider's queued send is still API,
  /// and the composer's own send reports its outcome directly.
  ///
  /// A SET, because the storyline spine renders an armed card per open episode
  /// and two sends can be in flight at once. One slot silenced the first send's
  /// outcome — including its failure.
  final Set<DraftTarget> _announceSendsFor = {};

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
  /// pull. See [_refreshAction], whose tooltip is the only thing that shows it.
  Future<String?>? _teamsSyncedAt;

  Timer? _poll;

  /// Set once the sign-out route is under way, so a second notification
  /// cannot start it again mid-teardown.
  bool _leaving = false;

  late final Future<AccountInfo?> _account =
      ref.read(authSessionProvider).storedAccount;

  /// The signed-in account once [_account] has resolved, held in state because
  /// the People grouping needs it SYNCHRONOUSLY on every build — a
  /// FutureBuilder around the rail would rebuild the whole column, and the
  /// grouping is a pure function that wants a value, not a future.
  ///
  /// Null for the first frames, which groups every thread by everyone on it,
  /// the owner included. One rebuild later it is right, and nothing was
  /// blocked waiting for a keychain read.
  AccountInfo? _owner;

  /// The owner as [peopleRooms] wants them.
  Owner get _ownerRecord =>
      (name: _owner?.displayName, address: _owner?.mail ?? _owner?.userPrincipalName);

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
    // LAST of the three, deliberately: this is a keychain read whose only
    // consumers are the People grouping and one avatar, and queueing it ahead
    // of the list load would put a face in front of the mail.
    //
    // Resolved once and kept, because both consumers want it synchronously on
    // every build and neither can await.
    unawaited(() async {
      final AccountInfo? account;
      try {
        account = await _account;
      } on Object {
        // A keychain the platform will not answer for — under `flutter test`
        // there is no channel behind it at all. Swallowed rather than left to
        // the zone: nothing on this screen waits for the answer, the rooms
        // simply group by everyone on a thread until it lands, and a failed
        // read must not be an unhandled error in whatever ran the app.
        return;
      }
      if (!mounted) return;
      setState(() => _owner = account);
    }());
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _probe.close();
    _mainComposerFocus.dispose();
    _sideComposerFocus.dispose();
    _findText.dispose();
    _findFocus.dispose();
    _filesSearchText.dispose();
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
    // Two indexed reads, on the same tick that brought the mail in. The sync
    // deletes suggestions whose thread received new mail and the queue writes
    // fresh ones, so a pane left alone for a minute would be listing work that
    // is already gone.
    ref.read(draftsInboxProvider.notifier).load();
    // The shelf only when it is what the reader is looking at: it is a paged
    // read over the whole mailbox, and running it on the minute for a pane
    // nobody has open is a query for nothing.
    if (_section == RailSection.files) {
      ref.read(filesProvider.notifier).load(sources: _activeSources);
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
    // The thread beside counts as open: it is being read as much as the one in
    // the main pane, and a transcript that never refreshed under a storyline
    // would sit a poll behind the rail rows beside it.
    final side = _side;
    if (side is ThreadPanel) {
      await ref
          .read(
            threadProvider(
              (source: side.source, conversationKey: side.conversationKey),
            ).notifier,
          )
          .load(fetchBodies: false);
      if (!mounted) return;
    }
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
    // A room's inline chats are as open as any transcript: they are on screen,
    // and a chat that never refreshed under a room would sit a poll behind the
    // rail rows beside it.
    final roomKey = _selectedRoomKey;
    if (roomKey != null) {
      for (final room in _rooms) {
        if (room.key != roomKey) continue;
        for (final chat in roomChats(room)) {
          await ref
              .read(threadProvider(
                (source: chat.source, conversationKey: chat.id),
              ).notifier)
              .load(fetchBodies: false);
          if (!mounted) return;
        }
        break;
      }
    }
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
    // The side panel holds an [AttachmentRef] — or a conversation key — out of
    // the mailbox that was just wiped, and it would keep drawing over the next
    // person's empty inbox. Cleared here rather than left to the next
    // selection, because signing out is not a selection.
    _clearOverlays();
    // A SELECTION and so not in that block, but it names people out of the
    // mailbox that was just wiped, and it must not survive into the next
    // person's session either.
    _selectedRoomKey = null;
    if (!mounted) return;
    ref.invalidate(conversationsProvider);
    ref.invalidate(storylinesProvider);
    ref.invalidate(threadProvider);
    ref.invalidate(draftProvider);
    ref.invalidate(storylineTimelineProvider);
    widget.onSignedOut?.call();
  }

  /// Everything that is an overlay on the pane rather than the pane itself.
  ///
  /// The seven selection setters each clear exactly this list before setting
  /// their own field: a picker, a reply box or a file left open over the next
  /// thing the user asked for is the bug, and it is the same list every time.
  /// Called from inside the caller's own `setState`, so one selection is one
  /// frame.
  void _clearOverlays() {
    _side = null;
    _sideFull = false;
    _addingToStorylineId = null;
    _pickingStorylineForThread = null;
    _railOpen = false;
    _replyTo = null;
    _showingActivityLog = false;
    _showingSettings = false;
    _showingCompose = false;
  }

  /// Opens something beside the main pane, always in the split and never in
  /// the full pane: a panel that inherited the last one's ⤢ would take over a
  /// screen the user did not ask it to.
  void _openBeside(SidePanel panel) => setState(() {
        _side = panel;
        _sideFull = false;
        _dropSideReplyTarget();
      });

  void _closeSide() => setState(() {
        _side = null;
        _sideFull = false;
        _dropSideReplyTarget();
      });

  /// A side thread that goes away takes its reply target with it. The caption
  /// belongs to a box that is no longer on screen, and a send into the thread
  /// that comes back next must not inherit somebody else's message id.
  ///
  /// Called from inside the caller's own `setState`.
  void _dropSideReplyTarget() {
    final replyTo = _replyTo;
    if (replyTo != null && !_isMainThread(replyTo.target)) _replyTo = null;
  }

  /// Opens a conversation BESIDE whatever is in the main pane — a storyline's
  /// episode card, and in later phases a person room's root message.
  ///
  /// Everything [_select] does except take the main pane: the thread and its
  /// draft are loaded the same way, and opening it still counts as reading it.
  void _openThreadBeside(String source, String conversationKey) {
    _openBeside(
      ThreadPanel(source: source, conversationKey: conversationKey),
    );
    final target = (source: source, conversationKey: conversationKey);
    ref.read(conversationsProvider.notifier).noteThreadOpened(conversationKey);
    ref.read(conversationsProvider.notifier).markRead(source, conversationKey);
    ref.read(threadProvider(target).notifier).load();
    ref.read(draftProvider(target).notifier).load();
  }

  /// Which file the side panel is showing, for the chips that mark it. Both
  /// panes read this one getter — a chip highlighted in the transcript and not
  /// in the spine is two answers to one question.
  AttachmentRef? get _sideAttachment {
    final side = _side;
    return side is FilePanel ? side.attachment : null;
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
      _clearOverlays();
      _selectedId = id;
      _selectedSource = resolvedSource;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _selectedRoomKey = null;
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
      _clearOverlays();
      _selectedStorylineId = id;
      _selectedId = null;
      _selectedSource = null;
      _selectedLaterDay = null;
      _selectedRoomKey = null;
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
    // Same rule for Drafts & sent: the two lists have no bus behind them — the
    // model writes a suggestion while the reader is elsewhere — so arriving is
    // the moment they are worth being current.
    if (section == RailSection.drafts) {
      ref.read(draftsInboxProvider.notifier).load();
    }
    // And the Files shelf, for the same reason: a sync lands documents while
    // the reader is elsewhere, and arriving is the shelf's only chance to be
    // current.
    if (section == RailSection.files) {
      ref.read(filesProvider.notifier).load(sources: _activeSources);
    }
    setState(() {
      _clearOverlays();
      _section = section;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _selectedRoomKey = null;
    });
  }

  /// Opens one person's room. The section moves with it, so Back out of the
  /// room lands on the People overview rather than wherever the user was
  /// before — the same rule [_selectLaterDay] follows for a day.
  void _selectRoom(String key) {
    setState(() {
      _clearOverlays();
      _section = RailSection.people;
      _selectedRoomKey = key;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
    });

    for (final room in _rooms) {
      if (room.key != key) continue;
      // The room's chats are drawn inline, so opening the room IS opening
      // them — the same pair [_openThreadBeside] runs, for the same reason a
      // Slack DM is read the moment it is on screen. Mail threads stay unread
      // until somebody opens one: a card is a summary, not the mail.
      for (final chat in roomChats(room)) {
        final target = (source: chat.source, conversationKey: chat.id);
        ref.read(conversationsProvider.notifier).noteThreadOpened(chat.id);
        ref
            .read(conversationsProvider.notifier)
            .markRead(chat.source, chat.id);
        ref.read(threadProvider(target).notifier).load();
      }
      // The docked composer's suggestion, if this room has a box at all.
      final target = roomComposerTarget(room);
      if (target != null) ref.read(draftProvider(target).notifier).load();
      return;
    }
  }

  /// Opens one day's Later digest. The section moves with it, so backing out of
  /// the day lands on the whole pile rather than wherever the user was before —
  /// and the tab moves with it too, since a day only means anything in Later.
  void _selectLaterDay(String dayKey) {
    setState(() {
      _clearOverlays();
      _section = RailSection.archive;
      _archiveTab = ArchiveTab.later;
      _selectedLaterDay = dayKey;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedRoomKey = null;
    });
  }

  /// Opens the activity log, which is a pane and not a section: it belongs to
  /// the app rather than to the mail, so it is reached from the icon rail's
  /// avatar menu and clears whatever the user was reading.
  void _openActivityLog() {
    setState(() {
      _clearOverlays();
      _showingActivityLog = true;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _selectedRoomKey = null;
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
            // The suggestion this thread was holding has just been sent, so it
            // belongs in the other half of the Drafts & sent pane. Cheap
            // enough to run whether or not that pane is up: two indexed reads.
            ref.read(draftsInboxProvider.notifier).load();
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
          // A queued reply leaves on a timer with nothing awaiting it, so this
          // is the only place its send can move the Drafts & sent lists.
          ref.read(draftsInboxProvider.notifier).load();
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
      // ⌘K from anywhere on the screen. `CallbackShortcuts` only sees keys
      // while focus is somewhere inside its subtree, and on a freshly built
      // screen nothing has focus at all — so the `Focus(autofocus: true)`
      // wrapper is what makes the binding global. It takes focus once, at the
      // top, and hands it over the moment anything below asks: a composer or a
      // search box the reader clicks into still gets its keystrokes.
      //
      // The control variant is for a runner that is not a Mac. Second binding
      // in the app; the first is `HomeSearchField`'s Escape.
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              _focusFind,
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _focusFind,
        },
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: Stack(
              // Expand, or the stack takes its size from the ribbon layer —
              // which is nothing at all until something settles, and the inbox
              // under it would lay out at zero.
              fit: StackFit.expand,
              children: [
                Positioned.fill(child: _body(state)),
                // A sibling ABOVE the body rather than something inside it:
                // the pane swaps out from under every selection, and a ribbon
                // mounted in there would be unmounted mid-announcement — and
                // the narrow layout's rail overlay would cover it.
                _ribbonLayer(),
              ],
            ),
          ),
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
    //
    // A thread open BESIDE the main pane is being read just as much as one in
    // it, and it is not [_selectedId]; without the second arm the ribbon
    // announces the conversation the user is looking at.
    final side = _side;
    final beside = side is ThreadPanel ? side : null;
    final onScreen = items.length == 1 &&
        ((items.single.conversationKey == _selectedId &&
                (_selectedSource == null ||
                    items.single.source == _selectedSource)) ||
            (beside != null &&
                items.single.conversationKey == beside.conversationKey &&
                items.single.source == beside.source));

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
        // Grouped ONCE per build, here, and handed to the rail, the room pane
        // and the main ladder: three callers deriving the same rooms from the
        // same list is three chances for the row the user tapped and the pane
        // that opened to disagree about who is in it.
        final rooms = peopleRooms(
          rows,
          owner: _ownerRecord,
          threshold: ref.watch(appPrefsProvider).attentionThreshold,
        );
        // Kept for [_submitFind], which needs exactly what the rail was
        // handed and runs long after this build has finished. Plain writes,
        // not setState: they are derived from the list above, so they change
        // when it changes and never on their own.
        _rows = rows;
        _rooms = rooms;
        return LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth >= _twoPaneBreakpoint
                  ? _wide(rows, rooms, loadError)
                  : _narrow(rows, rooms, loadError),
        );
    }
  }

  /// The rail, the main pane, and whatever is open beside it.
  ///
  /// The width is measured POST-RAIL — see [SidePanelHost.availableBesideRail]
  /// — and the two-pane breakpoint is applied to THAT figure rather than to
  /// the window: 56 of icon rail, 260 of list column, the 1px divider and the
  /// 16px seam come off first, so the split appears from a window of 1293px.
  /// Measuring the raw window instead would open the split at 960, where the
  /// main pane would be left with 323 — under the transcript's own minimum,
  /// with nothing to catch it.
  Widget _wide(
    List<Conversation> conversations,
    List<PersonRoom> rooms,
    String? loadError,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = _side;
        // A full-pane file is a rung of [_main], not a panel beside it.
        final beside = _sideFull ? null : side;
        final available =
            SidePanelHost.availableBesideRail(constraints.maxWidth);
        final width = (beside == null || available < _twoPaneBreakpoint)
            ? null
            : SidePanelHost.widthFor(
                available: available,
                // A history is a page of prose and levers, as wide as a
                // transcript; a file, a person and a Why fit the narrower one.
                minWidth: (beside is ThreadPanel || beside is HistoryPanel)
                    ? SidePanelHost.threadMinWidth
                    : SidePanelHost.fileMinWidth,
                mainMinWidth: SidePanelHost.mainMinWidth,
              );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _iconRail(conversations),
            _rail(conversations, rooms),
            const SizedBox(
              width: 1,
              child: ColoredBox(color: BondColors.border),
            ),
            // Both cannot be had at this width, so the panel REPLACES the main
            // pane rather than squeezing it — the same call the rail makes at
            // its own breakpoint, and the one the thread pane's split made
            // before this moved out here.
            if (beside != null && width == null)
              Expanded(child: _sidePanel(beside))
            else ...[
              Expanded(child: _main(conversations, rooms, loadError)),
              if (beside != null && width != null) ...[
                const SizedBox(width: BondSpacing.s16),
                SizedBox(width: width, child: _sidePanel(beside)),
              ],
            ],
          ],
        );
      },
    );
  }

  /// The rail lifts off the page instead of shoving it aside: at this width
  /// the main pane has nothing to spare.
  Widget _narrow(
    List<Conversation> conversations,
    List<PersonRoom> rooms,
    String? loadError,
  ) {
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
            // One thing at a time at this width: an open side panel has the
            // pane, exactly as the file preview did before the panel was a
            // shell-level thing.
            Expanded(
              child: (_side != null && !_sideFull)
                  ? _sidePanel(_side!)
                  : _main(conversations, rooms, loadError),
            ),
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
              // Both columns lift off together: the stops and the list they
              // scope are one navigator, and half of it would be half a way
              // around the app.
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _iconRail(conversations),
                  _rail(conversations, rooms),
                ],
              ),
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

  /// A deferred thread's date, rewritten to the day the reader just picked.
  ///
  /// It goes through [ConversationsNotifier.sendThreadToLater] rather than
  /// through a bare date write, because naming a day for ONE thread is a
  /// per-thread deferral whatever filed it before: a row a sender rule swept
  /// up is promoted to a deferral of its own, which is what the user asked for
  /// by giving this one a date.
  Future<void> _snoozeThread(String source, String key, DateTime until) async {
    await ref
        .read(conversationsProvider.notifier)
        .sendThreadToLater(source, key, until: until);
    final when = untilLabel(MessageStore.isoStamp(until.toUtc()), DateTime.now());
    _toast('Back ${when ?? 'later'}.');
  }

  Future<void> _keepThread(String source, String key) async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.keepThreadInInbox(source, key);
    _toast(
      'Thread kept in your inbox.',
      onUndo: () => notifier.sendThreadToLater(source, key),
    );
  }

  /// The stop the two rails highlight, or null when what is on screen is not a
  /// section at all — a thread, a storyline, a room, a Later day or a pane.
  ///
  /// One getter for both columns: the icon rail and the list column must never
  /// disagree about where the user is, and two copies of this rule is how they
  /// would come to.
  RailSection? get _highlightedSection => (_selectedId == null &&
          _selectedStorylineId == null &&
          _selectedLaterDay == null &&
          _selectedRoomKey == null &&
          !_showingActivityLog &&
          !_showingSettings &&
          !_showingCompose)
      ? _section
      : null;

  /// The 56px strip of stops, and the account's face at the foot of it.
  Widget _iconRail(List<Conversation> conversations) {
    return IconRail(
      // Drafts & sent is a ROW in the Home stack, not a stop, so the strip
      // lights the stack it belongs to. Anything else would leave every icon
      // dark while a pane is up, which reads as "you are nowhere".
      selected: _highlightedSection == RailSection.drafts
          ? RailSection.home
          : _highlightedSection,
      // The same count the list column's own badge shows, at the same
      // threshold: two numbers for one pile is one number too many.
      needsYouCount: needsYouRows(
        conversations,
        threshold: ref.watch(appPrefsProvider).attentionThreshold,
      ).length,
      onSelect: _selectSection,
      accountName: _owner?.displayName ?? '',
      accountAddress: _owner?.mail ?? _owner?.userPrincipalName,
      onSettings: _openSettings,
      // Behind the preference it has always been behind. Null leaves the item
      // out of the menu rather than showing one that does nothing.
      onActivityLog:
          ref.watch(appPrefsProvider).showActivityLog ? _openActivityLog : null,
      onSignOut: _signOut,
      photos: ref.read(profilePhotosProvider),
    );
  }

  Widget _rail(List<Conversation> conversations, List<PersonRoom> rooms) {
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
      // A thread, a storyline, a room or a Later day being open means no
      // section overview is showing, so the rail must not highlight one.
      selectedSection: _highlightedSection,
      header: _listHeader(),
      // The column is scoped to wherever the user is, and it keeps that scope
      // while they read: a thread opened from People must not drop the column
      // back to the Home stack under them.
      scope: _section ?? RailSection.home,
      find: _find,
      unreadOnly: _unreadOnly,
      // Counted off the SOURCE-FILTERED rows, the same list the pane is built
      // from, so the badge and the pane never disagree about how much is
      // waiting.
      pendingDraftCount:
          conversations.where((c) => c.pendingDraftCount > 0).length,
      // The shelf's own state, so the rows here and the pills in the pane
      // cannot disagree about which shelf is up.
      filesKind: ref.watch(filesProvider).kind,
      onSelectFilesKind: (kind) =>
          ref.read(filesProvider.notifier).setKind(kind, sources: _activeSources),
      rooms: rooms,
      selectedRoomKey: _selectedRoomKey,
      onSelectRoom: _selectRoom,
      photos: ref.read(profilePhotosProvider),
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
    );
  }

  /// What the list column is showing, how to add to it, and how to bring it up
  /// to date — drawn at the TOP of the column, above the list.
  ///
  /// Everything the footer used to carry that belonged to the MAIL is here;
  /// everything that belonged to the app went to the avatar menu on the icon
  /// rail (D8). What is left is four lines: which pile this is beside the
  /// controls that act on it, the Find field, the source chips, and the triage
  /// caption.
  ///
  /// The Teams freshness caption is gone as a line and lives in the refresh
  /// button's tooltip: it is a fact ABOUT that button — chats do not arrive on
  /// their own, so the one control that pulls them is the one place worth
  /// saying how old they are.
  Widget _listHeader() {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (_section ?? RailSection.home).label.toUpperCase(),
                  style: BondType.caption.copyWith(
                    color: BondColors.onDarkMuted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.96,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Writing to somebody is the one control here that starts
              // something rather than adjusting what is already on screen.
              _unreadToggle(),
              _railAction(
                Icons.edit_outlined,
                'New message',
                () => _openCompose(),
              ),
              _refreshAction(),
            ],
          ),
          const SizedBox(height: BondSpacing.s8),
          FindField(
            controller: _findText,
            focusNode: _findFocus,
            onChanged: (value) => setState(() => _find = value),
            onSubmit: (_) => _submitFind(),
            onClear: _clearFind,
          ),
          const SizedBox(height: BondSpacing.s8),
          _sourceFilterBar(),
          _triageProgress(),
        ],
      ),
    );
  }

  /// The ONE button that pulls Teams. Every other refresh in this screen — the
  /// timer, the retry links on the error banners — is mail only.
  ///
  /// Its tooltip carries how old the Teams side of the inbox is, and says
  /// nothing at all before the first pull. The difference between "quiet" and
  /// "stale" is worth a sentence, and this is the control that changes it.
  Widget _refreshAction() {
    // Held rather than re-read on every build: it is a stored read and so a
    // future now, and a fresh future per build would restart the FutureBuilder
    // — blanking the tooltip for a frame every time anything on this screen
    // changed. [_refreshTeams] drops it, which is the only thing that can
    // change the answer.
    final future = _teamsSyncedAt ??= ref.read(teamsSyncProvider).lastSyncedAt;
    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final label = relativeTime(snapshot.data, DateTime.now());
        return _railAction(
          Icons.refresh,
          label == null ? 'Refresh' : 'Refresh · Teams updated $label',
          () => unawaited(_refreshAll()),
        );
      },
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
          onSelected: _setSourceFilter,
        ),
      ),
    );
  }

  /// Narrows every pane to one connector, or widens back to both.
  ///
  /// One method for the pills and for the empty pane's `Show all`, so the
  /// shelf re-read below happens whichever control moved the filter.
  void _setSourceFilter(String? source) {
    setState(() => _sourceFilter = source);
    // Every other pane is built from the already-filtered rows; the shelf
    // reads the store itself, so the chips have to re-ask it.
    if (_section == RailSection.files) {
      ref.read(filesProvider.notifier).load(sources: _activeSources);
    }
  }

  /// The line under an empty pane while a source pill is down: which half of
  /// the mailbox the reader is looking at, and the way back to all of it.
  ///
  /// Null when nothing is narrowed, so a pane that is simply empty says so
  /// and nothing more. The pill that emptied the pane is on the other side of
  /// the divider, a column away from where the reader is looking; without
  /// this line an empty Needs You under Teams reads as "nothing needs you"
  /// when the truth is "nothing on Teams needs you".
  Widget? _scopeNotice() {
    final scope = _sourceFilter;
    if (scope == null) return null;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: BondSpacing.s4,
      children: [
        Text(
          'Showing ${sourceFilterLabel(scope)} only.',
          style: BondType.caption,
        ),
        TextButton(
          key: InboxScreen.showAllSourcesKey,
          onPressed: () => _setSourceFilter(null),
          child: const Text('Show all'),
        ),
      ],
    );
  }

  /// Opens Settings, which is a pane and not a section — it belongs to the
  /// app rather than to the mail, so it is reached from the icon rail's avatar
  /// menu and clears whatever the user was reading, exactly as the activity
  /// log does.
  void _openSettings() {
    setState(() {
      // Which includes the rail overlay: at narrow widths leaving it open
      // would put the pane the gear just opened behind a scrim.
      _clearOverlays();
      _showingSettings = true;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _selectedRoomKey = null;
    });
  }

  void _closeSettings() => setState(() => _showingSettings = false);

  /// Opens one message's history BESIDE whatever is on screen.
  ///
  /// Deliberately NOT a selector: it clears nothing underneath, because the
  /// question "what happened to this" is always asked about something the
  /// reader is already looking at, and closing the panel has to leave them
  /// where they were. From a side thread, a Why panel or a file it replaces
  /// that panel — the side shows one thing — and [_openBeside] closes the
  /// rail overlay at narrow widths.
  void _openHistory(String source, String id) =>
      _openBeside(HistoryPanel(source: source, id: id));

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
      // The side panel goes with the thread it was opened from. The ladder
      // would not show it without a selection, but a pane leaves the same
      // state behind whichever pane it was — Settings clears these, so does
      // this.
      _clearOverlays();
      _showingCompose = true;
      _composePrefill = prefill;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _selectedRoomKey = null;
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
  ///
  /// [scope] is what tells the two rungs apart: the avatar menu's Settings
  /// opens all of it, the AI stop opens the model half under the title 'AI'.
  /// ONE builder for both, so a callback added to one is added to the other —
  /// two copies of forty wired parameters is two copies that drift.
  Widget _settingsScreen({
    required SettingsScope scope,
    required VoidCallback onBack,
  }) {
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
      scope: scope,
      onBack: onBack,
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

  /// Unread only, on or off.
  ///
  /// A toggle in the caption row rather than a fourth pill under the source
  /// chips, which is where the plan put it: three source pills already fill
  /// 236px, and a fourth would wrap onto a line of its own for one word. It
  /// keeps [_railAction]'s size and density so the caption row reads as one
  /// set of controls rather than as a button beside two others.
  Widget _unreadToggle() {
    return IconButton(
      key: const Key('unread-toggle'),
      onPressed: () => setState(() => _unreadOnly = !_unreadOnly),
      isSelected: _unreadOnly,
      icon: const Icon(Icons.mark_email_unread_outlined),
      selectedIcon: const Icon(Icons.mark_email_unread),
      iconSize: 18,
      color: _unreadOnly ? BondColors.railAccent : BondColors.onDarkSecondary,
      tooltip: _unreadOnly ? 'Show everything' : 'Unread only',
      padding: const EdgeInsets.all(BondSpacing.s4),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
    );
  }

  /// Empties the Find field and puts every row back. Both the controller and
  /// the mirror, because the box is a view of the first and the rail reads the
  /// second.
  void _clearFind() {
    _findText.clear();
    setState(() => _find = '');
  }

  /// Puts the cursor in the Find field, from anywhere — what ⌘K does.
  ///
  /// At narrow widths the column is an overlay, so it is opened first: a
  /// binding that focused a field nobody can see would be one that swallowed
  /// the keystroke.
  ///
  /// The focus request waits a frame, because the field may only exist once
  /// the overlay this same call opened has been laid out. The selection goes
  /// with it: ⌘K on a box that already holds a needle should let the reader
  /// type straight over it, which is what every switcher does.
  void _focusFind() {
    setState(() {
      if (MediaQuery.sizeOf(context).width < _twoPaneBreakpoint) {
        _railOpen = true;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _findFocus.requestFocus();
      _findText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findText.text.length,
      );
    });
  }

  /// Enter in the Find field: open the first row the column is still drawing.
  ///
  /// [firstFindTarget] is the ONE place that order lives — the rail draws it
  /// and this walks it — so the row that opens is the row under the reader's
  /// eyes rather than a second opinion about which one came first.
  ///
  /// Nothing matched and there IS a needle: the question goes to Home's search
  /// instead. That is the honest escalation — Find only ever looked at what is
  /// on the rail, search looks at the whole index — and it is what keeps a
  /// needle nothing on the rail answers from being a dead end.
  void _submitFind() {
    final target = firstFindTarget(
      scope: _section ?? RailSection.home,
      conversations: _rows,
      storylines: _storylines(),
      rooms: _rooms,
      find: _find,
      unreadOnly: _unreadOnly,
      threshold: ref.read(appPrefsProvider).attentionThreshold,
    );
    switch (target) {
      case FindThread(:final source, :final conversationKey):
        _select(conversationKey, source: source);
      case FindStoryline(:final id):
        _selectStoryline(id);
      case FindRoom(:final key):
        _selectRoom(key);
      case null:
        final text = _find.trim();
        if (text.isEmpty) return;
        _selectSection(RailSection.home);
        ref.read(homeFeedProvider.notifier).submitSearch(text);
        return;
    }
    // The switcher closes on a pick, as Slack's does: the needle answered its
    // question, and leaving it up would leave the column filtered around a
    // thread the reader has already opened.
    _clearFind();
    _findFocus.unfocus();
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
  /// log, then the two picker panes, then the full attachment viewer, then the
  /// thread transcript, then the storyline timeline, then the section
  /// overview. A message's history is not a rung: it opens BESIDE, as a
  /// [HistoryPanel], so the picker its Add to storyline… opens draws here
  /// while the story stays on screen. The order is the priority — compose,
  /// Settings and the log come first because they are the three that are not
  /// about the mail already on screen, and a pane outranks what it was opened
  /// from because it is the newer thing the user asked for.
  ///
  /// The full-pane file viewer sits directly above the transcript because that
  /// is what it was expanded from and what Back returns to — and above the
  /// storyline too, since a document on the shelf expands into the same pane.
  /// Back from it drops to the split in every case now: the side panel is the
  /// shell's, so there is always something for it to drop back to.
  ///
  /// A selected Later day is not a case here: it is a section overview with a
  /// filter on it, and [_overviewBody] reads it.
  Widget _main(
    List<Conversation> conversations,
    List<PersonRoom> rooms,
    String? loadError,
  ) {
    if (_showingCompose) return _compose();
    if (_showingSettings) {
      return _settingsScreen(scope: SettingsScope.all, onBack: _closeSettings);
    }
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

    final side = _side;
    // The full viewer stands wherever the file was opened from — a thread, a
    // storyline's shelf, a room, the Files stop, a person's files — as long as
    // the thread it rode in on still exists. A viewer whose thread vanished
    // falls through instead — never setState in build; the next selection
    // clears it. A file with no thread behind it (a shelf's) has nothing to
    // vanish, so it stands until something else is selected.
    if (side is FilePanel && _sideFull && _viewerOriginExists(side)) {
      return _attachmentViewer(side);
    }

    final selected = _selected(conversations);
    if (selected != null) return _thread(selected);

    final storylineId = _selectedStorylineId;
    if (storylineId != null) {
      final storyline = _storylineById(storylineId);
      if (storyline != null) return _storyline(storyline);
    }

    // A room whose people all went quiet is a room that no longer exists — the
    // grouping is derived, not stored. Falling through rather than clearing the
    // key, because build never setStates: the next selection clears it.
    final roomKey = _selectedRoomKey;
    if (roomKey != null) {
      for (final room in rooms) {
        if (room.key == roomKey) return _room(room);
      }
    }

    // Drafts & sent sits directly above Home because it is a row IN the Home
    // stack: the reader is still standing on Home's column, and the pane in
    // front of them is one of the things that column offered.
    if (_section == RailSection.drafts) return _drafts();

    // The last rung before the section overviews, so every selection above
    // still outranks it: a thread opened from the feed shows the thread, and
    // Home is what is left when nothing else is selected. A Later day is not a
    // section here — it is an overview with a filter — so it is checked too.
    if ((_section ?? RailSection.home) == RailSection.home &&
        _selectedLaterDay == null) {
      return _home();
    }

    // The AI stop's pane IS Settings, narrowed to the sections that are about
    // the model. It sits here rather than with the other panes above because
    // it is a SECTION and not an overlay: nothing opened it, the user is
    // simply standing on that stop.
    if (_section == RailSection.ai) {
      return _settingsScreen(
        scope: SettingsScope.ai,
        onBack: () => _selectSection(RailSection.home),
      );
    }

    return _overview(conversations, loadError);
  }

  /// Every suggestion still waiting, and everything already sent.
  ///
  /// Both halves open BESIDE rather than in the main pane, which is the whole
  /// point of the pane: the docked composer in a side thread already holds the
  /// suggested body, so a reader can work down the list — read, send, next —
  /// without the list going away underneath them.
  Widget _drafts() {
    final inbox = ref.watch(draftsInboxProvider);
    return DraftsPane(
      drafts: inbox.drafts,
      sent: inbox.sent,
      loaded: inbox.loaded,
      error: inbox.error,
      now: DateTime.now(),
      onOpenDraft: (draft) =>
          _openThreadBeside(draft.source, draft.conversationKey),
      onOpenSent: (row) => _openThreadBeside(row.source, row.conversationKey),
      onDismiss: (draft) async {
        await ref
            .read(draftsInboxProvider.notifier)
            .dismiss(draft.source, draft.replyToMessageId);
        if (!mounted) return;
        // Two more reloads, and both earn their keep. The thread's own draft
        // notifier is what a composer open BESIDE this pane is reading, and it
        // would still be holding the suggestion that was just thrown away; the
        // conversation list carries `pending_draft_count`, which is the rail's
        // badge. Without them the pane, the composer and the badge would all
        // be saying different things about the same row.
        ref.read(draftProvider(draft.target).notifier).load();
        ref.read(conversationsProvider.notifier).load(syncFirst: false);
      },
    );
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
      // The one thing a re-read cannot say is that nothing was owed, because
      // the row looks the same afterwards — so that answer is spoken.
      onRetry: (source, id) => unawaited(() async {
        final stages =
            await ref.read(pipelineRepairServiceProvider).retryOwed(source, id);
        if (!mounted || stages.isNotEmpty) return;
        _toast('Nothing to retry — every stage has finished.');
      }()),
      // Two doors on every row — the stage bar and the Result cell — because
      // those are the two places a reader looks when the sentence is not the
      // one they expected.
      onOpenHistory: _openHistory,
    );
  }

  /// One message's whole story, and every lever beside it, in the side panel.
  ///
  /// The story itself, and every provider behind it, live in
  /// [MessageHistoryHost]; what is left here is what only this screen can
  /// answer — where Back goes, and where the storyline picker is drawn. No ⤢,
  /// for the Why panel's reason: it is prose about one message and does not
  /// improve by being given the whole window.
  Widget _historyPanel(HistoryPanel side) {
    return SidePanelHost(
      title: 'What happened',
      leading: const Icon(Icons.history, size: 18),
      onClose: _closeSide,
      child: MessageHistoryHost(
        target: (source: side.source, id: side.id),
        // The host draws the header; the story renders bare inside it — so
        // its own Back and Home are never drawn, and the ✕ above is the one
        // way out. Both are still the widget's required API, and both are
        // given the answer they would have: leaving the panel leaves whatever
        // was underneath exactly where it was.
        chrome: false,
        onBack: _closeSide,
        onHome: () => _selectSection(RailSection.home),
        onOpenThread: (threadSource, conversationKey) =>
            _select(conversationKey, source: threadSource),
        onOpenStoryline: _selectStoryline,
        // The picker overlays the main pane rather than replacing the panel —
        // see [_main] — so filing from here comes back to the story it was
        // filed from.
        onAddToStoryline: (source, threadKey) => setState(
          () => _pickingStorylineForThread = (source: source, id: threadKey),
        ),
        onKeepInInbox: _keepThread,
        onEditRules: _openSettings,
      ),
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
          _reloadHistoryBeside();
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
          _reloadHistoryBeside();
        },
      ),
    );
  }

  /// Re-reads the history beside the main pane after a write made on its
  /// behalf from OUTSIDE it — the storyline picker's pick or create.
  ///
  /// Every lever on the history itself chains its own reload; the picker is
  /// the one that lives in the main pane, and the panel stays mounted while it
  /// is up, so nothing else would re-read. Filing a thread moves no stage, so
  /// the progress bus the notifier listens to says nothing either. When the
  /// picker was opened from somewhere else there is no history beside, and
  /// this does nothing.
  void _reloadHistoryBeside() {
    final side = _side;
    if (side is! HistoryPanel) return;
    unawaited(ref
        .read(messageHistoryProvider((source: side.source, id: side.id))
            .notifier)
        .reload());
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
        _clearOverlays();
        _selectedStorylineId = null;
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
      // The card's own tap. A thread opens BESIDE the spine rather than over
      // it: the storyline is the room the reader is in, and the answer they
      // are about to write belongs to one conversation in it.
      onOpenEpisode: (episode) =>
          _openThreadBeside(episode.source, episode.conversationKey),
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
          _clearOverlays();
          _selectedStorylineId = null;
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
      // Beside the spine, not over it — the storyline stays on screen while
      // the document is read against it. No thread rides along: the shelf's
      // files belong to the storyline rather than to any one conversation, so
      // there is no composer for 'Use in reply' to write into.
      onOpenDocument: (attachment) =>
          _openBeside(FilePanel(attachment: attachment)),
      onPinDocument: (attachment) =>
          unawaited(_pinAttachment(attachment, storyline.id)),
      onUnpinDocument: (attachment) =>
          unawaited(_unpinDocument(storyline.id, attachment)),
    );

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
          // No composer under the spine, and no picker over it. A storyline
          // is several conversations and this pane could only ever answer one
          // of them, which is a question the reader had to answer before they
          // could type. Tapping a card opens that conversation beside the
          // spine WITH its own box, so the reply is addressed to exactly one
          // thread and the pane it belongs to says which.
          Expanded(child: panel),
        ],
      ),
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

  /// One person's room: everything live with them, in the order it happened.
  ///
  /// Goal one of the round, literally. Chats read as messages and mail threads
  /// read as cards, interleaved by time, so a colleague who both mails and
  /// chats has ONE history here rather than two piles to merge in the reader's
  /// head. Opening any of them puts the thread BESIDE the room (D3), so the
  /// history the reader came from stays on screen.
  ///
  /// The composer under it targets the 1:1 chat when there is one, and
  /// otherwise there is a `Message …` button that opens a new mail — never
  /// both, because two ways to write to one person on one pane is two
  /// decisions the reader did not ask to make.
  Widget _room(PersonRoom room) {
    // Watched, not read: a chat whose transcript lands after the room opened
    // has to turn from a card into its messages without another click.
    final chats = <ThreadTarget, List<Message>>{};
    for (final chat in roomChats(room)) {
      final target = (source: chat.source, conversationKey: chat.id);
      final state = ref.watch(threadProvider(target));
      if (state is ThreadLoaded) chats[target] = state.messages;
    }

    final target = roomComposerTarget(room);
    // A chat gets a box only on the top rung, exactly as a chat thread does:
    // there is no drafts folder behind a Teams message, so without the grant
    // the honest thing is no box at all.
    final canReply = target != null &&
        ref.watch(draftProvider(target)).capability == SendCapability.send;
    final mailThread = newestMailThread(room);
    final photos = ref.read(profilePhotosProvider);

    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RoomHeader<ThreadTab>(
            title: Text(
              room.title,
              style: BondType.titleSm,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: roomSubtitle(room),
            people: [
              for (final p in room.people)
                if (p.display.isNotEmpty)
                  (
                    name: p.display,
                    address: p.email,
                    photoKey: photoKeyFor(address: p.email),
                  ),
            ],
            photos: photos,
            // Back goes to the People overview rather than to whatever was on
            // screen before: the room IS the People stop, and dropping the
            // reader elsewhere would make the way out depend on how they got in.
            onBack: () => _selectSection(RailSection.people),
            onPeopleTap: () => _openPersonPanel(room.key),
            actions: [
              RoomAction(
                icon: Icons.person_outline,
                label: 'Profile',
                onTap: () => _openPersonPanel(room.key),
              ),
            ],
          ),
          const SizedBox(height: BondSpacing.s12),
          Expanded(
            child: PersonRoomPane(
              room: room,
              chats: chats,
              now: DateTime.now(),
              photos: photos,
              thumbnailFor: _thumbnailFor,
              onOpenThread: _openThreadBeside,
              onOpenAttachment: (attachment, from) =>
                  _openBeside(FilePanel(attachment: attachment, from: from)),
              onOpenLink: (url) => unawaited(_launchExternal(url)),
              // The button and the box are alternatives, never both.
              onMessage: (target == null && mailThread != null)
                  ? () => unawaited(_composeFrom(mailThread))
                  : null,
            ),
          ),
          if (canReply) ...[
            const SizedBox(height: BondSpacing.s12),
            _composer(
              target,
              focusNode: _mainComposerFocus,
              hint: 'Message ${room.title}…',
            ),
          ] else if (target != null) ...[
            // A chat with nowhere to write from here says where to write,
            // exactly as a chat thread does — a room that offered nothing at
            // all would read as a room with nobody in it.
            const SizedBox(height: BondSpacing.s12),
            _replyElsewhere(),
          ],
        ],
      ),
    );
  }

  /// The thread in the MAIN pane: the transcript, and the composer under it.
  Widget _thread(Conversation selected) => _threadColumn(
        selected,
        inSidePanel: false,
      );

  /// One conversation, wherever it is being read.
  ///
  /// The main pane and the side panel render the SAME column — one transcript
  /// widget, one composer, one set of quick replies — because two renderers
  /// for one conversation is how the two of them come to disagree about
  /// whether a thread can be replied to. What differs is only what the
  /// surrounding chrome already provides: in the side panel the host draws the
  /// header, so the panel offers no Back and no compose of its own, and a file
  /// opened from here REPLACES the panel it was opened from.
  Widget _threadColumn(
    Conversation selected, {
    required bool inSidePanel,
  }) {
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

    // One node per PANE and not per thread: the main pane and the side panel
    // each hold exactly one box, and which conversation is in it changes under
    // the same cursor.
    final composerFocus = inSidePanel ? _sideComposerFocus : _mainComposerFocus;

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

    // The message a send answers when nobody says otherwise. A card under any
    // OTHER message has to say otherwise — see `cardFor`.
    String? newestInboundId;
    for (final m in shown) {
      if (m.inbound) newestInboundId = m.id;
    }

    /// The suggestion offered under one message, or null where there is none
    /// left to offer.
    ///
    /// Every guard here is about honesty rather than tidiness: a card offers to
    /// write words into the box that answer THIS message, so it goes the moment
    /// that message has been answered — by a synced reply or by a queued one.
    /// A card never sends; the composer's own button is the only send.
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
      return QuickReplyBar(
        options: options,
        armed: draft.capability == SendCapability.send,
        // Whatever the grant, a tap puts this option in the box and takes the
        // cursor there. The box is already under the thread, so all a card owes
        // the reader is the words and somewhere to change them — and, under an
        // OLDER message, which message they answer: a send resolves to the
        // newest inbound on its own, so a card that stayed silent about its
        // message would have its reply land on a different one. The newest
        // message's card says nothing, because nothing needs saying.
        onPick: (option) {
          _stage(target, body: option.body);
          if (m.id != newestInboundId) {
            _replyToMessage(target, m, composerFocus);
          } else {
            composerFocus.requestFocus();
          }
        },
        onDismiss: () => unawaited(notifier.dismissOptionsFor(m.id)),
      );
    }

    final panel = ThreadDetailPanel(
      key: ValueKey(selected.id),
      conversation: selected,
      messages: shown,
      // Read, not watched: the service is a session-long singleton, and each
      // avatar asks it for its own face.
      photos: ref.read(profilePhotosProvider),
      // The suggestions sit with the messages they answer. The panel places
      // them and never learns what they are.
      suggestionFor: cardFor,
      onMarkDone: () => ref
          .read(conversationsProvider.notifier)
          .markDone(selected.source, selected.id),
      onReopen: () => ref
          .read(conversationsProvider.notifier)
          .reopenThread(selected.source, selected.id),
      // In the side panel the host's ✕ is the way out, and there is no
      // selection under this thread for a Back to return to.
      onBack: inSidePanel
          ? null
          : () => setState(() {
                _clearOverlays();
                _selectedId = null;
                _selectedSource = null;
              }),
      // The reply affordance rides at the end of the transcript so it reads as
      // attached to the message it answers. After the user's OWN last message
      // there is nothing to answer, and it renders nothing.
      afterTranscript: canReply && (answersSomebody || pendingBody != null)
          ? _quickReplies(selected, target, draft)
          : null,
      // Every ask on the pane is a call to action, so every one of them puts
      // the cursor in the box — the banner included. Null where there is no box
      // under the thread at all.
      onOpenReply: canReply ? composerFocus.requestFocus : null,
      // The hover strip. Reply names the message the send will answer; Suggest
      // asks the queue for a fresh pair, which is the same thing the bar at the
      // end of the transcript asks for — offered here per message, where the
      // reader already is.
      onReplyTo: canReply
          ? (message) => _replyToMessage(target, message, composerFocus)
          : null,
      onSuggestFor: canReply && draft.suggestable
          ? (_) {
              // Asked for, so it lands in the box: staged before the generate
              // starts, so the words are not written to a box nobody opened.
              _stage(target);
              unawaited(notifier.generate());
            }
          : null,
      // The third hover button, and what the CTA banner opens. From a side
      // thread it REPLACES that thread, the same rule a file opened from
      // beside follows: the panel shows one thing.
      onWhy: (message) => _openWhy(target, message),
      // The faces: who is on this thread, and what else is live with them.
      onPeople: () =>
          _openPersonPanel(roomKeyFor(selected, owner: _ownerRecord)),
      onAddToStoryline: () => setState(() {
        _clearOverlays();
        _pickingStorylineForThread = (source: selected.source, id: selected.id);
      }),
      // Sender-scoped, because the screen is the layer that knows the address
      // behind the row. A thread with no address to key a rule on gets no item
      // rather than a rule keyed on the empty string, which would apply to
      // every anonymous sender at once.
      onSendToLater: selected.primaryEmail?.isNotEmpty == true
          ? () => _laterSender(selected.primaryEmail!, selected.source)
          : null,
      onKeepInInbox: () => _keepThread(selected.source, selected.id),
      // Compose is a whole pane, which a thread being read BESIDE something
      // else has no business opening: the ✕ and the ⤢ are the two ways out of
      // the side panel.
      onCompose: inSidePanel ? null : () => unawaited(_composeFrom(selected)),
      // Opening a file is a selection like any other: it replaces whatever the
      // side panel was showing — including this very thread, when the file was
      // opened from the side panel — and always lands on the split, never on
      // the full pane the user may have left open for the last one.
      //
      // The origin ALWAYS rides along, reply box or not: it is what a pin
      // resolves its storyline through, and a chat this build cannot send to
      // is still the thread the file came from. Whether 'Use in reply' is
      // offered is the file panel's own capability check, not this one's.
      onOpenAttachment: (attachment) => _openBeside(FilePanel(
        attachment: attachment,
        from: target,
      )),
      selectedAttachment: _sideAttachment,
      thumbnailFor: _thumbnailFor,
      // The same path the file panel's own button takes — see
      // [_useAttachmentInReply].
      onUseInReply:
          canReply ? (a) => _useAttachmentInReply(target, a) : null,
      onOpenLink: (url) => unawaited(_launchExternal(url)),
      // Per MESSAGE, not per thread: the pipeline decides one message at a
      // time, and the row's hover strip is where the question is asked — the
      // fourth button, after Why.
      onWhatHappened: (message) => _openHistory(message.source, message.id),
    );

    // The composer sits OUTSIDE the panel, in this column: the panel renders a
    // transcript and knows nothing about drafts or sending, and it stays that
    // way.
    return Padding(
      // Tighter beside than in the main pane: the host already spends 16 on
      // each side of its header, and 24 more inside a 420-wide panel is a
      // quarter of the transcript.
      padding: EdgeInsets.all(
        inSidePanel ? BondSpacing.s12 : BondSpacing.s24,
      ),
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
          // Docked, always: a thread that can be answered says where the answer
          // goes without being asked, the way every chat app the user already
          // has does. The transcript keeps the reader's attention anyway,
          // because the box is quiet until somebody types in it.
          if (canReply) ...[
            const SizedBox(height: BondSpacing.s12),
            _composer(
              target,
              focusNode: composerFocus,
              hint: 'Reply to ${_replyWhoFor(selected)}…',
            ),
          ] else ...[
            const SizedBox(height: BondSpacing.s12),
            _replyElsewhere(),
          ],
        ],
      ),
    );
  }

  /// Whatever is open beside the main pane, in the chrome every side panel
  /// wears.
  Widget _sidePanel(SidePanel side) => switch (side) {
        FilePanel() => _filePanel(side),
        ThreadPanel() => _threadPanel(side),
        PersonPanel() => _personPanel(side),
        WhyPanel() => _whyPanel(side),
        HistoryPanel() => _historyPanel(side),
      };

  /// Why one message got the verdict it did.
  ///
  /// No ⤢: this is a paragraph about one message, and a paragraph does not
  /// improve by being given the whole window. The ✕ is the only way out, which
  /// is also what makes it cheap to open from a hover.
  Widget _whyPanel(WhyPanel side) {
    final conversation = _conversationFor(side.source, side.conversationKey);
    final facts = ref.watch(whyFactsProvider((
      source: side.source,
      conversationKey: side.conversationKey,
      messageId: side.messageId,
    )));
    final threshold = ref.watch(appPrefsProvider).attentionThreshold;

    // The thread panel's own naming rule: a chat carries no subject, so it is
    // named by who is on it.
    final subject = conversation?.subject ?? '';
    final who = [
      for (final p in conversation?.participants ?? const <Participant>[])
        if (p.display.isNotEmpty) p.display,
    ].join(', ');

    return SidePanelHost(
      title: 'Why',
      subtitle: subject.isNotEmpty ? subject : (who.isEmpty ? null : who),
      leading: const Icon(Icons.help_outline, size: 18),
      onClose: _closeSide,
      child: facts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s24),
            child: Text(
              'Could not read this message.',
              style: BondType.small,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (facts) => WhyPanelBody(
          message: facts.message,
          conversation: conversation,
          extraction: facts.extraction,
          ai: facts.ai,
          threshold: threshold,
          now: DateTime.now(),
          // The longer answer, in the same slot: the history replaces this
          // panel, and its ✕ comes back to the transcript, not to here.
          onWhatHappened: () => _openHistory(side.source, side.messageId),
        ),
      ),
    );
  }

  /// Explains one message beside its transcript. From a SIDE thread it
  /// replaces that thread, which is the same rule a file opened from beside
  /// follows: the panel shows one thing.
  void _openWhy(DraftTarget target, Message message) => _openBeside(WhyPanel(
        source: target.source,
        conversationKey: target.conversationKey,
        messageId: message.id,
      ));

  /// Opens one person beside whatever the reader is looking at, and asks for
  /// the facts the room itself does not carry.
  ///
  /// The read is kicked here rather than from the panel's build, because a
  /// build must never write to a provider — and because a room reopened is a
  /// room whose storylines and files may have moved since it was last read.
  void _openPersonPanel(String roomKey) {
    _openBeside(PersonPanel(roomKey: roomKey));
    for (final room in _rooms) {
      if (room.key != roomKey) continue;
      ref
          .read(personFactsProvider.notifier)
          .load(room, sources: _activeSources);
      return;
    }
  }

  /// One person: who they are, what is live with them, and what they have sent.
  ///
  /// The room is resolved from the SAME list the rail and the main pane were
  /// handed, so the panel and the row that opened it can never disagree about
  /// who is in it. A key that is no longer there means the person went quiet
  /// while the panel was open, and the body says so.
  Widget _personPanel(PersonPanel side) {
    PersonRoom? room;
    for (final candidate in _rooms) {
      if (candidate.key == side.roomKey) {
        room = candidate;
        break;
      }
    }

    final facts = ref.watch(personFactsProvider);
    // Only the facts read for THIS person may be drawn under their name. A
    // read still out for somebody else renders as loading, never as their
    // files under this heading.
    final mine = facts.roomKey == side.roomKey;
    final storylines = <Storyline>[];
    if (mine) {
      final all = _storylines();
      for (final id in facts.storylineIds) {
        for (final storyline in all) {
          if (storyline.id == id) {
            storylines.add(storyline);
            break;
          }
        }
      }
    }

    final people = room?.people ?? const <Participant>[];
    return SidePanelHost(
      title: room?.title ?? 'Person',
      leading: people.length == 1
          ? BondAvatar(
              name: people.first.display,
              address: people.first.email,
              size: 24,
              photoKey: photoKeyFor(address: people.first.email),
              photos: ref.read(profilePhotosProvider),
            )
          : null,
      onClose: _closeSide,
      child: PersonPanelBody(
        room: room,
        storylines: storylines,
        files: mine ? facts.files : const [],
        loaded: mine && facts.loaded,
        now: DateTime.now(),
        photos: ref.read(profilePhotosProvider),
        onOpenThread: _openThreadBeside,
        // A main selection, which clears the side panel on its way — the
        // storyline IS the next thing the reader asked for, and leaving the
        // person beside it would be answering a question nobody asked twice.
        onOpenStoryline: _selectStoryline,
        onOpenFile: (row) => _openBeside(FilePanel(
          attachment: row.ref,
          from: row.conversationKey == null
              ? null
              : (source: row.source, conversationKey: row.conversationKey!),
        )),
      ),
    );
  }

  /// A file beside the thread or the storyline it was opened from.
  ///
  /// Keyed by the file, so moving from one attachment to another builds a new
  /// panel — and its memoised fetches — rather than reusing the last one's.
  Widget _filePanel(FilePanel side) {
    final attachment = side.attachment;
    final from = side.from;
    // Read here rather than in the closure: this is the build path, and the
    // control has to appear the frame the thread's membership lands.
    final pinTo = _pinTargetFor(attachment, from: from);
    // The same rung ladder the thread pane applies: mail always has a box
    // because it bottoms out at the clipboard, a chat only with the send
    // grant. A file with no thread behind it — one off a storyline's shelf —
    // has nowhere to write at all.
    final canReply = from != null &&
        (from.source == 'email' ||
            ref.watch(draftProvider(from)).capability == SendCapability.send);
    final size = formatBytes(attachment.size);

    return SidePanelHost(
      leading: Text(
        attachmentGlyph(
          attachment.kind,
          attachment.contentType,
          name: attachment.name,
        ),
        style: BondType.body,
      ),
      title: attachment.name ?? '(unnamed attachment)',
      trailing: size.isEmpty ? null : Text(size, style: BondType.caption),
      onExpand: () => setState(() => _sideFull = true),
      onClose: _closeSide,
      child: AttachmentPreviewPanel(
        key: attachmentKey('preview', attachment),
        attachment: attachment,
        bytes: _attachmentBytes,
        engines: _previewEngines,
        // The host draws the header, including the ⤢ and the ✕ — two of each
        // on one panel is two controls doing one thing.
        showHeader: false,
        onClose: _closeSide,
        onOpen: () => unawaited(_openAttachmentInOs(attachment)),
        onSave: () => unawaited(_saveAttachment(attachment)),
        // Only where there is a composer to write into. Opening the box is
        // what makes the new draft visible; the spinner in it is the
        // notifier's own `generating`, so nothing here waits.
        onUseInReply:
            canReply ? () => _useAttachmentInReply(from, attachment) : null,
        // Nowhere to pin is not a disabled button, it is no button: a thread in
        // no storyline has nothing to offer here.
        onPinToStoryline: pinTo == null
            ? null
            : () => unawaited(_pinAttachment(attachment, pinTo)),
        pinned: _isPinned(attachment),
        onOpenLink: (url) => unawaited(_launchExternal(url)),
      ),
    );
  }

  /// Puts one file into the reply being written for [from].
  ///
  /// One method rather than a closure per surface, because "use this file in
  /// the reply" is asked from three places now — the preview panel's own
  /// button, a card's hover strip in the transcript, and the same strip on the
  /// thread's Files tab — and three copies of this would be three chances for
  /// one of them to leave the draft written off screen.
  void _useAttachmentInReply(DraftTarget from, AttachmentRef attachment) {
    setState(() {
      // The box is always there; what has to be on screen is the THREAD. A
      // file opened from the MAIN thread leaves that thread where it is; one
      // opened from the thread beside REPLACED it, so the thread comes back
      // and the file goes — the draft is what was asked for, and a draft
      // written off screen is nothing happening.
      if (!_isMainThread(from)) {
        _side = ThreadPanel(
          source: from.source,
          conversationKey: from.conversationKey,
        );
        _sideFull = false;
      }
    });
    // The reader asked for a draft about this file, so the box is the place it
    // belongs — staged before the generate, so the words land in an open box
    // rather than waiting on a card for a second gesture.
    _stage(from);
    unawaited(ref.read(draftProvider(from).notifier).generate(
          pinnedAttachmentIds: [attachment.attachmentId],
        ));
    // The cursor goes where the draft will land, so the user is already in the
    // box the words appear in.
    (_isMainThread(from) ? _mainComposerFocus : _sideComposerFocus)
        .requestFocus();
  }

  /// A conversation beside the storyline it belongs to.
  ///
  /// The thread is resolved the way [_selected] resolves the main pane's, out
  /// of the UNFILTERED list: a storyline merges mail and chats, and the source
  /// pills are what the user is browsing with rather than a statement about
  /// what a card may open.
  Widget _threadPanel(ThreadPanel side) {
    final conversation = _conversationFor(side.source, side.conversationKey);
    if (conversation == null) {
      // Moved by a sync, marked done, wiped. Saying so beats a blank panel,
      // and never a `setState` from a build to close it.
      return SidePanelHost(
        title: 'Conversation',
        onClose: _closeSide,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s24),
            child: Text(
              'This conversation is no longer in your inbox.',
              style: BondType.small,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final subject = conversation.subject ?? '';
    final who = [
      for (final p in conversation.participants)
        if (p.display.isNotEmpty) p.display,
    ].join(', ');

    return SidePanelHost(
      // A chat carries no subject — Graph does not give one — so it is named
      // by who is on it, the way a chat is named everywhere else.
      title: subject.isNotEmpty ? subject : (who.isNotEmpty ? who : '(no subject)'),
      subtitle: subject.isNotEmpty ? (who.isEmpty ? null : who) : null,
      // ⤢ hands the thread the main pane proper, which is a selection: it
      // clears the side panel on its way, so the thread is never in both.
      onExpand: () => _select(side.conversationKey, source: side.source),
      onClose: _closeSide,
      child: _threadColumn(conversation, inSidePanel: true),
    );
  }

  /// Whether [target] is the thread the MAIN pane is showing. The main pane
  /// keeps its own composer on screen, so a draft written into it needs no
  /// panel brought back.
  bool _isMainThread(DraftTarget target) =>
      _selectedId == target.conversationKey &&
      (_selectedSource == null || _selectedSource == target.source);

  /// One conversation by source and key, wherever it is in the loaded list.
  ///
  /// Unfiltered, for the reason [_selected] reads the unfiltered list: an
  /// explicit click outranks whichever source pill happens to be down.
  /// Whether the thread a file was opened from is still in the mailbox.
  ///
  /// The viewer rung's guard. A file off a storyline's shelf carries no
  /// thread, and the shelf is not a thing that vanishes under a reader mid-
  /// look; a file opened from a thread belongs to that thread, and a wipe, a
  /// mark-done or a sync that moved it takes the viewer with it.
  bool _viewerOriginExists(FilePanel side) {
    final from = side.from;
    if (from == null) return true;
    return _conversationFor(from.source, from.conversationKey) != null;
  }

  Conversation? _conversationFor(String source, String key) {
    final state = ref.watch(conversationsProvider);
    if (state is ConversationsLoaded) {
      for (final c in state.conversations) {
        if (c.id == key && c.source == source) return c;
      }
    }
    return null;
  }

  /// The same panel with the pane to itself. Back returns to the split — the
  /// panel is the shell's, so there is always something underneath it — and
  /// Home clears everything.
  Widget _attachmentViewer(FilePanel side) {
    final attachment = side.attachment;
    final pinTo = _pinTargetFor(attachment, from: side.from);
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: AttachmentViewerPane(
        key: attachmentKey('viewer', attachment),
        attachment: attachment,
        bytes: _attachmentBytes,
        engines: _previewEngines,
        onBack: () => setState(() => _sideFull = false),
        onHome: () => _selectSection(RailSection.home),
        onOpen: () => unawaited(_openAttachmentInOs(attachment)),
        onSave: () => unawaited(_saveAttachment(attachment)),
        // No 'Use in reply' here: there is no composer on the full pane, and
        // an action whose result is off screen is not an action.
        onPinToStoryline: pinTo == null
            ? null
            : () => unawaited(_pinAttachment(attachment, pinTo)),
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
  /// two. From the storyline's own shelf there is no guessing: it is the
  /// storyline on screen.
  ///
  /// [from] is the conversation the file was opened from, and it is asked
  /// FIRST: a thread open beside a storyline is not [_selectedId], so without
  /// it a file opened from that thread would pin to whatever storyline the
  /// main pane happened to be showing rather than to the thread's own.
  ///
  /// Watched, not read: this runs from a build path, and a thread joining a
  /// storyline has to make the control appear without a second selection.
  String? _pinTargetFor(AttachmentRef attachment, {DraftTarget? from}) {
    final threadId = from?.conversationKey ?? _selectedId;
    if (threadId == null) return _selectedStorylineId;
    final ids = ref
        .watch(storylineThreadIdsProvider(
          (
            source: from?.source ?? attachment.source,
            conversationKey: threadId,
          ),
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

  /// Who the docked box is addressed to, for its placeholder.
  ///
  /// The first participant's name where there is one, the subject where there
  /// is not: "Reply to (no subject)…" is a poor line, but it is still an answer
  /// to "which thread am I typing into", which is what the placeholder is for.
  String _replyWhoFor(Conversation selected) {
    for (final p in selected.participants) {
      if (p.display.isNotEmpty) return p.display;
    }
    if (selected.subject?.isNotEmpty == true) return selected.subject!;
    return 'this thread';
  }

  /// The hover strip's **Reply**: this message, and not the newest one, is what
  /// the next send answers.
  ///
  /// The cursor goes with it. Naming a message and then leaving the user to
  /// find the box would be two gestures for one intention — and the caption the
  /// name draws is above that box, so the eye is being sent there anyway.
  void _replyToMessage(DraftTarget target, Message message, FocusNode focus) {
    final who = message.fromName?.isNotEmpty == true
        ? message.fromName!
        : (message.fromAddress?.isNotEmpty == true
            ? message.fromAddress!
            : 'this message');
    setState(() {
      _replyTo = (target: target, messageId: message.id, who: who);
    });
    focus.requestFocus();
  }

  /// The bar under the transcript: the way to ask for a suggestion, and the
  /// undo row while a send is queued.
  ///
  /// It carries no cards any more — a suggestion answers one message, and it is
  /// drawn under that message. Nor is it a doorway: the composer is docked
  /// under every thread that can be answered. What is left here is what belongs
  /// to the THREAD rather than to any message in it.
  Widget _quickReplies(
    Conversation selected,
    DraftTarget target,
    DraftState draft,
  ) {
    final notifier = ref.read(draftProvider(target).notifier);
    return QuickReplyBar(
      options: const [],
      armed: draft.capability == SendCapability.send,
      onPick: (option) => _pickQuickReply(selected, option),
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
  /// It puts the whole option in the box and takes the cursor there, in every
  /// grant state. A card is text on screen, and a tap on text that quietly put
  /// mail in front of somebody — undo window or not — is not what a reader
  /// expects of it. The composer's own button remains the one send.
  ///
  /// The words are STAGED rather than saved: nothing about the stored draft
  /// changes until the reader types, which is what keeps the suggestion on its
  /// card if they stage it and think better of it.
  void _pickQuickReply(Conversation c, DraftOption option) {
    final target = (source: c.source, conversationKey: c.id);
    _stage(target, body: option.body);
    (_isMainThread(target) ? _mainComposerFocus : _sideComposerFocus)
        .requestFocus();
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
  Widget _composer(
    DraftTarget target, {
    required FocusNode focusNode,
    required String hint,
  }) {
    final conversationKey = target.conversationKey;
    final draft = ref.watch(draftProvider(target));
    final notifier = ref.read(draftProvider(target).notifier);
    final stagedBody = _stagedBodyFor(target, draft);

    final composer = Composer(
      // Keyed on the conversation so switching threads builds a fresh field
      // rather than carrying one thread's typed text into another's — and on
      // the send epoch, so a COMPLETED send builds a fresh empty one instead
      // of leaving the sent text armed behind a re-enabled button. The staged
      // flag is the third: the ✕ has to rebuild an EMPTY field and a stage a
      // filled one, and the field's own controller would otherwise keep
      // whatever it was last given.
      key: ValueKey('composer-$conversationKey-${draft.sendEpoch}'
          '-${stagedBody == null ? 'empty' : 'staged'}'),
      suggestedBody: stagedBody,
      provenance: _provenance,
      generating: draft.generating,
      sending: draft.sending,
      capability: draft.capability,
      onSend: (body) => _send(target, body),
      // Both sources, unconditionally. A chat is drafted through the same
      // queue and the same system prompt a mail is — only the channel's style
      // rules differ, and those ride in the user message — so Regenerate means
      // exactly the same thing on either kind of thread.
      // Staged FIRST, then asked for: the reader pressed a button to get words
      // in this box, so the box has to be listening when they arrive.
      onGenerate: () {
        _stage(target);
        notifier.generate();
      },
      // The ✕ empties the BOX and nothing else. The suggestion is not thrown
      // away by closing the thing it was copied into — deleting one is still
      // the card's own ×, with its two-step confirm.
      onDismiss: () => _unstage(target),
      onEdited: notifier.markEdited,
      hint: hint,
      focusNode: focusNode,
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
        // Only when the user named a message. The caption is the whole of what
        // makes an override visible — a send that quietly answered something
        // other than the newest message would be indistinguishable from a bug.
        if (_replyTo?.target == target) ...[
          Row(
            key: const Key('replying-to'),
            children: [
              Expanded(
                child: Text(
                  'Replying to ${_replyTo!.who}',
                  style: BondType.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _replyTo = null),
                icon: const Icon(Icons.close),
                iconSize: 16,
                tooltip: 'Cancel reply',
                padding: const EdgeInsets.all(BondSpacing.s4),
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: BondSpacing.s4),
        ],
        // A suggestion exists and is not in the box. The cards under the
        // messages are the usual way to reach one, but the draft's own body is
        // not always one of them — a Regenerate rewrites the body without
        // reopening cards, and a thread whose cards were dismissed still has a
        // draft — so without this line a suggestion could sit in the store with
        // no way to reach it from an empty box.
        if (stagedBody == null && (draft.body?.isNotEmpty ?? false)) ...[
          Row(
            key: InboxScreen.useSuggestionKey,
            children: [
              Expanded(
                child: Text(
                  '✨ A suggested reply is ready',
                  style: BondType.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => _stage(target),
                child: const Text('Use it'),
              ),
            ],
          ),
          const SizedBox(height: BondSpacing.s4),
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
    // Only this pane's own override. A message named in the thread beside must
    // not steer a send from the main pane.
    final replyTo = _replyTo?.target == target ? _replyTo!.messageId : null;
    final outcome = await ref
        .read(draftProvider(target).notifier)
        .send(body, replyTo: replyTo);
    if (!mounted) return;
    // Anything but a failure means the named message has been answered, and a
    // caption that outlived its send would steer the NEXT one. A failure keeps
    // it: the retry is the same reply to the same message.
    if (outcome != SendOutcome.failed && _replyTo?.target == target) {
      setState(() => _replyTo = null);
    }
    // And the box that carried it is no longer holding anything staged. The
    // epoch bump rebuilds it empty either way; what this stops is the entry
    // surviving to re-stage the NEXT suggestion this thread is given.
    if (outcome != SendOutcome.failed) _unstage(target);
    switch (outcome) {
      case SendOutcome.sent:
        // A second read, after the sync `send` runs on its way out. The epoch
        // listener already put the echo on screen; by now the Sent Items copy
        // may have replaced it, and this is what shows that swap.
        await _reloadOpenThread();
        if (!mounted) return;
        // The reply just crossed from one half of the Drafts & sent pane to
        // the other. It may be open beside the send that fired this.
        ref.read(draftsInboxProvider.notifier).load();
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
    final base = (section == RailSection.archive && day != null)
        ? 'Later · ${formatDayLabel(day) ?? day}'
        : section.label;
    // The narrowing rides on the title, spelled exactly as the pill spells
    // it: every overview is built from the source-filtered rows, and a pane
    // titled plain 'Needs You' over a list that was quietly halved is a pane
    // that lies about what it is. Home is not here on purpose — the feed
    // reads both connectors whatever the pills say.
    final scope = _sourceFilter;
    final title =
        scope == null ? base : '$base · ${sourceFilterLabel(scope)}';

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
    // Its own early return, on the archive arm's precedent: the shelf has a
    // search box and a pill row above its list, so it is a column rather than
    // a `(label, rows)` pair the list pane could draw.
    if (section == RailSection.files) return _filesPane();
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
        onSnooze: (source, key, until) =>
            unawaited(_snoozeThread(source, key, until)),
      );
    }

    if (section == RailSection.needsYou) return _needsYouOverview(conversations);

    final sections = switch (section) {
      // The People OVERVIEW is the flat list of everything nobody has claimed
      // — the same rows the rail groups into rooms, ungrouped. A room is one
      // person; this is all of them, and it is what the stop lands on before
      // a room is picked.
      RailSection.people => [
          (
            'OPEN',
            conversationRows(
              conversations,
              threshold: ref.watch(appPrefsProvider).attentionThreshold,
            ),
          ),
        ],
      // Unreachable: [_main] routes Home, Drafts & sent and AI to their own
      // panes, and the three arms above return before this switch. The cases
      // exist so the analyzer keeps this exhaustive when a stop is added.
      RailSection.home ||
      RailSection.drafts ||
      RailSection.files ||
      RailSection.archive ||
      RailSection.storylines ||
      RailSection.needsYou ||
      RailSection.ai =>
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
      emptyNotice: _scopeNotice(),
    );
  }

  /// Every document in the mailbox, on one shelf.
  ///
  /// A file opens BESIDE with its thread carried along, which is what makes
  /// Use in reply and pinning work from here: the shelf knows which
  /// conversation each file came with, so the preview panel has the same
  /// origin it would have had if the file had been opened from the transcript.
  Widget _filesPane() {
    final files = ref.watch(filesProvider);
    return FilesPane(
      emptyNotice: _scopeNotice(),
      rows: files.rows,
      loaded: files.loaded,
      loadingMore: files.loadingMore,
      atEnd: files.atEnd,
      error: files.error,
      kind: files.kind,
      onKind: (kind) => ref
          .read(filesProvider.notifier)
          .setKind(kind, sources: _activeSources),
      searchController: _filesSearchText,
      search: files.search,
      searchQuery: files.searchQuery,
      searching: files.searching,
      searchNotice: files.searchNotice,
      onSearch: (query) => ref
          .read(filesProvider.notifier)
          .submitSearch(query, sources: _activeSources),
      onExitSearch: () {
        _filesSearchText.clear();
        ref.read(filesProvider.notifier).exitSearch();
      },
      thumbnailFor: _thumbnailFor,
      onOpen: (row) => _openBeside(FilePanel(
        attachment: row.ref,
        from: row.conversationKey == null
            ? null
            : (source: row.source, conversationKey: row.conversationKey!),
      )),
      onOpenThread: _openThreadBeside,
      onOpenLink: (url) => unawaited(_launchExternal(url)),
      onLoadMore: () =>
          ref.read(filesProvider.notifier).loadMore(sources: _activeSources),
      now: DateTime.now(),
    );
  }

  /// Needs You, under five lenses.
  ///
  /// [NeedsYouTab.all] is the list the rail's badge counts, in the rail's own
  /// order and at the rail's own threshold — so the `+N more` row opens the
  /// list it promised. The other four filter that same list rather than
  /// re-deriving one: the ranking was decided once, and a tab that re-read the
  /// store would eventually rank differently from the column beside it.
  ///
  /// Its own method rather than an arm of the switch below, on the archive
  /// arm's precedent: the pills sit ABOVE the list, so this returns a column
  /// and not a `(label, rows)` pair.
  Widget _needsYouOverview(List<Conversation> conversations) {
    final tab = _needsYouTab;
    final rows = needsYouTabRows(
      tab,
      needsYouRows(
        conversations,
        threshold: ref.watch(appPrefsProvider).attentionThreshold,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BondFilterPillRow<NeedsYouTab>(
          key: const Key('needs-you-tabs'),
          options: NeedsYouTab.values,
          selected: tab,
          labelOf: (t) => t.label,
          onSelected: (t) => setState(() => _needsYouTab = t),
        ),
        const SizedBox(height: BondSpacing.s12),
        Expanded(
          child: ConversationListPane(
            sources: _sources,
            filter: InboxFilter.open,
            conversations: conversations,
            selectedId: _selectedId,
            selectedSource: _selectedSource,
            onSelect: (source, id) => _select(id, source: source),
            sectionsOverride: [
              (
                tab == NeedsYouTab.all
                    ? 'NEEDS YOU'
                    : tab.label.toUpperCase(),
                rows,
              ),
            ],
            // On a list the reader picked BECAUSE every row has a date on it,
            // the date in the sender's own words is worth more than another
            // copy of the ask — which the row's title already carries.
            captionFor: tab == NeedsYouTab.deadlines
                ? (c) => 'Deadline · ${c.latestDeadline}'
                : null,
            processingSince: ref.watch(sessionStartProvider),
            emptyText: tab.emptyText,
            emptyNotice: _scopeNotice(),
          ),
        ),
      ],
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
