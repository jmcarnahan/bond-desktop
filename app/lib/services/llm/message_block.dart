import '../../models/attachment_models.dart';
import '../../models/message_models.dart';
import '../attachments/attachment_markers.dart';
import '../mail_body.dart' show stripLinkTargets;
import '../sender_display.dart';

/// Enough of a body for a model to judge intent. Past this it is quoted thread
/// and signatures, which cost tokens and add nothing.
const int messageBlockBodyCap = 4000;

/// One inbound message, rendered for a prompt.
///
/// **The one place a channel's shape is known.** Every task that puts a
/// message in front of the model — triage, extraction, and whatever comes
/// next — renders it through here, so "a chat has no subject line, and its
/// address is a Graph id nobody should read" is a fact this file holds and no
/// task repeats. A per-task copy of the block is how the two sources would
/// quietly drift apart.
///
/// The whole block is the sender's own text, headers included, which is why
/// callers fence all of it rather than just the body.
String buildMessageBlock(Message message) {
  final raw = message.bodyText?.isNotEmpty == true
      ? message.bodyText!
      : (message.bodyPreview ?? '');
  // The markers come out before anything else looks at the body. `[[att:AAMk…]]`
  // is a token this app minted, and a model shown one reasons about the token
  // rather than about the message.
  final stripped = stripAttachmentMarkers(raw);
  // Then the `<target>` tail off every canonical link run, leaving the label.
  // BEFORE the cap and not after: an automated mail spends a hundred
  // characters of tracking query per anchor, and a strip that ran afterwards
  // would have let those bytes push the sentence somebody wrote past 4000.
  final unlinked = stripLinkTargets(stripped);
  // A chat message can be nothing BUT a shared file — somebody dropped a
  // contract into a thread and typed no words with it — and an empty body
  // tells the model the message said nothing, which is the opposite of true.
  final spoken =
      unlinked.isEmpty ? attachmentStandIn(message.attachments) : unlinked;
  // The quote goes ABOVE the words, the way it reads on screen: "29 and 30" is
  // an answer to a question, and the model can only see which question if it is
  // told what this reply was pointed at.
  final quoted = quotedReplyLines(message.attachments);
  final body = quoted.isEmpty ? spoken : '$quoted\n$spoken';
  final clipped = body.length > messageBlockBodyCap
      ? body.substring(0, messageBlockBodyCap)
      : body;

  return '${senderLine(message)}\n'
      '${_subjectLine(message)}'
      'Received: ${message.receivedAt ?? ''}\n'
      '\n'
      'Body:\n$clipped';
}

/// How many attachment names a stand-in sentence lists, and how much of a
/// card it quotes.
const int _standInNames = 3;
const int _standInCardCap = 300;

/// How much of a quoted message a reply's `↪` line carries. Short on purpose:
/// it is there to say WHICH turn is being answered, and the quoted message is
/// almost always in the thread tail already.
const int _quotePreviewCap = 200;

/// How many quoted turns a reply gets to name. Teams sends one — a quote-reply
/// points at a single message and there is no compose surface that quotes two —
/// so this is a ceiling on a shape nobody has seen, not a policy.
///
/// It is here because these lines sit AHEAD of the body and the whole thing is
/// clipped to [messageBlockBodyCap] afterwards: enough quote lines would spend
/// the budget on other people's sentences and clip away the words this message
/// actually said, which is the one thing the prompt cannot do without.
const int quotedReplyMaxLines = 2;

