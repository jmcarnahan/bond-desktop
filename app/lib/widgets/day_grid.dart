import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:kalender/kalender.dart';

import '../models/calendar_models.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart';
import '../services/calendar/event_standing.dart';
import '../services/calendar/overlaps.dart';
import '../services/calendar/write_rules.dart';
import '../theme/tokens.dart';
import 'day_pane.dart' show DayPane;
import 'event_standing_style.dart';

/// How much of the calendar the grid shows at once.
enum GridSpan { day, week }

/// A time the grid shows as a translucent, outlined, non-draggable tile:
/// where a drop's move would land while its write is in flight, or a
/// proposal (Phase 8's hook) — never something on the calendar.
///
/// Drawn beside the real tiles rather than as one of them, so a reader can
/// see what a suggested time runs into before anything is written.
@immutable
class GridProposal {
  const GridProposal({
    required this.startUtc,
    required this.endUtc,
    required this.label,
    this.subject = '',
    this.caption = '',
    this.adjustable = false,
  });

  final DateTime startUtc;
  final DateTime endUtc;

  /// What the ghost is ("Proposed", "Move here?"), drawn as its caption
  /// under [subject], or as its title when there is no subject.
  final String label;

  /// The caption under an unnamed ghost's [label] title — a drop's "Send or
  /// Cancel above", so the ghost says it is the move the confirm strip
  /// asks about. Unused when there is a [subject].
  final String caption;

  /// What is being proposed: the invite's or the blank event's name, or the
  /// moved meeting's subject. Untrusted text, drawn plain.
  final String subject;

  /// A drag or resize on it asks [DayGrid.onProposalChanged] — a standing
  /// proposal the host can re-run; never a drop's pending move.
  final bool adjustable;

  @override
  bool operator ==(Object other) =>
      other is GridProposal &&
      other.startUtc == startUtc &&
      other.endUtc == endUtc &&
      other.label == label &&
      other.subject == subject &&
      other.caption == caption &&
      other.adjustable == adjustable;

  @override
  int get hashCode =>
      Object.hash(startUtc, endUtc, label, subject, caption, adjustable);
}

/// The Day stop's grid: one day or one week of time columns, drawn by the
/// `kalender` package (pinned exactly: pre-1.0, its minors break).
///
/// Prop-only like [DayPane]'s agenda: the host reads the mirror and hands the
/// events in, so what a tile shows is always what the store says. That is
/// the whole drag rule. A drop or a resize is never applied here — the grid
/// asks [onMoveRequested] and leaves the tile where it was; the host runs the
/// write through the same preview → confirm / Undo every other move uses,
/// and only the store's answer moves the tile. A refused, failed or
/// dismissed move therefore snaps back by doing nothing at all.
///
/// Only what [canMove] allows is draggable, and only timed events: moving an
/// attendee's copy would be moving someone else's meeting, and an all-day
/// drag is out of this round.
///
/// A press on EMPTY time is a proposal too: the grid asks
/// [onCreateRequested] with the span and draws nothing for it — the host
/// decides whether it is an ask's invite or a blank event, and only the
/// store's answer, once that write goes through, puts a tile there.
///
/// Subjects are the ORGANISER's text: plain [Text], never markup.
class DayGrid extends StatefulWidget {
  const DayGrid({
    super.key,
    required this.day,
    required this.span,
    required this.events,
    required this.markers,
    this.proposal,
    this.locked = false,
    required this.zone,
    required this.clock,
    this.onOpenEvent,
    this.onOpenItem,
    this.onMoveRequested,
    this.onVisibleDayChanged,
    this.onCreateRequested,
    this.defaultCreateMinutes = 30,
    this.onProposalChanged,
    this.onProposalTapped,
    this.onRefused,
  });

  /// The day shown (day span), or any day of the week shown (week span;
  /// weeks start Monday).
  final CalendarDate day;
  final GridSpan span;

  /// Every event touching the visible range, timed and all-day.
  final List<CalendarEvent> events;

  /// Deadlines and returns for the visible days, drawn in the all-day
  /// header. Any other [DayItem] is ignored: meetings come from [events].
  final List<DayItem> markers;

  final GridProposal? proposal;

  /// Every tile locked, the movable ones included: a write is in flight or
  /// waiting on its confirm, and a second drop under that strip would be a
  /// second move of a tile whose first has not landed.
  final bool locked;

  final CalendarZone zone;

  /// The Now line and which column is "today".
  final DateTime Function() clock;

