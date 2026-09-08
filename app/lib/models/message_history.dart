import 'package:flutter/foundation.dart' show immutable;

import '../services/activity_log.dart';
import 'home_models.dart';

/// Everything the app can say about ONE message: what it decided, when each
/// stage ran, what is still queued, where the thread was filed, and every line
/// the activity log wrote about any of it.
///
/// A read model and nothing else — assembled from rows a store handed over,
/// never from a store — so the whole shape can be built and asserted in a test
/// with no database around it.
///
/// Defensive in `home_models.dart`'s way: every field reads through a nullable
/// cast with a default, because a column an older build never wrote must
/// render as a blank line rather than throw inside the one screen a person
/// opened to find out what went wrong.

/// One pipeline stage as the progress row records it.
///
/// [at] is null while the stage is still `pending`, and stays null for a stage
/// that never ran: the store only stamps the clock on a terminal state, so an
/// absent time is the honest answer rather than a gap.
@immutable
class StageRecord {
  /// `triage` | `extract` | `storyline` | `draft` | `settle`.
  final String name;

  /// `pending` | `running` | `done` | `skipped` | `error`, raw for
  /// [HomeFeedRow]'s reason: the vocabulary is SQL's, and a value a newer
  /// build introduced must render as something.
  final String state;

  final String? at;

  const StageRecord(this.name, this.state, this.at);
}

/// One row of the work queue, as it stands.
///
/// [entityId] rides along rather than being implied by the message, because
/// the three grains that file here spell it three ways — the message id, the
/// conversation key, and `'<message id>|<attachment id>'` — and a reader
/// looking at a stuck queue needs to see which of them a row is about.
@immutable
class WorkRecord {
  final String kind;
  final String entityId;
  final String status;
  final int attempts;
  final String? error;
  final String updatedAt;

  const WorkRecord({
    required this.kind,
    required this.entityId,
    required this.status,
    this.attempts = 0,
    this.error,
    this.updatedAt = '',
  });

  factory WorkRecord.fromRow(Map<String, Object?> row) => WorkRecord(
        kind: row['task_kind'] as String? ?? '',
        entityId: row['entity_id'] as String? ?? '',
        status: row['status'] as String? ?? 'pending',
        attempts: (row['attempts'] as num?)?.toInt() ?? 0,
        error: row['error'] as String?,
        updatedAt: row['updated_at'] as String? ?? '',
      );
}

/// One storyline this message's thread was filed into.
///
/// [title] and [status] are nullable because the read behind this is a LEFT
/// JOIN: a filing outlives the storyline row it names, and the screen says
/// what happened rather than what still stands.
@immutable
class ThreadMembership {
  final String storylineId;
  final String? title;
  final String? status;

  /// `auto` or `user` — the model's filing or a person's.
  final String addedBy;

  final String? evidence;
  final String addedAt;

  const ThreadMembership({
    required this.storylineId,
    this.title,
    this.status,
    this.addedBy = 'auto',
    this.evidence,
    this.addedAt = '',
  });

  factory ThreadMembership.fromRow(Map<String, Object?> row) =>
      ThreadMembership(
        storylineId: row['storyline_id'] as String? ?? '',
        title: row['title'] as String?,
        status: row['status'] as String?,
        addedBy: row['added_by'] as String? ?? 'auto',
        evidence: row['evidence'] as String?,
        addedAt: row['added_at'] as String? ?? '',
      );

  bool get addedByUser => addedBy == 'user';
}

/// One storyline this message's thread was kept OUT of, and who said so.
@immutable
class ThreadBlock {
  final String storylineId;
  final String? title;
  final String? status;

  /// `user` is the owner's own removal; `audit` is the re-check pass that runs
  /// after one. Only the owner's is a lesson.
  final String blockedBy;

  final String? evidence;
  final String blockedAt;

  const ThreadBlock({
    required this.storylineId,
    this.title,
    this.status,
    this.blockedBy = 'user',
    this.evidence,
    this.blockedAt = '',
  });

