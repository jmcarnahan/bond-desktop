import 'package:flutter/material.dart';

import '../models/attachment_models.dart';
import '../models/message_models.dart';
import '../services/deadline_parse.dart' show showableDeadline;
import '../services/profile_photos.dart';
import '../services/sender_display.dart';
import '../theme/tokens.dart';
import 'attachment_card.dart';
import 'attachment_chip.dart';
import 'attachment_format.dart';
import 'bond_avatar.dart';
import 'chips.dart';
import 'image_grid.dart';
import 'inline_image_thumb.dart';
import 'link_unfurl.dart';
import 'linked_text.dart';
import 'preview/preview_kind.dart';
import 'quote_block.dart';
import 'time_format.dart';

// The avatar and its two pure helpers moved to `bond_avatar.dart` when the
// same face had to be drawn in a typeahead row and a rail. Re-exported so
// every caller that learned them here still finds them here.
export 'bond_avatar.dart' show avatarColorFor, initialsFor;

/// How long a gap can be before a message stops reading as part of the same
/// breath and gets its own header again.
const Duration _runWindow = Duration(minutes: 5);

/// Collapse threshold — either many lines or a long body.
const int _maxLines = 12;
const int _maxChars = 600;

/// Where a chat message's file or pasted picture sat in the sentence.
/// `teams_sync` writes these in place of the `<attachment>` and hosted-content
/// `<img>` tags it used to delete outright, so the stored body records the
/// position and this row can draw the file there rather than in a block at the
/// bottom. See `services/attachments/attachment_markers.dart`, which is what
/// every prompt and every embedding uses to take them back out.
final RegExp _teamsMarker = RegExp(r'\[\[(att|img):([^\]]+)\]\]');

/// Graph's HTML→text conversion renders an inline image — a signature logo,
/// typically — as a literal `[cid:…]` token. It was stripped as presentational
/// noise and the id thrown away; the id is in fact the join key onto
/// `attachments.content_id`, which is how a pasted screenshot gets drawn in
/// place and a logo gets left out. The stored body stays as ingested either
/// way; this is a display-time read of it.
final RegExp _cidCapture = RegExp(r'\[cid:([^\]]+)\]');

/// Every token the layout walks, in one pass so that markers and cid tokens
/// keep their order relative to each other. Built from the two regexes above
/// rather than written a third time.
///
/// A token takes the horizontal space AFTER it with it and leaves the space
/// before it alone. That is what turns "see [[att:x]] for the numbers" into
/// "see for the numbers" rather than "seefor" or "see  for" — the space before
/// a token is the one that was holding the sentence together.
final RegExp _bodyToken = RegExp(
  '${_teamsMarker.pattern}[ \\t]*|${_cidCapture.pattern}[ \\t]*',
);

/// Runs of blank lines, which is what taking a token out of its own paragraph
/// leaves behind.
final RegExp _blankRun = RegExp(r'\n{3,}');

/// A single whitespace character — where the clamp looks for the edge of the
/// last word it kept.
final RegExp _whitespace = RegExp(r'\s');

/// The kinds that are somewhere ELSE rather than something the message carried.
///
/// Wider than `preview_kind.dart`'s own link set, which is about what a preview
/// can BUILD: a `reference` previews like the drive file it points at, but it
/// still arrived as a link and it still has a site the reader needs told. So
/// the row draws all three as unfurls and everything else as a card.
const Set<String> _linkKinds = linkAttachmentKinds;

/// Under this an inline image is furniture — a signature logo, a social icon,
/// a tracking pixel — and is stripped from the body and left out of the chips
/// entirely. Over it, somebody meant to show you something.
///
/// Bytes, not pixels: the size is what both connectors state, and a logo that
/// wants twenty kilobytes to say a company name is a picture worth drawing.
/// A size of 0 means "the connector did not say" (every Teams attachment) and
/// is never treated as small.
const int inlineImageMinBytes = 20 * 1024;

/// Whether [b] collapses under [a]: same sender, same direction, and close
/// enough in time. An unparseable timestamp on either side breaks the run —
/// the header is the safe answer.
bool sameRun(Message a, Message b) {
  if (a.outbound != b.outbound) return false;
  if ((a.fromAddress ?? '').toLowerCase() !=
      (b.fromAddress ?? '').toLowerCase()) {
    return false;
  }
  final first = DateTime.tryParse(a.receivedAt ?? '');
  final second = DateTime.tryParse(b.receivedAt ?? '');
  if (first == null || second == null) return false;
  return second.difference(first).abs() <= _runWindow;
}

/// The local calendar day a message landed on, as `yyyy-mm-dd`. Null when the
/// timestamp does not parse, which reads as "no day divider" upstream.
String? dayKeyOf(Message m) => dayKeyOfIso(m.receivedAt);

/// One piece of a message body: either words, or a file that sat between them.
sealed class BodySegment {
  const BodySegment();
}

final class BodyTextSegment extends BodySegment {
  final String text;

  const BodyTextSegment(this.text);
}

final class BodyAttachmentSegment extends BodySegment {
  final AttachmentRef attachment;

