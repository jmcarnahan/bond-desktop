import 'package:flutter/foundation.dart' show immutable;

import 'attachment_models.dart';

/// Row models for the home screen — the live table of messages moving through
/// the AI pipeline, and the counts above it.
///
/// Defensive in the same way `message_models.dart` is: every field reads
/// through a nullable cast with a default, so neither a half-written row nor a
/// column an older build never wrote can throw during a render.

/// How long a dropped row stays on screen, grayed, before it starts to go.
/// The whole point of showing it at all is that the reader gets to see WHAT
/// was dropped and why, so it has to outlast a glance.
const Duration homeDropLinger = Duration(seconds: 3);

/// The collapse that takes the grayed row off the table.
///
/// Here, beside the linger, because two files have to agree on it byte for
/// byte: the row animates its height down over this, and the notifier waits
/// exactly this long before deleting it. Deleting early leaves a jump;
/// deleting late leaves a gap where the row already was.
const Duration homeDropCollapse = Duration(milliseconds: 180);

/// How long a still-pending row may go without a progress write before it is
/// called stuck rather than slow.
///
/// Fifteen minutes is longer than any single stage takes and shorter than a
/// person's patience with a bar that is not moving. The tile's SQL and the
/// row's Dart both read this one number, so a list with two flags on it and a
/// tile that counted three cannot happen.
const Duration homeStalledAfter = Duration(minutes: 15);

/// How far back the hot-storylines strip looks.
///
/// A week, not a day. "What has this mailbox been busy with" is a question
/// about a stretch of time, and a day is short enough that a quiet Sunday —
/// or a test account — reads as an empty strip, which looks like a fault
/// rather than a quiet day. A week is the unit the rest of the app already
/// reasons in (the needs-you re-judge, the default lookback presets).
///
/// The tiles no longer read it. They count the whole feed, because every tile
/// is a filter and a filter's number has to be the number of rows under it.
const Duration homeMetricsWindow = Duration(days: 7);

