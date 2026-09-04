import '../data/message_store.dart';
import 'activity_log.dart';
import 'ai_worker.dart';
import 'needs_you.dart';

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
/// ([needsYouFloor]) only ever RAISES it: a message the floor says nothing
/// about is left NULL for whoever judges next, never written down as a no.
///
/// This handler deliberately has NO arm in [AiWorker]'s `_park` and
/// `_recordFailure` per-kind ladders. Those ladders exist for one reason: a
/// stage with a `message_progress` column has to re-note its state when the
/// worker, not the handler, decides how an exception ended. Needs-you has no
/// stage column, so an arm here would write nothing and read as an oversight
/// to the next person who "fixes" it.
class NeedsYouHandler extends WorkHandler {
  static const String _source = 'email';

  final MessageStore _store;

  /// Where a pass that deliberately did nothing gets to say so. Defaulted to
  /// the disabled log, so a test that builds this handler writes nothing extra.
  final ActivityLog _log;

  NeedsYouHandler(this._store, {ActivityLog? activityLog})
      : _log = activityLog ?? ActivityLog.disabled();

  @override
  String get kind => 'needs_you';

  /// Three at once. The floor touches nothing shared — it reads one row and
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

    // Below the floor, and that is not a verdict. The row stays NULL so it is
    // still on the worklist for the judgement that can actually read the text.
    // Phase 2: model judgment for non-floor messages lands here.
    _log
      ..noteStatus('skipped')
      ..note({'reason': 'below_floor'});
  }
}
