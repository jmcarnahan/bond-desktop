import 'package:flutter/material.dart';

import '../models/calendar_models.dart';
import '../services/calendar/calendar_sync.dart' show CalendarAvailability;
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart';
import '../services/calendar/event_view.dart';
import '../services/calendar/overlaps.dart';
import '../theme/tokens.dart';
import 'clock_tick.dart';
import 'day_pane.dart' show DayPane;

/// One meeting, read beside whatever named it: when it is, whether to join,
/// where the owner stands, who is coming, and which conversations are about
/// it.
///
/// Prop-only, as [DayPane] is: the screen resolves the event, its links and
/// its overlaps through the providers and hands them in, so the panel is a
/// function of its arguments and a test pins `now` and the zone. The subject
/// is the host header's title, so the body starts at the when line.
///
/// A series master is never shown as itself — its times are the series'
/// FIRST meeting — but as [displayOccurrence]'s pick, the next one still
/// ahead. The actions and overlaps a host passes are for that occurrence.
///
/// Everything the organiser wrote — subject, location, the invite's body —
/// arrives untrusted and is drawn as plain text: never a link, never markup.
/// The only links are the join URL and Outlook's own page, each behind a
/// button, through [onOpenLink] and the screen's guarded launcher.
class EventPanelBody extends StatelessWidget {
  const EventPanelBody({
    super.key,
    required this.lookup,
    required this.zone,
    required this.now,
    required this.today,
    this.overlaps,
    this.links = const [],
    required this.onOpenLink,
    required this.onOpenThread,
    this.onOpenStoryline,
    this.onOpenSettings,
    this.brief,
    this.actions,
    this.onRetry,
  });

  static const String goneText = 'This event no longer exists.';
  static const String unreachableText =
      "Couldn't reach the calendar. Try again in a moment.";

  static const Key joinKey = ValueKey('event-panel-join');
  static const Key openInOutlookKey = ValueKey('event-panel-open-in-outlook');
  static const Key tallyKey = ValueKey('event-panel-tally');
  static const Key overlapKey = ValueKey('event-panel-overlap');
  static const Key responseKey = ValueKey('event-panel-response');
  static const Key whenKey = ValueKey('event-panel-when');
  static const Key bodyPreviewKey = ValueKey('event-panel-body-preview');
  static const Key retryKey = ValueKey('event-panel-retry');

  static Key linkKeyFor(String source, String conversationKey) =>
      ValueKey('event-panel-link-$source-$conversationKey');

  static Key attendeeKeyFor(String address) =>
      ValueKey('event-panel-attendee-$address');

  /// Null while the read is in flight: a line saying so, never an empty
  /// panel that could be read as "no such meeting".
  final EventLookup? lookup;
  final CalendarZone zone;

  /// The host's clock reading for this build; the countdown and the Join
  /// button follow it from there on their own tick.
  final DateTime now;

  /// Today in [zone], for "Today · …" / "Tomorrow · …".
  final CalendarDate today;

  /// What the shown occurrence runs into, computed by the host against that
  /// day's events. Null says nothing.
  final Overlaps? overlaps;

  final List<EventLink> links;
  final void Function(String url) onOpenLink;
  final void Function(String source, String conversationKey) onOpenThread;

  /// Opens a link's storyline. Null draws no storyline chips.
  final void Function(String storylineId)? onOpenStoryline;

  /// Where the scope-missing sentence's button goes. Null draws no button.
  final VoidCallback? onOpenSettings;

  /// What the meeting is about, as a model read it — a later phase's. Drawn
  /// under a 'Brief' heading only when given.
  final Widget? brief;

  /// Accept / Maybe / Decline and the rest — a later phase's. Drawn under the
  /// response line only when given.
  final Widget? actions;

  /// Reads the event again after an unreachable answer. That answer is a
  /// successful value the provider keeps until the calendar next changes, so
  /// without this a moment offline would stand until then. Null draws no
  /// button.
  final VoidCallback? onRetry;

  static final TextStyle _muted =
      BondType.small.copyWith(color: BondColors.inkMuted);