  factory ThreadBlock.fromRow(Map<String, Object?> row) => ThreadBlock(
        storylineId: row['storyline_id'] as String? ?? '',
        title: row['title'] as String?,
        status: row['status'] as String?,
        blockedBy: row['blocked_by'] as String? ?? 'user',
        evidence: row['evidence'] as String?,
        blockedAt: row['blocked_at'] as String? ?? '',
      );

  bool get blockedByUser => blockedBy == 'user';
}

/// The whole story of one message, in the order a person asks it in: what it
/// is, what the app decided, how far it got, what is still owed, and what was
/// written down along the way.
@immutable
class MessageHistory {
  final String source;
  final String sourceMessageId;

  /// The thread's key, taken from the message row and falling back to the
  /// progress row — the two are written together, and either alone is enough
  /// to ask the thread-keyed reads their questions.
  final String conversationKey;

  /// False when there is no `messages` row at all: a message the wipe took, or
  /// a link followed after the mailbox was re-synced. The screen has one
  /// sentence for that and no rails.
  final bool exists;

  /// The feed row, when `message_progress` holds one — everything the home
  /// table already knows how to render, so the screen and the feed cannot
  /// disagree about the same message.
  final HomeFeedRow? row;

  final String? subject;
  final String? fromName;
  final String? fromAddress;
  final String? receivedAt;
  final String? direction;

  final String triageStatus;
  final int triageAttempts;
  final String? triageError;
  final String? gateReason;

  /// `user` when the owner has pulled this message back past the gates. It
  /// survives an Ignore on purpose — see `MessageStore.dropMessage` — so a
  /// reader has to be able to see both at once.
  final String? gateOverride;

  /// Three-valued, like [HomeFeedRow.needsYouVerdict]: null is "nothing has
  /// judged this yet", which sends a reader somewhere else entirely from "no".
  final bool? needsYouVerdict;

  final String? needsYouReason;
  final String? urgency;
  final String? category;
  final String? summary;

  final String? conversationState;
  final String? ctaText;
  final String? bucket;
  final String? bucketReason;
  final String? lastOutboundAt;
  final double? attentionScore;

  /// The bar [attentionScore] was measured against, read live rather than
  /// stored: a score means nothing without the threshold in force, and the
  /// owner can move it.
  final double threshold;

  /// Always five, in pipeline order, so the screen renders a fixed rail rather
  /// than a list whose length is a fact about the database.
  final List<StageRecord> stages;

  final List<WorkRecord> work;
  final List<ThreadMembership> memberships;
  final List<ThreadBlock> blocks;
  final List<ActivityEvent> events;

  const MessageHistory({
    required this.source,
    required this.sourceMessageId,
    required this.conversationKey,
    required this.exists,
    required this.threshold,
    this.row,
    this.subject,
    this.fromName,
    this.fromAddress,
    this.receivedAt,
    this.direction,
    this.triageStatus = 'pending',
    this.triageAttempts = 0,
    this.triageError,
    this.gateReason,
    this.gateOverride,
    this.needsYouVerdict,
    this.needsYouReason,
    this.urgency,
    this.category,
    this.summary,
    this.conversationState,
    this.ctaText,
    this.bucket,
    this.bucketReason,
    this.lastOutboundAt,
    this.attentionScore,
    this.stages = const [],
    this.work = const [],
    this.memberships = const [],
    this.blocks = const [],
    this.events = const [],
  });

  /// A message the store has nothing under. Still a [MessageHistory] rather
  /// than a null, so the screen has a source and an id to name in its one
  /// sentence.
  factory MessageHistory.missing(
    String source,
    String sourceMessageId, {
    required double threshold,
  }) =>
      MessageHistory(
        source: source,
        sourceMessageId: sourceMessageId,
        conversationKey: '',
        exists: false,
        threshold: threshold,
        stages: _pendingStages(),
      );

