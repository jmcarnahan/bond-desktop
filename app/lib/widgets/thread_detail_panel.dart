import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/attachment_models.dart';
import '../models/label_models.dart';
import '../models/message_models.dart';
import '../models/open_asks.dart';
import '../services/decision/needs_you_predicate.dart';
import '../services/external_sender.dart';
import '../services/mention_index.dart';
import '../services/profile_photos.dart';
import '../services/sender_display.dart';
import '../theme/tokens.dart';
import 'app_rail.dart' show isNeedsYou;
import 'attachment_card.dart';
import 'attachment_format.dart';
import 'bot_run_row.dart';
import 'chips.dart';
import 'hover_actions.dart';
import 'inline_alert.dart';
import 'label_picker.dart';
import 'link_unfurl.dart';
import 'linked_text.dart';
import 'mention_navigator.dart';
import 'message_row.dart';
import 'needs_you_reason.dart';
import 'preview/preview_kind.dart';
import 'room_header.dart';
import 'thread_action_bar.dart';
import 'time_format.dart';
import 'triage_intents.dart';

/// The two halves of a thread: what was said, and what came with it.
enum ThreadTab { messages, files }

/// The kinds that live somewhere else rather than on the message — drawn as
/// unfurls on the Files tab exactly as they are in the transcript.
const Set<String> _linkKinds = linkAttachmentKinds;

/// Every file this thread carried, newest message first.
///
/// DERIVED from the transcript rather than queried. `MessageStore.loadThread`
/// loads the WHOLE thread with no limit and hydrates every message's
/// attachments, so the list is already in hand; a second query would be a
/// second answer to one question, with a loading state the transcript beside
/// it never has and a window in which the tab's count and the tab's contents
/// disagree.
///
/// Inline images are left out: a signature logo is not a file anybody sent,
/// which is the same rule the Documents shelf and the row's own fold count
/// follow. Quote-replies are left out for a stronger reason — a
/// `message_reference` is not a file at all, it is a piece of this same
/// transcript (`quoteAttachmentKind`), and counting one would put a thread with
/// no files under a `Files (1)` tab whose single row had no name.
///
/// Messages arrive oldest-first, so the walk is reversed; within one message
/// the connector's own `ordinal` is the order, because that is the order the
/// sender attached them in.
List<AttachmentRef> threadFiles(List<Message> messages) {
  final files = <AttachmentRef>[];
  for (final message in messages.reversed) {
    final carried = [
      for (final attachment in message.attachments)
        if (!attachment.isInline && !attachment.isQuoteReply) attachment,
    ]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    files.addAll(carried);
  }
  return files;
}

/// A handle on the open transcript's jumps, for a host whose keys are bound
/// ABOVE the panel.
///
/// The panel answers [NextMentionIntent] and [PreviousMentionIntent] itself, so
/// the navigator's arrows and anything else inside the thread work with nothing
/// wired. A KEY cannot take that path: a key event is dispatched from the
/// primary focus, and in the inbox the focus lives on the region that holds the
/// list and the detail — above this panel — so the screen's own `Actions` entry
/// is what answers, and it needs somewhere to send the request. This is that
/// somewhere.
///
/// Held by the host, handed in as [ThreadDetailPanel.jumps], and attached by the
/// panel for as long as one is mounted. Every method is a no-op while nothing is
/// attached, which is what a key pressed on the list with no thread open means.
class TranscriptJumps {
  _ThreadDetailPanelState? _panel;

  /// Whether a transcript is listening. The host has no reason to ask before
  /// calling — the calls are already no-ops — but a control that draws itself
  /// from this does.
  bool get attached => _panel != null;

  /// The next message in the open thread that names the owner, and the one
  /// before it. Both walk the same index the navigator counts and both stop at
  /// the thread's edges.
  void nextMention() => _panel?._stepMention(forward: true);

  void previousMention() => _panel?._stepMention(forward: false);

  /// Scroll to one message by id and flash it. Silent for an id this transcript
  /// never loaded — the host is welcome to ask about a message that scrolled out
  /// of the window it read.
  void toMessage(String messageId) =>
      unawaited(_panel?._jumpToMessage(messageId) ?? Future<void>.value());
}

/// The thread view: the main pane's whole content once a thread is open.
///
/// The transcript reads as one flat column — day dividers, left-aligned
/// messages, runs collapsed under one header — rather than as a chat of
/// facing bubbles.
///
/// It renders a header, the action bar under it, the ask and a transcript, and
/// nothing else: the composer is docked UNDER this panel by the host, which is
/// what keeps the panel ignorant of drafts and sending.
///
/// A thread carrying files wears TABS — Messages and Files (n) — because "where
/// is that attachment" is a question about the whole conversation rather than
/// about any one message in it, and scrolling a transcript is the wrong way to
/// answer it. A thread with no files draws no tab row at all and looks exactly
/// as it always did.
class ThreadDetailPanel extends StatefulWidget {
  final Conversation conversation;
  final List<Message> messages;

  /// Flips the thread to done.
  final VoidCallback onMarkDone;

  /// Puts a done thread back into the working inbox — the same button in the
  /// same place, saying the opposite thing, because a thread the user closed
  /// by mistake is read from here. Null hides it, for a host with nowhere to
  /// put a reopened thread.
  final VoidCallback? onReopen;

  /// Returns to the section overview. Null hides the back affordance, for
  /// layouts where the thread is not something you navigated into.
  final VoidCallback? onBack;

  /// Opens the pane that picks — or names — the storyline this thread goes
  /// into: the action bar's storyline button. It does not list the storylines
  /// itself: the choice is a pane with a way back, because the house rule is
  /// screens rather than popups. Null hides the button, so a host that knows
  /// nothing about storylines renders exactly what it used to.
  final VoidCallback? onAddToStoryline;

  /// Defers this thread's sender — the ⋯'s "Send this sender to Later".
  /// Sender-scoped because that is the correction worth collecting: one
  /// thread going quiet changes one row, a sender going quiet changes the
  /// shape of the inbox. [onLaterThread] is the one-thread deferral. Null
  /// hides the item.
  final VoidCallback? onSendToLater;

  /// Stops this thread's sender reaching the model at all — a gate the owner
  /// writes rather than one the app guessed. Sender-scoped like
  /// [onSendToLater] and a step past it: Later quiets what is already here,
  /// this refuses what comes next. Null hides the item.
  final VoidCallback? onDropSender;

  /// Brings a deferred thread back: the action bar's Keep in inbox, in Later's
  /// place. Only shown when the thread is actually in a bucket — an "undo" for
  /// something that never happened is a button that reads as broken.
  final VoidCallback? onKeepInInbox;

  /// Defers THIS thread — the action bar's Later, and the `s` key's path. The
  /// sender-wide [onSendToLater] stays in the ⋯, where the corrections about
  /// a sender live. Null hides the button.
  final VoidCallback? onLaterThread;

