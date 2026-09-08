import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'attention.dart';
import 'notify/settled_event.dart';
import 'notify_worthy.dart';
import 'pipeline_progress.dart';

// Re-exported because this file is where `notifyWorthy` lived, and the settle
// is still where a reader looks for it. It moved out so `PipelineProgress` can
// call it — the coordinator imports that recorder, so the recorder cannot
// import back.
export 'notify_worthy.dart' show notifyWorthy, ownsCta;

/// The coordinator's own copy of the null-tolerant int read. Private in both
/// files on purpose: it is a cast, not a rule, and nothing about the settle
/// depends on the two staying the same expression.
int? _int(Object? value) => (value as num?)?.toInt();

/// Decides, once per message, whether the user hears about it.
///
/// Every eligible inbound message gets a `message_notify` row the moment it
/// lands, and that row leaves `pending` exactly once — `notified` or
/// `suppressed` — inside a bounded deadline. Only a settle that this process
/// won emits a [MessageSettled], so a message is announced once or not at all,
/// across crashes and across two app instances on one database file.
///
/// It talks to sqlite and the activity log and to nothing else: no backend, no
/// Graph call, no poll of Teams. The timer below wakes up, reads the store,
/// writes the store, and goes back to sleep — which is what makes it safe to
/// leave running in an offline session.
class NotificationCoordinator {
  /// How long a message may stay undecided. This is the honest budget for the
  /// pipeline behind it — fast triage, extraction, an embed and one confirm —
  /// with room for a single 120s model timeout and its retry. Past it the row
  /// settles on whatever verdicts exist, because a mention six minutes late is
  /// still useful and one that never comes is a lost message.
  static const Duration settleDeadline = Duration(minutes: 6);

  /// How far back a message's own timestamp may reach and still count as new.
  /// A first Teams connect writes weeks of history with a `created_at` of now;
  /// only `received_at` shows that it is old.
  static const Duration recencyWindow = Duration(hours: 6);

  /// The floor under everything here. In a Teams-only or offline session this
  /// timer is the ONLY thing running, so the deadline has to be reachable
  /// without a sync ever completing again.
  static const Duration sweepInterval = Duration(seconds: 30);

  /// Longer than the list reload's 400ms debounce on purpose: a drain finishing
  /// twenty items fires twenty activity events, and this collapses that burst
  /// into one sweep rather than twenty.
  static const Duration eventDebounce = Duration(milliseconds: 750);

  /// The activity kinds that can change a verdict. A sync or a draft event
  /// moves nothing this reads, so it does not wake the sweep.
  ///
  /// These are activity-row kinds, and `AiWorker` stamps each row with its
  /// handler's `kind` — so `needs_you` here is `NeedsYouHandler.kind`, the same
  /// string as its `work_items.task_kind`. It earns a place because the pass
  /// both writes an ask this reads and holds the row open until it lands.
  static const Set<String> _pipelineKinds = {
    'triage',
    'needs_you',
    'extract',
    'storyline',
  };

  /// The reasons that mean **the app decided the user does not need this**,
  /// which is exactly what `dropped` records. `read`, `done` and `stale` are
  /// not among them and must not be: a message the user got to before the
  /// pipeline settled is finished, not discarded, and hiding it under the
  /// "show dropped" toggle would be the app taking credit for a decision the
  /// person made. Neither is `deadline`: a deadline suppression is a verdict
  /// rendered on an INCOMPLETE pipeline — for a message whose triage never
  /// ran (a model server down, a backlog) it is a timeout, not a judgment,
  /// and hiding it would bury exactly the messages the pipeline failed on.
  static const Set<String> _dropReasons = {'gated', 'not_worthy'};

  final MessageStore _store;
  final ActivityLog _log;

  /// Where each settle lands for the home screen.
  final PipelineProgress _pipeline;

  final Future<double> Function()? _threshold;
  final DateTime Function() _clock;

  /// When this process first saw a sync complete. In memory on purpose — see
  /// [noteSyncCompleted].
  DateTime? _armedAt;

  bool _started = false;
  bool _sweeping = false;
  bool _resweep = false;

  Timer? _debounce;
  Timer? _timer;
  StreamSubscription<ActivityEvent>? _events;
  final _controller = StreamController<MessageSettled>.broadcast();

  NotificationCoordinator(
    this._store, {
    ActivityLog? activityLog,
    Future<double> Function()? attentionThreshold,
    DateTime Function()? clock,
    PipelineProgress progress = const PipelineProgress.disabled(),
  })  : _log = activityLog ?? ActivityLog.disabled(),
        _pipeline = progress,
        _threshold = attentionThreshold,
        _clock = clock ?? (() => DateTime.now().toUtc());

  /// Fires once per message that earned a mention. Broadcast: the ribbon and
  /// the OS dispatcher are two independent consumers of the same settle.
  Stream<MessageSettled> get notifications => _controller.stream;

