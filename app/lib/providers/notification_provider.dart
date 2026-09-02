import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../services/notification_coordinator.dart';
import '../services/notify/settled_event.dart';
import 'activity_provider.dart';
import 'app_providers.dart';

/// The ONE seam every notification surface reads.
///
/// The stream is broadcast, so the in-app ribbon and the OS dispatcher are two
/// independent consumers of the same settle rather than two things deciding
/// separately whether the user has been told.
final settledEventsProvider = Provider<Stream<MessageSettled>>(
  (ref) => ref.watch(notificationCoordinatorProvider).notifications,
);

/// What was announced in the last [NotificationCoordinator.recencyWindow] —
/// the backing read for "what did I miss", newest first.
///
/// Watching [activityEventsProvider] is what keeps it live, the same trick
/// [activitySnapshotProvider] plays: a settle follows pipeline activity, so
/// re-reading on every recorded event costs one query and needs no timer.
final recentNotificationsProvider =
    FutureProvider.autoDispose<List<Map<String, Object?>>>((ref) async {
  ref.watch(activityEventsProvider);
  final store = ref.watch(messageStoreProvider);
  final since = DateTime.now()
      .toUtc()
      .subtract(NotificationCoordinator.recencyWindow)
      .toIso8601String();
  return store.recentNotified(sinceIso: since, limit: 20);
});

/// Both queues' standing, re-read on every recorded event. The activity panel
/// reads it for one number: how much work has been given up on, which is the
/// only pipeline fact the counters above it cannot show.
final pipelineHealthProvider =
    FutureProvider.autoDispose<PipelineHealth>((ref) async {
  ref.watch(activityEventsProvider);
  return ref.watch(messageStoreProvider).pipelineHealth();
});
