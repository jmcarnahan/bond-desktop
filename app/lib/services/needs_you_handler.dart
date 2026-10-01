import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'decision/decision_client.dart';
import 'decision/decision_input.dart' show decisionOwnerString;
import 'decision/decision_policy.dart';
import 'decision/needs_you_exemplars.dart';
import 'owner_lookup.dart';
import 'pipeline_progress.dart';
import 'triage_queue.dart'
    show applyDecision, decisionInputFor, followNeedsYouChip;

/// Settles ONE message's needs-you probability, `messages.needs_you_p`.
///
/// `entity_id` is a source message id: this is a judgement about a thing
/// somebody said, not about the thread it was said in, and a quiet thread that
/// gets one direct question is exactly the case a per-thread verdict would
/// lose.
///
/// The probability is the decision model's calibrated p(needs_you = yes), and
/// the owner's slider is the cut on it (`needsYouAt`). The triage pass
/// writes it for every kept message it decided with the owner known, so for
/// most messages this pass finds it already there and does nothing. It
/// decides a message AGAIN, with the decision model, when the stored decision
/// is missing or was made without an owner line (the head was trained with
/// that line, so its number is not trusted without it), and then it writes
/// the whole state that decision determines through [applyDecision], the
/// triage claim's writer: the triage fields, the extraction's intent and
/// importance and the thread fold move with the p. NULL on the row means
/// not decided yet, never a low probability.
///
/// No language model is asked about needs-you, on any path, and there is no
/// band, bar or floor: the slider is the owner's control over the cut, and
/// the owner's Needs You answers (`NeedsYouExemplars`, applied inside
/// [applyDecision]) are already in the stored number this pass copies.
///
/// This handler deliberately has NO arm in [AiWorker]'s `_park` and
/// `_recordFailure` per-kind ladders. Those ladders exist for one reason: a
/// stage with a `message_progress` column has to re-note its state when the
/// worker, not the handler, decides how an exception ended. Needs-you has no
/// stage column, so an arm here would write nothing and read as an oversight
/// to the next person who "fixes" it. The generic parking above those ladders
/// still applies: a decision server or a model that is not running parks the
/// whole kind, and nothing here falls back from one to the other.
///
/// It does move ONE `message_progress` column, and it is not a stage. The
/// `needs_you` flag on a settled row is a snapshot taken at settle time, so a
/// probability this pass CHANGES across the slider leaves the chip beside it
/// showing the old answer. When, and only when, the answer at the owner's
/// threshold moves, [followNeedsYouChip] hands the message to
/// [PipelineProgress.refreshNeedsYou], which rewrites the flag. A pass that
/// leaves the answer where it was writes nothing, which is what keeps a chip
/// cleared by a reply or by a Done from coming back.
class NeedsYouHandler extends WorkHandler {
  static const String _source = 'email';

  final MessageStore _store;

  /// Where a pass that deliberately did nothing gets to say so. Defaulted to
  /// the disabled log, so a test that builds this handler writes nothing extra.
  final ActivityLog _log;

  /// The owner lookup, asked ONCE for the life of this handler by
  /// [memoizedOwner]. It is a keychain read, and the answer only changes on
  /// sign-out — which disposes the provider that built this handler and so
  /// builds a new one. Only a lookup that ANSWERED is kept, so a keychain
  /// hiccup is forgotten and the decision input simply names no owner, which
  /// the line's own contract already allows.
  final OwnerLookup _owner;

  /// Where a changed answer goes. Defaulted to the disabled recorder, like
  /// every instrumented constructor in this app, so the tests that only care
  /// about the probability build this handler unchanged.
  final PipelineProgress _pipeline;

  /// The owner's Needs You slider, read the same way every other reader of
  /// it does. A callback rather than a value because the slider moves under a
  /// handler that is built once, and the flag this writes has to mean what the
  /// tiles elsewhere mean.
  final Future<double> Function()? _threshold;

  /// The decision model, for a message whose stored decision is missing or
  /// was made without the owner known. It THROWS when it cannot answer, and
  /// the throw is left to the worker, which parks the kind: there is no
  /// language-model fallback for the default prompt.
  final DecisionClient _decision;

  /// The owner's Needs You answers, which [applyDecision] lets replace the
  /// model's on a re-decide. The copy step needs none: it copies the stored
  /// decision's `needs_you_p`, which already carries the owner's answer, and
  /// its reason from the stored answers, which say so. Null in a test that
  /// wires none.
  final NeedsYouExemplars? _exemplars;

