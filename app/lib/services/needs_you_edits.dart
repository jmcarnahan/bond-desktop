import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'decision/decision_client.dart';
import 'decision/needs_you_exemplars.dart';
import 'decision/needs_you_predicate.dart';
import 'llm/llm_client.dart';
import 'pipeline_progress.dart';
import 'triage_queue.dart' show applyDecision, decisionInputFor;

/// One press of "Remove from Needs You" or "Add to Needs You": the labels
/// it wrote and the one `created_at` stamp they all carry — what the toast's
/// Undo holds and hands to [NeedsYouEdits.retract].
///
/// The stamp is there because a label's id is not enough: `decision_labels`
/// hands a deleted highest id out again, so an Undo retried with stale ids
/// could otherwise delete a NEWER press's label.
@immutable
class NeedsYouPress {
  /// The `decision_labels` rows the press wrote; empty when the thread's
  /// Needs You window was (the owner wrote last) and nothing was written.
  final List<int> ids;

  /// The `created_at` every one of [ids] was written with.
  final String createdAt;

  NeedsYouPress(List<int> ids, this.createdAt) : ids = List.unmodifiable(ids);

  /// A press that wrote nothing.
  const NeedsYouPress.none()
      : ids = const [],
        createdAt = '';

  bool get isEmpty => ids.isEmpty;
}

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

  /// The sweep's message in flight, which [retract] waits out: it may have
  /// matched a label before the undo deleted it and write after.
  Future<void>? _inFlight;

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
  /// Returns the press, for [retract]; an empty one when the window was
  /// (nothing waits on the owner there).
  ///
  /// Every message, not just the driver: the thread's number is the MAX over
  /// the window, and a second ask left at its old p would hold the thread in.
  ///
  /// DECIDE FIRST, WRITE SECOND: every message is decided (the one network
  /// step) before anything is stored, so a decision error propagates with
  /// nothing written and the caller's "the thread is unchanged" is true.
  /// Processing turned off refuses the press the same way ([_refuseWhenOff]):
  /// a press is a decision, and a label the switch kept from being applied
  /// would sit unseen.
  Future<NeedsYouPress> remove(String source, String conversationKey) async {
    _refuseWhenOff();
    final rows = await _store.needsYouWindowMessages(source, conversationKey);
    if (rows.isEmpty) return const NeedsYouPress.none();
    final owner = await _owner();
    final decided = [
      for (final row in rows)
        await _decide(row, owner, conversationKey: conversationKey),
    ];
    final createdAt = MessageStore.isoStamp(DateTime.now());
    final ids = <int>[
      for (var i = 0; i < rows.length; i++)
        await _label(source, conversationKey, rows[i], decided[i], owner,
            answer: 'no', createdAt: createdAt),
    ];
    if (decided.any((d) => d.vector != null)) {
      // Unawaited: the press is done once its own thread is written. Nobody
      // awaits this future, so a failure is logged here rather than left to
      // the zone.
      unawaited(sweep().then<void>(
        (_) {},
        onError: (Object e) => debugPrint('needs_you: the sweep failed: $e'),
      ));
    }
    return NeedsYouPress(ids, createdAt);
  }

  /// "Add to Needs You" on one thread: the newest message of its Needs You
  /// window is labelled `yes` and decided again, so the thread's probability
  /// becomes 1.0. No sweep. Returns the press, for [retract]; an empty one
  /// when the window is — the owner wrote last, so nothing waits on the
  /// owner there — and nothing was written. Decided before anything is
  /// written, and refused with processing off, as [remove] is.
  ///
  /// A thread that is Done or in Later takes the label all the same, but
  /// stays off the rail: Needs You reads neither.
  Future<NeedsYouPress> add(String source, String conversationKey) async {
    _refuseWhenOff();
    final rows = await _store.needsYouWindowMessages(source, conversationKey);
    if (rows.isEmpty) return const NeedsYouPress.none();
    final owner = await _owner();
    final decided =
        await _decide(rows.last, owner, conversationKey: conversationKey);
    final createdAt = MessageStore.isoStamp(DateTime.now());
    final id = await _label(source, conversationKey, rows.last, decided, owner,
        answer: 'yes', createdAt: createdAt);
    return NeedsYouPress([id], createdAt);
  }

  /// The undo of a press: deletes the labels [press] wrote and decides
  /// again, with the labels that remain, every message whose stored decision
  /// cites one of them — the pressed thread's and every thread the sweep
  /// removed — so each takes the model's number back unless another label
  /// still matches it. Returns how many messages it decided again; an
  /// unknown id deletes and decides nothing, and an id a newer press took
  /// over (ids are handed out again) is left to that press entirely.
  ///
  /// Decide first, as a press does: the citing messages are decided before
  /// the labels are deleted, then each is written with its fetched result
  /// (whose owner answer [applyDecision] looks up at write time, so the
  /// deleted labels no longer match). A decision server that cannot answer
  /// therefore propagates with nothing changed, and so does processing
  /// turned off ([_refuseWhenOff]): an undo that deleted the labels and then
  /// stopped would leave the press's answers in place with no label behind
  /// them and no way back. A per-message format fault is logged and that
  /// message keeps its decision.
  ///
  /// A sweep still running from the press can have matched a label before
  /// the delete and write its 0.0 after it, citing a label that is gone. So
  /// the undo waits out the sweep's message in flight and then asks again
  /// which messages cite the deleted labels, deciding those again, for at
  /// most [_retractRounds] rounds. The sweep carries on meanwhile, matching
  /// nothing of this press.
  Future<int> retract(NeedsYouPress press) async {
    _refuseWhenOff();
    if (press.isEmpty) return 0;
    final takenOver = {
      for (final label in await _exemplars.load())
        if (label.createdAt != press.createdAt) label.id,
    };
    final ids = [
      for (final id in press.ids)
        if (!takenOver.contains(id)) id,
    ];
    if (ids.isEmpty) return 0;
    final owner = await _owner();
    final first = await _decideAll(
      await _store.messagesCitingNeedsYouLabels(ids),
      owner,
    );
    await _store.deleteNeedsYouLabels(ids, createdAt: press.createdAt);
    _exemplars.invalidate();
    final inFlight = _inFlight;
    var redecided = await _applyAll(first, owner);
    if (inFlight != null) {
      // Its error is the sweep's to log.
      await inFlight.then<void>((_) {}, onError: (Object _) {});
    }
    for (var round = 0; round < _retractRounds; round++) {
      if (_off) break;
      final late = await _store.messagesCitingNeedsYouLabels(ids);
      if (late.isEmpty) break;
      redecided += await _applyAll(await _decideAll(late, owner), owner);
    }
    return redecided;
  }

  /// How many times [retract] asks again for decisions a running sweep
  /// wrote against the deleted labels.
  static const _retractRounds = 3;

  /// Throws when processing is off: the owner's presses and undo are
  /// decisions, and a half-done one is worse than a refused one. The inbox
  /// words the throw as its failure sentence.
  void _refuseWhenOff() {
    if (_off) throw StateError('processing is off');
  }

  /// One message decided. Throws what the decision client throws.
  Future<DecisionResult> _decide(
    Map<String, Object?> row,
    String? owner, {
    String? conversationKey,
  }) async =>
      _client.decide(await decisionInputFor(
        _store,
        row['source'] as String,
        Message.fromRow(row),
        conversationKey: conversationKey ?? row['conversation_key'] as String?,
        owner: owner,
      ));

  /// [rows] decided, for [retract], with nothing written: a message the
  /// model could not read ([LlmFormatException]) is logged and left out, a
  /// server that cannot answer propagates.
  Future<List<(Map<String, Object?>, DecisionResult)>> _decideAll(
    List<Map<String, Object?>> rows,
    String? owner,
  ) async {
    final decided = <(Map<String, Object?>, DecisionResult)>[];
    for (final row in rows) {
      try {
        decided.add((row, await _decide(row, owner)));
      } on LlmFormatException catch (e) {
        debugPrint('needs_you: an undo could not decide one message: '
            '${e.runtimeType}');
      }
    }
    return decided;
  }

  /// [decided] written through [applyDecision], for [retract]; returns how
  /// many were.
  Future<int> _applyAll(
    List<(Map<String, Object?>, DecisionResult)> decided,
    String? owner,
  ) async {
    for (final (row, result) in decided) {
      await _apply(row, result, owner);
    }
    return decided.length;
  }

  /// Stores the owner's [answer] about [row] with the vector of its fresh
  /// decision [decided], then writes that decision through [applyDecision],
  /// which finds the label it just got. Returns the label's id.
  Future<int> _label(
    String source,
    String conversationKey,
    Map<String, Object?> row,
    DecisionResult decided,
    String? owner, {
    required String answer,
    required String createdAt,
  }) async {
    final labelId = await _store.writeNeedsYouLabel(
      source: source,
      conversationKey: conversationKey,
      sourceMessageId: row['source_message_id'] as String,
      answer: answer,
      origin: answer == 'yes' ? 'add' : 'remove',
      vector: decided.vector,
      vectorModel: decided.model,
      createdAt: createdAt,
    );
    _exemplars.invalidate();
    await _apply(row, decided, owner);
    return labelId;
  }

  /// [decided] written for [row] through [applyDecision] with the owner's
  /// labels as they stand now.
  Future<void> _apply(
    Map<String, Object?> row,
    DecisionResult decided,
    String? owner,
  ) =>
      applyDecision(
        _store,
        row['source'] as String,
        row,
        decided,
        ownerKnown: owner != null,
        progress: _progress,
        threshold: _threshold,
        exemplars: _exemplars,
      );

  /// One message decided again and written through [applyDecision] with the
  /// owner's labels — the sweep's step. Throws what the decision client
  /// throws.
  Future<void> _decideAndApply(Map<String, Object?> row, String? owner) async =>
      _apply(row, await _decide(row, owner), owner);

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
      _inFlight = null;
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
          await (_inFlight = _decideAndApply(row, owner));
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