  /// The owner's "Remove from Needs You" / "Add to Needs You" on this thread
  /// — the action bar draws whichever the thread's place calls for, by the
  /// rail's own rule ([isNeedsYou] at [needsYouThreshold]). Null hides it.
  final VoidCallback? onRemoveFromNeedsYou;
  final VoidCallback? onAddToNeedsYou;

  /// Takes one label off this thread (the chip's ✕). Null draws chips with no
  /// ✕.
  final void Function(Label label)? onRemoveLabel;

  /// Finds every thread under one label (the chip's name). Null draws chips
  /// that do not answer a tap.
  final void Function(Label label)? onFindLabel;

  /// Rendered at the END of the transcript, inside the same scroll view and
  /// indented to the message body column, so it reads as attached to the last
  /// message rather than parked under the pane.
  ///
  /// Hosts pass the reply affordance here. The panel does not know what it is
  /// and does not ask — it renders a transcript and knows nothing about drafts
  /// or sending, which is the arrangement the composer already lives under.
  final Widget? afterTranscript;

  /// The answer offered to one message, drawn under it. Null — for a message or
  /// altogether — means there is nothing to draw there.
  ///
  /// A builder rather than a list, for the same reason [afterTranscript] is a
  /// widget: the panel renders a transcript and knows nothing about drafts. It
  /// asks the host per message and places whatever comes back.
  final Widget? Function(Message message)? suggestionFor;

  /// Brings the composer forward. The box is always docked under a thread that
  /// can be answered, so this is a focus rather than an opening — but every ask
  /// on this pane, the banner and each message's own line, is still a call to
  /// action, and each one has to put the cursor where the answer goes. Null
  /// leaves them all as statements, for a host with no box under it.
  final VoidCallback? onOpenReply;

  /// The hover strip's **Reply**: this message is the one being answered. Null
  /// leaves the button off the strip, for a host that cannot reply here.
  final void Function(Message message)? onReplyTo;

  /// The hover strip's **Suggest a reply**: draft an answer to this message.
  /// Null leaves the button off the strip.
  final void Function(Message message)? onSuggestFor;

  /// The hover strip's **Why**, and what the CTA banner opens: explain this
  /// message's verdict beside the transcript. Null leaves the button off the
  /// strip and hands the banner back to [onOpenReply].
  final void Function(Message message)? onWhy;

  /// Opens the person beside the thread — what the header's faces do. Null
  /// leaves the stack a picture.
  final VoidCallback? onPeople;

  /// Opens a new message to this thread's people. What that means is the
  /// host's business — a chat is addressed as itself, a mail thread as its
  /// participants — and the panel neither knows nor asks. Null hides the
  /// button, for a host with no compose to open.
  final VoidCallback? onCompose;

  /// What opening one of the thread's files does. Null leaves every chip and
  /// picture in the transcript a statement — the panel has nowhere of its own
  /// to show a file, and never invents one.
  final void Function(AttachmentRef attachment)? onOpenAttachment;

  /// The file the host is previewing, so the row that carried it can say so.
  /// Passed straight down; the comparison is `sameAttachment`, never `==`.
  final AttachmentRef? selectedAttachment;

  /// The picture for an attachment, or null while there is none. An
  /// [ImageProvider] rather than bytes or a path — see [MessageRow.thumbnailFor].
  final ImageProvider? Function(AttachmentRef attachment)? thumbnailFor;

  /// Where each sender's face comes from, passed straight to every row. Null
  /// draws initials and asks nothing.
  final ProfilePhotos? photos;

  /// Puts one of the thread's files into the reply being written — what the
  /// card's hover strip offers, in the transcript and on the Files tab alike.
  /// Null leaves the strip off, for a host with no box under the thread.
  final void Function(AttachmentRef attachment)? onUseInReply;

  /// Hands a link's address to the operating system — the unfurl's `Open link`.
  /// Null draws no button.
  final void Function(String url)? onOpenLink;
  /// Opens one message's own history, from the fourth button on its hover
  /// strip. The panel does not know what a history is: it hands back the
  /// message that was asked about and the host decides where that goes — the
  /// same arrangement [onOpenAttachment] lives under. Null draws no button.
  final void Function(Message message)? onWhatHappened;

  /// Opens the panel naming which of the owner's directories this thread
  /// reads when a reply is drafted in it. Null hides the action — a host with
  /// no library behind it.
  final VoidCallback? onContext;

  /// How many directories this thread links directly: the action bar's
  /// Context icon carries it twice — a small badge, because a count nobody
  /// hovers is a count nobody reads, and the tooltip ("Context · 3").
  /// Inherited storyline links are deliberately not counted here: they are
  /// not this thread's to turn off, and a number that included them would
  /// promise switches the panel does not draw.
  final int contextLinked;

  /// Which of this thread's messages the reader has UNFOLDED, overriding the
  /// fold this panel would otherwise open them with.
  ///
  /// The panel's own rule ([_transcript]) decides what starts folded, and a
  /// `MessageRow` keeps the reader's toggle for as long as it lives. Neither
  /// survives the panel being replaced and built again — a side thread that
  /// went under a file preview — so a host that can lose it keeps the set and
  /// hands it back through here, with [onFoldChanged] to fill it. Empty is
  /// what every other host passes, and renders exactly what it always did.
  final Set<String> unfolded;

  /// Told which message the reader folded or unfolded, and what it became, so
  /// [unfolded] can be kept. Null leaves every fold the row's own business.
  final void Function(String messageId, bool collapsed)? onFoldChanged;

  /// The owner's vocabulary for the inline picker, in the order the picker wants
  /// it (see [LabelPicker.labels]). Empty — the default — is what a host that
  /// knows nothing about labels passes, and draws nothing.
  final List<Label> labels;

  /// Which question the picker under the banner is asking, or null while it is
  /// collapsed.
  ///
  /// HOST-OWNED rather than local state, on purpose: `l` and `Shift+E` live in a
  /// keyboard map outside this panel and have to be able to open the strip, and
  /// an apply has to be able to collapse it in the same step as the write it
  /// caused. The strip draws only when a mode is set AND [onApplyLabel],
  /// [onCreateLabel] and [onCloseLabelPicker] are all wired — a picker that
  /// could not apply what it was asked for is worse than no picker.
  final LabelPickerMode? labelPicker;

  /// Asks the host to open the picker in one of its two modes — what the action
  /// bar's "Mark done with a label" choice and its Add label do. Null hides
  /// both, and Mark done then acts at once rather than offering choices.
  final void Function(LabelPickerMode mode)? onOpenLabelPicker;

  /// An existing label was chosen. The host applies it, and on the dismiss path
  /// marks the thread done in the same call so the two are one undo.
  final void Function(Label label)? onApplyLabel;

