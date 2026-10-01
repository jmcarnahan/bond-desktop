import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'decision/decision_client.dart';
import 'decision/needs_you_exemplars.dart';
import 'decision/needs_you_predicate.dart';
import 'decision/stored_decision.dart';
import 'llm/embeddings_client.dart' show decodeEmbedding;
import 'llm/llm_client.dart';
import 'pipeline_progress.dart';
import 'triage_queue.dart' show applyDecision, decisionInputFor;

/// One press of "Remove from Needs You" or "Add to Needs You": the labels
/// it wrote and the one `created_at` stamp they all carry — what the toast's
/// Undo holds and hands to [NeedsYouEdits.retract] — and what the press did
/// to other threads, which the toast says.
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

  /// Whether any label carried a vector, so the press can reach mail like
  /// the pressed thread at all. False on a backend with no vector (Kev),
  /// where the answer holds for the pressed messages alone and the toast
  /// promises nothing more.
  final bool similar;

  /// How many OTHER threads the press's sweep moved across the owner's
  /// slider: out of Needs You for a removal, into it for an addition.
  final int changed;

  NeedsYouPress(
    List<int> ids,
    this.createdAt, {
    this.similar = false,
    this.changed = 0,
  }) : ids = List.unmodifiable(ids);

  /// A press that wrote nothing.
  const NeedsYouPress.none()
      : ids = const [],
        createdAt = '',
        similar = false,
        changed = 0;

  bool get isEmpty => ids.isEmpty;
}

/// One message's decision ready to write, and whether the state it was made
/// from carried the owner line (`applyDecision`'s `ownerKnown`).
typedef _Decided = ({DecisionResult result, bool ownerKnown});

