import 'package:flutter/material.dart';

import '../models/calendar_models.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart' show overlapLine;
import '../services/calendar/event_view.dart';
import '../services/calendar/overlaps.dart';
import '../theme/tokens.dart';
import 'event_panel.dart' show EventJoinRow;

/// The meeting an invite (or a cancellation) is about, drawn under that
/// message in the transcript.
///
/// The mail itself says what the organiser wrote when they sent it; this
/// says what the calendar says NOW — the time as it stands after any
/// update, who has answered, what it runs into — and offers the two things
/// a reader of an invite does next: join, or open the meeting beside.
///
/// Prop-only: [MeetingCardHost] resolves the event and hands it in. A lookup
/// that is blocked or unreachable draws nothing at all, because the message
/// above already says everything the mail knew and a card that said "could
/// not reach the calendar" under every invite would be noise. A lookup that
/// is gone says so in one line: the reader is looking at an invite to a
/// meeting that no longer exists, and that is worth knowing.
class MeetingCard extends StatelessWidget {
  const MeetingCard({
    super.key,
    required this.cancellation,
    required this.lookup,
    required this.zone,
    required this.now,
    required this.today,
    this.overlaps,
    required this.onOpenEvent,
    required this.onOpenLink,
    this.actions,
  });

  static const Key openEventKey = ValueKey('meeting-card-open-event');
  static const Key joinKey = ValueKey('meeting-card-join');
  static const Key tallyKey = ValueKey('meeting-card-tally');
  static const Key cancelledKey = ValueKey('meeting-card-cancelled');
  static const Key goneKey = ValueKey('meeting-card-gone');

  static const String goneText = 'This meeting is no longer on your calendar.';
  static const String goneCancelledText =
      'Cancelled · this meeting is no longer on your calendar.';

  /// Whether the MESSAGE is a cancellation (`isCancellationCard`). A
  /// cancellation card is one line whatever the calendar says.
  final bool cancellation;

  /// Never null: the host draws nothing while the read is in flight.
  final EventLookup lookup;
  final CalendarZone zone;
  final DateTime now;
  final CalendarDate today;

  /// What the shown occurrence runs into; null says nothing.
  final Overlaps? overlaps;

  /// Opens the event panel, with the LOOKED-UP id — the master's for a
  /// series, since the panel does its own occurrence pick.
  final void Function(String eventId) onOpenEvent;
  final void Function(String url) onOpenLink;

  /// Accept / Maybe / Decline — a later phase's. Drawn under the tally only
  /// when given.
  final Widget? actions;

  static final TextStyle _muted =
      BondType.small.copyWith(color: BondColors.inkMuted);

  static String _subject(CalendarEvent e) =>
      e.subject.trim().isEmpty ? '(no subject)' : e.subject.trim();

  @override
  Widget build(BuildContext context) {
    switch (lookup.state) {
      case EventLookupState.blocked:
      case EventLookupState.unreachable:
        return const SizedBox.shrink();
      case EventLookupState.gone:
        return Text(
          cancellation ? goneCancelledText : goneText,
          key: goneKey,
          style: _muted,
        );
      case EventLookupState.found:
        final event = lookup.event;
        if (event == null) return const SizedBox.shrink();
        return _found(event);
    }
  }

  Widget _found(CalendarEvent event) {
    final shown =
        displayOccurrence(event, lookup.occurrences, now.toUtc(), zone);
    final when = eventWhenLine(shown, zone: zone, today: today);
    if (cancellation || shown.isCancelled) {
      return Text(
        'Cancelled: ${_subject(shown)}${when.isEmpty ? '' : ' · $when'}',
        key: cancelledKey,
        style: _muted,
      );
    }
    final series = isSeriesEvent(event) || isSeriesEvent(shown);
    final overlap = overlaps == null ? null : overlapLine(overlaps!);
    final tally = attendeeTally(shown);
    return Container(
      padding: const EdgeInsets.all(BondSpacing.s12),
      decoration: BoxDecoration(
        color: BondColors.surface,
        border: Border.all(color: BondColors.border),
        borderRadius: BondRadii.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.event_outlined,
                size: 16,
                color: BondColors.inkSecondary,
              ),
              const SizedBox(width: BondSpacing.s8),
              Flexible(
                child: Text(
                  '${_subject(shown)}${series ? ' · series' : ''}',
                  style: BondType.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (when.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(when, style: BondType.small),
          ],
          if (overlap != null)
            Text(
              overlap,
              style: BondType.caption.copyWith(color: BondColors.attention),
            ),
          if (tally != null) Text(tally, key: tallyKey, style: _muted),
          if (actions != null) ...[
            const SizedBox(height: BondSpacing.s8),
            actions!,
          ],
          const SizedBox(height: BondSpacing.s8),
          EventJoinRow(
            event: shown,
            now: now,
            zone: zone,
            joinKey: joinKey,
            onOpenLink: onOpenLink,
            trailing: [
              TextButton(
                key: openEventKey,
                onPressed: () => onOpenEvent(event.id),
                child: const Text('Open event'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
