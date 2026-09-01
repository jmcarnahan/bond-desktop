import 'ai_worker.dart';
import 'storyline_service.dart';

/// The two storyline queues, as work handlers.
///
/// Both are thin on purpose: the worker owns claiming, retrying and parking,
/// and everything a handler adds on top of calling the service is behaviour
/// the worker can no longer see.

/// Considers one conversation for the storylines that already exist. Queued by
/// the extraction handler whenever a thread's embedding changes.
class StorylineAssignHandler extends WorkHandler {
  static const String _source = 'email';

  final StorylineService _service;

  StorylineAssignHandler(this._service);

  @override
  String get kind => 'storyline';

  @override
  Future<void> run(Map<String, Object?> item) {
    final source = item['source'] as String? ?? _source;
    final key = item['entity_id'] as String? ?? '';
    // An empty key is a row nothing can be done about. Done, not failed —
    // retrying it would produce the same nothing twice.
    if (key.isEmpty) return Future<void>.value();
    return _service.assignConversation(source, key);
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