  /// The stages in the order the pipeline runs them, and the columns each one
  /// is written under. One list, so the rail and the assembler cannot disagree
  /// about which stages exist or what order they are in.
  static const List<({String name, String state, String at})> stageColumns = [
    (name: 'triage', state: 'triage_state', at: 'triage_at'),
    (name: 'extract', state: 'extract_state', at: 'extract_at'),
    (name: 'storyline', state: 'storyline_state', at: 'storyline_at'),
    (name: 'draft', state: 'draft_state', at: 'draft_at'),
    (name: 'settle', state: 'settle_state', at: 'settle_at'),
  ];

  static List<StageRecord> _pendingStages() => [
        for (final stage in stageColumns)
          StageRecord(stage.name, 'pending', null),
      ];

  /// Builds the whole story out of rows somebody else read.
  ///
  /// Pure on purpose: the reads are eight separate questions and the shape they
  /// fold into is the part worth pinning, so this takes their answers rather
  /// than a store. A null [message] is the only thing that makes
  /// [MessageHistory.exists] false — a progress row without one is a hole in
  /// the database, and the screen would rather say the message is gone than
  /// render half of it.
  static MessageHistory assemble({
    required String source,
    required String sourceMessageId,
    required Map<String, Object?>? message,
    required Map<String, Object?>? conversation,
    required Map<String, Object?>? conversationAi,
    required Map<String, Object?>? progress,
    required HomeFeedRow? row,
    required List<Map<String, Object?>> work,
    required List<Map<String, Object?>> memberships,
    required List<Map<String, Object?>> blocks,
    required List<Map<String, Object?>> activity,
    required double threshold,
  }) {
    if (message == null) {
      return MessageHistory.missing(
        source,
        sourceMessageId,
        threshold: threshold,
      );
    }
    return MessageHistory(
      source: source,
      sourceMessageId: sourceMessageId,
      conversationKey: message['conversation_key'] as String? ??
          progress?['conversation_key'] as String? ??
          '',
      exists: true,
      threshold: threshold,
      row: row,
      subject: message['subject'] as String?,
      fromName: message['from_name'] as String?,
      fromAddress: message['from_address'] as String?,
      receivedAt: message['received_at'] as String?,
      direction: message['direction'] as String?,
      triageStatus: message['triage_status'] as String? ?? 'pending',
      triageAttempts: (message['triage_attempts'] as num?)?.toInt() ?? 0,
      triageError: message['triage_error'] as String?,
      gateReason: message['gate_reason'] as String?,
      gateOverride: message['gate_override'] as String?,
      // Stored 0/1/null, and all three mean something different.
      needsYouVerdict: switch (message['needs_you_verdict'] as num?) {
        null => null,
        final n => n.toInt() == 1,
      },
      needsYouReason: message['needs_you_reason'] as String?,
      urgency: message['urgency'] as String?,
      category: message['category'] as String?,
      summary: message['summary'] as String?,
      conversationState: conversation?['state'] as String?,
      ctaText: conversation?['cta_text'] as String?,
      lastOutboundAt: conversation?['last_outbound_at'] as String?,
      bucket: conversationAi?['bucket'] as String?,
      bucketReason: conversationAi?['bucket_reason'] as String?,
      attentionScore: (conversationAi?['attention_score'] as num?)?.toDouble(),
      // Five either way. A message stored before the progress table existed
      // has no row, and five pending stages is the truthful reading of that:
      // nothing is recorded as having run.
      stages: progress == null
          ? _pendingStages()
          : [
              for (final stage in stageColumns)
                StageRecord(
                  stage.name,
                  progress[stage.state] as String? ?? 'pending',
                  progress[stage.at] as String?,
                ),
            ],
      work: [for (final item in work) WorkRecord.fromRow(item)],
      memberships: [
        for (final item in memberships) ThreadMembership.fromRow(item),
      ],
      blocks: [for (final item in blocks) ThreadBlock.fromRow(item)],
      events: [for (final item in activity) ActivityEvent.fromRow(item)],
    );
  }
}