  final void Function(String eventId)? onOpenEvent;

  /// A deadline or return tile's tap.
  final void Function(DayItem item)? onOpenItem;

  /// A drop or resize on a movable tile. The grid does NOT move the tile
  /// itself; the host runs the write and the store's answer moves it. Null
  /// (a write already in flight) leaves every drop unanswered.
  final void Function(String eventId, DateTime startUtc, DateTime endUtc)?
      onMoveRequested;

  /// The person paged the grid: the first day now showing.
  final void Function(CalendarDate firstVisibleDay)? onVisibleDayChanged;

  /// A drag over empty time in the body (the span it covered), or a bare
  /// tap there ([defaultCreateMinutes] from the quarter hour tapped). The
  /// grid adds no tile. Null — or [locked] — leaves empty time inert.
  final void Function(DateTime startUtc, DateTime endUtc)? onCreateRequested;

  /// How long a bare tap's span is: the open ask's length, else 30.
  final int defaultCreateMinutes;

  /// A drag or resize on an [GridProposal.adjustable] proposal — to another
  /// time, or another day's column in the week — with the new span. Like a
  /// drop, the tile is not moved here: the host re-runs its proposal and the
  /// ghost is redrawn where that answer puts it.
  final void Function(DateTime startUtc, DateTime endUtc)? onProposalChanged;

  /// A tap on the proposal tile: the host brings its card into view.
  final VoidCallback? onProposalTapped;

  /// A drag the grid will not pass on, with its sentence for the host to
  /// say: a resize that would leave its day ([resizeLeavesDay]).
  final void Function(String sentence)? onRefused;

  /// What [onRefused] says for a resize dragged into another day's column.
  static const String resizeLeavesDay =
      'A meeting stays on one day — move it instead.';

  /// Whether [startUtc]–[endUtc] is one local day's span in [zone]: its
  /// last minute on its first day. The host's belt for any span it is
  /// handed. The dates alone decide: a fall-back day is 25 hours long, and
  /// all of it is one day.
  static bool staysOnOneDay(
      CalendarZone zone, DateTime startUtc, DateTime endUtc) {
    final (first, last) = _daysOf(zone, startUtc, endUtc);
    return first == last;
  }

  /// The grid's resize rule: whether a resize of [wasStartUtc]–[wasEndUtc]
  /// to [startUtc]–[endUtc] keeps to the local day or days the meeting
  /// already covered. A one-day meeting stays on its day; the owner's own
  /// overnight meeting may be moved or resized within the days it already
  /// covered, never dragged past them.
  static bool resizeKeepsDays(CalendarZone zone, DateTime wasStartUtc,
      DateTime wasEndUtc, DateTime startUtc, DateTime endUtc) {
    final (wasFirst, wasLast) = _daysOf(zone, wasStartUtc, wasEndUtc);
    final (first, last) = _daysOf(zone, startUtc, endUtc);
    return !first.isBefore(wasFirst) && !last.isAfter(wasLast);
  }

  /// The local dates of a span's first and last minute in [zone]: a span
  /// that ends at midnight ends on the day before it.
  static (CalendarDate, CalendarDate) _daysOf(
      CalendarZone zone, DateTime startUtc, DateTime endUtc) {
    final last = endUtc.isAfter(startUtc)
        ? endUtc.subtract(const Duration(minutes: 1))
        : endUtc;
    return (zone.dateOf(startUtc.toUtc()), zone.dateOf(last.toUtc()));
  }

  static Key tileKeyFor(String eventId) => ValueKey('day-grid-tile-$eventId');
  /// A deadline ([kind] `due`) or return (`back`) tile. The source and the
  /// kind are both in it: a Teams chat and a mail thread can share an id,
  /// and one thread can be due on Tuesday and back on Thursday of one week.
  /// A reminder's tile (`reminder`) is keyed by the REMINDER's id in place
  /// of the conversation key, since one thread may carry two.
  static Key markerKeyFor(String source, String conversationKey,
          {required String kind}) =>
      ValueKey('day-grid-marker-$kind-$source-$conversationKey');
  static const Key proposalKey = ValueKey('day-grid-proposal');

  /// While a tile is dragged: the copy under the pointer, the original left
  /// behind, and the outline where it would land.
  static const Key feedbackKey = ValueKey('day-grid-feedback');
  static const Key draggedKey = ValueKey('day-grid-dragged');
  static const Key dropTargetKey = ValueKey('day-grid-drop-target');

