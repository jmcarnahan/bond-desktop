import '../../models/attachment_models.dart';
import '../../models/message_models.dart';
import '../attachments/attachment_markers.dart';

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
  // A chat message can be nothing BUT a shared file — somebody dropped a
  // contract into a thread and typed no words with it — and an empty body
  // tells the model the message said nothing, which is the opposite of true.
  final body = stripped.isEmpty ? attachmentStandIn(message.attachments) : stripped;
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
String attachmentStandIn(List<AttachmentRef> attachments) {
  final shared = [for (final a in attachments) if (!a.isInline) a];
  if (shared.isEmpty) return attachments.isEmpty ? '' : 'Shared an image';

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
String senderLine(Message message) => switch (message.source) {
      'teams' => 'From: ${message.fromName ?? ''}',
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
/// one. One number, shared by every task that fences a digest, so the three
/// prompts cannot come to disagree about how much history a stage reads.
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
/// It stays first, and the lines that survive keep their original order.
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
String _trimHeader(int dropped) =>
    '(thread digest trimmed to fit; $dropped older lines omitted)';

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
/// Needs-you is the deliberate exception: its `_contextText` quotes a
/// `From:` / `Sent:` transcript of its own and is not meant to converge.
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

/// Markers out, for [buildMessageBlock]'s reason — a tail is quoted text too,
/// and a `[[att:…]]` in it is a token nobody typed.
String _tailBody(Message message) => stripAttachmentMarkers(
      message.bodyText?.isNotEmpty == true
          ? message.bodyText!
          : message.bodyPreview,
    );

String _clampTail(String value, int cap) =>
    value.length > cap ? value.substring(0, cap) : value;
