import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;

/// One stage write, as it happened.
///
/// Keys and a stage, deliberately — not a row. Every stage write sits on a
/// path the pipeline runs per message, and a `RETURNING *` on each of them
/// would buy the screen data it can batch-read for itself the moment the
/// burst settles. A listener collects the keys it saw, reads
/// `MessageStore.progressRowsFor` once, and patches.
///
/// [receivedAt] rides along for the one decision that cannot wait for that
/// read: whether this tick is about something NEWER than what the screen is
/// showing, which is the difference between patching a visible row and
/// prepending a new one.
@immutable
class ProgressTick {
  final String source;
  final String sourceMessageId;

  /// `ingest` | `triage` | `extract` | `storyline` | `settle`.
  final String stage;

  /// What that stage moved to — `pending` | `running` | `done` | `skipped` |
  /// `error`.
  final String state;

  /// The message's own timestamp, which is also the feed's sort key.
  final String receivedAt;

  const ProgressTick({
    required this.source,
    required this.sourceMessageId,
    required this.stage,
    required this.state,
    required this.receivedAt,
  });

  @override
  String toString() =>
      'ProgressTick($source/$sourceMessageId $stage=$state @$receivedAt)';
}

/// Ticks once per stage write, so an open home screen follows the pipeline
/// without polling it.
///
/// The rule it exists under is the one [ActivityLog] documents at length:
/// **the observer must never be able to break the thing it observes.**
/// [publish] does not throw, does not await, and does not care whether
/// anybody is listening — a stage write that failed to be announced is a bar
/// that fills a moment late, which is not worth a message.
///
/// [ProgressBus.disabled] is the default every instrumented constructor takes,
/// so a test that builds a queue without caring about the screen keeps
/// compiling and keeps costing nothing.
class ProgressBus {
  final StreamController<ProgressTick>? _ticks;

  ProgressBus() : _ticks = StreamController<ProgressTick>.broadcast();

  /// A bus that drops everything.
  const ProgressBus.disabled() : _ticks = null;

  /// Broadcast, so the home screen and anything else that ever wants these
  /// are independent subscribers — and so a listener attaching late misses
  /// nothing it cannot re-read from `message_progress`.
  Stream<ProgressTick> get ticks =>
      _ticks?.stream ?? const Stream<ProgressTick>.empty();

  void publish(ProgressTick tick) {
    final ticks = _ticks;
    if (ticks == null || ticks.isClosed) return;
    try {
      ticks.add(tick);
    } catch (e) {
      debugPrint('ProgressBus: dropped $tick: $e');
    }
  }

  void dispose() {
    _ticks?.close();
  }
}
