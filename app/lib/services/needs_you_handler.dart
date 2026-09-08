import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'attachments/attachment_digest_lines.dart';
import 'ai_worker.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'attention.dart';
import 'llm/needs_you_task.dart';
import 'needs_you.dart';
import 'pipeline_progress.dart';

/// Who the owner is, asked lazily. A record rather than two arguments so
/// "the app does not know yet" is one null rather than two — a keychain that
/// has not answered has no name AND no address.
typedef OwnerLookup = Future<({String? name, String? address})?> Function();

/// Decides whether ONE message needs the owner, and writes the verdict onto
/// its row.
///
/// `entity_id` is a source message id: this is a judgement about a thing
/// somebody said, not about the thread it was said in, and a quiet thread that
/// gets one direct question is exactly the case a per-thread verdict would
/// lose.
///
/// The verdict is TRI-STATE on `messages`, and the third state is the point.
/// NULL means this pass has never judged the row — which is what makes the
/// unjudged rows a worklist — 0 is a judgement that the message does not need
/// the owner, and 1 that it does. The deterministic floor
/// ([needsYouFloor]) only ever RAISES it, and so does the model below it: what
/// the floor is silent about is read by [NeedsYouTask], which is the only
/// thing here that can write a 0.
///
/// The owner's `needs_you_rules` pref REPLACES the default body of the system
/// prompt outright — an empty pref is the default body. It is read per item,
/// so an edit mid-drain reaches the rest of the drain, and memoized on its own
/// text, so an unchanged pref costs no rebuilt prompt.
///
/// It reads the message, never triage's verdicts. The queue in front of this
/// handler takes rows whose `triage_status` is still `pending`, so
/// `reply_expected` and `needs_action` may not have been written yet — and
/// waiting on them would make the verdict depend on which drain got there
/// first. The body is what this pass judges.
///
/// This handler deliberately has NO arm in [AiWorker]'s `_park` and
/// `_recordFailure` per-kind ladders. Those ladders exist for one reason: a
/// stage with a `message_progress` column has to re-note its state when the
/// worker, not the handler, decides how an exception ended. Needs-you has no
/// stage column, so an arm here would write nothing and read as an oversight
/// to the next person who "fixes" it. The generic parking above those ladders
/// still applies: a model that is not running parks the whole kind.
///
/// It does move ONE `message_progress` column, and it is not a stage. The
/// `needs_you` flag on a settled row is a snapshot of the verdict taken at
/// settle time, so a verdict this pass CHANGES leaves the chip beside it
/// showing the old answer — a home screen disagreeing with the row it reads
/// from. When, and only when, the stored verdict moves, the tail below hands
/// the message to [PipelineProgress.refreshNeedsYou], which re-asks
/// `notifyWorthy` and rewrites the flag. A re-verdict that returns the SAME
/// answer writes nothing, which is what keeps a chip cleared by a reply or by
/// a Done from coming back.
class NeedsYouHandler extends WorkHandler {
  static const String _source = 'email';

  /// A sentence, a boolean and an enum. No room for the model to start
  /// drafting inside a judgement.
  static const int _maxTokens = 256;

  final MessageStore _store;
  final LlmClient _client;

  /// Where a pass that deliberately did nothing gets to say so. Defaulted to
  /// the disabled log, so a test that builds this handler writes nothing extra.
  final ActivityLog _log;

  final OwnerLookup _owner;

  /// The owner lookup, asked ONCE for the life of this handler. It is a
  /// keychain read, and the answer only changes on sign-out — which disposes
  /// the provider that built this handler and so builds a new one. Only a
  /// lookup that ANSWERED is kept — see [_ownerIdentity].
  Future<({String? name, String? address})?>? _ownerFuture;

  /// The task, memoized on the rules text it was built from. The pref is read
  /// per item so a mid-drain edit takes effect on the next message, but an
  /// UNCHANGED pref must reuse the same task — same string object, same KV
  /// prefix — rather than rebuild the prompt per item.
  String? _rulesText;
  NeedsYouTask _task = const NeedsYouTask();

  /// Where a changed verdict goes. Defaulted to the disabled recorder, like
  /// every instrumented constructor in this app, so the tests that only care
  /// about the verdict build this handler unchanged.
  final PipelineProgress _pipeline;

  /// The user's attention floor, read the same way the settle machine reads
  /// it. A callback rather than a value because the slider moves under a
  /// handler that is built once, and the flag this writes has to mean what the
  /// tiles elsewhere mean.
  final Future<double> Function()? _threshold;

