/// Getting at what came with a message: its words, and its bytes.
///
/// A seam for the same reason [MailBackend] and [TeamsBackend] are seams — the
/// app reaches Microsoft two ways, through the Bond MCP server and through the
/// SDK, and every caller above this line must be unable to tell which. What is
/// asymmetric between the two implementations is stated here rather than
/// discovered: the server has a document extractor and the SDK does not, so the
/// SDK answers `skipped/no_extractor` for a Word file and fetches its bytes
/// exactly the same way.
///
/// The division of labour between a REFUSAL and a FAILURE is the whole contract:
///
/// - **A refusal is an answer.** A file too large to fetch, a link with no url,
///   an image with no words in it — none of those get better on a second
///   attempt, and none of them are errors. [extractText] returns
///   [AttachmentText.skipped]; [fetchBytes], which has no "no bytes" value to
///   return, throws [AttachmentUnavailable].
/// - **A failure is transport.** A socket that dropped, a throttle, a session
///   that needs consent again. Those throw the types the worker already routes
///   on — `GraphMailException`, `GraphTeamsException`, `NotSignedIn`,
///   `ReconsentRequired` — and are retried or park the drain accordingly.
///
/// Anything that conflates the two costs a document permanently (a retryable
/// failure recorded as a skip) or spends three requests establishing the same
/// no (a refusal retried as a failure).
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import '../../models/attachment_models.dart';

/// What one attachment says, or why it says nothing.
@immutable
class AttachmentText {
  /// `'ok'` or `'skipped'`. A String rather than an enum because it is written
  /// straight into `attachments.text_status`, which every other writer of that
  /// column also spells in words.
  final String status;

  final String? text;

  /// Whether the extractor stopped early. The reader is told where the words
  /// were cut rather than being left to believe a truncated document is the
  /// whole of it.
  final bool truncated;

  /// Why there are no words, when there are none: `binary`, `unsupported`,
  /// `too_large`, `reference`, `no_extractor`, `empty`, `access_denied`,
  /// `not_found`, `invalid_link`, `is_folder`, `external_sender`,
  /// `unavailable`, `gone`, `no_url`. Stored in `attachments.text_reason` and
  /// shown on the chip, so "why is this one not readable" is answered where the
  /// question gets asked.
  final String? reason;

  /// How many bytes the connector moved to answer. Recorded on the activity
  /// row: the cost of reading a document is the one number that tells a slow
  /// drain from a big mailbox.
  final int fetchedBytes;

  const AttachmentText.ok(
    String this.text, {
    this.truncated = false,
    this.fetchedBytes = 0,
  })  : status = 'ok',
        reason = null;

  const AttachmentText.skipped(String this.reason)
      : status = 'skipped',
        text = null,
        truncated = false,
        fetchedBytes = 0;
}

/// One attachment's bytes, and what the connector called them.
///
/// [contentType] and [name] are nullable because both connectors sometimes
/// decline to say: a hosted-content image has no file name at all, and Graph
/// reports `application/octet-stream` often enough that a caller must be able
/// to tell "no answer" from a real one. The cache and the preview both fall
/// back to the ref's own name.
@immutable
class AttachmentBytesResult {
  final Uint8List bytes;
  final String? contentType;
  final String? name;

  const AttachmentBytesResult(this.bytes, {this.contentType, this.name});
}

/// A permanent refusal from the connector — the file is not coming, and
/// retrying will not change that.
///
/// Never thrown for transport failures. Those are `GraphMailException`,
/// `GraphTeamsException`, `ReconsentRequired` and `NotSignedIn`, which the
/// worker already routes on; wrapping one of them here would turn a throttle
/// into a document permanently marked unreadable.
class AttachmentUnavailable implements Exception {
  /// The word, in the same vocabulary [AttachmentText.reason] uses, so a
  /// refusal that arrives while fetching bytes can be recorded as the text
  /// skip it amounts to.
  final String reason;

  /// Optional detail for a log. Never shown on its own — the reason is what
  /// the UI renders.
  final String message;

  const AttachmentUnavailable(this.reason, [this.message = '']);

  @override
  String toString() =>
      message.isEmpty ? 'AttachmentUnavailable($reason)' : '$reason: $message';
}

abstract class AttachmentBackend {
  /// The largest file this connector will hand over in one piece.
  ///
  /// A property of the CONNECTOR rather than of the app, which is why it lives
  /// on the seam: the two implementations have genuinely different ceilings,
  /// and a single constant would either refuse files the SDK path can fetch or
  /// send the server requests it answers with an error. The caller refuses
  /// above it before making the request, so the number is spent on nothing.
  int get maxPreviewBytes;

  /// The words in [ref], or a named reason there are none.
  ///
  /// Never throws for a permanent refusal — a refusal is an [AttachmentText]
  /// with `status == 'skipped'`.
  Future<AttachmentText> extractText(AttachmentRef ref);

  /// The bytes of [ref].
  ///
  /// [thumbnail] asks the connector for a rendered preview instead of the file
  /// itself: `''` for the file, or `'small'`, `'medium'`, `'large'` — which
  /// only a Teams shared file understands, because only OneDrive renders them.
  ///
  /// Throws [AttachmentUnavailable] for a permanent refusal; a transport
  /// failure throws its own type.
  Future<AttachmentBytesResult> fetchBytes(
    AttachmentRef ref, {
    String thumbnail = '',
  });
}
