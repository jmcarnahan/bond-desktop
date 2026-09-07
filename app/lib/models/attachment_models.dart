import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// One thing that came with a message, and what the app has managed to learn
/// about it.
///
/// ONE model for the whole round rather than a UI shape and a service shape:
/// the chip that draws it, the backend that fetches its bytes, and the handler
/// that reads its words all name the same fields, so a column added later has
/// exactly one place to be plumbed through.
///
/// **No value equality, deliberately.** A `==` over thirty fields would say
/// two refs differ because a digest landed between two frames, which is
/// exactly when a selected preview must NOT be dropped. Every comparison the
/// UI makes goes through `sameAttachment`, which compares the two ids that
/// actually identify a file.
@immutable
class AttachmentRef {
  /// Which connector this came from — `'email'` or `'teams'`. The first half
  /// of the primary key, and never derivable from the ids: a Teams
  /// hosted-content id and a Graph attachment id are the same alphabet.
  final String source;

  /// The message it came with. `messages.source_message_id`.
  final String messageId;

  /// The connector's own identity for this file: a Graph attachment id for
  /// mail, an entry id or a hosted-content id for chat.
  final String attachmentId;

  /// The order the connector listed it in. What the chips draw in, and what
  /// the text policy caps on — a running count would refuse a different file
  /// on every re-list.
  final int ordinal;

  /// `file|item|reference|image|card|message_reference|other|unknown`.
  final String kind;

  final String? name;
  final String? contentType;

  /// Bytes, with **0 meaning unknown** rather than empty. The Teams wire never
  /// states a size, so a nullable int would put a null check at every call
  /// site to say the same thing; `formatBytes(0)` renders nothing.
  final int size;

  /// Whether the sender's client placed this inside the body rather than
  /// attaching it — a signature logo, a pasted screenshot.
  final bool isInline;

  /// The `cid:` value an inline image is referenced by from the HTML body.
  /// The join key that turns `[cid:logo@example]` in a mail body into this
  /// row.
  final String? contentId;

  /// Where the file lives when it is a link rather than a payload: a OneDrive
  /// or SharePoint URL for a reference attachment or a Teams shared file.
  final String? sourceUrl;

  final String? thumbnailUrl;

  /// The text of an adaptive card, when the connector rendered one. What a
  /// card-only chat message says instead of a body.
  final String? cardText;

  // ── An `item` attachment: a message forwarded as a file ──────────────
  final String? itemSubject;
  final String? itemFrom;
  final String? itemReceived;

  /// `pending|done|skipped|error` — owned by the text handler. `pending` on
  /// every row the sync writes, including ones the policy has already refused:
  /// the refusal is recorded when the handler claims the item, so the reason
  /// and the status are written by the same hand.
  final String textStatus;

  /// Why there are no words — a policy word (`inline`, `too_large`,
  /// `small_image`, `reference_no_url`, …) or a connector one (`no_extractor`,
  /// `access_denied`). Null while pending and on success.
  final String? textReason;

  final bool textTruncated;
  final int textChars;

  /// `pending|done|skipped|error` — owned by the digest handler.
  final String digestStatus;

  /// What the model made of the document, or null when it has not read one.
  final AttachmentDigest? digest;

  // ── The local cache (Phase 2 writes these) ───────────────────────────
  final String? blobPath;
  final String? blobSha256;
  final String? blobFetchedAt;
  final String? thumbPath;

  /// The storyline the owner pinned this document to, or null. The one column
  /// on this row a person sets by hand, which is why a re-sync never touches
  /// it.
  final String? pinnedStorylineId;

  /// The chat this message is in — `messages.conversation_key`, carried along
  /// because every Teams attachment call needs a chat id and the row itself
  /// has no column for one. Null for mail, where the message id is enough.
  final String? conversationKey;

  const AttachmentRef({
    required this.source,
    required this.messageId,
    required this.attachmentId,
    this.ordinal = 0,
    this.kind = 'file',
    this.name,
    this.contentType,
    this.size = 0,
    this.isInline = false,
    this.contentId,
    this.sourceUrl,
    this.thumbnailUrl,
    this.cardText,
    this.itemSubject,
    this.itemFrom,
    this.itemReceived,
    this.textStatus = 'pending',
    this.textReason,
    this.textTruncated = false,
    this.textChars = 0,
    this.digestStatus = 'pending',
    this.digest,
    this.blobPath,
    this.blobSha256,
    this.blobFetchedAt,
    this.thumbPath,
    this.pinnedStorylineId,
    this.conversationKey,
  });

  /// Where the bytes come from when they are not a payload. An alias for
  /// [sourceUrl] and not a second column: the backends ask for "the url this
  /// is fetched by", and naming it twice in the store would be two things to
  /// keep in step.
  String? get contentUrl => sourceUrl;

