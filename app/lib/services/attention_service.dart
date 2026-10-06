import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'attention.dart';
import 'decision/needs_you_predicate.dart';
import '../models/extraction_models.dart';

/// What one attention pass wrote — see [AttentionService.recompute].
class AttentionPass {
  const AttentionPass({
    required this.scored,
    required this.scores,
    required this.buckets,
  });

  /// How many threads were scored (every thread not done).
  final int scored;

  /// The score written per thread this pass, keyed [MessageStore.openAskKey].
  final Map<String, double> scores;

  /// The bucket written per thread this pass, same key. A key PRESENT with a
  /// null value is a bucket cleared, so read it with `containsKey`, never by
  /// the value alone.
  final Map<String, String?> buckets;

  /// A pass over an empty mailbox: nothing scored, nothing written.
  static const AttentionPass empty =
      AttentionPass(scored: 0, scores: {}, buckets: {});

  /// [rows] (the list query's rows, see [MessageStore.conversationRows]) with
  /// this pass's writes applied: `attention_score` and `bucket`, the two
  /// columns of that query the pass writes.
  ///
  /// A row the pass did not change in value is returned as the SAME map
  /// instance, so the caller can tell which models to rebuild with
  /// `identical`.
  List<Map<String, Object?>> applyTo(List<Map<String, Object?>> rows) => [
        for (final row in rows) _applyToRow(row),
      ];

  Map<String, Object?> _applyToRow(Map<String, Object?> row) {
    final key = MessageStore.openAskKey(
      row['source'] as String? ?? '',
      row['conversation_key'] as String? ?? '',
    );
    final score = scores[key];
    final scoreMoved = score != null &&
        score != (row['attention_score'] as num?)?.toDouble();
    final bucketMoved =
        buckets.containsKey(key) && buckets[key] != row['bucket'];
    if (!scoreMoved && !bucketMoved) return row;
    return {
      ...row,
      if (scoreMoved) 'attention_score': score,
      if (bucketMoved) 'bucket': buckets[key],
    };
  }
}

/// Scores and files the whole mailbox in one pass.
///
/// Two jobs rather than one because they need exactly the same reads — the
/// threads, each one's newest inbound message and extraction, the sender
/// answer rates, the sender rules, who owns each bucket and which threads
/// hold an open ask — and doing them separately would mean running all of
/// them twice.
///
/// It is awaited by the list load, on the rows that load has just read: eight
/// reads (seven when the load hands its rows over), a few hundred
/// multiplications, and every write in ONE batch. Awaited rather than put on
/// a timer of its own, because a pass anywhere else would let the list render
/// rows whose score was computed against a different sender rule than the
/// one the user just set, which reads as the correction not having worked.
class AttentionService {
  final MessageStore _store;

  AttentionService(this._store);

  /// Rescores every open thread and re-files every thread that the rules — not
  /// a person — put where it is. Returns how many threads were scored.
  ///
  /// Threads the user has marked done are skipped entirely: they are not in any
  /// list, so a score on them would be a number nothing reads.
  ///
  /// [now] is injected so a test can pin the recency decay; production passes
  /// nothing and gets the wall clock.
  Future<int> recomputeAll({
    List<String> sources = const ['email'],
    DateTime? now,
  }) async =>
      (await recompute(sources: sources, now: now)).scored;