  /// Whether to draw it or name it. Decided once here so the row does not ask
  /// the question again while building.
  final bool asImage;

  const BodyAttachmentSegment({
    required this.attachment,
    required this.asImage,
  });
}

/// What a body is once its attachments have been placed in it.
///
/// [plainText] is deliberately the WHOLE body as words — every text run joined
/// — because that is what the `Show more` clamp measures and what a folded row
/// shows one line of. Splitting the body into segments must not change either
/// of those, or a message would fold differently for having a picture in it.
/// [thumbnailable] is a SUBSET of [chips] and not a fourth bucket: a PDF or a
/// shared Word file may have a picture of its first page, and if it does the
/// row draws it — but the file is still named in the chip row underneath,
/// which is what carries its size and its tap target. Counting it twice would
/// make a folded row claim two files where there is one.
/// [quotes] is the one bucket that is NOT a file this message carried: a Teams
/// quote-reply arrives as an attachment and is drawn above the words as the
/// piece of conversation it is (`quote_block.dart`), so it is in none of the
/// other four lists and counts toward nothing.
typedef BodyLayout = ({
  List<BodySegment> segments,
  String plainText,
  List<AttachmentRef> chips,
  List<AttachmentRef> trailingImages,
  List<AttachmentRef> thumbnailable,
  List<AttachmentRef> quotes,
});

/// The body a row reads.
///
/// The preview stands in until the body arrives: bodies are fetched per thread
/// on open, and a row with nothing in it reads as an empty message rather than
/// as one still loading.
String rawBodyOf(Message message) {
  final bodyText = message.bodyText;
  return (bodyText == null || bodyText.isEmpty)
      ? (message.bodyPreview ?? '')
      : bodyText;
}

/// Places [attachments] into [body] where the sender put them, and says what is
/// left over.
///
/// The rules, all of which exist because a message is one thing and not a body
/// with an appendix:
///
/// - `[[att:id]]` / `[[img:id]]` naming an attachment on this message puts it
///   at that point in the text and takes the marker out. A marker naming
///   nothing — an edit removed the file, the id is from another message — has
///   its marker taken out anyway, because a reader must never see the app's
///   own bookkeeping.
/// - `[cid:x]` matching an INLINE attachment of at least [inlineImageMinBytes]
///   draws it there. A smaller one is stripped exactly as it always was, and is
///   dropped from the chips too: a signature logo is not a file somebody sent.
/// - A marker naming a QUOTE-REPLY loses its marker and places nothing. Teams
///   writes that marker at the head of the body, which is how the quote used to
///   draw itself as a `🔗 (unnamed)` chip above the reply; the quote goes to
///   [BodyLayout.quotes] instead and the row draws a quote block there.
/// - Everything unplaced falls to the bottom in `ordinal` order — pictures as
///   pictures, the rest as chips.
///
/// Pure and top-level so it is tested like `initialsFor` and `sameRun`, without
/// pumping a widget.
BodyLayout layOutBody(String body, List<AttachmentRef> attachments) {
  final byId = <String, AttachmentRef>{};
  final byContentId = <String, AttachmentRef>{};
  for (final attachment in attachments) {
    byId.putIfAbsent(attachment.attachmentId, () => attachment);
    final contentId = attachment.contentId;
    if (contentId != null && contentId.isNotEmpty) {
      byContentId.putIfAbsent(contentId, () => attachment);
    }
  }

  final segments = <BodySegment>[];
  final plain = StringBuffer();
  final pending = StringBuffer();
  final placed = <String>{};
  final dropped = <String>{};
  var sawToken = false;

  void flushText() {
    final run = pending.toString().trim();
    pending.clear();
    if (run.isNotEmpty) segments.add(BodyTextSegment(run));
  }

  var cursor = 0;
  for (final match in _bodyToken.allMatches(body)) {
    sawToken = true;
    final run = body.substring(cursor, match.start);
    pending.write(run);
    plain.write(run);
    cursor = match.end;

    final markerId = match[2];
    final contentId = match[3];
    AttachmentRef? target;
    if (markerId != null) {
      target = byId[markerId];
    } else if (contentId != null) {
      final referenced = byContentId[contentId];
      if (referenced != null && referenced.isInline) {
        if (referenced.size >= inlineImageMinBytes) {
          target = referenced;
        } else {
          dropped.add(referenced.attachmentId);
        }
      }
    }
    if (target == null) continue;
    // A quote-reply is not drawn where its marker sat. It is the thing being
    // replied TO, so it belongs above the whole reply rather than inside it.
    if (target.isQuoteReply) continue;
    // A body that names the same file twice draws it once, where it was first
    // mentioned; the second mention just loses its marker.
    if (!placed.add(target.attachmentId)) continue;
    flushText();
    segments.add(BodyAttachmentSegment(
      attachment: target,
      asImage: isImageAttachment(target),
    ));
  }
  final tail = body.substring(cursor);
  pending.write(tail);
  plain.write(tail);
  flushText();

  // The tidy-up applies only to a body that actually lost a token — the same
  // early-out `stripAttachmentMarkers` makes, and for the same reason: an
  // ordinary mail body's blank lines are its paragraphs.
  var plainText = plain.toString();
  if (sawToken) {
    plainText = plainText.replaceAll(_blankRun, '\n\n').trimRight();
  }

  final placedAnything = segments.any((s) => s is BodyAttachmentSegment);
  final resolved = placedAnything
      ? segments
      // Nothing was placed, so the body is one run of words and must render
      // byte for byte the way it always has.
      : <BodySegment>[if (plainText.isNotEmpty) BodyTextSegment(plainText)];

  final quotes = [
    for (final attachment in attachments)
      if (attachment.isQuoteReply) attachment,
  ]..sort((a, b) => a.ordinal.compareTo(b.ordinal));

  final leftovers = [
    for (final attachment in attachments)
      if (!placed.contains(attachment.attachmentId) &&
          !dropped.contains(attachment.attachmentId) &&
          !attachment.isQuoteReply &&
          !_isSubThresholdInlineImage(attachment))
        attachment,
  ]..sort((a, b) => a.ordinal.compareTo(b.ordinal));

  final chips = <AttachmentRef>[];
  final trailingImages = <AttachmentRef>[];
  final thumbnailable = <AttachmentRef>[];
  for (final attachment in leftovers) {
    if (isImageAttachment(attachment)) {
      trailingImages.add(attachment);
      continue;
    }
    chips.add(attachment);
    // A document that something in this build might be able to draw: a PDF
    // (its own first page), a chat's shared file (OneDrive's rendering) or a web
    // page (the Runner's WebKit). Whether one actually arrives is the host's
    // answer, not this function's — it says only which files are worth asking
    // about.
    if (!attachment.isInline &&
        const {PreviewKind.pdf, PreviewKind.document, PreviewKind.html}
            .contains(previewKindFor(attachment))) {
      thumbnailable.add(attachment);
    }
  }

  return (
    segments: resolved,
    plainText: plainText,
    chips: chips,
    trailingImages: trailingImages,
    thumbnailable: thumbnailable,
    quotes: quotes,
  );
}