/// How far back the pipeline pulse counts as "just now".
///
/// Ten minutes, where the tiles look back a week. The pulse is a reading of
/// what the machine is doing at this moment, and a pipeline that takes
/// seventeen seconds a message fills ten minutes with real work — long enough
/// that a quiet stretch is visible as a quiet stretch, short enough that
/// yesterday's drain is not still being reported as news.
const Duration homePulseWindow = Duration(minutes: 10);

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
///
/// The reason fields are the opposite and are meant to be: [needsYouReason],
/// [gateReason], [bucketReason], [storylineEvidence] and the rest are the
/// pipeline's own record of why it decided what it did, read live on every
/// query. A row has to be able to explain itself with what the pipeline
/// believes NOW, or the explanation would go on defending a decision that has
/// since been revised.
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

  /// Where the reply pipeline got to. `skipped` is the common end here: most
  /// messages are not worth answering, and a bar that waited for a draft that
  /// was never going to be written would never finish.
  final String draftState;

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

  /// What triage said this message was about, in its own words
  /// (`messages.summary`). Null until triage has run, and null for good on a
  /// message the gate threw out before reading it.
  final String? summary;

  /// The ask the app wrote for this row's THREAD (`conversations.cta_text`).
  ///
  /// Per thread where [summary] is per message, which is exactly why they are
  /// two fields and not one: the ask is restated every time the thread moves,
  /// so a row can carry an ask that was written about a message NEWER than
  /// itself. That is the honest reading — the thread is still owed the same
  /// thing — and collapsing the two would make an old row claim a new
  /// message's words as its own summary.
  final String? ctaText;

  /// The thread's live state (`conversations.state`) — `needs_reply`, `done`,
  /// and the rest of the rail's vocabulary. Null when the message has no
  /// thread row yet.
  ///
  /// The rail's Needs You rule reads it, and [needsYou] — the settle pass's
  /// snapshot, frozen on the message — does not. Both are on the row on
  /// purpose: the snapshot is the verdict the reader was given at the time,
  /// and this is what is true now, which is what the tile counting threads has
  /// to agree with.
  final String? threadState;

  /// Whether the message carried anything attached, straight off
  /// `messages.has_attachments`. False on any read that did not select the
  /// column — which reads as "nothing attached" rather than as a paperclip on
  /// a message that has none.
  ///
  /// It is here so `has:file` can be answered without a second query per hit:
  /// a search returns fifty rows and a per-row attachment lookup would be
  /// fifty reads to decide which ones to throw away.
  final bool hasAttachments;
  /// When the pipeline last wrote anything about this row. The stalled
  /// clock's zero, and empty only on a path that predates the column.
  final String updatedAt;

  /// The needs-you judgement as it stands on the message. Null is its own
  /// answer — nothing has judged this one yet — and is why it is not a plain
  /// bool: "no" and "not asked" send a reader to different places.
  final bool? needsYouVerdict;

  /// Why the verdict went that way, in the judge's own words.
  final String? needsYouReason;

  /// Why triage let the message through, or did not. Distinct from
  /// [dropReason], which is the gate's verdict recorded on the progress row.
  final String? gateReason;

  /// Where the attention sweep filed the thread — `later`, `done`, and the
  /// rest of the archive rail's vocabulary. Null when nothing has ruled.
  final String? bucket;

  /// Who decided the [bucket], or `user` when a person did.
  final String? bucketReason;

  /// The sweep's ranking score for the thread, 0 to 1. Null before it ran.
  final double? attentionScore;

  /// What the storyline pass wrote down for joining this thread to its
  /// storyline. Null when the row is filed nowhere.
  final String? storylineEvidence;

  /// `auto` or `user` — whether the filing was the model's or a person's.
  final String? storylineAddedBy;

  /// True when something is queued or running for this message, its thread,
  /// or one of its documents. A row with work open is never stalled, however
  /// long it has been sitting there.
  final bool workOpen;

  const HomeFeedRow({
    required this.source,
    required this.sourceMessageId,
    required this.conversationKey,
    required this.receivedAt,
    required this.triageState,
    required this.extractState,
    required this.storylineState,
    required this.draftState,
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
    this.summary,
    this.ctaText,
    this.threadState,
    this.hasAttachments = false,
    this.updatedAt = '',
    this.needsYouVerdict,
    this.needsYouReason,
    this.gateReason,
    this.bucket,
    this.bucketReason,
    this.attentionScore,
    this.storylineEvidence,
    this.storylineAddedBy,
    this.workOpen = false,
  });

  factory HomeFeedRow.fromRow(Map<String, Object?> row) => HomeFeedRow(
        source: row['source'] as String? ?? 'email',
        sourceMessageId: row['source_message_id'] as String? ?? '',
        conversationKey: row['conversation_key'] as String? ?? '',
        receivedAt: row['received_at'] as String? ?? '',
        triageState: row['triage_state'] as String? ?? 'pending',
        extractState: row['extract_state'] as String? ?? 'pending',
        storylineState: row['storyline_state'] as String? ?? 'pending',
        draftState: row['draft_state'] as String? ?? 'pending',
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
        summary: row['summary'] as String?,
        ctaText: row['cta_text'] as String?,
        threadState: row['thread_state'] as String?,
        hasAttachments: (row['has_attachments'] as num?)?.toInt() == 1,
        updatedAt: row['updated_at'] as String? ?? '',
        // Three-valued on purpose: null stays null, and only a stored 1 is a
        // yes. Anything else the column could hold is a no. `Message.fromRow`
        // reads the same column through its `_boolFromInt` (non-zero is a
        // yes); the store normalises the column to 0/1/NULL, so the two agree
        // on every value it can hold — keep them agreeing if either moves.
        needsYouVerdict: switch (row['needs_you_verdict'] as num?) {
          null => null,
          final n => n.toInt() == 1,
        },
        needsYouReason: row['needs_you_reason'] as String?,
        gateReason: row['gate_reason'] as String?,
        bucket: row['bucket'] as String?,
        bucketReason: row['bucket_reason'] as String?,
        attentionScore: (row['attention_score'] as num?)?.toDouble(),
        storylineEvidence: row['storyline_evidence'] as String?,
        storylineAddedBy: row['storyline_added_by'] as String?,
        workOpen: (row['work_open'] as num?)?.toInt() == 1,
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

  /// This row as it will read once Restore has run — the optimistic twin of
  /// `MessageStore.restoreProgress`, the same reset spelled on the model.
  ///
  /// It exists so a pane can show the row un-dropped in the same frame the
  /// button was pressed in, rather than waiting on the write and the re-read.
  /// [needsYou], [urgency] and the storyline fields carry over untouched for
  /// the store method's reason: triage and settle will restate them, and
  /// blanking them here would only make the row flicker on its way to the
  /// same values. The identity and text fields are facts about the message
  /// and were never in question.
  HomeFeedRow restored() => HomeFeedRow(
        source: source,
        sourceMessageId: sourceMessageId,
        conversationKey: conversationKey,
        receivedAt: receivedAt,
        triageState: 'pending',
        extractState: 'pending',
        storylineState: 'pending',
        draftState: 'pending',
        settleState: 'pending',
        outcome: 'pending',
        dropped: false,
        dropReason: null,
        storylineId: storylineId,
        storylineTitle: storylineTitle,
        needsYou: needsYou,
        urgency: urgency,
        subject: subject,
        fromName: fromName,
        fromAddress: fromAddress,
        summary: summary,
        ctaText: ctaText,
        threadState: threadState,
        hasAttachments: hasAttachments,
        updatedAt: updatedAt,
        needsYouVerdict: needsYouVerdict,
        needsYouReason: needsYouReason,
        gateReason: gateReason,
        bucket: bucket,
        bucketReason: bucketReason,
        attentionScore: attentionScore,
        storylineEvidence: storylineEvidence,
        storylineAddedBy: storylineAddedBy,
        // `RestoreService` queues the work in the same breath as the reset, so
        // the optimistic row must not spend a frame claiming to be stalled.
        workOpen: true,
      );

  /// Still pending, nothing queued or running for it or its thread, and no
  /// progress write for [homeStalledAfter]. [now] is a parameter, never read
  /// from the clock, so a test can pin the threshold.
  ///
  /// An unreadable [updatedAt] answers false rather than true: an unknown
  /// clock is not evidence that anything went wrong, and a row accused of
  /// being stuck because a column was never written would send the reader
  /// after a fault that is not there.
  bool isStalled(DateTime now) {
    if (outcome != 'pending') return false;
    if (workOpen) return false;
    final since = DateTime.tryParse(updatedAt)?.toUtc();
    if (since == null) return false;
    return now.toUtc().difference(since) >= homeStalledAfter;
  }
}

