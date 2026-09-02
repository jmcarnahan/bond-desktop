import '../../models/message_models.dart';

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
  final body = message.bodyText?.isNotEmpty == true
      ? message.bodyText!
      : (message.bodyPreview ?? '');
  final clipped = body.length > messageBlockBodyCap
      ? body.substring(0, messageBlockBodyCap)
      : body;

  return '${_sender(message)}\n'
      '${_subjectLine(message)}'
      'Received: ${message.receivedAt ?? ''}\n'
      '\n'
      'Body:\n$clipped';
}

/// Mail identifies a sender by address; a chat cannot. A chat's `from_address`
/// is `teams:<graph user id>` — a namespaced uuid the model can only be
/// distracted by — so a chat sender is the display name and nothing else.
String _sender(Message message) => switch (message.source) {
      'teams' => 'From: ${message.fromName ?? ''}',
      _ => 'From: ${message.fromName ?? ''} <${message.fromAddress ?? ''}>',
    };

/// A chat has no subject, ever (`TeamsSync.messageRow` stores null rather than
/// inventing one from the first line). An empty `Subject:` line would tell the
/// model a title was missing rather than that this channel has none.
String _subjectLine(Message message) => switch (message.source) {
      'teams' => '',
      _ => 'Subject: ${message.subject ?? ''}\n',
    };
