import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/message_store.dart';
import '../models/message_models.dart' show CtaUrgency;
import '../services/notification_coordinator.dart';
import '../services/notify/desktop_notification_service.dart';
import '../services/notify/settled_event.dart';
import 'activity_provider.dart';
import 'app_providers.dart';
import 'prefs_provider.dart';

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

/// What the ribbon is saying, if anything.
///
/// [items] is what this batch has collected, newest LAST and capped at
/// [NotificationRibbonNotifier.retained] — while [total] counts every distinct
/// thread the batch has seen, so the copy can honestly say "8 messages need
/// you" off five retained events.
///
/// [visible] and the items are deliberately independent: the ribbon animates
/// out, and a widget that lost its text the moment it was dismissed would
/// collapse to an empty banner on the way off screen.
@immutable
class RibbonState {
  final List<MessageSettled> items;
  final int total;
  final bool visible;

  const RibbonState({
    this.items = const [],
    this.total = 0,
    this.visible = false,
  });

  /// Nothing has settled yet. What the notifier starts on and what a batch
  /// never returns to — a hidden ribbon keeps its last contents.
  static const RibbonState empty = RibbonState();

  /// Whether anything in the batch is the loud kind. The surface maps this to
  /// its own severity vocabulary; mirrors `ConversationRow._dotTone`, where
  /// urgent is the only urgency that changes the tone.
  bool get anyUrgent =>
      items.any((item) => item.ctaUrgency == CtaUrgency.urgent);

  /// What to say. One settle is named after the message; several are named
  /// after their number, and after the storyline when there is exactly one
  /// between them — "3 messages in Website redesign" is a place to go, while
  /// "3 messages need you" is only a count.
  String get text {
    if (items.isEmpty) return '';
    if (total <= 1 && items.length == 1) {
      final item = items.single;
      final lead = _nonEmpty(item.title) ??
          _nonEmpty(item.ctaText) ??
          'A message needs you';
      final storyline = _nonEmpty(item.storylineTitle);
      return storyline == null ? lead : '$lead · in $storyline';
    }
    final shared = _sharedStorylineTitle;
    return shared == null
        ? '$total messages need you'
        : '$total messages in $shared';
  }

  /// The storyline every RETAINED item is in, or null. Read off the retained
  /// items rather than the full batch because the evicted ones are gone — an
  /// accepted imprecision, and only past five threads at once.
  String? get _sharedStorylineTitle {
    if (items.isEmpty) return null;
    final id = items.first.storylineId;
    if (id == null || id.isEmpty) return null;
    for (final item in items) {
      if (item.storylineId != id) return null;
    }
    return _nonEmpty(items.first.storylineTitle);
  }

  /// An empty string carries no more than a null does, and the fallbacks above
  /// have to fall through both.
  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}

/// Turns the settle stream into the one thing on screen that announces it.
///
/// Coalescing is the whole job: three messages landing at once are one thing
/// that happened, and a ribbon per settle would be a stack of banners over the
/// mail. The batch is keyed by [MessageSettled.key], so a thread that settles
/// twice replaces itself rather than counting twice.
class NotificationRibbonNotifier extends StateNotifier<RibbonState> {
  /// How long the ribbon stays after the last settle. Long enough to read a
  /// line and reach for it, short enough not to sit over the inbox.
  static const Duration defaultDwell = Duration(seconds: 8);

  /// The hard ceiling from the FIRST settle of a batch. A burst arriving every
  /// few seconds would otherwise restart the dwell forever and pin the ribbon
  /// on screen for as long as the mail kept coming.
  static const Duration defaultMaxDwell = Duration(seconds: 20);

  /// How many settles the batch keeps. Past this the copy is a count anyway,
  /// and the routing has already given up on picking a thread.
  static const int retained = 5;

  final bool Function() _enabled;
  final Duration _dwell;
  final Duration _maxDwell;