  /// A name nothing matched was typed. The host creates it (idempotent on the
  /// trimmed name) and applies what comes back; a future handed back holds the
  /// picker busy until it settles — see [LabelPicker.onCreate].
  final FutureOr<void> Function(String name)? onCreateLabel;

  /// Dismiss with nothing on it. Offered only while [labelPicker] is
  /// [LabelPickerMode.dismiss] — there is nothing to dismiss on the label-only
  /// path — and null takes it away there too.
  final VoidCallback? onDismissWithoutLabel;

  /// Escape, and the strip's own ✕. Sets the host's open state back to null.
  final VoidCallback? onCloseLabelPicker;

  /// The host's handle on this transcript's jumps — see [TranscriptJumps]. Null
  /// is what every host that binds no keys passes, and the navigator's own
  /// arrows still work.
  final TranscriptJumps? jumps;

  /// The owner's own mail domains, for the `External` chip beside the state
  /// chip. Empty — the default — draws no chip, which is the thread every host
  /// that has not resolved the signed-in account yet still gets.
  ///
  /// The question is answered off [messages] here rather than off
  /// [Conversation.latestInboundFrom]: this pane holds the whole transcript, so
  /// the newest inbound message is already in hand, and reading the sender the
  /// reader can SEE at the bottom of the thread is the one way the chip cannot
  /// contradict the pane it sits over. Same rule either way — see
  /// [Conversation.isExternalTo] for what it is and why nothing stores it.
  final Set<String> ownerDomains;

  /// The owner's Needs You slider, for the mention navigator: an action item
  /// on a message the decision model placed below it names nobody
  /// ([namesOwner]). A host with no slider gets the default.
  final double needsYouThreshold;

  const ThreadDetailPanel({
    super.key,
    required this.conversation,
    required this.messages,
    required this.onMarkDone,
    this.onReopen,
    this.onBack,
    this.onAddToStoryline,
    this.needsYouThreshold = NeedsYouTuning.defaultThreshold,
    this.onSendToLater,
    this.onDropSender,
    this.onKeepInInbox,
    this.onLaterThread,
    this.onRemoveFromNeedsYou,
    this.onAddToNeedsYou,
    this.onRemoveLabel,
    this.onFindLabel,
    this.afterTranscript,
    this.suggestionFor,
    this.onOpenReply,
    this.onReplyTo,
    this.onSuggestFor,
    this.onWhy,
    this.onPeople,
    this.onCompose,
    this.onOpenAttachment,
    this.selectedAttachment,
    this.thumbnailFor,
    this.photos,
    this.onUseInReply,
    this.onOpenLink,
    this.onWhatHappened,
    this.onContext,
    this.contextLinked = 0,
    this.unfolded = const <String>{},
    this.onFoldChanged,
    this.labels = const [],
    this.labelPicker,
    this.onOpenLabelPicker,
    this.onApplyLabel,
    this.onCreateLabel,
    this.onDismissWithoutLabel,
    this.onCloseLabelPicker,
    this.jumps,
    this.ownerDomains = const {},
  });

  /// The `External` chip beside the state chip, for a test that wants the chip
  /// in this header rather than the one on a row behind it.
  static const Key externalChipKey = ValueKey('thread-external');

  /// How long an arrived-at row stays lit. Long enough to catch the eye that
  /// was moving, short enough that it is gone before the reader starts reading
  /// — and public so a test can pump past it rather than guess.
  static const Duration flashDuration = Duration(milliseconds: 1200);

  /// The tinted wrapper around a row a jump has just landed on.
  static Key flashKeyFor(String messageId) =>
      ValueKey('transcript-flash-$messageId');

  /// The [BotRunRow] standing for the run whose first message is [firstId].
  static Key botRunKeyFor(String firstId) => ValueKey('bot-run-$firstId');

  @override
  State<ThreadDetailPanel> createState() => _ThreadDetailPanelState();
}

class _ThreadDetailPanelState extends State<ThreadDetailPanel> {
  /// Which half of the thread is showing. Seeded on Messages and kept for the
  /// life of the panel — the storyline's own `_tab` precedent: a reader who
  /// went looking for a file and came back to the words has not asked to be
  /// put back on the Files tab by the next sync.
  ThreadTab _tab = ThreadTab.messages;

  /// Wide enough for a long paragraph, narrow enough that an ultrawide window
  /// does not turn every message into one unreadable line.
  static const double _maxContentWidth = 900;

  /// The transcript's own controller, so a jump can move the list rather than
  /// only asking a built row to show itself.
  final ScrollController _scroll = ScrollController();

  /// One [GlobalKey] per message, minted on demand and kept for the life of the
  /// panel: `Scrollable.ensureVisible` needs the row's own context, and a key
  /// that changed between builds would hand back a context that had just been
  /// discarded.
  final Map<String, GlobalKey> _rowKeys = {};

  /// How many times each row has been jumped to — see
  /// [MessageRow.unfoldRequest]. Counts rather than flags, and never cleared, so
  /// a second jump to a row the reader folded again opens it again.
  final Map<String, int> _unfoldRequests = {};

  /// Which bot runs the reader has opened, keyed by the run's FIRST message id
  /// (see [_botRuns]). Kept for the life of the thread and cleared with
  /// [_unfoldRequests] when the thread changes: a run's first id is only a key
  /// inside the transcript that minted it.
  final Set<String> _openRuns = {};

  /// Which mention the reader is standing on, or null before they have stepped.
  String? _mentionAt;

  /// Which jump is the current one. A far jump can still be retrying (each lap
  /// awaits a frame) when the reader starts a nearer one — `]` autorepeat is
  /// enough — and without a generation check the STALE walk's last scroll
  /// would win the viewport while [_flashId] and the navigator name the new
  /// target. Each entry to [_jumpToMessage] takes the next number; a lap that
  /// wakes to find it is no longer current stops moving the list.
  int _jumpSeq = 0;

  /// The row lit by the jump that just landed, and the timer that puts it out.
  String? _flashId;
  Timer? _flashTimer;

  /// How many times a jump scrolls and looks again before it gives up.
  ///
  /// A row outside the viewport (and outside its cache extent) has no element
  /// and therefore no context, so `ensureVisible` cannot be asked about it at
  /// all. Each attempt scrolls toward where the row is ESTIMATED to be and lets
  /// a frame build; every scroll makes the list's own extent estimate more
  /// accurate, so the walk converges in two or three steps on a normal thread.
  /// The cap is what keeps a thread whose rows are wildly uneven from looping.
  static const int _jumpAttempts = 8;

  /// Where in the viewport an arrived-at row lands: near the top, with a little
  /// of the message above it for context. Dead top would hide what the reader
  /// was answering.
  static const double _jumpAlignment = 0.1;

  /// The tint an arrived-at row wears for [ThreadDetailPanel.flashDuration].
  ///
  /// Not animated, on purpose: the highlight has to be at its brightest the
  /// instant the scroll lands, and a fade-in is faintest exactly when the
  /// reader's eye arrives.
  static const BoxDecoration _flashTint = BoxDecoration(
    color: BondColors.attentionTint,
    borderRadius: BondRadii.smAll,
  );

