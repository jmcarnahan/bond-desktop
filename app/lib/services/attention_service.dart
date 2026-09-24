import 'dart:convert';

import '../data/message_store.dart';
import '../models/label_models.dart';
import '../models/message_models.dart';
import 'attention.dart';
import 'label_rules.dart';
import 'llm/extract_task.dart';

/// Scores and files the whole mailbox in one pass.
///
/// Two jobs rather than one because they need exactly the same handful of
/// reads —
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
  /// Threads the user has marked done are skipped entirely: they are not in any
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
    // One set for the whole mailbox rather than a query per thread: this pass
    // runs on every list load, and the open-ask question would otherwise be
    // hundreds of round trips behind each one.
    final openAsks = await _store.openAskThreads(sources: sources);
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
    // The owner's standing label rules, read ONCE for the whole pass for
    // `allSenderPrefs`' reason: this runs on every list load, and a query per
    // thread would put hundreds of round trips behind each one. Empty is the
    // normal case and costs the walk below nothing.
    final labelRules = await _store.listLabelRules();

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
            latestReplyExpected: _tristate(latest?['reply_expected']),
            latestNeedsAction: _tristate(latest?['needs_action']),
            latestDeadline: latest?['deadline'] as String?,
            addressedMe: ((latest?['addressed_me'] as num?) ?? 0) != 0,
            needsYouVerdict: _tristate(latest?['needs_you_verdict']),
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
        hasOpenAsk: openAsks.contains(
          MessageStore.openAskKey(conversation.source, conversation.id),
        ),
        laterRule: _laterRule(labelRules, conversation, address),
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
  /// [laterRule] is a standing label rule (see [_laterRule]) and it is read AFTER
  /// the sender preferences, not before. Both are the owner's word, and the
  /// sender rule is the more specific of the two: somebody who said `keep` about
  /// one address meant it over a rule they wrote about the whole domain. A rule
  /// that has already filed a thread is never reached at all — that bucket reads
  /// `'user'`, and this returns on it above.
  Future<void> _sweepBucket(
    Conversation conversation, {
    required String? senderPref,
    required ExtractionResult? extraction,
    required String? reason,
    required bool hasOpenAsk,
    LabelRule? laterRule,
  }) async {
    if (reason == 'user') return;

    if (quietsSender(senderPref)) {
      await _file(conversation, 'later', 'sender_pref');
      return;
    }
    if (senderPref == 'keep') {
      if (conversation.bucket != null) await _file(conversation, null, null);
      return;
    }

    if (laterRule != null) {
      await _fileLaterByRule(conversation, laterRule);
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
            needsYouVerdict: hasOpenAsk,
          );

    if (bucket != null) {
      await _file(conversation, bucket, 'low_value');
    } else if (reason == 'low_value') {
      await _file(conversation, null, null);
    }
  }

  /// The owner's standing `later` rule for one thread, or null.
  ///
  /// The matcher the triage gate, the retroactive apply and [ExtractHandler] all
  /// use, so the four agree about which mail a rule is about; only a `later`
  /// disposition is this pass's business, for the reason
  /// `ExtractHandler._laterRule` gives.
  ///
  /// [classification] is passed as NULL, and that is a real limitation rather
  /// than a shortcut: `classificationOf` reads a message's headers and its gate
  /// reason, and [MessageStore.latestInboundMeta] — the one read this pass has of
  /// the newest inbound message — carries neither. So a CLASSIFICATION-scoped
  /// rule does not act here, while sender, domain and subject rules do. The
  /// direction of that gap is the saving grace: classification is the LOWEST of
  /// the matcher's four precedences, so a missing one can only lose a match, never
  /// promote the wrong rule. New mail is covered either way — `ExtractHandler`
  /// has the whole row and asks with the classification in hand — which leaves
  /// exactly one case uncovered: mail that arrived BEFORE a classification-scoped
  /// `later` rule existed and that the retroactive apply did not reach.
  ///
  /// The sender name is null for the same reason and matters less: a `sender` or
  /// `domain` rule matches on the ADDRESS, which this pass has.
  static LabelRule? _laterRule(
    List<LabelRule> rules,
    Conversation conversation,
    String address,
  ) {
    if (rules.isEmpty) return null;
    final rule = matchLabelRule(
      rules,
      source: conversation.source,
      senderAddress: address.isEmpty ? null : address,
      senderName: null,
      subject: conversation.subject,
      classification: null,
    );
    if (rule == null || rule.disposition != LabelRule.sendToLater) return null;
    return rule;
  }

  /// Files one thread under Later on a rule's behalf, and under the rule's word.
  ///
  /// `ExtractHandler._fileLaterByRule`'s twin, and every decision in it is that
  /// one's: the reason is the protected `'user'` so no later pass sweeps the
  /// filing back, the stale deferral date goes because a rule has no "when" in
  /// it, and the link carries `rule_id` so the Settings count and the undo both
  /// find the thread. The count is bumped only for a link that is NEW.
  Future<void> _fileLaterByRule(
    Conversation conversation,
    LabelRule rule,
  ) async {
    await _file(conversation, 'later', 'user');
    await _store.setSnoozedUntil(conversation.source, conversation.id, null);
    final isNew = await _store.applyLabelsByRule(
      conversation.source,
      conversation.id,
      rule.labelId,
      ruleId: rule.id,
    );
    if (isNew) await _store.bumpRuleHiddenCount(rule.id);
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

  /// One of the 0/1/NULL judgment columns — triage's, or the needs-you
  /// stage's — as a nullable bool.
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
