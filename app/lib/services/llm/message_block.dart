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