/// One semantic-search result: a feed row, and how far its message sat from
/// the query.
///
/// [distance] is vec0's cosine distance, not a similarity — 0 is identical, 1
/// is orthogonal, and smaller is better. It rides along rather than being
/// thrown away because it is the only thing that can tell a screen the
/// difference between "the top hit answers the question" and "the top hit is
/// merely the least bad of a bad list".
@immutable
class SemanticHit {
  final HomeFeedRow row;
  final double distance;

  const SemanticHit(this.row, this.distance);
}

/// One keyword-search result: a feed row, how well the words scored, and how
/// much of the query it actually contained.
///
/// [SemanticHit]'s opposite number, and shaped like it for the same reason —
/// the store hands back a ranking plus the number the ranking was made from,
/// and the fusion above needs both.
@immutable
class KeywordHit {
  final HomeFeedRow row;

  /// FTS5's bm25 score, already NEGATED at the index so that bigger is better.
  /// It has no absolute scale; it is only meaningful against the best score
  /// the same query found.
  final double bm25;

  /// The fraction of the query's terms this row contains, 0 to 1.
  ///
  /// The correction bm25 needs. An OR query lets a row that matched one rare
  /// word top the ranking on that word's rarity alone, and without this the
  /// message containing only "12" would outrank the one that answers the
  /// question.
  final double coverage;