  /// Closes out the previous process's leftovers, then starts listening.
  ///
  /// The expiry runs BEFORE anything can emit, deliberately: rows left open
  /// past their deadline by a session that ended are suppressed silently, so
  /// launching the app does not open with a burst of toasts about mail that
  /// went stale while it was closed.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _store.expireStaleNotify(nowIso: _iso(_clock()));
    } catch (e) {
      debugPrint('notify: expiring stale rows failed: $e');
    }
    _events = _log.events
        .where((e) => _pipelineKinds.contains(e.kind))
        .listen((_) => _scheduleSweep());
    _timer = Timer.periodic(sweepInterval, (_) => unawaited(sweep()));
  }

  void _scheduleSweep() {
    _debounce?.cancel();
    _debounce = Timer(eventDebounce, () => unawaited(sweep()));
  }

  /// Arms admission at the first sync this process completed.
  ///
  /// Keyed to the first successful sync and held in memory, both on purpose: a
  /// fresh process arms fresh, and everything already in the database when it
  /// armed is by definition the backlog — exactly the flood that must never be
  /// announced. This is NOT `sessionStartProvider`: that one dates the UI's
  /// session, this one dates the mailbox's, and conflating them would arm
  /// before the first sync landed and admit the whole first-run download.
  void noteSyncCompleted() {
    _armedAt ??= _clock();
  }

  /// The optimization hook: the drain just wrote its verdicts, so sweep now
  /// rather than waiting up to [sweepInterval]. The timer remains the
  /// guarantee — the chain that calls this swallows failures, so a sweep
  /// missed here is late, not lost.
  Future<void> noteDrainSettled() => sweep();

  /// One pass over the open candidates.
  ///
  /// Serialized: a sweep already running is not joined but noted, and the
  /// runner loops once more when it finishes. Two concurrent passes would both
  /// read the same pending rows and race on the settle — which the store's
  /// guard survives, but at the cost of doing everything twice.
  Future<void> sweep() async {
    if (_sweeping) {
      _resweep = true;
      return;
    }
    _sweeping = true;
    try {
      do {
        _resweep = false;
        await _sweepOnce();
      } while (_resweep);
    } finally {
      _sweeping = false;
    }
  }

  Future<void> _sweepOnce() async {
    // Each stage is wrapped on its own: a failed stage must not take down the
    // sweep loop or the timer that drives it, or one bad read would end
    // notifications for the rest of the session.

    // The watchdog usually rides on a sync. A Teams-only or offline session
    // never runs one, and a claim abandoned there would hold its message
    // `processing` forever — which is a candidate that never completes.
    try {
      final stale = _iso(_clock().subtract(staleClaimAfter));
      await _store.reclaimStaleTriage(
        staleBeforeIso: stale,
        sources: const ['email', 'teams'],
      );
      await _store.reclaimStaleWork(staleBeforeIso: stale);
    } catch (e) {
      debugPrint('notify: reclaiming stale claims failed: $e');
    }

    // Unarmed means no sync has completed in this process yet, and everything
    // in the table is backlog. Nothing is admitted until that changes.
    if (_armedAt != null) {
      try {
        await _store.admitNotifyCandidates(
          armedAtIso: _iso(_armedAt!),
          recencyFloorIso: _iso(_armedAt!.subtract(recencyWindow)),
          deadlineIso: _iso(_clock().add(settleDeadline)),
        );
      } catch (e) {
        debugPrint('notify: admitting candidates failed: $e');
      }
    }

    List<Map<String, Object?>> rows;
    try {
      rows = await _store.openNotifyCandidates();
    } catch (e) {
      debugPrint('notify: reading candidates failed: $e');
      return;
    }
    if (rows.isEmpty) return;

    // Once per sweep, not once per row: the threshold is one preference read
    // and every candidate is judged against the same number.
    final threshold = await _attentionThreshold();
    final nowIso = _iso(_clock());

    for (final row in rows) {
      var decision = _decide(row, threshold: threshold, nowIso: nowIso);
      if (decision == null) continue;
      final source = row['source'] as String? ?? '';
      final id = row['source_message_id'] as String? ?? '';
      // Re-read the row we are about to settle. The candidates were captured
      // when the sweep began, and a verdict written between that capture and
      // this settle would otherwise be lost for good: the settle snapshots the
      // stale answer, and [MessageStore.refreshNeedsYouFlag] refuses to correct
      // a row that was not settled yet when it ran. One extra read per SETTLE,
      // not per candidate — the sweep usually walks past everything it reads,
      // and only the handful that are about to be decided pay for it.
      Map<String, Object?>? fresh;
      try {
        fresh = await _store.notifyRowFor(source, id);
      } catch (e) {
        debugPrint('notify: re-reading $source/$id failed: $e');
      }
      // The fresh read carries what can move under a sweep — the verdict, the
      // read flag, the triage status, the conversation state, the outbound
      // stamp, the score and the bucket. The stage states and
      // `needs_you_judged` stay from the capture, because those only ever move
      // forward and a re-read could only agree with them.
      final current = fresh == null ? row : {...row, ...fresh};
      decision = _decide(current, threshold: threshold, nowIso: nowIso);
      if (decision == null) continue;
      try {
        final settled = await _store.settleNotify(
          source,
          id,
          state: decision.state,
          reason: decision.reason,
        );
        if (!settled) continue;
        final droppedHere = decision.state == 'suppressed' &&
            _dropReasons.contains(decision.reason);
        // The SAME verdict the decision was made on, not a second opinion:
        // `needs_you` is what the home screen's tile reads and the toast is
        // what the user saw, and two evaluations of one predicate would
        // eventually disagree about one message. A dropped row never carries a
        // chip either way — the feed hides it and the tile would still count
        // it.
        await _pipeline.noteSettled(
          source,
          id,
          needsYou: !droppedHere && notifyWorthy(current, threshold: threshold),
          reason: decision.reason,
          dropped: droppedHere,
        );
        if (decision.state != 'notified') continue;
        await _emit(current, decision);
      } catch (e) {
        debugPrint('notify: settling $source/$id failed: $e');
      }
    }
  }

  Future<double> _attentionThreshold() async {
    if (_threshold == null) return AttentionTuning.defaultThreshold;
    try {
      return await _threshold();
    } catch (e) {
      debugPrint('notify: reading the attention threshold failed: $e');
      return AttentionTuning.defaultThreshold;
    }
  }

  /// The decision table, in order. Returns null to leave the row open.
  _Decision? _decide(
    Map<String, Object?> row, {
    required double threshold,
    required String nowIso,
  }) {
    // The gate threw it out after it was admitted. It still settles — every
    // admitted row settles — but silently.
    if (row['triage_status'] == 'skipped') {
      return const _Decision('suppressed', 'gated');
    }
    // Read at settle time as well as at admission: the user opening the
    // message while the model worked is the commonest reason not to interrupt
    // them about it.
    if (_int(row['is_read']) == 1) {
      return const _Decision('suppressed', 'read');
    }
    if (row['conversation_state'] == 'done') {
      return const _Decision('suppressed', 'done');
    }
    if (_isComplete(row)) {
      return notifyWorthy(row, threshold: threshold)
          ? const _Decision('notified', 'settled')
          : const _Decision('suppressed', 'not_worthy');
    }
    final deadline = row['deadline_at'] as String? ?? '';
    if (deadline.compareTo(nowIso) <= 0) {
      // A deadline settle with no attention score scores zero, writes
      // `needs_you = 0`, and nothing ever comes back to it. So hold once more:
      // the score is stamped by the list load's attention sweep, which runs
      // every minute the app is open, and one more deadline's grace is the same
      // bound the deadline itself already asks the user to accept. Past that
      // grace it settles on what it has, because a candidate held forever is
      // worse than one judged on a missing score.
      if (row['attention_score'] == null) {
        final grace = DateTime.tryParse(deadline);
        if (grace != null &&
            nowIso.compareTo(_iso(grace.add(settleDeadline))) < 0) {
          return null;
        }
      }
      return notifyWorthy(row, threshold: threshold)
          ? const _Decision('notified', 'deadline', onDeadline: true)
          : const _Decision('suppressed', 'deadline', onDeadline: true);
    }
    return null;
  }

  /// Whether every pass that could still change the verdict has finished —
  /// asked of the PIPELINE'S RECORD, not of the queue.
  ///
  /// The work rows used to be the answer, and they were the wrong one. They
  /// are enqueued after both drains of a sync while triage claims its rows the
  /// moment a page commits, so a sweep landing in that gap found a triaged
  /// message with no work rows at all and read it as finished. It settled, and
  /// the storyline stamp that arrived a minute later was refused — a row stuck
  /// at `outcome = 'pending'` for good. `extract_state` and `storyline_state`
  /// cannot lie that way: they say `pending` until the stage that owns them
  /// writes something else.
  ///
  /// An ABSENT stage — no `message_progress` row at all — now reads as OPEN
  /// rather than terminal, which is the flip from what the comment below used
  /// to argue. It is the safer default in both directions: the cost of waiting
  /// on a stage nobody will run is one deadline settle, and the cost of not
  /// waiting is the frozen row above. The deadline is what makes that trade
  /// affordable, and it now BITES on a bulk drain — a message past the
  /// 150-per-pass backlog cap has a pending stage and no work row, so it
  /// settles six minutes later instead of immediately. A re-drain is not news,
  /// so that is a price and not a defect.
  ///
  /// `needs_you_judged` keeps the `== 0` spelling its neighbours' `== 1` used
  /// to have, and the documented split still holds for it: an absent key reads
  /// as JUDGED, because needs-you is the one stage with no column of its own
  /// and a projection that forgot the flag would otherwise hold every row to
  /// its deadline. A verdict left STALE by a re-judge also reads as judged, so
  /// a candidate can settle on the old answer — the chip follows the new one
  /// when it lands, through [PipelineProgress.refreshNeedsYou].
  bool _isComplete(Map<String, Object?> row) {
    const terminal = {'triaged', 'error', 'skipped'};
    if (!terminal.contains(row['triage_status'])) return false;
    if (_int(row['needs_you_judged']) == 0) return false;
    const stageTerminal = {'done', 'skipped', 'error'};
    if (!stageTerminal.contains(row['extract_state'])) return false;
    if (!stageTerminal.contains(row['storyline_state'])) return false;
    if (row['attention_score'] == null) return false;
    final aiAt = row['ai_updated_at'] as String?;
    final msgAt = row['message_updated_at'] as String? ?? '';
    // Both are ISO-8601 UTC at the store's one precision, which sorts
    // lexicographically — see [MessageStore.isoStamp] for the mixed-precision
    // trap this used to fall into. A score stamped before the message last
    // changed is a verdict about an older version of it, and waiting for the
    // restamp is the whole point of the deadline.
    if (aiAt == null || aiAt.compareTo(msgAt) < 0) return false;
    return true;
  }

  Future<void> _emit(Map<String, Object?> row, _Decision decision) async {
    if (_controller.isClosed) return;
    final source = row['source'] as String? ?? '';
    final conversationKey = row['conversation_key'] as String? ?? '';

    String? storylineId;
    String? storylineTitle;
    // Only on a complete settle. A deadline settle leaves both null because
    // the storyline pass may still be open — "not known", not "none".
    if (!decision.onDeadline) {
      try {
        final ids = await _store.storylineIdsFor(source, conversationKey);
        if (ids.isNotEmpty) {
          storylineId = ids.first;
          storylineTitle = (await _store.getStoryline(ids.first))?.title;
        }
      } catch (e) {
        // A failed lookup costs the storyline label, not the notification.
        debugPrint('notify: storyline lookup for $conversationKey failed: $e');
      }
    }

    // The same staleness treatment the deadline settle gives the storyline
    // above, for the same reason: the conversation's CTA belongs to the newest
    // triaged message, so on a candidate whose own triage never finished it is
    // somebody else's ask and this toast must not quote it. The urgency goes
    // with it — it only colours the CTA's severity, and a colour kept from a
    // sentence that is no longer shown is a severity about nothing.
    final quotesCta = ownsCta(row);
    if (_controller.isClosed) return;
    _controller.add(
      MessageSettled(
        source: source,
        sourceMessageId: row['source_message_id'] as String? ?? '',
        conversationKey: conversationKey,
        title: row['subject'] as String? ?? row['from_name'] as String?,
        summary: row['summary'] as String?,
        ctaText: quotesCta ? row['cta_text'] as String? : null,
        ctaUrgency:
            CtaUrgency.fromWire(
                quotesCta ? row['cta_urgency'] as String? : null),
        urgency: row['urgency'] as String?,
        deadline: row['deadline'] as String?,
        replyExpected: _int(row['reply_expected']) == 1,
        storylineId: storylineId,
        storylineTitle: storylineTitle,
        attentionScore: (row['attention_score'] as num?)?.toDouble(),
        receivedAt: row['received_at'] as String?,
        settledAt: _iso(_clock()),
        settledOnDeadline: decision.onDeadline,
      ),
    );
  }

  /// The timers are cancelled BEFORE the first await, deliberately. Riverpod
  /// calls this synchronously when the container goes away and does not wait
  /// on the future, so anything past an await here outlives the disposal — and
  /// a 30-second periodic timer that outlives its container is a leak the
  /// widget tests catch and a background wakeup in the app.
  Future<void> dispose() async {
    _debounce?.cancel();
    _debounce = null;
    _timer?.cancel();
    _timer = null;
    final events = _events;
    _events = null;
    await events?.cancel();
    await _controller.close();
  }

  /// The store's own stamp shape, because everything this writes is compared
  /// as a string against something the store wrote — a deadline against a
  /// message's `updated_at`, a stale-claim cutoff against a claim's. See
  /// [MessageStore.isoStamp] for why the precision has to match.
  static String _iso(DateTime t) => MessageStore.isoStamp(t);
}

/// What a sweep decided about one candidate.
class _Decision {
  final String state;
  final String reason;
  final bool onDeadline;

  const _Decision(this.state, this.reason, {this.onDeadline = false});
}
