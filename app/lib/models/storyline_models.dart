import 'package:flutter/foundation.dart' show immutable;

/// Row models for storylines — the named groups of related conversations the
/// clustering pass proposes and the user keeps, renames or dismisses.
///
/// Defensive in the same way `message_models.dart` is: every field reads
/// through a nullable cast with a default, so neither a half-written row nor a
/// column an older build never wrote can throw during a render.

/// One storyline as stored, plus the two counts the list query derives.
///
/// [status] stays a raw string rather than an enum: it is written by the
/// service, read by the UI, and a value from a newer build must render as
/// something rather than crash a list. The four it takes are
/// `suggested` | `active` | `dismissed` | `archived`.
@immutable
class Storyline {
  final String id;
  final String title;
  final String? summary;
  final String status;

  /// `auto` when the sweep proposed it, `user` when a person created it. It is
  /// what lets the UI say "you added this" rather than showing model evidence
  /// for something the model had no part in.
  final String createdBy;

  /// Set once a person renames it. A locked title survives every later
  /// re-naming pass — the model may keep refreshing the summary underneath it,
  /// but the name is the user's.
  final bool titleLocked;

  final bool pinned;

  /// The newest `last_message_at` of any member thread. Only ever moves
  /// forward — see `MessageStore.touchStorylineActivity`.
  final String? lastActivityAt;

  /// Derived by the list query, not stored: how many threads belong to this
  /// storyline, and how many of those are awaiting a reply.
  final int memberCount;
  final int openCount;

  const Storyline({
    required this.id,
    required this.title,
    this.summary,
    this.status = 'suggested',
    this.createdBy = 'auto',
    this.titleLocked = false,
    this.pinned = false,
    this.lastActivityAt,
    this.memberCount = 0,
    this.openCount = 0,
  });

  bool get isSuggested => status == 'suggested';

  /// A row from `storylines`, optionally carrying the `member_count` /
  /// `open_count` the list query joins on. Both default to zero, so a bare
  /// `SELECT *` still reads.
  factory Storyline.fromRow(Map<String, Object?> row) {
    return Storyline(
      id: row['id'] as String? ?? '',
      title: row['title'] as String? ?? '',
      summary: row['summary'] as String?,
      status: row['status'] as String? ?? 'suggested',
      createdBy: row['created_by'] as String? ?? 'auto',
      // STRICT has no bool: these are 0/1 integers.
      titleLocked: (row['title_locked'] as num?)?.toInt() == 1,
      pinned: (row['pinned'] as num?)?.toInt() == 1,
      lastActivityAt: row['last_activity_at'] as String?,
      memberCount: (row['member_count'] as num?)?.toInt() ?? 0,
      openCount: (row['open_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One thread's membership in a storyline.
///
/// [evidence] is the sentence that justifies the membership — the model's
/// reason for an `auto` row, and null for a `user` one, where the reason is
/// simply that a person said so.
@immutable
class StorylineMember {
  final String storylineId;
  final String source;
  final String conversationKey;
  final String addedBy;
  final String? evidence;
  final String addedAt;

  const StorylineMember({
    required this.storylineId,
    this.source = 'email',
    required this.conversationKey,
    this.addedBy = 'auto',
    this.evidence,
    this.addedAt = '',
  });

  bool get addedByUser => addedBy == 'user';

  factory StorylineMember.fromRow(Map<String, Object?> row) {
    return StorylineMember(
      storylineId: row['storyline_id'] as String? ?? '',
      source: row['source'] as String? ?? 'email',
      conversationKey: row['conversation_key'] as String? ?? '',
      addedBy: row['added_by'] as String? ?? 'auto',
      evidence: row['evidence'] as String?,
      addedAt: row['added_at'] as String? ?? '',
    );
  }
}