/// Everything the OWNER does to Needs You: "Remove from Needs You" and "Add
/// to Needs You" on a thread, the sweep each press makes over the list, the
/// undo of a press ([retract]) and the Forget of every press
/// ([retractAll]).
///
/// A press is a LABEL and a write, nothing more. Each message the press
/// answers for is labelled in `decision_labels` with the decision model's
/// vector of it ([MessageStore.writeNeedsYouLabel]) and its decision is
/// written again through [applyDecision] — the one writer every decision
/// path shares — which now finds the label and stores the owner's answer
/// (1.0 or 0.0) with its reason and chip. No Needs You query changes: the
/// number they read carries the answer.
///
/// The decision and its vector come from the STORED decision
/// ([MessageStore.decisionFor]) whenever it has a vector under the model the
/// client answers with now ([DecisionClient.modelTag]): no model call. A
/// message without one is decided by the model, as every press was before
/// v24.
///
/// Then the sweep: a SCAN, not model calls. Every window message of every
/// thread on the other side of the press — in Needs You for a removal, out
/// of it (and neither done nor in Later) for an addition — whose stored
/// vector is within `NeedsYouExemplarTuning.matchCosine` of one of the
/// press's labels has its stored decision written again through
/// [applyDecision], which now matches the label. It is bounded by the
/// stored vectors and runs inside the press, so the similar threads have
/// moved before the toast says how many did.
///
/// Undo is not the opposite press. A `yes` label on a message whose vector
/// is the removed one's would make every near-duplicate a yes from then on,
/// and the threads the sweep removed would stay removed. [retract] deletes
/// the labels the press wrote and writes again every message whose stored
/// decision took its answer from one of them, from the model's own number
/// kept beside the override (`model_needs_you_p`), so the model's numbers
/// come back — on the pressed thread and on every thread the sweep took.
///
/// No work kind and no durable queue: the label is stored first, and any
/// later decision of a message like it applies it anyway.
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

  /// The processing switch, read before every message of the sweep and the
  /// undo, which stop (keeping what they wrote) when it answers no — so a
  /// reset that turned processing off is not raced by a loop of decision
  /// writes over rows it is deleting. Unwired is on, as for `TriageQueue`.
  final bool Function()? _enabled;

  /// The tag a fresh decision's vector carries now
  /// ([DecisionClient.modelTag]); a stored decision is used in place of a
  /// model call only under it. Unwired, or answering null, asks the model
  /// for every pressed message.
  final String? Function()? _modelTag;

  NeedsYouEdits(
    this._store,
    this._client,
    this._exemplars, {
    required this._owner,
    required this._threshold,
    this._progress = const PipelineProgress.disabled(),
    this._enabled,
    this._modelTag,
  });

  /// True only when a switch was wired AND says no.
  bool get _off => _enabled?.call() == false;

  /// "Remove from Needs You" on one thread: every message of its Needs You
  /// window ([MessageStore.needsYouWindowMessages]) is labelled `no` with its
  /// vector and written again, so the thread's probability drops to 0.0
  /// under any slider; then every thread in Needs You with a message like
  /// one of them leaves too ([_sweep]). Returns the press, for [retract] and
  /// the toast; an empty one when the window was (nothing waits on the owner
  /// there).
  ///
  /// Every message, not just the driver: the thread's number is the MAX over
  /// the window, and a second ask left at its old p would hold the thread in.
  ///
  /// DECIDE FIRST, WRITE SECOND: every message's decision is in hand (from
  /// the store, or the one network step) before anything is stored, so a
  /// decision error propagates with nothing written and the caller's "the
  /// thread is unchanged" is true. Processing turned off refuses the press
  /// the same way ([_refuseWhenOff]): a press is a decision, and a label the
  /// switch kept from being applied would sit unseen.
  Future<NeedsYouPress> remove(String source, String conversationKey) async {
    _refuseWhenOff();
    final rows = await _store.needsYouWindowMessages(source, conversationKey);
    if (rows.isEmpty) return const NeedsYouPress.none();
    return _press(source, conversationKey, rows, answer: 'no');
  }

  /// "Add to Needs You" on one thread: the newest message of its Needs You
  /// window is labelled `yes` and written again, so the thread's probability
  /// becomes 1.0; then every thread out of Needs You (and neither done nor in
  /// Later) with a message like it comes in ([_sweep]). Returns the press,
  /// for [retract]; an empty one when the window is — the owner wrote last,
  /// so nothing waits on the owner there — and nothing was written. Decided
  /// before anything is written, and refused with processing off, as
  /// [remove] is.
  ///
  /// A thread that is Done or in Later takes the label all the same, but
  /// stays off the rail: Needs You reads neither.
  Future<NeedsYouPress> add(String source, String conversationKey) async {
    _refuseWhenOff();
    final rows = await _store.needsYouWindowMessages(source, conversationKey);
    if (rows.isEmpty) return const NeedsYouPress.none();
    return _press(source, conversationKey, [rows.last], answer: 'yes');
  }

  /// [remove] and [add] once their messages are chosen: decide, label and
  /// write each, then sweep.
  Future<NeedsYouPress> _press(
    String source,
    String conversationKey,
    List<Map<String, Object?>> rows, {
    required String answer,
  }) async {
    final tag = _modelTag?.call();
    String? owner;
    var ownerAsked = false;
    final decided = <_Decided>[];
    for (final row in rows) {
      final stored = _storedResult(
        await _store.decisionFor(source, row['source_message_id'] as String),
        tag,
      );
      if (stored != null) {
        decided.add(stored);
        continue;
      }
      if (!ownerAsked) {
        owner = await _owner();
        ownerAsked = true;
      }
      decided.add((
        result: await _decide(row, owner, conversationKey: conversationKey),
        ownerKnown: owner != null,
      ));
    }
    final createdAt = MessageStore.isoStamp(DateTime.now());
    final ids = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final labelId = await _store.writeNeedsYouLabel(
        source: source,
        conversationKey: conversationKey,
        sourceMessageId: rows[i]['source_message_id'] as String,
        answer: answer,
        origin: answer == 'yes' ? 'add' : 'remove',
        vector: decided[i].result.vector,
        vectorModel: decided[i].result.model,
        createdAt: createdAt,
      );
      _exemplars.invalidate();
      await _apply(rows[i], decided[i]);
      ids.add(labelId);
    }
    final vectors = [
      for (final d in decided)
        if (d.result.vector case final vector?)
          (vector: vector, model: d.result.model),
    ];
    return NeedsYouPress(
      ids,
      createdAt,
      similar: vectors.isNotEmpty,
      changed: vectors.isEmpty
          ? 0
          : await _sweep(vectors, removing: answer == 'no'),
    );
  }

  /// The undo of a press: deletes the labels [press] wrote and writes again,
  /// with the labels that remain, every message whose stored decision cites
  /// one of them — the pressed thread's and every thread the sweep moved —
  /// so each takes the model's number back unless another label still
  /// matches it. Returns how many messages it wrote; an unknown id deletes
  /// and writes nothing, and an id a newer press took over (ids are handed
  /// out again) is left to that press entirely.
  ///
  /// A citing message whose stored decision kept the model's own number and
  /// vector under the current model ([_storedResult]) is written from it with
  /// no model call; the rest are decided by the model.
  ///
  /// Decide first, as a press does: every citing message's decision is in
  /// hand before the labels are deleted, then each is written (and
  /// [applyDecision] looks up the owner's answer at write time, so the
  /// deleted labels no longer match). A decision server that cannot answer
  /// therefore propagates with nothing changed, and so does processing
  /// turned off ([_refuseWhenOff]): an undo that deleted the labels and then
  /// stopped would leave the press's answers in place with no label behind
  /// them and no way back. A per-message format fault is logged and that
  /// message keeps its decision.
  ///
  /// One pass: the sweep runs inside its press, so no sweep of this press
  /// can write a citation after the delete.
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
    final tag = _modelTag?.call();
    String? owner;
    var ownerAsked = false;
    final decided = <(Map<String, Object?>, _Decided)>[];
    for (final row in await _store.messagesCitingNeedsYouLabels(ids)) {
      final stored = _storedResult(
        await _store.decisionFor(
          row['source'] as String,
          row['source_message_id'] as String,
        ),
        tag,
      );
      if (stored != null) {
        decided.add((row, stored));
        continue;
      }
      if (!ownerAsked) {
        owner = await _owner();
        ownerAsked = true;
      }
      try {
        decided.add((
          row,
          (result: await _decide(row, owner), ownerKnown: owner != null),
        ));
      } on LlmFormatException catch (e) {
        debugPrint('needs_you: an undo could not decide one message: '
            '${e.runtimeType}');
      }
    }
    await _store.deleteNeedsYouLabels(ids, createdAt: press.createdAt);
    _exemplars.invalidate();
    var written = 0;
    for (final (row, d) in decided) {
      if (_off) break;
      await _apply(row, d);
      written++;
    }
    return written;
  }

  /// Every Needs You press the owner ever made, undone, newest first
  /// ([MessageStore.needsYouLabelStamps], one [retract] per stamp): Settings'
  /// **Forget all Needs You answers**. Returns how many messages were
  /// written. Throws what [retract] throws, keeping the presses it already
  /// undid undone.
  Future<int> retractAll() async {
    _refuseWhenOff();
    final labels = await _store.needsYouLabels();
    var written = 0;
    for (final stamp in await _store.needsYouLabelStamps()) {
      written += await retract(NeedsYouPress(
        [
          for (final label in labels)
            if (label.createdAt == stamp) label.id,
        ],
        stamp,
      ));
    }
    return written;
  }

  /// Throws when processing is off: the owner's presses and undo are
  /// decisions, and a half-done one is worse than a refused one. The inbox
  /// words the throw as its failure sentence.
  void _refuseWhenOff() {
    if (_off) throw StateError('processing is off');
  }

  /// [stored] as a decision ready to write again, with no model call — the
  /// model's own answers ([StoredDecision.modelAnswers]) and the vector they
  /// came with — or null when it cannot stand in for a fresh decision: no
  /// stored decision, no vector, a vector under another model than [tag]
  /// (or no current tag at all), or an override that did not keep the
  /// model's number.
  ///
  /// [vector] stands in for the stored one when the caller already decoded
  /// it (the sweep, from the candidate's bytes).
  static _Decided? _storedResult(
    StoredDecision? stored,
    String? tag, {
    List<double>? vector,
  }) {
    if (stored == null || tag == null) return null;
    vector ??= stored.vector;
    if (vector == null || stored.vectorModel != tag) return null;
    final answers = stored.modelAnswers;
    if (answers == null) return null;
    return (
      result: DecisionResult(
        answers: answers,
        state: '',
        model: stored.vectorModel,
        // The model's own timing, kept: the Why panel prints it.
        latencyMs: stored.latencyMs?.round() ?? 0,
        truncated: stored.truncated,
        vector: vector,
      ),
      ownerKnown: stored.ownerKnown,
    );
  }

  /// One message decided by the model. Throws what the decision client
  /// throws.
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

  /// [decided] written for [row] through [applyDecision] with the owner's
  /// labels as they stand now.
  Future<void> _apply(Map<String, Object?> row, _Decided decided) =>
      applyDecision(
        _store,
        row['source'] as String,
        row,
        decided.result,
        ownerKnown: decided.ownerKnown,
        progress: _progress,
        threshold: _threshold,
        exemplars: _exemplars,
      );

  /// The press's sweep: every window message on the other side of the press
  /// ([MessageStore.needsYouCandidateVectors]: in Needs You when [removing],
  /// else out of it and neither done nor in Later) whose stored vector is
  /// within [NeedsYouExemplarTuning.matchCosine] of any of the press's
  /// [vectors] under the same model has its stored decision written again
  /// through [applyDecision], which then matches the new label. Returns how
  /// many of the threads it wrote to crossed the owner's slider.
  ///
  /// Every window message, not the driver alone: a templated thread holds
  /// several near-duplicates, and the next one would become the driver and
  /// keep the thread where it was. No model call and no
  /// `LlmUnavailableException` arm: a candidate whose stored decision cannot
  /// be written again as it stands ([_storedResult]) is left to the next
  /// decision of it, which inherits the label anyway. Processing turned off
  /// stops it between messages.
  ///
  /// An addition's candidates are most of a mailbox, so each is compared
  /// straight off its BLOB ([_cosineToBlob]) against the press's vectors,
  /// whose norms are taken once, and only a match is decoded.
  Future<int> _sweep(
    List<({List<double> vector, String model})> vectors, {
    required bool removing,
  }) async {
    final cut = await _threshold();
    final touched = <(String, String)>{};
    for (final model in {for (final v in vectors) v.model}) {
      final mine = [
        for (final v in vectors)
          if (v.model == model) _Probe(v.vector),
      ];
      final candidates = await _store.needsYouCandidateVectors(
        inNeedsYou: removing,
        threshold: cut,
        model: model,
      );
      for (final candidate in candidates) {
        if (!mine.any(
          (p) => _cosineToBlob(p, candidate.vector) >=
              NeedsYouExemplarTuning.matchCosine,
        )) {
          continue;
        }
        if (_off) return _crossed(touched, cut, removing: removing);
        final row = await _store.getMessageRow(candidate.source, candidate.id);
        final stored = _storedResult(
          await _store.decisionFor(
            candidate.source,
            candidate.id,
            withVector: false,
          ),
          model,
          vector: decodeEmbedding(candidate.vector),
        );
        if (row == null || stored == null) continue;
        await _apply(row, stored);
        touched.add((candidate.source, candidate.conversationKey));
      }
    }
    return _crossed(touched, cut, removing: removing);
  }

  /// How many of [touched] threads now sit on the far side of the slider
  /// [cut] from where the sweep found them: out of Needs You when
  /// [removing], in it otherwise. The sweep's candidates were all on the
  /// near side, so this is how many moved.
  Future<int> _crossed(
    Set<(String, String)> touched,
    double cut, {
    required bool removing,
  }) async {
    var crossed = 0;
    for (final (source, key) in touched) {
      double? max;
      for (final row in await _store.needsYouWindowMessages(source, key)) {
        final p = (row['needs_you_p'] as num?)?.toDouble();
        if (p != null && (max == null || p > max)) max = p;
      }
      if (needsYouAt(max, cut) != removing) crossed++;
    }
    return crossed;
  }
}