/// What a reply quoted, as one line the model can read whom it answers from.
///
/// `↪ replying to <sender>: <preview>`, and nothing when the message quoted
/// nothing. A Teams quote-reply arrives as an attachment with no name
/// ([quoteAttachmentKind]), so before this the prompt was told the message had
/// shared a file called `(unnamed)` — a sentence about a file that does not
/// exist, in place of the one fact the quote carries.
///
/// Either half alone is still worth a line: a sender with no snippet says who
/// is being answered, and a snippet with no sender says which turn. Past
/// [quotedReplyMaxLines] the rest are dropped silently: there is nothing useful
/// to say about quotes a reader will never see, and a `(+3 more)` note would
/// cost body characters to say it.
String quotedReplyLines(List<AttachmentRef> attachments) {
  final lines = <String>[];
  for (final attachment in attachments) {
    if (lines.length == quotedReplyMaxLines) break;
    if (!attachment.isQuoteReply) continue;
    final sender = attachment.quotedSender?.trim() ?? '';
    final preview = _clampQuote(attachment.quotedPreview?.trim() ?? '');
    if (sender.isEmpty && preview.isEmpty) continue;
    lines.add(switch ((sender.isEmpty, preview.isEmpty)) {
      (false, false) => '↪ replying to $sender: $preview',
      (false, true) => '↪ replying to $sender',
      _ => '↪ replying to: $preview',
    });
  }
  return lines.join('\n');
}

String _clampQuote(String preview) => preview.length > _quotePreviewCap
    ? preview.substring(0, _quotePreviewCap)
    : preview;

/// What a message with no words of its own says instead.
///
/// Reads from [AttachmentRef] rather than raw rows because [Message.attachments]
/// is what every caller already has: [MessageStore.loadThread] hydrates it with
/// one query per thread, so a prompt builder never has to go looking.
///
/// Three answers, in the order they are worth having. A rendered card IS the
/// message — somebody sent a poll or an approval request and the card carries
/// its text. Failing that, the names of the files say what arrived. Failing
/// both, the message is an image and nothing more, which is worth saying
/// exactly once rather than describing.
///
/// Inline rows are filtered out first: a signature logo is not what a message
/// is about, and "Shared a file: image001.png" on a mail with an empty unique
/// body would be a sentence about a footer.
///
/// Quote-replies come out with them, and for a sharper reason: a quote is
/// neither a file nor a card, its `card_text` is somebody ELSE's sentence, and
/// its missing name is what used to make a quote-reply read `Shared a file:
/// (unnamed)`. [quotedReplyLines] says what a quote is, above the body.
String attachmentStandIn(List<AttachmentRef> attachments) {
  final carried = [for (final a in attachments) if (!a.isQuoteReply) a];
  final shared = [for (final a in carried) if (!a.isInline) a];
  if (shared.isEmpty) return carried.isEmpty ? '' : 'Shared an image';

  for (final attachment in shared) {
    final card = attachment.cardText?.trim() ?? '';
    if (card.isEmpty) continue;
    return card.length > _standInCardCap
        ? card.substring(0, _standInCardCap)
        : card;
  }

  final names = [
    for (final attachment in shared.take(_standInNames))
      (attachment.name ?? '').trim().isEmpty ? '(unnamed)' : attachment.name!,
  ];
  return 'Shared a file: ${names.join(', ')}';
}

/// Mail identifies a sender by address; a chat cannot. A chat's `from_address`
/// is `teams:<graph user id>` — a namespaced uuid the model can only be
/// distracted by — so a chat sender is the display name and nothing else.
///
/// Public because the block is not the only place a sender is named: the
/// drafting task renders its thread lines through here too, which is what
/// keeps "a chat sender is a name, not an address" a fact this file holds
/// rather than a rule two prompts each remember separately.
///
/// The chat name goes through [displaySenderName], which is what stops the one
/// row that has no name — a bot stored before ingest started calling it `Bot` —
/// from rendering `From:` with nothing after it. Mail's line is untouched: its
/// address is a fact the model may use, and it already sits where the model
/// expects it.
String senderLine(Message message) => switch (message.source) {
      'teams' => 'From: ${displaySenderName(name: message.fromName)}',
      _ => 'From: ${message.fromName ?? ''} <${message.fromAddress ?? ''}>',
    };

