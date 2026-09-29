import 'package:flutter/material.dart';

import '../models/calendar_models.dart';
import '../models/message_models.dart';
import '../services/calendar/calendar_sync.dart' show CalendarAvailability;
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart';
import '../theme/tokens.dart';
import 'chips.dart';
import 'clock_tick.dart';

/// Which of the Day stop's two lists the pane is showing.
enum DayPaneMode { agenda, invites }

/// The Day stop's main pane: one day's agenda, or the invites still owed an
/// answer.
///
/// Prop-only: the screen reads the mirror through the day providers and hands
/// the rows in, so this pane is a function of its arguments and a test can
/// pin `now` and the zone. The merge itself is [buildDayItems]'s; this only
/// draws it.
///
/// Subjects and locations are the ORGANISER's text and arrive untrusted, so
/// they are plain [Text] — never a link, never markup. The one link on a row
/// is the join URL, behind a button, through [onOpenLink] and the screen's
/// guarded launcher.
///
/// Meeting, all-day and invite rows open the event panel beside the pane
/// through [onOpenEvent]. Without it they stay inert — no ink, no hover —
/// because a row that reacted to a tap by doing nothing would be a row that
/// looked broken.
class DayPane extends StatelessWidget {
  const DayPane({
    super.key,
    required this.mode,
    required this.day,
    required this.today,
    required this.now,
    required this.zone,
    required this.availability,
    required this.events,
    required this.conversations,
    required this.invites,
    required this.onSelectDay,
    required this.onBackToDay,
    required this.onOpenConversation,
    required this.onOpenLink,
    required this.onOpenSettings,
    this.onOpenEvent,
  });

  /// How far back and forward the arrows go: the mirror's window. A day
  /// outside it would read as empty when it is merely not synced.
  static const int daysBack = 30;
  static const int daysForward = 120;

  /// The sentence SDK mode's backend throws, repeated here as a literal
  /// because the backend keeps its copy private.
  static const String sdkModeText =
      'The calendar needs the Bond server connection (Settings › Connection).';
  static const String scopeMissingText =
      'Calendar permission needed — Settings › Connection';
  static const String offlineText =
      "Can't reach the calendar right now — showing what was saved.";
  static const String emptyText = 'Nothing on your calendar.';
  static const String readingText = 'Reading your calendar…';
  static const String gridCaption = 'Grid arrives in a later phase';

  final DayPaneMode mode;
  final CalendarDate day;
  final CalendarDate today;
  final DateTime now;
  final CalendarZone zone;
  final CalendarAvailability availability;

  /// The day's events, or null while the read is still in flight — which
  /// draws nothing rather than a false "Nothing on your calendar".
  final List<CalendarEvent>? events;
  final List<Conversation> conversations;

  /// Already ordered: pinned first, then soonest. Null while the read is
  /// still in flight, which draws nothing — the [events] rule, so a slow read
  /// never flashes "No invites to answer." over invites that are coming.
  final List<InviteEntry>? invites;

  final void Function(CalendarDate day) onSelectDay;
  final VoidCallback onBackToDay;
  final void Function(String source, String conversationKey) onOpenConversation;
  final void Function(String url) onOpenLink;
  final VoidCallback onOpenSettings;

  /// Opens one event beside the pane, by its Graph id. Null leaves the event
  /// rows inert.
  final void Function(String eventId)? onOpenEvent;

