import 'package:flutter/material.dart';

import '../models/calendar_models.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/event_view.dart';
import '../theme/tokens.dart';

/// The line at the top of a person's room: the next meeting with them and
/// when the reader last met them — "Next meeting: Design review · Tomorrow
/// 10:00 AM · Last met 12 days ago".
///
/// The two facts a reader walking into a room most often wants from the
/// calendar, and each is a link: a tap opens that meeting beside the room.
/// Prop-only; the host reads [PersonMeetings] and hands it in. Nothing to
/// say draws nothing, so a person the reader has never met with costs the
/// room no line.
class PersonMeetingLine extends StatelessWidget {
  const PersonMeetingLine({
    super.key,
    required this.meetings,
    required this.zone,
    required this.today,
    required this.onOpenEvent,
  });

  static const Key nextKey = ValueKey('person-meeting-next');
  static const Key lastKey = ValueKey('person-meeting-last');

  final PersonMeetings meetings;
  final CalendarZone zone;
  final CalendarDate today;
  final void Function(String eventId) onOpenEvent;

  @override
  Widget build(BuildContext context) {
    final next = meetings.next;
    final last = meetings.last;
    if (next == null && last == null) return const SizedBox.shrink();
    final parts = <Widget>[
      if (next != null)
        _link(
          nextKey,
          nextMeetingLabel(next, zone: zone, today: today),
          () => onOpenEvent(next.id),
        ),
      if (last != null)
        _link(
          lastKey,
          lastMetLabel(last, zone: zone, today: today),
          () => onOpenEvent(last.id),
        ),
    ];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0)
            Text(
              ' · ',
              style: BondType.caption.copyWith(color: BondColors.inkMuted),
            ),
          parts[i],
        ],
      ],
    );
  }

  Widget _link(Key key, String text, VoidCallback onTap) => Material(
        color: Colors.transparent,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BondRadii.smAll,
          child: Text(
            text,
            style: BondType.caption.copyWith(color: BondColors.primary),
          ),
        ),
      );
}
