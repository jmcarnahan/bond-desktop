import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import 'activity_log.dart';
import 'storyline_service.dart';

/// What one repair actually moved — the outcome a caller and a test can read
/// without going back to the rows.
class GateRepairOutcome {
  /// The model had already extracted the message the gate landed on. The
  /// roadmap's `extracted_then_gated` counter, one message at a time.
  final bool extracted;

  /// Storyline memberships evicted, which is never more than the thread had.
  final int storylines;

  final bool embeddingCleared;

  /// `storyline` work rows deleted because they would have filed a thread
  /// nothing kept justifies.
  final int pendingWorkDeleted;

  /// Whether the thread had nothing kept left in it, so the repair path ran
  /// — which is not the same as something having moved: a thread with no
  /// vector, no membership and no queued filing is repaired by doing nothing.
  /// False when a kept inbound is left, and when there was no such message.
  final bool allGated;

  const GateRepairOutcome({
    this.extracted = false,
    this.storylines = 0,
    this.embeddingCleared = false,
    this.pendingWorkDeleted = 0,
    this.allGated = false,
  });

  /// Nothing moved and nothing was recorded.
  static const nothing = GateRepairOutcome();
}

/// What a gate that speaks late has to undo.
///
/// A gate normally speaks before anything is built: the claim invariant means
/// no message is extracted or judged until triage has answered about it. Three
/// things break that order, and each of them lands here:
///
/// - the triage drain's own gates, on a message whose thread was embedded and
///   filed because of some OTHER message in it that has since been gated too;
/// - the owner's Ignore, which is a gate arriving after the whole pipeline has
///   run on the message;
/// - the databases that predate the invariant, where extraction and the gates
///   genuinely raced. Those are swept once, behind the
///   `gated_conversation_repair` pref.
///
/// The test is the store's own: a conversation with ZERO kept inbound messages
/// is a thread nothing in the app should still be describing. Its embedding is
/// a vector in the clustering corpus, its automatic storyline memberships put
/// it in a group's recap, and its pending `storyline` row would file it again.
/// All three go.
///
/// A service rather than a method on the store, because the repair spans two
/// of them — the storyline side has its own bookkeeping to keep honest — and
/// rather than a branch inside `TriageQueue`, because that queue judges
/// messages and this cleans up after a judgement.
///
/// What it deliberately does NOT do is queue a storyline audit. An audit means
/// "the owner says the model was wrong about this group", and a gate says
/// nothing of the kind — see [StorylineService.evictGatedThread]. For the same
/// reason the block it writes never reaches a prompt: the confirm prompt reads
/// `blocksOf(blockedBy: 'user')`, and a `gate` block is not the owner's word.
class GateRepairService {
  /// How many all-gated threads one pass of [repairAll] walks.
  ///
  /// The sweep runs inside the mail sync with no progress signal of its own,
  /// and every eviction queues a storyline refresh that is a model call, so a
  /// mailbox that raced hundreds of threads before the claim invariant would
  /// otherwise spend its first sync in here and then burst the recap queue.
  /// A slice per sync, and the one-shot stays owed until a slice comes back
  /// short.
  static const int oneShotCap = 200;

  final MessageStore _store;
  final StorylineService _storylines;
  final ActivityLog _log;

  GateRepairService(
    this._store,
    this._storylines, {
    ActivityLog? activityLog,
  }) : _log = activityLog ?? ActivityLog.disabled();

  /// Called after a gate lands on ONE message.
  ///
  /// [reason] says which gate it was: `extracted_then_gated` for the triage
  /// drain's own verdict, `ignored` for the owner's Ignore. It rides the
  /// activity row so a reader can tell a repair the app decided on from one a
  /// person asked for.
  ///
  /// Nothing moves while the thread still has a kept inbound message: one
  /// newsletter among a colleague's mail is not a reason to unfile the thread.
  /// The counter is still recorded in that case, because a message that was
  /// extracted and then gated is worth counting wherever it happened.
  Future<GateRepairOutcome> afterGate(
    String source,
    String sourceMessageId, {
    required String reason,
  }) async {
    try {
      final row = await _store.getMessageRow(source, sourceMessageId);
      // Nothing stored under the keys is nothing to repair, and nothing to
      // write down either: a log of what the app did must not claim a repair
      // of a message that does not exist.
      if (row == null) return GateRepairOutcome.nothing;

      final extracted = await _store.hasExtraction(source, sourceMessageId);
      final key = row['conversation_key'] as String? ?? '';

      if (key.isEmpty || await _store.keptInboundCount(source, key) > 0) {
        return await _recordOne(
          source,
          sourceMessageId,
          reason: reason,
          key: key,
          extracted: extracted,
          outcome: GateRepairOutcome(extracted: extracted),
        );
      }

      final repair = await _repairConversation(source, key);
      return await _recordOne(
        source,
        sourceMessageId,
        reason: reason,
        key: key,
        extracted: extracted,
        outcome: GateRepairOutcome(
          extracted: extracted,
          storylines: repair.storylines,
          embeddingCleared: repair.embeddingCleared,
          pendingWorkDeleted: repair.pendingWorkDeleted,
          allGated: true,
        ),
      );
    } catch (e) {
      // This is called from inside the triage drain and from a button. A
      // store failure here must break neither: the verdict the gate wrote is
      // already on the row, and the one-shot below will find whatever this
      // could not clean.
      debugPrint('gate repair: $source/$sourceMessageId failed: $e');
      return GateRepairOutcome.nothing;
    }
  }

