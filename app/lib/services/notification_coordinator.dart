import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../data/message_store.dart';
import '../models/message_models.dart';
import 'activity_log.dart';
import 'attention.dart';
import 'notify/settled_event.dart';

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
  static const Set<String> _pipelineKinds = {'triage', 'extract', 'storyline'};

  final MessageStore _store;
  final ActivityLog _log;
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
  })  : _log = activityLog ?? ActivityLog.disabled(),
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
      final decision = _decide(row, threshold: threshold, nowIso: nowIso);
      if (decision == null) continue;
      final source = row['source'] as String? ?? '';
      final id = row['source_message_id'] as String? ?? '';
      try {
        final settled = await _store.settleNotify(
          source,
          id,
          state: decision.state,
          reason: decision.reason,
        );
        if (!settled) continue;
        if (decision.state != 'notified') continue;
        await _emit(row, decision);
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
      return _worthy(row, threshold: threshold)
          ? const _Decision('notified', 'settled')
          : const _Decision('suppressed', 'not_worthy');
    }
    final deadline = row['deadline_at'] as String? ?? '';
    if (deadline.compareTo(nowIso) <= 0) {
      return _worthy(row, threshold: threshold)
          ? const _Decision('notified', 'deadline', onDeadline: true)
          : const _Decision('suppressed', 'deadline', onDeadline: true);
    }
    return null;
  }

  /// Whether every pass that could still change the verdict has finished.
  ///
  /// An ABSENT work row counts as terminal: never-queued is a real end state —
  /// a message the extractor was never going to look at is not one to wait on.
  bool _isComplete(Map<String, Object?> row) {
    const terminal = {'triaged', 'error', 'skipped'};
    if (!terminal.contains(row['triage_status'])) return false;
    if (_int(row['extract_open']) != 0) return false;
    if (_int(row['storyline_open']) != 0) return false;
    if (row['attention_score'] == null) return false;
    final aiAt = row['ai_updated_at'] as String?;
    final msgAt = row['message_updated_at'] as String? ?? '';
    // Both are ISO-8601 UTC, which sorts lexicographically. A score stamped
    // before the message last changed is a verdict about an older version of
    // it, and waiting for the restamp is the whole point of the deadline.
    if (aiAt == null || aiAt.compareTo(msgAt) < 0) return false;
    return true;
  }

  /// Whether this is worth interrupting for: a message-level ask AND a
  /// thread-level volume, never one of the two.
  ///
  /// BOTH halves are required, and they answer different questions. The ask
  /// says the message wants something from the reader. The volume says the
  /// user wants to hear about this thread at all — the attention threshold and
  /// the `later` bucket are their ONE loudness control, and an ask that
  /// bypassed them would take the control away exactly when it matters.
  /// Volume alone is worse still: a high score is a ranking, not a request, so
  /// firing on it would announce every unread message of every decent thread
  /// and invert the app into the notification stream it exists to replace.
  /// Either half alone is a notification the user did not sign up for.
  ///
  /// `== 1` comparisons only, never truthiness: `reply_expected` NULL means
  /// "no v2 pass has judged this", which is not a "no". Reading NULL as 0
  /// would turn every un-judged message into a decided negative.
  ///
  /// Every ask below is the message's own except `cta_text`, which lives on the
  /// CONVERSATION and belongs to whichever message was triaged into it last.
  /// The thread's CTA therefore testifies for this message only when this
  /// message's own triage wrote it: `triaged` is the one status whose pass
  /// rewrote the conversation's CTA fields. Counted for a candidate still
  /// `pending` at its deadline, or one whose triage ended in `error`, it is
  /// another message's ask — and the toast that followed named THIS message
  /// while quoting THAT one.
  bool _worthy(Map<String, Object?> row, {required double threshold}) {
    final ask = _int(row['reply_expected']) == 1 ||
        _int(row['needs_action']) == 1 ||
        row['urgency'] == 'urgent' ||
        row['urgency'] == 'high' ||
        (row['deadline'] as String? ?? '').isNotEmpty ||
        (_ownsCta(row) && (row['cta_text'] as String? ?? '').isNotEmpty);
    // Unread is already guaranteed — a read message never reaches here.
    final score = (row['attention_score'] as num?)?.toDouble() ?? 0;
    return ask &&
        row['conversation_state'] != 'done' &&
        row['bucket'] != 'later' &&
        score >= threshold;
  }

  /// Whether the conversation's CTA fields are this message's own words.
  ///
  /// They describe the newest TRIAGED message of the thread, so only a
  /// candidate whose own triage finished may be judged — or quoted — by them.
  static bool _ownsCta(Map<String, Object?> row) =>
      row['triage_status'] == 'triaged';

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
    final ownsCta = _ownsCta(row);
    if (_controller.isClosed) return;
    _controller.add(
      MessageSettled(
        source: source,
        sourceMessageId: row['source_message_id'] as String? ?? '',
        conversationKey: conversationKey,
        title: row['subject'] as String? ?? row['from_name'] as String?,
        summary: row['summary'] as String?,
        ctaText: ownsCta ? row['cta_text'] as String? : null,
        ctaUrgency:
            CtaUrgency.fromWire(ownsCta ? row['cta_urgency'] as String? : null),
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

  static int? _int(Object? value) => (value as num?)?.toInt();

  /// The clock already yields UTC, so this is the store's timestamp format.
  static String _iso(DateTime t) => t.toIso8601String();
}

/// What a sweep decided about one candidate.
class _Decision {
  final String state;
  final String reason;
  final bool onDeadline;

  const _Decision(this.state, this.reason, {this.onDeadline = false});
}