  NeedsYouHandler(
    this._store,
    this._client, {
    ActivityLog? activityLog,
    OwnerLookup? owner,
    PipelineProgress progress = const PipelineProgress.disabled(),
    Future<double> Function()? attentionThreshold,
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _owner = owner ?? (() async => null),
        _pipeline = progress,
        _threshold = attentionThreshold;

  @override
  String get kind => 'needs_you';

  /// Three at once. An item touches nothing shared — it reads one row and
  /// writes that same row's two columns — so items of this kind are genuinely
  /// independent of each other, which is the bar [WorkHandler.concurrency]
  /// sets for raising it.
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

    // Read BEFORE either branch writes, because "did the verdict move" is the
    // whole condition on the chip rewrite below and there is no other record
    // of what it was. Stored shape, not Dart's: 0, 1 or null, where null is
    // "never judged" and differs from both.
    final previous = _int(row['needs_you_verdict']);

    if (needsYouFloor(row)) {
      await _store.writeNeedsYouVerdict(
        source,
        id,
        verdict: true,
        reason: 'teams_direct',
      );
      _log.note({'verdict': true, 'reason': 'teams_direct'});
      await _followChip(source, id, previous: previous, verdict: true);
      return;
    }

    // Below the floor, which settles nothing: the model reads the text.
    var message = Message.fromRow(row);
    final key = row['conversation_key'] as String? ?? '';
    // Hydrated only when the row says there is something to hydrate —
    // `loadThread` does this for a whole thread; a single-row read has to ask.
    if (row['has_attachments'] == 1) {
      message = message.withAttachments(
        await _store.attachmentRefsFor(source, id, conversationKey: key),
      );
    }
    // The thread AS IT WAS when this message landed, so the verdict on a
    // message does not change with how far behind the queue was.
    final thread = await _store.loadThread(
      key,
      sources: [source],
      untilIso: row['received_at'] as String? ?? row['created_at'] as String?,
    );
    final context = [
      for (final earlier in thread)
        if (earlier.id != message.id) earlier,
    ];
    // What the files on this message say, when any of them have been read.
    // Keyed on this message alone and not the thread: the judgement is about
    // what THIS message asks of the owner, and a contract attached three turns
    // ago is context the thread text already carries.
    //
    // The digest handler requeues this kind once a document lands an ask, so a
    // message judged before its attachments were read is judged again with
    // this block filled in.
    final digests = (await _store.digestsForMessages(source, [id]))[id] ??
        const <Map<String, Object?>>[];

    // Read per item rather than held, like [DraftHandler]'s about-me: someone
    // who edits their rules mid-drain wants the rest of the drain to use them.
    final rules = await _store.getPref(needsYouRulesKey);
    final owner = await _ownerIdentity();

    final result = await runTask(
      _client,
      _taskFor(rules),
      NeedsYouInput(
        message: message,
        thread: context,
        attachmentDigests: attachmentDigestLines(digests),
        ownerName: owner?.name,
        ownerAddress: owner?.address,
        now: DateTime.now(),
      ),
      // Zero, like every judgement in this app: the same message must get the
      // same verdict twice, or a re-drain would flip rows under the user.
      temperature: 0,
      maxTokens: _maxTokens,
    );

    // Raise-only, hesitation included. The floor has already said yes to
    // everything it covers, so all this model can do is raise what the floor
    // left alone — and a low-confidence yes stays a no, because the verdict
    // buys an interruption and "possibly" is not grounds for one.
    final verdict = result.needsYou && result.confidence != 'low';

    // A throw from the call above — the model being down included — is left to
    // propagate. The verdict stays NULL, the row stays on the worklist, and
    // the worker's park-and-retry machinery owns what happens next.
    await _store.writeNeedsYouVerdict(
      source,
      id,
      verdict: verdict,
      reason: result.evidence,
    );
    _log.note({'verdict': verdict, 'confidence': result.confidence});
    await _followChip(source, id, previous: previous, verdict: verdict);
  }

  /// Moves the settled row's Needs You chip when — and only when — this pass
  /// changed the answer.
  ///
  /// The comparison is against the STORED shape, so a first verdict (`null` →
  /// 0 or 1) counts as a change and a repeat of either answer does not. That
  /// asymmetry is the point: a repeat must write nothing, or a chip the user
  /// cleared by replying would come back every time the row was re-judged.
  ///
  /// Nothing here can fail the item. The recorder swallows its own errors, and
  /// the threshold read below degrades to the default: a chip that did not
  /// follow is a stale square on the home screen, and re-running a model call
  /// over it would be the more expensive mistake.
  Future<void> _followChip(
    String source,
    String id, {
    required int? previous,
    required bool verdict,
  }) async {
    if (previous == (verdict ? 1 : 0)) return;
    await _pipeline.refreshNeedsYou(
      source,
      id,
      threshold: await _thresholdOrDefault(),
    );
  }

  /// The settle machine's own reader, degraded the settle machine's way — see
  /// `NotificationCoordinator._attentionThreshold`. A preference that cannot
  /// be read is a default, never a failed item.
  Future<double> _thresholdOrDefault() async {
    final read = _threshold;
    if (read == null) return AttentionTuning.defaultThreshold;
    try {
      return await read();
    } catch (e) {
      debugPrint('needs_you: reading the attention threshold failed: $e');
      return AttentionTuning.defaultThreshold;
    }
  }

  /// The stored verdict as it sits on the row: 0, 1, or null for never judged.
  static int? _int(Object? value) => (value as num?)?.toInt();

  /// The task for one pref reading, built at most once per distinct text.
  ///
  /// Empty and default-equal both take the const default path. The pane
  /// normalizes a default-equal save back to '', but a pref written by hand
  /// must not silently fork the prompt into a non-const copy of the same
  /// words — that would cost a cache re-prime for no change in what is asked.
  ///
  /// The clamp mirrors the editor's `maxLength`, for the same case: a pref
  /// that reached the store through something other than the pane.
  NeedsYouTask _taskFor(String? rules) {
    var body = rules?.trim() ?? '';
    if (body.length > needsYouRulesCap) body = body.substring(0, needsYouRulesCap);
    if (body.isEmpty || body == needsYouDefaultRules.trim()) {
      if (_rulesText != null) {
        _rulesText = null;
        _task = const NeedsYouTask();
      }
      return _task;
    }
    if (body != _rulesText) {
      _rulesText = body;
      _task = NeedsYouTask.withRules(body);
    }
    return _task;
  }

  /// The memoized lookup, degraded rather than trusted. A keychain read that
  /// THREW is forgotten — caching the failed future would leave every later
  /// item rethrowing a hiccup until the app restarts — and this prompt simply
  /// names no owner, which the line's own contract already allows. Failing the
  /// item instead would spend its retries on something no retry of the model
  /// can fix.
  Future<({String? name, String? address})?> _ownerIdentity() async {
    try {
      return await (_ownerFuture ??= _owner());
    } catch (_) {
      _ownerFuture = null;
      return null;
    }
  }
}