/// How many attachments a reader would say this message has.
///
/// Not `message.attachments.length`: the sub-threshold inline logos a mail
/// client staples to every signature are not files anybody sent, and a folded
/// row claiming `📎 3 files` for a message with one contract and two logos is
/// worse than saying nothing.
///
/// Answered through [layOutBody] rather than by a second rule, so the count and
/// what the open row draws can never disagree.
int displayableAttachmentCount(Message message) {
  if (message.attachments.isEmpty) return 0;
  return displayableCountOf(layOutBody(rawBodyOf(message), message.attachments));
}

/// The same count from a layout the caller already has — the row builds one per
/// frame and must not walk the body twice to label its own fold.
int displayableCountOf(BodyLayout layout) =>
    layout.chips.length +
    layout.trailingImages.length +
    layout.segments.whereType<BodyAttachmentSegment>().length;

/// An inline picture small enough to be furniture. A stated size of 0 means the
/// connector never said, which is not the same as small.
bool _isSubThresholdInlineImage(AttachmentRef attachment) =>
    attachment.isInline &&
    isImageAttachment(attachment) &&
    attachment.size > 0 &&
    attachment.size < inlineImageMinBytes;

/// One message in a thread, flat and left-aligned whichever way it went.
///
/// There are no bubbles and no right-hand column: a transcript reads top to
/// bottom in one gutter, and direction is carried by the avatar alone.
/// Consecutive messages from the same sender collapse under the first one's
/// header. Bodies are plain-text [LinkedText] — mail content is NEVER
/// markdown-rendered. Links are the ONE exception and a narrow one: a bare
/// address and the canonical `label <url>` run a converter wrote are painted as
/// links (see `linked_text.dart`), and every other character stays exactly as it
/// was stored. No `*`, no `_`, no `#`, no `[](…)`.
///
/// A row can also be FOLDED, which is a different thing from the `Show more`
/// clamp on a long body: folded, the message keeps its header and gives up its
/// body to a single muted line. The rules the host cannot see and this row
/// therefore does not invent:
///
/// - Folding is offered only where [collapsible] says so, and starts folded
///   only where [initiallyCollapsed] does. Both are the host's call, because
///   both need the whole thread to answer.
/// - What survives the fold is what says the message still wants something: an
///   open ask keeps its line, and a message carrying a [suggestion] says so in
///   one caption. A folded row must never be the reason an answer went unsent.
/// - The user's own toggle outlives every rebuild. Nothing recomputes it.
///
/// The files a message carried sit UNDER the words that came with them, drawn
/// as what they are: a document is a card with its own picture on it, one
/// photograph is a picture, two or more are a grid, and a link is an unfurl
/// that names the site before it names the file. A file the sender put INSIDE
/// a sentence is the exception and stays a chip there — a 320px card halfway
/// through a paragraph is not a paragraph.
class MessageRow extends StatefulWidget {
  final Message message;

  /// False renders a continuation: no avatar, no name, no timestamp.
  final bool showHeader;

