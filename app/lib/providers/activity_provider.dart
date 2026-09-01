import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart'
    show
        activityLastSweepKey,
        activityLastSyncMailKey,
        activityLastSyncTeamsKey;
import '../models/message_models.dart';
import '../services/activity_log.dart';
import 'app_providers.dart';
import 'conversations_provider.dart' show inboxSources;

/// Everything the activity pane renders, read in one pass.
///
/// It is a snapshot rather than a set of reads the panel makes for itself
/// because the store is asynchronous: a widget build cannot await, so the
/// stats, the rows, the three freshness stamps and the subject of every row's
/// thread are gathered here and handed over whole.
@immutable
class ActivitySnapshot {
  final ActivityStats stats;

  /// Newest first, the order the store hands them over.
  final List<ActivityEvent> events;

  final String? lastMailSyncIso;
  final String? lastTeamsSyncIso;
  final String? lastSweepIso;

  /// `'$source|$conversationKey'` → the thread's subject. Only threads that
  /// have one appear; [labelFor] answers null for everything else, which is the
  /// ordinary case — triage records a MESSAGE id, which is not a conversation
  /// key.
  final Map<String, String> _subjects;

  const ActivitySnapshot({
    required this.stats,
    required this.events,
    required Map<String, String> subjects,
    this.lastMailSyncIso,
    this.lastTeamsSyncIso,
    this.lastSweepIso,
  }) : _subjects = subjects;

  String? labelFor(ActivityEvent event) {
    final entityId = event.entityId;
    if (entityId == null) return null;
    return _subjects['${event.source ?? 'email'}|$entityId'];
  }
}

/// The recorder's own stream, lifted into a provider so the snapshot below can
/// depend on it. One subscription for however many widgets watch.
final activityEventsProvider = StreamProvider.autoDispose<ActivityEvent>(
  (ref) => ref.watch(activityLogProvider).events,
);

/// The activity pane's read model, re-read on every recorded event.
///
/// Watching [activityEventsProvider] is what keeps it live: each event is a new
/// value, which recomputes this. Riverpod carries the previous snapshot through
/// the reload, so the table does not blink between an event and its re-read.
final activitySnapshotProvider =
    FutureProvider.autoDispose<ActivitySnapshot>((ref) async {
  ref.watch(activityEventsProvider);
  final store = ref.watch(messageStoreProvider);

  final sinceIso = DateTime.now()
      .toUtc()
      .subtract(const Duration(days: 7))
      .toIso8601String();

  // One list read for every subject the rows might name, rather than a lookup
  // per row: the panel can ask about three hundred events, and a query behind
  // each one would be three hundred round trips per recorded event.
  final conversations = await store.loadConversations(sources: inboxSources);
  final subjects = <String, String>{};
  for (final conversation in conversations) {
    final subject = conversation.subject;
    if (subject == null || subject.isEmpty) continue;
    subjects['${conversation.source}|${conversation.id}'] = subject;
  }

  return ActivitySnapshot(
    stats: await store.activityStats(sinceIso: sinceIso),
    events: [
      for (final row in await store.recentActivity(limit: 300))
        ActivityEvent.fromRow(row),
    ],
    subjects: subjects,
    lastMailSyncIso: await store.getPref(activityLastSyncMailKey),
    lastTeamsSyncIso: await store.getPref(activityLastSyncTeamsKey),
    lastSweepIso: await store.getPref(activityLastSweepKey),
  );
});
