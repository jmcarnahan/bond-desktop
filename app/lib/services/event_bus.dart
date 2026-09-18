import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// A broadcast announcement channel with one rule, and a disabled twin that
/// costs nothing.
///
/// Two buses in this app wanted the same eight lines — the pipeline's stage
/// ticks and a draft's streamed text — so the lines live here once and each
/// bus is the event type it carries. [ProgressBus] extends it;
/// [DraftStreamBus] is an alias of it.
///
/// [EventBus.disabled] is the default every instrumented constructor takes, so
/// a test that builds a queue or a handler without caring about the screen
/// keeps compiling and keeps costing nothing.
class EventBus<T> {
  final StreamController<T>? _events;

  EventBus() : _events = StreamController<T>.broadcast();

  /// A bus that drops everything.
  const EventBus.disabled() : _events = null;

  /// Broadcast, so two screens watching the same thing are independent
  /// subscribers — and so a listener attaching late misses nothing it cannot
  /// re-read from the database underneath.
  ///
  /// Not `const Stream<T>.empty()`: a const expression may not use a type
  /// parameter, so the disabled bus builds its empty stream per read.
  Stream<T> get stream => _events?.stream ?? Stream<T>.empty();

  /// False on [EventBus.disabled]. Lets a producer skip work nobody will ever
  /// see — assembling an event is sometimes more expensive than dropping it.
  bool get enabled => _events != null;

  /// The rule this class exists under, the one [ActivityLog] documents at
  /// length: **the observer must never be able to break the thing it
  /// observes.** This does not throw, does not await, and does not care
  /// whether anybody is listening — an announcement that failed is a bar that
  /// fills a moment late, which is not worth a message.
  void publish(T event) {
    final events = _events;
    if (events == null || events.isClosed) return;
    try {
      events.add(event);
    } catch (e) {
      debugPrint('EventBus: dropped $event: $e');
    }
  }

  void dispose() {
    _events?.close();
  }
}