  /// Whether this message's own ask is still unanswered. The row does not work
  /// that out — the rule needs the whole thread, so the host passes the answer
  /// (`models/open_asks.dart`) in.
  final bool openAsk;

  /// What tapping the ask does. Null leaves it a statement — a row whose host
  /// has nowhere to send the tap must not look like it takes one.
  final VoidCallback? onAskTap;

  /// The answer offered to THIS message, drawn under it when the row is open.
  /// The row knows nothing about drafts — the host builds the card and this
  /// only places it, beneath the ask it answers.
  final Widget? suggestion;

  /// The meeting this message invites to, or cancels, drawn under it when the
  /// row is open. The host decides whether the message is an invite and builds
  /// the card; the row only places it — as with [suggestion], it knows nothing
  /// about calendars.
  final Widget? meetingCard;

  /// Whether the header folds this message away. False renders exactly what it
  /// always did: no chevron, no tap, nothing to fold.
  final bool collapsible;

  /// Whether it starts folded. Read once, at construction — see [_collapsed].
  final bool initiallyCollapsed;

  /// A COUNTER of times the host has asked for this row to be opened, which is
  /// how a jump lands on a folded message and finds it readable.
  ///
  /// Not a bool and not a re-read of [initiallyCollapsed]: the fold is seeded
  /// once and never recomputed, deliberately (see [_collapsed]), so the only
  /// honest way to open a row from outside is an EVENT rather than a state the
  /// row keeps re-deciding. Each increment is one such event — "the reader just
  /// jumped here" — so a reader who folds the row again and jumps back to it
  /// gets it opened again. Never decreases, so the host keeps one number per
  /// message rather than clearing a flag on the frame after it set one.
  final int unfoldRequest;

  /// Whether this message names the owner — an `@mention`, a 1:1, or an ask the
  /// extractor wrote for them (`services/mention_index.dart`). Draws the `@ you`
  /// marker, and is why the host starts such a row unfolded in a thread whose
  /// history is otherwise folded away. False is what every other host passes.
  final bool namesOwner;

  /// Told whenever the reader folds or unfolds this row, with what it became.
  ///
  /// The fold survives every rebuild on its own (see [_collapsed]); what it
  /// cannot survive is the row being DISPOSED, which is what happens to a
  /// transcript replaced by something else and built again when it comes back.
  /// A host that can lose the row remembers the answer and hands it back as
  /// [initiallyCollapsed]; one that never loses it passes null and the fold
  /// stays the row's own business.
  final void Function(bool collapsed)? onFoldChanged;

  /// What opening one of this message's files does. Null leaves every chip and
  /// picture a statement — a row whose host has nowhere to show a file must not
  /// offer to show it.
  final void Function(AttachmentRef attachment)? onOpenAttachment;

  /// The file the host is currently previewing, if it is one of this message's.
  /// Compared with `sameAttachment`: [AttachmentRef] has no value equality, and
  /// a digest landing mid-frame must not deselect what the reader is looking
  /// at.
  final AttachmentRef? selectedAttachment;

  /// The picture for an attachment, or null while there is none.
  ///
  /// An [ImageProvider] rather than bytes or a path: the bytes arrive
  /// asynchronously from a cache this row knows nothing about, and under
  /// `flutter test` the host hands over a `MemoryImage` so no widget here ever
  /// reads a disk.
  final ImageProvider? Function(AttachmentRef attachment)? thumbnailFor;

  /// Where the sender's face comes from. Null draws initials and asks nothing,
  /// which is what every test and every signed-out session gets.
  final ProfilePhotos? photos;

  /// What the card's hover strip offers: put THIS file into the reply being
  /// written. Null hides the strip, for a host with no box to write into — the
  /// same rule [onAskTap] follows, and the same rule the file panel's own
  /// button follows, because they are one path.
  final void Function(AttachmentRef attachment)? onUseInReply;

  /// Hands a link's address to the operating system — the unfurl's `Open link`.
  /// Null draws no button, and so does an address `webUriOf` refuses.
  final void Function(String url)? onOpenLink;

  /// What tapping the quote above a reply does, asked PER QUOTE.
  ///
  /// A quote-reply names the message it quotes (`content_id`), and only the host
  /// knows whether that message is one of the rows it loaded. So the row asks
  /// about each quote and draws whatever comes back: a tap where the answer is
  /// somewhere on this screen, a statement where it is not. Null altogether
  /// leaves every quote a statement, which is what a host with no transcript to
  /// scroll passes.
  final VoidCallback? Function(AttachmentRef quote)? quoteTapFor;

  const MessageRow({
    super.key,
    required this.message,
    this.showHeader = true,
    this.openAsk = false,
    this.onAskTap,
    this.suggestion,
    this.meetingCard,
    this.collapsible = false,
    this.initiallyCollapsed = false,
    this.unfoldRequest = 0,
    this.namesOwner = false,
    this.onFoldChanged,
    this.onOpenAttachment,
    this.selectedAttachment,
    this.thumbnailFor,
    this.photos,
    this.onUseInReply,
    this.onOpenLink,
    this.quoteTapFor,
  });