  NeedsYouHandler(
    this._store, {
    required DecisionClient decisionClient,
    ActivityLog? activityLog,
    OwnerLookup? owner,
    PipelineProgress progress = const PipelineProgress.disabled(),
    Future<double> Function()? needsYouThreshold,
    this._exemplars,
  })  : _decision = decisionClient,
        _log = activityLog ?? ActivityLog.disabled(),
        _owner = memoizedOwner(owner ?? (() async => null)),
        _pipeline = progress,
        _threshold = needsYouThreshold;

  @override
  String get kind => 'needs_you';

  /// Three at once. An item writes its own row, its own decision row and
  /// extraction, and at most its thread's CTA fold, which only the thread's
  /// newest inbound message moves (`foldCtaUp`'s own guard) — the same fold
  /// three triage claims already run side by side — so items of this kind
  /// are independent of each other, which is the bar
  /// [WorkHandler.concurrency] sets for raising it.
  @override
  int get concurrency => 3;

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final id = item['entity_id'] as String? ?? '';

    final row = await _store.getMessageRow(source, id);
    // Queued, then deleted before the worker reached it. Nothing to judge and
    // nothing wrong — the item is done, not failed.
    if (row == null) {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'deleted'});
      return;
    }

    // The user's own message. The enqueue only ever offers inbound rows, so
    // this is a guard rather than a case — and it is here for the reason every
    // guard in this handler is: the queue can hand over a row that has changed
    // since it was written.
    if (row['direction'] != 'inbound') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'outbound'});
      return;
    }

    // Queued, then GATED before the worker reached it — [DraftHandler]'s exit,
    // and the same `teams_source` tolerance: a chat stored before chats were
    // triaged is `skipped` for a reason no judgement stands behind.
    if (row['triage_status'] == 'skipped' &&
        row['gate_reason'] != 'teams_source') {
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'gated'});
      return;
    }

    // Read BEFORE any branch writes, because "did the answer move" is the
    // whole condition on the chip rewrite below and there is no other record
    // of what it was. NULL is "not decided yet".
    final previous = (row['needs_you_p'] as num?)?.toDouble();

    // A decision made with the owner known is trusted as it stands. One made
    // WITHOUT the owner line is shown but untrusted (the head was trained with
    // that line): it is decided again here once the owner is known, and kept
    // as it is while the owner is still unknown, so a pass run before the
    // keychain answers does not re-decide the same message over and over.
    // Either way a kept p is copied onto the row only when the row does not
    // already carry it.
    final found = await _store.decisionFor(source, id);
    final storedP = found?.needsYouP;
    final stored =
        found != null && storedP != null && found.answers.fields.isNotEmpty
            ? found
            : null;
    final owner = stored != null && stored.ownerKnown
        ? null
        : decisionOwnerString(await _owner());
    if (stored != null &&
        storedP != null &&
        (stored.ownerKnown || owner == null)) {
      if (previous == storedP) {
        _log.note({
          'source': 'decision',
          'p': storedP,
          'reason': stored.ownerKnown ? 'decided' : 'owner_unknown',
        });
        return;
      }
      await _store.writeNeedsYouP(
        source,
        id,
        p: storedP,
        reason: needsYouYesReason(stored.answers),
      );
      _log.note({'source': 'decision', 'p': storedP});
      await followNeedsYouChip(
        _pipeline,
        source,
        id,
        previous: previous,
        p: storedP,
        threshold: _threshold,
      );
      return;
    }

    // No decision, or an ownerless one now that the owner is known: decide
    // again, with the decision model and the same input the triage pass
    // builds. With no decision at all and the owner still unknown the message
    // is decided ownerless anyway and its p written, because an undecided row
    // is a message nobody sees; a later pass decides it again once the owner
    // is known (see above). A throw — the decision server down, its heads
    // refused — is left to the worker, which parks the kind.
    final decided = await _decision.decide(await decisionInputFor(
      _store,
      source,
      Message.fromRow(row),
      conversationKey: row['conversation_key'] as String?,
      owner: owner,
    ));
    // The whole state the decision determines, through the writer the triage
    // claim uses, so a message decided here reads exactly as one triage
    // decided: its urgency, category, booleans, extraction intent and thread
    // fold move with its p, and its chip follows the p across the slider.
    await applyDecision(
      _store,
      source,
      row,
      decided,
      ownerKnown: owner != null,
      progress: _pipeline,
      threshold: _threshold,
      exemplars: _exemplars,
    );
    _log.note({
      'source': 'decision',
      'p': needsYouP(decided.answers),
      'redecided': true,
      'owner_known': owner != null,
    });
  }
}
