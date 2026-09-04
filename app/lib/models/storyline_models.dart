import 'package:flutter/foundation.dart' show immutable;

import 'message_models.dart';

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

  /// The membership criteria the confirm task judges candidates against.
  /// Auto-drafted by the naming pass; locked the moment a person edits it.
  final String? charter;

  /// Set once a person edits the charter. Same contract as [titleLocked]: a
  /// later naming pass may keep refreshing everything else, but what belongs
  /// in the storyline is then the user's call.
  final bool charterLocked;

  final bool pinned;

  /// The newest `last_message_at` of any member thread. Only ever moves
  /// forward — see `MessageStore.touchStorylineActivity`.
  final String? lastActivityAt;

  /// The dedupe key for the member set as it stands, maintained by every
  /// membership write. Null on a row that has no member set to describe — a
  /// cluster the sweep tombstoned without ever storing one.
  final String? memberHash;

  /// The membership as it stood the last time the refresh pass described this
  /// storyline. The gate is an equality test against [memberHash], so a thread
  /// added since leaves these stale and the pass runs again. Null on a
  /// storyline nobody has described yet.
  final String? refreshedMemberHash;
  final int? refreshedMemberCount;

  /// What the refresh pass would have written to [charter] if the charter were
  /// not the user's. A locked charter is never overwritten — the model's
  /// version waits here for the user to accept or dismiss it.
  final String? charterSuggestion;

  /// The recap: where things stand across every member thread, so the reader
  /// need not re-read them. [recapOpenJson] and [recapDecisionsJson] are JSON
  /// arrays of short strings, kept as text because nothing but the recap pane
  /// reads them. [recapThrough] is the `received_at` of the newest message the
  /// recap has seen — what makes the pass skip a storyline nothing happened in.
  final String? recapText;
  final String? recapOpenJson;
  final String? recapDecisionsJson;
  final String? recapThrough;

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
    this.charter,
    this.charterLocked = false,
    this.pinned = false,
    this.lastActivityAt,
    this.memberHash,
    this.refreshedMemberHash,
    this.refreshedMemberCount,
    this.charterSuggestion,
    this.recapText,
    this.recapOpenJson,
    this.recapDecisionsJson,
    this.recapThrough,
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
      charter: row['charter'] as String?,
      charterLocked: (row['charter_locked'] as num?)?.toInt() == 1,
      pinned: (row['pinned'] as num?)?.toInt() == 1,
      lastActivityAt: row['last_activity_at'] as String?,
      memberHash: row['member_hash'] as String?,
      refreshedMemberHash: row['refreshed_member_hash'] as String?,
      refreshedMemberCount: (row['refreshed_member_count'] as num?)?.toInt(),
      charterSuggestion: row['charter_suggestion'] as String?,
      recapText: row['recap_text'] as String?,
      recapOpenJson: row['recap_open_json'] as String?,
      recapDecisionsJson: row['recap_decisions_json'] as String?,
      recapThrough: row['recap_through'] as String?,
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

/// One member thread's whole run inside a storyline — the unit the storyline
/// pane renders as a card.
///
/// Assembled by `StorylineTimelineNotifier`, not read from a table: the store
/// answers with messages, and which thread each one belongs to is a column on
/// the row rather than a field on [Message].
@immutable
class StorylineEpisode {
  final String source;
  final String conversationKey;

  /// First non-empty stripped subject in chronological order — the same rule
  /// the conversation fold uses, so the card matches the inbox row. Empty when
  /// no message carries one.
  final String subject;

  /// Distinct sender display names in first-appearance order.
  final List<String> participants;

  /// The thread's messages, oldest first.
  final List<Message> messages;

  /// The newest message's timestamp; null when none carries one.
  final String? latestAt;

  /// The newest inbound message's triage summary; null until triage has run.
  final String? summary;

  /// Where the thread sits in the reply lifecycle, read from its conversation
  /// row when the episode is assembled. It rides on the episode so a card can
  /// say the thread needs the user by the SAME rule the thread panel uses,
  /// rather than by a second one that could drift from it. Defaults to
  /// [ConversationState.waiting] — a thread with no row demands nothing.
  final ConversationState state;

  /// The ask the triage pass wrote for the thread, from the same conversation
  /// row as [state]. Null until triage has found one; only ever rendered
  /// together with a [ConversationState.needsReply] state.
  final String? ctaText;

  const StorylineEpisode({
    required this.source,
    required this.conversationKey,
    required this.subject,
    required this.participants,
    required this.messages,
    this.latestAt,
    this.summary,
    this.state = ConversationState.waiting,
    this.ctaText,
  });

  /// The composite a storyline's membership is keyed on. A conversation key is
  /// only unique within its connector.
  String get threadKey => '$source\n$conversationKey';
}
