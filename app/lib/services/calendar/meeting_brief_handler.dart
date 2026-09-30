import 'dart:convert';

import '../../data/calendar_store.dart';
import '../../models/calendar_models.dart';
import '../activity_log.dart';
import '../ai_worker.dart';
import '../llm/json_task.dart';
import '../llm/llm_client.dart';
import '../llm/meeting_brief_task.dart';
import 'brief_gatherer.dart';
import 'event_view.dart' show displayOccurrence;

/// What a `meeting_brief` row's `payload_json` says: whether a person asked
/// for this brief (Regenerate) rather than the planner having queued it.
///
/// The draft row's `DraftRequest` shape (`{"asked":true}`) with none of its
/// ids, because a brief has nothing to pin. `asked` is true only for the
/// literal `true`, and anything unreadable reads as not asked — a malformed
/// payload costs the override, never the brief.
class BriefRequest {
  final bool asked;
  const BriefRequest({this.asked = false});

  static const BriefRequest none = BriefRequest();

  factory BriefRequest.fromPayload(Object? payloadJson) {
    if (payloadJson is! String || payloadJson.isEmpty) return none;
    try {
      final decoded = jsonDecode(payloadJson);
      return decoded is Map && decoded['asked'] == true
          ? const BriefRequest(asked: true)
          : none;
    } on FormatException {
      return none;
    }
  }

  /// Null when nothing was asked, so a planner row keeps a null payload.
  String? encode() => asked ? jsonEncode({'asked': true}) : null;
}

