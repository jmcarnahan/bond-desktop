import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'decision/decision_client.dart';
import 'decision/needs_you_exemplars.dart';
import 'decision/needs_you_predicate.dart';
import 'llm/llm_client.dart';
import 'pipeline_progress.dart';
import 'triage_queue.dart' show applyDecision, decisionInputFor;

/// Everything the OWNER does to Needs You: "Remove from Needs You" and "Add
/// to Needs You" on a thread, the sweep a removal starts, and the undo of a
/// press ([retract]).
///
/// A press is a LABEL and a re-decide, nothing more. Each message the press
/// answers for is decided by the decision model (for its vector), labelled
/// in `decision_labels` with that vector ([MessageStore.writeNeedsYouLabel]),
/// and then written through [applyDecision] — the one writer every decision
/// path shares — which now finds the label and stores the owner's answer
/// (1.0 or 0.0) with its reason and chip. No Needs You query changes: the
/// number they read carries the answer.
///
/// A removal then sweeps every thread still in Needs You at the owner's
/// slider ([sweep]): every message of its window is decided again through
/// the same path, and the ones within `NeedsYouExemplarTuning.matchCosine` of
/// the new label leave with their chips. An addition sweeps nothing —
/// teaching the model about a miss applies to mail decided from then on.
///
/// Undo is not the opposite press. A `yes` label on a message whose vector
/// is the removed one's would make every near-duplicate a yes from then on,
/// and the threads the sweep removed would stay removed. [retract] deletes
/// the labels the press wrote and decides again every message whose stored
/// decision took its answer from one of them, so the model's numbers come
/// back — on the pressed thread and on every thread the sweep took.
///
/// No work kind and no durable queue: the label is stored first, the sweep
/// is idempotent (a second press repeats it), and a crash mid-sweep costs a
/// second press — the labels are stored, so the next sweep, or any later
/// decision of those messages, applies them.
class NeedsYouEdits {
  final MessageStore _store;
  final DecisionClient _client;
  final NeedsYouExemplars _exemplars;

  /// The decision state's owner line (`decisionOwnerString`), or null when
  /// the keychain has not answered.
  final Future<String?> Function() _owner;

  /// The owner's Needs You slider, read fresh: which threads the sweep
  /// visits, and the chip rule inside [applyDecision].
  final Future<double> Function() _threshold;

  /// Where a moved chip goes ([applyDecision]'s `followNeedsYouChip`).
  final PipelineProgress _progress;

  /// Called once when a sweep ends — the provider reloads the conversation
  /// list, since nothing else re-reads it after a quiet run of writes.
  final void Function()? _onSwept;

  /// The processing switch, read before every message of the sweep and the
  /// undo, which stop (keeping what they wrote) when it answers no — so a
  /// reset that turned processing off is not raced by a loop of decision
  /// writes over rows it is deleting. Unwired is on, as for `TriageQueue`.
  final bool Function()? _enabled;

  /// A sweep is running; a press meanwhile sets [_again] instead of starting
  /// a second loop over the same threads.
  bool _sweeping = false;
  bool _again = false;

  NeedsYouEdits(
    this._store,
    this._client,
    this._exemplars, {
    required this._owner,
    required this._threshold,
    this._progress = const PipelineProgress.disabled(),
    this._onSwept,
    this._enabled,
  });

  /// True only when a switch was wired AND says no.
  bool get _off => _enabled?.call() == false;

  /// "Remove from Needs You" on one thread: every message of its Needs You
  /// window ([MessageStore.needsYouWindowMessages]) is labelled `no` with its
  /// vector and decided again, so the thread's probability drops to 0.0
  /// under any slider; then the sweep starts, unawaited, when a label carries
  /// a vector to match (on Kev none does, and a sweep would change nothing).
  /// Returns the label ids it wrote, for [retract]; empty when the window
  /// was (nothing waits on the owner there).
  ///
  /// Every message, not just the driver: the thread's number is the MAX over
  /// the window, and a second ask left at its old p would hold the thread in.
  /// A decision error propagates to the caller, which shows the house
  /// failure sentence; the labels written before it stay.
  Future<List<int>> remove(String source, String conversationKey) async {
    final rows = await _store.needsYouWindowMessages(source, conversationKey);
    if (rows.isEmpty) return const [];
    final owner = await _owner();
    final ids = <int>[];
    var anyVector = false;
    for (final row in rows) {
      final label =
          await _label(source, conversationKey, row, owner, answer: 'no');
      ids.add(label.id);
      anyVector = anyVector || label.hasVector;
    }
    if (anyVector) {
      // Unawaited: the press is done once its own thread is written. Nobody
      // awaits this future, so a failure is logged here rather than left to
      // the zone.
      unawaited(sweep().then<void>(
        (_) {},
        onError: (Object e) => debugPrint('needs_you: the sweep failed: $e'),
      ));
    }
    return ids;
  }

  /// "Add to Needs You" on one thread: the newest message of its Needs You
  /// window is labelled `yes` and decided again, so the thread's probability
  /// becomes 1.0. No sweep. Returns the label id in a list, for [retract];
  /// empty when the window is — the owner wrote last, so nothing waits on
  /// the owner there — and nothing was written.
  ///
  /// A thread that is Done or in Later takes the label all the same, but
  /// stays off the rail: Needs You reads neither.
  Future<List<int>> add(String source, String conversationKey) async {
    final rows = await _store.needsYouWindowMessages(source, conversationKey);
    if (rows.isEmpty) return const [];
    final label = await _label(
      source,
      conversationKey,
      rows.last,
      await _owner(),
      answer: 'yes',
    );
    return [label.id];
  }