/// How directly this message came at the reader, in one line.
///
/// Derived from the `addressed_me` the connector wrote at ingest — sole To:
/// recipient for mail, a 1:1 chat or an @mention for Teams — plus the To: count
/// the row already carries. It is the APP's own statement about the message,
/// not the sender's, which is why callers put it OUTSIDE the fence: it is a
/// fact the model may act on rather than text it must only analyse.
///
/// A NULL or false `addressed_me` collapses into the quiet case deliberately.
/// A connector that never wrote the column, and one that wrote "no", both mean
/// the same thing here — nothing knows this message singled the reader out —
/// and reading either as "yes" would push a group broadcast up the list.
String buildDirectnessLine(Message message) {
  if (message.source == 'teams') {
    return message.addressedMe
        ? 'Addressed to: you directly (a 1:1 chat, or you are @mentioned).'
        : 'Addressed to: a group chat, not you specifically.';
  }
  if (message.addressedMe) return 'Addressed to: only you.';
  if (message.to.length > 1) {
    return 'Addressed to: you and ${message.to.length - 1} others.';
  }
  return 'Addressed to: you indirectly (CC, a list, or unknown).';
}

/// A chat has no subject, ever (`TeamsSync.messageRow` stores null rather than
/// inventing one from the first line). An empty `Subject:` line would tell the
/// model a title was missing rather than that this channel has none.
String _subjectLine(Message message) => switch (message.source) {
      'teams' => '',
      _ => 'Subject: ${message.subject ?? ''}\n',
    };

/// The digest's own budget inside a prompt, in characters.
///
/// Roughly three quoted thread messages' worth, and deliberately smaller than
/// the digest the packer builds (its own cap is 2000): the digest is CONTEXT
/// sitting above the message being judged, and a context block that outweighs
/// the message is how a loud older turn gets classified in place of the new
/// one. One number, shared by every task that fences a digest, so no two
/// prompts can come to disagree about how much history a stage reads.
const int threadDigestCap = 900;

/// Trims [digest] to [cap] by WHOLE LINES, dropping from the OLD end.
///
/// A `substring(0, cap)` clamp would do the opposite of what is wanted here: a
/// digest is oldest-first, so a head clip keeps the oldest lines and throws
/// away the newest — which is exactly where an open ask lives. So the budget
/// is spent from the newest end backwards, the way the packer itself spends
/// it.
///
/// The `(thread has N earlier messages; M quoted below)` header is kept
/// whatever else goes: without it a trimmed digest reads as the whole thread.
/// It stays first, its M is rewritten to the number of lines that actually
/// survive (so it never claims more than the reader gets), and the lines that
/// survive keep their original order.
///
/// A digest with no header of its own was quoted whole by its builder, so a
/// trim here is the first thing that leaves anything out — and it says so,
/// with a synthesized header naming how many older lines went, whenever the
/// budget can carry that line AND at least one whole line beneath it. Under a
/// budget too small for both, the newest lines win and the trim is silent:
/// a header that ate the last whole turn would be a worse prompt than no
/// header.
///
/// A digest already under the cap comes back byte for byte. When not even the
/// newest single line fits beside the header, that line is clipped from its
/// END so the result is exactly [cap] characters — half a line of the newest
/// turn beats none of it.
String fitThreadDigest(String digest, int cap) {
  if (digest.length <= cap) return digest;

  final lines = digest.split('\n');
  final hasHeader = lines.first.startsWith('(thread has ');
  final rest = hasHeader ? lines.sublist(1) : lines;

  // The newest lines of [rest] that fit under [header], oldest first.
  List<String> keep(String? header) {
    var used = header?.length ?? 0;
    final kept = <String>[];
    for (var i = rest.length - 1; i >= 0; i--) {
      final line = rest[i];
      // The newline that joins this line to whatever is already above it. The
      // very first piece of the result carries none.
      final extra =
          (header == null && kept.isEmpty) ? line.length : line.length + 1;
      // The first line that does not fit ends it: older lines are shorter
      // only by accident, and skipping one to squeeze in an older one would
      // print a history with a hole in it that nothing names.
      if (used + extra > cap) break;
      used += extra;
      kept.insert(0, line);
    }
    return kept;
  }

  var header = hasHeader ? lines.first : null;
  var kept = keep(header);
  if (header != null && kept.length < rest.length) {
    // The packer's header counts what IT quoted; once lines are dropped here
    // that count overstates what the reader gets, so it is rewritten to the
    // lines that survive — one when only a clipped newest line does. The
    // packer writes one line per quoted message, so the count only falls and
    // the rewritten header is never longer; the guard is for a header that
    // does not match its own lines, which is left as it came rather than
    // risk a join one character over the cap.
    final requoted = _requote(header, kept.isEmpty ? 1 : kept.length);
    if (requoted.length <= header.length) header = requoted;
  }
  if (header == null && kept.isNotEmpty && kept.length < rest.length) {
    // Re-fit under the synthesized line; its length depends on the count's
    // digits, so once more if the count moved, and never more than a couple.
    var dropped = rest.length - kept.length;
    for (var pass = 0; pass < 3; pass++) {
      final announced = keep(_trimHeader(dropped));
      if (announced.isEmpty) break; // too tight to say so: stay silent
      final droppedNow = rest.length - announced.length;
      if (droppedNow == dropped) {
        header = _trimHeader(dropped);
        kept = announced;
        break;
      }
      dropped = droppedNow;
    }
  }

  if (kept.isNotEmpty) {
    return [?header, ...kept].join('\n');
  }

  // Nothing but the header fits. A header longer than the whole budget is
  // clipped to it; a header that fills the budget to within one character
  // leaves no room for a newline and is returned whole; otherwise the newest
  // line fills what is left.
  if (header == null) return rest.last.substring(0, cap);
  // `rest` cannot be empty here: a digest that is nothing but its header is
  // shorter than the header and came back unchanged at the top.
  if (header.length + 1 >= cap) {
    return header.length > cap ? header.substring(0, cap) : header;
  }
  return '$header\n${rest.last.substring(0, cap - header.length - 1)}';
}

