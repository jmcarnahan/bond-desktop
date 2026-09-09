import 'package:flutter/foundation.dart' show immutable;

import 'message_models.dart';

/// The two halves of the Drafts & sent pane: the model's unsent work, and the
/// user's own outbound mail.
///
/// They are separate types rather than one because they are separate things.
/// A draft is a suggestion nobody has agreed to, addressed to a message; a
/// sent row is a message that has already gone. What they share is a shape on
/// screen, not a shape in the store.

/// One suggestion waiting on the message its thread is waiting on.
///
/// Only the newest inbound message's suggestion is ever one of these — see
/// `MessageStore.pendingDrafts` — which is the same rule the composer resolves
/// its own draft by. That makes "the pane lists it" and "the thread would show
/// it" the same claim rather than two claims that can drift apart.
@immutable
class PendingDraft {
  final String source;
  final String conversationKey;

  /// The message this answers, which is also the row's key in `drafts`.
  final String replyToMessageId;

  final String body;

  /// `suggested` or `edited` — the two statuses that mean "still waiting".
  /// `sent` and `dismissed` never reach here.
  final String status;

  /// When the row was last written. What the list is ordered by, newest first:
  /// the freshest suggestion is the one about the most recent thing said.
  final String updatedAt;

  /// The thread's subject, joined from `conversations`.
  final String? subject;

  /// Who the reply is TO — the display name of the message being answered,
  /// falling back to its address. Null when the message is not stored, which
  /// can happen to a draft whose thread was pruned out from under it.
  final String? who;

  const PendingDraft({
    required this.source,
    required this.conversationKey,
    required this.replyToMessageId,
    required this.body,
    required this.status,
    required this.updatedAt,
    this.subject,
    this.who,
  });

  /// The pair every draft-shaped provider is keyed by. Spelled here so the
  /// pane's host does not have to reassemble it from two fields and get the
  /// order wrong.
  ({String source, String conversationKey}) get target =>
      (source: source, conversationKey: conversationKey);

  /// A row from `MessageStore.pendingDrafts`' projection.
  factory PendingDraft.fromRow(Map<String, Object?> row) {
    final name = (row['from_name'] as String?)?.trim();
    final address = (row['from_address'] as String?)?.trim();
    return PendingDraft(
      source: row['source'] as String? ?? 'email',
      conversationKey: row['conversation_key'] as String? ?? '',
      replyToMessageId: row['reply_to_message_id'] as String? ?? '',
      body: row['body'] as String? ?? '',
      status: row['status'] as String? ?? 'suggested',
      updatedAt: row['updated_at'] as String? ?? '',
      subject: row['subject'] as String?,
      // The name when there is one, the address when there is not — the same
      // fallback every other surface in the app uses to name a person.
      who: (name != null && name.isNotEmpty)
          ? name
          : ((address != null && address.isNotEmpty) ? address : null),
    );
  }
}

/// One message the user has already sent, mail or chat.
///
/// There is no `sent` table and there does not need to be: a send writes an
/// outbound row into `messages`, so the Sent list is that column read back.
/// Mail sends land first as local echoes and are replaced by the server's copy
/// on a later sync — [echo] is how a row says which of the two it still is.
@immutable
class SentRow {
  final String source;
  final String conversationKey;

  /// `source_message_id`. Provisional while [echo] is true.
  final String messageId;

  final String? subject;

  /// The recipients as stored, parsed exactly as [Message.fromRow] parses
  /// them — through [recipientsFromJson], so the two can never disagree about
  /// what a `to_json` blob means.
  final List<String> to;

  /// The first line of the message, from `body_preview` and then `body_text`.
  /// Null when the row carries neither.
  final String? preview;

  /// `COALESCE(received_at, created_at)` — never empty, because a locally
  /// written echo has no `received_at` until the server's copy arrives and a
  /// list ordered on a null would put the newest thing last.
  final String sentAt;

  const SentRow({
    required this.source,
    required this.conversationKey,
    required this.messageId,
    required this.to,
    required this.sentAt,
    this.subject,
    this.preview,
  });

  /// Whether this is still the app's own record of the send rather than the
  /// server's. The Sent Items copy has not landed yet, so the row is real mail
  /// with a provisional id — the pane says "syncing" rather than hiding it.
  bool get echo => messageId.startsWith(localEchoPrefix);

  /// A row from `MessageStore.recentOutbound`' projection.
  factory SentRow.fromRow(Map<String, Object?> row) {
    final preview = (row['body_preview'] as String?)?.trim();
    final body = (row['body_text'] as String?) ?? '';
    // The first LINE of the body, not the first hundred characters: a reply
    // opens with a greeting, and a row that ran on into the paragraph under it
    // would be a row nobody can scan.
    final firstLine = body.split('\n').first.trim();
    return SentRow(
      source: row['source'] as String? ?? 'email',
      conversationKey: row['conversation_key'] as String? ?? '',
      messageId: row['source_message_id'] as String? ?? '',
      subject: row['subject'] as String?,
      to: recipientsFromJson(row['to_json']),
      preview: (preview != null && preview.isNotEmpty)
          ? preview
          : (firstLine.isEmpty ? null : firstLine),
      sentAt: row['sent_at'] as String? ?? '',
    );
  }
}