  /// The panel answers the two mention intents itself, which is what makes the
  /// navigator's arrows work with nothing wired above. A key bound above the
  /// panel takes the other door, [TranscriptJumps] — the same two methods either
  /// way, so there is one implementation of "next mention" and two ways in.
  late final Map<Type, Action<Intent>> _mentionActions = {
    NextMentionIntent: CallbackAction<NextMentionIntent>(
      onInvoke: (_) {
        _stepMention(forward: true);
        return null;
      },
    ),
    PreviousMentionIntent: CallbackAction<PreviousMentionIntent>(
      onInvoke: (_) {
        _stepMention(forward: false);
        return null;
      },
    ),
  };

  @override
  void initState() {
    super.initState();
    widget.jumps?._panel = this;
  }

  @override
  void didUpdateWidget(ThreadDetailPanel old) {
    super.didUpdateWidget(old);
    if (old.jumps != widget.jumps) {
      if (old.jumps?._panel == this) old.jumps?._panel = null;
      widget.jumps?._panel = this;
    }
    // A different thread is a different walk: the stop the reader was on is a
    // message this panel no longer draws. The keys go with it, or the map grows
    // for every thread the reader opens in one session.
    if (old.conversation.id != widget.conversation.id ||
        old.conversation.source != widget.conversation.source) {
      _mentionAt = null;
      _flashTimer?.cancel();
      _flashId = null;
      _rowKeys.clear();
      _unfoldRequests.clear();
      _openRuns.clear();
    }
  }

  @override
  void dispose() {
    if (widget.jumps?._panel == this) widget.jumps?._panel = null;
    _flashTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _rowKeyFor(String messageId) =>
      _rowKeys.putIfAbsent(messageId, GlobalKey.new);

  /// The ids of the messages that name the owner, in transcript order.
  List<String> get _mentions => mentionIndexOf(
        widget.messages,
        threshold: widget.needsYouThreshold,
      );

  /// One step along that index, and the jump that follows it.
  ///
  /// Stops at the ends (see [stepMention]): a press at the last mention leaves
  /// the reader where they are rather than sending them back to the top.
  void _stepMention({required bool forward}) {
    final next = stepMention(_mentions, _mentionAt, forward: forward);
    if (next == null) return;
    setState(() => _mentionAt = next);
    unawaited(_jumpToMessage(next));
  }

  /// Put [messageId] on screen, open, and lit.
  ///
  /// Three things in one act, because a jump that did any two of them would
  /// leave the reader looking at a folded row or at a row they cannot tell from
  /// its neighbours:
  ///
  ///  1. the row is asked to unfold ([MessageRow.unfoldRequest]) and reports the
  ///     unfold back through [ThreadDetailPanel.onFoldChanged], so the host's
  ///     set remembers it if this panel is replaced and built again;
  ///  2. the transcript scrolls to it, retrying for rows the list has not built
  ///     yet (see [_jumpAttempts]);
  ///  3. it wears [_flashTint] for [ThreadDetailPanel.flashDuration].
  ///
  /// Silent for a message this thread never loaded: the reason id on a
  /// conversation and the `content_id` on a quote can both name a message
  /// outside the window that was read, and a jump to nowhere must not throw
  /// under a reader's finger.
  Future<void> _jumpToMessage(String messageId) async {
    if (!_isLoaded(messageId)) return;
    final seq = ++_jumpSeq;
    setState(() {
      _unfoldRequests[messageId] = (_unfoldRequests[messageId] ?? 0) + 1;
      // A target inside a folded bot run has no row until the run opens, and
      // the walk below can only land on a row that exists — so the run opens
      // HERE, in the same frame, before the first lap looks for it.
      for (final run in _botRuns(_mentions.toSet())) {
        if (run.ids.contains(messageId)) _openRuns.add(run.ids.first);
      }
      _flashId = messageId;
      // A jump lands on the transcript whichever tab the reader went looking at
      // files from.
      _tab = ThreadTab.messages;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(ThreadDetailPanel.flashDuration, () {
      if (mounted) setState(() => _flashId = null);
    });

    for (var attempt = 0; attempt < _jumpAttempts; attempt++) {
      // The frame the setState above asked for, and after that the frame each
      // scroll asks for: a row is only reachable once it has been built.
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted || seq != _jumpSeq) return;
      // The row's own context, not this State's, so it carries its own mounted
      // check: the key is kept across builds and can be holding an element the
      // last frame discarded.
      final rowContext = _rowKeys[messageId]?.currentContext;
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(
          rowContext,
          alignment: _jumpAlignment,
          // Instant, matching the hard scrolls that got us here: animating the
          // last hop of a walk that teleported through the thread reads as a
          // glitch rather than as movement.
          duration: Duration.zero,
        );
        return;
      }
      if (!_scroll.hasClients) continue;
      final position = _scroll.position;
      final estimate = _estimatedOffsetFor(messageId, position);
      if (estimate == null) return;
      // Already as close as the estimate can put us and the row still is not
      // built: another identical scroll would not build it either.
      if ((estimate - position.pixels).abs() < 1) return;
      position.jumpTo(estimate);
    }
  }

  /// Whether [messageId] is one of the rows this panel drew.
  bool _isLoaded(String messageId) =>
      messageId.isNotEmpty &&
      widget.messages.any((message) => message.id == messageId);

  /// Roughly where [messageId] sits in the scrollable, read off the list's own
  /// extent estimate.
  ///
  /// A fraction of the way down by MESSAGE INDEX, which is approximate twice
  /// over: rows differ in height and the day dividers are extra children. Both
  /// are why the caller retries rather than trusting one answer — and why the
  /// estimate is re-read each lap, since the list refines its extent as more of
  /// it is built.
  double? _estimatedOffsetFor(String messageId, ScrollPosition position) {
    final index = widget.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return null;
    final min = position.minScrollExtent;
    final max = position.maxScrollExtent;
    if (!min.isFinite || !max.isFinite || max <= min) return null;
    if (widget.messages.length < 2) return min;
    final fraction = index / (widget.messages.length - 1);
    return min + (max - min) * fraction;
  }

  /// The navigator under the header, or nothing at all in a thread that names
  /// the owner nowhere.
  ///
  /// Nothing rather than `@ You · 0`: a control that counts to zero is a control
  /// the reader has to read before learning there is nothing to press. The
  /// position is 1-based off the same index the walk steps along, so the words
  /// and the walk cannot disagree.
  Widget? _mentionStrip() {
    final mentions = _mentions;
    if (mentions.isEmpty) return null;
    final at = _mentionAt == null ? -1 : mentions.indexOf(_mentionAt!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s16,
        BondSpacing.s8,
        BondSpacing.s16,
        0,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: MentionNavigator(
          count: mentions.length,
          position: at < 0 ? null : at + 1,
        ),
      ),
    );
  }