  /// The one-shot over the whole database, and how many conversations it
  /// repaired.
  ///
  /// Run once per install behind a pref — see `SyncService` — because what it
  /// is for is history: the threads embedded and filed before a gate could
  /// speak first. New gates are handled one at a time by [afterGate].
  ///
  /// Always records its row, even having found nothing. A one-shot that ran
  /// and found a clean database is worth exactly one line saying so, and the
  /// pref means nobody gets a second chance to ask.
  ///
  /// The count is the conversations actually repaired: one thread's failure
  /// is caught, counted on the row as `failed`, and taken off the number, so
  /// the sync row never claims a repair that did not land. A failure of the
  /// SWEEP itself — the listing, the final record — is different and is
  /// rethrown on purpose: the caller owns the pref, and a sweep that never
  /// ran must not be marked as done. `afterGate` swallows because it runs
  /// inside a drain; this runs once, and the sync around it decides.
  /// The row's `conversations` is every thread walked, failed ones included;
  /// `repaired` leaves the failures out. So the sync row and the activity row
  /// can differ by exactly `failed`, and both are right about what they say.
  Future<({int repaired, bool complete})> repairAll({
    int cap = oneShotCap,
  }) async {
    try {
      final pairs =
          await _store.conversationsWithEmbeddingAndNoKeptInbound(limit: cap);
      // Short of the cap means the listing was the whole population; a full
      // slice means there may be more, and the caller keeps the one-shot
      // owed until a pass comes back short.
      final complete = pairs.length < cap;
      var storylines = 0;
      var embeddings = 0;
      var deleted = 0;
      var failed = 0;
      for (final pair in pairs) {
        try {
          final repair =
              await _repairConversation(pair.source, pair.conversationKey);
          storylines += repair.storylines;
          if (repair.embeddingCleared) embeddings++;
          deleted += repair.pendingWorkDeleted;
        } catch (e) {
          // One thread's repair failing is not the sweep's failure. The pref
          // is set either way, so what this costs is those threads staying as
          // they are — which is where they already were.
          failed++;
          debugPrint('gate repair: ${pair.source}/${pair.conversationKey} '
              'failed: $e');
        }
      }

      final extracted = await _store.extractedThenGatedCount();
      await _log.record(
        'gate_repair',
        count: storylines,
        detail: {
          'reason': 'one_shot',
          'conversations': pairs.length,
          'extracted': extracted,
          'storylines': storylines,
          'embeddings_cleared': embeddings,
          if (deleted > 0) 'pending_work_deleted': deleted,
          if (failed > 0) 'failed': failed,
          if (!complete) 'capped': cap,
        },
      );
      return (repaired: pairs.length - failed, complete: complete);
    } catch (e) {
      debugPrint('gate repair: the one-shot failed: $e');
      rethrow;
    }
  }

  /// Everything one all-gated thread loses. The shared body of both entry
  /// points, so a one-shot repair and a live one cannot drift apart.
  Future<
      ({
        int storylines,
        bool embeddingCleared,
        int pendingWorkDeleted,
      })> _repairConversation(String source, String key) async {
    final storylines = await _storylines.evictGatedThread(source, key);

    // Read before the write, so `embedding_cleared` on the row is a fact
    // rather than an intention: most of these threads were never embedded.
    final ai = await _store.getConversationAi(source, key);
    final hadEmbedding = ai != null && ai['embedding'] != null;
    if (hadEmbedding) await _store.clearConversationEmbedding(source, key);

    final deleted = await _store.deletePendingWork('storyline', source, key);

    return (
      storylines: storylines,
      embeddingCleared: hadEmbedding,
      pendingWorkDeleted: deleted,
    );
  }

  /// One repair's row — written only when there is something to say.
  ///
  /// A gate landing on an unextracted message in a thread nothing was ever
  /// built from is the common case, by a wide margin, and the panel would be
  /// nothing but those rows if they were recorded. So the row goes in when
  /// something actually moved, or when the counter has something to count.
  Future<GateRepairOutcome> _recordOne(
    String source,
    String sourceMessageId, {
    required String reason,
    required String key,
    required bool extracted,
    required GateRepairOutcome outcome,
  }) async {
    final moved = outcome.storylines > 0 ||
        outcome.embeddingCleared ||
        outcome.pendingWorkDeleted > 0;
    if (!moved && !extracted) return outcome;
    await _log.record(
      'gate_repair',
      source: source,
      entityId: sourceMessageId,
      count: outcome.storylines,
      detail: {
        'reason': reason,
        'extracted': extracted ? 1 : 0,
        'storylines': outcome.storylines,
        'embedding_cleared': outcome.embeddingCleared,
        if (outcome.pendingWorkDeleted > 0)
          'pending_work_deleted': outcome.pendingWorkDeleted,
        'conversation_key': key,
      },
    );
    return outcome;
  }
}
