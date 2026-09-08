import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../models/message_models.dart';
import '../models/open_asks.dart';
import '../services/profile_photos.dart';
import '../theme/tokens.dart';
import 'attachment_card.dart';
import 'attachment_format.dart';
import 'chips.dart';
import 'hover_actions.dart';
import 'inline_alert.dart';
import 'link_unfurl.dart';
import 'message_row.dart';
import 'preview/preview_kind.dart';
import 'room_header.dart';
import 'time_format.dart';

/// The two halves of a thread: what was said, and what came with it.
enum ThreadTab { messages, files }

/// The kinds that live somewhere else rather than on the message — drawn as
/// unfurls on the Files tab exactly as they are in the transcript.
const Set<String> _linkKinds = {'reference', 'message_reference', 'card'};

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
/// follow.
///
/// Messages arrive oldest-first, so the walk is reversed; within one message
/// the connector's own `ordinal` is the order, because that is the order the
/// sender attached them in.
List<AttachmentRef> threadFiles(List<Message> messages) {
  final files = <AttachmentRef>[];
  for (final message in messages.reversed) {
    final carried = [
      for (final attachment in message.attachments)
        if (!attachment.isInline) attachment,
    ]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    files.addAll(carried);
  }
  return files;
}

/// The thread view: the main pane's whole content once a thread is open.
///
/// The transcript reads as one flat column — day dividers, left-aligned
/// messages, runs collapsed under one header — rather than as a chat of
/// facing bubbles.
///
/// It renders a transcript and a header, and nothing else: the composer is
/// docked UNDER this panel by the host, which is what keeps the panel ignorant
/// of drafts and sending.
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
  /// into. The menu does not list the storylines itself: the choice is a pane
  /// with a way back, because the house rule is screens rather than popups.
  /// Null hides the item, so a host that knows nothing about storylines
  /// renders exactly what it used to.
  final VoidCallback? onAddToStoryline;

  /// Defers this thread's sender. Sender-scoped rather than thread-scoped
  /// because that is the correction worth collecting: one thread going quiet
  /// changes one row, a sender going quiet changes the shape of the inbox.
  /// Null hides the item.
  final VoidCallback? onSendToLater;

  /// Brings a deferred thread back. Only shown when the thread is actually in
  /// a bucket — an "undo" for something that never happened is a menu item
  /// that reads as broken.
  final VoidCallback? onKeepInInbox;

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

  const ThreadDetailPanel({
    super.key,
    required this.conversation,
    required this.messages,
    required this.onMarkDone,
    this.onReopen,
    this.onBack,
    this.onAddToStoryline,
    this.onSendToLater,
    this.onKeepInInbox,
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
  });

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

  /// The transcript, flattened: a divider each time the calendar day turns
  /// over, then one row per message with its header suppressed when it
  /// continues the run above it.
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

      final open = hasOpenAsk(
        message,
        lastOutboundAt: lastOut,
        conversationClosed: closed,
      );
      final suggestion = widget.suggestionFor?.call(message);
      final header = previous == null || !sameRun(previous, message);
      final next = i + 1 < widget.messages.length ? widget.messages[i + 1] : null;
      final standalone = next == null || !sameRun(message, next);
      final isLast = identical(message, widget.messages.last);
      // Only a message that is a run all by itself folds, and never the newest
      // one. Folding a run's header while its continuations stayed up would
      // hide half a run and leave the rest of it hanging under no name; and the
      // last message is what the thread is about — a transcript that opens with
      // its point folded away has answered the wrong question.
      final collapsible = header && standalone && !isLast;
      final row = MessageRow(
        key: ValueKey(message.id),
        message: message,
        showHeader: header,
        openAsk: open,
        // Only a line that is actually on screen gets a tap.
        onAskTap: open ? widget.onOpenReply : null,
        suggestion: suggestion,
        collapsible: collapsible,
        // Folded by default only where there is nothing left to do: history the
        // thread has moved past. An open ask or a live suggestion is the whole
        // reason to scroll back, so neither ever starts hidden.
        initiallyCollapsed: collapsible && !open && suggestion == null,
        onOpenAttachment: widget.onOpenAttachment,
        selectedAttachment: widget.selectedAttachment,
        thumbnailFor: widget.thumbnailFor,
        photos: widget.photos,
        onUseInReply: widget.onUseInReply,
        onOpenLink: widget.onOpenLink,
      );
      // Only what is being ANSWERED wears the strip. There is nothing to reply
      // to on the user's own message, and nothing to draft an answer to either.
      items.add(HoverActions(
        key: ValueKey('hover-${message.id}'),
        actions: message.inbound ? _hoverActionsFor(message) : const [],
        child: row,
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

  /// What the pointer offers on one inbound row. Empty when the host wired
  /// neither callback, which is what turns the wrapper back into the bare row.
  List<HoverAction> _hoverActionsFor(Message message) {
    final reply = widget.onReplyTo;
    final suggest = widget.onSuggestFor;
    final why = widget.onWhy;
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
      // Last, because it is the only one that does not act on the mail: the
      // two before it write a reply, this one explains the row.
      if (why != null)
        HoverAction(
          icon: Icons.help_outline,
          tooltip: 'Why',
          onTap: () => why(message),
          key: HoverActions.whyKeyFor(message.id),
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
    return Container(
      decoration: BoxDecoration(
        color: BondColors.surface,
        borderRadius: BondRadii.mdAll,
        border: Border.all(color: BondColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(files),
          const Divider(height: 1, color: BondColors.border),
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
          Expanded(
            child: _tab == ThreadTab.files
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
    const drawable = {PreviewKind.pdf, PreviewKind.document};
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
    final alert = InlineAlert(
      severity: InlineAlertSeverity.attention,
      text: text,
      maxLines: 2,
    );
    final why = widget.onWhy;
    final newest = _newestInbound;
    final onTap = (why != null && newest != null)
        ? () => why(newest)
        : widget.onOpenReply;
    if (onTap == null) return alert;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        child: alert,
      ),
    );
  }

  /// The room this thread is: what it is about, who is on it, where it stands,
  /// and the few things that can be done to the whole conversation. Filing it —
  /// into a storyline, or out of the inbox — sits behind the ⋯, because those
  /// are corrections rather than part of reading mail, and the automatic passes
  /// are supposed to get them right without being asked.
  ///
  /// The storyline half is one item that opens a pane. Listing every storyline
  /// in the menu would put the whole choice in a popup, and the house rule is a
  /// screen with a way back.
  Widget _header(List<AttachmentRef> files) {
    final participants = widget.conversation.participants
        .map((p) => p.display)
        .where((d) => d.isNotEmpty)
        .join(', ');

    final bucketed = widget.conversation.bucket != null;
    final showKeep = widget.onKeepInInbox != null && bucketed;

    return RoomHeader<ThreadTab>(
      // One tab is a label pretending to be a choice, so a thread with no
      // files draws no tab row at all — see `RoomHeader`'s own rule. That is
      // what keeps a fileless thread looking exactly as it always did.
      tabs: files.isEmpty ? const [ThreadTab.messages] : ThreadTab.values,
      selectedTab: _tab,
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
      stateChip: BondChip.semantic(
        _stateLabel(widget.conversation.state),
        _stateTone(widget.conversation.state),
      ),
      onBack: widget.onBack,
      actions: [
        // Before the state chip's neighbours, because writing to these people
        // is something to DO with the thread. An icon rather than a labelled
        // button: this header shares its width with the attachment preview in
        // the split, and every label here comes out of the title.
        if (widget.onCompose != null)
          RoomAction(
            icon: Icons.edit_outlined,
            label: 'Message',
            onTap: widget.onCompose,
            key: const Key('thread-compose'),
          ),
        // The same button in the same place saying the opposite thing, because
        // a thread closed by mistake is reopened from here.
        if (widget.conversation.state != ConversationState.done)
          RoomAction(label: 'Mark done', onTap: widget.onMarkDone)
        else if (widget.onReopen != null)
          RoomAction(label: 'Reopen', onTap: widget.onReopen),
      ],
      moreItems: [
        if (widget.onAddToStoryline != null)
          RoomMenuItem(
            value: _addToStorylineValue,
            label: 'Add to storyline…',
            onTap: widget.onAddToStoryline,
          ),
        if (widget.onSendToLater != null)
          RoomMenuItem(
            value: _sendToLaterValue,
            label: 'Send to Later',
            onTap: widget.onSendToLater,
            dividerBefore: widget.onAddToStoryline != null,
          ),
        if (showKeep)
          RoomMenuItem(
            value: _keepInInboxValue,
            label: 'Keep in inbox',
            onTap: widget.onKeepInInbox,
            dividerBefore: widget.onAddToStoryline != null && widget.onSendToLater == null,
          ),
      ],
    );
  }

  static const String _addToStorylineValue = '__add_to_storyline__';
  static const String _sendToLaterValue = '__send_to_later__';
  static const String _keepInInboxValue = '__keep_in_inbox__';
}
