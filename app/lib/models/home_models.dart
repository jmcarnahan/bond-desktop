import 'package:flutter/foundation.dart' show immutable;

/// Row models for the home screen — the live table of messages moving through
/// the AI pipeline, and the counts above it.
///
/// Defensive in the same way `message_models.dart` is: every field reads
/// through a nullable cast with a default, so neither a half-written row nor a
/// column an older build never wrote can throw during a render.

/// One message's trip through the pipeline, as one feed row.
///
/// Every stage state is a raw string rather than an enum, for the reason a
/// storyline's status is one: the vocabulary is
/// `pending` | `running` | `done` | `skipped` | `error`, it is written by SQL,
/// and a value a newer build introduced must render as something rather than
/// crash the table someone left open all day.
///
/// [needsYou], [urgency] and [storylineId] are SNAPSHOTS, frozen when the app
/// settled the message. That is what makes scrolling back through history
/// honest: a thread that has since gone quiet still shows the verdict the user
/// was actually given at the time.
@immutable
class HomeFeedRow {
  final String source;
  final String sourceMessageId;
  final String conversationKey;

  /// The paging key, and never null: the store writes
  /// `COALESCE(received_at, created_at)`.
  final String receivedAt;

  final String triageState;
  final String extractState;
  final String storylineState;
  final String settleState;

  /// `pending` while the pipeline is still working, then `done` or `dropped`.
  final String outcome;

  /// True when the app decided the user does not need this one. Redundant
  /// against [outcome] on purpose — see the `message_progress` DDL.
  final bool dropped;

  /// Why, in the vocabulary the gates and the notify sweep already use
  /// (`newsletter`, `no_reply`, `not_worthy`, …). Null unless [dropped].
  final String? dropReason;

  final String? storylineId;

  /// The storyline's name, or null when the row joined none.
  ///
  /// Not filtered by the storyline's status, deliberately: the row is a record
  /// of what the app filed this message under at the time, and a title that
  /// vanished because the group was dismissed last week would leave a reader
  /// scrolling past history that no longer says what happened.
  final String? storylineTitle;

  final bool needsYou;
  final String? urgency;

  final String? subject;
  final String? fromName;
  final String? fromAddress;

  const HomeFeedRow({
    required this.source,
    required this.sourceMessageId,
    required this.conversationKey,
    required this.receivedAt,
    required this.triageState,
    required this.extractState,
    required this.storylineState,
    required this.settleState,
    required this.outcome,
    required this.dropped,
    this.dropReason,
    this.storylineId,
    this.storylineTitle,
    this.needsYou = false,
    this.urgency,
    this.subject,
    this.fromName,
    this.fromAddress,
  });

  factory HomeFeedRow.fromRow(Map<String, Object?> row) => HomeFeedRow(
        source: row['source'] as String? ?? 'email',
        sourceMessageId: row['source_message_id'] as String? ?? '',
        conversationKey: row['conversation_key'] as String? ?? '',
        receivedAt: row['received_at'] as String? ?? '',
        triageState: row['triage_state'] as String? ?? 'pending',
        extractState: row['extract_state'] as String? ?? 'pending',
        storylineState: row['storyline_state'] as String? ?? 'pending',
        settleState: row['settle_state'] as String? ?? 'pending',
        outcome: row['outcome'] as String? ?? 'pending',
        dropped: (row['dropped'] as num?)?.toInt() == 1,
        dropReason: row['drop_reason'] as String?,
        storylineId: row['storyline_id'] as String?,
        storylineTitle: row['storyline_title'] as String?,
        needsYou: (row['needs_you'] as num?)?.toInt() == 1,
        urgency: row['urgency'] as String?,
        subject: row['subject'] as String?,
        fromName: row['from_name'] as String?,
        fromAddress: row['from_address'] as String?,
      );

  /// The pair the feed is keyed and cursored by. A message id is only unique
  /// within its connector, so neither half stands alone.
  ({String source, String id}) get key =>
      (source: source, id: sourceMessageId);

  /// [key] as one string — what list items are keyed by and what the live
  /// phase's entering/fading/collapsing sets hold. Defined once here because
  /// the provider and the pane must agree on it byte for byte: a set keyed by
  /// one spelling and widgets keyed by another is an animation that never
  /// finds its row. Newline as the joint — neither connector's ids contain
  /// one.
  String get feedKey => '$source\n$sourceMessageId';
}

/// The numbers over the feed, all of them over one window.
///
/// One statement writes every field, which is what makes them agree with each
/// other: read separately, a message settling between two queries would be
/// counted in one and not the other, and the tiles would disagree by one for
/// as long as nobody reloaded.
@immutable
class HomeMetrics {
  final int emails;
  final int teams;

  /// `urgent` or `high` — the same pair the notify sweep treats as an ask.
  final int urgent;

  /// What the app decided the user did not need. The same number the "Show
  /// dropped" toggle reveals, so the tile is a promise the toggle keeps.
  final int dropped;

  final int needsYou;

  /// Messages whose thread landed in a storyline.
  final int storylined;

  /// Still moving: `outcome = 'pending'`.
  final int inFlight;

  /// Messages where some stage ended in `error`. Counted once however many
  /// stages failed — this is "how many messages went wrong", not "how many
  /// things went wrong".
  final int errored;

  final int total;

  const HomeMetrics({
    this.emails = 0,
    this.teams = 0,
    this.urgent = 0,
    this.dropped = 0,
    this.needsYou = 0,
    this.storylined = 0,
    this.inFlight = 0,
    this.errored = 0,
    this.total = 0,
  });

  factory HomeMetrics.fromRow(Map<String, Object?> row) {
    int at(String column) => (row[column] as num?)?.toInt() ?? 0;
    return HomeMetrics(
      emails: at('emails'),
      teams: at('teams'),
      urgent: at('urgent'),
      dropped: at('dropped'),
      needsYou: at('needs_you'),
      storylined: at('storylined'),
      inFlight: at('in_flight'),
      errored: at('errored'),
      total: at('total'),
    );
  }
}

/// One storyline the window was busy with: how much landed in it and when it
/// last moved.
@immutable
class HotStoryline {
  final String id;
  final String title;

  /// Messages that landed in it inside the window — the "hot" a dashboard
  /// means, rather than the storyline's lifetime size.
  final int messageCount;

  final String lastAt;

  const HotStoryline({
    required this.id,
    required this.title,
    required this.messageCount,
    required this.lastAt,
  });

  factory HotStoryline.fromRow(Map<String, Object?> row) => HotStoryline(
        id: row['id'] as String? ?? '',
        title: row['title'] as String? ?? '',
        messageCount: (row['message_count'] as num?)?.toInt() ?? 0,
        lastAt: row['last_at'] as String? ?? '',
      );
}
