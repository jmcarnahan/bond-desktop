import 'package:flutter/foundation.dart' show immutable;

import 'attachment_models.dart';

/// The Files stop's vocabulary: one shelf, four ways to look at it.
///
/// Not file TYPES — a reader hunting a document is not thinking in MIME. The
/// four are the three things a message can carry (a document, a picture, a
/// link) plus the whole pile, which is where the shelf starts.
enum FilesKind { all, documents, images, links }

extension FilesKindLabel on FilesKind {
  String get label => switch (this) {
        FilesKind.all => 'All',
        FilesKind.documents => 'Documents',
        FilesKind.images => 'Images',
        FilesKind.links => 'Links',
      };
}

/// One file on the shelf, with enough of its message to file it under a day
/// and open the thread it came from.
///
/// The attachment itself is an [AttachmentRef] rather than a flattened copy of
/// its columns, because every widget that draws a file already speaks that
/// type — the card, the unfurl, the preview panel and the pin all take one.
/// What is added here is the handful of message columns the shelf needs and
/// the attachments table does not have: who sent it, when, and what the thread
/// was called.
@immutable
class FileRow {
  /// The file, built from the joined row — which carries `conversation_key`,
  /// so [AttachmentRef.fromRow] picks it up without being told.
  final AttachmentRef ref;

  final String? fromName;
  final String? fromAddress;

  /// Whether the owner is the one who sent it. `messages.direction`, resolved
  /// here so the pane can say "you" without knowing the wire word.
  final bool outbound;

  /// `messages.received_at` — what the day grouping and the relative time are
  /// both read from.
  final String? receivedAt;

  /// The thread's subject, which is also the label on the way back into it.
  final String? subject;

  const FileRow({
    required this.ref,
    this.fromName,
    this.fromAddress,
    this.outbound = false,
    this.receivedAt,
    this.subject,
  });

  /// A row from `MessageStore.recentAttachments`' projection.
  ///
  /// Defensive in the models' house style: every field reads through a
  /// nullable cast with a default, so a half-written row costs a caption
  /// rather than the render around it.
  factory FileRow.fromRow(Map<String, Object?> row) => FileRow(
        ref: AttachmentRef.fromRow(row),
        fromName: row['from_name'] as String?,
        fromAddress: row['from_address'] as String?,
        outbound: (row['direction'] as String?) == 'outbound',
        receivedAt: row['received_at'] as String?,
        subject: row['subject'] as String?,
      );

  String get source => ref.source;

  /// The thread this file came with, or null when the join had none. What the
  /// caption's way back into the conversation is keyed by.
  String? get conversationKey => ref.conversationKey;
}
