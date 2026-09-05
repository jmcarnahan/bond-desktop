import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'llm/json_task.dart';
import 'llm/llm_client.dart';
import 'llm/needs_you_task.dart';
import 'needs_you.dart';

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

  NeedsYouHandler(
    this._store,
    this._client, {
    ActivityLog? activityLog,
    OwnerLookup? owner,
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _owner = owner ?? (() async => null);

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

    if (needsYouFloor(row)) {
      await _store.writeNeedsYouVerdict(
        source,
        id,
        verdict: true,
        reason: 'teams_direct',
      );
      _log.note({'verdict': true, 'reason': 'teams_direct'});
      return;
    }

    // Below the floor, which settles nothing: the model reads the text.
    final message = Message.fromRow(row);
    final key = row['conversation_key'] as String? ?? '';
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
    // Read per item rather than held, like [DraftHandler]'s about-me: someone
    // who edits their rules mid-drain wants the rest of the drain to use them.
    final rules = await _store.getPref(needsYouRulesKey);
    final owner = await _ownerIdentity();

    final result = await runTask(
      _client,
      const NeedsYouTask(),
      NeedsYouInput(
        message: message,
        thread: context,
        userRules: rules,
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
