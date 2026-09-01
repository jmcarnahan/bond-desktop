import 'dart:convert';

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'attention.dart';
import 'llm/extract_task.dart';

/// Scores and files the whole mailbox in one pass.
///
/// Two jobs rather than one because they need exactly the same four reads —
/// the threads, each one's newest inbound message and extraction, the sender
/// answer rates, and the sender rules — and doing them separately would mean
/// running all four twice.
///
/// It is awaited by the list load, immediately before the rows are read. That
/// is affordable because none of it is a model call: four indexed queries and
/// a few hundred multiplications, well under a millisecond on a mailbox this
/// size. Doing it on a timer instead would mean the list can
/// render rows whose score was computed against a different sender rule than
/// the one the user just set, which reads as the correction not having worked.
class AttentionService {
  final MessageStore _store;

  AttentionService(this._store);

  /// Rescores every open thread and re-files every thread that the rules — not
  /// a person — put where it is. Returns how many threads were scored.
  ///
  /// Threads the LO has marked done are skipped entirely: they are not in any
  /// list, so a score on them would be a number nothing reads.
  ///
  /// [now] is injected so a test can pin the recency decay; production passes
  /// nothing and gets the wall clock.
  Future<int> recomputeAll({
    List<String> sources = const ['email'],
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final conversations = await _store.loadConversations(sources: sources);
    if (conversations.isEmpty) return 0;

    final meta = await _store.latestInboundMeta(sources: sources);
    final prefs = await _store.allSenderPrefs();
    final reasons = await _store.bucketReasons(sources: sources);
    // Reply rates are per-source, and email is the only source that has one.
    // A second connector gets its own call here rather than a merged map, so
    // an address that appears in both does not average across them.
    final replyRates = await _store.senderReplyRates();

    var scored = 0;
    for (final conversation in conversations) {
      final latest = meta[conversation.id];
      final address =
          (latest?['from_address'] as String? ?? '').toLowerCase();
      final senderPref = address.isEmpty ? null : prefs[address];
      final extraction = _extraction(latest?['extraction_json']);

      if (conversation.state != ConversationState.done) {
        await _store.writeAttentionScore(
          conversation.source,
          conversation.id,
          attentionScore(
            conversation: conversation,
            latestIntent: extraction?.intent,
            senderReplyRate: replyRates[address] ?? 0,
            senderPref: senderPref,
            now: at,
          ),
        );
        scored++;
      }

      await _sweepBucket(
        conversation,
        senderPref: senderPref,
        extraction: extraction,
        reason: reasons[conversation.id],
      );
    }
    return scored;
  }

  /// Decides where one thread belongs and writes it — but only when the
  /// decision is this pass's to make.
  ///
  /// The ownership rule is what keeps a sweep that runs on every keystroke from
  /// undoing people. A bucket carries the name of whoever wrote it:
  /// - `user` — someone deferred this one thread by hand. Nothing here touches
  ///   it, in either direction. It is the most specific instruction anyone has
  ///   given about this thread.
  /// - `sender_pref` — a standing rule about the sender. Rewritten from the
  ///   rule itself, so removing the rule removes the bucket.
  /// - `low_value` — this pass's own guess, and the only bucket it will clear
  ///   on the strength of a new guess.
  Future<void> _sweepBucket(
    Conversation conversation, {
    required String? senderPref,
    required ExtractionResult? extraction,
    required String? reason,
  }) async {
    if (reason == 'user') return;

    if (senderPref == 'later') {
      await _file(conversation, 'later', 'sender_pref');
      return;
    }
    if (senderPref == 'keep') {
      if (conversation.bucket != null) await _file(conversation, null, null);
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
          );

    if (bucket != null) {
      await _file(conversation, bucket, 'low_value');
    } else if (reason == 'low_value') {
      await _file(conversation, null, null);
    }
  }

  Future<void> _file(
    Conversation conversation,
    String? bucket,
    String? reason,
  ) {
    return _store.setConversationBucket(
      conversation.source,
      conversation.id,
      bucket: bucket,
      reason: reason,
    );
  }

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