  @override
  State<DayGrid> createState() => _DayGridState();
}

enum _TileKind { event, deadline, returning, reminder, proposal }

/// One tile's worth of what the grid needs to draw and route it. The
/// package restores id, interaction and isAllDay after a drag, so
/// [copyWithData] carries only these fields.
class _GridTile extends KalenderEvent {
  _GridTile({
    super.id,
    required super.start,
    required super.end,
    super.isAllDay,
    super.interaction,
    required this.kind,
    required this.title,
    this.eventId = '',
    this.item,
    this.standing = EventStanding.noAnswerNeeded,
    this.cancelled = false,
    this.overlap = false,
    this.softOverlap = false,
    this.movable = false,
    this.caption = '',
  });

  final _TileKind kind;
  final String title;
  final String eventId;
  final DayItem? item;
  /// Where the owner stands on the meeting ([standingOf]); the fill and the
  /// bar wear it. Markers keep the default.
  final EventStanding standing;
  final bool cancelled;

  /// A HARD overlap: the bar turns the error colour and the title gets '⚠'.
  final bool overlap;

  /// A SOFT overlap only (the other side is a tentative hold): the '⚠', not
  /// the bar.
  final bool softOverlap;
  final bool movable;

  /// A proposal's second line ("Proposed") under its subject.
  final String caption;

  @override
  _GridTile copyWithData({required DateTime start, required DateTime end}) =>
      _GridTile(
        start: start,
        end: end,
        kind: kind,
        title: title,
        eventId: eventId,
        item: item,
        standing: standing,
        cancelled: cancelled,
        overlap: overlap,
        softOverlap: softOverlap,
        movable: movable,
        caption: caption,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return super == other &&
        other is _GridTile &&
        other.kind == kind &&
        other.title == title &&
        other.eventId == eventId &&
        other.item == item &&
        other.standing == standing &&
        other.cancelled == cancelled &&
        other.overlap == overlap &&
        other.softOverlap == softOverlap &&
        other.movable == movable &&
        other.caption == caption;
  }

  @override
  int get hashCode => Object.hash(super.hashCode, kind, title, eventId, item,
      standing, cancelled, overlap, softOverlap, movable, caption);
}

class _DayGridState extends State<DayGrid> {
  late final DefaultEventsController _events =
      DefaultEventsController(locations: [widget.zone.location]);
  final KalenderController _controller = KalenderController();

  /// A method, torn off, rather than a closure written inline: the package
  /// compares configurations with `==` and the callback is part of it, and
  /// two tear-offs of one method on one object are equal where two fresh
  /// closures are not. The display zone's wall clock, because the package
  /// reads "now" by its components.
  DateTime _now() => widget.zone.toLocal(widget.clock().toUtc());

  late MultiDayViewConfiguration _config = _configFor(widget.span);

  @override
  void initState() {
    super.initState();
    _events.replaceEvents(_tiles());
  }