  const KeywordHit(this.row, {required this.bm25, required this.coverage});
}

/// Which half of a search found a row.
///
/// Not a display label — nothing prints it yet. It is the fact a later "why
/// this result?" surface will be built from, and recording it at the moment
/// the two rankings are merged is far cheaper than reconstructing it after.
enum MatchedBy { meaning, words, both }

/// One search result, whichever way it was found.
///
/// Replaces the ranked-hits-plus-text-rows pair the search used to hand back.
/// Two lists meant a reader saw the same mailbox twice under two headings,
/// with the row that BOTH passes found sitting at the top of one and buried in
/// the other; one list with one score puts it where it belongs.
///
/// The numbers ride along rather than being discarded after the sort. Nothing
/// shows them today; they are what a per-row explanation would need, and a
/// score with no evidence behind it is the kind of thing nobody can debug.
@immutable
class SearchHit {
  final HomeFeedRow row;

  /// The fused relevance, 0 to 1. Everything below `SearchTuning.minScore` was
  /// dropped before this list was built, so a hit that is here earned it.
  final double score;

  /// Cosine distance from the query, or null when the index did not find this
  /// row — a gate-dropped message was never embedded and can only ever arrive
  /// by words.
  final double? distance;

  /// The word pass's score, bigger-is-better, or null when only meaning found
  /// it.
  final double? bm25;

  final MatchedBy matchedBy;

  const SearchHit({
    required this.row,
    required this.score,
    this.distance,
    this.bm25,
    required this.matchedBy,
  });
}

/// The search results a reader is looking at, in place of the live feed.
///
/// Down here beside [SemanticHit] rather than up in the feed's notifier,
/// because the pane renders it and the pane reads no providers: the models are
/// the floor both the state and the widget can stand on.
@immutable
class HomeSearch {
  /// The query the [hits] answer — carried with them, so a result set that
  /// arrived after the box was typed into again is labelled by what it is
  /// rather than by what is on screen.
  final String query;

  /// ONE ranking, meaning and words together, best first.
  ///
  /// Never null: an empty list is a real answer — nothing matches — and the
  /// state where there is no answer at all is no [HomeSearch] at all.
  ///
  /// Each [SearchHit] carries the numbers `search_fusion.dart` ranked it by,
  /// so a row found both ways sits above the rows found one way instead of
  /// appearing twice under two headings. Gate-dropped mail was never embedded
  /// and can only ever arrive here by its words, which is what makes it
  /// findable at all when *Show dropped* is on.
  final List<SearchHit> hits;

  /// The passages of attached documents that answer the same query. Never
  /// null, for [hits]' reason: an empty list is a real answer.
  final List<AttachmentChunkHit> documents;

  /// Non-null when only one half of the search ran — the meaning pass or the
  /// word pass could not — and this set of results is narrower than it looks.
  ///
  /// Travels with the rows for [ArchiveSearch.notice]'s reason: it is a fact
  /// about this answer, not a standing condition of the screen.
  final String? notice;

  const HomeSearch(
    this.query,
    this.hits, {
    this.documents = const [],
    this.notice,
  });
}

/// The archive pane's result set: what a search of the whole history came back
/// with, and whether half of it was missing.
///
/// Rows and not hits, because the archive renders feed rows and has nowhere to
/// put a score: the fused ranking still decides the ORDER, and then it is
/// flattened. A shape that carried the numbers would carry them for nobody.
///
/// [notice] travels WITH the results rather than beside them on the screen:
/// "only one half of the search ran" is a fact about THIS result set — the
/// answer is narrower than it looks — and not a standing condition of the pane.
///
/// Down here beside [HomeSearch] for its reason: the pane renders this and the
/// pane reads no providers.
@immutable
class ArchiveSearch {
  /// The query the [rows] answer, trimmed — so a set that landed after the box
  /// was typed into again is labelled by what it is.
  final String query;

