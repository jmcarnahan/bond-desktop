import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../data/message_store.dart' show MessageStore;
import '../models/attachment_models.dart';
import '../models/calendar_models.dart' show CalendarDate, CalendarEvent, MailboxSettings;
import '../models/context_models.dart' show ContextScopeKind;
import '../models/draft_provenance.dart';
import '../models/label_models.dart';
import '../models/message_models.dart';
import '../models/open_asks.dart' show latestOutboundAt;
import '../models/people_sort.dart';
import '../models/person.dart';
import '../models/storyline_models.dart';
import '../providers/activity_provider.dart';
import '../providers/app_providers.dart';
import '../providers/archive_provider.dart';
import '../providers/context_provider.dart';
import '../providers/day_providers.dart';
import '../providers/conversations_provider.dart';
import '../providers/draft_provider.dart';
import '../providers/event_providers.dart';
import '../providers/drafts_inbox_provider.dart';
import '../providers/files_provider.dart';
import '../providers/home_provider.dart';
import '../providers/labels_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/person_facts_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/notify_routing.dart';
import '../providers/prefs_provider.dart';
import '../providers/message_history_provider.dart';
import '../providers/recipient_search_provider.dart';
import '../providers/storylines_provider.dart';
import '../providers/why_provider.dart';
import '../services/ai_workers.dart' show pumpTriageThenWorkersQuietly;
import '../services/attachments/attachment_bytes.dart';
import '../services/chat_roster.dart' show teamsRosterLacks;
import '../services/select_similar.dart';
import '../services/attachments/file_dialogs.dart';
import '../services/attachments/html_open.dart';
import '../services/attachments/xlsx_reader.dart';
import '../services/backend/backend_types.dart';
import '../services/calendar/brief_gatherer.dart' show briefQuickCheck;
import '../services/calendar/meeting_brief_handler.dart' show BriefRequest;
import '../services/calendar/calendar_sync.dart' show CalendarSyncStatus;
import '../services/calendar/calendar_writes.dart'
    show CalendarWrite, MoveEvent;
import '../services/calendar/calendar_zone.dart' show CalendarZone;
import '../services/calendar/command/command_lexicon.dart'
    show looksLikeCalendarCommand;
import '../services/calendar/command/command_parser.dart' show parseCommand;
import '../services/calendar/command/command_planner.dart';
import '../services/calendar/command/command_router.dart' show CommandOutcome;
import '../services/calendar/command/command_types.dart'
    show CommandGuess, CommandPath, KnownPerson, ParsedCommand;
import '../services/calendar/day_items.dart';
import '../services/calendar/event_view.dart';
import '../services/calendar/find_time.dart' show searchFindTime;
import '../services/calendar/scheduling_ask.dart' show schedulingAskKey;
import '../services/calendar/overlaps.dart'
    show FreeSlot, Overlaps, overlapsForEvent;
import '../services/calendar/when_resolver.dart' show WhenResolution;
import '../services/calendar/write_rules.dart'
    show
        NewTimeProblem,
        NewTimeTimed,
        checkDrop,
        writeDoneMessage,
        writeSummary;
import '../services/external_sender.dart';
import '../services/llm/draft_task.dart' show DraftOption;
// [ModelSlot] and [LlmTargetSpec] arrive with `prefs_provider.dart`, which
// re-exports them; [ModelPlacement] is not re-exported, and the rail's AI
// stop needs it to say whether the models run on the box.
import '../services/llm/model_slots.dart' show ModelPlacement;
import '../services/llm/storyline_tasks.dart' show NameStorylineTask;
import '../services/profile_photos.dart' show photoKeyFor;
import '../services/triage_queue.dart';
import '../theme/tokens.dart';
import '../widgets/activity_log_panel.dart';
import '../widgets/app_rail.dart';
import '../widgets/archive_pane.dart';
import '../widgets/attachment_format.dart';
import '../widgets/bulk_action_bar.dart';
import '../widgets/cheat_sheet_panel.dart';
import '../widgets/chips.dart';
import '../widgets/composer.dart';
import '../widgets/context_file_panel.dart';
import '../widgets/context_panel.dart';
import '../widgets/conversation_list_pane.dart';
import '../widgets/calendar_write_flow.dart';
import '../widgets/command_plan_card.dart';
import '../widgets/day_command_bar.dart';
import '../widgets/day_grid.dart';
import '../widgets/brief_section.dart';
import '../widgets/day_pane.dart';
import '../widgets/drafts_pane.dart';
import '../widgets/event_actions.dart';
import '../widgets/event_panel.dart';
import '../widgets/files_pane.dart';
import '../widgets/find_field.dart';
import '../widgets/find_time_pane.dart';
import '../widgets/find_filter.dart';
import '../widgets/bond_avatar.dart' show BondAvatar;
import '../widgets/home_pane.dart';
import '../widgets/label_picker.dart';
import '../widgets/icon_rail.dart';
import '../widgets/inline_alert.dart';
import '../widgets/linked_text.dart' show linkTargetOf;
import '../widgets/meeting_card_host.dart';
import '../widgets/message_history_host.dart';
import '../widgets/needs_you_tabs.dart';
import '../widgets/notification_ribbon.dart';
import '../widgets/people_directory_pane.dart';
import '../widgets/people_rooms.dart';
import '../widgets/person_meeting_line.dart';
import '../widgets/person_panel.dart';
import '../widgets/person_room_pane.dart';
import '../widgets/possible_storylines_fold.dart';
import '../widgets/preview/attachment_preview_panel.dart';
import '../widgets/preview/attachment_viewer_pane.dart';
import '../widgets/preview/pdf_preview.dart';
import '../widgets/preview/preview_engines.dart';
import '../widgets/preview/preview_kind.dart' show openRefused;
import '../widgets/quick_replies.dart';
import '../widgets/room_header.dart';
import '../widgets/settings_screen.dart';
import '../widgets/side_panel.dart';
import '../widgets/sort_menu.dart';
import '../widgets/source_filter.dart';
import '../widgets/storyline_pickers.dart';
import '../widgets/storyline_timeline.dart';
import '../widgets/thread_detail_panel.dart';
import '../widgets/time_format.dart';
import '../widgets/triage_intents.dart';
import '../widgets/why_panel.dart';
import 'new_message_screen.dart';
import 'settings_host.dart';

/// The inbox's key map, and the whole key map — the keyboard-triage notes on
/// the screen's state say what each key means.
///
/// Top-level rather than a private static so `cheat_sheet_test` can hold the
/// sheet against the map itself rather than against a copy of it.
///
/// ⌘Z carries a control twin for a runner that is not a Mac, the way the ⌘K
/// binding in `build` does. Escape is mapped to Flutter's own [DismissIntent]
/// rather than to a name of ours: the app already turns Escape into that
/// intent, and anything nested in this region that means something else by it
/// — the side panel's ✕, the Find box's clear — binds the key closer to the
/// cursor and still wins.
@visibleForTesting
const Map<ShortcutActivator, Intent> triageKeys = {
  SingleActivator(LogicalKeyboardKey.keyJ): NextThreadIntent(),
  SingleActivator(LogicalKeyboardKey.arrowDown): NextThreadIntent(),
  SingleActivator(LogicalKeyboardKey.keyK): PreviousThreadIntent(),
  SingleActivator(LogicalKeyboardKey.arrowUp): PreviousThreadIntent(),
  // The letters that DO something to a thread fire once per press: a key held
  // a beat too long would otherwise repeat `e` down the pile, clearing rows
  // the reader never looked at, or flip `x` on and off again. Movement, undo
  // and the sheet keep the default — holding `j` to scroll is what a held key
  // is for.
  SingleActivator(LogicalKeyboardKey.keyE, includeRepeats: false):
      DismissThreadIntent(),
  SingleActivator(LogicalKeyboardKey.keyE, shift: true, includeRepeats: false):
      DismissWithLabelIntent(),
  SingleActivator(LogicalKeyboardKey.keyL, includeRepeats: false):
      LabelThreadIntent(),
  SingleActivator(LogicalKeyboardKey.keyS, includeRepeats: false):
      LaterThreadIntent(),
  SingleActivator(LogicalKeyboardKey.keyR, includeRepeats: false):
      QuickReplyIntent(),
  SingleActivator(LogicalKeyboardKey.keyM, includeRepeats: false):
      DropSenderIntent(),
  SingleActivator(LogicalKeyboardKey.keyX, includeRepeats: false):
      ToggleCheckedIntent(),
  // Brackets, because they already read as forward/back WITHIN a thing
  // where j/k are the things themselves — and they collide with nothing.
  SingleActivator(LogicalKeyboardKey.bracketRight): NextMentionIntent(),
  SingleActivator(LogicalKeyboardKey.bracketLeft): PreviousMentionIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ): UndoLastIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true): UndoLastIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, control: true): UndoLastIntent(),
  // By the character, not by Shift+slash: `?` sits on a different key on a
  // German or French layout, and the reader means the glyph.
  CharacterActivator('?'): ShowCheatSheetIntent(),
  SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
};

/// One triage gesture, wherever it came from.
///
/// A closure and an enabled rule, because the bodies live on the inbox's state
/// and every one of them is "do this to the thread the reader is on". Disabled
/// rather than absent while the cursor is in a box: an action the dispatcher
/// finds disabled leaves the key event UNHANDLED, so the letter reaches the box
/// the reader was typing in — see `_InboxScreenState._editingText`.
class _TriageAction<T extends Intent> extends Action<T> {
  _TriageAction(this._run, {this.live});

  final VoidCallback _run;

  /// Asked at invoke time rather than captured, so one map built once in
  /// `initState` still answers where the cursor is right now.
  final bool Function()? live;

  @override
  bool get isActionEnabled => live?.call() ?? true;

  @override
  Object? invoke(T intent) {
    _run();
    return null;
  }
}

/// A bulk selection as a bulk act captured it, for its Undo to put back.
typedef _Selection = ({
  Set<({String source, String key})> checked,
  ({String source, String key})? anchor,
});

