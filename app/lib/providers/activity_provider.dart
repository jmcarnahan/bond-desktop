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
import '../utils/coalescer.dart' show coalesceLatest;
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

/// How far apart two activity ticks are, at the closest: the width of the
/// window [activityTickProvider] thins the recorder's stream to.
///
/// A quarter second because a read model a quarter second behind its event is
/// not something a person sees, and the AI lanes record one event per item,
/// several a second in a burst; every one of them used to re-run every read
/// model below.
const Duration activityTickWindow = Duration(milliseconds: 250);

/// The activity TICK for read models: a count that moves at most once per
/// [activityTickWindow], whenever the recorder wrote anything in that window.
///
/// Eleven providers re-read the store on it — the snapshot and the stamps
/// below, the cloud-draft count, the context panes, the notification and
/// pipeline reads, the Home pulse — and none of them reads a value off it: it
/// only says "something happened". Unthinned, a drain burst re-ran all of
/// them once per recorded item, which is why the window is here, on the one
/// provider they all watch, and not in each of them.
///
/// Anything that needs EVERY event listens to [ActivityLog.events] itself, as
/// the notification coordinator does; this provider drops events inside a
/// window on purpose.
///
/// A notifier holding its own subscription rather than a `StreamProvider`
/// over the thinned stream, because of when each lets go. A stream provider
/// that is disposed before its first event keeps a listener on the stream
/// until the stream ends, and the recorder's never does: a Settings pane or a
/// context pane opened and closed between two syncs would each leave a
/// thinned stream behind, arming a timer for every busy window for the rest
/// of the session. Here the subscription is cancelled as the provider is
/// disposed, and the window's timer with it.
final activityTickProvider =
    NotifierProvider.autoDispose<ActivityTick, int>(ActivityTick.new);

/// The count behind [activityTickProvider].
class ActivityTick extends AutoDisposeNotifier<int> {
  @override
  int build() {
    final ticks = coalesceLatest(
      ref.watch(activityLogProvider).events,
      activityTickWindow,
    ).listen((_) => state++);
    ref.onDispose(ticks.cancel);
    return 0;
  }
}

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
/// activity tick, and the settings screen's Sync & data section needs four
/// preference reads. Kept live the same way: watching [activityTickProvider]
/// re-reads it on the tick, at most once per [activityTickWindow], and the
/// sync passes stamp their preference before they record, so the re-read
/// always sees the new time. The reconcile
/// stamp rides along for the same reason and by the same mechanism: the mail
/// pass writes it before recording `sync_mail`.
final syncStampsProvider = FutureProvider.autoDispose<SyncStamps>((ref) async {
  ref.watch(activityTickProvider);
  final store = ref.watch(messageStoreProvider);
  return SyncStamps(
    mailIso: await store.getPref(activityLastSyncMailKey),
    teamsIso: await store.getPref(activityLastSyncTeamsKey),
    sweepIso: await store.getPref(activityLastSweepKey),
    reconcileIso: await store.getPref(mailLastReconcileKey),
  );
});

/// How many drafts have gone to a third-party target since local midnight —
/// the number beside the cap in Settings, Processing.
///
/// Here rather than beside [cloudDraftLedgerProvider] in `app_providers.dart`
/// only because this file imports that one: the live tick is
/// [activityTickProvider], which lives here, and the import the other way
/// round would be a cycle. Watching that tick is the whole liveness
/// mechanism, exactly as it is for the three providers above — the draft
/// handler records a row, and the line moves.
final cloudDraftsTodayProvider = FutureProvider.autoDispose<int>((ref) {
  ref.watch(activityTickProvider);
  return ref.watch(cloudDraftLedgerProvider).usedToday();
});

/// The activity pane's read model, re-read on the activity tick.
///
/// Watching [activityTickProvider] is what keeps it live: each tick is a new
/// value, which recomputes this, at most once per [activityTickWindow] however
/// fast the drains record. Riverpod carries the previous snapshot through the
/// reload, so the table does not blink between a tick and its re-read.
final activitySnapshotProvider =
    FutureProvider.autoDispose<ActivitySnapshot>((ref) async {
  ref.watch(activityTickProvider);
  final store = ref.watch(messageStoreProvider);

  final sinceIso = DateTime.now()
      .toUtc()
      .subtract(const Duration(days: 7))
      .toIso8601String();

  // One read for every subject the rows might name, rather than a lookup per
  // row: the panel can ask about three hundred events, and a query behind each
  // one would be three hundred round trips per tick. And a narrow two-column
  // read rather than the inbox's list query, which would count unread mail,
  // busy work, attachments and drafts per thread only for this to keep the
  // subject.
  final subjects = await store.conversationSubjects(sources: inboxSources);

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