  @override
  Widget build(BuildContext context) {
    final l = lookup;
    if (l == null) return _sentence(Text(DayPane.readingText, style: _muted));
    switch (l.state) {
      case EventLookupState.gone:
        return _sentence(Text(goneText, style: _muted));
      case EventLookupState.unreachable:
        final retry = onRetry;
        return _sentence(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(unreachableText, style: _muted),
              if (retry != null)
                TextButton(
                  key: retryKey,
                  onPressed: retry,
                  child: const Text('Retry'),
                ),
            ],
          ),
        );
      case EventLookupState.blocked:
        return _sentence(_blocked(l.availability));
      case EventLookupState.found:
        final event = l.event;
        if (event == null) return _sentence(Text(goneText, style: _muted));
        return _found(event, l.occurrences);
    }
  }

  Widget _sentence(Widget child) => Padding(
        padding: const EdgeInsets.all(BondSpacing.s16),
        child: Align(alignment: Alignment.topLeft, child: child),
      );

  Widget _blocked(CalendarAvailability availability) {
    if (availability == CalendarAvailability.scopeMissing) {
      final open = onOpenSettings;
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: BondSpacing.s8,
        children: [
          Text(DayPane.scopeMissingText, style: _muted),
          if (open != null)
            TextButton(onPressed: open, child: const Text('Open Settings')),
        ],
      );
    }
    return Text(DayPane.sdkModeText, style: _muted);
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s4),
        child: Text(text, style: BondType.label),
      );

  Widget _found(CalendarEvent event, List<CalendarEvent> occurrences) {
    final shown = displayOccurrence(event, occurrences, now.toUtc(), zone);
    final when = eventWhenLine(shown, zone: zone, today: today);
    final series = isSeriesEvent(event) || isSeriesEvent(shown);
    final overlap = overlaps == null ? null : overlapLine(overlaps!);
    final tally = attendeeTally(shown);
    final organiser = shown.organizerName.trim().isNotEmpty
        ? shown.organizerName.trim()
        : shown.organizerAddress.trim();
    final body = shown.bodyPreview.trim();

    return ListView(
      padding: const EdgeInsets.all(BondSpacing.s16),
      children: [
        if (when.isNotEmpty || series)
          Text(
            '$when${series ? '${when.isEmpty ? '' : ' · '}series' : ''}',
            key: whenKey,
            style: BondType.body.copyWith(fontWeight: FontWeight.w600),
          ),
        if (shown.isCancelled)
          Text(
            'Cancelled',
            style: BondType.caption.copyWith(color: BondColors.error),
          ),
        const SizedBox(height: BondSpacing.s8),
        EventJoinRow(
          event: shown,
          now: now,
          zone: zone,
          joinKey: joinKey,
          onOpenLink: onOpenLink,
          trailing: [
            if (shown.webLink.trim().isNotEmpty)
              TextButton(
                key: openInOutlookKey,
                onPressed: () => onOpenLink(shown.webLink.trim()),
                child: const Text('Open in Outlook'),
              ),
          ],
        ),
        if (shown.location.trim().isNotEmpty)
          Text(shown.location.trim(), style: _muted),
        if (shown.isOrganizer)
          Text('You organised this', style: _muted)
        else if (organiser.isNotEmpty)
          Text('Organised by $organiser', style: _muted),
        const SizedBox(height: BondSpacing.s8),
        Text(responseLine(shown), key: responseKey, style: BondType.small),
        if (actions != null) ...[
          const SizedBox(height: BondSpacing.s8),
          actions!,
        ],
        if (overlap != null) ...[
          const SizedBox(height: BondSpacing.s4),
          Text(
            overlap,
            key: overlapKey,
            style: BondType.caption.copyWith(color: BondColors.attention),
          ),
        ],
        if (shown.attendees.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s16),
          _heading('People'),
          if (tally != null)
            Padding(
              padding: const EdgeInsets.only(bottom: BondSpacing.s4),
              child: Text(tally, key: tallyKey, style: BondType.small),
            ),
          for (final a in shown.attendees)
            _attendeeRow(a, organiserCopy: shown.isOrganizer),
        ],
        if (links.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s16),
          _heading('Conversations'),
          for (final link in links) _linkRow(link),
        ],
        if (brief != null) ...[
          const SizedBox(height: BondSpacing.s16),
          _heading('Brief'),
          brief!,
        ],
        if (body.isNotEmpty) ...[
          const SizedBox(height: BondSpacing.s16),
          _heading('From the invite'),
          // The organiser's words, untrusted: plain text that can be
          // selected and copied, and nothing in it is a link.
          SelectableText(body, key: bodyPreviewKey, style: _muted),
        ],
      ],
    );
  }

  /// One invitee: how they answered, as an icon with the word in its
  /// tooltip, then who they are. Optional invitees and rooms say so.
  ///
  /// "No reply" is a claim only the organiser's copy can make: an attendee's
  /// copy commonly reads `none` for everyone ([attendeeTally]'s reason), so
  /// there an unanswered row is a plain dot that says it is not known.
  Widget _attendeeRow(Attendee a, {required bool organiserCopy}) {
    final (IconData icon, Color color, String word) =
        switch (a.response.trim().toLowerCase()) {
      'accepted' => (Icons.check_circle_outline, BondColors.success, 'Accepted'),
      'tentativelyaccepted' => (
          Icons.help_outline,
          BondColors.attention,
          'Maybe'
        ),
      'declined' => (Icons.cancel_outlined, BondColors.inkMuted, 'Declined'),
      _ => organiserCopy
          ? (Icons.radio_button_unchecked, BondColors.inkMuted, 'No reply')
          : (Icons.circle_outlined, BondColors.inkMuted, 'Not known'),
    };
    final name = a.name.trim().isNotEmpty ? a.name.trim() : a.address;
    final type = a.type.trim().toLowerCase();
    final suffix = type == 'optional'
        ? ' · optional'
        : type == 'resource'
            ? ' · room'
            : '';
    return Padding(
      key: attendeeKeyFor(a.address),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Tooltip(message: word, child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: BondSpacing.s8),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: name),
                  if (suffix.isNotEmpty)
                    TextSpan(
                      text: suffix,
                      style: const TextStyle(color: BondColors.inkMuted),
                    ),
                ],
              ),
              style: BondType.small,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// One linked conversation: its kind, its name, and the storyline it is
  /// filed in. The chip is its own [InkWell] inside the row's, so pressing
  /// it opens the storyline rather than the thread underneath — the
  /// innermost gesture wins.
  Widget _linkRow(EventLink link) {
    final storylineId = link.storylineId;
    final storylineTitle = link.storylineTitle;
    final openStoryline = onOpenStoryline;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: linkKeyFor(link.source, link.conversationKey),
        onTap: () => onOpenThread(link.source, link.conversationKey),
        borderRadius: BondRadii.smAll,
        hoverColor: BondColors.faintGround,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: BondSpacing.s4,
            horizontal: BondSpacing.s4,
          ),
          child: Row(
            children: [
              Icon(
                link.isMeetingChat
                    ? Icons.chat_bubble_outline
                    : Icons.mail_outline,
                size: 16,
                color: BondColors.inkSecondary,
              ),
              const SizedBox(width: BondSpacing.s8),
              Expanded(
                child: Text(
                  link.title,
                  style: BondType.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (storylineId != null &&
                  storylineTitle != null &&
                  openStoryline != null) ...[
                const SizedBox(width: BondSpacing.s8),
                Flexible(
                  child: Tooltip(
                    message: storylineTitle,
                    child: InkWell(
                      onTap: () => openStoryline(storylineId),
                      borderRadius: BondRadii.smAll,
                      child: Text(
                        storylineTitle,
                        style: BondType.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: BondColors.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The countdown and the Join button for one meeting, under ONE
/// [ClockTick], so the button turns emphatic fifteen minutes out and the
/// countdown moves on a panel nobody touches — and the two never disagree
/// about the time.
///
/// The button is there while the meeting has a link and has not ended
/// ([offersJoin]); it is a filled button while [joinable] says now is the
/// time, a quiet outlined one before that. [trailing] rides at the end of
/// the same row — the panel's 'Open in Outlook', the card's 'Open event'.
class EventJoinRow extends StatelessWidget {
  const EventJoinRow({
    super.key,
    required this.event,
    required this.now,
    required this.zone,
    required this.joinKey,
    required this.onOpenLink,
    this.trailing = const [],
    this.showCountdown = true,
  });

  final CalendarEvent event;
  final DateTime now;
  final CalendarZone zone;

  /// The key the Join button wears, so each host's tests can find its own.
  final Key joinKey;
  final void Function(String url) onOpenLink;
  final List<Widget> trailing;
  final bool showCountdown;

  @override
  Widget build(BuildContext context) {
    return ClockTick(
      initial: now,
      builder: (context, t) {
        final nowUtc = t.toUtc();
        final countdown = showCountdown ? meetingCountdown(event, nowUtc) : null;
        final url = event.joinUrl.trim();
        final children = <Widget>[
          if (countdown != null)
            Text(
              countdown,
              style: BondType.caption.copyWith(color: BondColors.primary),
            ),
          if (offersJoin(event, nowUtc, zone))
            joinable(event, nowUtc)
                ? FilledButton(
                    key: joinKey,
                    onPressed: () => onOpenLink(url),
                    child: const Text('Join'),
                  )
                : OutlinedButton(
                    key: joinKey,
                    onPressed: () => onOpenLink(url),
                    child: const Text('Join'),
                  ),
          ...trailing,
        ];
        if (children.isEmpty) return const SizedBox.shrink();
        return Wrap(
          spacing: BondSpacing.s8,
          runSpacing: BondSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        );
      },
    );
  }
}