  /// Insertion-ordered so [RibbonState.items] reads oldest first; a re-settle
  /// on an existing key overwrites in place and does not reorder.
  final LinkedHashMap<String, MessageSettled> _batch =
      LinkedHashMap<String, MessageSettled>();

  /// Every distinct key this batch has seen, including the ones evicted from
  /// [_batch]. This is what [RibbonState.total] counts.
  final Set<String> _seen = <String>{};

  StreamSubscription<MessageSettled>? _events;
  Timer? _dwellTimer;
  Timer? _ceilingTimer;

  NotificationRibbonNotifier({
    required Stream<MessageSettled> events,
    required bool Function() enabled,
    Duration dwell = defaultDwell,
    Duration maxDwell = defaultMaxDwell,
  })  : _enabled = enabled,
        _dwell = dwell,
        _maxDwell = maxDwell,
        super(RibbonState.empty) {
    _events = events.listen(_add);
  }

  void _add(MessageSettled event) {
    if (!mounted) return;
    // Dropped, not queued. Turning the ribbon back on is not a request to be
    // told about the settles that happened while it was off.
    if (!_enabled()) return;

    if (!state.visible) {
      // First settle of a batch — the previous one's contents are still in
      // state for its exit animation, but they are not this batch's.
      _batch.clear();
      _seen.clear();
      _ceilingTimer?.cancel();
      _ceilingTimer = Timer(_maxDwell, _hide);
    }

    _batch[event.key] = event;
    _seen.add(event.key);
    while (_batch.length > retained) {
      _batch.remove(_batch.keys.first);
    }

    _dwellTimer?.cancel();
    _dwellTimer = Timer(_dwell, _hide);

    state = RibbonState(
      items: List<MessageSettled>.unmodifiable(_batch.values),
      total: _seen.length,
      visible: true,
    );
  }

  /// Takes the ribbon off screen and keeps what it said. Both the close button
  /// and a click through to the thread end here, as do both timers.
  void dismiss() => _hide();

  void _hide() {
    _dwellTimer?.cancel();
    _dwellTimer = null;
    _ceilingTimer?.cancel();
    _ceilingTimer = null;
    if (!mounted || !state.visible) return;
    state = RibbonState(
      items: state.items,
      total: state.total,
      visible: false,
    );
  }

  /// Both timers and the subscription go BEFORE `super.dispose()` and before
  /// any await: Riverpod disposes synchronously and drops whatever a disposal
  /// returns, so anything past an await here would outlive the container and
  /// fail every widget test in the suite on a leaked timer.
  @override
  void dispose() {
    _dwellTimer?.cancel();
    _ceilingTimer?.cancel();
    _events?.cancel();
    super.dispose();
  }
}

/// The ribbon, wired to the one settle seam.
///
/// [NotificationRibbonNotifier._enabled] READS the preference rather than
/// watching it: a watch would rebuild this provider when the switch moved,
/// discarding a batch mid-dwell — and the preference is about whether the next
/// settle speaks up, not about what is already on screen.
final notificationRibbonProvider =
    StateNotifierProvider<NotificationRibbonNotifier, RibbonState>(
  (ref) => NotificationRibbonNotifier(
    events: ref.watch(settledEventsProvider),
    enabled: () => ref.read(appPrefsProvider).notifyRibbon,
  ),
);

/// The OS notification dispatcher, wired to the same settle seam as the ribbon.
///
/// [DesktopNotificationService._enabled] READS the preference for the same
/// reason the ribbon's does: a watch would rebuild this provider when the
/// setting moved, tearing the service down mid-window and losing a batch that
/// was about to be posted. Only [NotifyStyle.native] gets this far — the other
/// two styles are the ribbon's business and never reach the operating system.
final desktopNotificationServiceProvider =
    Provider<DesktopNotificationService>((ref) {
  final service = DesktopNotificationService(
    events: ref.watch(settledEventsProvider),
    notifier: ref.watch(desktopNotifierProvider),
    enabled: () => ref.read(appPrefsProvider).notifyStyle == NotifyStyle.native,
  );
  ref.onDispose(service.dispose);
  return service;
});
