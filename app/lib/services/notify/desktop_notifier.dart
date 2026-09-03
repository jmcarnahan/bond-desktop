import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// Where a tapped OS notification is asking the app to go.
///
/// It is the whole of what survives a trip through the operating system: a
/// toast hands back one string and nothing else, so everything the app needs to
/// act on the tap has to fit in here and come back out intact. That is why it
/// carries [source] alongside [conversationKey] — a conversation key is unique
/// within a connector and not across them — and why the shape is versioned: a
/// notification posted by yesterday's build can still be sitting in Notification
/// Centre when today's build reads it.
@immutable
class NotificationTarget {
  final String source;
  final String conversationKey;

  /// The storyline the thread was in when it settled, when that was known.
  /// Context, not the destination — see `intentForTarget`.
  final String? storylineId;

  /// How many distinct threads this one notification stands for, at least one.
  /// Above one the payload's thread is only the newest of a pile, and the tap
  /// goes to the section rather than to it.
  final int count;

  const NotificationTarget({
    required this.source,
    required this.conversationKey,
    this.storylineId,
    this.count = 1,
  });

  /// The version this build writes and the only one [decode] accepts. A payload
  /// stamped with anything else came from a build that meant something else by
  /// these fields, and guessing at it would navigate somewhere nobody asked
  /// for.
  static const int version = 1;

  String encode() => jsonEncode({
        'v': version,
        'source': source,
        'conversationKey': conversationKey,
        'storylineId': storylineId,
        'count': count,
      });

  /// The payload as this app wrote it, or null for anything else.
  ///
  /// Every failure is the same answer — null — and the caller's response to it
  /// is to do nothing at all. A tap the app cannot read is a tap it must not
  /// act on: the alternative is navigating somewhere on the strength of a
  /// string that some other program put in the notification centre.
  static NotificationTarget? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    final Object? raw;
    try {
      raw = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (raw is! Map) return null;
    if (raw['v'] != version) return null;
    final source = raw['source'];
    final conversationKey = raw['conversationKey'];
    if (source is! String || source.isEmpty) return null;
    if (conversationKey is! String || conversationKey.isEmpty) return null;
    final count = raw['count'];
    if (count is! int) return null;
    final storylineId = raw['storylineId'];
    return NotificationTarget(
      source: source,
      conversationKey: conversationKey,
      storylineId: storylineId is String ? storylineId : null,
      count: count,
    );
  }
}

/// One toast, already written. The composing is the dispatcher's job; by the
/// time it reaches a [DesktopNotifier] there is nothing left to decide.
@immutable
class DesktopNotification {
  final String title;
  final String body;
  final NotificationTarget target;

  const DesktopNotification({
    required this.title,
    required this.body,
    required this.target,
  });
}

/// The seam between the app and the operating system's notification centre.
///
/// Everything above this line is pure Dart and testable; everything below it is
/// a plugin's problem. The app holds this interface and never the plugin, which
/// is what keeps the OS out of the test suite entirely.
abstract class DesktopNotifier {
  /// Whether this platform can post a notification at all. False makes the
  /// other two members no-ops rather than errors.
  bool get supported;

  /// Asks the OS for permission, once the app actually has something to say.
  /// False for every reason there is — unsupported, denied, or a platform that
  /// threw — because the caller's answer to all of them is the same: stay
  /// quiet.
  Future<bool> ensureAuthorized();

  Future<void> show(DesktopNotification notification);
}

/// A notifier for a platform that has no notification centre this app can
/// reach.
///
/// Degradation is a class rather than a branch: the callers ask a
/// [DesktopNotifier] to do something and it either does or does not, and there
/// is no `if (Platform...)` anywhere above this file deciding which.
class NoopDesktopNotifier implements DesktopNotifier {
  const NoopDesktopNotifier();

  @override
  bool get supported => false;

  @override
  Future<bool> ensureAuthorized() async => false;

  @override
  Future<void> show(DesktopNotification notification) async {}
}