  /// What tapping the `Why:` line does: go to the message the verdict named.
  ///
  /// Null — and so an inert line — when the pipeline named no message, or named
  /// one this read never loaded. Entry 8a's promise was that the reason says
  /// WHICH message; this is the other half, and it is only offered where the app
  /// can keep it.
  VoidCallback? get _toReasonMessage {
    final id = widget.conversation.needsYouReasonMessageId;
    if (id == null || !_isLoaded(id)) return null;
    return () => unawaited(_jumpToMessage(id));
  }

  static String _stateLabel(ConversationState state) => switch (state) {
        ConversationState.needsReply => 'Needs reply',
        ConversationState.waiting => 'Waiting',
        ConversationState.done => 'Done',
      };

  static BondTone _stateTone(ConversationState state) => switch (state) {
        ConversationState.needsReply => BondTone.attention,
        ConversationState.waiting => BondTone.neutral,
        ConversationState.done => BondTone.success,
      };

  /// The gate word `TeamsSync` stamps on an application's message
  /// (`teamsBotGate`), spelled out rather than imported so this widget does not
  /// drag the connector and its store in behind it.
  static const String _botGate = 'auto_generated';

  /// The fewest consecutive bot messages that fold into one [BotRunRow]. Two is
  /// a pair a reader takes in at a glance; the wall starts at three.
  static const int _botRunMin = 3;

  /// The runs of one application's messages this transcript draws as a single
  /// [BotRunRow], each as the index of its first message and every id in it.
  ///
  /// A bot message is one `TeamsSync` gated as [_botGate] in a Teams thread —
  /// the ingest fact, not [isBotSender]'s guess, which a bot with a display name
  /// passes straight through. Mail is excluded outright: the header gate writes
  /// the same word on an auto-reply, and an out-of-office in a mail thread is a
  /// message somebody may need to read.
  ///
  /// A run is consecutive, one sender, and one day — a day divider between two
  /// halves would have nowhere to sit inside one line. A message that names the
  /// owner, or is the one the Why line points at, never joins: it is the reason
  /// the thread is open, and folding it into a count hides the point. A jump to
  /// any other member opens the run instead (see [_jumpToMessage]). Nor does
  /// the thread's LAST message, for the per-message fold's reason: it is what
  /// the thread is about, so a run ending the thread folds all but it — and
  /// nothing at all if that leaves fewer than [_botRunMin].
  List<({int start, List<String> ids})> _botRuns(Set<String> mentions) {
    if (widget.conversation.source != 'teams') return const [];
    final reasonId = widget.conversation.needsYouReasonMessageId;
    final messages = widget.messages;
    bool joins(Message m) =>
        !identical(m, messages.last) &&
        !m.outbound &&
        m.gateReason == _botGate &&
        (m.fromAddress ?? '').isNotEmpty &&
        !mentions.contains(m.id) &&
        m.id != reasonId;

    final runs = <({int start, List<String> ids})>[];
    var i = 0;
    while (i < messages.length) {
      if (!joins(messages[i])) {
        i++;
        continue;
      }
      final head = messages[i];
      var end = i + 1;
      while (end < messages.length &&
          joins(messages[end]) &&
          messages[end].fromAddress!.toLowerCase() ==
              head.fromAddress!.toLowerCase() &&
          dayKeyOf(messages[end]) == dayKeyOf(head)) {
        end++;
      }
      if (end - i >= _botRunMin) {
        runs.add((
          start: i,
          ids: [for (var k = i; k < end; k++) messages[k].id],
        ));
      }
      i = end;
    }
    return runs;
  }

  /// The transcript, flattened: a divider each time the calendar day turns
  /// over, then one row per message with its header suppressed when it
  /// continues the run above it — and one [BotRunRow] in place of each run
  /// [_botRuns] finds, with the run's rows under it only once it is opened.
  List<Widget> _transcript() {
    final items = <Widget>[];
    String? previousDay;
    Message? previous;
    var first = true;

    // One scan of the thread answers the open-ask rule for every row in it.
    // Anything but "needs reply" closes them: without this, a send that clears
    // the banner leaves the ask lines lit for up to a minute until the sent
    // message syncs back.
    final lastOut = latestOutboundAt(widget.messages);
    final closed = widget.conversation.state != ConversationState.needsReply;
    // One scan for the mentions too, and the same answer the navigator counts.
    final mentions = _mentions.toSet();
    final runs = {for (final run in _botRuns(mentions)) run.start: run};

    for (var i = 0; i < widget.messages.length; i++) {
      final message = widget.messages[i];
      final day = dayKeyOf(message);
      final label = formatDayLabel(message.receivedAt);
      if (label != null && (first || day != previousDay)) {
        items.add(DayDivider(label: label));
        // A new day always opens with a full header, however close in time
        // the previous message was.
        previous = null;
      }
      previousDay = day;
      first = false;

      final run = runs[i];
      if (run != null) {
        final runKey = run.ids.first;
        final opened = _openRuns.contains(runKey);
        items.add(BotRunRow(
          key: ThreadDetailPanel.botRunKeyFor(runKey),
          senderName: displaySenderName(
            name: message.fromName,
            address: message.fromAddress,
          ),
          count: run.ids.length,
          expanded: opened,
          onTap: () => setState(() {
            if (!_openRuns.remove(runKey)) _openRuns.add(runKey);
          }),
        ));
        // Whatever follows the line — the run's own first row, or the next
        // sender once a folded run is skipped — opens with a full header.
        previous = null;
        if (!opened) {
          i += run.ids.length - 1;
          continue;
        }
      }

      final open = hasOpenAsk(
        message,
        lastOutboundAt: lastOut,
        conversationClosed: closed,
      );
      final suggestion = widget.suggestionFor?.call(message);
      final header = previous == null || !sameRun(previous, message);
      final next = i + 1 < widget.messages.length ? widget.messages[i + 1] : null;
      // A bot run's line sits between this row and the next, so the next one
      // opens with its own header and this one ends its run.
      final standalone =
          next == null || runs.containsKey(i + 1) || !sameRun(message, next);
      final isLast = identical(message, widget.messages.last);
      // Only a message that is a run all by itself folds, and never the newest
      // one. Folding a run's header while its continuations stayed up would
      // hide half a run and leave the rest of it hanging under no name; and the
      // last message is what the thread is about — a transcript that opens with
      // its point folded away has answered the wrong question.
      final collapsible = header && standalone && !isLast;
      final namesOwner = mentions.contains(message.id);
      final row = MessageRow(
        key: ValueKey(message.id),
        message: message,
        showHeader: header,
        openAsk: open,
        namesOwner: namesOwner,
        unfoldRequest: _unfoldRequests[message.id] ?? 0,
        quoteTapFor: _quoteTapFor,
        // Only a line that is actually on screen gets a tap.
        onAskTap: open ? widget.onOpenReply : null,
        suggestion: suggestion,
        collapsible: collapsible,
        // Folded by default only where there is nothing left to do: history the
        // thread has moved past. An open ask or a live suggestion is the whole
        // reason to scroll back, so neither ever starts hidden — and neither
        // does a run the reader already opened, which is what the host's set
        // remembers across a panel that was replaced and came back.
        //
        // A message that NAMES the owner is the same argument one step earlier:
        // an @mention halfway up a fifty-message chat is why the thread is in
        // Needs You, and a thread that opens with it folded to one muted line
        // has hidden its own point. An answered ask still folds — `open` is
        // false by then — but the marker stays, so the row is still findable.
        //
        // A pending jump counts too: a far row the list has not built yet only
        // sees `unfoldRequest` move via didUpdateWidget, so a row FIRST built
        // mid-jump must read the request here or the jump lands on a fold.
        initiallyCollapsed: collapsible &&
            !open &&
            !namesOwner &&
            suggestion == null &&
            !widget.unfolded.contains(message.id) &&
            !_unfoldRequests.containsKey(message.id),
        onFoldChanged: widget.onFoldChanged == null
            ? null
            : (collapsed) => widget.onFoldChanged!(message.id, collapsed),
        onOpenAttachment: widget.onOpenAttachment,
        selectedAttachment: widget.selectedAttachment,
        thumbnailFor: widget.thumbnailFor,
        photos: widget.photos,
        onUseInReply: widget.onUseInReply,
        onOpenLink: widget.onOpenLink,
      );
      // Only what is being ANSWERED wears the strip. There is nothing to reply
      // to on the user's own message, and nothing to draft an answer to either.
      final hovered = HoverActions(
        key: ValueKey('hover-${message.id}'),
        actions: message.inbound ? _hoverActionsFor(message) : const [],
        child: row,
      );
      // Two wrappers whose SHAPE never changes, which is the whole reason they
      // are written this way: the [KeyedSubtree] carries the key a jump needs a
      // context from (and adds no layout of its own), and the [DecoratedBox] is
      // always there with an empty decoration when the row is not lit. A wrapper
      // that came and went with the flash would take the row's element with it
      // and lose the fold the jump had just opened.
      items.add(KeyedSubtree(
        key: _rowKeyFor(message.id),
        child: DecoratedBox(
          key: ThreadDetailPanel.flashKeyFor(message.id),
          decoration: _flashId == message.id
              ? _flashTint
              : const BoxDecoration(),
          child: hovered,
        ),
      ));
      previous = message;
    }

    final after = widget.afterTranscript;
    if (after != null) {
      items.add(Padding(
        // The avatar column plus its gutter — `MessageRow` reserves exactly
        // this much on continuation rows, so the affordance starts where the
        // message bodies above it do.
        padding: const EdgeInsets.only(
          left: _bodyColumnInset,
          top: BondSpacing.s16,
        ),
        child: after,
      ));
    }
    return items;
  }