/// Writes one pre-meeting brief: `work_items(kind: 'meeting_brief', source:
/// 'calendar', entity_id: the event id)`.
///
/// On the DRAFT lane, after `draft`: a brief is user-facing prose on the
/// generative model, read by a person rather than by another stage, so it
/// belongs with the other thing a person reads — and after the draft handler,
/// because a reply someone is waiting on outranks a brief for a meeting
/// hours away. The planner queues it after a calendar sync and pumps this
/// lane; Regenerate requeues it to the front.
///
/// Every outcome is a row in `event_briefs`, so the panel can always say
/// something: `ready` with the brief, `skipped` with the rule that kept the
/// meeting out, or `failed` — except over a READY brief, which a failure or a
/// skip never replaces: the old brief keeps its text and status and only its
/// `generated_at` moves ([CalendarStore.touchBrief]), so the planner's
/// two-hour rule throttles the retries. A dead model server is NOT an outcome: the
/// [LlmUnavailableException] goes straight through to the worker, which parks
/// the kind without spending an attempt, exactly as it parks a draft.
class MeetingBriefHandler extends WorkHandler {
  MeetingBriefHandler(
    this._calendar,
    this._gatherer, {
    required this._client,
    ActivityLog? activityLog,
    DateTime Function()? clock,
    this._onStored,
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _clock = clock ?? DateTime.now;

  final CalendarStore _calendar;
  final BriefGatherer _gatherer;

  /// The `meeting_brief` stage's client, asked for at the call. A closure so
  /// a test can hand a different double per run; the provider hands the one
  /// stage client it watched.
  final LlmClient Function() _client;
  final ActivityLog _log;
  final DateTime Function() _clock;

  /// Told after every row this handler writes, so an open panel re-reads.
  final void Function()? _onStored;

  @override
  String get kind => 'meeting_brief';

  @override
  Future<void> run(Map<String, Object?> item) async {
    final asked = BriefRequest.fromPayload(item['payload_json']).asked;
    final now = _clock();
    final stamp = calendarStamp(now);

    final stored = await _calendar.event(item['entity_id'] as String? ?? '');
    if (stored == null) {
      await _skip(item['entity_id'] as String? ?? '', BriefIneligibility.gone,
          stamp);
      return;
    }
    // The planner queues occurrences and the panel regenerates the occurrence
    // it shows, but a master can still arrive (a row queued by an older
    // build). It is briefed as the occurrence the panel would show, and the
    // row is keyed by THAT occurrence's id, because `eventBriefProvider`
    // reads briefs by the shown occurrence and a row under the master's id
    // would never be read.
    var event = stored;
    if (stored.isSeriesMaster) {
      event = displayOccurrence(
        stored,
        await _calendar.occurrencesOf(stored.id),
        now.toUtc(),
        _gatherer.zoneNow(),
      );
    }
    final id = event.id;
    final existing = await _calendar.brief(id);

    final gathered = await _gatherer.gather(event, now: now);
    final BriefInput input;
    switch (gathered) {
      case BriefIneligible(:final why):
        await _skip(id, why, stamp, existing: existing);
        return;
      case BriefEligible(input: final found):
        input = found;
    }

    // A person's Regenerate always writes: they are looking at the brief and
    // asked for another, and "nothing changed" is not an answer to that.
    if (!asked &&
        existing != null &&
        existing.isReady &&
        existing.inputsHash == input.inputsHash) {
      // Nothing it was written from has moved: the stored brief IS the
      // answer, and a second call would only reword it.
      _log
        ..noteStatus('skipped')
        ..note({'reason': 'unchanged'});
      return;
    }

    try {
      final brief = await runTask(
        _client(),
        MeetingBriefTask(threadCount: input.threads.length),
        input,
        temperature: MeetingBriefTask.temperature,
        maxTokens: MeetingBriefTask.maxTokens,
      );
      if (brief.headline.isEmpty) {
        // Retryable, on the draft handler's rule for an empty reply: a blank
        // headline is usually a one-off, and storing it would put an empty
        // brief in the panel as though it were one.
        throw const LlmFormatException('The model wrote an empty brief.');
      }
      final withThreads = brief.withThreads([
        for (final t in input.threads)
          BriefThreadRef(
            source: t.source,
            conversationKey: t.conversationKey,
            subject: t.subject,
          ),
      ]);
      await _calendar.putBrief(
        eventId: id,
        inputsHash: input.inputsHash,
        status: EventBrief.ready,
        briefJson: jsonEncode(withThreads.toJson()),
        model: _modelOf(),
        generatedAt: stamp,
      );
      _log.note({
        'threads': input.threads.length,
        'asks': withThreads.openAsks.length,
      });
      _stored();
    } on LlmUnavailableException {
      // Parks the lane; the stored row, if any, stands.
      rethrow;
    } catch (_) {
      // The worker records the error and decides retry against give-up. Over
      // a ready brief the old one stands and only its stamp moves; otherwise
      // the row says the brief could not be written so the panel offers
      // Regenerate rather than waiting on a brief that is not coming.
      if (existing != null && existing.isReady) {
        await _calendar.touchBrief(id, generatedAt: stamp);
        _log.note({'kept': 'ready'});
      } else {
        await _calendar.putBrief(
          eventId: id,
          inputsHash: input.inputsHash,
          status: EventBrief.failed,
          generatedAt: stamp,
        );
      }
      _stored();
      rethrow;
    }
  }

  /// Records why the meeting got no brief — unless a ready brief is stored,
  /// which stands (a meeting that has just started, or whose mail aged out
  /// of the window, still has a brief worth reading) with only its stamp
  /// moved.
  Future<void> _skip(
    String id,
    BriefIneligibility why,
    String stamp, {
    EventBrief? existing,
  }) async {
    if (existing != null && existing.isReady) {
      await _calendar.touchBrief(id, generatedAt: stamp);
      _log
        ..noteStatus('skipped')
        ..note({'reason': why.wire, 'kept': 'ready'});
      _stored();
      return;
    }
    await _calendar.putBrief(
      eventId: id,
      inputsHash: '${EventBrief.ineligiblePrefix}${why.wire}',
      status: EventBrief.skipped,
      generatedAt: stamp,
    );
    _log
      ..noteStatus('skipped')
      ..note({'reason': why.wire});
    _stored();
  }

  /// The model the stage resolved to, for the row. Empty when the client
  /// cannot say: the row is still worth writing without it.
  String _modelOf() {
    try {
      return _client().model;
    } on Object {
      return '';
    }
  }

  void _stored() {
    try {
      _onStored?.call();
    } on Object {
      // A torn-down container; the next read finds the row anyway.
    }
  }
}