  /// [onOpenEvent] bound to [e], or null when there is nothing to open with.
  VoidCallback? _openEvent(CalendarEvent e) {
    final open = onOpenEvent;
    return open == null ? null : () => open(e.id);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: mode == DayPaneMode.invites ? _invitesPane() : _agendaPane(),
      ),
    );
  }

  // ── agenda ───────────────────────────────────────────────────────────

  List<Widget> _agendaPane() {
    final first = today.addDays(-daysBack);
    final last = today.addDays(daysForward);
    return [
      Row(
        children: [
          Expanded(child: Text(dayTitle(day, today), style: BondType.title)),
          IconButton(
            tooltip: 'Previous day',
            icon: const Icon(Icons.chevron_left),
            onPressed:
                day.isAfter(first) ? () => onSelectDay(day.addDays(-1)) : null,
          ),
          TextButton(
            onPressed: day == today ? null : () => onSelectDay(today),
            child: const Text('Today'),
          ),
          IconButton(
            tooltip: 'Next day',
            icon: const Icon(Icons.chevron_right),
            onPressed:
                day.isBefore(last) ? () => onSelectDay(day.addDays(1)) : null,
          ),
        ],
      ),
      const SizedBox(height: BondSpacing.s8),
      _modeControl(),
      if (availability == CalendarAvailability.unavailable) ...[
        const SizedBox(height: BondSpacing.s8),
        Text(
          offlineText,
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      ],
      const SizedBox(height: BondSpacing.s16),
      Expanded(child: _agendaBody()),
    ];
  }

  /// Agenda | Grid. Only Agenda exists this phase; Grid is drawn, disabled,
  /// and says so in words next to it rather than in a tooltip alone.
  Widget _modeControl() {
    return Row(
      children: [
        const BondFilterPill(label: 'Agenda', selected: true, onTap: null),
        const SizedBox(width: BondSpacing.s8),
        const Tooltip(
          message: gridCaption,
          child: BondFilterPill(label: 'Grid', onTap: null),
        ),
        const SizedBox(width: BondSpacing.s12),
        Flexible(
          child: Text(
            gridCaption,
            style: BondType.caption.copyWith(color: BondColors.inkMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// The sentence that stands in for the list where the calendar is not this
  /// session's to show, or null where it is. Shared by both modes: the
  /// invites view has no more to say than the agenda does when there is no
  /// calendar, and "No invites to answer." there would be a false all-clear.
  Widget? _blocked() {
    if (availability == CalendarAvailability.scopeMissing) {
      return Align(
        alignment: Alignment.topLeft,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: BondSpacing.s8,
          children: [
            Text(scopeMissingText, style: _muted),
            TextButton(
              onPressed: onOpenSettings,
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    }
    if (availability == CalendarAvailability.sdkMode) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(sdkModeText, style: _muted),
      );
    }
    return null;
  }

  /// The day's rows under ONE [ClockTick]: the merge, the Now marker, every
  /// countdown and every Join button read the same tick, so the marker moves
  /// down the list and a Join button appears fifteen minutes out on a pane
  /// that nobody touches — and no two rows ever disagree about the time.
  Widget _agendaBody() {
    final blocked = _blocked();
    if (blocked != null) return blocked;
    final list = events;
    if (list == null) return const SizedBox.shrink();
    return ClockTick(
      initial: now,
      builder: (context, t) {
        final items = buildDayItems(
          day: day,
          events: list,
          conversations: conversations,
          now: t,
          zone: zone,
        );
        final hasRows = items.any((i) => i is! NowMarker);
        if (!hasRows) {
          return Align(
            alignment: Alignment.topLeft,
            child: Text(
              availability == CalendarAvailability.unknown
                  ? readingText
                  : emptyText,
              style: _muted,
            ),
          );
        }
        return ListView(
          children: [
            for (final item in items) _itemRow(item, t),
          ],
        );
      },
    );
  }

  Widget _itemRow(DayItem item, DateTime t) => switch (item) {
        MeetingItem() => _meetingRow(item, t),
        AllDayItem(:final event) => _allDayRow(event),
        DeadlineItem() => _deadlineRow(item),
        ReturnItem() => _returnRow(item),
        NowMarker() => _nowRow(),
      };

  static final TextStyle _muted =
      BondType.small.copyWith(color: BondColors.inkMuted);
  static final TextStyle _caption =
      BondType.caption.copyWith(color: BondColors.inkMuted);

  static String _subject(String s) =>
      s.trim().isEmpty ? '(no subject)' : s.trim();

  /// The fixed-width time column every row lines up on.
  Widget _when(String text) => SizedBox(
        width: 160,
        child: Text(
          text,
          style: BondType.small.copyWith(color: BondColors.inkSecondary),
          maxLines: 2,
        ),
      );

  Widget _row({required Widget when, required Widget body, VoidCallback? onTap}) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [when, const SizedBox(width: BondSpacing.s12), Expanded(child: body)],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BondRadii.smAll,
      hoverColor: BondColors.faintGround,
      child: content,
    );
  }

  /// [t] is the agenda's tick, not [now]: the countdown and the Join button
  /// follow the clock.
  Widget _meetingRow(MeetingItem item, DateTime t) {
    final e = item.event;
    final cancelled = e.isCancelled;
    final declined = e.responseStatus.trim().toLowerCase() == 'declined';
    final overlap = overlapLine(item.overlaps);
    final nowUtc = t.toUtc();
    final range = (e.startUtc != null && e.endUtc != null)
        ? formatEventRange(zone, e.startUtc!, e.endUtc!)
        : '';

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                _subject(e.subject),
                style: BondType.body.copyWith(
                  fontWeight: FontWeight.w600,
                  decoration: cancelled ? TextDecoration.lineThrough : null,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (e.joinUrl.trim().isNotEmpty) ...[
              const SizedBox(width: BondSpacing.s8),
              const Tooltip(
                message: 'Online meeting',
                child: Icon(
                  Icons.videocam_outlined,
                  size: 16,
                  color: BondColors.inkMuted,
                ),
              ),
            ],
          ],
        ),
        if (e.location.trim().isNotEmpty)
          Text(e.location.trim(), style: _muted, maxLines: 1,
              overflow: TextOverflow.ellipsis),
        if (cancelled) Text('Cancelled', style: _caption),
        if (declined) Text('Declined', style: _caption),
        if (overlap != null)
          Text(
            overlap,
            style: BondType.caption.copyWith(color: BondColors.attention),
          ),
      ],
    );

    final trailing = <Widget>[
      Text(
        meetingCountdown(e, nowUtc) ?? '',
        style: BondType.caption.copyWith(color: BondColors.primary),
      ),
      if (joinable(e, nowUtc))
        TextButton(
          onPressed: () => onOpenLink(e.joinUrl),
          child: const Text('Join'),
        ),
      if (item.needsResponse) ...[
        const SizedBox(width: BondSpacing.s8),
        const BondChip(tone: BondTone.attention, label: 'RSVP owed'),
      ],
    ];

    final row = _row(
      when: _when(range),
      onTap: _openEvent(e),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: body),
          const SizedBox(width: BondSpacing.s8),
          ...trailing,
        ],
      ),
    );
    return declined ? Opacity(opacity: 0.5, child: row) : row;
  }

  Widget _allDayRow(CalendarEvent e) {
    final start = e.startDate;
    final end = e.endDate;
    final multi = start != null && end != null && end.isAfter(start.addDays(1));
    final label =
        multi ? 'All day · until ${shortDate(end.addDays(-1))}' : 'All day';
    return _row(
      when: _when(label),
      onTap: _openEvent(e),
      body: Text(
        _subject(e.subject),
        style: BondType.body.copyWith(
          fontWeight: FontWeight.w600,
          decoration: e.isCancelled ? TextDecoration.lineThrough : null,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _deadlineRow(DeadlineItem item) {
    final c = item.conversation;
    return _row(
      when: _when('Due'),
      onTap: () => onOpenConversation(c.source, c.id),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _subject(c.subject ?? ''),
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(item.deadline, style: _muted, maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _returnRow(ReturnItem item) {
    final c = item.conversation;
    return _row(
      when: _when(formatEventTime(zone, item.atUtc)),
      onTap: () => onOpenConversation(c.source, c.id),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Back from Later', style: _caption),
          Text(
            _subject(c.subject ?? ''),
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _nowRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s4),
      child: Row(
        children: [
          Text(
            'Now',
            style: BondType.caption.copyWith(
              color: BondColors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          Expanded(child: Container(height: 1, color: BondColors.primary)),
        ],
      ),
    );
  }

  // ── invites ──────────────────────────────────────────────────────────

  List<Widget> _invitesPane() {
    return [
      Row(
        children: [
          Tooltip(
            message: 'Back to Day',
            child: TextButton(
              onPressed: onBackToDay,
              child: const Text('‹ Day'),
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          const Expanded(child: Text('Invites', style: BondType.title)),
        ],
      ),
      if (availability == CalendarAvailability.unavailable) ...[
        const SizedBox(height: BondSpacing.s8),
        Text(
          offlineText,
          style: BondType.caption.copyWith(color: BondColors.inkMuted),
        ),
      ],
      const SizedBox(height: BondSpacing.s16),
      Expanded(child: _invitesBody()),
    ];
  }

  Widget _invitesBody() {
    final blocked = _blocked();
    if (blocked != null) return blocked;
    final list = invites;
    if (list == null) return const SizedBox.shrink();
    if (list.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('No invites to answer.', style: _muted),
      );
    }
    return ListView(
      children: [for (final entry in list) _inviteRow(entry)],
    );
  }

  Widget _inviteRow(InviteEntry entry) {
    final e = entry.event;
    final date = inviteDate(e, zone);
    final dateText = date == null ? '' : shortDate(date);
    final when = e.isAllDay
        ? '$dateText · All day'
        : (e.startUtc != null && e.endUtc != null)
            ? '$dateText · ${formatEventRange(zone, e.startUtc!, e.endUtc!)}'
            : dateText;
    final from = e.organizerName.trim().isNotEmpty
        ? e.organizerName.trim()
        : e.organizerAddress.trim();
    final overlap = overlapLine(entry.overlaps);
    return _row(
      when: _when(when),
      onTap: _openEvent(e),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_subject(e.subject)}${entry.isSeries ? ' · series' : ''}',
                  style: BondType.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (from.isNotEmpty)
                  Text('from $from', style: _muted, maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                if (overlap != null)
                  Text(
                    overlap,
                    style:
                        BondType.caption.copyWith(color: BondColors.attention),
                  ),
              ],
            ),
          ),
          if (entry.pinned) ...[
            const SizedBox(width: BondSpacing.s8),
            const BondChip(tone: BondTone.error, label: 'Urgent'),
          ],
        ],
      ),
    );
  }
}