  /// What tapping the quote above a reply does: go to the message it quotes.
  ///
  /// The quoted message's id rides on the reference's `content_id` — the column
  /// the Teams sync reuses for it, documented on [AttachmentRef.quotedSender] —
  /// so the whole resolution is one lookup against the rows this panel drew. A
  /// quote of a message older than the window that was read resolves to nothing,
  /// and [QuoteBlock] draws a statement rather than a control that goes nowhere.
  VoidCallback? _quoteTapFor(AttachmentRef quote) {
    final quoted = quote.contentId;
    if (quoted == null || !_isLoaded(quoted)) return null;
    return () => unawaited(_jumpToMessage(quoted));
  }

  /// What the pointer offers on one inbound row. Empty when the host wired
  /// none of the four, which is what turns the wrapper back into the bare row.
  List<HoverAction> _hoverActionsFor(Message message) {
    final reply = widget.onReplyTo;
    final suggest = widget.onSuggestFor;
    final why = widget.onWhy;
    final history = widget.onWhatHappened;
    return [
      if (reply != null)
        HoverAction(
          icon: Icons.reply_outlined,
          tooltip: 'Reply',
          onTap: () => reply(message),
          key: HoverActions.replyKeyFor(message.id),
        ),
      if (suggest != null)
        HoverAction(
          icon: Icons.auto_awesome,
          tooltip: 'Suggest a reply',
          onTap: () => suggest(message),
          key: HoverActions.suggestKeyFor(message.id),
        ),
      // After the two that write a reply, because this one and the next only
      // explain the row: the verdict first, then everything behind it.
      if (why != null)
        HoverAction(
          icon: Icons.help_outline,
          tooltip: 'Why',
          onTap: () => why(message),
          key: HoverActions.whyKeyFor(message.id),
        ),
      // After Why, because it is the longer answer to the same question: Why
      // is the verdict, this is everything the pipeline did to reach it.
      if (history != null)
        HoverAction(
          icon: Icons.history,
          tooltip: 'What happened',
          onTap: () => history(message),
          key: HoverActions.historyKeyFor(message.id),
        ),
    ];
  }

  /// The newest inbound message in the transcript — what the banner's ask is
  /// actually about, and so what the banner explains.
  ///
  /// The optimistic bubble is outbound and cannot be it. A thread with nothing
  /// inbound in it has no ask to explain, and the banner falls back.
  Message? get _newestInbound {
    for (final message in widget.messages.reversed) {
      if (message.inbound && !message.pendingSend) return message;
    }
    return null;
  }

  /// [MessageRow]'s avatar diameter (36) plus the gutter it puts beside it.
  static const double _bodyColumnInset = 36 + BondSpacing.s12;