  /// The one line a folded row keeps about its files.
  static const Key collapsedAttachmentHintKey =
      ValueKey('message-row-attachment-hint');

  /// The `@ you` marker — what a reader scanning a long thread is looking for,
  /// and what a test asks for instead of hunting a colour.
  static const Key ownerMarkerKey = ValueKey('message-row-owner-marker');

  /// The run of file cards under a message — what a test asks for to say "the
  /// files this message carried are drawn here".
  static const Key cardsKey = ValueKey('message-row-cards');

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow> {
  bool _expanded = false;

  /// Whether this message is folded to its header.
  ///
  /// Seeded once and NEVER recomputed — there is deliberately no
  /// `didUpdateWidget` arm for it. A transcript rebuilds on every sync, every
  /// draft reload and every inbox setState; re-reading
  /// [MessageRow.initiallyCollapsed] on any of those would fold a message the
  /// user had just opened, under their cursor, for a reason they could not see.
  late bool _collapsed;

  /// The avatar's diameter, and the width the gutter keeps reserved on
  /// continuation rows so bodies stay in one column.
  static const double _avatarSize = 36;

  @override
  void initState() {
    super.initState();
    _collapsed = widget.initiallyCollapsed && widget.collapsible;
  }

  /// The ONE arm that reopens a folded row from outside, and it reads an event
  /// rather than a state: a fresh [MessageRow.unfoldRequest] means the reader
  /// has just been sent here, and a message the reader was sent to has to be
  /// readable when they arrive. [MessageRow.initiallyCollapsed] is still never
  /// re-read — that is the rule this arm sits beside rather than the rule it
  /// breaks.
  @override
  void didUpdateWidget(MessageRow old) {
    super.didUpdateWidget(old);
    if (widget.unfoldRequest != old.unfoldRequest && _collapsed) {
      setState(() => _collapsed = false);
      widget.onFoldChanged?.call(false);
    }
  }

  String get _raw => rawBodyOf(widget.message);

  /// The body with its attachments placed in it. Computed ONCE per build and
  /// handed down — a transcript rebuilds on every sync, and this walks the
  /// whole body.
  BodyLayout _layout() => layOutBody(_raw, widget.message.attachments);

  /// Whether the body is long enough to earn the `Show more` clamp. Unrelated
  /// to [_collapsed], which folds the whole message rather than trimming it.
  bool _bodyOverflows(BodyLayout layout) {
    final body = layout.plainText;
    return body.length > _maxChars ||
        '\n'.allMatches(body).length + 1 > _maxLines;
  }

  String _visibleBody(BodyLayout layout) {
    final body = layout.plainText;
    if (_expanded || !_bodyOverflows(layout)) return body;
    // Clamp to the first N lines, then the char cap, whichever hits first.
    final lines = body.split('\n');
    var clamped =
        lines.length > _maxLines ? lines.take(_maxLines).join('\n') : body;
    if (clamped.length > _maxChars) {
      clamped = _cutAt(clamped, _maxChars);
    }
    return clamped.trimRight();
  }

  /// [text] cut to [cap] characters, never through a link.
  ///
  /// The cap used to land wherever it landed, which cut a long address in half
  /// — and half an address still parses, so the clamped body painted a link to
  /// somewhere else entirely. Where the last token is the start of a link (a
  /// bare address, or the `label <` head of a canonical run whose address the
  /// cut took) the whole token comes off, and `Show more` is where the rest of
  /// it is. A cut through ordinary words is left where it fell.
  ///
  /// A window with no whitespace in it at all — a machine-generated blob, one
  /// enormous address — is the one case the token can't come off: there would be
  /// nothing left to paint, and such a body has no words to show either way. The
  /// cut stands there, and `Show more` still has the whole of it.
  static String _cutAt(String text, int cap) {
    final head = text.substring(0, cap);
    final boundary = head.lastIndexOf(_whitespace);
    if (boundary <= 0) return head;
    final tail = head.substring(boundary + 1);
    if (tail.contains('<') || tail.toLowerCase().contains('http')) {
      return head.substring(0, boundary + 1);
    }
    return head;
  }

  String get _senderName {
    final message = widget.message;
    return displaySenderName(
      name: message.fromName,
      address: message.fromAddress,
      fallback: message.outbound ? 'You' : unknownSenderName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final pending = message.pendingSend;

    // Only inbound mail is ever queued, so the suffix says "the model has not
    // reached this one yet" rather than appearing on every row in a thread.
    final triaging = !pending &&
        message.inbound &&
        (message.triageStatus == 'pending' ||
            message.triageStatus == 'processing');

    final when = pending ? '' : (formatTimestamp(message.receivedAt) ?? '');
    final meta = !triaging
        ? when
        : when.isEmpty
            ? 'triaging'
            : '$when · triaging';
    final summary = message.summary;

    // A queued reply is always the thread's last message and always on its way
    // out; folding it would hide the only thing on screen saying so.
    final folds = widget.collapsible && !pending;
    final collapsed = folds && _collapsed;
    final suggestion = widget.suggestion;

    final layout = _layout();
    final overflows = _bodyOverflows(layout);

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.showHeader
            ? _avatar(message)
            : const SizedBox(width: _avatarSize),
        const SizedBox(width: BondSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showHeader) ...[
                _header(meta, folds: folds),
                const SizedBox(height: 2),
              ]
              // A continuation row has no header to hang the marker on, and a
              // mention in the middle of somebody's run is still the reason the
              // reader came here, so it wears one of its own.
              else if (widget.namesOwner) ...[
                _ownerMarker(),
                const SizedBox(height: 2),
              ],
              if (collapsed) ...[
                // One line of what was said, and then only what still wants
                // something: the fold hides reading, never answering.
                Text(
                  layout.plainText.split('\n').firstWhere(
                        (line) => line.trim().isNotEmpty,
                        orElse: () => '',
                      ),
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // A folded message says it carried files, and nothing more —
                // the fold must not be the reason a contract went unseen, and
                // an arriving attachment must not unfold a row under the
                // reader's cursor.
                if (displayableCountOf(layout) > 0)
                  Text(
                    _attachmentHint(displayableCountOf(layout)),
                    key: MessageRow.collapsedAttachmentHintKey,
                    style:
                        BondType.caption.copyWith(color: BondColors.inkMuted),
                  ),
              ] else ...[
                // What this reply is answering, first: a quote reads before the
                // words that answer it or it is not a quote.
                for (final quote in layout.quotes)
                  QuoteBlock(
                    key: QuoteBlock.keyFor(quote),
                    attachment: quote,
                    onTap: widget.quoteTapFor?.call(quote),
                  ),
                ..._bodySegments(layout, overflows),
                if (overflows) ...[
                  const SizedBox(height: BondSpacing.s4),
                  _ShowToggle(
                    expanded: _expanded,
                    onTap: () => setState(() => _expanded = !_expanded),
                  ),
                ],
                if (pending) ...[
                  const SizedBox(height: BondSpacing.s4),
                  Text('Sending…', style: BondType.caption),
                ],
                // The model's short read of this message — one or two
                // sentences, clamped at 500 characters — labelled as the
                // model's: it sits under mail the user can see for themselves,
                // and it must never be mistaken for something the sender wrote.
                if (summary != null && summary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'AI: $summary',
                    style:
                        BondType.caption.copyWith(color: BondColors.inkMuted),
                  ),
                ],
                // The meeting the mail is about, straight under what was said
                // about it and above the files.
                if (widget.meetingCard != null) ...[
                  const SizedBox(height: BondSpacing.s8),
                  widget.meetingCard!,
                ],
                // The files, last: under everything that was said about them,
                // and above the ask that is probably about them too.
                //
                // Pictures first, because a picture is what the message IS
                // when somebody sent one. One stays the single thumbnail it
                // always was; two or more become a grid, which is what every
                // chat app a reader has used draws for them.
                ..._trailingPictures(layout),
                ..._links(layout),
                ..._cards(layout),
              ],
              // The ask this message is still waiting on. The thread banner
              // carries only the newest one, so an older message keeps its own
              // here until a reply answers it. Folded or not: a message that
              // wants an answer has to say so from behind the fold too.
              if (widget.openAsk) ...[
                const SizedBox(height: BondSpacing.s4),
                _askLine(message),
              ]
              // No ask, but an answer waiting under the fold — the hint that
              // there is something actionable here, in the ask's place.
              else if (collapsed && suggestion != null) ...[
                const SizedBox(height: BondSpacing.s4),
                Text(
                  '✨ Suggested reply',
                  style: BondType.caption.copyWith(color: BondColors.inkMuted),
                ),
              ],
              if (!collapsed && suggestion != null)
                Padding(
                  padding: const EdgeInsets.only(top: BondSpacing.s8),
                  child: suggestion,
                ),
            ],
          ),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(
        top: widget.showHeader ? BondSpacing.s16 : BondSpacing.s4,
      ),
      child: Opacity(opacity: pending ? 0.6 : 1, child: row),
    );
  }

  static String _attachmentHint(int count) =>
      count == 1 ? '📎 1 file' : '📎 $count files';

  /// The body, with the files the sender put in it drawn where they sat.
  ///
  /// A CLAMPED body renders as one block of text and nothing else. Splicing a
  /// picture into a sentence that has been cut mid-word reads as a bug, and the
  /// files are not lost by it — every one of them is still named in the chip
  /// row below.
  List<Widget> _bodySegments(BodyLayout layout, bool overflows) {
    final clamped = overflows && !_expanded;
    final placed = layout.segments.any((s) => s is BodyAttachmentSegment);
    if (clamped || !placed) {
      return [_text(_visibleBody(layout))];
    }

    final widgets = <Widget>[];
    for (final segment in layout.segments) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: BondSpacing.s8));
      }
      switch (segment) {
        case BodyTextSegment(:final text):
          widgets.add(_text(text));
        case BodyAttachmentSegment(:final attachment, :final asImage):
          widgets.add(asImage
              ? _thumb(attachment)
              : Align(
                  alignment: Alignment.centerLeft,
                  child: AttachmentChip(
                    key: AttachmentChip.keyFor(attachment),
                    attachment: attachment,
                    selected: sameAttachment(
                      widget.selectedAttachment,
                      attachment,
                    ),
                    onTap: _openAttachment(attachment),
                  ),
                ));
      }
    }
    return widgets;
  }

  /// A stretch of body words. Its links came off anchors a real sender wrote,
  /// whose text runs to a whole question ("Why am I receiving this notification
  /// from Office?"), so the label caps here are the generous pair — the tight
  /// defaults are for the one-line asks a model writes.
  Widget _text(String text) => LinkedText(
        text,
        style: BondType.body.copyWith(color: BondColors.ink, height: 1.4),
        onOpenLink: _openLink,
        maxLabelChars: bodyMaxLabelChars,
        maxLabelWords: bodyMaxLabelWords,
      );

  /// The link seam, in the shape [LinkedText] takes. Null where the host gave
  /// the row nowhere to send a tap, which paints the labels as words.
  void Function(Uri target)? get _openLink {
    final open = widget.onOpenLink;
    return open == null ? null : (target) => open(target.toString());
  }

  /// A picture, left-aligned in the body column and bounded on both axes — the
  /// transcript is a `ListView`, where an unbounded child is an assertion
  /// rather than a wrong-looking frame.
  Widget _thumb(AttachmentRef attachment) => Align(
        alignment: Alignment.centerLeft,
        child: InlineImageThumb(
          key: InlineImageThumb.keyFor(attachment),
          attachment: attachment,
          image: widget.thumbnailFor?.call(attachment),
          onTap: _openAttachment(attachment),
        ),
      );

  /// The pictures the body never pointed at.
  ///
  /// One stays the single thumbnail it has always been — a lone photograph is
  /// the message, and cropping it to a square would throw away the half of it
  /// somebody meant to show. Two or more become a grid, because a column of
  /// full-width pictures is a scroll rather than a message.
  List<Widget> _trailingPictures(BodyLayout layout) {
    final images = layout.trailingImages;
    if (images.isEmpty) return const [];
    return [
      const SizedBox(height: BondSpacing.s8),
      if (images.length == 1)
        _thumb(images.first)
      else
        ImageGrid(
          key: ImageGrid.gridKey,
          images: images,
          imageFor: (attachment) => widget.thumbnailFor?.call(attachment),
          onTap: widget.onOpenAttachment,
        ),
    ];
  }

  /// The links, as unfurls.
  ///
  /// A picture is passed only for a link this build might actually be able to
  /// render — `layout.thumbnailable` is the list that already answers that. A
  /// mail link to a drive PDF IS on it, because the bytes ladder fetches a
  /// `reference` by its url like any other file; a card or a quoted message
  /// never is, and asking the host for a picture of one would be asking for a
  /// picture that can never arrive.
  List<Widget> _links(BodyLayout layout) {
    final links = [
      for (final attachment in layout.chips)
        if (_linkKinds.contains(attachment.kind)) attachment,
    ];
    if (links.isEmpty) return const [];
    return [
      const SizedBox(height: BondSpacing.s8),
      Wrap(
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s8,
        children: [
          for (final attachment in links)
            LinkUnfurl(
              key: LinkUnfurl.keyFor(attachment),
              attachment: attachment,
              image: _thumbnailIfWanted(layout, attachment),
              onOpen: _openAttachment(attachment),
              onOpenLink: widget.onOpenLink,
            ),
        ],
      ),
    ];
  }

  /// The files, as cards.
  ///
  /// Everything in `layout.chips` that is not a link: a document, a
  /// spreadsheet, a forwarded message. The card carries the digest line, so
  /// there is no second run of captions under the row any more — one line per
  /// file, on the file.
  List<Widget> _cards(BodyLayout layout) {
    final files = [
      for (final attachment in layout.chips)
        if (!_linkKinds.contains(attachment.kind)) attachment,
    ];
    if (files.isEmpty) return const [];
    final use = widget.onUseInReply;
    return [
      const SizedBox(height: BondSpacing.s8),
      Wrap(
        key: MessageRow.cardsKey,
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s8,
        children: [
          for (final attachment in files)
            AttachmentCard(
              key: AttachmentCard.keyFor(attachment),
              attachment: attachment,
              selected:
                  sameAttachment(widget.selectedAttachment, attachment),
              image: _thumbnailIfWanted(layout, attachment),
              onTap: _openAttachment(attachment),
              onUseInReply: use == null ? null : () => use(attachment),
            ),
        ],
      ),
    ];
  }

  /// The host's picture for a file, but only for a file the layout says is
  /// worth asking about. `thumbnailable` is that answer, and it is the same
  /// list the row used to draw a separate thumbnail from — so a link still
  /// asks nothing, which a test pins.
  ImageProvider? _thumbnailIfWanted(
    BodyLayout layout,
    AttachmentRef attachment,
  ) {
    final wanted = layout.thumbnailable
        .any((candidate) => sameAttachment(candidate, attachment));
    if (!wanted) return null;
    return widget.thumbnailFor?.call(attachment);
  }

  VoidCallback? _openAttachment(AttachmentRef attachment) {
    final open = widget.onOpenAttachment;
    return open == null ? null : () => open(attachment);
  }

  /// Who said it and when — and, where the row folds, the whole affordance for
  /// folding it. The header is the target rather than a separate button: it is
  /// the one part of the message that stays whichever way the row is, so the
  /// place to press is the same open and closed.
  ///
  /// Its own transparent Material, because ink paints on the nearest Material
  /// ANCESTOR — which is behind the pane's opaque surface, the same trap
  /// `_askLine` and `thread_detail_panel._ctaBanner` document.
  Widget _header(String meta, {required bool folds}) {
    final line = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            _senderName,
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(width: BondSpacing.s8),
          // Flexible like the name: "Sep 27, 11:02 PM · triaging" beside the
          // `@ you` marker is wider than a beside pane, and a message parked
          // in triage wears that suffix for as long as the model is down.
          Flexible(
            child: Text(
              meta,
              style: BondType.caption,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        // After the name and the stamp, before the chevron: it says something
        // about this message, not about whether the row is open.
        if (widget.namesOwner) ...[
          const SizedBox(width: BondSpacing.s8),
          _ownerMarker(),
        ],
        if (folds) ...[
          const SizedBox(width: BondSpacing.s4),
          Icon(
            _collapsed ? Icons.expand_more : Icons.expand_less,
            size: 16,
            color: BondColors.inkMuted,
          ),
        ],
      ],
    );

    if (!folds) return line;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () {
          setState(() => _collapsed = !_collapsed);
          widget.onFoldChanged?.call(_collapsed);
        },
        borderRadius: BondRadii.smAll,
        child: line,
      ),
    );
  }

  /// The `@ you` marker: this is one of the messages the navigator counts.
  ///
  /// The attention tone, the same copper the ask line and the banner wear,
  /// because it is the same claim in fewer words — something here is the
  /// reader's. Lowercase `you`, matching the header's own sentence case.
  Widget _ownerMarker() => BondChip.semantic(
        '@ you',
        BondTone.attention,
        key: MessageRow.ownerMarkerKey,
      );

  /// The open ask, in the same copper ink an inbox row tints its CTA with.
  /// Triage names an action item where it can; where it only judged that a
  /// reply is owed, the generic line still has to say so.
  ///
  /// A call to action the reader can act on: where the host gave it somewhere
  /// to go, the line is the way into the reply.
  Widget _askLine(Message message) {
    final ask = message.actionItems.isNotEmpty
        ? message.actionItems.first
        : 'Reply expected';
    // Through [showableDeadline], so plan-relative wording the extractor
    // repeated ("Day 1", "sprint 2") never wears a chip that reads like a
    // date the app worked out.
    final deadline = showableDeadline(message.deadline, now: DateTime.now());

    final onTap = widget.onAskTap;
    final line = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: BondSpacing.s8,
      runSpacing: BondSpacing.s4,
      children: [
        // An action item is written by a model reading the body, so it carries
        // whatever link the body carried — "Verify access at <url>". Not
        // selectable, because this line never was, and a tap on a link beats
        // the InkWell below to the gesture arena by sitting deeper in it.
        LinkedText(
          ask,
          style: BondType.caption.copyWith(
            color: BondColors.onAttentionTint,
            fontWeight: FontWeight.w600,
          ),
          onOpenLink: _openLink,
          selectable: false,
        ),
        if (deadline != null && deadline.isNotEmpty)
          BondChip.semantic(deadline, BondTone.attention),
      ],
    );

    if (onTap == null) return line;
    // Its own transparent Material: ink paints on the nearest Material
    // ancestor, which sits behind the pane's opaque surface — the same trap
    // `thread_detail_panel._ctaBanner` documents.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.smAll,
        child: line,
      ),
    );
  }

  Widget _avatar(Message message) {
    return BondAvatar(
      name: message.fromName,
      address: message.fromAddress,
      outbound: message.outbound,
      size: _avatarSize,
      // A stored message knows an address and never a Graph id, except for
      // Teams, where the address IS one wearing a `teams:` prefix.
      photoKey: photoKeyFor(address: message.fromAddress),
      photos: widget.photos,
    );
  }
}

/// The day separator between runs of messages — a hairline with the day's
/// name sitting in the gap.
class DayDivider extends StatelessWidget {
  final String label;

  const DayDivider({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s16),
      child: Row(
        children: [
          const Expanded(
            child: Divider(height: 1, color: BondColors.border),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
            child: Text(label, style: BondType.caption),
          ),
          const Expanded(
            child: Divider(height: 1, color: BondColors.border),
          ),
        ],
      ),
    );
  }
}

/// The Show more/less affordance — a quiet inline text toggle, kept local so
/// the row owns its own collapse without an ad-hoc button style.
class _ShowToggle extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _ShowToggle({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BondRadii.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          expanded ? 'Show less' : 'Show more',
          style: BondType.label.copyWith(
            letterSpacing: 0,
            color: BondColors.primary,
          ),
        ),
      ),
    );
  }
}