  /// One fused ranking, best first, meaning and words together. Never null:
  /// empty is a real answer.
  final List<HomeFeedRow> rows;

  /// Non-null when only one half of the search ran and the other answered
  /// alone.
  final String? notice;

  const ArchiveSearch(this.query, this.rows, this.notice);
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

  /// The subset of [inFlight] that has stopped moving — pending, with nothing
  /// queued or running for it, and no progress write since the cutoff the
  /// caller bound. Counted here so the tile and the flags on the rows below
  /// it are one answer rather than two.
  final int stalled;

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
    this.stalled = 0,
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
      stalled: at('stalled'),
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

/// What the pipeline is doing right now, and what it has just finished.
///
/// The tiles answer "what has the app been doing lately" over a week; this
/// answers "is anything happening" over ten minutes, which is a different
/// question and the one a reader asks when the table under a filter looks
/// emptier than they expected. The filter may be hiding the work — the pulse
/// is what says so.
///
/// The stage words are keys rather than an enum for [HomeFeedRow]'s reason:
/// they are read out of `work_items.task_kind` and `messages.triage_status`,
/// and a kind a newer build introduces must be skippable rather than a crash.
@immutable
class PipelinePulse {
  /// Stage word → items waiting, keyed by [stages]. A stage nothing is queued
  /// for is ABSENT rather than zero, so a caller can tell "nothing waiting"
  /// from "this stage was never asked about".
  final Map<String, int> queued;

  /// Stage word → items being worked, keyed the same way.
  final Map<String, int> running;

  /// Settled, dropped and judged-needs-you inside [homePulseWindow] — measured
  /// on `message_progress.updated_at`, which is when the pipeline last wrote
  /// about the row rather than when the message arrived.
  final int recentSettled;
  final int recentDropped;
  final int recentNeedsYou;

  /// Still `outcome = 'pending'`, whatever their age. Not window-bounded on
  /// purpose: a message stuck since yesterday is exactly the one a reader
  /// wants counted, and a ten-minute window would quietly stop mentioning it.
  final int inFlight;

  const PipelinePulse({
    this.queued = const {},
    this.running = const {},
    this.recentSettled = 0,
    this.recentDropped = 0,
    this.recentNeedsYou = 0,
    this.inFlight = 0,
  });

  /// Pipeline order — the order any narration walks. Triage first because it
  /// is the gate everything else is downstream of, files last because a
  /// document's text is read after the message it hangs off has been handled.
  static const List<String> stages = [
    'triage',
    'extract',
    'needs_you',
    'storyline',
    'draft',
    'embed',
    'files',
  ];

  /// `work_items.task_kind` → stage word.
  ///
  /// Several kinds collapse onto one stage on purpose: the six storyline
  /// passes are one thing to a reader, and both attachment kinds are "files".
  /// A kind that is not here is not pipeline work and is not counted —
  /// `mark_read` is a chore the app runs on the user's behalf, and a pulse
  /// that reported it as a stage would be narrating housekeeping.
  static const Map<String, String> kindStages = {
    'extract': 'extract',
    'needs_you': 'needs_you',
    'draft': 'draft',
    'embed_message': 'embed',
    'attachment_text': 'files',
    'attachment_digest': 'files',
    'storyline': 'storyline',
    'storyline_sweep': 'storyline',
    'storyline_recruit': 'storyline',
    'storyline_refresh': 'storyline',
    'storyline_audit': 'storyline',
    'storyline_recap': 'storyline',
  };

  int get working =>
      running.values.fold(0, (total, count) => total + count);

  int get waiting => queued.values.fold(0, (total, count) => total + count);

  /// Whether anything is moving at all — what decides between narrating the
  /// stages and saying the pipeline is idle.
  bool get busy => working + waiting > 0;

  /// Everything outstanding for one stage, waiting and working together. Zero
  /// for a stage neither map mentions, so a caller can walk [stages]
  /// unconditionally.
  int countFor(String stage) =>
      (queued[stage] ?? 0) + (running[stage] ?? 0);
}