  @override
  Widget build(BuildContext context) {
    // Computed ONCE per build and handed to both the header and the body: the
    // count on the tab and the list under it are the same answer, so they can
    // never disagree about how many files a thread has.
    final files = threadFiles(widget.messages);
    // The tab the pane is on, not the tab the reader last chose: a thread
    // whose files went away between two reads draws no tab row, and a
    // reader parked on Files with no pill to leave by would be stranded on
    // "No files on this thread."
    final tab = files.isEmpty ? ThreadTab.messages : _tab;
    final cta = widget.conversation.ctaText;
    final showCta = widget.conversation.state == ConversationState.needsReply &&
        cta != null &&
        cta.isNotEmpty;

    // The banner names the newest ask only. When older ones are still open,
    // the count says so — the transcript below is where they are read.
    final openAsks = openAskCount(
      widget.messages,
      conversationClosed:
          widget.conversation.state != ConversationState.needsReply,
    );

    // A height-filling bordered surface, not a shrink-wrapping card: the
    // message ListView below needs a bounded height to scroll in.
    final pane = Container(
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(files, tab),
          const Divider(height: 1, color: BondColors.border),
          _actionBar(),
          // The open picker straight under the bar that opened it: pressed in
          // one place, it must not appear a banner and a mention strip lower.
          ?_labelStrip(),
          // Above the ask and under the header: the ask says what the thread
          // wants, and this says where in the thread it is wanted of you.
          ?_mentionStrip(),
          if (showCta)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                BondSpacing.s16,
                BondSpacing.s12,
                BondSpacing.s16,
                0,
              ),
              // Two lines, not however many the model wrote: the ask sits
              // directly above the transcript, and the tooltip keeps the full
              // text a hover away.
              // The tooltip stays the bare ask: it exists to show the full
              // text the banner had to clamp.
              child: Tooltip(
                message: cta,
                child: _ctaBanner(
                  openAsks > 1 ? '$cta · $openAsks open asks' : cta,
                ),
              ),
            ),
          // Only where the banner is absent. The banner already quotes the ask
          // the newest message made, which is a better answer to "why is this
          // waiting on me" than the verdict's reason for it; two explanations
          // stacked would read as two different ones.
          if (!showCta &&
              widget.conversation.state == ConversationState.needsReply)
            NeedsYouWhyLine(
              reason: widget.conversation.needsYouReason,
              at: widget.conversation.needsYouReasonAt,
              p: widget.conversation.needsYouP,
              decidedNow: widget.conversation.needsYouDecidedNow,
              onTap: _toReasonMessage,
            ),
          Expanded(
            child: tab == ThreadTab.files
                ? _filesBody(files)
                : widget.messages.isEmpty
                ? Center(
                    child: Text('No messages in this thread.',
                        style: BondType.small),
                  )
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _maxContentWidth,
                      ),
                      child: ListView(
                        // A jump drives this directly when the row it wants has
                        // not been built yet and so has no context to make
                        // visible; see [_jumpToMessage]. It coexists with the
                        // key below — the bucket restores an offset on build and
                        // the controller moves one after it.
                        controller: _scroll,
                        // The offset is written to the nearest [PageStorage]
                        // bucket under this key when a scroll ends and read
                        // back when the list is built again, so a transcript
                        // that went under a file preview comes back where the
                        // reader left it rather than at the top. Keyed by the
                        // CONVERSATION: two threads read one after the other
                        // are two offsets, and the host's own bucket is what
                        // keeps the main pane's copy of a thread from sharing
                        // one with the panel beside it.
                        key: PageStorageKey<String>(
                          'transcript:${widget.conversation.source}'
                          '|${widget.conversation.id}',
                        ),
                        padding: const EdgeInsets.fromLTRB(
                          BondSpacing.s24,
                          0,
                          BondSpacing.s24,
                          BondSpacing.s24,
                        ),
                        children: _transcript(),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );

