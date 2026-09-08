import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart'
    show
        activityLastSweepKey,
        activityLastSyncMailKey,
        activityLastSyncTeamsKey;
import '../models/message_models.dart';
import '../services/activity_log.dart';
import '../services/sync_service.dart' show mailLastReconcileKey;
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
    required this._subjects,
    this.lastMailSyncIso,
    this.lastTeamsSyncIso,
    this.lastSweepIso,
  });

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

/// When each pass last completed, and nothing else.
@immutable
class SyncStamps {
  final String? mailIso;
  final String? teamsIso;
  final String? sweepIso;

  /// When the mail reconcile last finished. Its own stamp rather than a fact
  /// derived from [mailIso], because it runs on a cadence of its own: a mail
  /// sync a minute old sits beside a reconcile up to ten minutes old, and a
  /// reader checking whether the safety net is alive needs the second number.
  final String? reconcileIso;

  const SyncStamps({
    this.mailIso,
    this.teamsIso,
    this.sweepIso,
    this.reconcileIso,
  });
}

/// The four freshness stamps alone, for anything that only wants to say
/// "when did this last run".
///
/// Split from [activitySnapshotProvider] because that one pays for the whole
/// pane — three hundred events and every conversation subject — on every
/// recorded event, and the settings screen's Sync & data section needs three
/// preference reads. Kept live the same way: watching [activityEventsProvider]
/// re-reads it after every event, and the sync passes stamp their preference
/// before they record, so the re-read always sees the new time. The reconcile
/// stamp rides along for the same reason and by the same mechanism: the mail
/// pass writes it before recording `sync_mail`.
final syncStampsProvider = FutureProvider.autoDispose<SyncStamps>((ref) async {
  ref.watch(activityEventsProvider);
  final store = ref.watch(messageStoreProvider);
  return SyncStamps(
    mailIso: await store.getPref(activityLastSyncMailKey),
    teamsIso: await store.getPref(activityLastSyncTeamsKey),
    sweepIso: await store.getPref(activityLastSweepKey),
    reconcileIso: await store.getPref(mailLastReconcileKey),
  );
});

/// Needs-you judgements still queued, re-read on every recorded event so the
/// Settings summary counts down as the re-judge the owner started drains.
///
/// Watching [activityEventsProvider] is the whole liveness mechanism, the same
/// one [syncStampsProvider] uses: every stage that finishes records something,
/// so the number moves without a timer of its own.
final needsYouPendingProvider = FutureProvider.autoDispose<int>((ref) async {
  ref.watch(activityEventsProvider);
  final store = ref.watch(messageStoreProvider);
  final counts = await store.workCounts('needs_you', sources: inboxSources);
  // Both statuses, because a claimed item is still an answer the owner is
  // waiting for — a countdown that skipped the one being worked on would sit
  // at "1 message" and then jump to nothing.
  return (counts['pending'] ?? 0) + (counts['processing'] ?? 0);
});

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
