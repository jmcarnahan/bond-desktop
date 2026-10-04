import 'package:flutter/material.dart';

import '../models/calendar_models.dart';
import '../models/message_models.dart';
import '../models/reminder_models.dart';
import '../services/calendar/calendar_sync.dart' show CalendarAvailability;
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart';
import '../services/calendar/event_view.dart'
    show EventStanding, standingOf, standingWord;
import '../services/calendar/overlaps.dart' show Overlaps;
import '../services/calendar/write_rules.dart' show canRespond;
import '../theme/tokens.dart';
import 'brief_section.dart' show BriefSection;
import 'chips.dart';
import 'clock_tick.dart';
import 'command_plan_card.dart' show CommandPlanCard;
import 'day_grid.dart' show GridSpan;
import 'event_standing_style.dart';

/// Which of the Day stop's two lists the pane is showing.
enum DayPaneMode { agenda, invites }

/// How the day is drawn: the agenda list, or the time grid.
enum DayView { agenda, grid }

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
/// The day has two faces, Agenda and Grid ([view]); the grid itself is the
/// host's to build ([grid]), because its drops run writes and the writer is
/// the app's. The pane only places it, and says the same availability
/// sentences over it that it says over the agenda.
///
/// Every meeting row wears its standing: a 3-px bar down its left edge in
/// the standing's colour (`standingBarColor`, the grid's palette), and a
/// 'Maybe' caption for a tentative one. A meeting that overlaps another
/// carries a clash strip — '⚠ overlaps' and one chip per clashing meeting,
/// hard before soft, each opening that meeting — and, when the owner attends
/// it, the compact answer buttons, so one side can be stepped down from its
/// row.
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
    required this.view,
    required this.onViewChanged,
    required this.gridSpan,
    required this.onGridSpanChanged,
    this.grid,
    this.onOpenEvent,
    this.inviteActions,
    this.meetingActions,
    this.briefs = const {},
    this.briefsWaiting = const {},
    this.expandedBriefs = const {},
    this.onToggleBrief,
    this.briefBody,
    this.commandBar,
    this.planCard,
    this.reminders = const [],
  });

  /// The key of a meeting's agenda row.
  static Key meetingRowKeyFor(String eventId) =>
      ValueKey('day-meeting-$eventId');

  /// The key of a meeting row's standing bar.
  static Key standingBarKeyFor(String eventId) =>
      ValueKey('day-standing-$eventId');

  /// The key of a meeting row's clash strip.
  static Key clashKeyFor(String eventId) => ValueKey('day-clash-$eventId');

  /// The key of the chip on [eventId]'s clash strip that opens [otherId].
  static Key clashChipKeyFor(String eventId, String otherId) =>
      ValueKey('day-clash-$eventId-$otherId');

  /// The key of a meeting row's brief glance.
  static Key briefTeaserKeyFor(String eventId) =>
      ValueKey('day-brief-teaser-$eventId');

  /// The key of a meeting row's brief note, drawn in the glance slot while
  /// its brief waits.
  static Key briefNoteKeyFor(String eventId) =>
      ValueKey('day-brief-note-$eventId');

  /// The key of the button beside a glance that opens and closes the brief.
  static Key briefToggleKeyFor(String eventId) =>
      ValueKey('day-brief-toggle-$eventId');

  /// Where every row's subject starts: the time column and its gap, then
  /// the standing bar and its gap — a meeting row draws the bar, every other
  /// row leaves its room empty, so the subject column never steps between
  /// row types. An opened brief is drawn from here, under the subject it
  /// belongs to.
  static const double subjectIndent =
      _whenWidth + BondSpacing.s12 + _barWidth + BondSpacing.s8;
  static const double _barWidth = 3;
  static const double _whenWidth = 160;

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

  static const Key agendaKey = ValueKey('day-view-agenda');
  static const Key gridKey = ValueKey('day-view-grid');
  static const Key spanDayKey = ValueKey('day-grid-span-day');
  static const Key spanWeekKey = ValueKey('day-grid-span-week');

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

  final DayView view;
  final void Function(DayView view) onViewChanged;

  /// Day or Week, while [view] is the grid; the arrows step by it.
  final GridSpan gridSpan;
  final void Function(GridSpan span) onGridSpanChanged;

  /// The host-built grid, drawn in grid view. Null while it cannot be built
  /// yet (the read in flight), which says [readingText].
  final Widget? grid;

  /// Opens one event beside the pane, by its Graph id. Null leaves the event
  /// rows inert.
  final void Function(String eventId)? onOpenEvent;

  /// Yes / Maybe / No for one invite row, drawn under its text. The host
  /// builds it (the writes need the app's writer); null draws none. A press
  /// on a button inside the row is the button's, never the row's open.
  final Widget Function(InviteEntry entry)? inviteActions;

  /// Yes / Maybe / No / Dismiss for an UNANSWERED meeting's agenda row that
  /// has not ended, drawn under its text exactly as [inviteActions] is under
  /// an invite row — and for a meeting you attend that overlaps a busy
  /// meeting or a Maybe, so one side can be stepped down to Maybe or
  /// declined from its row (the current answer drawn as chosen; a clash
  /// with only an unanswered invite Outlook pencilled in draws none — the
  /// invite is the side to settle); the host builds it (the writes need
  /// the app's writer); null draws the 'RSVP owed' chip instead. A press
  /// inside is the button's, never the row's open.
  final Widget Function(CalendarEvent e)? meetingActions;

  /// Written briefs by event id. Each one's glance (its headline, up to three
  /// lines) is drawn muted under the meeting's subject, so the day reads at a
  /// look; model output over other people's mail, so plain text.
  final Map<String, MeetingBrief> briefs;

  /// The meetings whose brief is not written yet but is coming (the files
  /// sent ahead are still being read): each says so muted in the glance slot
  /// ([BriefSection.materialsPendingText]) with no chevron — there is nothing
  /// to open yet — until it starts, when no brief is coming any more. A
  /// written brief wins.
  final Set<String> briefsWaiting;

  /// The meetings whose brief is open under their row. The host holds it.
  final Set<String> expandedBriefs;

  /// Opens or closes one meeting's brief: the glance and the chevron beside
  /// it both ask. Null draws the glance with no toggle.
  final void Function(String eventId)? onToggleBrief;

  /// The host-built brief, drawn under an open row. The host builds it
  /// because it reads the store and opens threads and files.
  final Widget Function(String eventId)? briefBody;

  /// The host-built command bar (`DayCommandBar`), drawn under the title row
  /// in both the agenda and the grid, so a command typed over one face is
  /// still there on the other. Null draws none; the invites view has none.
  final Widget? commandBar;

  /// What the bar's last Enter produced (`CommandPlanCard`), drawn directly
  /// under the bar and above the list or the grid, where the eye already is.
  final Widget? planCard;

  /// The active To Do reminders (soonest first, as the store answers them);
  /// the merge places each on the local date of its instant, and its row
  /// opens its thread through [onOpenConversation].
  final List<Reminder> reminders;

  /// [onOpenEvent] bound to [e], or null when there is nothing to open with.
  VoidCallback? _openEvent(CalendarEvent e) {
    final open = onOpenEvent;
    return open == null ? null : () => open(e.id);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: mode == DayPaneMode.invites
              ? _invitesPane()
              : _agendaPane(constraints.maxHeight),
        ),
      ),
    );
  }

  // ── agenda ───────────────────────────────────────────────────────────

  bool get _week => view == DayView.grid && gridSpan == GridSpan.week;

  /// [height] is the pane's own, which caps the plan card.
  List<Widget> _agendaPane(double height) {
    final first = today.addDays(-daysBack);
    final last = today.addDays(daysForward);
    // A week at a time on the week grid, a day everywhere else. A step that
    // would leave the mirror's window is refused, not clamped: landing short
    // of where the arrow said would be its own surprise.
    final step = _week ? 7 : 1;
    final unit = _week ? 'week' : 'day';
    return [
      Row(
        children: [
          Expanded(child: Text(dayTitle(day, today), style: BondType.title)),
          IconButton(
            tooltip: 'Previous $unit',
            icon: const Icon(Icons.chevron_left),
            onPressed: !day.addDays(-step).isBefore(first)
                ? () => onSelectDay(day.addDays(-step))
                : null,
          ),
          TextButton(
            onPressed: day == today ? null : () => onSelectDay(today),
            child: const Text('Today'),
          ),
          IconButton(
            tooltip: 'Next $unit',
            icon: const Icon(Icons.chevron_right),
            onPressed: !day.addDays(step).isAfter(last)
                ? () => onSelectDay(day.addDays(step))
                : null,
          ),
        ],
      ),
      if (commandBar != null) ...[
        const SizedBox(height: BondSpacing.s8),
        commandBar!,
      ],
      if (planCard != null) ...[
        const SizedBox(height: BondSpacing.s8),
        // A long answer scrolls inside the card; the day stays in view.
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: CommandPlanCard.maxHeightIn(height)),
          child: planCard!,
        ),
      ],
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
      Expanded(
        child: view == DayView.grid ? _gridBody() : _agendaBody(),
      ),
    ];
  }

  /// Agenda | Grid, and beside Grid its Day | Week. The selected pill takes
  /// no tap: pressing what is already showing would only rewrite the pref.
  Widget _modeControl() {
    final grid = view == DayView.grid;
    return Row(
      children: [
        BondFilterPill(
          key: agendaKey,
          label: 'Agenda',
          selected: !grid,
          onTap: grid ? () => onViewChanged(DayView.agenda) : null,
        ),
        const SizedBox(width: BondSpacing.s8),
        BondFilterPill(
          key: gridKey,
          label: 'Grid',
          selected: grid,
          onTap: grid ? null : () => onViewChanged(DayView.grid),
        ),
        if (grid) ...[
          const SizedBox(width: BondSpacing.s24),
          BondFilterPill(
            key: spanDayKey,
            label: 'Day',
            selected: gridSpan == GridSpan.day,
            onTap: gridSpan == GridSpan.day
                ? null
                : () => onGridSpanChanged(GridSpan.day),
          ),
          const SizedBox(width: BondSpacing.s8),
          BondFilterPill(
            key: spanWeekKey,
            label: 'Week',
            selected: gridSpan == GridSpan.week,
            onTap: gridSpan == GridSpan.week
                ? null
                : () => onGridSpanChanged(GridSpan.week),
          ),
        ],
      ],
    );
  }

  /// The host's grid, under the same availability rules as the agenda: the
  /// calendar that is not this session's to show is a sentence here too.
  Widget _gridBody() {
    final blocked = _blocked();
    if (blocked != null) return blocked;
    final built = grid;
    if (built != null) return built;
    return Align(
      alignment: Alignment.topLeft,
      child: Text(readingText, style: _muted),
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
          reminders: reminders,
        );
        final hasRows = items.any((i) => i is! NowMarker);
        if (!hasRows) {
          return Align(
            alignment: Alignment.topLeft,
            child: Text(
              switch (availability) {
                CalendarAvailability.unknown => readingText,
                CalendarAvailability.unavailable => nothingSavedText,
                _ => emptyText,
              },
              style: _muted,
            ),
          );
        }
        return ListView(
          children: [for (final item in items) _itemRow(item, t)],
        );
      },
    );
  }

  Widget _itemRow(DayItem item, DateTime t) => switch (item) {
        MeetingItem() => _meetingRow(item, t),
        AllDayItem(:final event) => _allDayRow(event),
        DeadlineItem() => _deadlineRow(item),
        ReturnItem() => _returnRow(item),
        ReminderItem() => _reminderRow(item),
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
        width: _whenWidth,
        child: Text(
          text,
          style: BondType.small.copyWith(color: BondColors.inkSecondary),
          maxLines: 2,
        ),
      );

  /// [barred]: the body draws the standing bar itself (a meeting row);
  /// every other body is inset by the bar's room, so one [subjectIndent]
  /// holds for all rows.
  Widget _row({
    required Widget when,
    required Widget body,
    VoidCallback? onTap,
    bool barred = false,
  }) {
    final inset = barred
        ? body
        : Padding(
            padding: const EdgeInsets.only(left: _barWidth + BondSpacing.s8),
            child: body,
          );
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: BondSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [when, const SizedBox(width: BondSpacing.s12), Expanded(child: inset)],
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
    final standing = standingOf(e);
    final hasClash =
        item.overlaps.hard.isNotEmpty || item.overlaps.soft.isNotEmpty;
    // The clash that earns this row buttons: a real one, or a Maybe the
    // owner gave. An unanswered invite Outlook pencilled in is the side to
    // settle, and it has buttons of its own.
    final settleHere = item.overlaps.hard.isNotEmpty ||
        item.overlaps.soft
            .any((x) => standingOf(x) == EventStanding.tentative);
    final nowUtc = t.toUtc();
    final range = (e.startUtc != null && e.endUtc != null)
        ? formatEventRange(zone, e.startUtc!, e.endUtc!)
        : '';
    // A meeting the owner is not going to offers no brief.
    final brief = cancelled ? null : briefs[e.id];
    final expanded = brief != null && expandedBriefs.contains(e.id);
    // A wait the planner stops tending once the meeting starts: no brief
    // is coming, so the note goes.
    final started = e.startUtc != null && !e.startUtc!.isAfter(nowUtc);
    final note = !cancelled && !started && briefsWaiting.contains(e.id);
    final glance = brief == null || brief.headline.isEmpty
        ? null
        : _glance(e.id, brief.headline, expanded);
    // The invitation is answered where it is seen, until the meeting ends;
    // the chip is the fallback when the host gives no buttons, and all an
    // ended meeting still owed an answer shows. A hard clash, or one with a
    // Maybe, keeps the buttons on a meeting the owner attends, so one side
    // can be stepped down; an organiser's row has none (the panel has Move
    // and Cancel).
    final ended = e.endUtc != null && !e.endUtc!.isAfter(nowUtc);
    final actions =
        !ended && (item.needsResponse || (settleHere && canRespond(e)))
            ? meetingActions?.call(e)
            : null;

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
        ?glance,
        if (glance == null && note)
          Text(BriefSection.materialsPendingText,
              key: briefNoteKeyFor(e.id), style: _caption,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        if (e.location.trim().isNotEmpty)
          Text(e.location.trim(), style: _muted, maxLines: 1,
              overflow: TextOverflow.ellipsis),
        if (cancelled) Text('Cancelled', style: _caption),
        if (standing == EventStanding.tentative)
          Text(standingWord(standing), style: _caption),
        if (hasClash) _clashStrip(e, item.overlaps),
        if (actions != null) ...[
          const SizedBox(height: BondSpacing.s4),
          actions,
        ],
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
      if (item.needsResponse && actions == null) ...[
        const SizedBox(width: BondSpacing.s8),
        const BondChip(tone: BondTone.attention, label: 'RSVP owed'),
      ],
    ];

    final row = KeyedSubtree(
      key: meetingRowKeyFor(e.id),
      child: _row(
        when: _when(range),
        onTap: _openEvent(e),
        barred: true,
        // The bar is the body's left border, so it runs the body's full
        // height whatever the row grows to (glance, strip, buttons).
        body: Container(
          key: standingBarKeyFor(e.id),
          padding: const EdgeInsets.only(left: BondSpacing.s8),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                  color: standingBarColor(standing), width: _barWidth),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: body),
              const SizedBox(width: BondSpacing.s8),
              ...trailing,
            ],
          ),
        ),
      ),
    );
    final open = briefBody;
    if (glance == null || !expanded || open == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Padding(
          padding: const EdgeInsets.only(
            left: subjectIndent,
            bottom: BondSpacing.s8,
          ),
          child: open(e.id),
        ),
      ],
    );
  }

  /// A brief's glance under a meeting's subject, with the chevron that opens
  /// the rest. Both are their own tap targets inside the row, so a tap on
  /// either toggles the brief and a tap anywhere else on the row still opens
  /// the event.
  Widget _glance(String id, String headline, bool expanded) {
    final toggle = onToggleBrief;
    final text = Text(
      headline,
      key: briefTeaserKeyFor(id),
      style: _muted,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
    if (toggle == null) return text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          // A pointer shortcut only: the chevron is the one focus stop and
          // the one spoken toggle, so a keyboard walk meets it once.
          child: InkWell(
            canRequestFocus: false,
            excludeFromSemantics: true,
            onTap: () => toggle(id),
            borderRadius: BondRadii.smAll,
            child: text,
          ),
        ),
        IconButton(
          key: briefToggleKeyFor(id),
          tooltip: expanded ? 'Hide the brief' : 'Show the brief',
          icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: () => toggle(id),
        ),
      ],
    );
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

  /// The key of a reminder's row, by its id.
  static Key reminderRowKeyFor(String id) => ValueKey('day-reminder-$id');

  /// A To Do reminder: when it fires, where it lives, and its title — the
  /// app's own words, so plain text. A tap opens the thread it is about.
  Widget _reminderRow(ReminderItem item) {
    final r = item.reminder;
    return KeyedSubtree(
      key: reminderRowKeyFor(r.id),
      child: _row(
        when: _when(formatEventTime(zone, item.atUtc)),
        onTap: () => onOpenConversation(r.source, r.conversationKey),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reminder · in To Do', style: _caption),
            Text(
              _subject(r.title),
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
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

  /// '⚠ overlaps' (red for a hard clash, muted when every clash is soft) and
  /// one chip per meeting [e] runs into, hard before soft (soft muted, said
  /// 'maybe'); a chip opens that meeting beside the pane
  /// and is the chip's press, never the row's.
  Widget _clashStrip(CalendarEvent e, Overlaps o) {
    Widget chip(CalendarEvent other, {required bool soft}) {
      final open = onOpenEvent;
      final colour = soft ? BondColors.inkMuted : BondColors.inkSecondary;
      return InkWell(
        key: clashChipKeyFor(e.id, other.id),
        onTap: open == null ? null : () => open(other.id),
        borderRadius: BondRadii.fullAll,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: BondSpacing.s8, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BondRadii.fullAll,
            border: Border.all(color: soft ? BondColors.border : colour),
          ),
          child: Text(
            clashLabel(zone, other, soft: soft),
            style: BondType.caption.copyWith(color: colour),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: BondSpacing.s4),
      child: Wrap(
        key: clashKeyFor(e.id),
        spacing: BondSpacing.s8,
        runSpacing: BondSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('⚠ overlaps',
              style: BondType.caption.copyWith(
                  color: o.hard.isNotEmpty
                      ? BondColors.error
                      : BondColors.inkMuted)),
          for (final other in o.hard) chip(other, soft: false),
          for (final other in o.soft) chip(other, soft: true),
        ],
      ),
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
    final actions = inviteActions?.call(entry);
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
                if (actions != null) ...[
                  const SizedBox(height: BondSpacing.s4),
                  actions,
                ],
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