  @override
  void didUpdateWidget(DayGrid old) {
    super.didUpdateWidget(old);
    // The host rebuilds the markers on every build (the sixty-second poll
    // included), so they are compared by what they draw, not by identity.
    if (!listEquals(old.events, widget.events) ||
        !listEquals(_markerSig(old.markers), _markerSig(widget.markers)) ||
        old.proposal != widget.proposal ||
        old.locked != widget.locked ||
        old.zone != widget.zone) {
      _events.replaceEvents(_tiles());
    }
    // A zone change rebuilds the configuration as a span change does: its
    // first day and its window are local dates, built in the old zone.
    if (old.span != widget.span || old.zone != widget.zone) {
      // The new configuration reaches the view on this build; the check
      // waits until it has, or it would page the view being replaced.
      _config = _configFor(widget.span);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showDay();
      });
    } else if (old.day != widget.day) {
      _showDay();
    }
  }

  /// Pages the view to [DayGrid.day] unless it is already showing it.
  void _showDay() {
    if (_visibleFirstDay() == _firstDayFor(widget.day)) return;
    _controller.jumpToDate(widget.zone.localDateTime(widget.day, 12, 0));
  }

  @override
  void dispose() {
    // The view is already unmounted by now (children go first), so neither
    // controller has a listener left to write to.
    _controller.dispose();
    _events.dispose();
    super.dispose();
  }

  MultiDayViewConfiguration _configFor(GridSpan span) {
    final zone = widget.zone;
    final initial = zone.localDateTime(widget.day, 12, 0);
    // The working morning at the top, not midnight: a grid that opens on
    // six empty hours reads as an empty calendar.
    const top = KalenderTime(hour: 7, minute: 0);
    // The mirror's window, the arrows' own limits: a page outside it would
    // read as an empty calendar when it is merely not synced. The package
    // counts whole days up to an end that is a midnight, so the arrows' last
    // day is in only when the end is the midnight after it. Taken when the
    // configuration is built: a grid left open past midnight keeps
    // yesterday's window until its span changes.
    final today = zone.dateOf(widget.clock().toUtc());
    final range = KalenderDateTimeRange(
      start: zone.localDateTime(today.addDays(-DayPane.daysBack), 0, 0),
      end: zone.localDateTime(today.addDays(DayPane.daysForward + 1), 0, 0),
    );
    return span == GridSpan.day
        ? MultiDayViewConfiguration.singleDay(
            initialDateTime: initial,
            nowCallback: _now,
            initialTimeOfDay: top,
            displayRange: range,
          )
        : MultiDayViewConfiguration.week(
            firstDayOfWeek: DateTime.monday,
            initialDateTime: initial,
            nowCallback: _now,
            initialTimeOfDay: top,
            displayRange: range,
          );
  }

  /// The first column [day] would put on screen in the current span.
  CalendarDate _firstDayFor(CalendarDate day) =>
      widget.span == GridSpan.day ? day : mondayOf(day);

  CalendarDate? _visibleFirstDay() {
    final range = _controller.visibleDateTimeRange.value;
    if (range == null) return null;
    return widget.zone.dateOf(range.start.toUtc());
  }

  // ── the tiles ────────────────────────────────────────────────────────

  List<KalenderEvent> _tiles() {
    final zone = widget.zone;
    final tiles = <KalenderEvent>[];
    for (final e in widget.events) {
      if (e.isSeriesMaster) continue;
      final standing = standingOf(e);
      // A declined meeting is not drawn: the owner said no, and Outlook
      // takes it off the calendar anyway.
      if (standing == EventStanding.declined) continue;
      if (e.isAllDay) {
        final start = e.startDate;
        if (start == null) continue;
        final end = e.endDate;
        final last = end != null && end.isAfter(start) ? end : start.addDays(1);
        tiles.add(_GridTile(
          id: 'event:${e.id}',
          start: zone.localDateTime(start, 0, 0),
          end: zone.localDateTime(last, 0, 0),
          isAllDay: true,
          interaction: EventInteraction.allowNone(),
          kind: _TileKind.event,
          title: e.subject,
          eventId: e.id,
          standing: standing,
          cancelled: standing == EventStanding.cancelled,
        ));
        continue;
      }
      final s = e.startUtc;
      final end = e.endUtc;
      if (s == null || end == null || end.isBefore(s)) continue;
      // [canMove] already refuses a cancelled event and a series master;
      // timed is the grid's own rule (an all-day drag is out of this round).
      final movable = !widget.locked && canMove(e) && e.isTimed;
      final overlaps = overlapsForEvent(e, widget.events, zone: zone);
      tiles.add(_GridTile(
        id: 'event:${e.id}',
        start: s,
        end: end,
        interaction: movable
            ? EventInteraction(
                allowRescheduling: true,
                allowStartResize: true,
                allowEndResize: true,
              )
            : EventInteraction.allowNone(),
        kind: _TileKind.event,
        title: e.subject,
        eventId: e.id,
        standing: standing,
        cancelled: standing == EventStanding.cancelled,
        overlap: overlaps.hard.isNotEmpty,
        softOverlap: overlaps.soft.isNotEmpty,
        movable: movable,
      ));
    }

    var n = 0;
    for (final item in widget.markers) {
      final (kind, date, title) = switch (item) {
        DeadlineItem d => (
            _TileKind.deadline,
            d.day ?? widget.day,
            'Due · ${_subject(d.conversation.subject ?? '')} · ${d.deadline}',
          ),
        ReturnItem(:final conversation, :final atUtc) => (
            _TileKind.returning,
            zone.dateOf(atUtc),
            'Back: ${_subject(conversation.subject ?? '')}',
          ),
        ReminderItem(:final reminder, :final atUtc) => (
            _TileKind.reminder,
            zone.dateOf(atUtc),
            'Reminder · ${_subject(reminder.title)}',
          ),
        _ => (null, null, ''),
      };
      if (kind == null || date == null) continue;
      tiles.add(_GridTile(
        id: 'marker:${n++}',
        start: zone.localDateTime(date, 0, 0),
        end: zone.localDateTime(date.addDays(1), 0, 0),
        isAllDay: true,
        interaction: EventInteraction.allowNone(),
        kind: kind,
        title: title,
        item: item,
      ));
    }

    final p = widget.proposal;
    if (p != null && p.endUtc.isAfter(p.startUtc)) {
      // A standing proposal moves and resizes like an own event — to
      // another time, or another column in the week — and asks the host.
      final adjustable =
          p.adjustable && !widget.locked && widget.onProposalChanged != null;
      final named = p.subject.trim().isNotEmpty;
      tiles.add(_GridTile(
        id: 'proposal',
        start: p.startUtc,
        end: p.endUtc,
        interaction: adjustable
            ? EventInteraction(
                allowRescheduling: true,
                allowStartResize: true,
                allowEndResize: true,
              )
            : EventInteraction.allowNone(),
        kind: _TileKind.proposal,
        title: named ? p.subject.trim() : p.label,
        caption: named ? p.label : p.caption,
        movable: adjustable,
      ));
    }
    return tiles;
  }

  /// What each marker tile would draw and route by, in order.
  static List<String> _markerSig(List<DayItem> markers) => [
        for (final m in markers)
          switch (m) {
            DeadlineItem(:final conversation, :final deadline, :final day) =>
              'd\u0000${conversation.source}\u0000${conversation.id}\u0000'
                  '${day?.toIso()}\u0000$deadline\u0000${conversation.subject}',
            ReturnItem(:final conversation, :final atUtc) =>
              'r\u0000${conversation.source}\u0000${conversation.id}\u0000'
                  '${atUtc.toIso8601String()}\u0000${conversation.subject}',
            ReminderItem(:final reminder, :final atUtc) =>
              'm\u0000${reminder.source}\u0000${reminder.id}\u0000'
                  '${atUtc.toIso8601String()}\u0000${reminder.title}',
            _ => '',
          },
      ];

  static String _subject(String s) =>
      s.trim().isEmpty ? '(no subject)' : s.trim();

  // ── callbacks ────────────────────────────────────────────────────────

  void _tapped(KalenderEvent event) {
    if (event is! _GridTile) return;
    switch (event.kind) {
      case _TileKind.event:
        widget.onOpenEvent?.call(event.eventId);
      case _TileKind.deadline:
      case _TileKind.returning:
      case _TileKind.reminder:
        final item = event.item;
        if (item != null) widget.onOpenItem?.call(item);
      case _TileKind.proposal:
        if (!widget.locked) widget.onProposalTapped?.call();
    }
  }

  /// Never `updateEvent`: the tile stays where the store put it until the
  /// store says otherwise.
  ///
  /// A drop where the tile already was stops here: the package snaps a click
  /// that wobbled a pixel back to the tile's own start and end and still
  /// calls this, and a wobble must cost nothing — no dry run, no toast.
  void _changed(KalenderEvent original, KalenderEvent updated) {
    if (original is! _GridTile) return;
    // kalender reads a resize's end from the pointer's COLUMN as well as its
    // height, so an end handle drifting into Thursday makes a two-day span.
    // A resize keeps to the day (or an overnight meeting's days) it covered;
    // only a move (the same length) changes columns.
    if (_resizeLeavesDay(original, updated)) {
      widget.onRefused?.call(DayGrid.resizeLeavesDay);
      return;
    }
    if (original.kind == _TileKind.proposal) {
      if (!original.movable ||
          (updated.start.isAtSameMomentAs(original.start) &&
              updated.end.isAtSameMomentAs(original.end))) {
        return;
      }
      widget.onProposalChanged?.call(_utc(updated.start), _utc(updated.end));
      return;
    }
    if (original.kind != _TileKind.event || !original.movable) return;
    if (updated.start.isAtSameMomentAs(original.start) &&
        updated.end.isAtSameMomentAs(original.end)) {
      return;
    }
    widget.onMoveRequested
        ?.call(original.eventId, _utc(updated.start), _utc(updated.end));
  }

  bool get _creates => !widget.locked && widget.onCreateRequested != null;

  /// A drag over empty time ended: the span it covered, as the package
  /// sized it while the pointer moved. A drag that barely moved — the
  /// package seeds exactly one snap, a quarter hour, and never less — is a
  /// tap that wobbled and takes the default length.
  ///
  /// The package never adds a created event itself — that is the host's
  /// job in its `onEventCreated` — so nothing is added here, and the grid
  /// stays a mirror of the store, as it does for a drop.
  void _created(KalenderEvent event) {
    if (!_creates) return;
    final start = _utc(event.start);
    var end = _utc(event.end);
    if (end.difference(start) <= const Duration(minutes: 15)) {
      end = start.add(Duration(minutes: widget.defaultCreateMinutes));
    }
    widget.onCreateRequested?.call(start, end);
  }

  /// A bare tap on empty time in the body: [DayGrid.defaultCreateMinutes]
  /// from the quarter hour tapped (the package snaps the date it reports).
  /// A tap in the all-day header reports a [MultiDayDetail] and does
  /// nothing: creation there stays off.
  void _emptyTapped(TapDetail detail) {
    if (!_creates || detail is! DayDetail) return;
    final start = _utc(detail.date);
    widget.onCreateRequested?.call(
        start, start.add(Duration(minutes: widget.defaultCreateMinutes)));
  }

  bool _resizeLeavesDay(KalenderEvent original, KalenderEvent updated) {
    final was = original.end.difference(original.start);
    final now = updated.end.difference(updated.start);
    if (was == now) return false;
    return !DayGrid.resizeKeepsDays(widget.zone, _utc(original.start),
        _utc(original.end), _utc(updated.start), _utc(updated.end));
  }

  /// A plain UTC [DateTime] at [t]'s instant. The package hands back
  /// `TZDateTime`s, whose `==` also compares the location, so one never
  /// equals the plain UTC stamp the store holds for the same instant.
  static DateTime _utc(DateTime t) =>
      DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

  /// Reports only a page the PERSON turned: a jump the host asked for, and
  /// the page the view opened on, land on the day the host already holds.
  void _pageChanged(KalenderDateTimeRange range) {
    final first = widget.zone.dateOf(range.start.toUtc());
    if (first == _firstDayFor(widget.day)) return;
    widget.onVisibleDayChanged?.call(first);
  }

  // ── the look ─────────────────────────────────────────────────────────

  Widget _tile(BuildContext context, KalenderEvent event, KalenderDateTimeRange range) =>
      _tileBody(event);

  /// What follows the pointer during a drag: the same tile at the landing
  /// size, a little see-through, outlined in the primary colour. Material
  /// for its text, since it is drawn in the overlay, outside the grid.
  Widget _feedbackTile(BuildContext context, KalenderEvent event, Size size) =>
      Material(
        key: DayGrid.feedbackKey,
        type: MaterialType.transparency,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: Opacity(
            opacity: 0.85,
            child: _tileBody(event,
                keyed: false,
                outline: Border.all(color: BondColors.primary, width: 1.5)),
          ),
        ),
      );

  /// The tile left behind while it is dragged: faded, so the eye follows
  /// the feedback rather than it.
  Widget _tileWhileDragging(BuildContext context, KalenderEvent event) =>
      Opacity(key: DayGrid.draggedKey, opacity: 0.35, child: _tileBody(event));

  /// Where the drop would land, drawn as the pointer moves: the ghost's own
  /// look, a primary outline on an 8 % fill.
  Widget _dropTarget(BuildContext context, KalenderEvent event) => Container(
        key: DayGrid.dropTargetKey,
        decoration: BoxDecoration(
          color: BondColors.primary.withValues(alpha: 0.08),
          borderRadius: BondRadii.smAll,
          border: Border.all(color: BondColors.primary, width: 1.5),
        ),
      );

  /// One tile's drawing, shared by the tile, its drag feedback and the tile
  /// left behind. [keyed] false leaves its key off (the feedback is a copy,
  /// and a test finds the tile by its key); [outline] replaces its border.
  Widget _tileBody(KalenderEvent event, {bool keyed = true, Border? outline}) {
    if (event is! _GridTile) return const SizedBox.shrink();
    final zone = widget.zone;
    final Key key = switch (event.kind) {
      _TileKind.event => DayGrid.tileKeyFor(event.eventId),
      _TileKind.proposal => DayGrid.proposalKey,
      _ => _markerKey(event.item),
    };

    Color fill;
    Color bar;
    Border? border;
    switch (event.kind) {
      case _TileKind.proposal:
        fill = BondColors.primary.withValues(alpha: 0.08);
        bar = Colors.transparent;
        border = Border.all(color: BondColors.primary, width: 1.5);
      case _TileKind.deadline:
        fill = BondColors.attentionTint;
        bar = BondColors.attention;
      case _TileKind.returning:
        fill = BondColors.neutralTint;
        bar = BondColors.inkMuted;
      case _TileKind.reminder:
        fill = BondColors.neutralTint;
        bar = BondColors.primary;
      case _TileKind.event:
        // The standing's colours, the same palette as the agenda row; a
        // hard overlap takes the bar in the error colour, distinct from a
        // Maybe's attention.
        fill = standingFillColor(event.standing);
        bar = event.overlap
            ? BondColors.error
            : standingBarColor(event.standing);
        if (event.standing == EventStanding.unanswered) {
          // Not yet the owner's: a thin primary edge round a faint fill.
          border = Border.all(
              color: BondColors.primary.withValues(alpha: 0.5), width: 1);
        }
        if (event.cancelled) {
          fill = BondColors.neutralTint;
          bar = BondColors.inkMuted;
        }
    }

    final struck = event.cancelled;
    final clash = event.overlap || event.softOverlap;
    final title = Text(
      event.kind == _TileKind.event
          ? '${clash ? '⚠ ' : ''}${_subject(event.title)}'
          : event.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: BondType.caption.copyWith(
        color: event.cancelled ? BondColors.inkMuted : BondColors.ink,
        fontWeight: FontWeight.w600,
        decoration: struck ? TextDecoration.lineThrough : null,
      ),
    );
    final timed = !event.isAllDay;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tall = constraints.maxHeight > 30;
        return Container(
          key: keyed ? key : null,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BondRadii.smAll,
            border: outline ?? border,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (event.kind != _TileKind.proposal)
                Container(width: 3, color: bar),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: BondSpacing.s4, vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // A short proposal has one line: its caption rides
                      // on it, so "Proposed" is never lost.
                      if (event.caption.isNotEmpty && !tall)
                        Flexible(
                          child: Text.rich(
                            TextSpan(
                              text: event.title,
                              style: title.style,
                              children: [
                                TextSpan(
                                  text: ' · ${event.caption}',
                                  style: BondType.caption
                                      .copyWith(color: BondColors.primary),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        Flexible(child: title),
                      if (event.caption.isNotEmpty && tall)
                        Flexible(
                          child: Text(
                            event.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BondType.caption
                                .copyWith(color: BondColors.primary),
                          ),
                        )
                      else if (timed && tall)
                        Flexible(
                          child: Text(
                            formatEventRange(zone, event.start, event.end),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BondType.caption
                                .copyWith(color: BondColors.inkSecondary),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Key _markerKey(DayItem? item) => switch (item) {
        DeadlineItem(:final conversation) => DayGrid.markerKeyFor(
            conversation.source, conversation.id,
            kind: 'due'),
        ReturnItem(:final conversation) => DayGrid.markerKeyFor(
            conversation.source, conversation.id,
            kind: 'back'),
        ReminderItem(:final reminder) => DayGrid.markerKeyFor(
            reminder.source, reminder.id,
            kind: 'reminder'),
        _ => const ValueKey('day-grid-marker'),
      };

  @override
  Widget build(BuildContext context) {
    // Every builder a tear-off: kalender compares components with `==`.
    // Without the three drag builders kalender draws NOTHING while a tile
    // is dragged — no feedback, no faded original, no landing outline — and
    // the tile only jumps when the drop lands. The feedback keeps the grab
    // point under the pointer (`childDragAnchorStrategy`, kalender's own
    // default, written out so it is a choice).
    final tiles = TileComponents(
      tileBuilder: _tile,
      feedbackTileBuilder: _feedbackTile,
      tileWhenDraggingBuilder: _tileWhileDragging,
      dropTargetTile: _dropTarget,
      dragAnchorStrategy: childDragAnchorStrategy,
      verticalResizeHandle: const _ResizePill(),
    );
    // A 10-px resize band at a tile's end, not kalender's 16: the middle of
    // a 30-minute tile (21 px) drags, and only its last 10 px resize. The
    // start band hides where kalender hides it (twice its length over half
    // the tile).
    return KalenderTheme(
      data: const KalenderThemeData(
          resizeHandleStyle: ResizeHandleStyle(length: 10)),
      child: KalenderView(
      eventsController: _events,
      kalenderController: _controller,
      location: widget.zone.location,
      viewConfiguration: _config,
      callbacks: KalenderCallbacks(
        onEventTapped: _tapped,
        onEventChanged: _changed,
        onPageChanged: _pageChanged,
        onEventCreated: _creates ? _created : null,
        onTappedWithDetail: _creates ? _emptyTapped : null,
      ),
      components: KalenderComponents(
        multiDayComponents: MultiDayComponents(
          bodyComponents: MultiDayBodyComponents(
            // "9 AM" down the side, the agenda's clock, whatever the
            // device's 24-hour setting says.
            timelineStringBuilder: _timeline,
            // Hours only on the axis; see [_HourTimeLine].
            timeline: (context, heightPerMinute, timeOfDayRange,
                    eventBeingDragged, visibleDateTimeRange) =>
                _HourTimeLine(
              timeOfDayRange: timeOfDayRange,
              heightPerMinute: heightPerMinute,
              eventBeingDragged: eventBeingDragged,
              visibleDateTimeRange: visibleDateTimeRange,
            ),
          ),
        ),
      ),
      header: KalenderHeader(
        interaction: KalenderInteraction(
          allowEventCreation: false,
          allowResizing: false,
          allowRescheduling: false,
        ),
        multiDayTileComponents: tiles,
      ),
      body: KalenderBody(
        // Creating on empty time: kalender 0.32 offers `tap` (a plain
        // Draggable, which starts on the first movement — the desktop's
        // press-and-drag sizes the span as the pointer moves) and
        // `longPress` (a LongPressDraggable, held first — what a phone
        // needs, where a plain drag is the scroll). Neither makes an event
        // from a bare tap: that is `onTappedWithDetail` ([_emptyTapped]).
        interaction: KalenderInteraction(
          allowEventCreation: _creates,
          createEventGesture: switch (defaultTargetPlatform) {
            TargetPlatform.android ||
            TargetPlatform.iOS =>
              EventInteractionGesture.longPress,
            _ => EventInteractionGesture.tap,
          },
        ),
        // Quarter hours, and never the Now line: a meeting dragged near now
        // would otherwise land on 4:07.
        snapping: const KalenderSnapping(
          snapIntervalMinutes: 15,
          snapToTimeIndicator: false,
        ),
        multiDayTileComponents: tiles,
        // Side by side: overlapping tiles divide the column instead of
        // covering each other, so a clash is visible as two tiles —
        // kalender's default `overlap()` strategy draws them on top of
        // each other. Day and week share this one body configuration.
        multiDayBodyConfiguration: const MultiDayBodyConfiguration(
          minimumTileHeight: 20,
          eventLayoutStrategy: EventLayoutStrategy.sideBySide(),
        ),
      ),
    ),
    );
  }

  static String _timeline(BuildContext context, KalenderTime time) {
    final t = DateTime.utc(2000, 1, 1, time.hour, time.minute);
    return time.minute == 0
        ? DateFormat('h a').format(t)
        : DateFormat('h:mm a').format(t);
  }
}

/// kalender's timeline labels every 30, 15 or even 5 minutes as soon as the
/// grid is tall enough for the text to fit (`segmentDuration`), which on a
/// desktop window is a wall of "5:30 AM" down the side. An hour per label
/// here, whatever the height: the half-hour lines still draw, and the labels
/// a drag shows at a tile's ends keep their minutes, because those go
/// through the string builder and not through this.
class _HourTimeLine extends TimeLine {
  const _HourTimeLine({
    required super.timeOfDayRange,
    required super.heightPerMinute,
    required super.eventBeingDragged,
    required super.visibleDateTimeRange,
  });

  @override
  int segmentDuration(
    KalenderTimeRange timeOfDayRange,
    double heightPerMinute,
    double itemHeight,
  ) =>
      60;
}

/// The mark on a tile's resize band: a small pill at its end, so the band
/// LOOKS like the place that resizes.
///
/// The band behind it is filled with a transparent colour on purpose:
/// kalender's resize `Draggable` hit-tests only its child, and a bare
/// `Center` answers only where the 3-px pill is drawn, which made the 10-px
/// band a 3-px line in the middle of it.
class _ResizePill extends StatelessWidget {
  const _ResizePill();

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.transparent,
        alignment: Alignment.center,
        child: Container(
          width: 24,
          height: 3,
          decoration: BoxDecoration(
            color: BondColors.primary.withValues(alpha: 0.5),
            borderRadius: BondRadii.fullAll,
          ),
        ),
      );
}