  /// The pass itself: what [recomputeAll] does, answering with everything it
  /// wrote rather than only the count.
  ///
  /// [conversations] is the list the caller has just read, when it has one:
  /// the pass then scores exactly those threads and does not read the list a
  /// second time. Without it the pass reads the list itself.
  ///
  /// Every score and every bucket goes out in ONE batch
  /// ([MessageStore.writeAttentionPass]), and none is skipped for being
  /// unchanged: each write stamps `conversation_ai.updated_at`, which the
  /// notification settle reads as this pass having seen the thread. The stamp
  /// is taken as the pass STARTS, before any of its reads, so a message that
  /// changes while the pass runs is stamped later than the pass and waits for
  /// the next one.
  Future<AttentionPass> recompute({
    List<String> sources = const ['email'],
    DateTime? now,
    List<Conversation>? conversations,
  }) async {
    // The real clock, whatever [now] says: this is when the pass looked, which
    // is a different question from the instant the decay is measured at.
    final stamp = MessageStore.isoStamp(DateTime.now());
    final at = now ?? minuteOf(DateTime.now());
    final list =
        conversations ?? await _store.loadConversations(sources: sources);
    if (list.isEmpty) return AttentionPass.empty;

    final meta = await _store.latestInboundMeta(sources: sources);
    final prefs = await _store.allSenderPrefs();
    final reasons = await _store.bucketReasons(sources: sources);
    // One set for the whole mailbox rather than a query per thread: this pass
    // runs on every list load, and the open-ask question would otherwise be
    // hundreds of round trips behind each one.
    //
    // The owner's slider is read once for the pass, so every thread's ask is
    // judged against the same number the rail and the tile read.
    final threshold = await _store.needsYouThreshold();
    final openAsks =
        await _store.openAskThreads(sources: sources, threshold: threshold);
    // One rate map, built from a call per source rather than one merged query:
    // each source's denominator stays its own, so a mailbox the user answers
    // and a chat backlog they do not cannot average into a middling nudge for
    // both. Spreading them together is safe because a Teams address always
    // carries the `teams:` prefix, which makes a cross-source key collision
    // impossible by construction.
    final replyRates = {
      ...await _store.senderReplyRates(),
      ...await _store.senderReplyRates(source: 'teams'),
    };

    final scoreWrites = <({String source, String key, double score})>[];
    final bucketWrites =
        <({String source, String key, String? bucket, String? reason})>[];
    for (final conversation in list) {
      final latest = meta[conversation.id];
      final address =
          (latest?['from_address'] as String? ?? '').toLowerCase();
      final senderPref = address.isEmpty ? null : prefs[address];
      final extraction = _extraction(latest?['extraction_json']);

      if (conversation.state != ConversationState.done) {
        scoreWrites.add((
          source: conversation.source,
          key: conversation.id,
          score: attentionScore(
            conversation: conversation,
            latestIntent: extraction?.intent,
            senderReplyRate: replyRates[address] ?? 0,
            senderPref: senderPref,
            latestReplyExpected: _tristate(latest?['reply_expected']),
            latestNeedsAction: _tristate(latest?['needs_action']),
            latestDeadline: latest?['deadline'] as String?,
            addressedMe: ((latest?['addressed_me'] as num?) ?? 0) != 0,
            needsYou: needsYouAt(
              (latest?['needs_you_p'] as num?)?.toDouble(),
              threshold,
            ),
            now: at,
          ),
        ));
      }

      _sweepBucket(
        conversation,
        bucketWrites,
        senderPref: senderPref,
        extraction: extraction,
        reason: reasons[conversation.id],
        hasOpenAsk: openAsks.contains(
          MessageStore.openAskKey(conversation.source, conversation.id),
        ),
      );
    }

    await _store.writeAttentionPass(
      scores: scoreWrites,
      buckets: bucketWrites,
      stamp: stamp,
    );
    return AttentionPass(
      scored: scoreWrites.length,
      scores: {
        for (final w in scoreWrites)
          MessageStore.openAskKey(w.source, w.key): w.score,
      },
      buckets: {
        for (final w in bucketWrites)
          MessageStore.openAskKey(w.source, w.key): w.bucket,
      },
    );
  }

