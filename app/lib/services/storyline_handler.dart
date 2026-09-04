import 'activity_log.dart';
import 'ai_worker.dart';
import 'pipeline_progress.dart';
import 'storyline_service.dart';

/// The storyline queues, as work handlers.
///
/// All are thin on purpose: the worker owns claiming, retrying and parking,
/// and everything a handler adds on top of calling the service is behaviour
/// the worker can no longer see.

/// Considers one conversation for the storylines that already exist. Queued by
/// the extraction handler whenever a thread's embedding changes.
class StorylineAssignHandler extends WorkHandler {
  static const String _source = 'email';

  final StorylineService _service;

  /// Where the pass's outcome goes when it is worth saying. The service notes
  /// what it FILED; this notes the two ways it deliberately did not.
  final ActivityLog _log;

  /// Where this stage lands for the home screen. Defaulted to the disabled
  /// recorder, so a test that builds this handler writes nothing extra.
  final PipelineProgress _pipeline;

  StorylineAssignHandler(
    this._service, {
    ActivityLog? activityLog,
    PipelineProgress progress = const PipelineProgress.disabled(),
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress;

  @override
  String get kind => 'storyline';

  @override
  Future<void> run(Map<String, Object?> item) async {
    final source = item['source'] as String? ?? _source;
    final key = item['entity_id'] as String? ?? '';
    // An empty key is a row nothing can be done about. Done, not failed —
    // retrying it would produce the same nothing twice.
    if (key.isEmpty) return;

    final outcome = await _service.assignConversation(source, key);
    // Four of the five outcomes end this stage: the thread was filed, or it
    // was looked at and deliberately not filed. `noVector` is the exception —
    // the queue parks on an embedding server that is not running, so the bar
    // parks with it rather than claiming a verdict nobody reached.
    switch (outcome) {
      // `assigned` is noted by the service, with the storyline's NAME — the
      // handler only has the conversation key, which the row already carries.
      case AssignOutcome.assigned:
        await _pipeline.noteStoryline(
          source,
          key,
          state: 'done',
          storylineId: await _pipeline.assignedStorylineId(source, key),
        );
      // `noCandidate` is noted by nobody, and that silence is load-bearing:
      // `storyline` is a quiet kind, so a pass that did nothing writes no row
      // at all — but only while every detail it carries is a zero. One string
      // here would put a row in the activity panel for every thread whose
      // embedding changed and matched nothing, which is most of them.
      case AssignOutcome.noCandidate:
        await _pipeline.noteStoryline(source, key, state: 'done');
      case AssignOutcome.rejected:
      case AssignOutcome.blocked:
        await _pipeline.noteStoryline(source, key, state: 'done');
        _log
          ..noteStatus('skipped')
          ..note({'outcome': outcome.name});
      case AssignOutcome.noVector:
        break;
    }
  }
}

/// Hunts for member threads one storyline is missing, against the charter the
/// user just saved. Queued only by `StorylineService.setCharter`, one row per
/// storyline id — a second save before the first pass drains changes nothing,
/// which is exactly right: the pass reads the charter when it runs.
class StorylineRecruitHandler extends WorkHandler {
  final StorylineService _service;

  StorylineRecruitHandler(this._service);

  @override
  String get kind => 'storyline_recruit';

  @override
  Future<void> run(Map<String, Object?> item) {
    final id = item['entity_id'] as String? ?? '';
    // An empty id is a row nothing can be done about. Done, not failed —
    // retrying it would produce the same nothing twice.
    if (id.isEmpty) return Future<void>.value();
    return _service.recruit(id);
  }
}

/// Re-describes one storyline whose membership has moved — its title, its
/// summary, and its charter when the charter is the model's own. Queued by
/// every path that changes who is in a storyline: the user's add and remove,
/// a cleared charter, the assignment pass under its growth gate, a recruit
/// that filed something, and the sweep's catch-up for the ones that were lost.
///
/// Registered BETWEEN the sweep and the recruit, and the position is
/// behaviour. `AiWorker._drainAll` walks handlers in list order once per pass,
/// so a row written for a LATER handler drains in the same pass and a row for
/// an earlier one waits: a user edit refreshes and then recruits in one drain,
/// while a recruit that files threads has its refresh wait a pass. That is the
/// damper on the only cycle these two can form.
class StorylineRefreshHandler extends WorkHandler {
  final StorylineService _service;

  StorylineRefreshHandler(this._service);

  @override
  String get kind => 'storyline_refresh';

  @override
  Future<void> run(Map<String, Object?> item) {
    final id = item['entity_id'] as String? ?? '';
    // An empty id is a row nothing can be done about. Done, not failed —
    // retrying it would produce the same nothing twice.
    if (id.isEmpty) return Future<void>.value();
    return _service.refresh(id);
  }
}

/// Looks for new groups across everything not in a storyline yet. Queued once
/// per sync against the single entity id `sweep` — there is one mailbox, so
/// there is one sweep, and the work table's primary key is what keeps a
/// hundred syncs from queueing a hundred of them.
class StorylineSweepHandler extends WorkHandler {
  final StorylineService _service;

  StorylineSweepHandler(this._service);

  @override
  String get kind => 'storyline_sweep';

  @override
  Future<void> run(Map<String, Object?> item) => _service.sweep();
}