  /// The undo of a press: deletes the labels [labelIds] (what [remove] or
  /// [add] returned) and decides again, with the labels that remain, every
  /// message whose stored decision cites one of them — the pressed thread's
  /// and every thread the sweep removed — so each takes the model's number
  /// back unless another label still matches it. Returns how many messages
  /// it decided again; an unknown id deletes and decides nothing.
  ///
  /// The citing rows are read BEFORE the delete and the decisions still cite
  /// the deleted ids until each is decided again, so a retract that a
  /// decision error cut short is finished by calling it again with the same
  /// ids. A decision server that cannot answer propagates, as a press does;
  /// a per-message fault is logged and that message keeps its decision.
  Future<int> retract(List<int> labelIds) async {
    if (labelIds.isEmpty) return 0;
    final rows = await _store.messagesCitingNeedsYouLabels(labelIds);
    await _store.deleteNeedsYouLabels(labelIds);
    _exemplars.invalidate();
    if (rows.isEmpty) return 0;
    final owner = await _owner();
    var redecided = 0;
    for (final row in rows) {
      if (_off) break;
      try {
        await _decideAndApply(row, owner);
      } on LlmUnavailableException {
        rethrow;
      } on LlmFormatException catch (e) {
        debugPrint('needs_you: an undo could not decide one message: '
            '${e.runtimeType}');
        continue;
      }
      redecided++;
    }
    return redecided;
  }

  /// Decides [row], stores the owner's [answer] about it with the fresh
  /// vector, and writes the decision through [applyDecision], which finds
  /// the label it just got.
  Future<({int id, bool hasVector})> _label(
    String source,
    String conversationKey,
    Map<String, Object?> row,
    String? owner, {
    required String answer,
  }) async {
    final id = row['source_message_id'] as String;
    final decided = await _client.decide(await decisionInputFor(
      _store,
      source,
      Message.fromRow(row),
      conversationKey: conversationKey,
      owner: owner,
    ));
    final labelId = await _store.writeNeedsYouLabel(
      source: source,
      conversationKey: conversationKey,
      sourceMessageId: id,
      answer: answer,
      origin: answer == 'yes' ? 'add' : 'remove',
      vector: decided.vector,
      vectorModel: decided.model,
    );
    _exemplars.invalidate();
    await applyDecision(
      _store,
      source,
      row,
      decided,
      ownerKnown: owner != null,
      progress: _progress,
      threshold: _threshold,
      exemplars: _exemplars,
    );
    return (id: labelId, hasVector: decided.vector != null);
  }

  /// One message decided again and written through [applyDecision] with the
  /// owner's labels. Throws what the decision client throws.
  Future<void> _decideAndApply(Map<String, Object?> row, String? owner) async {
    final source = row['source'] as String;
    final decided = await _client.decide(await decisionInputFor(
      _store,
      source,
      Message.fromRow(row),
      conversationKey: row['conversation_key'] as String?,
      owner: owner,
    ));
    await applyDecision(
      _store,
      source,
      row,
      decided,
      ownerKnown: owner != null,
      progress: _progress,
      threshold: _threshold,
      exemplars: _exemplars,
    );
  }

  /// Decides every message of every thread in Needs You at the slider again
  /// (the threads [MessageStore.needsYouDriverRows] lists, each over its
  /// whole window, [MessageStore.needsYouWindowMessages]), through
  /// [applyDecision] with the owner's labels, so near-duplicates of a removed
  /// message leave. The whole window and not only the driver: a templated
  /// thread holds several near-duplicates, and the next one would become the
  /// driver and keep the thread in. Returns how many threads left Needs You,
  /// and calls the `onSwept` hook once at the end.
  ///
  /// [TriageQueue.redecide]'s loop, with one difference: a decision server
  /// that cannot answer ([LlmUnavailableException]) stops the sweep with one
  /// log line — the labels are stored, so the next decision of each message
  /// inherits them anyway — but a per-message fault ([LlmFormatException]) is
  /// only logged: every message here already holds a current decision, which
  /// a failed mark would hide. Processing turned off stops it too.
  ///
  /// A call while a sweep runs returns 0 at once and has the running sweep
  /// make one more pass, which is how a second press is seen.
  Future<int> sweep() async {
    if (_sweeping) {
      _again = true;
      return 0;
    }
    _sweeping = true;
    var changed = 0;
    try {
      do {
        _again = false;
        final pass = await _sweepOnce();
        changed += pass.changed;
        if (pass.stopped) break;
      } while (_again);
    } finally {
      _sweeping = false;
      _again = false;
    }
    _onSwept?.call();
    return changed;
  }

  Future<({int changed, bool stopped})> _sweepOnce() async {
    final cut = await _threshold();
    final owner = await _owner();
    var changed = 0;
    for (final driver in await _store.needsYouDriverRows(cut)) {
      final source = driver['source'] as String;
      final key = driver['conversation_key'] as String;
      final window = await _store.needsYouWindowMessages(source, key);
      for (final row in window) {
        if (_off) return (changed: changed, stopped: true);
        try {
          await _decideAndApply(row, owner);
        } on LlmUnavailableException catch (e) {
          debugPrint('needs_you: the sweep stopped, the decision model is '
              'unavailable: ${e.runtimeType}');
          return (changed: changed, stopped: true);
        } on LlmFormatException catch (e) {
          debugPrint('needs_you: the sweep could not decide one message: '
              '${e.runtimeType}');
          continue;
        }
      }
      double? max;
      for (final row in await _store.needsYouWindowMessages(source, key)) {
        final p = (row['needs_you_p'] as num?)?.toDouble();
        if (p != null && (max == null || p > max)) max = p;
      }
      if (!needsYouAt(max, cut)) changed++;
    }
    return (changed: changed, stopped: false);
  }
}
