import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show debugPrint;

import 'desktop_notifier.dart';
import 'settled_event.dart';

/// Turns the settle stream into OS notifications.
///
/// It is the second consumer of [MessageSettled] and the exact counterpart of
/// the in-app ribbon: same stream, same coalescing idea, different surface. The
/// two never coordinate, because they do not need to — macOS presents nothing
/// while the app is frontmost, which is precisely when the ribbon is the thing
/// the user can see.
class DesktopNotificationService {
  /// How long a batch collects before it is posted. Short — this is not the
  /// ribbon's dwell, it is only long enough that a sync finishing three threads
  /// at once is one toast rather than three.
  static const Duration defaultCoalesceWindow = Duration(seconds: 2);

  final DesktopNotifier _notifier;
  final bool Function() _enabled;
  final Duration _coalesceWindow;

  /// Insertion-ordered, keyed by [MessageSettled.key]: a thread that settles
  /// twice inside one window replaces itself rather than counting twice, and
  /// the newest arrival is the last value.
  final LinkedHashMap<String, MessageSettled> _batch =
      LinkedHashMap<String, MessageSettled>();

  StreamSubscription<MessageSettled>? _events;
  Timer? _timer;

  /// The one permission ask this process makes, memoized on its answer.
  ///
  /// Null until the first flush that actually has something to post: the
  /// permission dialog is a thing the user sees, and raising it at launch would
  /// ask before the app had earned the question. A DENIAL is memoized too, and
  /// deliberately not persisted — the process simply stays quiet, and the next
  /// launch asks again, which is what makes re-granting in System Settings work
  /// without a stored flag to clear.
  Future<bool>? _authorized;

  /// The tail of the posts made so far — see [_flush] for why they are a chain
  /// rather than parallel calls.
  Future<void> _posting = Future<void>.value();

  DesktopNotificationService({
    required Stream<MessageSettled> events,
    required DesktopNotifier notifier,
    required bool Function() enabled,
    Duration coalesceWindow = defaultCoalesceWindow,
  })  : _notifier = notifier,
        _enabled = enabled,
        _coalesceWindow = coalesceWindow {
    _events = events.listen(_add);
  }

  void _add(MessageSettled event) {
    // Dropped, not buffered. Turning notifications on is not a request to hear
    // about the settles that happened while they were off — the same rule the
    // ribbon's notifier follows, and the reason the opted-out user never even
    // sees the permission prompt.
    if (!_enabled()) return;

    _batch[event.key] = event;
    // The FIRST event of a batch arms the window and later ones do not restart
    // it: a steady trickle of settles must still produce a toast every couple
    // of seconds rather than one that keeps being postponed.
    _timer ??= Timer(_coalesceWindow, _flush);
  }

  void _flush() {
    _timer = null;
    final items = List<MessageSettled>.of(_batch.values);
    _batch.clear();
    if (items.isEmpty) return;
    // Chained rather than fired off, so a slow post cannot have the next window
    // overtake it and put two toasts out of order. Nothing awaits the chain, so
    // nothing would catch it either: a plugin that throws must leave the app
    // exactly as it was, not raise an unhandled async error out of a timer.
    _posting = _posting.then((_) => _post(items)).catchError(
          (Object error) => debugPrint('desktop notification failed: $error'),
        );
  }

  Future<void> _post(List<MessageSettled> items) async {
    final authorized = await (_authorized ??= _notifier.ensureAuthorized());
    if (!authorized) return;
    await _notifier.show(_compose(items));
  }

  /// One notification per flush, whatever the batch holds.
  ///
  /// A single settle is named after the message, exactly as the ribbon names
  /// it. Several become a count, because past one there is no honest headline
  /// and the body is only there to show which of them arrived last.
  DesktopNotification _compose(List<MessageSettled> items) {
    final newest = items.last;
    if (items.length == 1) {
      return DesktopNotification(
        title: newest.title ?? 'A message needs you',
        body: newest.ctaText ?? newest.summary ?? '',
        target: NotificationTarget(
          source: newest.source,
          conversationKey: newest.conversationKey,
          storylineId: newest.storylineId,
          count: 1,
        ),
      );
    }
    return DesktopNotification(
      title: '${items.length} messages need you',
      body: newest.ctaText ?? newest.title ?? '',
      target: NotificationTarget(
        // The newest thread, carried so the payload is never empty — but the
        // count above it is what the tap actually routes on.
        source: newest.source,
        conversationKey: newest.conversationKey,
        storylineId: _sharedStorylineId(items),
        count: items.length,
      ),
    );
  }

  /// The storyline every item in the batch is in, or null. A pile that does not
  /// agree on one has no storyline, and claiming the newest item's would put a
  /// storyline on a notification most of whose threads are outside it.
  static String? _sharedStorylineId(List<MessageSettled> items) {
    final id = items.first.storylineId;
    if (id == null || id.isEmpty) return null;
    for (final item in items) {
      if (item.storylineId != id) return null;
    }
    return id;
  }

  /// The timer and the subscription go FIRST, before anything else and before
  /// any await. Riverpod disposes synchronously and drops whatever a disposal
  /// returns, so a timer still armed past this point outlives the container and
  /// fails every widget test in the suite on a leaked timer — which is exactly
  /// what happened once already, to the ribbon's notifier.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(_events?.cancel());
    _events = null;
    _batch.clear();
  }
}