/// The whole app, for now: a dark rail of sections beside one main pane that
/// shows either a section's threads or the open thread's transcript.
///
/// Every row on screen comes from sqlite, which the Graph delta sync fills in
/// behind it. The screen never waits on the network to render: it reads what
/// is stored, asks for a refresh, and shows a banner if that refresh did not
/// land.
/// The one sentence under the inbox's list: how much is waiting, and whether
/// anything is stuck.
///
/// A pure function, apart from the screen, because the WORDING is the thing
/// worth pinning and the screen it lives on owns a sixty-second timer.
///
/// Processing being off wins over every park: a queue nobody is draining is
/// not a queue that is stuck. `session` keeps today's wording, because a
/// sign-out is already routed by the inbox notifier and a second sentence
/// about it here would be the app saying the same thing twice.
/// `model_unavailable` and `unauthorized` read differently on the two
/// placements, because there the answer changes what a person should go and
/// look at; `embed_unavailable` does not, because that server is on this Mac
/// under either placement, `decision_unavailable`, `decision_not_installed`,
/// `decision_misconfigured` and `decision_unauthorized` name the decision
/// model rather than a machine, and `not_installed` is a generative model this Mac has not
/// downloaded, which no server restart fixes.
///
/// "Retrying each minute" is the inbox's own poll and the supervisor's
/// `onReady`, and it is the only cadence this sentence may claim: nothing
/// polls a user-defined server's health.
String railProgressLine({
  required bool on,
  required int remaining,
  required String? reason,
  required int waiting,
  required bool onBox,
}) {
  // [waiting] rather than [remaining], because the switch is about the whole
  // pipeline and the worker lanes have backlogs of their own. The two numbers
  // are the same whenever triage is the only queue holding rows.
  if (!on) return 'Processing is off · $waiting waiting';
  switch (reason) {
    case 'model_unavailable':
      return onBox
          ? 'Your server is not answering · $waiting waiting · retrying each '
              'minute'
          : 'Model server unreachable · $waiting waiting · retrying each '
              'minute';
    // The same sentence under BOTH modes, because the embedding server is on
    // this Mac either way: the user-defined mode moves every generating stage
    // and leaves embeddings local, so "your server is not answering" would
    // name a machine that is answering fine.
    case 'embed_unavailable':
      return 'Embedding server unreachable · $waiting waiting · retrying each '
          'minute';
    // Its own sentence because it is its own server: the decision model is
    // placed apart from the generating one, and "Model server unreachable"
    // would send a person to a server that is answering fine. One wording on
    // both placements, like the embedding arm, because the word names the
    // model rather than the machine.
    case 'decision_unavailable':
      return 'Decision model unreachable · $waiting waiting · retrying each '
          'minute';
    // The decision model's own install is missing (the router is not serving
    // it, or its heads file is not there). Its fix is a command, not the
    // generative download below, so it says which.
    case 'decision_not_installed':
      return 'The decision model is not installed · $waiting waiting · run '
          'make decide-install, then Check in Settings';
    // A server that answers, but not as the decision model does (another
    // model's tokenizer, normalised vectors, no /tokenize), or a heads file
    // this build refuses. Waiting fixes neither, so no retry cadence is
    // claimed: the sentence names both causes and both fixes.
    case 'decision_misconfigured':
      return 'The decision server is not the decision model, or its heads '
          'file does not match · $waiting waiting · check its address in '
          'Settings, or run make decide-install';
    // Named for the decision server whichever way the generative model is
    // placed: that placement says nothing about where this key went.
    case 'decision_unauthorized':
      return 'The decision server refused the access key · $waiting waiting';
    // A managed generative model the router cannot serve because it is not
    // on disk.
    // Not "unreachable": the server is fine, and waiting will not help, so
    // no retry cadence is claimed and the sentence says what to do.
    case 'not_installed':
      return 'A model this Mac runs is not downloaded · $waiting waiting · '
          'set up again in Settings';
    // Named for the machine that refused, like the arm above it: a local
    // server behind a reverse proxy can answer 401 too, and telling that
    // person to go and look at a server they named would send them to the
    // wrong place.
    case 'unauthorized':
      return onBox
          ? 'Your server refused the access key · $waiting waiting'
          : 'Model server refused the access key · $waiting waiting';
    default:
      return 'Triaging $remaining remaining…';
  }
}

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

  /// The day the Day stop is showing; null is today. Null rather than a
  /// stored date so a stop left open across midnight follows the clock.
  ///
  /// Cleared, with [_showingInvites], wherever [_section] is assigned — a
  /// day only means anything on the Day stop — and deliberately NOT by
  /// [_select] and the other openers that leave the stop in place, so
  /// closing a thread opened from a Day row lands back on the same day.
  CalendarDate? _selectedDay;

  /// Whether the Day stop is showing the invites owed rather than a day.
  bool _showingInvites = false;

  /// The Day stop's face and the grid's span, remembered across launches
  /// ([dayViewKey], [dayGridSpanKey]). Unlike [_selectedDay] they are NOT
  /// cleared with the section: they are how the reader likes the day drawn,
  /// not where they were.
  DayView _dayView = DayView.agenda;
  GridSpan _gridSpan = GridSpan.day;

  /// Set by the first press on each control, so the startup read — which may
  /// land after it — never puts back what the reader just changed. One flag
  /// per pref: a press on Agenda | Grid before the read says nothing about
  /// Day | Week, whose stored value the read still restores.
  bool _dayViewTouched = false;
  bool _gridSpanTouched = false;

  /// The last events list the grid drew, and the zone it was read in. While
  /// the next day's or week's read is in flight the grid keeps drawing this
  /// rather than unmounting for "Reading…", which would rebuild its
  /// controllers and scroll the day back to the morning on every arrow.
  /// Tiles are placed by their own instants, so an old list draws nothing
  /// on a page it does not touch. A cache written in build, never a reason
  /// to rebuild.
  List<CalendarEvent>? _lastGridEvents;
  CalendarZone? _lastGridZone;

  /// The move a grid drop asked for, while its write is in flight: the grid
  /// draws it as the ghost tile, "Moving here…", beside the tile that stays
  /// where the store has it. Cleared by the flow's `onIdle`; drawn only while
  /// the flow says busy, so a flow that went away mid-write leaves no ghost.
  ({String id, DateTime startUtc, DateTime endUtc})? _gridMove;

  /// What the Day command bar's last Enter produced, and the text that
  /// produced it (a pressed choice submits the same text again with the
  /// choice bound). Cleared by Escape, Cancel, a write that went through, and
  /// leaving the Day stop — wherever [_section] is assigned to another stop,
  /// the [_selectedDay] rule.
  CommandOutcome? _commandOutcome;
  String _commandText = '';

  /// Every choice pressed on the card for [_commandText], in press order:
  /// two ambiguous names are two presses, and the second must not forget
  /// the first. Handed to the router whole on each press; reset by a new
  /// Enter, Escape and leaving the stop ([_forgetCommand]).
  List<CommandBind> _commandBinds = const [];

  /// A submitted command is still being read; the bar ignores Enter.
  bool _commandBusy = false;

  /// Bumped on every submit, so an answer that arrives after a newer Enter,
  /// an Escape or a trip off the stop is dropped rather than drawn.
  int _commandSerial = 0;

  /// Words ⌘K's "Ask Day" row handed over, waiting for the bar to take them.
  /// One-shot: the bar submits them a frame after it sees them, and the
  /// submit clears this, so the next build hands the bar null and the same
  /// words can be asked again later.
  String? _pendingCommandText;

  /// Which pile Archive is showing. Kept here rather than in the pane so the
  /// tab survives every rebuild the sixty-second poll causes.
  ArchiveTab _archiveTab = ArchiveTab.later;

  /// Which lens the Needs You overview is showing. Here for [_archiveTab]'s
  /// reason, and it survives a trip into a thread and back for the same one:
  /// coming back lands on the tab the reader left.
  NeedsYouTab _needsYouTab = NeedsYouTab.all;

  /// The session's progress over the pile (12g): how many rows have LEFT it
  /// since the reader arrived, over how big it was when they arrived. The
  /// total is snapshotted on the overview's first non-empty render and does
  /// not move when new mail lands mid-session — the line answers "how far
  /// through what I sat down to", and a moving total answers nothing. Both
  /// reset whenever the pile on screen changes ([_resetPileProgress]), so the
  /// next sit-down starts its own count.
  int _clearedThisSession = 0;
  int? _pileAtSessionStart;

  /// The pile as [_triageRows] last read it WHILE the thread the keys act on
  /// ([_triageTarget]) was in it — or while nothing was open — as (source,
  /// key) pairs in drawn order.
  ///
  /// A thread can leave the pile while it is still open beside it: a sent
  /// reply sets it waiting and clears its ask, so it is gone from Needs You
  /// with the reader still reading it. From then on the live list no longer
  /// says where it stood, and `j`, `k` and a reply's mark-done would have
  /// nowhere to step from. This remembers: a read that no longer finds the
  /// target leaves it alone, and [_stepFromDeparted] walks it to the nearest
  /// neighbour still drawn. Cleared by [_resetPileProgress], because a
  /// remembered place in a pile that is no longer on screen is no place.
  List<({String source, String key})> _lastPileIds = const [];

  /// Ends the sit-down: the next non-empty render of whatever pile is on
  /// screen snapshots its own total. Called wherever the pile the reader is
  /// looking at CHANGES — the rail moving, a tab pick, the label lens — since
  /// "3 of 40" held over a five-row tab is a progress line about a pile that
  /// is no longer there. Callers wrap it in their own setState.
  void _resetPileProgress() {
    _clearedThisSession = 0;
    _pileAtSessionStart = null;
    // Where a departed thread stood is a fact about the pile it left.
    _lastPileIds = const [];
    // A selection is about the pile it was made in, and so is its picker.
    _checked.clear();
    _checkAnchor = null;
    _bulkPickerRequest = null;
  }

  /// True only while [_triageAndAdvance] runs an act on a row that is IN the
  /// pile. [_toast] reads it: an undoable toast raised in that window is a
  /// row leaving, so the count and its way back live on the same bar the act
  /// already raised — which is what keeps `_dropSender`'s menu path, whose
  /// toasts fire outside the window, out of the count.
  bool _countingCleared = false;

  /// True while [_triageAndAdvance] is running an act. One act at a time: a
  /// second act starting while the first write is still out would compute
  /// its landing from a list the first is about to move, and act on a thread
  /// the reader has not seen yet.
  ///
  /// What happens to the second one depends on where it came from. A key or a
  /// button is DROPPED: its surface is still on screen, so the reader sees
  /// nothing happened, sees where the first act landed, and presses again. A
  /// picker's apply, its no-label way out and a reply's mark-done are QUEUED
  /// (`queue: true`): the strip or the box that asked has already gone, so a
  /// drop would read as success over a thing that never happened. They wait
  /// on [_triageIdle] and then run as if pressed at that moment.
  bool _triaging = false;

  /// Completed when the act holding [_triaging] finishes — what a queued act
  /// waits on. A fresh one per act, so a waiter never wakes on a stale one.
  Completer<void>? _triageIdle;

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

  /// The People stop's two live filter boxes and the pills over them.
  ///
  /// Held on the screen for [_filesSearchText]'s reason: both panes are
  /// rebuilt on every sync, and a controller either of them owned would lose a
  /// half-typed needle each time. The needles are kept normalised, so the pane
  /// and the pure filters behind it measure the same thing.
  final TextEditingController _peopleSearchText = TextEditingController();
  final TextEditingController _roomSearchText = TextEditingController();
  String _peopleNeedle = '';
  String _roomNeedle = '';
  PeopleFilter _peopleFilter = PeopleFilter.all;
  RoomFilter _roomFilter = RoomFilter.all;

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

  /// Whether the last layout gave the pane to something other than the main
  /// pane's own content: a side panel too wide to sit beside it, any side
  /// panel at the narrow width, or a file opened full-pane. With it set, the
  /// Needs You overview and its ticked rows are not on screen, and
  /// [_selectionActive] and [_toggleTargetChecked] stand down.
  ///
  /// A plain field written by [_wide] and [_narrow], for [_rows]'s reason: it
  /// is derived from the layout every frame, nothing renders it, and the keys
  /// read it later in response to a press.
  bool _overviewCovered = false;

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

  /// The storyline the add-thread pane is picking a conversation for. An
  /// overlay on the storyline selection rather than a peer of it: back returns
  /// to the storyline underneath.
  String? _addingToStorylineId;

  /// The thread the add-to-storyline pane is filing. Same overlay contract.
  ({String source, String id})? _pickingStorylineForThread;

  /// The thread Find a time is open for — a pane over that thread, the same
  /// overlay contract as the two above: Back and Put in reply return to the
  /// thread underneath, and every selection clears it.
  ({String source, String key})? _findTimeFor;

  /// Whether the New storyline pane is up — a storyline declared from a title
  /// and a charter with no thread in it yet. Same overlay contract as the two
  /// above, and it takes the main pane rather than a layer over it.
  bool _declaringStoryline = false;

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

  /// Bumped on every EXPLICIT stage and on the ✕, and part of the composer's
  /// key — see [_composer] — so those two rebuild the field from scratch. A
  /// quiet stage ([_stageQuietly]) leaves it alone, which is what keeps a
  /// sentence typed while the model was thinking from being thrown away when
  /// the model's answer lands.
  final Map<String, int> _stageSeq = {};

  /// Which directories have their `Files ›` disclosure open on the Context
  /// panel.
  ///
  /// [_clearOverlays] deliberately does NOT touch it: this is a preference of
  /// the panel and not a panel, so a person who opened a project's file list,
  /// looked at a file and came back is owed the list still open.
  final Set<String> _expandedContextDirs = {};

  String _stageKey(DraftTarget t) => '${t.source}|${t.conversationKey}';

  /// Puts [body] — or, null, the draft's own body — in the box, and rebuilds
  /// the box to do it: the reader asked for these words by name (a card, the
  /// `Use it` line), and a field holding their own half-typed sentence has to
  /// give way to them.
  void _stage(DraftTarget t, {String? body}) => setState(() {
        final key = _stageKey(t);
        _staged[key] = body;
        _stageSeq[key] = (_stageSeq[key] ?? 0) + 1;
      });

  /// Tells the box to LISTEN for the draft — the generate the reader just
  /// asked for — without rebuilding it. The words land through the field's own
  /// update, which never overwrites typed text: a sentence written while the
  /// model was thinking outranks what the model wrote.
  void _stageQuietly(DraftTarget t) =>
      setState(() => _staged[_stageKey(t)] = null);

  /// Empties the box, and rebuilds it empty.
  void _unstage(DraftTarget t) => setState(() {
        final key = _stageKey(t);
        _staged.remove(key);
        _stageSeq[key] = (_stageSeq[key] ?? 0) + 1;
      });

  /// The side thread whose box should take the cursor the moment it mounts —
  /// set by the room header's `Message`, which opens a chat beside and means
  /// "type here". Read by [_composer] as the field's `autofocus`; a focus
  /// requested a frame after the open would miss, because the box appears
  /// only once the draft's capability has been read.
  DraftTarget? _focusSideOnMount;

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

  // One handle per mounted transcript, for the same reason the composer focus
  // is two nodes: the wide layout mounts a main and a side panel at once, and
  // a shared handle would belong to whichever attached last. The keys bind to
  // the main one, as FocusReplyIntent does with its focus node.
  final TranscriptJumps _mainJumps = TranscriptJumps();
  final TranscriptJumps _sideJumps = TranscriptJumps();

  /// What makes the side panel's own Escape binding reachable — see
  /// [_sidePanel].
  ///
  /// `CallbackShortcuts` only sees keys while focus is somewhere inside its
  /// subtree, and nothing in a panel of pictures and chips ever asks for
  /// focus: a reader who clicked a thumbnail and pressed Escape would be
  /// pressing it at the screen's own root. So the panel takes focus on a click
  /// anywhere in it — but only where it does not already have it, or a press in
  /// the reply box would pull the cursor out of the box the press was aimed at.
  /// Never autofocused: it must not take the cursor off the main pane's
  /// composer just because something opened beside it.
  final FocusNode _sidePanelFocus = FocusNode(debugLabel: 'side panel');

  /// What makes the triage keys reachable — see [_triageScope].
  ///
  /// The `Shortcuts` pair sits over the list and the detail and nowhere else, so
  /// it only sees a key while focus is somewhere inside that region; the
  /// `Focus(autofocus: true)` at the top of [build] exists to make ⌘K global and
  /// would otherwise hold the focus itself, above the pair, where single letters
  /// would never arrive. So this node asks for focus in [initState] and gets it
  /// the moment the region mounts (a request made before a node has a parent is
  /// honoured at its reparent), and [_takeTriageFocus] hands it back whenever a
  /// selection moves. It never takes focus off something INSIDE the region: a
  /// composer or a picker there is a descendant, and [FocusNode.hasFocus] is
  /// what says so.
  final FocusNode _triageFocus = FocusNode(debugLabel: 'triage list');

  /// The undo the last toast offered, and the only one [UndoLastIntent] can
  /// reach.
  ///
  /// ONE slot, deliberately: [_toast] hides the bar already on screen rather
  /// than queueing behind it, so the only undo a reader can see is the newest
  /// one — and a second action therefore OVERWRITES the first's undo here, for
  /// the keyboard exactly as it already did for the bar. A toast with no undo of
  /// its own clears the slot for the same reason: there is nothing on screen
  /// offering to take anything back.
  VoidCallback? _lastUndo;

  /// The label picker the reader has asked for: which thread it is about, and
  /// whether applying a label should dismiss the thread with it (`Shift+E`) or
  /// leave it where it is (`l`).
  ///
  /// The picker mount reads this; wired at phase integration. Nothing in this
  /// file draws a picker — the widget and its two mounts land with the picker
  /// package, and this is the request they answer.
  ({String source, String key, bool dismissAfter})? _labelPickerRequest;

  /// The row whose in-list quick reply is open, on [_labelPickerRequest]'s
  /// pattern: a request the pane answers, and a stale one that names no drawn
  /// row draws nothing. One strip at a time — each of the two opens clears
  /// the other's request, because a box and a picker on one row would be two
  /// answers to "what is the reader doing here".
  ({String source, String key})? _quickReplyFor;

  /// The rows ticked for a bulk act (12c), by source and id — records compare
  /// by value, so a row rebuilt by a sync is still the row that was ticked.
  ///
  /// Here and nowhere else: the pane is stateless by design and only draws the
  /// boxes, and the keys, the bar and the acts all read this one set. It can
  /// hold a row a sync has since taken off the list, which is why nothing reads
  /// it bare — see [_liveChecked].
  final Set<({String source, String key})> _checked = {};

  /// The last row ticked or unticked on its own: where a Shift-click range
  /// starts, and the row select-similar offers to match. A range leaves it
  /// where it was, so a second Shift-click re-sweeps from the same place.
  ({String source, String key})? _checkAnchor;

  /// The bulk bar's label picker, open or not, and whether applying a label
  /// dismisses the ticked rows with it (`Shift+E`) or files them where they
  /// stand (`l`, the bar's Label…). One of the three strips — it, the row
  /// picker's [_labelPickerRequest] and [_quickReplyFor] each clear the other
  /// two when they open.
  ({bool dismissAfter})? _bulkPickerRequest;

  /// The label lens on the Needs You pile, or null for no lens. Session state
  /// like [_needsYouTab], not a preference: a filter the reader put on to work
  /// through one pile does not belong on tomorrow's inbox.
  String? _needsYouLabelId;

  /// [_needsYouLabelId], but only while the vocabulary still holds that label:
  /// a lens whose label was deleted in Settings must read as no lens, not as an
  /// empty pile with no visible cause.
  String? get _activeNeedsYouLabelId {
    final id = _needsYouLabelId;
    if (id == null) return null;
    final labels = ref.read(labelsProvider).labels;
    return labels.any((l) => l.id == id) ? id : null;
  }

  /// What is open beside the main pane, innermost LAST: a file, or a thread
  /// reached from inside a storyline. An overlay ON what the main pane is
  /// showing rather than a peer of it — a file is read against the message
  /// that carried it, and a thread against the storyline it belongs to.
  /// Cleared wherever the selection moves, exactly like [_replyTo].
  ///
  /// A stack rather than a slot, because a panel opened from INSIDE another
  /// one is a step further in rather than a different subject: a file clicked
  /// in the thread beside used to overwrite that thread, and the ✕ on it
  /// dismissed the whole panel — the reader lost the conversation they were
  /// reading and had to find it in the list again. Opening from outside still
  /// REPLACES ([_openBeside] without `push`), because the side shows one
  /// thing and a panel nobody navigated into has nothing behind it.
  final List<SidePanel> _sideStack = [];

  /// The panel actually on screen — the innermost one. Every reader of "what
  /// is beside" goes through here rather than indexing the stack.
  SidePanel? get _side => _sideStack.isEmpty ? null : _sideStack.last;

  /// Where the side panel's transcripts keep their scroll offsets, so a thread
  /// that was pushed under a file comes back where the reader left it rather
  /// than at the top. Its own bucket and not the route's: the same thread can
  /// be in the main pane and beside it at once, and one bucket would have the
  /// two panes fighting over one offset.
  final PageStorageBucket _sideStorage = PageStorageBucket();

  /// Which rows of which thread the reader has UNFOLDED, by
  /// `'$source|$conversationKey'`.
  ///
  /// Hoisted out of `MessageRow`, which seeds its own fold once and never
  /// recomputes it: that keeps a fold from moving under a cursor, but it also
  /// means a transcript rebuilt from scratch — a side thread coming back from
  /// under a file — opens every history row folded again. The set is only ever
  /// about unfolds; a row the reader FOLDED that started open is not restored,
  /// and the panel's own rule opens it again.
  ///
  /// [_clearOverlays] deliberately does NOT touch it, for
  /// [_expandedContextDirs]'s reason: this is a preference about a thread, not
  /// a panel, and somebody who opened a run and came back is owed it open.
  final Map<String, Set<String>> _unfoldedRows = {};

  /// Whether the innermost panel has the whole main pane. Only ever true of a
  /// [FilePanel] — ⤢ on a thread hands it to the main pane proper, which
  /// clears the stack — and cleared on every pop.
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

  /// Whether a pull is OUT on each connector, for the Inbox's pulse strip.
  ///
  /// Two flags rather than one, because the two pulls are independent — the
  /// timer runs mail alone and the resume path runs Teams alone — and one flag
  /// would report "Syncing mail and Teams…" for either of them. Local to this
  /// screen for [_syncing]'s reason: it is what one line of narration says
  /// while a future is in flight, and a future in flight is not a fact the
  /// database has any opinion about.
  bool _mailPulling = false;
  bool _teamsPulling = false;

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

  /// What "external" is measured against, everywhere this screen says it:
  /// empty for the first frames — nobody is external until the account is
  /// read, which errs quiet rather than tinting the whole list.
  Set<String> get _ownerDomains =>
      ownerDomainsOf(_owner?.mail ?? _owner?.userPrincipalName);

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
      // The chips first, so the first page is read under the connectors the
      // screen is actually showing. Two reads at most, once, at startup — the
      // notifier's sequence guard discards whichever answer is older.
      ref.read(homeFeedProvider.notifier).setSources(_activeSources);
      ref.read(homeFeedProvider.notifier).load();
      // The label vocabulary rides the same read: one indexed table, and the
      // row chips, the filter pills and Find's autocomplete all want it from
      // the first frame that draws them.
      unawaited(ref.read(labelsProvider.notifier).load());
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
    unawaited(_loadDayView());
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
    // Asked for now and honoured when the region arrives: the list is where a
    // reader who has clicked nothing yet is standing, and it is where the
    // triage keys have to land. See [_triageFocus].
    _triageFocus.requestFocus();
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _mainComposerFocus.dispose();
    _sideComposerFocus.dispose();
    _sidePanelFocus.dispose();
    _triageFocus.dispose();
    _findText.dispose();
    _findFocus.dispose();
    _filesSearchText.dispose();
    _peopleSearchText.dispose();
    _roomSearchText.dispose();
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

  /// Reports a pull going out or coming back, for the pulse strip.
  ///
  /// A no-op when neither flag moves: this runs on every pass, and a setState
  /// per minute for a value that did not change would rebuild the whole screen
  /// for nothing. Off the widget tree it still writes the fields, so a pass
  /// that finished after the screen went away leaves nothing stuck at "out".
  void _notePulling({bool? mail, bool? teams}) {
    final nextMail = mail ?? _mailPulling;
    final nextTeams = teams ?? _teamsPulling;
    if (nextMail == _mailPulling && nextTeams == _teamsPulling) return;
    if (!mounted) {
      _mailPulling = nextMail;
      _teamsPulling = nextTeams;
      return;
    }
    setState(() {
      _mailPulling = nextMail;
      _teamsPulling = nextTeams;
    });
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
  ///
  /// The calendar rides the timer too — it is Graph calendar, not the Teams
  /// messaging endpoints, so the poll may reach it — but fire-and-forget and
  /// only once the mail load has returned, so it can neither fail nor delay
  /// mail. It is started in the same `finally` that clears the pulling flag,
  /// so a mail load that threw does not cost the calendar its tick.
  /// [forceCalendar] skips its two-minute throttle.
  Future<void> _refresh({bool forceCalendar = false}) async {
    if (!mounted) return;
    _notePulling(mail: true);
    final mail = ref.read(conversationsProvider.notifier).load();
    ref.read(storylinesProvider.notifier).load();
    // The tiles otherwise re-read only behind a pipeline tick, and a row
    // crosses the stalled threshold by NOT ticking. This poll is the clock
    // that lets the In flight tile catch up with the rows under it, which
    // re-evaluate on every rebuild. A no-op when nobody is watching them.
    ref.invalidate(homeMetricsProvider);
    // Beside it for the same reason one step further on: the pulse's ten-minute
    // window decays without a tick, so a drain that finished eight minutes ago
    // would still be reported as news until something else moved.
    ref.invalidate(pipelinePulseProvider);
    // The clear is in a `finally` and not after the await: this method returns
    // early on `!mounted` below, and a leg that threw would otherwise leave the
    // strip saying "Syncing mail…" for the rest of the session.
    try {
      await mail;
    } finally {
      _notePulling(mail: false);
      // Un-awaited, as everywhere: the calendar never holds up this pass.
      if (mounted) _syncCalendar(force: forceCalendar);
    }
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
  ///
  /// The thread BESIDE also gets its draft reloaded here, where the selected
  /// thread's is reloaded by [_refresh]. Same hazard, two places, because the
  /// two threads are tracked in two fields and an Inbox row only ever sets the
  /// side one.
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
      // The same hazard [_refresh] states about the selected thread, and this
      // is now the likelier half of it: an Inbox row opens BESIDE and never
      // sets `_selectedId`, so the thread the reader is actually looking at on
      // the landing screen is the one whose draft would go stale. The sync
      // deletes a draft whose thread just received new mail, and a suggestion
      // left on screen after that gets sent as a reply to a message that is no
      // longer the newest one.
      ref
          .read(
            draftProvider(
              (source: side.source, conversationKey: side.conversationKey),
            ).notifier,
          )
          .load();
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
    // A room has no transcript of its own to refresh: it is a list of cards
    // derived from the conversation list, which the poll has already reloaded.
    final storyline = _selectedStorylineId;
    if (storyline != null) {
      await ref.read(storylineTimelineProvider(storyline).notifier).load();
    }
  }

  /// What the refresh button does: the mail refresh the timer also runs, plus
  /// the Teams pull the timer must never run. Startup comes through here too,
  /// and both force the calendar past its throttle: a person who pressed
  /// Refresh, or just opened the app, is asking for now.
  ///
  /// The read-acks are pumped from HERE rather than from [_refresh], for the
  /// same reason [_refreshTeams] is: the queue carries chat acks as well as
  /// mail ones, and every call on it has to trace back to something the user
  /// did. Refresh is the second way a parked ack gets another go — the first
  /// is reopening the thread.
  Future<void> _refreshAll() async {
    final mail = _refresh(forceCalendar: true);
    unawaited(ref.read(readAckQueueProvider).pump());
    await _refreshTeams();
    // Held to the end rather than awaited first: the two pulls go out
    // together, as they always have, and this future is only here so a caller
    // that wants to know when the whole thing is done can find out.
    await mail;
  }

  /// One calendar sync tick, fire-and-forget. What it found reaches the
  /// calendar's readers through the sync's own publisher
  /// ([calendarOutcomePublisher]), as a write's forced read does; this only
  /// plans briefs off it.
  ///
  /// Never awaited by [_refresh] and never on `ConversationsNotifier.load`:
  /// a slow or failing calendar must not hold up or break the mail. The sync
  /// itself never throws; the catch is for the provider reads, and it is
  /// silent beyond a trace for the same reason.
  void _syncCalendar({bool force = false}) {
    unawaited(() async {
      try {
        final sync = ref.read(calendarSyncProvider);
        final outcome = await sync.syncNow(force: force);
        if (!mounted) return;
        // Briefs are planned only off a sync that completed, and only while
        // the models may run; the plan itself is store reads, and its pump
        // is the draft lane's, so nothing here waits on a model.
        if (outcome.status == CalendarSyncStatus.synced &&
            ref.read(processingProvider)) {
          unawaited(_planBriefs());
        }
      } on Object catch (e) {
        debugPrint('calendar sync was not run: $e');
      }
    }());
  }

  /// Queues the briefs the calendar now makes due and wakes the draft lane
  /// when it queued any. Fire-and-forget off [_syncCalendar]; a failure is a
  /// trace and never reaches the mail.
  Future<void> _planBriefs() async {
    try {
      final zone =
          ref.read(calendarZoneProvider).valueOrNull ?? CalendarZone.utc();
      final queued = await ref
          .read(briefPlannerProvider)
          .plan(now: DateTime.now(), zone: zone);
      if (!mounted || queued == 0) return;
      ref.read(briefRevisionProvider.notifier).state++;
      unawaited(ref.read(draftWorkerProvider).pump());
    } on Object catch (e) {
      debugPrint('briefs were not planned: ${e.runtimeType}');
    }
  }

  /// Regenerate on a brief: to the front of the draft lane, because a person
  /// asked for it now, and marked asked so the handler writes a new brief
  /// even when nothing it is written from has changed.
  Future<void> _regenerateBrief(String eventId) async {
    try {
      await ref.read(messageStoreProvider).requeueWork(
            'meeting_brief',
            'calendar',
            eventId,
            payloadJson: const BriefRequest(asked: true).encode(),
            refreshCreatedAt: true,
          );
      if (!mounted) return;
      ref.read(briefRevisionProvider.notifier).state++;
      unawaited(ref.read(draftWorkerProvider).pump());
    } on Object catch (e) {
      debugPrint('a brief was not requeued: ${e.runtimeType}');
    }
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
    _notePulling(teams: true);
    try {
      await ref.read(conversationsProvider.notifier).refreshTeams();
    } finally {
      _notePulling(teams: false);
    }
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
    // The links and nothing else: they name conversation keys and storyline
    // ids the wipe just deleted. The directories stay registered — they are
    // the user's own folders, not this mailbox's data.
    await ref.read(contextStoreProvider).unlinkAll();
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
    _sideStack.clear();
    _sideFull = false;
    _focusSideOnMount = null;
    _addingToStorylineId = null;
    _pickingStorylineForThread = null;
    _findTimeFor = null;
    _declaringStoryline = false;
    _railOpen = false;
    _replyTo = null;
    _showingActivityLog = false;
    _showingSettings = false;
    _showingCompose = false;
  }

  /// Opens something beside the main pane, always in the split and never in
  /// the full pane: a panel that inherited the last one's ⤢ would take over a
  /// screen the user did not ask it to.
  ///
  /// REPLACE is the default and stays it: the side shows one thing, and a
  /// panel opened from the main pane, the rail or a list row is a new subject
  /// with nothing behind it. [push] is for the opens that originate INSIDE the
  /// panel — a file, a Why or a history asked for from the thread beside, a
  /// directory file asked for from the Context panel beside — where the thing
  /// underneath is what the reader came from and the ✕ owes it back to them.
  /// Pushing what is already on top replaces it, so a second tap on the same
  /// chip cannot stack a panel on itself. Pushing what already sits DEEPER
  /// unwinds the stack back to it — [_restoreSideThread]'s rule — so a
  /// meeting → its thread → that thread's invite card cannot cycle into
  /// meeting, thread, meeting.
  void _openBeside(SidePanel panel, {bool push = false}) => setState(() {
        final at = push
            ? _sideStack.lastIndexWhere((p) => _samePanel(p, panel))
            : -1;
        if (at >= 0) {
          _sideStack.removeRange(at + 1, _sideStack.length);
          _sideStack[at] = panel;
        } else if (push && _sideStack.isNotEmpty) {
          _sideStack.add(panel);
        } else if (_sideStack.isEmpty) {
          _sideStack.add(panel);
        } else {
          _sideStack[_sideStack.length - 1] = panel;
        }
        _sideFull = false;
        _focusSideOnMount = null;
        _dropSideReplyTarget();
      });

  /// The ✕, and Escape: closes THIS panel, which means going back to whatever
  /// it was opened from and closing the side only when there is nothing left
  /// underneath. ⤢ never survives a pop — the panel coming back was last seen
  /// in the split and is owed the split.
  void _closeSide() {
    setState(() {
      if (_sideStack.isNotEmpty) _sideStack.removeLast();
      _sideFull = false;
      _focusSideOnMount = null;
      _dropSideReplyTarget();
    });
    // The panel was the room the cursor was standing in, and it is going away.
    // Unasked for, the cursor falls out of the region with it and the letter
    // keys go dead on a list the reader is looking straight at — so the list
    // takes it back. Not [_takeTriageFocus]: the node about to be disposed is
    // itself inside the region, so `hasFocus` is true right up to the frame
    // that drops it.
    _triageFocus.requestFocus();
  }

  /// Whether two panels are about the same thing — what stops a push stacking
  /// a panel on itself, and how [_restoreSideThread] finds the thread it is
  /// bringing back.
  ///
  /// By subject rather than by `==`: no [SidePanel] carries value equality,
  /// and [AttachmentRef] deliberately does not either — a digest landing
  /// mid-frame must not make a file stop being the file on screen, which is
  /// why `sameAttachment` exists.
  static bool _samePanel(SidePanel a, SidePanel b) => switch ((a, b)) {
        (ThreadPanel a, ThreadPanel b) =>
          a.source == b.source && a.conversationKey == b.conversationKey,
        (FilePanel a, FilePanel b) => sameAttachment(a.attachment, b.attachment),
        (PersonPanel a, PersonPanel b) => a.roomKey == b.roomKey,
        (WhyPanel a, WhyPanel b) =>
          a.source == b.source && a.messageId == b.messageId,
        (HistoryPanel a, HistoryPanel b) => a.source == b.source && a.id == b.id,
        (ContextPanel a, ContextPanel b) =>
          a.kind == b.kind && a.source == b.source && a.scopeKey == b.scopeKey,
        (ContextFilePanel a, ContextFilePanel b) =>
          a.fileId == b.fileId && a.locator == b.locator,
        (CheatSheetPanel(), CheatSheetPanel()) => true,
        (EventPanel a, EventPanel b) => a.eventId == b.eventId,
        _ => false,
      };

  /// A side thread that goes away takes its reply target with it. The caption
  /// belongs to a box that is no longer on screen, and a send into the thread
  /// that comes back next must not inherit somebody else's message id.
  ///
  /// "Goes away" is about the whole STACK, not the top of it: a thread pushed
  /// under a file it opened is still on its way back, and dropping the caption
  /// there would lose the message the reader said they were answering between
  /// the ✕ and the panel returning. The half-typed body itself never came
  /// through here — it lives on `draftProvider` and in [_staged].
  ///
  /// Called from inside the caller's own `setState`.
  void _dropSideReplyTarget() {
    final replyTo = _replyTo;
    if (replyTo == null || _isMainThread(replyTo.target)) return;
    final thread = ThreadPanel(
      source: replyTo.target.source,
      conversationKey: replyTo.target.conversationKey,
    );
    for (final panel in _sideStack) {
      if (_samePanel(panel, thread)) return;
    }
    _replyTo = null;
  }

  /// Brings the thread [from] back to the side panel, whatever is standing on
  /// it — what `Use in reply` and `Consult` need, because a draft written into
  /// a box that is off screen is nothing happening.
  ///
  /// A file opened FROM the thread beside was pushed ON it, so the thread is
  /// underneath and unwinding to it is the whole job: its scroll, its unfolded
  /// rows and its reply caption all come back with it. A file opened from
  /// somewhere else — a storyline's shelf, a person's files — never had that
  /// thread underneath, so the top is replaced the way it always was.
  ///
  /// Called from inside the caller's own `setState`.
  void _restoreSideThread(DraftTarget from) {
    final thread = ThreadPanel(
      source: from.source,
      conversationKey: from.conversationKey,
    );
    _sideFull = false;
    for (var i = _sideStack.length - 1; i >= 0; i--) {
      if (!_samePanel(_sideStack[i], thread)) continue;
      _sideStack.removeRange(i + 1, _sideStack.length);
      return;
    }
    if (_sideStack.isEmpty) {
      _sideStack.add(thread);
    } else {
      _sideStack[_sideStack.length - 1] = thread;
    }
  }

  /// Where the ✕ on the innermost panel lands, for the row that says so. Null
  /// where a pop closes the panel: the ✕ already says that, and a second
  /// control saying the same thing is one of them lying.
  VoidCallback? get _sideBack => _sideStack.length > 1 ? _closeSide : null;

  /// What that row calls the panel underneath.
  String? get _sideBackLabel => _sideStack.length > 1
      ? _backLabelFor(_sideStack[_sideStack.length - 2])
      : null;

  /// What a panel is CALLED one rung down — the same words its own header
  /// carries, resolved from what the panel itself knows.
  ///
  /// In practice only a thread or the Context panel is ever underneath, since
  /// those are the two the pushes originate in; the other arms are here so
  /// that a later push cannot land on an unnamed row.
  String _backLabelFor(SidePanel panel) => switch (panel) {
        ThreadPanel() => _threadLabelFor(panel.source, panel.conversationKey),
        FilePanel() => panel.attachment.name ?? 'the file',
        PersonPanel() => _roomTitleFor(panel.roomKey) ?? 'the person',
        WhyPanel() => 'Why',
        HistoryPanel() => 'What happened',
        ContextPanel() => 'Context',
        ContextFilePanel() => 'the file',
        CheatSheetPanel() => 'Keyboard shortcuts',
        EventPanel() => 'the meeting',
      };

  /// A thread's own name for that row: [_roomNameFor]'s rule, and a phrase
  /// rather than a blank for one the list no longer has.
  String _threadLabelFor(String source, String conversationKey) {
    final conversation = _conversationFor(source, conversationKey);
    if (conversation == null) return 'the conversation';
    final name = _roomNameFor(conversation);
    return name.isEmpty ? 'the conversation' : name;
  }

  /// One room's title out of the list this build was handed, or null for a key
  /// whose people went quiet while the panel was open.
  String? _roomTitleFor(String roomKey) {
    for (final room in _rooms) {
      if (room.key == roomKey) return room.title;
    }
    return null;
  }

  /// Opens a conversation BESIDE whatever is in the main pane — a storyline's
  /// episode card, and in later phases a person room's root message.
  ///
  /// Everything [_select] does except take the main pane: the thread and its
  /// draft are loaded the same way, and opening it still counts as reading it.
  ///
  /// [push] is [_openBeside]'s: a thread asked for from INSIDE a panel — the
  /// event panel's Conversations — goes on top of it, so the ✕ comes back to
  /// the meeting.
  void _openThreadBeside(
    String source,
    String conversationKey, {
    bool push = false,
  }) {
    _openBeside(
      ThreadPanel(source: source, conversationKey: conversationKey),
      push: push,
    );
    final target = (source: source, conversationKey: conversationKey);
    ref.read(conversationsProvider.notifier).noteThreadOpened(conversationKey);
    ref.read(conversationsProvider.notifier).markRead(source, conversationKey);
    ref.read(threadProvider(target).notifier).load();
    ref.read(draftProvider(target).notifier).load();
  }

  /// Opens one meeting beside the main pane, by its Graph id — from a Day row,
  /// the Today section, a person's room, or (with [push]) an invite card in the
  /// thread beside, whose ✕ should land back on that thread.
  void _openEvent(String eventId, {bool push = false}) =>
      _openBeside(EventPanel(eventId: eventId), push: push);

  /// Which file the side panel is showing, for the chips that mark it. Both
  /// panes read this one getter — a chip highlighted in the transcript and not
  /// in the spine is two answers to one question.
  AttachmentRef? get _sideAttachment {
    final side = _side;
    return side is FilePanel ? side.attachment : null;
  }

  /// The thread open beside the main pane, for the lists in main that highlight
  /// it. Same shape as [_sideAttachment] and for the same reason: a row lit in
  /// the list and a panel showing something else is two answers to one
  /// question.
  ThreadPanel? get _threadBeside {
    final side = _side;
    return side is ThreadPanel ? side : null;
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
    // And the Day stop asks the calendar for a forced tick: the mirror is
    // only as current as the last sync, and arriving is when a reader is
    // looking at it.
    if (section == RailSection.day) _syncCalendar(force: true);
    setState(() {
      _clearOverlays();
      // Moving the rail ends the sit-down: the next visit to the overview
      // snapshots its own pile — see [_pileAtSessionStart].
      _resetPileProgress();
      _section = section;
      _selectedDay = null;
      _showingInvites = false;
      if (section != RailSection.day) _forgetCommand();
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
  ///
  /// It reads nothing and marks nothing. Every row in the room is a CARD — a
  /// summary, not the mail — and the conversation itself opens beside, where
  /// [_openThreadBeside] marks it read the way opening a thread always has.
  /// The room's own filter and needle reset with it: they were a question
  /// about the last person, and carrying them into the next one would open an
  /// empty room over somebody who has plenty.
  void _selectRoom(String key) {
    _roomSearchText.clear();
    setState(() {
      _clearOverlays();
      _section = RailSection.people;
      _selectedDay = null;
      _showingInvites = false;
      _forgetCommand();
      _selectedRoomKey = key;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _roomFilter = RoomFilter.all;
      _roomNeedle = '';
    });
  }

  /// Opens one day's Later digest. The section moves with it, so backing out of
  /// the day lands on the whole pile rather than wherever the user was before —
  /// and the tab moves with it too, since a day only means anything in Later.
  void _selectLaterDay(String dayKey) {
    setState(() {
      _clearOverlays();
      _section = RailSection.archive;
      _selectedDay = null;
      _showingInvites = false;
      _forgetCommand();
      _archiveTab = ArchiveTab.later;
      _selectedLaterDay = dayKey;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedRoomKey = null;
    });
  }

  /// Opens one day on the Day stop. The section moves with it, for
  /// [_selectLaterDay]'s reason: backing out of whatever opens next lands on
  /// the Day stop, and the column beside it is the days.
  ///
  /// Picking TODAY stores no date at all, the same as arriving on the stop:
  /// today is a moving thing, and a pinned date would leave a pane left open
  /// across midnight titled "Yesterday" — the reader asked for today, not for
  /// the date today happened to be.
  void _selectDay(CalendarDate day) {
    final today = ref
        .read(calendarZoneProvider)
        .valueOrNull
        ?.dateOf(DateTime.now().toUtc());
    setState(() {
      _clearOverlays();
      _section = RailSection.day;
      _selectedDay = day == today ? null : day;
      _showingInvites = false;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
      _selectedRoomKey = null;
    });
  }

  /// Reads the Day stop's remembered face once, at startup. A value this
  /// build did not write (or a failed read) leaves the default, the agenda.
  Future<void> _loadDayView() async {
    final String? view;
    final String? span;
    try {
      final store = ref.read(messageStoreProvider);
      view = await store.getPref(dayViewKey);
      span = await store.getPref(dayGridSpanKey);
    } on Object catch (e) {
      debugPrint('the day view preference could not be read: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      if (!_dayViewTouched) {
        _dayView =
            DayView.values.where((v) => v.name == view).firstOrNull ?? _dayView;
      }
      if (!_gridSpanTouched) {
        _gridSpan = GridSpan.values.where((v) => v.name == span).firstOrNull ??
            _gridSpan;
      }
    });
  }

  /// Agenda | Grid, and Day | Week: drawn at once, written behind. A write
  /// that fails costs only the memory of the choice, never the choice.
  void _setDayView({DayView? view, GridSpan? span}) {
    setState(() {
      if (view != null) {
        _dayViewTouched = true;
        _dayView = view;
      }
      if (span != null) {
        _gridSpanTouched = true;
        _gridSpan = span;
      }
    });
    final key = view != null ? dayViewKey : dayGridSpanKey;
    final value = view?.name ?? span!.name;
    unawaited(() async {
      try {
        await ref.read(messageStoreProvider).setPref(key, value);
      } on Object catch (e) {
        debugPrint('the day view preference could not be saved: $e');
      }
    }());
  }

  /// Opens the invites owed on the Day stop. The day stays what it was, so
  /// the pane's back affordance returns to the day the reader left.
  void _openInvites() {
    setState(() {
      _clearOverlays();
      _section = RailSection.day;
      _showingInvites = true;
      _selectedId = null;
      _selectedSource = null;
      _selectedStorylineId = null;
      _selectedLaterDay = null;
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

  /// [_storylines] under the source pills. The rail, the overview and Find
  /// read this one; a selection, the pickers and the dismissed fold read the
  /// unfiltered list — a pill narrows what is browsed, never what is open or
  /// what a thread may be filed into.
  List<Storyline> _scopedStorylines() =>
      storylinesBySource(_storylines(), _sourceFilter);

  /// True while a re-check this owner asked for is still in the worker. The
  /// set rides on the read model because the panel is pure and the screen
  /// holds nothing per storyline.
  bool _storylineAuditing(String id) {
    final state = ref.watch(storylinesProvider);
    return state is StorylinesLoaded && state.auditing.contains(id);
  }

  /// The storylines the user said no to. Read from the same state as
  /// [_storylines] and never mixed into it: the rail folds these away under a
  /// heading of their own.
  List<Storyline> _dismissedStorylines() {
    final state = ref.watch(storylinesProvider);
    return state is StorylinesLoaded ? state.dismissed : const [];
  }

  /// The groups the model found and would not vouch for. A third list beside
  /// [_storylines] and [_dismissedStorylines], for the same reason those two
  /// are apart: the rail draws it under a heading of its own, and a possible
  /// storyline mixed into the live list would read as something the model is
  /// offering.
  List<Storyline> _possibleStorylines() {
    final state = ref.watch(storylinesProvider);
    return state is StorylinesLoaded ? state.possible : const [];
  }

  /// [_possibleStorylines] under the source pills, the way [_scopedStorylines]
  /// narrows the live list.
  List<Storyline> _scopedPossible() =>
      storylinesBySource(_possibleStorylines(), _sourceFilter);

  Storyline? _storylineById(String id) {
    for (final storyline in _storylines()) {
      if (storyline.id == id) return storyline;
    }
    // The possible list too, and unfiltered: the Possible fold's own rows open
    // from here, and a storyline nobody has vouched for is exactly the one a
    // reader wants to look inside before answering.
    for (final storyline in _possibleStorylines()) {
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
        // What the keys need to know about this layout — see
        // [_overviewCovered]. Written here, where the replace-or-split call is
        // made, so the two can never disagree.
        _overviewCovered = _sideFull || (beside != null && width == null);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _iconRail(conversations),
            _rail(conversations, rooms),
            const SizedBox(
              width: 1,
              child: ColoredBox(color: BondColors.border),
            ),
            // The list and the detail, under the triage keys — see
            // [_triageScope]. One `Expanded` around both of them rather than one
            // each: the pair has to sit ABOVE whatever has the cursor, and the
            // inner row divides the same space the two of them divided before.
            Expanded(
              child: _triageScope(
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Both cannot be had at this width, so the panel REPLACES
                    // the main pane rather than squeezing it — the same call the
                    // rail makes at its own breakpoint, and the one the thread
                    // pane's split made before this moved out here.
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
                ),
              ),
            ),
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
    // [_wide]'s write, for this width: any side panel has the whole pane
    // here, and so does a file opened full-pane.
    _overviewCovered = _side != null;
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
            // The triage keys sit over the pane and not over the hamburger
            // above it, for [_wide]'s reason.
            Expanded(
              child: _triageScope(
                (_side != null && !_sideFull)
                    ? _sidePanel(_side!)
                    : _main(conversations, rooms, loadError),
              ),
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

  /// [cleared] is how many rows the act took off the pile: one for every
  /// single-row act, N for a bulk act's one bar, and zero for an act that
  /// leaves its rows where they stand (a bulk Label).
  void _toast(String message, {VoidCallback? onUndo, int cleared = 1}) {
    if (!mounted) return;
    // The progress count (12g), fed where the act says what it did: an
    // undoable bar inside [_countingCleared]'s window is [cleared] rows gone,
    // and pressing its Undo is those rows back. Counting here and not in the
    // acts keeps a refused act — a toast with no undo on it — out of the count.
    final total = _pileAtSessionStart;
    if (_countingCleared && onUndo != null && total != null && cleared > 0) {
      setState(() => _clearedThisSession =
          (_clearedThisSession + cleared).clamp(0, total));
      final inner = onUndo;
      onUndo = () {
        if (mounted) {
          setState(() => _clearedThisSession =
              (_clearedThisSession - cleared).clamp(0, total));
        }
        inner();
      };
    }
    if (onUndo != null) {
      // The bar's Undo and `z` share one slot: the button empties it as it
      // runs, or pressing it and `z` a breath later would run the same undo
      // twice. Only its own slot — a newer act may hold it by the time an
      // old bar is pressed.
      final inner = onUndo;
      late final VoidCallback once;
      once = () {
        if (_lastUndo == once) _lastUndo = null;
        inner();
      };
      onUndo = once;
    }
    // Every correction in the app already says what it did through this one
    // call, which makes it the one place the keyboard's undo can be fed from:
    // the sender rules, the thread actions and anything added later populate the
    // slot by construction rather than by remembering to. See [_lastUndo].
    _lastUndo = onUndo;
    final messenger = ScaffoldMessenger.of(context);
    // The previous bar goes now rather than queueing: correcting three senders
    // in a row should leave the third one's undo reachable, not the first's.
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: _undoDuration,
        // Stated, because the framework's default is the opposite: a bar
        // with an action PERSISTS until it is pressed, so every undoable bar
        // sat over the rail until the reader hit Undo just to be rid of it.
        // The window is the undo's life; `z` reaches the same undo after the
        // bar has gone, from the slot above. Except an undoable bar under a
        // screen reader, which is who that default exists for: walking to the
        // Undo takes longer than the window, so there it stays until closed.
        // A bar with nothing to press times out for everybody.
        persist: onUndo != null && MediaQuery.accessibleNavigationOf(context),
        // And a way to be rid of it sooner that is not undoing the thing.
        showCloseIcon: true,
        action: onUndo == null
            ? null
            : SnackBarAction(label: 'Undo', onPressed: onUndo),
      ),
    );
  }

  static String _threads(int n) => n == 1 ? '1 thread' : '$n threads';

  /// The sender of the newest inbound message with an address, or null.
  static String? _newestInboundSender(List<Message> messages) =>
      _newestInboundMessage(messages)?.fromAddress;

  /// The newest inbound message that names its sender, or null: whoever spoke
  /// last is who the thread is "from" for a reader deciding what to do about
  /// it.
  static Message? _newestInboundMessage(List<Message> messages) {
    Message? newest;
    for (final message in messages) {
      if (message.outbound) continue;
      if (message.fromAddress?.isNotEmpty != true) continue;
      if (newest == null ||
          (message.receivedAt ?? '').compareTo(newest.receivedAt ?? '') >= 0) {
        newest = message;
      }
    }
    return newest;
  }

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

  /// The owner's own gate on a sender, offered beside Later in the same menu.
  ///
  /// [_laterSender]'s shape exactly, including the capture BEFORE the write:
  /// the undo puts the rule back to whatever it was, and "there was no rule"
  /// is a different state from "the rule was later". The toast says both
  /// halves of what just happened, because they are different halves — new
  /// mail is gated from now on, and the threads already here moved.
  Future<void> _dropSender(String address, String source) async {
    final notifier = ref.read(conversationsProvider.notifier);
    final previous = await notifier.senderPref(address);
    final affected = await notifier.dropSender(address, source: source);
    _toast(
      '$address is dropped — new mail from them is gated; '
      '${_threads(affected)} moved to Later.',
      onUndo: () =>
          notifier.restoreSenderPref(address, previous, source: source),
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

  /// Replays the undo the last bar offered, and empties the slot.
  ///
  /// The bar goes with it: an Undo still on screen after the undo has run is a
  /// button offering to do the same thing twice.
  void _undoLast() {
    final undo = _lastUndo;
    if (undo == null) return;
    _lastUndo = null;
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    undo();
  }

  // ── keyboard triage ────────────────────────────────────────────────────
  //
  // One `Shortcuts` + `Actions` pair over the list and the detail, and every
  // gesture in it named as an [Intent] in `triage_intents.dart` — so the keys
  // here, the buttons on a row and the command palette that comes later all run
  // the same code. The keys:
  //
  //   j / ↓    the row under this one          k / ↑    the row above
  //   e        dismiss, then advance           Shift+E  dismiss with a label
  //   l        label, keeping the thread       s        Later, per thread
  //   m        drop the sender                 z / ⌘Z   undo the last action
  //   x        tick the row for a bulk act     r        quick reply on the row
  //   ] / [    next / previous mention in the open thread
  //   ?        the cheat sheet, beside         Esc      back to the list
  //
  // While rows are ticked, e / Shift+E / l / s / m act on the SELECTION — the
  // bar says "3 selected", and a single-row act under it would contradict it.
  // j / k / r and the row's hover buttons stay about the one row.
  //
  // The sheet (`widgets/cheat_sheet_panel.dart`) is this list for the reader,
  // and `cheat_sheet_test` holds it against [triageKeys].
  //
  // Every single letter is INERT while the cursor is in something that takes
  // typing — see [_editingText]. Escape is the one binding that is not: coming
  // back out of the composer is exactly what a reader means by it.

  /// What each intent does, built once so the map's identity survives a rebuild.
  ///
  /// [FocusReplyIntent] is here with no key on it: `r` belongs to the in-list
  /// quick reply — [QuickReplyIntent] holds it now — and the thread's own
  /// controls invoke this through [Actions].
  late final Map<Type, Action<Intent>> _triageActions = {
    NextThreadIntent: _TriageAction<NextThreadIntent>(
      () => _moveSelection(forward: true),
      live: _keysLive,
    ),
    PreviousThreadIntent: _TriageAction<PreviousThreadIntent>(
      () => _moveSelection(forward: false),
      live: _keysLive,
    ),
    DismissThreadIntent: _TriageAction<DismissThreadIntent>(
      () => unawaited(_selectionActive
          ? _bulkDismiss()
          : _triageAndAdvance(_dismissThread)),
      live: _keysLive,
    ),
    DismissWithLabelIntent: _TriageAction<DismissWithLabelIntent>(
      () => _selectionActive
          ? _requestBulkPicker(dismissAfter: true)
          : _requestLabelPicker(dismissAfter: true),
      live: _keysLive,
    ),
    LabelThreadIntent: _TriageAction<LabelThreadIntent>(
      () => _selectionActive
          ? _requestBulkPicker(dismissAfter: false)
          : _requestLabelPicker(dismissAfter: false),
      live: _keysLive,
    ),
    LaterThreadIntent: _TriageAction<LaterThreadIntent>(
      () => unawaited(_selectionActive
          ? _bulkLater()
          : _triageAndAdvance(_laterThread)),
      live: _keysLive,
    ),
    DropSenderIntent: _TriageAction<DropSenderIntent>(
      () => unawaited(_selectionActive
          ? _bulkDropSenders()
          : _triageAndAdvance(_dropSenderForThread)),
      live: _keysLive,
    ),
    ToggleCheckedIntent: _TriageAction<ToggleCheckedIntent>(
      _toggleTargetChecked,
      live: _keysLive,
    ),
    QuickReplyIntent: _TriageAction<QuickReplyIntent>(
      _openQuickReply,
      live: _keysLive,
    ),
    UndoLastIntent: _TriageAction<UndoLastIntent>(
      _undoLast,
      live: _keysLive,
    ),
    ShowCheatSheetIntent: _TriageAction<ShowCheatSheetIntent>(
      _openCheatSheet,
      live: _keysLive,
    ),
    // The thread the reader is IN, which on Needs You is the one BESIDE the
    // list rather than in main — so the handles are picked at press time, not
    // torn off here. Either is a no-op with no thread open.
    NextMentionIntent: _TriageAction<NextMentionIntent>(
      () => _openThreadJumps.nextMention(),
      live: _keysLive,
    ),
    PreviousMentionIntent: _TriageAction<PreviousMentionIntent>(
      () => _openThreadJumps.previousMention(),
      live: _keysLive,
    ),
    FocusReplyIntent: _TriageAction<FocusReplyIntent>(
      () => _openThreadComposerFocus.requestFocus(),
      live: _keysLive,
    ),
    DismissIntent: _TriageAction<DismissIntent>(_returnFocusToList),
  };

  /// `?`: the sheet, beside. PUSHED, for once from outside the panel — the
  /// sheet is a look at the keys rather than a new subject, so whatever was
  /// beside is still what the reader is working on and the ✕ owes it back.
  ///
  /// The cursor goes into the panel so Escape closes it there (the panel's own
  /// binding); the letters still work, since the panel is inside the region.
  void _openCheatSheet() {
    _openBeside(const CheatSheetPanel(), push: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _side is CheatSheetPanel) _sidePanelFocus.requestFocus();
    });
  }

  /// The transcript the thread keys serve: the side one while a thread is open
  /// beside, since that is the thread on screen, else main's.
  ///
  /// The TOP of the side stack, not the topmost thread in it: the side panel
  /// mounts only its top, so a thread under a pushed panel (the cheat sheet, a
  /// file) has no transcript attached to [_sideJumps] and nothing to jump in.
  /// Main's is the honest fallback there — `]` then walks the thread that IS
  /// on screen, or does nothing when main shows none.
  TranscriptJumps get _openThreadJumps =>
      _threadBeside != null ? _sideJumps : _mainJumps;

  /// [_openThreadJumps]'s rule for the reply box.
  FocusNode get _openThreadComposerFocus =>
      _threadBeside != null ? _sideComposerFocus : _mainComposerFocus;

  /// The one `Shortcuts` + `Actions` pair, over the list and the detail and
  /// nothing else.
  ///
  /// Called from both layouts and mounted once either way: [_wide] and [_narrow]
  /// are the two arms of one `LayoutBuilder`. The region is deliberately
  /// narrower than the screen — the rail's stops, its Find box and the source
  /// chips are chrome, and a `j` typed into Find is a letter.
  Widget _triageScope(Widget child) => Shortcuts(
        shortcuts: triageKeys,
        child: Actions(
          actions: _triageActions,
          child: Focus(focusNode: _triageFocus, child: child),
        ),
      );

  /// Whether the single letters are live, which is exactly "the cursor is not in
  /// a box".
  bool _keysLive() => !_editingText;

  /// Whether the cursor is in something that takes typing.
  ///
  /// Read off the focus manager rather than off any flag of ours: the composer,
  /// the Find box, a recipient field and whatever a later round adds are all
  /// `EditableText` underneath, and asking the one question covers them all. A
  /// disabled action leaves the key event UNHANDLED, so the `e` that would have
  /// dismissed a thread lands in the box as a letter — which is what somebody
  /// typing means by it.
  static bool get _editingText {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return focused.widget is EditableText ||
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Hands the cursor back to the list, unless it is already somewhere inside
  /// the region — a composer being typed in is not something to interrupt.
  void _takeTriageFocus() {
    if (_triageFocus.hasFocus) return;
    _triageFocus.requestFocus();
  }

  /// [_takeTriageFocus] for the far side of an await, a frame later and only
  /// if the reader is not typing by then. A label write is normally instant,
  /// but by the time a slow one's toast lands the cursor may be in Find or a
  /// composer — boxes a toast is no reason to pull it out of mid-word. The
  /// frame's delay also lets the strip the press unmounted actually go, so
  /// the typing being asked about is the reader's, not the dead strip's.
  void _takeTriageFocusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_editingText) _takeTriageFocus();
    });
  }

  /// A palette pick (12h): the intent travels UP from the triage region's own
  /// focus, never from the Find field's — the `Actions` map lives inside
  /// [_triageScope], deliberately not over the rail, and an invoke from the
  /// field's context would find nothing above it.
  void _runCommand(Intent intent) {
    // The one palette row that is not a triage act: it leaves the list for
    // the Day stop, so it is answered here rather than by the list's map.
    if (intent is AskDayIntent) {
      _askDay(intent.text);
      return;
    }
    final ctx = _triageFocus.context;
    if (ctx != null) Actions.maybeInvoke(ctx, intent);
  }

  /// Escape, as a cascade: the open strip first — either picker or the quick
  /// reply — and only once none is open, the selection. The cursor comes back
  /// to the list either way.
  ///
  /// The selection clears only from the LIST: an Escape that brings the cursor
  /// out of a box is the reader leaving the box, not giving up the rows they
  /// ticked before they went into it.
  void _returnFocusToList() {
    final stripOpen = _labelPickerRequest != null ||
        _quickReplyFor != null ||
        _bulkPickerRequest != null;
    final fromList = !_editingText;
    _clearLabelPickerRequest();
    _clearQuickReply();
    _clearBulkPicker();
    if (!stripOpen && fromList && _checked.isNotEmpty) _clearChecked();
    _triageFocus.requestFocus();
  }

  /// The rows the list is drawing, in the order it draws them.
  ///
  /// One derivation for the pane and for the keys: auto-advance has to land on
  /// the row that is actually under the one just cleared, and a second reading
  /// of "the list" is how the two would come to disagree. [prefs] is passed
  /// rather than read, so the pane can watch it and a key press can read it.
  ///
  /// Off the Needs You stop it is the same pile without the tab's lens, which is
  /// what the rail draws.
  ///
  /// Every read also records [_lastPileIds] — when nothing at all is open, or
  /// when the open thread is in the list it just read. A read that no longer
  /// finds the open thread leaves the snapshot as it was, which is how a thread
  /// that left the pile while open still has a place to step from. "Nothing at
  /// all" is the side stack empty and nothing in the main pane, not merely no
  /// [_triageTarget]: a file or a Why panel pushed over a thread beside hides
  /// the thread from [_threadBeside] without closing it, and refreshing then
  /// would forget where that thread stood before Back brings it back. A bare field
  /// write, no setState: [_pileAtSessionStart]'s idiom, and nothing draws it.
  List<Conversation> _triageRows(AppPrefs prefs) {
    final ranked = sortNeedsYou(
      prefs.needsYouSort,
      needsYouRows(_rows, threshold: prefs.attentionThreshold),
    );
    final rows = _section == RailSection.needsYou
        ? needsYouLabelRows(
            _activeNeedsYouLabelId,
            needsYouTabRows(_needsYouTab, ranked),
          )
        : ranked;
    final target = _triageTarget;
    final nothingOpen = _side == null && _selectedId == null;
    if ((target == null && nothingOpen) ||
        (target != null &&
            rows.any(
              (c) => c.id == target.key && c.source == target.source,
            ))) {
      _lastPileIds = [for (final c in rows) (source: c.source, key: c.id)];
    }
    return rows;
  }

  /// The nearest row to [target]'s old place that is still drawn, walking
  /// [_lastPileIds] from where [target] stood — down the pile when [forward],
  /// up it otherwise. Null when [target] was never in the snapshot (a thread
  /// opened from Archive, Home or a room) or when nothing on that side of it
  /// is left in [rows].
  ({String source, String key})? _stepFromDeparted(
    ({String source, String key}) target,
    List<Conversation> rows, {
    required bool forward,
  }) {
    final at = _lastPileIds.indexOf(target);
    if (at < 0) return null;
    final drawn = {for (final c in rows) (source: c.source, key: c.id)};
    final step = forward ? 1 : -1;
    for (var i = at + step; i >= 0 && i < _lastPileIds.length; i += step) {
      if (drawn.contains(_lastPileIds[i])) return _lastPileIds[i];
    }
    return null;
  }

  /// Where the reader lands when [target] leaves [rows], and whether [target]
  /// counts as a row of this pile ([_countingCleared]).
  ///
  /// In the pile: [nextRowAfter] — the row under it, else the new last one.
  /// Already gone from it but remembered by [_lastPileIds] (a sent reply took
  /// it off while it was open): the same rule walked over the snapshot — the
  /// nearest drawn row below where it stood, else the nearest above — and it
  /// still counts, because it was a row of this pile a moment ago — even with
  /// no drawn row left on either side to land on, which is the last row of a
  /// pile cleared by a reply. Neither: no landing, and not counted.
  ({({String source, String key})? landing, bool inPile}) _landingFor(
    ({String source, String key}) target,
    List<Conversation> rows,
  ) {
    if (rows.any((c) => c.id == target.key && c.source == target.source)) {
      final nextId = nextRowAfter([for (final c in rows) c.id], target.key);
      for (final row in rows) {
        if (row.id != nextId) continue;
        return (landing: (source: row.source, key: row.id), inPile: true);
      }
      return (landing: null, inPile: true);
    }
    final departed = _stepFromDeparted(target, rows, forward: true) ??
        _stepFromDeparted(target, rows, forward: false);
    return (
      landing: departed,
      inPile: departed != null || _lastPileIds.contains(target),
    );
  }

  /// The thread the keys act on: whatever is open beside, else the main pane's
  /// selection. The list lights the same row, so this is the thread the reader
  /// is looking at either way.
  ({String source, String key})? get _triageTarget {
    final beside = _threadBeside;
    if (beside != null) {
      return (source: beside.source, key: beside.conversationKey);
    }
    final id = _selectedId;
    return id == null ? null : (source: _selectedSource ?? 'email', key: id);
  }

  /// Opens a row the way the surface it is on already opens rows: a thread in
  /// the main pane is replaced there, and a list the reader is working through
  /// keeps its place and opens beside.
  void _selectTriageRow(String source, String key) {
    if (_selectedId != null) {
      _select(key, source: source);
    } else {
      _openThreadBeside(source, key);
    }
    _takeTriageFocus();
  }

  void _moveSelection({required bool forward}) {
    final rows = _triageRows(ref.read(appPrefsProvider));
    final target = _triageTarget;
    // A thread that is open but not drawn steps from where it STOOD, if it
    // stood here at all — a sent reply takes a thread off the pile while the
    // reader is still on it, and the next row is still the next row. One
    // opened from another stop — Archive, Home, a room — was never in this
    // pile, and stepping "next" from it would teleport the reader to the top
    // Needs You row, so it goes nowhere. No target at all still starts at the
    // top: that is a reader on the pile who has not picked a row yet.
    if (target != null &&
        !rows.any((c) => c.id == target.key && c.source == target.source)) {
      final step = _stepFromDeparted(target, rows, forward: forward);
      if (step != null) _selectTriageRow(step.source, step.key);
      return;
    }
    final next = neighbourRow(
      [for (final c in rows) c.id],
      target?.key,
      forward: forward,
    );
    // Null is the edge of the list, where the reader stays put: wrapping around
    // would hand them the thread they started at and call it progress.
    if (next == null) return;
    for (final row in rows) {
      if (row.id != next) continue;
      _selectTriageRow(row.source, row.id);
      return;
    }
  }

  /// Every destructive key, and every button that does the same thing: work out
  /// where the reader lands BEFORE the list moves, do the thing, then land them.
  ///
  /// Computed first because the row is about to leave the drawn list and take
  /// its place with it. Landing nowhere means there is nothing left to stand on,
  /// and then the thread the reader just cleared is closed rather than left in
  /// front of them.
  ///
  /// [on] is how a control NAMES its thread. The keys leave it null and get
  /// [_triageTarget], but a button drawn on a panel belongs to the conversation
  /// that panel is showing — and a thread in the main pane with another one open
  /// beside it would otherwise act on the one beside.
  ///
  /// The landing is [_landingFor]'s: a thread that already left the pile while
  /// open (a sent reply) lands from where it stood, and one cleared from
  /// another stop has no landing at all — advancing would put the reader on
  /// the top Needs You row, a teleport nobody asked for.
  ///
  /// One act at a time ([_triaging]): a key or button press while one is
  /// running is dropped, and a caller whose own surface has already gone
  /// passes [queue] to wait its turn instead — see [_triaging]. A queued act
  /// reads its target, the pile and its landing AFTER the wait, from the list
  /// as the act before it left it.
  ///
  /// And the landing yields to the reader: if the thread in front of them
  /// changed while the act's write was out — they clicked another row — that
  /// choice stands, and neither the landing nor the close runs over it.
  ///
  /// [act] answers whether its write landed. False means the thread is still
  /// where it was: the act has already said so in a bar with no Undo (which
  /// [_toast] does not count), and the reader stays on the thread with the
  /// cursor handed back, since moving them on would claim it was cleared.
  Future<void> _triageAndAdvance(
    Future<bool> Function(({String source, String key}) target) act, {
    ({String source, String key})? on,
    bool queue = false,
  }) async {
    if (_triaging) {
      if (!queue) return;
      // A loop, not one await: every waiter wakes on the same completion and
      // only the first to run takes the latch; the rest wait on the next act.
      while (_triaging) {
        await _triageIdle!.future;
      }
      if (!mounted) return;
    }
    _triaging = true;
    final idle = _triageIdle = Completer<void>();
    try {
      final target = on ?? _triageTarget;
      if (target == null) return;
      final before = _triageTarget;
      final rows = _triageRows(ref.read(appPrefsProvider));
      final (:landing, :inPile) = _landingFor(target, rows);

      // The window [_toast] counts in — see [_countingCleared]. Spanning the
      // act's own awaits is the point (its toast fires inside them); the cost
      // is that an unrelated bar landing in those few frames would be counted,
      // which the clamp bounds and a progress line can afford.
      _countingCleared = inPile;
      final bool landed;
      try {
        landed = await act(target);
      } finally {
        _countingCleared = false;
      }
      if (!mounted) return;
      // The reader moved while the write was out: where they went wins. And
      // a write that failed moves nobody — see [act] above.
      if (!landed || _triageTarget != before) {
        _takeTriageFocus();
        return;
      }
      if (landing != null) {
        _selectTriageRow(landing.source, landing.key);
        return;
      }
      final beside = _threadBeside;
      if (beside != null &&
          beside.source == target.source &&
          beside.conversationKey == target.key) {
        _closeSide();
      } else if (_selectedId == target.key) {
        setState(() {
          _clearOverlays();
          _selectedId = null;
          _selectedSource = null;
        });
      }
      _takeTriageFocus();
    } finally {
      _triaging = false;
      idle.complete();
    }
  }

  /// Dismiss: `done`, said in a bar with the way back on it.
  ///
  /// [ConversationsNotifier.reopenThread] is the undo rather than a stored
  /// previous state, because that is what the Reopen button already is — see its
  /// doc for why the state it lands in is re-derived.
  ///
  /// A null [MarkDoneUndo] is a write that failed and a row already put back,
  /// so the bar says that instead, with no Undo: an Undo over nothing would
  /// run [ConversationsNotifier.reopenThread], which re-derives a state and
  /// can move a thread the reader never touched.
  Future<bool> _dismissThread(({String source, String key}) target) async {
    final notifier = ref.read(conversationsProvider.notifier);
    final done = await _dismissOne(target);
    if (!mounted) return done != null;
    if (done == null) {
      _toast(_markDoneFailed);
      return false;
    }
    _toast(
      'Marked done.',
      onUndo: () => notifier.reopenThread(target.source, target.key),
    );
    return true;
  }

  /// The bar's sentence for a single Mark done whose write failed. One
  /// wording for the key, the button and the label path, in the house's
  /// "Couldn't … just now." form.
  static const String _markDoneFailed = "Couldn't mark that thread done just now.";

  /// [_dismissThread]'s do-step, with no bar: the [MarkDoneUndo] the store
  /// handed back, or null for a row whose write failed. A bulk dismiss undoes
  /// through this record rather than [ConversationsNotifier.reopenThread],
  /// because twelve rows put back must land exactly where each one stood —
  /// waiting or needs-reply — and a re-derived state is a guess per row.
  Future<MarkDoneUndo?> _dismissOne(
    ({String source, String key}) target, {
    List<String> labelIds = const [],
  }) =>
      ref
          .read(conversationsProvider.notifier)
          .markDone(target.source, target.key, labelIds: labelIds);

  /// [_snoozeThread] without a day named: the per-thread deferral takes the date
  /// the thread's own newest inbound message asked for, else seven days out.
  /// [ConversationsNotifier.keepThreadInInbox] is the undo, which is exactly
  /// what [_keepThread] offers in the other direction.
  ///
  /// Always answers true: [ConversationsNotifier.sendThreadToLater] throws on
  /// a failed write rather than returning a sentinel, so a failure never
  /// reaches the bar here.
  Future<bool> _laterThread(({String source, String key}) target) async {
    final undo = await _laterOne(target);
    _toast('Sent to Later.', onUndo: () => unawaited(undo()));
    return true;
  }

  /// [_laterThread]'s do-step: defers the thread and hands back its way out,
  /// with no bar — [_bulkLater] raises one bar for all of them.
  Future<Future<void> Function()> _laterOne(
    ({String source, String key}) target,
  ) async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.sendThreadToLater(target.source, target.key);
    return () => notifier.keepThreadInInbox(target.source, target.key);
  }

  /// `m`, on the address the thread panel's own menu item would key a rule on:
  /// whoever sent the newest inbound message where the transcript is loaded,
  /// else the row's own participant. [_dropSender] carries the toast and the
  /// undo that restores whatever rule was there before.
  ///
  /// Answers true, the no-sender case included, for [_laterThread]'s reason:
  /// [ConversationsNotifier.dropSender] throws rather than returning a
  /// sentinel.
  Future<bool> _dropSenderForThread(({String source, String key}) target) async {
    final thread = ref.read(threadProvider(
      (source: target.source, conversationKey: target.key),
    ));
    final messages =
        thread is ThreadLoaded ? thread.messages : const <Message>[];
    final address = _newestInboundSender(messages) ??
        _loadedRow(target)?.primaryEmail;
    if (address == null || address.isEmpty) {
      _toast('No sender on that thread to make a rule about.');
      return true;
    }
    await _dropSender(address, target.source);
    return true;
  }

  /// One loaded conversation by target, or null if the list does not hold it.
  ///
  /// [_conversationFor] answers the same question by `ref.watch`, which is for
  /// build; a key handler reads.
  Conversation? _loadedRow(({String source, String key}) target) {
    final loaded = ref.read(conversationsProvider);
    if (loaded is! ConversationsLoaded) return null;
    for (final c in loaded.conversations) {
      if (c.id == target.key && c.source == target.source) return c;
    }
    return null;
  }

  /// `l` and `Shift+E`, and every Label… button: the reader has asked for the
  /// picker on this thread.
  ///
  /// The request and not the picker — see [_labelPickerRequest]. The two picker
  /// mounts (the thread panel's strip, the list row's) read the request and
  /// answer it; [on] is how a control drawn on a row names that row, the same
  /// contract [_triageAndAdvance] keeps, and the keys leave it null for
  /// [_triageTarget].
  void _requestLabelPicker({
    required bool dismissAfter,
    ({String source, String key})? on,
  }) {
    final target = on ?? _triageTarget;
    if (target == null) return;
    // Re-read on every open: an apply moves `use_count`, which is the order
    // the chips are offered in, and the read is one indexed table.
    unawaited(ref.read(labelsProvider.notifier).load());
    setState(() {
      // The other strips' half of the one-strip rule — see [_quickReplyFor].
      _quickReplyFor = null;
      _bulkPickerRequest = null;
      _labelPickerRequest = (
        source: target.source,
        key: target.key,
        dismissAfter: dismissAfter,
      );
    });
  }

  /// A label picked from the open picker, applied to the thread the request
  /// names.
  ///
  /// Two different actions behind one chip, told apart by [dismissAfter]:
  /// `Shift+E`'s picker dismisses WITH the label — one [markDone], whose
  /// [MarkDoneUndo] takes back the state change and the links it created in one
  /// step, riding [_triageAndAdvance] so the label path gets the same landing
  /// and the same `z` as `e` — while `l`'s picker files the thread where it
  /// stands (keep with a label), and its undo is taking the chip back off.
  ///
  /// [dismissAfter] is passed, never read off the request here: every caller
  /// reads the request's flag SYNCHRONOUSLY at the tap or the Enter, and
  /// [_createAndApplyLabel] reaches this only after a create's await, by which
  /// time the request is long closed — reading it then turned "mark done with
  /// a label" into "keep with a label" whenever anything touched the request
  /// mid-write.
  ///
  /// It closes the picker only when the open request is still about [target]:
  /// a create that lands after the reader pressed `l` on another thread must
  /// not shut the picker they just opened there. The dismiss is queued behind
  /// any act still running ([_triaging]), since the chip or the Enter that
  /// asked for it has already gone from the screen.
  Future<void> _applyPickedLabel(
    ({String source, String key}) target,
    Label label, {
    required bool dismissAfter,
  }) async {
    _clearLabelPickerRequestFor(target);
    if (dismissAfter) {
      await _triageAndAdvance(
        (t) async {
          final notifier = ref.read(conversationsProvider.notifier);
          final undo =
              await notifier.markDone(t.source, t.key, labelIds: [label.id]);
          if (!mounted) return undo != null;
          // Worded from the result, never from what was asked: a failed
          // state write is not done, and a failed label write is done
          // without the word. The second still clears the thread, so its
          // bar keeps the Undo that reopens it.
          if (undo == null) {
            _toast(_markDoneFailed);
            return false;
          }
          _toast(
            undo.labelWriteFailed
                ? "Marked done. Couldn't add ${label.name} just now."
                : 'Marked done · ${label.name}.',
            onUndo: () => unawaited(notifier.undoMarkDone(undo)),
          );
          return true;
        },
        on: target,
        queue: true,
      );
      return;
    }
    // Already on the thread — a ✓ chip, or a typed name that resolved to one.
    // Applying it would change nothing, and the bar's Undo would then take
    // off a label the owner put there BEFORE this press: the one undo in the
    // app that would destroy something it never did.
    final List<Label> existing;
    try {
      existing = await ref
          .read(messageStoreProvider)
          .labelsForConversation(target.source, target.key);
    } catch (e) {
      // Unread is not "not there": applying blind is exactly what could hand
      // the bar an Undo over a label it never put on.
      debugPrint('reading the thread\'s labels failed: $e');
      if (!mounted) return;
      _toast("Couldn't file that thread just now.");
      _takeTriageFocusSoon();
      return;
    }
    if (!mounted) return;
    if (existing.any((l) => l.id == label.id)) {
      _toast('Already labeled ${label.name}.');
      _takeTriageFocusSoon();
      return;
    }
    final labels = ref.read(labelsProvider.notifier);
    final applied = await labels.apply(target.source, target.key, [label.id]);
    if (!mounted) return;
    if (!applied) {
      _toast(ref.read(labelsProvider).error ??
          "Couldn't file that thread just now.");
      _takeTriageFocusSoon();
      return;
    }
    _toast(
      'Labeled ${label.name}.',
      onUndo: () => _labelUndo(
        () async =>
            await labels.remove(target.source, target.key, label.id) != null,
        "Couldn't take that label off just now.",
      ),
    );
    // The strip the cursor was in has just unmounted, and nothing advanced to
    // take focus in its place: hand it back, or `z` on the toast this very
    // action raised would land nowhere.
    if (mounted) _takeTriageFocusSoon();
  }

  /// The chip's ✕: one label off one thread, with the way back on the bar —
  /// [_applyPickedLabel]'s toast, said the other way round.
  Future<void> _removeLabel(
    ({String source, String key}) target,
    Label label,
  ) async {
    final labels = ref.read(labelsProvider.notifier);
    final removal = await labels.remove(target.source, target.key, label.id);
    if (!mounted) return;
    if (removal == null) {
      _toast(ref.read(labelsProvider).error ??
          "Couldn't take that label off just now.");
      return;
    }
    // A chip that was already gone removed nothing, and says nothing. This is
    // the second press of a double-click on ✕, landing while the first
    // removal's reload is still out: a bar here would replace the first
    // press's bar and take its Undo and `z` with it, the only way back for a
    // label that really did come off.
    if (!removal.removed) return;
    _toast(
      'Removed ${label.name}.',
      onUndo: () => _labelUndo(
        () => labels.restore(target.source, target.key, label.id),
        "Couldn't put that label back just now.",
      ),
    );
  }

  /// A label toast's Undo, loud when it fails. The provider keeps the
  /// sentence in [LabelsState.error], which only an open picker draws, so an
  /// Undo — or its `z` — that failed behind a shut one would say nothing.
  void _labelUndo(Future<bool> Function() write, String failed) {
    unawaited(() async {
      if (await write() || !mounted) return;
      _toast(ref.read(labelsProvider).error ?? failed);
    }());
  }

  /// The chip's name: the rail's live lists narrowed to that label, in the
  /// Find field — the box that already reads `label:`, filter-only, which the
  /// semantic search over the inbox does not. LIVE lists only: Find narrows
  /// Needs You and the rooms, so a thread closed under the label is on the
  /// Done shelf rather than here, and the chip's tooltip says "Filter Needs
  /// You" to match. The facet is written by [completeLabelFacet], so a name
  /// with a space in it comes back quoted exactly as the box's own completion
  /// would quote it.
  ///
  /// The section moves with it by [sectionForLabelFind] — deliberately none
  /// of [_selectSection]'s resets: the thread being read stays open, and so
  /// does a room or storyline it was opened beside, which outranks the
  /// section in the main pane. Back out of that room then lands
  /// on People with the `label:` still in Find, which a room cannot match —
  /// the facet is the reader's to clear, as any needle is. The needle itself
  /// is [withLabelFacet]'s: added to what the reader typed, never over it.
  void _findLabel(Label label) {
    final text = withLabelFacet(_find, label.name);
    _findText.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      _find = text;
      _section = sectionForLabelFind(_section);
      _findTimeFor = null;
      _selectedDay = null;
      _showingInvites = false;
      if (_section != RailSection.day) _forgetCommand();
    });
    _focusFind(selectAll: false);
  }

  /// Enter on a name no chip carries: the vocabulary grows by one word and the
  /// word goes straight onto the thread — creating without applying would make
  /// the reader say the same thing twice.
  ///
  /// A create the store refused answers null and nothing is dismissed on the
  /// strength of a label that was never made. The picker is closed by then, so
  /// the toast says why — the provider's sentence where it kept one — and the
  /// cursor goes back to the list, since the strip it was in has unmounted and
  /// the keys would otherwise be dead until the reader clicked something.
  ///
  /// The request's mode is read and the request CLOSED before the create's
  /// await, not after it: the picker the reader typed into must not stay open
  /// and live across the write, where a second Enter would apply its top chip
  /// and an Escape or `l` would rewrite the mode this Enter was pressed in.
  /// The future is handed back to the picker, which holds itself busy until it
  /// settles, and the list takes the cursor a frame later — the strip it was in
  /// has gone, and the keys stay live while the write is out.
  Future<void> _createAndApplyLabel(
    ({String source, String key}) target,
    String name,
  ) async {
    final dismissAfter = _labelPickerRequest?.dismissAfter ?? false;
    _clearLabelPickerRequest();
    // The strip the cursor was in goes on the next frame; the list takes the
    // cursor then, not when the write lands, so the keys are live meanwhile.
    _takeTriageFocusSoon();
    final label = await ref.read(labelsProvider.notifier).create(name);
    if (!mounted) return;
    if (label == null) {
      // The provider kept the sentence; the bar is where this screen says
      // such things. A field that just sits there reads as a dead Enter key.
      _toast(ref.read(labelsProvider).error ??
          "Couldn't save that label just now.");
      _takeTriageFocusSoon();
      return;
    }
    await _applyPickedLabel(target, label, dismissAfter: dismissAfter);
  }

  /// The dismiss-mode picker's way out with nothing on it: entry 1c says
  /// dismissing without a tag is allowed, so this is `e` with the picker's
  /// politeness — same dismiss, same undo, same landing. Queued behind a
  /// running act rather than dropped, for [_applyPickedLabel]'s reason: the
  /// button that asked has already gone.
  Future<void> _dismissWithoutLabel(({String source, String key}) target) {
    _clearLabelPickerRequest();
    return _triageAndAdvance(_dismissThread, on: target, queue: true);
  }

  void _clearLabelPickerRequest() {
    if (_labelPickerRequest == null) return;
    setState(() => _labelPickerRequest = null);
  }

  /// [_clearLabelPickerRequest], only when the open request names [target] —
  /// a late apply closing a picker the reader has since opened on another
  /// thread would close something they did not finish with.
  void _clearLabelPickerRequestFor(({String source, String key}) target) {
    final request = _labelPickerRequest;
    if (request == null ||
        request.source != target.source ||
        request.key != target.key) {
      return;
    }
    _clearLabelPickerRequest();
  }

  /// `r`: the in-list quick reply on the thread the keys act on. Takes the
  /// picker's place when one is open — see [_quickReplyFor]'s one-strip rule.
  ///
  /// Only where the box can actually draw: the Needs You overview's pane is
  /// the one surface handed [_quickReplyFor]. Anywhere else the press would
  /// close an open picker and park a request that pops a box the next time
  /// the reader lands on the overview with that row in it.
  void _openQuickReply() {
    if (_section != RailSection.needsYou) return;
    final target = _triageTarget;
    if (target == null) return;
    setState(() {
      _labelPickerRequest = null;
      _bulkPickerRequest = null;
      _quickReplyFor = target;
    });
  }

  void _clearQuickReply() {
    if (_quickReplyFor == null) return;
    setState(() => _quickReplyFor = null);
  }

  /// The in-list box's send: the same [_send] every reply takes, with the
  /// box's own closing rule — it stays up on a failure, where its error line
  /// is, and on a notice, which has nowhere else to be said; it goes away with
  /// anything else, because anything else means the words left the box.
  Future<void> _sendQuickReply(
    ({String source, String key}) target,
    String body,
  ) async {
    final draftTarget = (
      source: target.source,
      conversationKey: target.key,
    );
    await _send(draftTarget, body);
    if (!mounted) return;
    final after = ref.read(draftProvider(draftTarget));
    if (after.error == null && after.notice == null) {
      _clearQuickReply();
    }
  }

  /// The mode a mount should draw the picker in for one thread, or null when
  /// the open request is not about that thread. One reading of the request for
  /// both mounts, so the panel and the list row cannot disagree about whose
  /// picker is open.
  LabelPickerMode? _pickerModeFor(String source, String key) {
    final request = _labelPickerRequest;
    if (request == null || request.source != source || request.key != key) {
      return null;
    }
    return request.dismissAfter ? LabelPickerMode.dismiss : LabelPickerMode.label;
  }

  // ── bulk triage (12c) ──────────────────────────────────────────────────
  //
  // A selection over the drawn Needs You pile, the bar that acts on it, and
  // select-similar. Every bulk act runs its rows ONE AT A TIME — `markDone`
  // flips the list optimistically, and parallel flips would each build on a
  // snapshot the others had already moved — and raises ONE bar whose Undo
  // takes back every row it touched and puts the selection back.

  /// The ticked rows the list is actually drawing, in the order it draws them.
  /// The bar's count and every bulk act read this and never [_checked] bare,
  /// so a row a sync took away meanwhile can never reach an act.
  List<Conversation> _liveChecked(List<Conversation> rows) => [
        for (final c in rows)
          if (_checked.contains((source: c.source, key: c.id))) c,
      ];

  /// Whether the keys should act on the selection instead of on one row:
  /// something is ticked AND drawn, on the one stop that draws boxes, AND that
  /// overview is actually on screen. Two things can hide it. A thread opened
  /// in the main pane from the rail column, Settings, the composer or the
  /// activity log takes the main pane ([_highlightedSection]). And a side
  /// panel can take the whole pane: below the two-pane split (a window under
  /// 1293px), at the narrow width, or as a full-pane file
  /// ([_overviewCovered]). Either way `e` means the thing in front of the
  /// reader, never rows they cannot see. Only a thread open BESIDE the
  /// overview, with room for both, leaves the selection live. The ticks
  /// themselves are kept either way: the reader can open a thread, look, and
  /// come back to the selection they made.
  bool get _selectionActive =>
      _highlightedSection == RailSection.needsYou &&
      !_overviewCovered &&
      _liveChecked(_triageRows(ref.read(appPrefsProvider))).isNotEmpty;

  /// A box pressed, or a card Shift-clicked. A range ticks everything between
  /// the anchor and [c] in drawn order and leaves the anchor where it was; a
  /// plain press flips one row and moves the anchor to it. A range with no
  /// anchor drawn is a plain press — there is nowhere for it to start.
  void _toggleChecked(Conversation c, {required bool range}) {
    final rows = _triageRows(ref.read(appPrefsProvider));
    final id = (source: c.source, key: c.id);
    setState(() {
      final anchor = _checkAnchor;
      if (range && anchor != null) {
        final from = rows.indexWhere(
            (r) => r.source == anchor.source && r.id == anchor.key);
        final to = rows.indexWhere((r) => r.source == c.source && r.id == c.id);
        if (from >= 0 && to >= 0) {
          final lo = from < to ? from : to;
          final hi = from < to ? to : from;
          for (var i = lo; i <= hi; i++) {
            _checked.add((source: rows[i].source, key: rows[i].id));
          }
          return;
        }
      }
      if (!_checked.remove(id)) _checked.add(id);
      _checkAnchor = id;
    });
    _takeTriageFocus();
  }

  /// `x`: [_toggleChecked] on the row the keys act on, if it is in the pile —
  /// a thread open from another stop has no box to tick, and neither does a
  /// thread whose panel covers the overview ([_overviewCovered]): a tick the
  /// reader cannot see is one the next `e` would act on behind their back.
  void _toggleTargetChecked() {
    if (_section != RailSection.needsYou) return;
    if (_overviewCovered) return;
    final target = _triageTarget;
    if (target == null) return;
    for (final c in _triageRows(ref.read(appPrefsProvider))) {
      if (c.source == target.source && c.id == target.key) {
        _toggleChecked(c, range: false);
        return;
      }
    }
  }

  void _clearChecked() {
    setState(() {
      _checked.clear();
      _checkAnchor = null;
      _bulkPickerRequest = null;
    });
  }

  /// Everything a bulk act must put back on Undo besides the rows themselves.
  _Selection _captureSelection() =>
      (checked: {..._checked}, anchor: _checkAnchor);

  void _restoreSelection(
    _Selection captured,
  ) {
    if (!mounted) return;
    setState(() {
      _checked
        ..clear()
        ..addAll(captured.checked);
      _checkAnchor = captured.anchor;
    });
  }

  /// Where the reader lands after the ticked rows leave, worked out BEFORE
  /// they do — [_triageAndAdvance]'s rule, for many rows. Only when the thread
  /// beside is one of them: a reader reading an unticked thread stays on it.
  /// The first unticked row after the last ticked one, else the nearest
  /// unticked row above; null when nothing unticked is left.
  ({({String source, String key})? landing, bool besideLeaves}) _bulkLanding(
    List<Conversation> rows,
    List<Conversation> picked,
  ) {
    final beside = _threadBeside;
    final besideLeaves = beside != null &&
        picked.any(
            (c) => c.source == beside.source && c.id == beside.conversationKey);
    if (!besideLeaves) return (landing: null, besideLeaves: false);
    bool ticked(Conversation c) =>
        picked.any((p) => p.source == c.source && p.id == c.id);
    final last = rows.lastIndexWhere(ticked);
    for (var i = last + 1; i < rows.length; i++) {
      if (!ticked(rows[i])) {
        return (
          landing: (source: rows[i].source, key: rows[i].id),
          besideLeaves: true,
        );
      }
    }
    for (var i = last - 1; i >= 0; i--) {
      if (!ticked(rows[i])) {
        return (
          landing: (source: rows[i].source, key: rows[i].id),
          besideLeaves: true,
        );
      }
    }
    return (landing: null, besideLeaves: true);
  }

  /// The landing half of a bulk act, after its rows have gone.
  void _landAfterBulk(
    ({({String source, String key})? landing, bool besideLeaves}) plan,
  ) {
    if (!mounted) return;
    final landing = plan.landing;
    if (landing != null) {
      _selectTriageRow(landing.source, landing.key);
      return;
    }
    if (plan.besideLeaves) _closeSide();
    _takeTriageFocus();
  }

  /// The one runner behind Dismiss, Later and Dismiss-with-a-label on the
  /// selection: rows serially through [one], each handing back its own undo or
  /// null for a row it could not change (skipped, and not counted), then ONE
  /// bar saying how many, whose Undo replays every row's undo in reverse and
  /// puts the selection back. The selection clears before the first row moves:
  /// the rows it names are leaving.
  Future<void> _bulkAct(
    Future<Future<void> Function()?> Function(({String source, String key}) t)
        one, {
    required String Function(int n) words,
  }) async {
    final rows = _triageRows(ref.read(appPrefsProvider));
    final picked = _liveChecked(rows);
    if (picked.isEmpty) return;
    final captured = _captureSelection();
    final plan = _bulkLanding(rows, picked);
    _clearChecked();
    final undos = <Future<void> Function()>[];
    for (final c in picked) {
      final undo = await one((source: c.source, key: c.id));
      if (undo != null) undos.add(undo);
    }
    if (!mounted) return;
    final failed = picked.length - undos.length;
    if (undos.isEmpty) {
      _toast("Couldn't change those threads just now.");
      _restoreSelection(captured);
      return;
    }
    final n = undos.length;
    final tail = failed == 0 ? '' : ' $failed could not be changed.';
    _countingCleared = true;
    try {
      _toast(
        '${words(n)}$tail',
        cleared: n,
        onUndo: () {
          unawaited(() async {
            for (final undo in undos.reversed) {
              await undo();
            }
          }());
          _restoreSelection(captured);
        },
      );
    } finally {
      _countingCleared = false;
    }
    _landAfterBulk(plan);
  }

  Future<void> _bulkDismiss({Label? label}) {
    final notifier = ref.read(conversationsProvider.notifier);
    // Rows that went to done without the word: [markDone] keeps the flip when
    // only the label write fails, so the bar must not claim the label on
    // them. Counted here and said in the sentence rather than left to the
    // provider's banner.
    var unlabelled = 0;
    return _bulkAct(
      (t) async {
        final undo = await _dismissOne(
          t,
          labelIds: label == null ? const [] : [label.id],
        );
        if (undo?.labelWriteFailed ?? false) unlabelled++;
        return undo == null ? null : () => notifier.undoMarkDone(undo);
      },
      words: (n) => label == null
          ? 'Marked done: ${_threads(n)}.'
          : unlabelled == 0
          ? 'Marked done: ${_threads(n)} · ${label.name}.'
          : 'Marked done: ${_threads(n)}. '
                "Couldn't add ${label.name} to $unlabelled.",
    );
  }

  Future<void> _bulkLater() => _bulkAct(
        _laterOne,
        words: (n) => 'Sent ${_threads(n)} to Later.',
      );

  /// Drop senders on the selection: each DISTINCT sender once — twelve rows
  /// from one mailbox is one rule, not twelve writes of it — keyed on the
  /// address select-similar's sender scope reads. Each sender's prior rule is
  /// captured before its write and the Undo restores them in reverse, the
  /// single-row [_dropSender]'s contract per address. [_toast]'s count is the
  /// ticked rows that actually LEFT the pile, read after the writes: a row
  /// whose newest inbound sender differs from its participant may stay.
  Future<void> _bulkDropSenders() async {
    final notifier = ref.read(conversationsProvider.notifier);
    final prefs = ref.read(appPrefsProvider);
    final rows = _triageRows(prefs);
    final picked = _liveChecked(rows);
    if (picked.isEmpty) return;
    final senders = <String, String>{};
    var noSender = 0;
    for (final c in picked) {
      final address = similarValueOf(c, SimilarScope.sender);
      if (address == null) {
        noSender++;
        continue;
      }
      senders.putIfAbsent(address, () => c.source);
    }
    if (senders.isEmpty) {
      _toast('No sender on those threads to make a rule about.');
      return;
    }
    final captured = _captureSelection();
    final plan = _bulkLanding(rows, picked);
    _clearChecked();
    final restores = <Future<void> Function()>[];
    var moved = 0;
    for (final MapEntry(key: address, value: source) in senders.entries) {
      final previous = await notifier.senderPref(address);
      moved += await notifier.dropSender(address, source: source);
      restores.add(
        () => notifier.restoreSenderPref(address, previous, source: source),
      );
    }
    if (!mounted) return;
    final loaded = ref.read(conversationsProvider);
    final still = loaded is ConversationsLoaded
        ? {
            for (final c in needsYouRows(
              loaded.conversations,
              threshold: prefs.attentionThreshold,
            ))
              (source: c.source, key: c.id),
          }
        : const <({String source, String key})>{};
    final left = picked
        .where((c) => !still.contains((source: c.source, key: c.id)))
        .length;
    final who = senders.length == 1 ? '1 sender' : '${senders.length} senders';
    final tail = noSender == 0 ? '' : ' $noSender had no sender.';
    _countingCleared = true;
    try {
      _toast(
        '$who dropped — ${_threads(moved)} moved to Later.$tail',
        cleared: left,
        onUndo: () {
          unawaited(() async {
            for (final restore in restores.reversed) {
              await restore();
            }
          }());
          _restoreSelection(captured);
        },
      );
    } finally {
      _countingCleared = false;
    }
    _landAfterBulk(plan);
  }

  /// The bar's Label…, `l` and `Shift+E` with rows ticked: the picker under
  /// the bar, one strip at a time — see [_bulkPickerRequest].
  void _requestBulkPicker({required bool dismissAfter}) {
    unawaited(ref.read(labelsProvider.notifier).load());
    setState(() {
      _labelPickerRequest = null;
      _quickReplyFor = null;
      _bulkPickerRequest = (dismissAfter: dismissAfter);
    });
  }

  void _clearBulkPicker() {
    if (_bulkPickerRequest == null) return;
    setState(() => _bulkPickerRequest = null);
  }

  /// A label chosen in the bar's picker. Dismiss mode is [_bulkDismiss] with
  /// the label on every row (one [markDone] each, so each row's undo takes back
  /// its own links). Label mode files the rows where they stand, touches only
  /// the rows not already carrying the word — so Undo takes off only what this
  /// press put on — and KEEPS the selection: the reader is still holding those
  /// rows, and may well dismiss them next.
  ///
  /// [dismissAfter] is passed, read by the caller at the tap or the Enter —
  /// [_applyPickedLabel]'s rule, for the bar's picker.
  Future<void> _applyBulkLabel(
    Label label, {
    required bool dismissAfter,
  }) async {
    _clearBulkPicker();
    if (dismissAfter) {
      await _bulkDismiss(label: label);
      return;
    }
    final picked = _liveChecked(_triageRows(ref.read(appPrefsProvider)));
    if (picked.isEmpty) return;
    final labels = ref.read(labelsProvider.notifier);
    final filed = <({String source, String key})>[];
    // Counted, so the toast says what happened rather than what was asked,
    // and the Undo holds only the links that actually went on.
    var failed = 0;
    for (final c in picked) {
      if (c.labels.any((l) => l.id == label.id)) continue;
      if (await labels.apply(c.source, c.id, [label.id])) {
        filed.add((source: c.source, key: c.id));
      } else {
        failed++;
      }
    }
    if (!mounted) return;
    // "Labeled" counts every row that now wears the word, the ones that
    // already did included — that is the state the reader asked for. With
    // nothing wearing it, the sentence is the failure alone.
    final wearing = picked.length - failed;
    _toast(
      failed == 0
          ? 'Labeled ${_threads(picked.length)} ${label.name}.'
          : wearing == 0
          ? "Couldn't label ${_threads(failed)} ${label.name} just now."
          : 'Labeled ${_threads(wearing)} ${label.name}. '
                '$failed could not be changed.',
      cleared: 0,
      onUndo: filed.isEmpty
          ? null
          : () => _labelUndo(() async {
              var ok = true;
              for (final t in filed.reversed) {
                ok = await labels.remove(t.source, t.key, label.id) != null &&
                    ok;
              }
              return ok;
            }, "Couldn't take that label off every thread just now."),
    );
    _takeTriageFocusSoon();
  }

  /// Enter on a new name in the bar's picker: create it, then
  /// [_applyBulkLabel] — [_createAndApplyLabel]'s shape, the mode read and the
  /// picker closed before the create's await for the same reason, and the
  /// cursor handed back to the list when the create is refused.
  Future<void> _createAndApplyBulkLabel(String name) async {
    final dismissAfter = _bulkPickerRequest?.dismissAfter ?? false;
    _clearBulkPicker();
    _takeTriageFocusSoon();
    final label = await ref.read(labelsProvider.notifier).create(name);
    if (!mounted) return;
    if (label == null) {
      _toast(ref.read(labelsProvider).error ??
          "Couldn't save that label just now.");
      _takeTriageFocusSoon();
      return;
    }
    await _applyBulkLabel(label, dismissAfter: dismissAfter);
  }

  /// The chips on the bar's second line, seeded from the anchor (else the
  /// first ticked row): a scope that does not apply to the seed, or whose
  /// every drawn match is already ticked, offers nothing and is left off.
  /// A press adds matches from the DRAWN rows only.
  List<BulkSimilarChip> _similarChips(
    List<Conversation> rows,
    List<Conversation> live,
  ) {
    if (live.isEmpty) return const [];
    final anchor = _checkAnchor;
    var seed = live.first;
    if (anchor != null) {
      for (final c in rows) {
        if (c.source == anchor.source && c.id == anchor.key) seed = c;
      }
    }
    return [
      for (final scope in SimilarScope.values)
        ?_similarChip(rows, seed, scope),
    ];
  }

  BulkSimilarChip? _similarChip(
    List<Conversation> rows,
    Conversation seed,
    SimilarScope scope,
  ) {
    final matches = similarRows(rows, seed, scope);
    if (matches.isEmpty) return null;
    if (matches.every((c) => _checked.contains((source: c.source, key: c.id)))) {
      return null;
    }
    return BulkSimilarChip(
      scope: scope,
      label: scope == SimilarScope.sender
          ? 'Same sender'
          : similarValueOf(seed, scope)!,
      count: matches.length,
      onTap: () => setState(() {
        for (final c in matches) {
          _checked.add((source: c.source, key: c.id));
        }
      }),
    );
  }

  /// The bar and, under it, its picker — or nothing while no drawn row is
  /// ticked. Pinned between the label lens and the list by the caller.
  List<Widget> _bulkBar(List<Conversation> rows, List<Label> labels) {
    final live = _liveChecked(rows);
    if (live.isEmpty) return const [];
    final request = _bulkPickerRequest;
    final n = live.length;
    return [
      BulkActionBar(
        count: n,
        onDismiss: () => unawaited(_bulkDismiss()),
        onLabel: () => _requestBulkPicker(dismissAfter: false),
        onLater: () => unawaited(_bulkLater()),
        onDropSenders: () => unawaited(_bulkDropSenders()),
        onClear: _clearChecked,
        similar: _similarChips(rows, live),
      ),
      if (request != null)
        Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s8),
          child: LabelPicker(
            key: const ValueKey('bulk-label-picker'),
            labels: labels,
            prompt: request.dismissAfter
                ? 'Mark ${_threads(n)} done with a label…'
                : 'Label ${_threads(n)}',
            onApply: (label) => unawaited(_applyBulkLabel(
              label,
              dismissAfter: _bulkPickerRequest?.dismissAfter ?? false,
            )),
            onCreate: (name) => _createAndApplyBulkLabel(name),
            onDismissWithoutLabel: request.dismissAfter
                ? () {
                    _clearBulkPicker();
                    unawaited(_bulkDismiss());
                  }
                : null,
            onClose: _clearBulkPicker,
          ),
        ),
    ];
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
    final calendar = _railCalendar(conversations);
    return AppRail(
      conversations: conversations,
      storylines: _scopedStorylines(),
      dismissed: _dismissedStorylines(),
      possible: _possibleStorylines(),
      selectedId: _selectedId,
      selectedSource: _selectedSource,
      selectedStorylineId: _selectedStorylineId,
      selectedLaterDay: _selectedLaterDay,
      laterCount: later.length,
      laterDays: laterDayCounts(conversations),
      attentionThreshold: ref.watch(appPrefsProvider).attentionThreshold,
      // The same value the overview's control writes and `_submitFind` reads.
      // One pile, one order, three places it is drawn.
      needsYouSort: ref.watch(appPrefsProvider).needsYouSort,
      ownerDomains: _ownerDomains,
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
      onNewStoryline: () => setState(() => _declaringStoryline = true),
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
      // The same two writes the suggestion rows make. Keeping one makes it
      // active and takes its threads out of the sweep's pool; letting one go
      // dismisses it with its members, so it lands in the fold below and can
      // be restored.
      onKeepPossible: (id) => ref.read(storylinesProvider.notifier).keep(id),
      onDismissPossible: (id) {
        // The row leaves the fold, so a selection pointing at it would render
        // nothing — the same clear the suggestion rows do, for the same
        // reason.
        if (_selectedStorylineId == id || _addingToStorylineId == id) {
          setState(() {
            _selectedStorylineId = null;
            _addingToStorylineId = null;
          });
        }
        ref.read(storylinesProvider.notifier).dismiss(id);
      },
      // The live rows' own selection. Reading the threads is the whole point
      // of opening one of these before answering.
      onOpenPossible: _selectStoryline,
      calendarShown: calendar.shown,
      todayShown: calendar.todayShown,
      todayMeetings: calendar.todayMeetings,
      calendarZone: calendar.zone,
      now: calendar.now,
      invitesCount: calendar.invites,
      dayRows: calendar.dayRows,
      today: calendar.today,
      selectedDay: _selectedDay,
      showingInvites: _showingInvites,
      onSelectDay: _selectDay,
      onOpenInvites: _openInvites,
      onOpenEvent: _openEvent,
    );
  }

  /// What the list column shows of the calendar, read once per build.
  ///
  /// The mirror's providers are watched only while the calendar is shown at
  /// all ([calendarShowsMirror]), so a session in SDK mode reads nothing from
  /// the table. Every read is the store's, never the backend's; an empty
  /// table is simply no rows.
  ({
    bool shown,
    bool todayShown,
    CalendarZone? zone,
    DateTime now,
    CalendarDate? today,
    List<CalendarEvent> todayMeetings,
    List<(CalendarDate, DaySummary)> dayRows,
    int invites,
  }) _railCalendar(List<Conversation> conversations) {
    final availability = ref.watch(calendarAvailabilityProvider);
    final shown = calendarShowsMirror(availability);
    final now = DateTime.now();
    final zone = shown ? ref.watch(calendarZoneProvider).valueOrNull : null;
    if (zone == null) {
      return (
        shown: shown,
        todayShown: false,
        zone: null,
        now: now,
        today: null,
        todayMeetings: const [],
        dayRows: const [],
        invites: 0,
      );
    }
    final today = zone.dateOf(now.toUtc());
    final upcoming =
        ref.watch(upcomingEventsProvider(today)).valueOrNull ?? const [];
    final invites =
        ref.watch(invitesOwedProvider(invitesAsOf(now))).valueOrNull ??
            const [];
    return (
      shown: shown,
      todayShown: calendarShowsToday(availability),
      zone: zone,
      now: now,
      today: today,
      todayMeetings:
          remainingToday(events: upcoming, nowUtc: now.toUtc(), zone: zone),
      // The day rows are the Day stop's column and nobody else's, and they
      // are the one costly part of this — fifteen merges on every build — so
      // they are worked out only while that column is on screen. The Today
      // meetings and the invite count still are: Home's Today section reads
      // them.
      dayRows: _section == RailSection.day
          ? upcomingDays(
              today: today,
              events: upcoming,
              conversations: conversations,
              invites: invites,
              now: now,
              zone: zone,
            )
          : const [],
      invites: invites.length,
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
          _processingToggle(),
          const SizedBox(height: BondSpacing.s8),
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
            // A `>` needle is a command being chosen, not a filter: narrowing
            // the column under it would empty the very list the command is
            // about to act on.
            onChanged: (value) => setState(
              () => _find = isCommandNeedle(value) ? '' : value,
            ),
            onSubmit: (_) => _submitFind(),
            onClear: _clearFind,
            onCommand: _runCommand,
            // A needle that reads as a calendar question gets the one
            // "Ask Day" row; the lexicon's rules only, no model.
            asksDay: (text) =>
                calendarShowsMirror(ref.read(calendarAvailabilityProvider)) &&
                looksLikeCalendarCommand(text),
            // Names only: the autocomplete completes `label:` terms, and the
            // matching itself is find_filter's, which reads the rows.
            labelNames: [
              for (final l in ref.watch(labelsProvider).labels) l.name,
            ],
          ),
          const SizedBox(height: BondSpacing.s8),
          _sourceFilterBar(),
          _triageProgress(),
        ],
      ),
    );
  }

  /// Whether this session runs model work at all — the first thing in the
  /// column, above the section label.
  ///
  /// Here rather than on the icon rail because the rail is 56 px of 44 px
  /// stops: a labelled switch does not fit, and an eighth unlabelled glyph
  /// would read as a place to go rather than a thing to turn off. This header
  /// draws on every section, sits above the scroll, and already holds
  /// [_triageProgress] — which is the caption that stops moving when the
  /// switch goes off, so the question and its answer are one block.
  Widget _processingToggle() {
    final on = ref.watch(processingProvider);
    // One node, not three: a switch, its name and its state read as a single
    // control to a screen reader, and split across three siblings they arrive
    // as an unlabelled toggle followed by two loose words.
    return MergeSemantics(
      child: Row(
        children: [
          // The compact Material switch: this is a rail control beside a
          // caption, not a settings row.
          Transform.scale(
            scale: 0.8,
            alignment: Alignment.centerLeft,
            child: Switch(
              key: const ValueKey('processing-toggle'),
              value: on,
              onChanged: (value) => unawaited(_setProcessing(value)),
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          Expanded(
            child: Text(
              'AI processing',
              style: BondType.caption.copyWith(
                color: BondColors.onDarkSecondary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // The word as well as the switch. A switch alone says which way it
          // is thrown only to somebody who already knows which way is on.
          Text(
            on ? 'On' : 'Off',
            style: BondType.caption.copyWith(
              color: on ? BondColors.railAccent : BondColors.onDarkMuted,
            ),
          ),
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
    // The Inbox feed reads the store itself too, for the shelf's reason — and
    // unconditionally, because the tiles, the hot strip and the pulse all read
    // the feed's copy of this list and none of them is necessarily on screen
    // when it moves. The notifier no-ops on an equal list, so a chip that
    // changed nothing costs nothing.
    ref.read(homeFeedProvider.notifier).setSources(_activeSources);
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
  /// where they were. From a Why panel or a file it REPLACES that panel — the
  /// side shows one thing — and [_openBeside] closes the rail overlay at
  /// narrow widths.
  ///
  /// [push] is the ask made from the thread BESIDE, where the transcript is
  /// what the reader came from: the story goes on top of it and the ✕ hands the
  /// transcript back. Asked from a Why panel that was itself pushed, the
  /// replace lands on the same stack and the ✕ still comes back to the
  /// transcript rather than to the Why — which is what that panel's own
  /// comment already promised.
  void _openHistory(String source, String id, {bool push = false}) =>
      _openBeside(HistoryPanel(source: source, id: id), push: push);

  /// Turns model work on or off for this session, and makes the four drains
  /// follow.
  ///
  /// A settings-host mutator's shape, and this screen is the one place that
  /// can do it for the same reason: the notifier holds a flag and knows
  /// nothing about the queues, and the queues read the flag but are never
  /// told when it moves. ON pumps triage and then the lanes, in that order and
  /// unawaited — a drain is minutes of model time and a switch must not hang
  /// on it. OFF calls `stop()` on all four, which is "finish the item in
  /// flight, then end the drain": without it a fast drain that had already
  /// started would keep dialling the model for as long as its backlog lasted.
  ///
  /// The activity row goes in either way, before the pumps, so the panel shows
  /// who asked for the work that follows it. The PREFERENCE is written beside
  /// the notifier and after it, so the switch flips under the finger and the
  /// next launch comes back the way this one was left.
  Future<void> _setProcessing(bool on) async {
    ref.read(processingProvider.notifier).set(on);
    await ref
        .read(activityLogProvider)
        .record('processing', status: on ? 'on' : 'off');
    if (!mounted) return;
    if (on) {
      // Quietly, because this is a button and nothing awaits what it starts:
      // a triage drain parked on a dead server would otherwise throw into
      // whatever zone the tap happened to be in, and cost the lanes their
      // pump on the way past.
      unawaited(pumpTriageThenWorkersQuietly(
        triage: () => ref.read(triageQueueProvider).pump(),
        workers: () => ref.read(aiWorkersProvider).pumpAll(),
      ));
    } else {
      // The queue, then the three lanes as one — see [AiWorkers.stopAll] for
      // why triage is named separately.
      ref.read(triageQueueProvider).stop();
      ref.read(aiWorkersProvider).stopAll();
    }
    // The preference LAST, after the drains have been told: it is what the
    // NEXT launch reads, and a write that throws must not leave the lanes
    // running under a switch that already reads off.
    await ref.read(appPrefsProvider.notifier).setProcessingOn(on);
  }

  /// How long a reset waits for a pull to land before going ahead anyway.
  ///
  /// Long enough for an ordinary page, short enough that a button is never
  /// stuck: a connector that has been out for thirty seconds is one the reset
  /// cannot usefully keep waiting for, and the second cursor clear in the
  /// settings host's `_forgetAndResync` is what covers the pass that lands
  /// after it.
  static const Duration _quietTimeout = Duration(seconds: 30);

  /// Waits until neither connector has a pull out, or until [_quietTimeout].
  ///
  /// A poll rather than a future to await, because the two flags are what the
  /// screen has: every pull it starts raises one and lowers it in a `finally`
  /// (see [_notePulling]), and there is no completer behind them to hang on.
  /// A quarter second is far below the length of a Graph page and far above
  /// the cost of reading two booleans.
  Future<void> _waitForPullsToSettle() async {
    final until = DateTime.now().add(_quietTimeout);
    while ((_mailPulling || _teamsPulling) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
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

  /// The settings pane, wired to this screen.
  ///
  /// The surface itself is [SettingsHost], which owns the probe and every
  /// writer only settings calls. What is bound here is what only the inbox can
  /// answer: where Back and Home go, the sidebar switch's own setter, the two
  /// pull flags a reset waits out, and the toasts. ONE binding for both rungs,
  /// so a callback the host gains is wired once rather than twice.
  ///
  /// [scope] is what tells the two rungs apart: the avatar menu's Settings
  /// opens all of it, the AI stop opens the model half under the title 'AI'.
  Widget _settingsHost({
    required SettingsScope scope,
    required VoidCallback onBack,
  }) =>
      SettingsHost(
        scope: scope,
        onBack: onBack,
        onHome: () => _selectSection(RailSection.home),
        onCloseSettings: _closeSettings,
        fileDialogs: _fileDialogs,
        onSetProcessing: _setProcessing,
        waitForPullsToSettle: _waitForPullsToSettle,
        onRefreshNow: _refreshAll,
        onSignOut: _signOut,
        onOpenActivityLog: _openActivityLog,
        onForgetThumbnails: _forgetThumbnails,
        onToast: _toast,
      );

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
  ///
  /// [selectAll] false leaves the cursor at the end instead — a needle the app
  /// just wrote for the reader (a label chip's `label:`) is one to add words
  /// to, not one to type over.
  void _focusFind({bool selectAll = true}) {
    setState(() {
      if (MediaQuery.sizeOf(context).width < _twoPaneBreakpoint) {
        _railOpen = true;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _findFocus.requestFocus();
      _findText.selection = selectAll
          ? TextSelection(baseOffset: 0, extentOffset: _findText.text.length)
          : TextSelection.collapsed(offset: _findText.text.length);
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
  ///
  /// Except a needle carrying a facet Home's search cannot read: `label:`,
  /// `-label:`, `is:done` and `is:external`. There it would hunt for the
  /// literal string "is:done" and answer nothing useful, so the reader stays
  /// where they are and the rail's own empty state says nothing matched.
  /// `from:` and `has:` are part of Home's grammar and still escalate.
  void _submitFind() {
    final target = firstFindTarget(
      scope: _section ?? RailSection.home,
      conversations: _rows,
      storylines: _scopedStorylines(),
      rooms: _rooms,
      find: _find,
      unreadOnly: _unreadOnly,
      threshold: ref.read(appPrefsProvider).attentionThreshold,
      needsYouSort: ref.read(appPrefsProvider).needsYouSort,
      ownerDomains: _ownerDomains,
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
        final query = FindQuery.parse(_find);
        // Only the facets Home's grammar cannot read. `from:` and `has:` are
        // honoured there (search_grammar.dart), so they still escalate.
        if (query.labels.isNotEmpty ||
            query.withoutLabels.isNotEmpty ||
            query.dismissedOnly ||
            query.externalOnly) {
          return;
        }
        _selectSection(RailSection.home);
        ref.read(homeFeedProvider.notifier).submitSearch(text);
        return;
    }
    // The switcher closes on a pick, as Slack's does: the needle answered its
    // question, and leaving it up would leave the column filtered around a
    // thread the reader has already opened.
    _clearFind();
    // Onto the triage keys rather than just off the field: a bare unfocus
    // left focus on the route's scope, above the keys, so the thread Find
    // had just opened answered no `e`, `j` or `z` until it was clicked.
    _findFocus.unfocus();
    _takeTriageFocus();
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
  ///
  /// While processing is off the same count is still worth saying, and the
  /// sentence changes rather than the number: a counter that had simply
  /// stopped moving would read as a stall rather than as a switch somebody
  /// threw. Nothing at all when there is nothing waiting — an off session with
  /// an empty queue has no news.
  ///
  /// A PARKED pipeline is the third sentence, and it is the one a person can
  /// act on: the reason rides the drains' own progress streams, so there is no
  /// health poll behind it and the line clears when the next pump gets an item
  /// through. "Retrying each minute" is the inbox's own sixty-second poll and
  /// is the only cadence this sentence may claim. Processing being off still
  /// wins: a queue nobody is draining is not a queue that is stuck.
  Widget _triageProgress() {
    final on = ref.watch(processingProvider);
    final parked = ref.watch(parkedProvider).valueOrNull;
    final onBox =
        ref.watch(appPrefsProvider).modelPlacement == ModelPlacement.box;
    return StreamBuilder<TriageProgress>(
      stream: ref.watch(triageQueueProvider).progress,
      builder: (context, snapshot) {
        final remaining = snapshot.data?.remaining ?? 0;
        final waiting = parked?.waiting ?? remaining;
        // The TRIAGE queue being empty is not the pipeline being empty: the
        // three worker lanes have backlogs of their own, and a parked draft
        // lane with nothing left to triage is exactly the case somebody needs
        // told about.
        //
        // A park with something waiting therefore speaks even when triage is
        // done. An unparked worker backlog does NOT: the only sentence there
        // is to say is "Triaging N remaining…", which would read `0` and be a
        // worse answer than silence. What the rail is for is the two states a
        // person can act on, a queue moving and a queue stuck.
        final stuck = parked?.reason != null && waiting > 0;
        if (remaining == 0 && !stuck) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: BondSpacing.s8),
          child: Text(
            railProgressLine(
              on: on,
              remaining: remaining,
              reason: parked?.reason,
              waiting: waiting,
              onBox: onBox,
            ),
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
      return _settingsHost(scope: SettingsScope.all, onBack: _closeSettings);
    }
    if (_showingActivityLog) return _activityLog();

    final addingTo = _addingToStorylineId;
    if (addingTo != null) {
      final storyline = _storylineById(addingTo);
      if (storyline != null) return _addThreadPane(storyline);
      // Dismissed or gone from under the pane; fall through to whatever is
      // next.
    }

    // Above the picking branch because it is the outer act: declaring a
    // storyline is not about any one thread, and the two are never up at once
    // anyway — the rail's control clears nothing but sets this, and every
    // selection clears both.
    if (_declaringStoryline) return _declareStorylinePane();

    final picking = _pickingStorylineForThread;
    if (picking != null) return _pickStorylinePane(picking);

    // Over the thread it was opened for; a thread that went from under it
    // falls through to whatever is next, and the next selection clears it.
    final findFor = _findTimeFor;
    if (findFor != null) {
      final thread = _conversationFor(findFor.source, findFor.key);
      if (thread != null) return _findTimePane(thread);
    }

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

    // The Day stop, below every selection above: a thread opened from a Day
    // row shows the thread, and closing it lands back on the same day because
    // [_select] leaves [_selectedDay] alone.
    if (_section == RailSection.day) return _dayPane(conversations);

    // The AI stop's pane IS Settings, narrowed to the sections that are about
    // the model. It sits here rather than with the other panes above because
    // it is a SECTION and not an overlay: nothing opened it, the user is
    // simply standing on that stop.
    if (_section == RailSection.ai) {
      return _settingsHost(
        scope: SettingsScope.ai,
        onBack: () => _selectSection(RailSection.home),
      );
    }

    return _overview(conversations, loadError);
  }

  /// The Day stop: one day's agenda, or the invites owed.
  ///
  /// "Today" is worked out HERE, from the clock, on every build, and handed to
  /// the providers as a date — so a pane left open across midnight moves on
  /// with the next rebuild rather than holding yesterday.
  ///
  /// Until the zone has resolved there is nothing honest to draw, except where
  /// the calendar is not shown at all: those states are sentences, and a
  /// sentence needs no zone.
  Widget _dayPane(List<Conversation> conversations) {
    final availability = ref.watch(calendarAvailabilityProvider);
    final shows = calendarShowsMirror(availability);
    final zone = ref.watch(calendarZoneProvider).valueOrNull ??
        (shows ? null : CalendarZone.utc());
    if (zone == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = zone.dateOf(now.toUtc());
    final day = _selectedDay ?? today;
    final events =
        shows ? ref.watch(dayEventsProvider(day)).valueOrNull : const <Never>[];
    // Null while the read is in flight, so the invites view draws nothing
    // rather than a false "No invites to answer."
    final invites = shows
        ? ref.watch(invitesOwedProvider(invitesAsOf(now))).valueOrNull
        : const <InviteEntry>[];
    final grid = _dayView == DayView.grid
        ? _dayGrid(conversations, zone: zone, day: day, today: today,
            now: now, shows: shows, dayEvents: events)
        : null;
    return DayPane(
      mode: _showingInvites ? DayPaneMode.invites : DayPaneMode.agenda,
      day: day,
      today: today,
      now: now,
      zone: zone,
      availability: availability,
      events: events,
      conversations: conversations,
      invites: invites,
      onSelectDay: _selectDay,
      onBackToDay: () => setState(() => _showingInvites = false),
      onOpenConversation: (source, id) => _select(id, source: source),
      onOpenLink: (url) => unawaited(_launchExternal(url)),
      onOpenSettings: _openSettings,
      onOpenEvent: _openEvent,
      view: _dayView,
      onViewChanged: (v) => _setDayView(view: v),
      gridSpan: _gridSpan,
      onGridSpanChanged: (s) => _setDayView(span: s),
      grid: grid,
      // The bar reads and writes the calendar this session shows; where the
      // mirror is hidden (SDK mode, a missing scope) there is none to ask.
      commandBar: shows ? _commandBar(zone, today) : null,
      planCard: shows ? _commandCard(zone, today) : null,
      // Today's threads asking for a time. Only today: an ask is about now,
      // and another day's agenda is about that day.
      schedulingAsks: day == today
          ? _schedulingAsksIn(conversations)
          : const <Conversation>[],
      onFindTime: _openFindTime,
      briefHeadlines: shows
          ? ref.watch(briefHeadlinesProvider(day)).valueOrNull ??
              const <String, String>{}
          : const <String, String>{},
      inviteActions: (entry) => CalendarWriteFlow(
        key: ValueKey('invite-write-${entry.event.id}'),
        writer: ref.read(calendarWritesProvider),
        onDone: _calendarWriteDone,
        onFailed: _calendarWriteFailed,
        builder: (context, start, busy) => EventActions(
          key: ValueKey(entry.event.id),
          target: entry.event,
          shown: entry.event,
          // A row folded from several owed occurrences answers the series,
          // through its master's id; a single invite, and a lone owed
          // exception, answers itself (InviteEntry.answersSeries).
          respondId: entry.answersSeries ? entry.respondId : null,
          zone: zone,
          clock: DateTime.now,
          today: today,
          start: start,
          busy: busy,
          compact: true,
        ),
      ),
    );
  }

  /// The Day stop's grid, or null until its first read lands. A later read in
  /// flight (the next day, the next week) keeps the last list on screen; see
  /// [_lastGridEvents].
  ///
  /// It sits inside a filling [CalendarWriteFlow], so a drop is a press like
  /// any other: an own event moves at once and offers Undo, a meeting with
  /// guests waits on the strip over the grid naming who is emailed, and a
  /// refused or failed move leaves the tile where the store has it.
  Widget? _dayGrid(
    List<Conversation> conversations, {
    required CalendarZone zone,
    required CalendarDate day,
    required CalendarDate today,
    required DateTime now,
    required bool shows,
    required List<CalendarEvent>? dayEvents,
  }) {
    final week = _gridSpan == GridSpan.week;
    final monday = mondayOf(day);
    final List<CalendarEvent>? read;
    if (!week) {
      read = dayEvents;
    } else {
      read = shows
          ? ref.watch(weekEventsProvider(monday)).valueOrNull
          : const <CalendarEvent>[];
    }
    // A list read in another zone placed its all-day tiles by that zone's
    // midnights, so it is not kept across a zone change.
    if (_lastGridZone != zone) _lastGridEvents = null;
    _lastGridZone = zone;
    if (read != null) _lastGridEvents = read;
    final events = read ?? _lastGridEvents;
    if (events == null) return null;
    final shown = events;
    // Deadlines and returns by the agenda's own rule ([rangeMarkers] shares
    // it with [buildDayItems]), so the header and the list can never
    // disagree about what falls when.
    final markers = rangeMarkers(
      from: week ? monday : day,
      toExclusive: week ? monday.addDays(7) : day.addDays(1),
      conversations: conversations,
      now: now,
      zone: zone,
    );
    final pending = _gridMove;
    // A standing command proposal is the ghost too, whenever no drop is
    // pending — the drag the person is making wins over the sentence they
    // typed. Placed by its instants, so it shows on whichever page holds it.
    final plan = _commandOutcome?.plan;
    final commandGhost = plan is CalendarProposal &&
            plan.startUtc != null &&
            plan.endUtc != null
        ? GridProposal(
            startUtc: plan.startUtc!,
            endUtc: plan.endUtc!,
            label: 'Proposed',
          )
        : null;
    return CalendarWriteFlow(
      key: const ValueKey('grid-move'),
      fill: true,
      // The tile the store answers with is the reset; a remount would scroll
      // the day back to the morning.
      resetOnSuccess: false,
      writer: ref.read(calendarWritesProvider),
      onDone: _calendarWriteDone,
      onFailed: _calendarWriteFailed,
      onIdle: () {
        if (mounted && _gridMove != null) setState(() => _gridMove = null);
      },
      builder: (context, start, busy) => DayGrid(
        day: day,
        span: _gridSpan,
        events: shown,
        markers: markers,
        proposal: busy && pending != null
            ? GridProposal(
                startUtc: pending.startUtc,
                endUtc: pending.endUtc,
                label: 'Moving here…',
              )
            : commandGhost,
        locked: busy,
        zone: zone,
        clock: DateTime.now,
        onOpenEvent: _openEvent,
        onOpenItem: (item) {
          switch (item) {
            case DeadlineItem(:final conversation):
            case ReturnItem(:final conversation):
              _select(conversation.id, source: conversation.source);
            default:
              break;
          }
        },
        onMoveRequested: busy
            ? null
            : (id, startUtc, endUtc) {
                final event = shown.where((e) => e.id == id).firstOrNull;
                if (event == null) return;
                // The typed move's refusals, in its words: a drop into the
                // past says so and writes nothing.
                final checked = checkDrop(
                  shown: event,
                  startUtc: startUtc,
                  endUtc: endUtc,
                  now: DateTime.now(),
                );
                if (checked is NewTimeProblem) {
                  _toast(checked.reason, cleared: 0);
                  return;
                }
                if (checked is! NewTimeTimed) return;
                final write = MoveEvent.timed(id,
                    startUtc: checked.startUtc, endUtc: checked.endUtc);
                setState(() => _gridMove = (
                      id: id,
                      startUtc: checked.startUtc,
                      endUtc: checked.endUtc,
                    ));
                start(
                  write,
                  summary: writeSummary(write,
                      shown: event, series: false, zone: zone, today: today),
                  doneMessage: writeDoneMessage(write,
                      shown: event, series: false, zone: zone),
                );
              },
        onVisibleDayChanged: _selectDay,
      ),
    );
  }

  /// A meeting card's Yes / Maybe / No. [target] is the id the card looked
  /// up — the master, for a recurring invite — so an answer there answers
  /// the series, and the summary says so.
  Widget? _cardActions(CalendarEvent target, CalendarEvent shown) {
    final zone = ref.read(calendarZoneProvider).valueOrNull;
    if (zone == null) return null;
    final now = DateTime.now();
    return CalendarWriteFlow(
      key: ValueKey('card-write-${target.id}'),
      writer: ref.read(calendarWritesProvider),
      onDone: _calendarWriteDone,
      onFailed: _calendarWriteFailed,
      builder: (context, start, busy) => EventActions(
        key: ValueKey(shown.id),
        target: target,
        shown: shown,
        zone: zone,
        clock: DateTime.now,
        today: zone.dateOf(now.toUtc()),
        start: start,
        busy: busy,
        compact: true,
      ),
    );
  }

  // ── the Day command bar ──────────────────────────────────────────────

  /// ⌘K's "Ask Day" row: the Day stop, and [text] handed to its bar, which
  /// submits it a frame later ([_pendingCommandText]).
  void _askDay(String text) {
    _selectSection(RailSection.day);
    setState(() => _pendingCommandText = text);
  }

  /// Drops the plan and anything in flight, as a bare field write for a
  /// caller already inside a setState.
  void _forgetCommand() {
    _commandOutcome = null;
    _commandText = '';
    _commandBinds = const [];
    _commandBusy = false;
    _commandSerial += 1;
    _pendingCommandText = null;
  }

  void _clearCommand() {
    if (!mounted) return;
    setState(_forgetCommand);
  }

  /// The people the bar matches names against: every room's people with a
  /// mailbox ([knownPeopleOfRooms]), from the rooms [_body] last grouped.
  List<KnownPerson> _commandPeople() => knownPeopleOfRooms(_rooms);

  /// The meetings the bar matches against: the mirror's next two weeks.
  /// Family arg computed here from the clock, the day providers' rule.
  List<CalendarEvent> _commandEvents(CalendarDate today) =>
      ref.watch(upcomingEventsProvider(today)).valueOrNull ??
      const <CalendarEvent>[];

  /// Enter in the bar ([choice] null), or a choice pressed on its card.
  ///
  /// A press adds its bind to [_commandBinds] and re-plans the outcome it
  /// answered (`resume`), so the model is not asked twice and a name
  /// settled by an earlier press stays settled. A fresh Enter starts over.
  ///
  /// The router never throws; the catch is a belt, because an exception here
  /// would leave the bar spinning with no card to say why.
  Future<void> _submitCommand(
    String text, {
    required CalendarZone zone,
    CommandOption? choice,
  }) async {
    final serial = _commandSerial + 1;
    final resume = choice == null ? null : _commandOutcome;
    final binds = choice == null
        ? const <CommandBind>[]
        : [..._commandBinds, choice.bind];
    setState(() {
      _commandSerial = serial;
      _commandBusy = true;
      _commandText = text;
      _commandBinds = binds;
      _pendingCommandText = null;
    });
    CommandOutcome outcome;
    final now = DateTime.now();
    var people = const <KnownPerson>[];
    var events = const <CalendarEvent>[];
    try {
      final today = zone.dateOf(now.toUtc());
      people = _commandPeople();
      events = ref.read(upcomingEventsProvider(today)).valueOrNull ??
          const <CalendarEvent>[];
      outcome = await ref.read(commandRouterProvider).submit(
            text,
            now: now,
            zone: zone,
            today: today,
            people: people,
            events: events,
            binds: binds,
            resume: resume,
          );
    } on Object catch (e) {
      debugPrint('calendar command: submit failed: ${e.runtimeType}');
      outcome = _commandFailed(text, now: now, zone: zone, people: people,
          events: events);
    }
    if (!mounted || serial != _commandSerial) return;
    setState(() {
      _commandOutcome = outcome;
      _commandBusy = false;
    });
  }

  /// The card for a command whose reading threw: the one sentence, over the
  /// pure parse (the router may be what threw). A parse that throws too
  /// still leaves a card, over an empty one.
  CommandOutcome _commandFailed(
    String text, {
    required DateTime now,
    required CalendarZone zone,
    required List<KnownPerson> people,
    required List<CalendarEvent> events,
  }) {
    const plan = CannotDo('Something went wrong reading that.');
    ParsedCommand parsed;
    try {
      parsed = parseCommand(text,
          now: now, zone: zone, people: people, events: events);
    } on Object {
      final today = zone.dateOf(now.toUtc());
      parsed = ParsedCommand(
        text: text,
        guess: CommandGuess.none,
        when: WhenResolution(today: today, zone: zone),
        eventWhen: WhenResolution(today: today, zone: zone),
      );
    }
    return CommandOutcome(plan: plan, path: CommandPath.lexicon, parsed: parsed);
  }

  /// A slot pressed on a [SlotChoice]: its write's dry run, as the proposal
  /// the card draws next.
  Future<void> _pickCommandSlot(
    SlotChoice choice,
    FreeSlot slot, {
    required CalendarZone zone,
    required CalendarDate today,
  }) async {
    final serial = _commandSerial + 1;
    final previous = _commandOutcome;
    setState(() {
      _commandSerial = serial;
      _commandBusy = true;
    });
    CommandPlan plan;
    try {
      plan = await ref.read(commandPlannerProvider).propose(
            choice.buildWrite(slot),
            target: choice.targetEvent,
            zone: zone,
            today: today,
          );
    } on Object catch (e) {
      // `propose` says its failures as plans; a throw is a belt, so the bar
      // can never be left spinning.
      debugPrint('calendar command: slot proposal failed: ${e.runtimeType}');
      plan = const CannotDo('Something went wrong reading that.');
    }
    if (!mounted || serial != _commandSerial) return;
    setState(() {
      _commandBusy = false;
      if (previous != null) {
        _commandOutcome = CommandOutcome(
            plan: plan, path: previous.path, parsed: previous.parsed);
      }
    });
  }

  /// The bar, bound to this screen's clock, zone, people and meetings.
  Widget _commandBar(CalendarZone zone, CalendarDate today) {
    final people = _commandPeople();
    final events = _commandEvents(today);
    return DayCommandBar(
      key: const ValueKey('day-command-bar'),
      preview: (text, {guess}) => ref.read(commandRouterProvider).preview(
            text,
            now: DateTime.now(),
            zone: zone,
            people: people,
            events: events,
            guess: guess,
          ),
      // The decision model's command head, after the lexicon's chips: one
      // request out, the newest text winning, nothing drawn without a head.
      refine: (text) =>
          ref.read(decisionCommandClassifierProvider).classifyPreview(text),
      submit: (text) => _submitCommand(text, zone: zone),
      zone: zone,
      clock: DateTime.now,
      initialText: _pendingCommandText,
      onCleared: _clearCommand,
      busy: _commandBusy,
      planStands: _commandOutcome != null,
    );
  }

  /// The card for the bar's last Enter, or null when there is none.
  Widget? _commandCard(CalendarZone zone, CalendarDate today) {
    final outcome = _commandOutcome;
    if (outcome == null) return null;
    final serial = _commandSerial;
    return CommandPlanCard(
      key: ValueKey('command-plan-$serial'),
      plan: outcome.plan,
      availability: ref.watch(calendarAvailabilityProvider),
      zone: zone,
      today: today,
      writer: ref.read(calendarWritesProvider),
      onDone: (message, undo) {
        _calendarWriteDone(message, undo);
        // Only the card this write came from: a new Enter while it was in
        // flight put up another card, and that one stands.
        if (serial == _commandSerial) _clearCommand();
      },
      onFailed: _calendarWriteFailed,
      onDismiss: _clearCommand,
      onPickSlot: (choice, slot) =>
          _pickCommandSlot(choice, slot, zone: zone, today: today),
      onChoose: (option) =>
          _submitCommand(_commandText, zone: zone, choice: option),
      onOpenEvent: _openEvent,
    );
  }

  /// Every calendar write says what it did through the one toast, and an
  /// undoable write (a private change that emailed nobody) offers its Undo
  /// there and on `z`. `cleared: 0`: a calendar write takes no row off the
  /// pile.
  void _calendarWriteDone(String message, CalendarWrite? undo) => _toast(
        message,
        onUndo: undo == null ? null : () => unawaited(_undoCalendarWrite(undo)),
        cleared: 0,
      );

  /// A calendar write that failed after the place it started had gone (the
  /// panel closed, a new command replaced its card): said here, because the
  /// inline error line had nowhere left to stand.
  void _calendarWriteFailed(String message) => _toast(message, cleared: 0);

  Future<void> _undoCalendarWrite(CalendarWrite undo) async {
    final outcome =
        await ref.read(calendarWritesProvider).commit(undo, isUndo: true);
    if (!mounted) return;
    _toast(outcome.ok ? 'Undone.' : outcome.message);
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
      // The tiles are the filter and the menu is the order; both live on the
      // notifier, which is what makes them survive a swap to a thread and back.
      filter: feed.filter,
      onFilter: (value) =>
          ref.read(homeFeedProvider.notifier).setFilter(value),
      sort: feed.sort,
      onSort: (value) => ref.read(homeFeedProvider.notifier).setSort(value),
      // The Emails / Teams tiles write the list column's chips, because that
      // is the one source selection the app has and a second copy of it on
      // this bar would be two answers to one question.
      onOpenContextFile: (fileId, locator) => _openBeside(
        ContextFilePanel(fileId: fileId, locator: locator),
      ),
      sourceFilter: _sourceFilter,
      onSelectSource: _setSourceFilter,
      // Whatever the last read said, carried through a re-read the same way the
      // tiles are; null only before the very first one.
      pulse: ref.watch(pipelinePulseProvider).valueOrNull,
      mailSyncing: _mailPulling,
      teamsSyncing: _teamsPulling,
      stamps: ref.watch(syncStampsProvider).valueOrNull,
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
      // BESIDE, not in main: this pane is a table, and a table a reader
      // cannot see while they read one of its rows is a table they have to
      // navigate back to for the next one. The Needs You overview's rule,
      // applied to the screen the app lands on. Everything [_select] does
      // except take the main pane — the thread is loaded, its draft is
      // loaded, and opening it still counts as reading it.
      onOpenThread: (source, key) => _openThreadBeside(source, key),
      onOpenStoryline: _selectStoryline,
      onLoadMore: () => ref.read(homeFeedProvider.notifier).loadMore(),
      onReleasePending: () =>
          ref.read(homeFeedProvider.notifier).releasePending(),
      onAnchoredChanged: (anchored) =>
          ref.read(homeFeedProvider.notifier).setAnchored(anchored),
      onSearch: (query) =>
          ref.read(homeFeedProvider.notifier).submitSearch(query),
      onExitSearch: () => ref.read(homeFeedProvider.notifier).exitSearch(),
      // Fire-and-forget, like Restore: the service swallows its own failures
      // and the row's next re-read is what reports whether anything moved.
      // The one thing a re-read cannot say is that nothing was owed, because
      // the row looks the same afterwards — so that answer is spoken.
      // While the switch is off the requeue still lands and nothing drains it,
      // so the row sits exactly as it did and the press reads as ignored. The
      // work is kept — turning processing on runs it — and the toast is the
      // only place that can say which of the two just happened.
      onRetry: (source, id) => unawaited(() async {
        final stages =
            await ref.read(pipelineRepairServiceProvider).retryOwed(source, id);
        if (!mounted) return;
        if (stages.isEmpty) {
          _toast('Nothing to retry — every stage has finished.');
        } else if (!ref.read(processingProvider)) {
          _toast('Queued until processing is on.');
        }
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
      onBack: _sideBack,
      backLabel: _sideBackLabel,
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

  /// The threads among [conversations] that [schedulingAsksProvider] says are
  /// asking for a time, in the list's order.
  List<Conversation> _schedulingAsksIn(List<Conversation> conversations) {
    final keys = ref.watch(schedulingAsksProvider).valueOrNull;
    if (keys == null || keys.isEmpty) return const [];
    return [
      for (final c in conversations)
        if (keys.contains(schedulingAskKey(c.source, c.id))) c,
    ];
  }

  /// Opens Find a time over the thread: selected first when it is not the
  /// main pane's already (a Day row, or the thread beside — whose panel the
  /// selection closes, the thread now standing in the main column), so Back
  /// and Put in reply land on it.
  void _openFindTime(String source, String key) {
    if (_selectedId != key || _selectedSource != source) {
      _select(key, source: source);
    }
    setState(() => _findTimeFor = (source: source, key: key));
  }

  /// Find a time for [thread]: its other people, the search, and the two
  /// ways out of a slot — the reply box, or an invite through the write flow.
  Widget _findTimePane(Conversation thread) {
    void back() => setState(() => _findTimeFor = null);
    final zone = ref.watch(calendarZoneProvider).valueOrNull;
    // Never a blank column: until the zone resolves the pane has no clock to
    // draw slots on, so it says what it is waiting for and keeps its way
    // out. Not a UTC stand-in — a search run on the wrong clock would stand
    // until the next change of people, length or week.
    if (zone == null) {
      return Padding(
        padding: const EdgeInsets.all(BondSpacing.s24),
        child: FindTimePane.waiting(
          onBack: back,
          onHome: () => _selectSection(RailSection.home),
        ),
      );
    }
    final owner = _ownerRecord.address?.trim().toLowerCase();
    final seen = <String>{};
    final people = <FindTimePerson>[
      for (final p in thread.participants)
        if ((p.email ?? '').trim().isNotEmpty &&
            p.email!.trim().toLowerCase() != owner &&
            // A Teams roster entry is no address; a repeat is one person.
            p.email!.contains('@') &&
            seen.add(p.email!.trim().toLowerCase()))
          // Lowercased, as the de-duplication above reads it: the search,
          // the invite's attendees and the pills all key on the address.
          (name: p.name ?? '', address: p.email!.trim().toLowerCase()),
    ];
    final target = (source: thread.source, conversationKey: thread.id);
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: FindTimePane(
        key: ValueKey('find-time-${thread.source}|${thread.id}'),
        availability: ref.watch(calendarAvailabilityProvider),
        subject: thread.subject,
        participants: people,
        zone: zone,
        today: zone.dateOf(DateTime.now().toUtc()),
        search: ({
          required addresses,
          required durationMinutes,
          required window,
        }) =>
            _findTimeSearch(
          addresses: addresses,
          durationMinutes: durationMinutes,
          window: window,
          zone: zone,
        ),
        onPutInReply: (text) => _putInReply(target, text),
        writer: ref.read(calendarWritesProvider),
        onDone: (message, undo, invited) {
          _calendarWriteDone(message, undo);
          // `add_to_calendar` when nobody was on it: the event went on the
          // owner's calendar and no invite went anywhere.
          unawaited(ref.read(activityLogProvider).record('find_time',
              detail: {
                'action': invited ? 'send_invite' : 'add_to_calendar',
              }));
          if (mounted) back();
        },
        onFailed: _calendarWriteFailed,
        onBack: back,
        onHome: () => _selectSection(RailSection.home),
      ),
    );
  }

  /// One Find a time search, and its activity row: how many slots, whose
  /// calendars, how many people, which week — counts and enum words only.
  Future<FindTimeResult> _findTimeSearch({
    required List<String> addresses,
    required int durationMinutes,
    required FindTimeWindow window,
    required CalendarZone zone,
  }) async {
    MailboxSettings? hours;
    try {
      hours = await ref.read(mailboxSettingsProvider.future);
    } on Object {
      hours = null;
    }
    final result = await searchFindTime(
      backend: ref.read(calendarBackendProvider),
      calendar: ref.read(calendarStoreProvider),
      hours: hours,
      addresses: addresses,
      durationMinutes: durationMinutes,
      window: window,
      now: DateTime.now(),
      zone: zone,
    );
    unawaited(ref.read(activityLogProvider).record('find_time', detail: {
      'source': result.source,
      'slots': result.slots.length,
      'people': addresses.length,
      'window': window.wire,
    }));
    return result;
  }

  /// Put in reply: [text] goes after whatever the box already holds (a blank
  /// line between), through the box's explicit stage — the path a tapped
  /// suggestion takes — and is recorded on the draft as the owner's words.
  /// Back on the thread, the cursor is in the box.
  void _putInReply(DraftTarget target, String text) {
    final draft = ref.read(draftProvider(target));
    final edited = (draft.draft?['status'] as String?) == 'edited';
    final current =
        (_stagedBodyFor(target, draft) ?? (edited ? draft.body : null) ?? '')
            .trimRight();
    final body = current.isEmpty ? text : '$current\n\n$text';
    setState(() => _findTimeFor = null);
    _stage(target, body: body);
    unawaited(ref.read(draftProvider(target).notifier).markEdited(body));
    unawaited(ref
        .read(activityLogProvider)
        .record('find_time', detail: const {'action': 'put_in_reply'}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mainComposerFocus.requestFocus();
    });
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
        // The same create with the charter the user typed beside the name, and
        // the same ending: the difference is entirely inside the service, which
        // locks the charter and sends the recruit hunting for the other threads
        // this one is the first of.
        onCreateWithCharter: (title, charter) async {
          final id = await ref.read(storylinesProvider.notifier).create(
                title,
                conversationKey: thread.id,
                source: thread.source,
                charter: charter,
              );
          if (!mounted) return;
          setState(() => _pickingStorylineForThread = null);
          ref.read(storylineTimelineProvider(id).notifier).load();
          _reloadHistoryBeside();
        },
      ),
    );
  }

  /// The New storyline pane: a title and a charter, and nothing in it yet.
  ///
  /// It ends the way the picker's create does, on the storyline it just made —
  /// [_selectStoryline] is the rail's own selection path, so the user lands in
  /// the storyline they declared and watches the recruit fill it.
  Widget _declareStorylinePane() {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: NewStorylinePane(
        onBack: () => setState(() => _declaringStoryline = false),
        onCreate: (title, charter) async {
          final id = await ref
              .read(storylinesProvider.notifier)
              .declare(title, charter);
          if (!mounted) return;
          // No clearing of the flag here: `_selectStoryline` runs
          // `_clearOverlays` inside its own `setState`, and that is what drops
          // this pane. Clearing it first would be a second frame saying the
          // same thing.
          _selectStoryline(id);
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
      onContext: () => _openContextFor(
        ContextScopeKind.storyline,
        // A storyline id is already global, and the link row stores no
        // connector for one.
        '',
        storyline.id,
        storyline.title,
      ),
      contextLinked: ref
              .watch(contextLinksProvider((
                kind: ContextScopeKind.storyline,
                source: '',
                scopeKey: storyline.id,
              )))
              .valueOrNull
              ?.length ??
          0,
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
      onRecruit: () => notifier.recruitNow(storyline.id),
      auditing: _storylineAuditing(storyline.id),
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

  /// One person's room: every thread with them, as cards.
  ///
  /// Goal one of the round, literally — a colleague who both mails and chats
  /// has ONE place here rather than two piles to merge in the reader's head,
  /// and a thread they were on with four other people is under their name too.
  /// Done and deferred threads are HERE and marked, because the question the
  /// stop answers is "what is there with this person", not "what is unfinished".
  ///
  /// Opening a card puts the thread BESIDE the room (D3), so the list the
  /// reader came from stays on screen — and the composer, the files and the
  /// thread menu are all over there, on the one conversation they belong to.
  /// The room itself offers `Message`, which is about the PERSON.
  Widget _room(PersonRoom room) {
    final photos = ref.read(profilePhotosProvider);
    final message = _messagePersonFor(room);

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
              // Omitted rather than disabled when there is nowhere to write:
              // [RoomHeader] renders a null `onTap` as a greyed button, and a
              // control that answers nothing must not look like one.
              if (message != null)
                RoomAction(
                  icon: Icons.edit_outlined,
                  label: 'Message',
                  onTap: message,
                ),
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
              filter: _roomFilter,
              onFilter: (f) => setState(() => _roomFilter = f),
              sort: ref.watch(appPrefsProvider).roomSort,
              onSort: (s) =>
                  unawaited(ref.read(appPrefsProvider.notifier).setRoomSort(s)),
              searchController: _roomSearchText,
              onSearch: (text) =>
                  setState(() => _roomNeedle = normalizeFind(text)),
              needle: _roomNeedle,
              now: DateTime.now(),
              photos: photos,
              onOpenThread: _openThreadBeside,
              emptyNotice: _scopeNotice(),
              meetingLine: _personMeetingLine(room),
            ),
          ),
        ],
      ),
    );
  }

  /// The next meeting with this room's people and when they last met, or null
  /// when there is no calendar to ask or nothing to say.
  ///
  /// "Now" is read HERE and handed to the provider floored to the quarter
  /// hour (`invitesAsOf`), the Day stop's rule: a provider that read the clock
  /// itself would keep calling a meeting "next" after it had started.
  Widget? _personMeetingLine(PersonRoom room) {
    if (!calendarShowsMirror(ref.watch(calendarAvailabilityProvider))) {
      return null;
    }
    final zone = ref.watch(calendarZoneProvider).valueOrNull;
    if (zone == null) return null;
    final addresses = personMeetingsKey(room.people.map((p) => p.email));
    if (addresses.isEmpty) return null;
    final now = DateTime.now();
    final meetings = ref
        .watch(personMeetingsProvider(
          (addresses: addresses, asOf: invitesAsOf(now)),
        ))
        .valueOrNull;
    if (meetings == null || meetings.isEmpty) return null;
    return PersonMeetingLine(
      meetings: meetings,
      zone: zone,
      today: zone.dateOf(now.toUtc()),
      onOpenEvent: _openEvent,
    );
  }

  /// What the room header's `Message` does, or null when there is nowhere
  /// obvious to write.
  ///
  /// A direct chat wins: a sentence typed at a person's name belongs in the
  /// conversation that is only the two of them, and the chat opens BESIDE with
  /// its own box focused, the way the hover Reply hands over the cursor.
  /// Failing that it is a new mail to their newest mail thread's people — a
  /// group thread included, because a mail is addressed on its face and the
  /// reader sees the To line before anything goes. A person met only in group
  /// CHATS gets no action at all: a chat has no To line to check, and the only
  /// place a sentence could land is in front of everybody in it.
  VoidCallback? _messagePersonFor(PersonRoom room) {
    final chat = directChat(room);
    if (chat != null) {
      return () {
        _openThreadBeside(chat.source, chat.id);
        // The box is in the thread that just opened beside, and it takes the
        // cursor when it MOUNTS — not a frame from now, because the box is
        // drawn only once the draft's capability has been read, and a focus
        // asked for before that has nothing to land on.
        setState(() {
          _focusSideOnMount = (source: chat.source, conversationKey: chat.id);
        });
      };
    }
    final mail = newestMailThread(room);
    if (mail != null) return () => unawaited(_composeFrom(mail));
    return null;
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
    /// A tap ASKS where this build can really send, and stages where it
    /// cannot.
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
        // Puts this option in the box and takes the cursor there: the whole
        // meaning of a tap where this build cannot send, and the *Edit first*
        // answer where it can. The box is already under the thread, so all a
        // card owes the reader is the words and somewhere to change them —
        // and, under an OLDER message, which message they answer: a send
        // resolves to the newest inbound on its own, so a card that stayed
        // silent about its message would have its reply land on a different
        // one. The newest message's card says nothing, because nothing needs
        // saying.
        onPick: (option) {
          _stage(target, body: option.body);
          if (m.id != newestInboundId) {
            _replyToMessage(target, m, composerFocus);
          } else {
            composerFocus.requestFocus();
          }
        },
        // The card's tap, confirmed. Only on the top rung: the lower rungs
        // save to Outlook or copy to the clipboard, and a question that says
        // Send and does either is a lie — so on those a tap asks nothing and
        // stages instead.
        //
        // Always addressed to `m.id`: the card answers the message it hangs
        // under, newest or not, and nothing is staged on the way — the words
        // the reader confirmed are the words that go.
        onSend: draft.capability == SendCapability.send
            ? (option) => unawaited(_send(target, option.body, replyTo: m.id))
            : null,
        onDismiss: () => unawaited(notifier.dismissOptionsFor(m.id)),
      );
    }

    // The address a drop rule is keyed on: whoever sent the newest inbound
    // message, not the first participant folded into the row. On a
    // multi-party thread those differ, and a gate on the wrong one is a
    // standing rule about somebody who did not send the mail being dropped.
    final dropAddress = _newestInboundSender(shown) ?? selected.primaryEmail;
    final panel = ThreadDetailPanel(
      key: ValueKey(selected.id),
      conversation: selected,
      messages: shown,
      jumps: inSidePanel ? _sideJumps : _mainJumps,
      ownerDomains: _ownerDomains,
      // Read, not watched: the service is a session-long singleton, and each
      // avatar asks it for its own face.
      photos: ref.read(profilePhotosProvider),
      // The folds live above the panel, so a side thread that went under a
      // file preview opens the runs the reader had opened rather than starting
      // over. Recorded WITHOUT a setState: nothing on this frame reads the
      // set — the row has already redrawn itself — and rebuilding the screen
      // under a cursor to note a fold would be a frame spent on nothing.
      unfolded: _unfoldedRows[_stageKey(target)] ?? const <String>{},
      onFoldChanged: (messageId, collapsed) {
        final rows = _unfoldedRows.putIfAbsent(_stageKey(target), () => {});
        if (collapsed) {
          rows.remove(messageId);
        } else {
          rows.add(messageId);
        }
      },
      // The suggestions sit with the messages they answer. The panel places
      // them and never learns what they are.
      suggestionFor: cardFor,
      // An invite or a cancellation carries its meeting under it. Opened from
      // the thread beside, the event goes ON that thread, so its ✕ comes back.
      meetingCardFor: (m) => showsMeetingCard(m)
          ? MeetingCardHost(
              message: m,
              onOpenEvent: (id) => _openEvent(id, push: inSidePanel),
              onOpenLink: (url) => unawaited(_launchExternal(url)),
              actionsFor: (target, shown) => _cardActions(target, shown),
            )
          : null,
      // The same path `e` takes, named on this panel's own thread: one dismiss
      // in the app, with one undo and one auto-advance behind it, rather than a
      // button that quietly does less than the key.
      onMarkDone: () => unawaited(_triageAndAdvance(
        _dismissThread,
        on: (source: selected.source, key: selected.id),
      )),
      // The picker strip, and the two affordances that open it. The panel
      // draws the strip whenever the one request names ITS thread — which is
      // how `l` and `Shift+E` land here — and every callback re-reads that
      // request at press time, so a strip the reader left open across an
      // auto-advance answers for the thread it is on, never a stale one.
      labels: ref.watch(labelsProvider).labels,
      labelPicker: _pickerModeFor(selected.source, selected.id),
      onOpenLabelPicker: (mode) => _requestLabelPicker(
        dismissAfter: mode == LabelPickerMode.dismiss,
        on: (source: selected.source, key: selected.id),
      ),
      onApplyLabel: (label) => unawaited(_applyPickedLabel(
        (source: selected.source, key: selected.id),
        label,
        dismissAfter: _labelPickerRequest?.dismissAfter ?? false,
      )),
      onCreateLabel: (name) => _createAndApplyLabel(
        (source: selected.source, key: selected.id),
        name,
      ),
      onDismissWithoutLabel: () => unawaited(
        _dismissWithoutLabel((source: selected.source, key: selected.id)),
      ),
      onCloseLabelPicker: _clearLabelPickerRequest,
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
              // Quietly — anything typed while the model thinks stays.
              _stageQuietly(target);
              unawaited(notifier.generate());
            }
          : null,
      // The third hover button, and what the CTA banner opens. From a side
      // thread it goes ON that thread, the same rule a file opened from beside
      // follows: the panel shows one thing, and the ✕ gives back the one the
      // question was asked about.
      onWhy: (message) => _openWhy(target, message, push: inSidePanel),
      // The faces: who is on this thread, and what else is live with them.
      // The SAME name resolution the rooms were built with, so a thread whose
      // recipient the sync stored nameless opens the colleague's room rather
      // than a key nothing on the rail is filed under.
      onPeople: () => _openPersonPanel(roomKeyFor(
        selected,
        owner: _ownerRecord,
        names: participantNames(_rows),
      )),
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
      onDropSender: dropAddress?.isNotEmpty == true
          ? () => _dropSender(dropAddress!, selected.source)
          : null,
      onKeepInInbox: () => _keepThread(selected.source, selected.id),
      // The action bar's Later: THIS thread, on the path `s` takes, with its
      // advance and its undo. The sender-wide deferral above stays in the ⋯.
      onLaterThread: () => unawaited(_triageAndAdvance(
        _laterThread,
        on: (source: selected.source, key: selected.id),
      )),
      onRemoveLabel: (label) => unawaited(_removeLabel(
        (source: selected.source, key: selected.id),
        label,
      )),
      onFindLabel: _findLabel,
      // Compose is a whole pane, which a thread being read BESIDE something
      // else has no business opening: the ✕ and the ⤢ are the two ways out of
      // the side panel.
      onCompose: inSidePanel ? null : () => unawaited(_composeFrom(selected)),
      // Only on a thread asking for a time. From the thread BESIDE too — a
      // Needs You row opens beside — where it moves the thread into the main
      // column and opens the pane there ([_openFindTime]), as Find a time
      // always takes the main pane.
      onFindTime: (ref.watch(schedulingAsksProvider).valueOrNull ?? const {})
              .contains(schedulingAskKey(selected.source, selected.id))
          ? () => _openFindTime(selected.source, selected.id)
          : null,
      // Opening a file always lands on the split, never on the full pane the
      // user may have left open for the last one. From the MAIN thread it is a
      // selection like any other and replaces whatever was beside; from the
      // thread BESIDE it goes on top of this very thread, so the ✕ hands the
      // conversation back with its scroll, its unfolded rows and its
      // half-typed reply rather than dismissing the panel.
      //
      // The origin ALWAYS rides along, reply box or not: it is what a pin
      // resolves its storyline through, and a chat this build cannot send to
      // is still the thread the file came from. Whether 'Use in reply' is
      // offered is the file panel's own capability check, not this one's.
      onOpenAttachment: (attachment) => _openBeside(
        FilePanel(attachment: attachment, from: target),
        push: inSidePanel,
      ),
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
      onWhatHappened: (message) =>
          _openHistory(message.source, message.id, push: inSidePanel),
      // Offered from a side thread too: the panel REPLACES that thread, the
      // rule Why already follows. The room's name is the thread panel's own
      // naming rule — a chat carries no subject and is named by who is on it.
      onContext: () => _openContextFor(
        ContextScopeKind.thread,
        target.source,
        target.conversationKey,
        _roomNameFor(selected),
      ),
      // Zero for the frame before the read lands, which reads as `Context`
      // and becomes `Context · 1` when it arrives.
      contextLinked: ref
              .watch(contextLinksProvider((
                kind: ContextScopeKind.thread,
                source: target.source,
                scopeKey: target.conversationKey,
              )))
              .valueOrNull
              ?.length ??
          0,
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
  ///
  /// Two things wrap every one of them. Escape is the ✕ from the keyboard,
  /// bound HERE and not on the screen so that it belongs to the panel while
  /// the reader is in it — `FindField`'s own arrangement, and the reason
  /// Escape in the main pane's composer still means whatever that means. And
  /// the panel's own [PageStorage] bucket is what lets a transcript pushed
  /// under a file come back at the offset it was left at.
  Widget _sidePanel(SidePanel side) {
    final panel = switch (side) {
      FilePanel() => _filePanel(side),
      ThreadPanel() => _threadPanel(side),
      PersonPanel() => _personPanel(side),
      WhyPanel() => _whyPanel(side),
      HistoryPanel() => _historyPanel(side),
      ContextPanel() => _contextPanel(side),
      ContextFilePanel() => _contextFilePanel(side),
      CheatSheetPanel() => _cheatSheetPanel(),
      EventPanel() => _eventPanel(side),
    };
    return PageStorage(
      bucket: _sideStorage,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _closeSide,
        },
        // Skipped in traversal: this node is here to hold focus for the
        // binding above it, and Tab landing on a panel's edge would be a stop
        // with nothing in it.
        child: Focus(
          focusNode: _sidePanelFocus,
          skipTraversal: true,
          child: Listener(
            onPointerDown: (_) {
              if (!_sidePanelFocus.hasFocus) _sidePanelFocus.requestFocus();
            },
            child: panel,
          ),
        ),
      ),
    );
  }

  /// One meeting, read beside whatever named it.
  ///
  /// The event is resolved from the mirror first and by a live read outside
  /// it (`eventByIdProvider`); its conversations come from the messages that
  /// name it, named here by what the list already calls them, with the
  /// storyline each is filed in. The overlaps are worked out against the day
  /// of the occurrence the panel SHOWS — the next one, for a series — because
  /// that is the slot the reader is deciding about.
  ///
  /// Until the zone has resolved a found event has no honest time to print,
  /// so the body says it is still reading; the other answers are sentences
  /// and need no zone. No ⤢: a meeting is a card's worth of facts, and the
  /// threads it links to open beside it, on top, with the ✕ to come back.
  Widget _eventPanel(EventPanel side) {
    final lookup = ref.watch(eventByIdProvider(side.eventId)).valueOrNull;
    final zoneRead = ref.watch(calendarZoneProvider).valueOrNull;
    final found = lookup != null && lookup.isFound && lookup.event != null;
    final zone = zoneRead ?? CalendarZone.utc();
    final now = DateTime.now();
    final today = zone.dateOf(now.toUtc());
    final links = ref.watch(eventLinksProvider(side.eventId)).valueOrNull ??
        const <EventLink>[];

    Overlaps? overlaps;
    // The occurrence the panel shows: a series master's next meeting. Moves
    // and proposals act on it; answers and cancels go to the master.
    final shown = found
        ? displayOccurrence(
            lookup.event!,
            lookup.occurrences,
            now.toUtc(),
            zone,
          )
        : null;
    if (shown != null && zoneRead != null) {
      final start = shown.startUtc;
      if (shown.isTimed && !shown.isCancelled && start != null) {
        final events =
            ref.watch(dayEventsProvider(zone.dateOf(start))).valueOrNull;
        if (events != null) {
          overlaps = overlapsForEvent(shown, events, zone: zone);
        }
      }
    }

    final subject = found ? lookup.event!.subject.trim() : '';
    return SidePanelHost(
      title: found ? (subject.isEmpty ? '(no subject)' : subject) : 'Meeting',
      leading: const Icon(Icons.event_outlined, size: 18),
      onClose: _closeSide,
      onBack: _sideBack,
      backLabel: _sideBackLabel,
      child: EventPanelBody(
        // A found event with no zone yet reads as still loading.
        lookup: found && zoneRead == null ? null : lookup,
        availability: ref.watch(calendarAvailabilityProvider),
        zone: zone,
        now: now,
        today: today,
        overlaps: overlaps,
        links: [
          for (final link in links)
            link.withView(
              title: _conversationFor(link.source, link.conversationKey) != null
                  ? _threadLabelFor(link.source, link.conversationKey)
                  : link.title,
              storylineTitle: link.storylineId == null
                  ? null
                  : _storylineById(link.storylineId!)?.title,
            ),
        ],
        onOpenLink: (url) => unawaited(_launchExternal(url)),
        onOpenThread: (source, key) =>
            _openThreadBeside(source, key, push: true),
        onOpenStoryline: _selectStoryline,
        onOpenSettings: _openSettings,
        brief: _briefFor(shown, zone: zoneRead, now: now),
        actions: shown == null || zoneRead == null
            ? null
            : CalendarWriteFlow(
                key: ValueKey('event-write-${side.eventId}'),
                writer: ref.read(calendarWritesProvider),
                onDone: _calendarWriteDone,
                onFailed: _calendarWriteFailed,
                builder: (context, start, busy) => EventActions(
                  // Keyed by the occurrence on display, so an open field
                  // typed against one occurrence never stands over the next.
                  key: ValueKey(shown.id),
                  target: lookup!.event!,
                  shown: shown,
                  zone: zone,
                  clock: DateTime.now,
                  today: today,
                  start: start,
                  busy: busy,
                ),
              ),
        // Unreachable is a kept value, not an error, so it stands until the
        // calendar next changes unless the reader asks again.
        onRetry: () {
          ref.invalidate(eventByIdProvider(side.eventId));
          ref.invalidate(eventLinksProvider(side.eventId));
        },
      ),
    );
  }

  /// The event panel's Brief section for the occurrence on display, or null
  /// when there is nothing to brief: no event yet, no zone yet, or a meeting
  /// that is over. A meeting under way keeps its section — the brief is
  /// still worth a glance while it runs.
  ///
  /// Keyed by the SHOWN occurrence's id, because briefs are: a series opened
  /// by its master reads the next meeting's brief.
  Widget? _briefFor(
    CalendarEvent? shown, {
    required CalendarZone? zone,
    required DateTime now,
  }) {
    if (shown == null || zone == null) return null;
    final nowUtc = now.toUtc();
    final end = shown.isAllDay
        ? (shown.endDate == null
            ? null
            : zone.localDateTime(shown.endDate!, 0, 0).toUtc())
        : shown.endUtc;
    if (end == null || !end.isAfter(nowUtc)) return null;
    // The rules that need no store read, with the owner unknown here: a
    // "no" from them is said, by its reason, when nothing is stored, and a
    // pass is left as "not known" for the planner, which knows the owner, to
    // settle (it records no_mail, no_others and too_many on the row).
    final quick =
        briefQuickCheck(shown, owner: null, now: nowUtc, zone: zone);
    return BriefSection(
      view: ref.watch(eventBriefProvider(shown.id)).valueOrNull,
      eligible: quick == null ? null : false,
      ineligibleReason: quick?.wire,
      now: now,
      onOpenThread: (source, key) =>
          _openThreadBeside(source, key, push: true),
      onRegenerate: () => unawaited(_regenerateBrief(shown.id)),
    );
  }

  /// The keys, read beside the list. No ⤢, for [_whyPanel]'s reason: a short
  /// list does not improve by being given the whole window.
  Widget _cheatSheetPanel() => SidePanelHost(
        title: 'Keyboard shortcuts',
        leading: const Icon(Icons.keyboard_outlined, size: 18),
        onClose: _closeSide,
        onBack: _sideBack,
        backLabel: _sideBackLabel,
        child: const CheatSheetBody(),
      );

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
      onBack: _sideBack,
      backLabel: _sideBackLabel,
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
          decision: facts.decision,
          threshold: threshold,
          now: DateTime.now(),
          // The longer answer, in the same slot: the history replaces this
          // panel, and its ✕ comes back to the transcript, not to here.
          onWhatHappened: () => _openHistory(side.source, side.messageId),
        ),
      ),
    );
  }

  /// Explains one message beside its transcript. From a SIDE thread it goes ON
  /// that thread, which is the same rule a file opened from beside follows: the
  /// panel shows one thing at a time, and the ✕ gives back the thing the
  /// question was asked about.
  void _openWhy(DraftTarget target, Message message, {bool push = false}) =>
      _openBeside(
        WhyPanel(
          source: target.source,
          conversationKey: target.conversationKey,
          messageId: message.id,
        ),
        push: push,
      );

  /// What a thread is CALLED in a panel header's subtitle.
  ///
  /// The thread panel's own naming rule, in one place: a chat carries no
  /// subject, so it is named by who is on it. [_whyPanel] resolves the same
  /// thing from a conversation it looked up; this one has the conversation
  /// already.
  static String _roomNameFor(Conversation selected) {
    final subject = selected.subject ?? '';
    if (subject.isNotEmpty) return subject;
    return [
      for (final participant in selected.participants)
        if (participant.display.isNotEmpty) participant.display,
    ].join(', ');
  }

  /// Which of the owner's directories a room reads, beside that room.
  ///
  /// From a SIDE thread it replaces that thread, the rule every other panel
  /// opened from beside follows: the panel shows one thing.
  void _openContextFor(
    ContextScopeKind kind,
    String source,
    String scopeKey,
    String title,
  ) =>
      _openBeside(ContextPanel(
        kind: kind,
        source: source,
        scopeKey: scopeKey,
        title: title,
      ));

  /// The link panel: the whole library with a switch each, and — on a thread
  /// — what it inherits from its storylines.
  ///
  /// No ⤢, for [_whyPanel]'s reason: this is a short list about one room, and
  /// a list does not improve by being given the whole window.
  Widget _contextPanel(ContextPanel side) {
    final scope = (
      kind: side.kind,
      source: side.source,
      scopeKey: side.scopeKey,
    );
    final library = ref.watch(contextDirectoriesProvider);
    final links = ref.watch(contextLinksProvider(scope));
    // A storyline inherits from nothing, so it is not asked. A thread's
    // inherited list is keyed on the thread, which is exactly the scope's own
    // two halves for a thread.
    final inherited = side.kind == ContextScopeKind.thread
        ? ref.watch(contextInheritedProvider((
            source: side.source,
            conversationKey: side.scopeKey,
          )))
        : null;
    final actions = ref.read(contextDirectoriesActionsProvider);

    Widget message(String text) => Center(
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s24),
            child: Text(
              text,
              style: BondType.small,
              textAlign: TextAlign.center,
            ),
          ),
        );

    // `valueOrNull` and a spinner only on the FIRST read, never `when` — the
    // rule the library section in [_settings] already keeps. Both of these
    // providers watch the activity stream, so every recorded row (the
    // sixty-second sync poll, every work item of a drain) puts them back
    // into `loading` with the previous value still in hand, and `when` draws
    // a spinner over that. A switch replaced by a spinner is a switch that
    // vanishes from under a finger.
    final rows = library.valueOrNull;
    final ids = links.valueOrNull;

    // A read that failed with a previous value in hand keeps drawing the
    // previous value: this panel is re-read once a minute whatever happens,
    // so blanking it costs the reader their switches over something the next
    // event fixes by itself. The failure goes to the log instead.
    if (library.hasError && rows != null) {
      debugPrint('Context panel: kept the last library — ${library.error}');
    }
    if (links.hasError && ids != null) {
      debugPrint('Context panel: kept the last links — ${links.error}');
    }

    final Widget body;
    if (rows == null && library.hasError) {
      body = message('Could not read your directories.');
    } else if (ids == null && links.hasError) {
      body = message('Could not read what this room links.');
    } else if (rows == null || ids == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = ContextPanelBody(
        rows: rows,
        linked: ids.toSet(),
        // The frame before the inherited read lands shows the switches
        // rather than a spinner: the list a person came here to use is
        // already in hand, and the muted lines under it are context.
        inherited: inherited?.valueOrNull ?? const [],
        onToggle: (id, on) => unawaited(actions.setLinked(id, scope, on)),
        onAddDirectory: () => unawaited(
          actions.addDirectoryTo(_fileDialogs, scope),
        ),
        onManage: _openSettings,
        expanded: _expandedContextDirs,
        // Only the open ones are read: a family provider per directory
        // means a closed disclosure costs no query at all.
        files: {
          for (final id in _expandedContextDirs)
            id: ref.watch(contextFilesProvider(id)).valueOrNull ?? const [],
        },
        onToggleFiles: (id) => setState(() {
          if (!_expandedContextDirs.remove(id)) {
            _expandedContextDirs.add(id);
          }
        }),
        // On top of this panel, never instead of it: the Context panel only
        // ever renders BESIDE, so a file opened out of its list is always a
        // step further in and its ✕ is owed the list back — with the `Files ›`
        // disclosures the reader opened to find the file still open.
        onOpenFile: (fileId) => _openBeside(
          ContextFilePanel(
            fileId: fileId,
            // A thread's panel can write a reply; a storyline's cannot,
            // because a storyline is not a room a draft is keyed by.
            from: side.kind == ContextScopeKind.thread
                ? (source: side.source, conversationKey: side.scopeKey)
                : null,
          ),
          push: true,
        ),
        now: DateTime.now(),
      );
    }

    // The title is a constant and the subtitle is the room's own name, so
    // neither moves while a reload is out: a header that flickered back to
    // its default once a minute would read as the panel reopening itself.
    return SidePanelHost(
      title: 'Context',
      subtitle: side.title.isEmpty ? null : side.title,
      leading: const Icon(Icons.folder_open_outlined, size: 18),
      onClose: _closeSide,
      onBack: _sideBack,
      backLabel: _sideBackLabel,
      child: body,
    );
  }

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
      onBack: _sideBack,
      backLabel: _sideBackLabel,
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
      onBack: _sideBack,
      backLabel: _sideBackLabel,
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
        onOpenInBrowser: (page) =>
            unawaited(openHtmlInBrowser(page, bytes: _attachmentBytes)),
        senderIsExternal: _fileSenderIsExternal(side),
      ),
    );
  }

  /// One file of one of the owner's own directories, read beside the room
  /// that named it.
  ///
  /// No ⤢, for [_whyPanel]'s reason and one of its own: this is the owner's
  /// own file opened to answer a question about the room next to it — "where
  /// did that sentence come from" — and taking the room away to show the file
  /// whole is answering a question nobody asked.
  Widget _contextFilePanel(ContextFilePanel side) {
    final async = ref.watch(
      contextFileProvider((fileId: side.fileId, locator: side.locator)),
    );
    final from = side.from;
    // [_filePanel]'s own rung ladder: mail always has a box because it bottoms
    // out at the clipboard, a chat only with the send grant.
    final canReply = from != null &&
        (from.source == 'email' ||
            ref.watch(draftProvider(from)).capability == SendCapability.send);

    // Which directories the room this was opened from actually READS: its own
    // links, plus the ones it inherits from its storylines. The retriever
    // re-checks exactly this before it quotes anything, so a Consult button
    // offered on a directory outside the set would be a button whose file is
    // silently dropped — the caption would be the lie, not the retriever.
    final scoped = <String>{};
    if (from != null) {
      scoped.addAll(ref
              .watch(contextLinksProvider((
                kind: ContextScopeKind.thread,
                source: from.source,
                scopeKey: from.conversationKey,
              )))
              .valueOrNull ??
          const <String>[]);
      final inherited =
          ref.watch(contextInheritedProvider(from)).valueOrNull ?? const [];
      for (final entry in inherited) {
        scoped.add(entry.dirId);
      }
    }

    Widget message(String text) => Center(
          child: Padding(
            padding: const EdgeInsets.all(BondSpacing.s24),
            child: Text(
              text,
              style: BondType.small,
              textAlign: TextAlign.center,
            ),
          ),
        );

    // [_contextPanel]'s rule, and one more of its own: this provider watches
    // the activity stream too, and a `when` here would not only blink the
    // words away but re-run the body's post-frame `ensureVisible` — yanking a
    // reader who had scrolled off the highlight straight back to it, once a
    // minute, for as long as the panel is open.
    final view = async.valueOrNull;
    if (async.hasError && view != null) {
      debugPrint('Context file panel: kept the last read — ${async.error}');
    }

    Widget host({
      required String title,
      String? subtitle,
      required Widget child,
    }) =>
        SidePanelHost(
          title: title,
          subtitle: subtitle,
          leading: const Icon(Icons.folder_open_outlined, size: 18),
          onClose: _closeSide,
          onBack: _sideBack,
          backLabel: _sideBackLabel,
          child: child,
        );

    if (view == null) {
      // `hasValue` and not `isLoading`: a file that came back null once is a
      // file that is gone, and the sentence saying so must not blink to a
      // spinner on every reload behind it.
      final first = !async.hasValue && !async.hasError;
      return host(
        title: 'File',
        child: first
            ? const Center(child: CircularProgressIndicator())
            : message('This file is no longer indexed.'),
      );
    }

    final inScope = scoped.contains(view.dir.id);
    return host(
      title: p.basename(view.file.relPath),
      subtitle: '${view.dir.displayName}/${view.file.relPath}',
      child: ContextFilePanelBody(
        file: view.file,
        dirName: view.dir.displayName,
        text: view.text,
        digest: view.digest,
        locator: side.locator,
        located: view.located,
        onConsult: canReply && inScope
            ? () => _consultContextFile(from, view.file.id)
            : null,
        // The room could have consulted this file but for the link, so the
        // sentence names the switch that would fix it rather than leaving a
        // reader to guess why the button they saw on the last file is gone.
        consultNote: canReply && !inScope
            ? 'Not linked to this room — switch «${view.dir.displayName}» '
                'on under Context to consult it.'
            : null,
        now: DateTime.now(),
      ),
    );
  }

  /// Puts one of the owner's own files into the reply being written for
  /// [from].
  ///
  /// [_useAttachmentInReply]'s body over the other corpus — the same restore
  /// of a thread that was replaced, the same quiet stage, the same focus —
  /// and its four comments explain every line of it. What differs is the
  /// list: a directory file is named by its row id and floats to the front of
  /// what the DIRECTORY retriever quotes.
  void _consultContextFile(DraftTarget from, int fileId) {
    setState(() {
      if (!_isMainThread(from)) _restoreSideThread(from);
    });
    _stageQuietly(from);
    unawaited(
      ref.read(draftProvider(from).notifier).generate(contextFileIds: [fileId]),
    );
    (_isMainThread(from) ? _mainComposerFocus : _sideComposerFocus)
        .requestFocus();
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
      // opened from the thread beside is standing ON it, so the panel unwinds
      // to the thread and the file goes — the draft is what was asked for, and
      // a draft written off screen is nothing happening.
      if (!_isMainThread(from)) _restoreSideThread(from);
    });
    // The reader asked for a draft about this file, so the box is the place it
    // belongs — staged before the generate, so the words land in an open box
    // rather than waiting on a card for a second gesture. Quietly, so a
    // sentence typed while the model thinks is not thrown away by its answer.
    _stageQuietly(from);
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
        onBack: _sideBack,
        backLabel: _sideBackLabel,
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
      onBack: _sideBack,
      backLabel: _sideBackLabel,
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
        onOpenInBrowser: (page) =>
            unawaited(openHtmlInBrowser(page, bytes: _attachmentBytes)),
        senderIsExternal: _fileSenderIsExternal(side),
      ),
    );
  }

  /// External for a file, by the yardstick every other surface uses: the
  /// newest KEPT inbound sender of the thread it was opened from —
  /// `Conversation.latestInboundFrom`, the same stored answer the list row
  /// and `is:external` read, so the preview's caution cannot strengthen on a
  /// gated `noreply@` the row does not tint for. The transcript is only the
  /// fallback when the row is not loaded. A shelf file carries no thread and
  /// reads internal — quiet over unknown.
  bool _fileSenderIsExternal(FilePanel side) {
    final from = side.from;
    if (from == null) return false;
    final row = _conversationFor(from.source, from.conversationKey);
    if (row != null && row.latestInboundFrom != null) {
      return row.isExternalTo(_ownerDomains);
    }
    final thread = ref.watch(threadProvider(from));
    return isExternalAddress(
      _newestInboundSender(
        thread is ThreadLoaded ? thread.messages : const <Message>[],
      ),
      _ownerDomains,
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

  /// A file this app cannot fetch, opened where it actually lives, and a link
  /// in a body opened where it points.
  ///
  /// Web addresses and `mailto:`, nothing else. The url is the SENDER's string
  /// — a Teams card or a reference attachment carries whatever the connector
  /// posted, verbatim — so handing it straight to the operating system would
  /// let a message launch a local application or mount a share behind a button
  /// that says 'Open in Teams'. Every caller that draws a BUTTON already
  /// refuses anything `webUriOf` refuses before drawing it, so the addition of
  /// `mailto:` here reaches only the link spans `LinkedText` painted: a mail
  /// composer, which is where a mail anchor goes. This is the guard behind all
  /// of them.
  Future<void> _launchExternal(String url) async {
    final uri = linkTargetOf(url);
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
      // The pair being written this moment, where the thread has none stored.
      // The per-message bars above show stored options only — a preview
      // belongs where the reader is waiting, which is the end of the
      // transcript.
      streamingOptions: draft.streaming?.options ?? const [],
      // Where a reply is suppressed (an automated sender wrote the newest
      // inbound), the bar offers the notification's own way in instead —
      // "View comment", "Open request" — through the same seam every other
      // link in the app is launched by. The bar itself decides when: only
      // where Suggest is withheld and no options are in hand.
      openIn: draft.openIn,
      onOpenLink: (url) => unawaited(_launchExternal(url)),
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
  /// The FALLBACK, for a draft that recorded no inventory of what went into
  /// its prompt — one written before the `context_json` column existed, or
  /// one written from nothing but the thread. A draft that did record one
  /// replaces this with the caption naming what was read.
  ///
  /// It lives on [DraftProvenance] so that the sentence the caption extends
  /// and the sentence it falls back to cannot drift apart.
  static const String _provenance = DraftProvenance.base;

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
    // Decoded ONCE: the caption and the chips are two readings of the same
    // column, and decoding it twice per build would be two chances to disagree
    // about what the draft read.
    final provenance = DraftProvenance.decode(draft.contextJson);
    // Watched, like the switch below: pointing the Improve stage somewhere
    // else — or clearing it — has to move the button on the next frame.
    final prefs = ref.watch(appPrefsProvider);
    final improveSpec = prefs.specForStage('draft_improve');
    // The caption, plus the sentence only a rewritten draft has. Appended
    // rather than folded into `caption()`, because the provenance sentence is
    // about what the model READ and this is about which model wrote it.
    final caption = provenance?.caption() ?? _provenance;
    final improvedBy = provenance?.improvedBy;

    final composer = Composer(
      // Keyed on the conversation so switching threads builds a fresh field
      // rather than carrying one thread's typed text into another's — and on
      // the send epoch, so a COMPLETED send builds a fresh empty one instead
      // of leaving the sent text armed behind a re-enabled button. The stage
      // sequence is the third: the ✕ has to rebuild an EMPTY field and a card
      // a filled one, and the field's own controller would otherwise keep
      // whatever it was last given. It is a COUNTER and not "is anything
      // staged", deliberately: a draft the reader asked for arrives through
      // the field's own update, which keeps a sentence they typed while
      // waiting — a key that flipped when the draft landed would rebuild the
      // field and lose it.
      key: ValueKey(
        'composer-$conversationKey-${draft.sendEpoch}'
        '-${_stageSeq[_stageKey(target)] ?? 0}',
      ),
      suggestedBody: stagedBody,
      // Above the box and never in it: the words the model is writing this
      // moment, until the stored row stages the finished one.
      streamingBody: draft.streaming?.replyBody,
      focusOnMount:
          focusNode == _sideComposerFocus && _focusSideOnMount == target,
      // What the model actually read, when the handler wrote it down. The
      // decode is tolerant and the `??` covers every way it can say nothing,
      // so a malformed column costs the specific line and not the caption.
      provenance: improvedBy == null
          ? caption
          : '$caption. Improved with '
              '${prefs.specById(improvedBy)?.name ?? 'another target'}',
      // Only the files with an id behind them. A draft written before the id
      // was stored names its files in the caption and opens none of them,
      // which is the right answer rather than a chip that goes nowhere.
      //
      // Capped where the caption caps. The chips are that sentence's names
      // made tappable, so a fourth chip would be a door to a file the sentence
      // above it never named. The take runs BEFORE the id filter for the same
      // reason: it is the first three files the caption named, not the first
      // three that happen to be openable.
      provenanceFiles: [
        for (final file
            in (provenance?.files ?? const []).take(DraftProvenance.maxFiles))
          if (file.fileId != null)
            (
              fileId: file.fileId!,
              dir: file.dir,
              path: file.path,
              locator: file.locator,
            ),
      ],
      onOpenProvenanceFile: (file) => _openBeside(ContextFilePanel(
        fileId: file.fileId,
        locator: file.locator,
        from: target,
      )),
      generating: draft.generating,
      sending: draft.sending,
      capability: draft.capability,
      // Both sources, the callbacks together: on mail a person added is a Cc,
      // on a chat a real mention entity — never a plain-text @Name that
      // notifies nobody (the full decision sits above these props in
      // composer.dart). The channel is what tells the search which people can
      // be sent to at all.
      addedRecipients: draft.addedRecipients,
      canEditRecipients: draft.canEditRecipients,
      onRecipientsChanged: notifier.setAddedRecipients,
      recipientSearch: (query) => ref.read(recipientSearchProvider).search(
            query,
            channel: target.source == 'teams'
                ? RecipientChannel.teams
                : RecipientChannel.mail,
          ),
      recipientPhotos: ref.watch(profilePhotosProvider),
      recipientChannel: target.source == 'teams'
          ? RecipientChannel.teams
          : RecipientChannel.mail,
      // Teams notifies only a chat's members, so a person the stored roster
      // is known not to hold is refused at the pick. Read at the pick, not
      // watched: the roster is whatever the list holds when they reach.
      refuseRecipient: target.source != 'teams'
          ? null
          : (person) {
              final chat = _loadedRow(
                (source: target.source, key: target.conversationKey),
              );
              if (chat == null || !teamsRosterLacks(chat, person.id)) {
                return null;
              }
              final name = person.displayName.isNotEmpty
                  ? person.displayName
                  : 'That person';
              return '$name is not in this chat, so a mention would not '
                  'reach them. Start a new chat to include them.';
            },
      onSend: (body) => _send(target, body),
      // Both sources, unconditionally. A chat is drafted through the same
      // queue and the same system prompt a mail is — only the channel's style
      // rules differ, and those ride in the user message — so Regenerate means
      // exactly the same thing on either kind of thread.
      // Staged FIRST, then asked for: the reader pressed a button to get words
      // in this box, so the box has to be listening when they arrive. Quietly:
      // whatever they type while the model thinks outranks what it writes.
      onGenerate: () {
        _stageQuietly(target);
        notifier.generate();
      },
      // Hidden until the stage is routed, which is decision 10's default:
      // nothing leaves this machine because a button was there to press.
      improveLabel:
          improveSpec == null ? null : 'Improve with ${improveSpec.name}',
      // Staged first, for the reason Draft reply is: the rewritten row lands
      // in the box the reader is looking at.
      onImprove: () {
        _stageQuietly(target);
        unawaited(notifier.improve());
      },
      improving: draft.improving,
      // The ✕ empties the BOX and nothing else. The suggestion is not thrown
      // away by closing the thing it was copied into — deleting one is still
      // the card's own ×, with its two-step confirm.
      onDismiss: () => _unstage(target),
      onEdited: notifier.markEdited,
      hint: hint,
      // Watched, not read: the button has to come back the moment the switch
      // at the top of the rail does.
      processingOff: !ref.watch(processingProvider),
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
        // Not red: the act worked, and this is its limit rather than a retry.
        if (draft.notice != null) ...[
          InlineAlert(
            severity: InlineAlertSeverity.attention,
            text: draft.notice!,
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
  ///
  /// [replyTo] is a caller that already knows which message is being answered
  /// — a suggestion card, which hangs under one message and means that one.
  ///
  /// With `replySendMarksDone` on, a sent reply on a thread of the Needs You
  /// pile is marked done through [_triageAndAdvance], so the reader lands on
  /// the next row and the progress line counts it; a thread from anywhere else
  /// is marked done in place and left open.
  Future<void> _send(DraftTarget target, String body, {String? replyTo}) async {
    // An explicit message outranks the pane's own caption: a card sends the
    // reply to the message it was drawn under, whatever the box above it was
    // pointed at. Failing that, only this pane's own override — a message
    // named in the thread beside must not steer a send from the main pane.
    final replyToId =
        replyTo ?? (_replyTo?.target == target ? _replyTo!.messageId : null);
    final outcome = await ref
        .read(draftProvider(target).notifier)
        .send(body, replyTo: replyToId);
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
        // The one read of the preference, here so the thread composer and the
        // in-list box clear the same way. Only a real send: a copy or an
        // Outlook save is a reply that has not gone anywhere yet, and `done`
        // on its strength would clear a thread that is still the reader's.
        final prefs = ref.read(appPrefsProvider);
        if (prefs.replySendMarksDone) {
          final thread = (source: target.source, key: target.conversationKey);
          // The reply went out whatever happens here, so the bar always says
          // so. A null [MarkDoneUndo] is a state write that failed: the bar
          // says the thread is not done, with no Undo, and on the pile path
          // [_triageAndAdvance] reads the false and does not move the reader.
          Future<bool> markDone(({String source, String key}) t) async {
            final conversations = ref.read(conversationsProvider.notifier);
            final undo = await conversations.markDone(t.source, t.key);
            if (!mounted) return undo != null;
            if (undo == null) {
              _toast("Reply sent. Couldn't mark it done.");
              return false;
            }
            _toast(
              'Reply sent · Marked done.',
              onUndo: () => unawaited(conversations.undoMarkDone(undo)),
            );
            return true;
          }

          // A thread of the pile — still drawn, or remembered where it stood
          // after the send took it off — is cleared the way `e` clears it:
          // [_triageAndAdvance], for the landing and the progress count. One
          // from anywhere else (Archive, Home) is marked done where it stands
          // and stays open, since there is no pile under it to land on and
          // closing it on the reader would be the only thing the send did.
          // Queued, never dropped, behind an act still running: the box that
          // sent has already gone, and the reply is not done until it is.
          final ofPile = _triageRows(prefs).any(
                (c) => c.id == thread.key && c.source == thread.source,
              ) ||
              _lastPileIds.contains(thread);
          if (ofPile) {
            await _triageAndAdvance(markDone, on: thread, queue: true);
          } else {
            await markDone(thread);
          }
        } else {
          _toast('Reply sent.');
        }
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
        ownerDomains: _ownerDomains,
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
          // The row leaves this pane either way, and while the switch is off
          // nothing behind it moves — the message is restored and its stages
          // are queued, which is a different thing from restored and read.
          // Said only while off: with processing on, the pane shedding the row
          // is the whole answer.
          if (!ref.read(processingProvider)) {
            _toast('Queued until processing is on.');
          }
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
    // Its own early return, on the same precedent: the directory has a filter
    // box, a pill row and an order control above its list, so it is a column
    // rather than a `(label, rows)` pair the list pane could draw.
    if (section == RailSection.people) return _peopleDirectory();

    // Unreachable: [_main] routes Home, Drafts & sent, Day and AI to their own
    // panes, and every stop with an overview returned above. Nothing rather
    // than a throw, so a stop added without an arm here draws an empty pane
    // and not a red screen.
    return const SizedBox.shrink();
  }

  /// Everyone, one row each. The People stop's landing: a directory, not the
  /// flat thread list — a person is the unit here, and a row opens their room
  /// in MAIN (the rail's People row does the same).
  ///
  /// [_rooms] and not a fresh grouping: it was written by [_body] earlier in
  /// this same build, from the same source-filtered list the rail was handed,
  /// so the directory and the column can never disagree about who is here.
  Widget _peopleDirectory() => PeopleDirectoryPane(
        rooms: _rooms,
        filter: _peopleFilter,
        onFilter: (f) => setState(() => _peopleFilter = f),
        sort: ref.watch(appPrefsProvider).peopleSort,
        onSort: (s) =>
            unawaited(ref.read(appPrefsProvider.notifier).setPeopleSort(s)),
        searchController: _peopleSearchText,
        onSearch: (text) => setState(() => _peopleNeedle = normalizeFind(text)),
        needle: _peopleNeedle,
        now: DateTime.now(),
        photos: ref.read(profilePhotosProvider),
        onOpen: _selectRoom,
        emptyNotice: _scopeNotice(),
      );

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

  /// Needs You, under five lenses and in the reader's own order.
  ///
  /// [NeedsYouTab.all] is the list the rail's badge counts, at the rail's own
  /// threshold and in the rail's own order — so the `+N more` row opens the
  /// list it promised. The other four filter that same list rather than
  /// re-deriving one: the ranking was decided once, and a tab that re-read the
  /// store would eventually rank differently from the column beside it. The
  /// order control sits beside the pills and changes the pile everywhere,
  /// because the rail, this list and Enter are three views of one thing.
  ///
  /// A row here opens BESIDE rather than taking the main pane. This overview
  /// is a room the reader is standing in, the way a storyline's spine is: the
  /// list is what they are working through, and swapping it out for the first
  /// thread they opened would cost them their place. ⤢ on the panel is how a
  /// thread gets the whole pane when it deserves it.
  ///
  /// Its own method rather than an arm of the switch below, on the archive
  /// arm's precedent: the pills sit ABOVE the list, so this returns a column
  /// and not a `(label, rows)` pair.
  Widget _needsYouOverview(List<Conversation> conversations) {
    final tab = _needsYouTab;
    final prefs = ref.watch(appPrefsProvider);
    final sort = prefs.needsYouSort;
    // Watched, so a label created in the picker is a pill here on the same
    // frame; the pile itself already re-reads through the provider's announce.
    final labels = ref.watch(labelsProvider).labels;
    // [_triageRows] and not a derivation of its own: the keys advance down THIS
    // list, and two readings of it is how `e` would land the reader somewhere
    // other than the row under the one they cleared.
    final rows = _triageRows(prefs);
    // The total, taken once — see [_pileAtSessionStart]. A bare field write:
    // it is read two statements down in this same build, and nothing else
    // draws it until then.
    if (rows.isNotEmpty) _pileAtSessionStart ??= rows.length;
    // The one open box's draft, watched HERE so the box redraws as its send
    // moves: the pane's row callback answers synchronously mid-build and must
    // not register a watch of its own.
    final quickReplyOn = _quickReplyFor;
    QuickReply? quickReply;
    if (quickReplyOn != null) {
      final d = ref.watch(draftProvider(
        (source: quickReplyOn.source, conversationKey: quickReplyOn.key),
      ));
      quickReply = QuickReply(
        body: d.body ?? '',
        sending: d.sending,
        error: d.error,
        notice: d.notice,
        // Staged in the thread composer, riding the same draft out of this
        // box — the count is what keeps that from being a silent Cc, or on a
        // chat a silent mention.
        addedRecipients: d.addedRecipients.length,
        mentionsNotCc: quickReplyOn.source == 'teams',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          // The pills wrap on a narrow pane, and the control belongs with
          // their FIRST line rather than centred against however many there
          // turned out to be.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: BondFilterPillRow<NeedsYouTab>(
                key: const Key('needs-you-tabs'),
                options: NeedsYouTab.values,
                selected: tab,
                labelOf: (t) => t.label,
                onSelected: (t) => setState(() {
                  _needsYouTab = t;
                  // A tab is a different pile — see [_resetPileProgress].
                  _resetPileProgress();
                }),
              ),
            ),
            const SizedBox(width: BondSpacing.s8),
            _needsYouSortControl(sort),
          ],
        ),
        // The label lens, under the tabs it narrows further. Absent until the
        // owner has words: a filter row over an empty vocabulary is a control
        // with nothing to say. No spacer of ours — the row carries its own
        // top padding, being the widget that knows whether it drew at all.
        if (labels.isNotEmpty)
          NeedsYouLabelFilter(
            labels: labels,
            selectedLabelId: _activeNeedsYouLabelId,
            onLabelSelected: (id) => setState(() {
              _needsYouLabelId = id;
              // Narrowing by label is a different pile too.
              _resetPileProgress();
            }),
          ),
        const SizedBox(height: BondSpacing.s12),
        // The bulk bar (12c), pinned over the list rather than in its scroll:
        // a bar that scrolled away would strand the selection it acts on.
        ..._bulkBar(rows, labels),
        Expanded(
          child: ConversationListPane(
            sources: _sources,
            filter: InboxFilter.open,
            conversations: conversations,
            // The thread beside, not the main pane's selection: this list
            // opens rows into the side panel, so what it lights is what is
            // over there.
            selectedId: _threadBeside?.conversationKey,
            selectedSource: _threadBeside?.source,
            // Beside, so the pile the reader is working through stays under
            // their eyes — the same rule a storyline's episode cards follow.
            // ⤢ on the panel hands the thread the whole pane.
            onSelect: _openThreadBeside,
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
            // The hover cluster: the four quick actions, each the SAME path
            // the key takes, named on the row it is drawn against — see
            // [_triageAndAdvance]'s doc for why a row action must say whose
            // row it is.
            onDismiss: (c) => unawaited(_triageAndAdvance(
              _dismissThread,
              on: (source: c.source, key: c.id),
            )),
            onLabel: (c) => _requestLabelPicker(
              dismissAfter: false,
              on: (source: c.source, key: c.id),
            ),
            onLater: (c) => unawaited(_triageAndAdvance(
              _laterThread,
              on: (source: c.source, key: c.id),
            )),
            onDismissSender: (c) => unawaited(_triageAndAdvance(
              _dropSenderForThread,
              on: (source: c.source, key: c.id),
            )),
            // The row-side picker mount. The thread panel's mount answers the
            // same request, so a thread that is open beside yields to it —
            // one request, one picker on screen.
            labels: labels,
            // The tint's yardstick (6a): display-time, off the signed-in
            // account, empty until it resolves — nobody external over a
            // missing answer.
            ownerDomains: _ownerDomains,
            labelPickerFor: (c) {
              final beside = _threadBeside;
              if (beside != null &&
                  beside.source == c.source &&
                  beside.conversationKey == c.id) {
                return null;
              }
              return _pickerModeFor(c.source, c.id);
            },
            onApplyLabel: (c, label) => unawaited(_applyPickedLabel(
              (source: c.source, key: c.id),
              label,
              dismissAfter: _labelPickerRequest?.dismissAfter ?? false,
            )),
            onCreateLabel: (c, name) => _createAndApplyLabel(
              (source: c.source, key: c.id),
              name,
            ),
            onDismissWithoutLabel: (c) => unawaited(
              _dismissWithoutLabel((source: c.source, key: c.id)),
            ),
            onCloseLabelPicker: (_) => _clearLabelPickerRequest(),
            // The session's line (12g): the pane draws it only when both
            // numbers are above zero, so a fresh sit-down shows nothing.
            progress: (
              cleared: _clearedThisSession,
              total: _pileAtSessionStart ?? 0,
            ),
            // The in-list box (12f): drawn only on the row `r` named, fed by
            // the draft watched above.
            quickReplyFor: (c) => quickReplyOn != null &&
                    quickReplyOn.source == c.source &&
                    quickReplyOn.key == c.id
                ? quickReply
                : null,
            // The future itself, not `unawaited`: the box releases its send
            // latch when it settles — see [ConversationListPane.onQuickReplySend].
            onQuickReplySend: (c, body) =>
                _sendQuickReply((source: c.source, key: c.id), body),
            onCloseQuickReply: (_) => _clearQuickReply(),
            // The selection gutter (12c): the boxes only — the set, the anchor
            // and every act on them are this screen's.
            checked: {..._checked},
            onToggleChecked: _toggleChecked,
          ),
        ),
      ],
    );
  }

  /// How the Needs You pile is ordered, as a quiet menu rather than a sixth
  /// pill: the pills are lenses on the pile and this is the pile's own order,
  /// and a control that looked like a tab would read as one.
  ///
  /// It writes the preference rather than any local state, because the rail
  /// and Enter read the same value — changing the order here is a statement
  /// about Needs You, not about this pane. [SortMenu] is the shape it is
  /// drawn in, shared with the People directory and a person's room.
  Widget _needsYouSortControl(NeedsYouSort sort) => SortMenu<NeedsYouSort>(
        key: const Key('needs-you-sort'),
        value: sort,
        options: NeedsYouSort.values,
        labelOf: (o) => o.label,
        itemKeyFor: (o) => Key('needs-you-sort-${o.name}'),
        onChanged: (value) => unawaited(
          ref.read(appPrefsProvider.notifier).setNeedsYouSort(value),
        ),
      );

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
  ///
  /// The possible storylines come last, after the live ones, each saying what
  /// it is: a group the model found and would not vouch for. They carry the
  /// same two answers, because the rail's fold is a narrow place to decide
  /// something and this pane has room to show the counts.
  Widget _storylinesOverview() {
    final storylines = [
      ...storylineRows(_scopedStorylines()),
      ..._scopedPossible(),
    ];
    if (storylines.isEmpty) {
      // A pill emptied this pane, rather than the model never having grouped
      // anything: say which half is showing and offer the way back, the same
      // line every other narrowed pane ends with.
      final notice = (_storylines().isEmpty && _possibleStorylines().isEmpty)
          ? null
          : _scopeNotice();
      if (notice != null) return Center(child: notice);
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
                              ? NameStorylineTask.fallbackTitle
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
                        // Only on the rows nobody vouched for, and beside the
                        // suggestion's silence rather than in place of it: a
                        // suggestion is the model offering a group, and this
                        // is the model admitting it could not tell.
                        if (storyline.isPossible) ...[
                          const SizedBox(height: 2),
                          Text(
                            possibleStorylineCaption,
                            key: possibleStorylineCaptionKeyFor(storyline.id),
                            style: BondType.caption,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (storyline.isSuggested || storyline.isPossible) ...[
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
