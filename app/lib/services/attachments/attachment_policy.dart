/// Which attachments this app spends a fetch on, and what one is called in
/// the work queue.
///
/// Pure and total, with no imports at all, because it is asked the same
/// question from four places that must never disagree: both sync paths ask it
/// before enqueuing work, and both handlers ask it again after claiming an
/// item. A message can be gated between those two moments — the user files a
/// thread, a re-triage skips it — and a judgement made only at enqueue time
/// would leave the handler fetching a document nobody will ever be shown.
///
/// Every refusal carries a word. It is stored in `attachments.text_reason`
/// and shown on the chip, so "why is this one not readable" has an answer at
/// the point the user asks it rather than in a log nobody opens.
library;

/// An inline image below this is decoration — a signature logo, a social
/// icon, a tracking pixel — and reading it costs a round trip for nothing.
/// Above it, a pasted screenshot is usually the whole message.
const int smallImageBytes = 20 * 1024;

/// The largest thing worth extracting text from. Below the server's own
/// 50 MB extraction ceiling on purpose: this is a judgement about what a
/// document IS — past 25 MB it is a video, an archive or a design file, none
/// of which are text a reply cites — and refusing here saves the fetch.
const int maxAttachmentBytes = 25 * 1024 * 1024;

/// How many of one message's attachments get read. A message carrying twenty
/// files is a distribution list or a backup, and the first five are what the
/// sender put at the top.
const int maxAttachmentsPerMessage = 5;

/// Whether [attachment] is worth extracting text from, and why not when it is
/// not.
///
/// [message] is a `messages` row; [attachment] is an `attachments` row, or the
/// row map about to be written for one — both are read by column name, so a
/// caller that has only just built the map can ask before it writes.
///
/// The gate check comes first and reads the way the pipeline reads elsewhere:
/// a message triage skipped is a message nothing downstream spends a model or
/// a network call on. Chat is the exception it has to make, because every
/// Teams message is born `skipped` under `teams_source` — that is a routing
/// fact about a channel with no detail fetch, not a judgement that the message
/// is junk.
///
/// Outbound is the second exception, and it has to be spelled out rather than
/// assumed: the owner's own documents are usually the most quotable thing on a
/// thread, but every outbound message is born `skipped` under `outbound`
/// (`gates.dart` `triageStatusOnInsert`), so a gate check that only excused
/// `teams_source` refused all of them. The predicate is
/// [MessageStore.recentStorylineMessages]' rule character for character —
/// outbound, or not skipped, or a chat.
(bool, String?) attachmentTextPolicy(
  Map<String, Object?> message,
  Map<String, Object?> attachment,
) {
  if (message['triage_status'] == 'skipped' &&
      message['direction'] != 'outbound' &&
      message['gate_reason'] != 'teams_source') {
    return (false, 'gated');
  }

  final kind = attachment['kind'] as String? ?? 'unknown';
  // A card is a rendering, a message_reference is a quote of something already
  // in the store, and an image has no words. Only these three carry a document.
  if (!const {'file', 'item', 'reference'}.contains(kind)) {
    return (false, 'kind_$kind');
  }

  // Both spellings, because the flag arrives as a bool from a connector and as
  // an int from a STRICT sqlite row.
  if (attachment['is_inline'] == true || attachment['is_inline'] == 1) {
    return (false, 'inline');
  }

  final contentType = (attachment['content_type'] as String? ?? '')
      .toLowerCase();
  final size = (attachment['size'] as num?)?.toInt() ?? 0;

  // Checked before the size cap so a tiny logo is refused as what it is,
  // rather than passing the cap and being fetched for nothing.
  if (contentType.startsWith('image/') && size < smallImageBytes) {
    return (false, 'small_image');
  }
  if (size > maxAttachmentBytes) return (false, 'too_large');

  // A link attachment with no url is unreachable. Today that is EVERY mail
  // reference attachment: neither the MCP server's select list nor the SDK's
  // `$expand` asks Graph for `sourceUrl`. The path is built and the refusal is
  // named so that a one-line server change turns these on with no change here.
  if (kind == 'reference' &&
      (attachment['source_url'] as String? ?? '').isEmpty &&
      (attachment['content_url'] as String? ?? '').isEmpty) {
    return (false, 'reference_no_url');
  }

  // The cap rides the connector's own ordinal rather than a running count, so
  // the same six-attachment message refuses the same sixth file every time it
  // is re-listed — a count would depend on which rows had already been judged.
  if (((attachment['ordinal'] as num?)?.toInt() ?? 0) >=
      maxAttachmentsPerMessage) {
    return (false, 'over_cap');
  }

  return (true, null);
}

/// One attachment's identity in the work queue, where the only key is a single
/// `entity_id` string.
///
/// `|` is the separator because it appears in neither half: a Graph attachment
/// id and a Teams hosted-content id are base64url, and a Teams message id is
/// decimal.
String attachmentEntityId(String messageId, String attachmentId) =>
    '$messageId|$attachmentId';

/// [attachmentEntityId] read back. A string with no separator is returned as a
/// message id with an empty attachment id — the handler treats that as a
/// malformed item rather than throwing, because a work row that cannot be
/// parsed must still be able to complete.
(String messageId, String attachmentId) splitAttachmentEntityId(String id) {
  final at = id.indexOf('|');
  return at < 0 ? (id, '') : (id.substring(0, at), id.substring(at + 1));
}