/// The line a trimmed header-less digest is given, in the packer's own idiom.
String _trimHeader(int dropped) => '(thread digest trimmed to fit; '
    '$dropped older line${dropped == 1 ? '' : 's'} omitted)';

/// The packer's `(thread has N earlier messages; M quoted below)` with M
/// replaced by [quoted]. A header not in that shape comes back unchanged.
String _requote(String header, int quoted) => header.replaceFirstMapped(
      RegExp(r'; \d+ quoted below\)$'),
      (_) => '; $quoted quoted below)',
    );

/// The thread tail as a transcript: who spoke, then what they said.
///
/// Deliberately not [buildMessageBlock] — headers on every quoted message
/// would cost more prompt than the quotes themselves, and the only thing a
/// tail has to establish is what was said and whether the reader answered it.
/// "You" for the reader's own messages is the whole point of that second half:
/// a thread whose last word is theirs is a thread nobody is waiting on.
///
/// Lives here rather than inside one task because two prompts render this
/// tail — triage, and extraction at the rungs the replay prices — and a
/// per-task copy is how the two would come to quote a thread differently.
/// [max] messages from the NEWEST end, each clipped at [cap].
String buildThreadTailText(List<Message> thread, {int max = 3, int cap = 300}) {
  if (thread.isEmpty) return '';
  final tail =
      thread.length > max ? thread.sublist(thread.length - max) : thread;
  return [
    for (final message in tail)
      '${message.outbound ? 'You' : (message.fromName ?? '')}: '
          '${_clampTail(_tailBody(message), cap)}',
  ].join('\n---\n');
}

/// Markers out and link targets with them, for [buildMessageBlock]'s reasons —
/// a tail is quoted text too, so a `[[att:…]]` in it is a token nobody typed
/// and a `<target>` in it is tracking query where the words should be. The tail
/// is where that bites hardest: its cap is 300 characters, so one automated
/// anchor could spend a whole quoted turn without saying anything, which is
/// why the strip runs before [_clampTail] rather than after.
String _tailBody(Message message) => stripLinkTargets(
      stripAttachmentMarkers(
        message.bodyText?.isNotEmpty == true
            ? message.bodyText!
            : message.bodyPreview,
      ),
    );

String _clampTail(String value, int cap) =>
    value.length > cap ? value.substring(0, cap) : value;