/// One of a press's vectors, unboxed, with its norm taken once: what the
/// sweep compares every candidate's bytes against.
class _Probe {
  final Float64List vector;
  final double norm;

  _Probe._(this.vector, this.norm);

  factory _Probe(List<double> v) {
    final vector = Float64List.fromList(v);
    var sq = 0.0;
    for (final x in vector) {
      sq += x * x;
    }
    return _Probe._(vector, math.sqrt(sq));
  }
}

/// `cosine` (`embeddings_client.dart`) between [probe] and the float32
/// little-endian [blob] `encodeEmbedding` wrote, read off the bytes with no
/// list built — the sweep's inner loop over most of a mailbox. The same
/// rules: a length mismatch or a zero vector is 0.
double _cosineToBlob(_Probe probe, Uint8List blob) {
  final count = blob.lengthInBytes ~/ 4;
  if (count != probe.vector.length || count == 0 || probe.norm == 0) return 0;
  final bytes = ByteData.sublistView(blob);
  var dot = 0.0;
  var sq = 0.0;
  for (var i = 0; i < count; i++) {
    final x = bytes.getFloat32(i * 4, Endian.little);
    dot += probe.vector[i] * x;
    sq += x * x;
  }
  if (sq == 0) return 0;
  return dot / (probe.norm * math.sqrt(sq));
}
