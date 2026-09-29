import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message_models.dart' show Message;
import '../providers/app_providers.dart' show calendarZoneProvider;
import '../providers/day_providers.dart' show dayEventsProvider;
import '../providers/event_providers.dart' show eventByIdProvider;
import '../services/calendar/event_view.dart';
import '../services/calendar/overlaps.dart';
import 'meeting_card.dart';

/// Resolves the meeting one invite message names and draws its
/// [MeetingCard].
///
/// A [ConsumerWidget] in `widgets/` for `MessageHistoryHost`'s reason: the
/// transcript that places it is prop-only and knows nothing about
/// calendars, so the reads live in the one widget that needs them.
///
/// Draws nothing until it has something honest to say — no event id, the
/// read still in flight, no zone yet — so a transcript never flickers a
/// half-built card under an invite. "Now" and "today" are read HERE on
/// every build and never inside a provider (`day_providers.dart`'s rule).
class MeetingCardHost extends ConsumerWidget {
  const MeetingCardHost({
    super.key,
    required this.message,
    required this.onOpenEvent,
    required this.onOpenLink,
  });

  final Message message;
  final void Function(String eventId) onOpenEvent;
  final void Function(String url) onOpenLink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = message.meetingEventId;
    if (id == null || id.trim().isEmpty) return const SizedBox.shrink();
    final lookup = ref.watch(eventByIdProvider(id)).valueOrNull;
    if (lookup == null) return const SizedBox.shrink();
    final zone = ref.watch(calendarZoneProvider).valueOrNull;
    if (zone == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = zone.dateOf(now.toUtc());
    final cancellation = isCancellationCard(message);

    Overlaps? overlaps;
    final event = lookup.event;
    if (lookup.isFound && event != null && !cancellation) {
      final shown =
          displayOccurrence(event, lookup.occurrences, now.toUtc(), zone);
      final start = shown.startUtc;
      if (shown.isTimed && !shown.isCancelled && start != null) {
        final events =
            ref.watch(dayEventsProvider(zone.dateOf(start))).valueOrNull;
        overlaps = events == null
            ? null
            : overlapsForEvent(shown, events, zone: zone);
      }
    }

    return MeetingCard(
      cancellation: cancellation,
      lookup: lookup,
      zone: zone,
      now: now,
      today: today,
      overlaps: overlaps,
      onOpenEvent: onOpenEvent,
      onOpenLink: onOpenLink,
    );
  }
}