  /// An `attachments` row, as the store returns it.
  ///
  /// [conversationKey] is passed in because it lives on `messages`, not here —
  /// callers that joined it (or already know the thread) hand it over, and
  /// everything else gets null.
  ///
  /// Defensive in the models' house style: every field reads through a
  /// nullable cast with a default, so a half-written row cannot throw during a
  /// render.
  factory AttachmentRef.fromRow(
    Map<String, Object?> row, {
    String? conversationKey,
  }) {
    return AttachmentRef(
      source: row['source'] as String? ?? 'email',
      messageId: row['source_message_id'] as String? ?? '',
      attachmentId: row['attachment_id'] as String? ?? '',
      ordinal: (row['ordinal'] as num?)?.toInt() ?? 0,
      kind: row['kind'] as String? ?? 'file',
      name: row['name'] as String?,
      contentType: row['content_type'] as String?,
      size: (row['size'] as num?)?.toInt() ?? 0,
      isInline: _flag(row['is_inline']),
      contentId: row['content_id'] as String?,
      sourceUrl: row['source_url'] as String?,
      thumbnailUrl: row['thumbnail_url'] as String?,
      cardText: row['card_text'] as String?,
      itemSubject: row['item_subject'] as String?,
      itemFrom: row['item_from'] as String?,
      itemReceived: row['item_received'] as String?,
      textStatus: row['text_status'] as String? ?? 'pending',
      textReason: row['text_reason'] as String?,
      textTruncated: _flag(row['text_truncated']),
      textChars: (row['text_chars'] as num?)?.toInt() ?? 0,
      digestStatus: row['digest_status'] as String? ?? 'pending',
      digest: decodeAttachmentDigest(row['digest_json'] as String?),
      blobPath: row['blob_path'] as String?,
      blobSha256: row['blob_sha256'] as String?,
      blobFetchedAt: row['blob_fetched_at'] as String?,
      thumbPath: row['thumb_path'] as String?,
      pinnedStorylineId: row['pinned_storyline_id'] as String?,
      // The join's own column wins when a caller did not name one, which is
      // how `attachmentsForStoryline` and `pinnedAttachmentsForStoryline` hand
      // the chat id over.
      conversationKey:
          conversationKey ?? row['conversation_key'] as String?,
    );
  }

  /// STRICT sqlite has no bool: a flag arrives as 0/1, and as a real bool from
  /// a connector map that has not been through the database yet.
  static bool _flag(Object? raw) => raw == 1 || raw == true;
}

/// What the fast model made of one attached document.
///
/// Written by the digest handler, read by the row (`AI:` line), the storyline
/// recap, and the needs-you re-verdict. Every field is model output and is
/// therefore rendered as such — under the same `AI:` label as every other
/// model line, never as though the document said it directly.
@immutable
class AttachmentDigest {
  /// One sentence naming what this document is and why it was sent.
  final String evidence;

  /// `quote|invoice|contract|schedule|report|slides|spreadsheet|form|letter|other`
  /// — what the document IS, not what its file extension says.
  final String kind;

  /// One sentence saying what the document says.
  final String summary;

  /// The specific things a person would quote back: amounts, dates, names,
  /// terms. Empty when the document states none.
  final List<String> facts;

  /// What the document requires of the reader — a signature, a payment, a date
  /// to confirm. Empty is the common case, and is what the needs-you
  /// re-verdict keys off.
  final List<String> asks;

  const AttachmentDigest({
    this.evidence = '',
    this.kind = 'other',
    this.summary = '',
    this.facts = const [],
    this.asks = const [],
  });

  /// Never throws, and never rejects: a missing key reads as empty, and a
  /// value of the wrong type reads as absent. A digest is a convenience on top
  /// of a document the app already stored, and a malformed one must cost a
  /// line of a recap rather than the render around it.
  factory AttachmentDigest.fromJson(Map<String, Object?> json) {
    return AttachmentDigest(
      evidence: json['evidence'] as String? ?? '',
      kind: json['kind'] as String? ?? 'other',
      summary: json['summary'] as String? ?? '',
      facts: _strings(json['facts']),
      asks: _strings(json['asks']),
    );
  }

  /// ALL FIVE keys, always, including the empty ones.
  ///
  /// Load-bearing: the store asks "does this message carry an ask" with a LIKE
  /// over the encoded JSON rather than a JSON1 extract, so `"asks":[` has to
  /// be present in every digest ever written, whatever it contains.
  Map<String, Object?> toJson() => {
        'evidence': evidence,
        'kind': kind,
        'summary': summary,
        'facts': facts,
        'asks': asks,
      };

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item != null) item.toString(),
    ];
  }
}

/// A `digest_json` column as an [AttachmentDigest], or null.
///
/// Null for absent, empty, unparseable, and anything that does not decode to a
/// map — every one of those means the same thing to every caller ("no digest
/// yet"), and a throw here would take out a list render.
AttachmentDigest? decodeAttachmentDigest(String? json) {
  if (json == null || json.isEmpty) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    return AttachmentDigest.fromJson(Map<String, Object?>.from(decoded));
  } on FormatException {
    return null;
  }
}

/// One passage of one document, and how near it sits to what was asked.
///
/// The chunk search's unit, and deliberately NOT a [SemanticHit]: a message hit
/// is a feed row a person already recognises, where this is a fragment of a
/// file — it has to say WHICH file, WHERE in it, and who sent it, or the reader
/// is shown three sentences with no idea what they are from.
///
/// [ref] carries the whole attachment row, `conversationKey` included, because
/// every use of a hit is an action on the file behind it: opening the preview,
/// pinning it to a storyline, quoting it into a reply.
@immutable
class AttachmentChunkHit {
  /// The document this passage came out of.
  final AttachmentRef ref;

  /// `attachment_chunks.id` — also the passage's rowid in the vector index.
  final int chunkId;

  /// Where it sits in the document's own order, from zero.
  final int seq;

  /// Where a person would look to find it: `Sheet Q3 rows 42–81`, `slide 4`,
  /// `part 2`, `digest`, or empty for a document that is one passage.
  final String locator;

  final String text;

  /// Who attached it. Null when the message behind it is gone — the pin
  /// outlives the message, so the hit has to too.
  final String? senderName;

  /// Whether the owner is the one who sent it.
  final bool outbound;

  final String? receivedAt;

  /// Cosine distance: 0 is identical, 1 orthogonal, 2 opposed.
  final double distance;

  const AttachmentChunkHit({
    required this.ref,
    required this.chunkId,
    required this.seq,
    required this.locator,
    required this.text,
    this.senderName,
    required this.outbound,
    this.receivedAt,
    required this.distance,
  });

  String? get name => ref.name;

  String? get contentType => ref.contentType;
}