  /// [d] cut to the start of its minute: the pass's clock when none is
  /// injected.
  ///
  /// The recency decay is continuous, so on the raw wall clock every pass
  /// would store a different number for every thread, and no two reads of the
  /// list would ever compare equal — every reload would be a new screen.
  /// Ticking once a minute makes an unchanged thread score bit-identically
  /// within the minute. It costs at most a minute of decay — 0.007 % at the
  /// seven-day half-life — applied to every thread alike, so the order is
  /// exactly that minute's. An injected `now` is used as given, so a test
  /// pins the decay to the instant it names.
  ///
  /// Cut on the instant rather than rebuilt from the calendar fields: in the
  /// hour a clock change repeats, the fields name two instants and a rebuild
  /// would pick the earlier one.
  @visibleForTesting
  static DateTime minuteOf(DateTime d) {
    final ms = d.millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(
      ms - ms % Duration.millisecondsPerMinute,
      isUtc: d.isUtc,
    );
  }

  /// Decides where one thread belongs and adds the write to [writes] — but
  /// only when the decision is this pass's to make.
  ///
  /// The ownership rule is what keeps a sweep that runs on every keystroke from
  /// undoing people. A bucket carries the name of whoever wrote it:
  /// - `user` — someone deferred this one thread by hand. Nothing here touches
  ///   it, in either direction. It is the most specific instruction anyone has
  ///   given about this thread.
  /// - `sender_pref` — a standing rule about the sender, either `later` or
  ///   `drop`; both file the thread the same way, because a sender the owner
  ///   dropped is a sender whose existing threads should go quiet. Rewritten
  ///   from the rule itself, so removing the rule removes the bucket.
  /// - `low_value` — this pass's own guess, and the only bucket it will clear
  ///   on the strength of a new guess.
  ///
  /// [hasOpenAsk] changes none of that ownership. It reaches only the
  /// `low_value` decision, where an unanswered ask on the thread is what stops
  /// the quiet-FYI rule from deferring it — see [bucketFor].
  ///
  /// A write is queued wherever a decision is made, whether or not the thread
  /// already sits there: each one stamps `updated_at`, which the notification
  /// settle reads (see [recompute]).
  void _sweepBucket(
    Conversation conversation,
    List<({String source, String key, String? bucket, String? reason})>
        writes, {
    required String? senderPref,
    required ExtractionResult? extraction,
    required String? reason,
    required bool hasOpenAsk,
  }) {
    void file(String? to, String? by) => writes.add((
          source: conversation.source,
          key: conversation.id,
          bucket: to,
          reason: by,
        ));

    if (reason == 'user') return;

    if (quietsSender(senderPref)) {
      file('later', 'sender_pref');
      return;
    }
    if (senderPref == 'keep') {
      if (conversation.bucket != null) file(null, null);
      return;
    }

    // No extraction yet means nothing is known about the message, which is not
    // the same as knowing it is unimportant. Such a thread stays in the inbox.
    final bucket = extraction == null
        ? null
        : bucketFor(
            intent: extraction.intent,
            importance: extraction.importance,
            needsReply: conversation.state == ConversationState.needsReply,
            needsYou: hasOpenAsk,
          );

    if (bucket != null) {
      file(bucket, 'low_value');
    } else if (reason == 'low_value') {
      file(null, null);
    }
  }

  /// One of triage's 0/1/NULL judgment columns as a nullable bool.
  ///
  /// The null has to survive the trip intact: it means nothing ever judged this
  /// message, which the scorer treats as a different thing from a stage having
  /// judged it and said no. Anything that is not a number reads as null for
  /// the same reason a corrupt extraction does — "nothing is known here" is the
  /// conservative answer, and it is the one the scorer already handles.
  ///
  /// (`message_models.dart` has the identical conversion as `_boolFromInt`, but
  /// it is library-private and not worth widening for three call sites.)
  static bool? _tristate(Object? raw) => raw is num ? raw != 0 : null;

  /// The stored extraction, or null when there is none and when what is stored
  /// does not parse. A corrupt blob reads as "not extracted yet", which every
  /// caller already handles — it must never take down a list load.
  static ExtractionResult? _extraction(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return ExtractionResult.fromJson(decoded);
    } on FormatException {
      return null;
    } on TypeError {
      // Valid JSON, wrong shapes — a field stored as a number where a string
      // belongs. Same verdict as unparseable: not extracted yet.
      return null;
    }
  }
}
