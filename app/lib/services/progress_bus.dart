import 'package:flutter/foundation.dart' show immutable;

import 'event_bus.dart';

/// One stage write, as it happened.
///
/// Keys and a stage, deliberately — not a row. Every stage write sits on a
/// path the pipeline runs per message, and a `RETURNING *` on each of them
/// would buy the screen data it can batch-read for itself the moment the
/// burst settles. A listener collects the keys it saw, reads
/// `MessageStore.progressPatchFor` once, and patches.
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
/// An [EventBus] of [ProgressTick] and nothing else: the rule the publish
/// happens under, the disabled twin and the broadcast stream are all that
/// class's, and they are documented there. What is specific to progress is the
/// name of the stream — [ticks] — which eleven call sites and every test read,
/// and which is why this is a subclass rather than a bare alias.
class ProgressBus extends EventBus<ProgressTick> {
  ProgressBus();

  /// A bus that drops everything.
  const ProgressBus.disabled() : super.disabled();

  /// Broadcast, so the home screen and anything else that ever wants these
  /// are independent subscribers — and so a listener attaching late misses
  /// nothing it cannot re-read from `message_progress`.
  Stream<ProgressTick> get ticks => stream;
}