    // Its own `Actions` for the two mention intents: a press on the navigator's
    // arrows is dispatched from INSIDE this subtree and is answered here, which
    // is what makes the control work in a host that binds no keys at all. A key
    // bound above the panel arrives the other way, through [TranscriptJumps],
    // and lands in the same two methods — one walk, two doors onto it.
    return Actions(actions: _mentionActions, child: pane);
  }

  /// Everything this thread carried, newest first, in the same cards the
  /// transcript draws.
  ///
  /// The same widgets on purpose: a file the reader recognises from the
  /// conversation must look like the same file here, digest line and all. The
  /// CTA banner stays above both tabs — what the thread wants does not stop
  /// being true because somebody went looking for an attachment.
  Widget _filesBody(List<AttachmentRef> files) {
    if (files.isEmpty) {
      return Center(
        child: Text('No files on this thread.', style: BondType.small),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxContentWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            BondSpacing.s24,
            BondSpacing.s16,
            BondSpacing.s24,
            BondSpacing.s24,
          ),
          children: [
            Wrap(
              spacing: BondSpacing.s8,
              runSpacing: BondSpacing.s8,
              children: [
                for (final file in files)
                  if (_linkKinds.contains(file.kind))
                    LinkUnfurl(
                      key: LinkUnfurl.keyFor(file),
                      attachment: file,
                      onOpen: _openFile(file),
                      onOpenLink: widget.onOpenLink,
                    )
                  else
                    AttachmentCard(
                      key: AttachmentCard.keyFor(file),
                      attachment: file,
                      selected:
                          sameAttachment(widget.selectedAttachment, file),
                      image: _fileImage(file),
                      onTap: _openFile(file),
                      onUseInReply: widget.onUseInReply == null
                          ? null
                          : () => widget.onUseInReply!(file),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  VoidCallback? _openFile(AttachmentRef file) {
    final open = widget.onOpenAttachment;
    return open == null ? null : () => open(file);
  }

  /// A picture only for a file this build might be able to render — a PDF's
  /// first page, a shared document's. Asking for one of a spreadsheet is
  /// asking for a picture that can never arrive, which is the same rule
  /// `layOutBody.thumbnailable` applies in the transcript.
  ImageProvider? _fileImage(AttachmentRef file) {
    const drawable = {
      PreviewKind.pdf,
      PreviewKind.document,
      PreviewKind.html,
    };
    if (!drawable.contains(previewKindFor(file))) return null;
    return widget.thumbnailFor?.call(file);
  }

  /// The ask above the transcript, and the shortest way to find out where it
  /// came from: the whole banner is the click.
  ///
  /// It opens **Why** on the newest inbound message, not the composer. The
  /// composer is docked under this panel and always visible, so "put the
  /// cursor in the box" is a click the reader does not need help with — while
  /// "where did this ask come from" had no answer anywhere until now. Every
  /// per-message ask line below still focuses the box, which is the affordance
  /// that wanted one.
  ///
  /// With no Why to open — a host that cannot show one, or a thread with
  /// nothing inbound in it — it falls back to focusing the composer, which is
  /// what it always did.
  ///
  /// Its own transparent Material, because ink paints on the nearest Material
  /// ANCESTOR — which here is behind the pane's opaque surface, where no hover
  /// could ever show.
  Widget _ctaBanner(String text) {
    final open = widget.onOpenLink;
    final alert = InlineAlert(
      severity: InlineAlertSeverity.attention,
      text: text,
      maxLines: 2,
      // The ask is written by a model reading the body, so it carries whatever
      // link the body carried. Two lines still, ellipsised still — the tap
      // opens the WHOLE address whichever half of it is on screen.
      content: (style) => LinkedText(
        text,
        style: style,
        onOpenLink:
            open == null ? null : (target) => open(target.toString()),
        selectable: false,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final why = widget.onWhy;
    final newest = _newestInbound;
    final opens = (why != null && newest != null)
        ? () => why(newest)
        : widget.onOpenReply;
    if (opens == null) return alert;
    // The transcript jump RIDES ALONG on whatever the banner already did, and is
    // never a tap of its own: a pane with nothing to open stays the statement it
    // shipped as. One press now opens the explanation and leaves the reader
    // standing on the message the words were read off.
    final onTap = newest == null
        ? opens
        : () {
            opens();
            unawaited(_jumpToMessage(newest.id));
          };
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        child: alert,
      ),
    );
  }

  /// The inline label picker while the host has it open, and null otherwise.
  ///
  /// Two acts open it: Mark done with a label files the thread away with a
  /// word saying why, Add label leaves it where it is and puts the word on
  /// it. Both open the SAME strip from the action bar, which is what keeps
  /// the keyboard flow (`Shift+E` and `l`) and the pointer flow one code
  /// path.
  Widget? _labelStrip() {
    final mode = widget.labelPicker;
    final apply = widget.onApplyLabel;
    final create = widget.onCreateLabel;
    final close = widget.onCloseLabelPicker;

    // Tight under the bar above it, which brings its own bottom padding.
    const padding = EdgeInsets.fromLTRB(
      BondSpacing.s16,
      BondSpacing.s4,
      BondSpacing.s16,
      0,
    );

    if (mode != null && apply != null && create != null && close != null) {
      return Padding(
        padding: padding,
        child: LabelPicker(
          labels: widget.labels,
          appliedIds: {for (final l in widget.conversation.labels) l.id},
          prompt: mode.prompt,
          onApply: apply,
          onCreate: create,
          // Only the dismiss path can end with no word on the thread.
          onDismissWithoutLabel: mode == LabelPickerMode.dismiss
              ? widget.onDismissWithoutLabel
              : null,
          onClose: close,
        ),
      );
    }

    // Collapsed, the strip is nothing: its two openers live on the action
    // bar now — Mark done's "with a label" choice and the label row's Add
    // label.
    return null;
  }

  /// The thread's verbs and its labels, under the header — see
  /// [ThreadActionBar] for why one row replaced three places.
  ///
  /// Mark done and Mark done with a label are [onMarkDone] and the
  /// dismiss-mode picker, the same two paths `e` and `Shift+E` take; Add
  /// label is the label-mode picker `l` opens. So a button and its key can
  /// never do different things.
  Widget _actionBar() {
    final open = widget.onOpenLabelPicker;
    final c = widget.conversation;
    return ThreadActionBar(
      done: c.state == ConversationState.done,
      inLater: c.bucket != null,
      onDone: widget.onMarkDone,
      onDoneWithReason:
          open == null ? null : () => open(LabelPickerMode.dismiss),
      onReopen: widget.onReopen,
      onLater: widget.onLaterThread,
      onKeepInInbox: widget.onKeepInInbox,
      inNeedsYou: isNeedsYou(c, threshold: widget.needsYouThreshold),
      onRemoveFromNeedsYou: widget.onRemoveFromNeedsYou,
      onAddToNeedsYou: widget.onAddToNeedsYou,
      onStoryline: widget.onAddToStoryline,
      onContext: widget.onContext,
      contextLinked: widget.contextLinked,
      onCompose: widget.onCompose,
      labels: c.labels,
      onAddLabel: open == null ? null : () => open(LabelPickerMode.label),
      onRemoveLabel: widget.onRemoveLabel,
      onFindLabel: widget.onFindLabel,
    );
  }

  /// Whether the person this thread is waiting on writes from outside the
  /// owner's domains — the newest inbound message's sender, and nobody else's,
  /// which is [Conversation.isExternalTo]'s rule.
  ///
  /// The stored answer first: `latestInboundFrom` comes through the same kept
  /// filter the list row and `is:external` read, so a bot's `noreply@` that
  /// the pipeline gated cannot make the header say External while the row
  /// says nothing. The transcript is only the fallback for a row loaded
  /// before the column existed, where its unfiltered newest inbound is still
  /// a better answer than none.
  bool get _external => isExternalAddress(
      widget.conversation.latestInboundFrom ?? _newestInbound?.fromAddress,
      widget.ownerDomains);

  /// The state chip, and beside it the one fact about the thread that is not a
  /// state.
  ///
  /// `External` stands where the tenant's injected "⚠ External Email — Use
  /// caution with links and attachments" banner used to be read: Phase 1 strips
  /// that line out of every body at ingest, so the warning has to exist
  /// somewhere the reader looks, and once per thread in the header is both
  /// quieter and harder to miss than once per message inside the prose.
  Widget _chips() {
    final state = BondChip.semantic(
      _stateLabel(widget.conversation.state),
      _stateTone(widget.conversation.state),
    );
    if (!_external) return state;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        state,
        const SizedBox(width: BondSpacing.s8),
        const BondChip(
          key: ThreadDetailPanel.externalChipKey,
          label: 'External',
          tone: BondTone.external,
        ),
      ],
    );
  }

  /// The room this thread is: what it is about, who is on it and where it
  /// stands. What can be done to it is the action bar under it; the ⋯ keeps
  /// only the corrections about the sender.
  Widget _header(List<AttachmentRef> files, ThreadTab tab) {
    final participants = widget.conversation.participants
        .map((p) => p.display)
        .where((d) => d.isNotEmpty)
        .join(', ');

    return RoomHeader<ThreadTab>(
      // One tab is a label pretending to be a choice, so a thread with no
      // files draws no tab row at all — see `RoomHeader`'s own rule. That is
      // what keeps a fileless thread looking exactly as it always did.
      tabs: files.isEmpty ? const [ThreadTab.messages] : ThreadTab.values,
      selectedTab: tab,
      tabLabel: (tab) => switch (tab) {
        ThreadTab.messages => 'Messages',
        ThreadTab.files => 'Files (${files.length})',
      },
      onTab: (tab) => setState(() => _tab = tab),
      title: Text(
        widget.conversation.subject?.isNotEmpty == true
            ? widget.conversation.subject!
            : '(no subject)',
        style: BondType.titleSm,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: participants.isEmpty ? null : participants,
      people: [
        for (final p in widget.conversation.participants)
          if (p.display.isNotEmpty)
            (
              name: p.display,
              address: p.email,
              photoKey: photoKeyFor(address: p.email),
            ),
      ],
      photos: widget.photos,
      onPeopleTap: widget.onPeople,
      stateChip: _chips(),
      onBack: widget.onBack,
      // Every verb about the THREAD is on the action bar under this header.
      // What stays here is about the SENDER — a standing rule, not a filing
      // of this one conversation — which is why it is behind the ⋯.
      moreItems: [
        if (widget.onSendToLater != null)
          RoomMenuItem(
            value: _sendToLaterValue,
            label: 'Send this sender to Later',
            onTap: widget.onSendToLater,
          ),
        if (widget.onDropSender != null)
          RoomMenuItem(
            value: _dropSenderValue,
            label: 'Drop this sender',
            onTap: widget.onDropSender,
          ),
      ],
    );
  }

  static const String _sendToLaterValue = '__send_to_later__';
  static const String _dropSenderValue = '__drop_sender__';
}
