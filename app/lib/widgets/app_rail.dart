import 'package:flutter/material.dart';

import '../models/calendar_models.dart';
import '../models/files_models.dart';
import '../models/message_models.dart';
import '../models/needs_you_sort.dart';
import '../models/storyline_models.dart';
import '../services/attention.dart';
import '../services/calendar/calendar_zone.dart';
import '../services/calendar/day_items.dart';
import '../services/decision/needs_you_predicate.dart';
import '../services/llm/storyline_tasks.dart' show NameStorylineTask;
import '../services/profile_photos.dart';
import '../services/sender_display.dart';
import '../theme/tokens.dart';
import 'bond_avatar.dart';
import 'clock_tick.dart';
import 'dismissed_storylines_fold.dart';
import 'find_filter.dart';
import 'people_rooms.dart';
import 'possible_storylines_fold.dart';
import 'processing_hint.dart';
import 'scheduling_ask_rows.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// The app's destinations, and the icon rail's vocabulary.
///
/// [RailSection.home] leads because it is where the app lands, and because it
/// is the only one that is about the pipeline rather than about a pile of
/// mail. [RailSection.ai] trails because it is the only one that is about the
/// app rather than about anything in the mailbox.
///
/// [RailSection.archive] keeps its enum name and is LABELLED 'Later', and
/// [RailSection.home] keeps its own and is LABELLED 'Inbox', for one reason:
/// the column `archive` reads is `bucket = 'later'`, and `home` is spelled in
/// providers, intents and tests from one end of the app to the other —
/// renaming either constant would rename it everywhere.
///
/// [RailSection.files] sits between People and Later because it is the last of
/// the piles that are about the MAIL rather than about the app: everything
/// above it is a way of asking who owes what, and this one asks where a
/// document went.
///
/// [RailSection.drafts] is the one destination that is NOT a stop on the icon
/// rail. It is a row in the Inbox stack — see `IconRail.stops`, which is an
/// explicit list and does not contain it — because what it holds is the
/// model's unsent work rather than a pile of mail, and a ninth icon for a
/// list that is usually empty would cost a permanent stop for an occasional
/// one. While its pane is up the icon rail lights Inbox, which is the stack the
/// row lives in.
///
/// [RailSection.day] sits right after Needs You: once a reader knows what they
/// owe, the next question is what is coming — the calendar's day, with the
/// deadlines and the returns from Later merged into it.
enum RailSection {
  home,
  needsYou,
  day,
  drafts,
  storylines,
  people,
  files,
  archive,
  ai
}

extension RailSectionLabel on RailSection {
  String get label => switch (this) {
        // 'Inbox' where the enum says `home`, exactly as `archive` is labelled
        // 'Later': the constant is spelled through the whole codebase and the
        // word a reader sees is the one that had to change.
        RailSection.home => 'Inbox',
        RailSection.needsYou => 'Needs You',
        RailSection.day => 'Day',
        RailSection.drafts => 'Drafts & sent',
        RailSection.storylines => 'Storylines',
        RailSection.people => 'People',
        RailSection.files => 'Files',
        RailSection.archive => 'Later',
        RailSection.ai => 'AI',
      };
}

/// Repeated leading Re:/Fw:/Fwd:, however they are cased and spaced.
final RegExp _replyPrefix = RegExp(r'^\s*(re|fw|fwd)\s*:\s*', caseSensitive: false);

String _stripReplyPrefixes(String subject) {
  var out = subject;
  while (true) {
    final match = _replyPrefix.firstMatch(out);
    if (match == null) break;
    out = out.substring(match.end);
  }
  return out.trim();
}

/// Whether one thread is the user's to answer.
///
/// THE predicate the two halves of the live inbox partition on: Needs You is
/// everything this returns true for, and every live thread it returns false
/// for is what is left over — the rows People's rooms are built from.
/// One function rather than a filter in each, because two filters that were
/// meant to be complements are two filters that will eventually disagree — and
/// the symptom is mail in both sections, or in neither.
///
/// Three tests: nothing deferred to Later, which is the whole point of Later;
/// nothing already closed; and the thread's needs-you probability
/// ([Conversation.needsYouP], the decision model's highest p over the kept
/// inbound the owner has not answered) at or above [threshold], the owner's
/// slider ([needsYouAt]). Nothing else gates: not triage's ask, not the
/// thread's `needs_reply` state, not the attention score, which only ORDERS
/// the rows ([needsYouRows]). An undecided thread (a null probability) needs
/// nobody until the model has read it.
///
/// The store spells the same rule once in SQL for the tile and the Needs You
/// filter, over the same probability expression, so the rail and the tile
/// cannot count different threads.
bool isNeedsYou(
  Conversation c, {
  double threshold = NeedsYouTuning.defaultThreshold,
}) {
  if (c.bucket == 'later') return false;
  if (c.state == ConversationState.done) return false;
  return needsYouAt(c.needsYouP, threshold);
}

/// What the user is on the hook for, loudest first — [isNeedsYou], sorted.
///
/// The sort is the attention score, which ORDERS here and nowhere gates. There
/// is no second "waiting on somebody else" block: a thread with no kept
/// inbound after the owner's last reply has no probability
/// ([Conversation.needsYouP] is NULL), so it can never be here to rank. Ties
/// keep input order, so the store's newest-first ordering shows through and
/// the list does not reshuffle between reads.
List<Conversation> needsYouRows(
  List<Conversation> all, {
  double threshold = NeedsYouTuning.defaultThreshold,
}) {
  final rows = <(int, Conversation)>[];
  var index = 0;
  for (final c in all) {
    if (!isNeedsYou(c, threshold: threshold)) continue;
    rows.add((index++, c));
  }

  rows.sort((a, b) {
    final byScore =
        (b.$2.attentionScore ?? 0).compareTo(a.$2.attentionScore ?? 0);
    if (byScore != 0) return byScore;
    // Dart's sort is not stable, so the original position is carried through
    // and used as the final tie-break rather than trusted implicitly.
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, c) in rows) c];
}

/// Every live thread the user does not owe an answer: resolved ones dropped,
/// deferred ones dropped, and everything Needs You claimed dropped.
///
/// The complement of [isNeedsYou], not a second opinion about it — exactly one
/// half claims each thread, so the counts on the rail add up and nothing is
/// asked for twice. Since it is the complement at the SAME [threshold], a
/// thread the slider cut out of Needs You lands here rather than nowhere: that
/// is what makes turning the slider up safe. The mail moves out of Needs You
/// and into its sender's room, it never disappears.
List<Conversation> conversationRows(
  List<Conversation> all, {
  double threshold = NeedsYouTuning.defaultThreshold,
}) =>
    [
      for (final c in all)
        if (c.state != ConversationState.done &&
            c.bucket != 'later' &&
            !isNeedsYou(c, threshold: threshold))
          c,
    ];

/// Everything deferred, in the order it was handed over.
///
/// Done threads are excluded: a thread the user closed is finished, not waiting
/// for a quieter moment, and leaving it in Later would make the digest a place
/// mail goes to be forgotten twice.
List<Conversation> laterRows(List<Conversation> all) => [
      for (final c in all)
        if (c.bucket == 'later' && c.state != ConversationState.done) c,
    ];

/// Deferred threads grouped by the local day of their last message, newest day
/// first, as `(dayKey, count)`.
///
/// The rail shows the days and the digest shows the mail. A count per day is
/// the smallest thing that can honestly say "nothing is being hidden from you":
/// it is visibly there, it says how much, and one tap opens all of it.
///
/// Threads whose timestamp does not parse are grouped under the empty key,
/// which sorts last and still renders — they are deferred mail like any other,
/// and dropping them would be the one thing Later must never do.
List<(String, int)> laterDayCounts(List<Conversation> all) {
  final counts = <String, int>{};
  for (final c in laterRows(all)) {
    final key = dayKeyOfIso(c.lastMessageAt) ?? '';
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final keys = counts.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final key in keys) (key, counts[key]!)];
}

/// The rail's label for one Later day row. Falls back to the raw key, and then
/// to "Undated", so a row always says something.
String laterDayLabel(String dayKey, int count) {
  final label = formatDayLabel(dayKey) ?? (dayKey.isEmpty ? 'Undated' : dayKey);
  return '$label — $count';
}

/// Storylines in rail order: everything still waiting on an answer first,
/// then everything live. Input order is preserved within each half — the store
/// already sorts proposals newest-first and live ones by recent activity, and
/// re-sorting here would be a second opinion about the same thing.
///
/// Archived storylines never reach the rail, and neither dismissed nor
/// possible ones reach THIS list; the store's default query returns none of
/// them. Those two arrive separately, as [AppRail.dismissed] and
/// [AppRail.possible], and the rail shows each under a fold of its own.
List<Storyline> storylineRows(List<Storyline> all) => [
      for (final s in all)
        if (s.isSuggested) s,
      for (final s in all)
        if (!s.isSuggested) s,
    ];

/// Only the threads from [source], or all of them when it is null.
///
/// Applied by the screen ONCE, before the rail and the overviews are handed a
/// list, rather than by each of them: every count on the rail — Needs You's
/// badge, Later's day rows — is derived from the list it is given, and a
/// filter applied in some places and not others would put a badge over a
/// section that renders fewer rows than it claims.
List<Conversation> bySource(List<Conversation> all, String? source) {
  if (source == null) return all;
  return [
    for (final c in all)
      if (c.source == source) c,
  ];
}

/// Only the storylines holding at least one thread from [source], or all of
/// them when it is null — `bySource` for storylines. A storyline with no
/// members yet has no source to match and is hidden under a pill, the way an
/// empty section is.
///
/// Applied by the screen ONCE, for `bySource`'s reason: the rail, the overview
/// and Find must agree about which rows exist under a pill.
List<Storyline> storylinesBySource(List<Storyline> all, String? source) {
  if (source == null) return all;
  return [
    for (final s in all)
      if (s.sources.contains(source)) s,
  ];
}

/// The one line a rail row has room for. Who it is beats what it is about:
/// at 260px a subject truncates to nothing useful, a name does not.
///
/// A chat is marked with a leading glyph and mail is not — see
/// `withSourceGlyph`. At this width the participant's name is often all the
/// two have to tell them apart, and the same colleague can be on both.
String railTitleFor(Conversation c) {
  final who = displaySenderName(
    name: c.primaryParticipant?.name,
    address: c.primaryParticipant?.email,
    // Empty rather than a word, so a row with nobody showable falls through to
    // its subject exactly as it did before. A chat participant's address is a
    // `teams:<id>` and is never the thing that falls through.
    fallback: '',
  );
  if (who.isNotEmpty) return withSourceGlyph(c.source, who);
  final subject = _stripReplyPrefixes(c.subject ?? '');
  if (subject.isNotEmpty) return withSourceGlyph(c.source, subject);
  return withSourceGlyph(c.source, '(no subject)');
}

/// The one line a Needs You row has room for — the ASK, not the person.
///
/// The opposite priority to [railTitleFor], and deliberately: a People room is
/// answering "who", and Needs You is answering "what do I owe". A column of
/// seven rows that all read the same colleague's name is a list the user has
/// to open one at a time to use; a column of asks can be read.
///
/// The ask first, because triage wrote it in the sender's terms. Then the
/// subject, which is what the mail itself called it. Only then the person,
/// which is what [railTitleFor] would have said all along — and in that last
/// case the row is already the person, so [needsYouWhoFor] adds nothing.
String needsYouTitleFor(Conversation c) {
  final ask = c.ctaText?.trim() ?? '';
  if (ask.isNotEmpty) return ask;
  final subject = _stripReplyPrefixes(c.subject ?? '');
  if (subject.isNotEmpty) return subject;
  return railTitleFor(c);
}

/// The dimmed `' · who'` a Needs You row carries after its ask, or null when
/// the row is ALREADY the person and repeating them would be noise.
String? needsYouWhoFor(Conversation c) {
  final who = displaySenderName(
    name: c.primaryParticipant?.name,
    address: c.primaryParticipant?.email,
    // Empty rather than a word, so a row with nobody showable falls through to
    // its subject exactly as it did before. A chat participant's address is a
    // `teams:<id>` and is never the thing that falls through.
    fallback: '',
  );
  if (who.isEmpty) return null;
  final title = needsYouTitleFor(c);
  if (title == who || title == withSourceGlyph(c.source, who)) return null;
  return ' · $who';
}

/// The list column: what is inside the destination the icon rail is pointing
/// at, one line per thing, under whatever [header] the screen hands down.
///
/// TWO shapes, chosen by [scope]. On Home it is the whole stack — Needs You,
/// Storylines, People, Later — each collapsible, which is the overview the old
/// single rail was. On any other stop it is that one section, expanded, with
/// no chevron: the user picked it on the icon rail, and a column that let them
/// close the only thing in it would be a column that could show nothing.
///
/// The rail owns only its collapse state. Selection lives on the screen, so
/// the rail can be rebuilt from scratch on any data change without losing the
/// user's place.
class AppRail extends StatefulWidget {
  /// The Storylines header's New storyline control, absent unless
  /// [onNewStoryline] is given.
  static const Key newStorylineKey = ValueKey('storyline-new');

  /// The Day column's Scheduling asks header label, and its chevron.
  static const Key asksHeaderKey = ValueKey('rail-asks-header');
  static const Key asksChevronKey = ValueKey('rail-asks-chevron');

  final List<Conversation> conversations;

  /// Suggestions and live storylines together, suggestions first. Empty is
  /// the normal state before the clustering pass has run, and the section
  /// says so rather than going blank.
  final List<Storyline> storylines;

  /// The storylines the user said no to, folded away under the live ones.
  ///
  /// Dismissing was the one storyline decision that had no way back: the row
  /// left the rail and nothing on screen remembered it. The list is folded
  /// because it is history rather than a queue — nothing here is asking for
  /// anything — but it is reachable, and every row in it can be restored.
  final List<Storyline> dismissed;

  /// The groups the sweep built and the model declined to vouch for, folded
  /// away between the live storylines and the dismissed ones.
  ///
  /// They ask the same Keep or Dismiss question a suggestion does, softly:
  /// nothing vouched for these, so they sit under a heading of their own
  /// rather than competing with the rows that are actually offering
  /// something. See [PossibleStorylinesFold].
  final List<Storyline> possible;

  /// The open thread, when one is open.
  final String? selectedId;

  /// The open thread's connector. A conversation key is unique only within one
  /// source, so a bare [selectedId] can match a row from the other connector
  /// and highlight it too. Null keeps the id-only comparison, which is what a
  /// host with a single connector wants.
  final String? selectedSource;

  /// The open storyline, when one is open. Never set at the same time as
  /// [selectedId] — the main pane shows one thing.
  final String? selectedStorylineId;

  /// The section whose overview is showing. Null while a thread is open.
  final RailSection? selectedSection;

  /// The Later day whose digest is showing, as a `yyyy-mm-dd` key. Never set
  /// at the same time as [selectedId] or [selectedStorylineId].
  final String? selectedLaterDay;

  /// How much is deferred, in total. A grey badge on Later, hidden at zero.
  /// Passed in rather than counted from [conversations] so the rail can show a
  /// total the screen computed once for both the badge and the digest.
  final int laterCount;

  /// `(dayKey, count)` per deferred day, newest first — one row each under
  /// Later. Empty with a non-zero [laterCount] is a host that chose not to
  /// break the pile down; the section still badges.
  final List<(String, int)> laterDays;

  /// The owner's Needs You slider: the needs-you probability a thread must
  /// reach to appear in Needs You ([isNeedsYou]). A host with no slider gets
  /// the default.
  final double needsYouThreshold;

  /// When this session started. A row whose last message arrived after it and
  /// whose thread still has work queued renders quiet — see [showsProcessing].
  /// Null, the default, shows no processing state at all.
  final DateTime? processingSince;

  /// The row's source travels with its id: the host cannot resolve one from
  /// the other, because both connectors mint keys with no knowledge of each
  /// other and a shared key would otherwise open whichever thread the host
  /// happened to scan first.
  final void Function(String source, String conversationId) onSelectConversation;
  final void Function(RailSection section) onSelectSection;

  /// Opens one day's Later digest. Null leaves the day rows unclickable, which
  /// is what a host that does not render a digest wants.
  final void Function(String dayKey)? onSelectLaterDay;

  /// Null hides the storyline affordances entirely, which is what a host that
  /// does not carry storylines wants.
  final void Function(String storylineId)? onSelectStoryline;
  final void Function(String storylineId)? onKeepSuggestion;
  final void Function(String storylineId)? onDismissSuggestion;

  /// Opens the pane where a person declares a storyline from a title and a
  /// description, with no thread in it yet. Null renders no such control at
  /// all, the way the three above do.
  final VoidCallback? onNewStoryline;

  /// The section caption, compose, refresh, the source chips and the triage
  /// line — built by the screen, drawn by the rail at the TOP of the column.
  ///
  /// At the top rather than the foot because it is about the list under it:
  /// which pile this is, how to add to it, how to bring it up to date. The
  /// foot is empty now, which is what the footer was crowding.
  final Widget header;

  /// Which stop the column is showing. [RailSection.home] is the whole stack;
  /// anything else is that one section on its own.
  final RailSection scope;

  /// The People rooms, already grouped by the screen — see [peopleRooms]. The
  /// rail renders them and never computes them: the grouping needs the signed
  /// in account, which is the screen's to know.
  final List<PersonRoom> rooms;

  final void Function(String roomKey) onSelectRoom;

  /// The open room, when one is open.
  final String? selectedRoomKey;

  /// Faces for the 1:1 rooms. Null renders initials, which is what a host with
  /// no directory behind it wants.
  final ProfilePhotos? photos;

  /// The Find needle, live off the header's field. Empty — the default — shows
  /// the whole column.
  ///
  /// It narrows what is DRAWN and never what is COUNTED: the Needs You badge
  /// still reads the whole pile. A filter changes what you can see, never what
  /// you owe, and a badge that shrank while the reader typed would let them
  /// hide their own work by mistyping a name.
  final String find;

  /// What `is:external` in [find] measures against — see
  /// [conversationMatches]. Empty, the default, makes that facet match
  /// nothing, which is what it matched before it existed.
  final Set<String> ownerDomains;

  /// Whether to draw only rows with something unread on them. Threads and
  /// rooms answer to it; storylines do not — a storyline is not read or
  /// unread, and hiding one under a filter about mail would make the toggle
  /// mean two things.
  final bool unreadOnly;

  /// How many threads carry a suggestion waiting to be sent — the badge on the
  /// Drafts & sent row. Zero hides it. Passed in rather than counted here for
  /// the reason [laterCount] is: the pane and the badge must be counting the
  /// same list, and the screen is what holds it.
  final int pendingDraftCount;

  /// Which shelf the Files stop is showing. Held by the screen's provider
  /// rather than here, because the pane's own pills change the same fact and
  /// two controls holding one answer is how they come to disagree.
  final FilesKind filesKind;

  /// Null leaves the four rows drawn but inert, the rule every other row on
  /// this rail follows.
  final ValueChanged<FilesKind>? onSelectFilesKind;

  /// Puts a dismissed storyline back as a suggestion. Null leaves the fold's
  /// Restore buttons inert.
  final void Function(String storylineId)? onRestoreStoryline;

  /// The Possible fold's three: accept one, let one go, or open one to read
  /// its threads first. Null leaves that control inert, the rule every other
  /// row on this rail follows.
  final void Function(String storylineId)? onKeepPossible;
  final void Function(String storylineId)? onDismissPossible;
  final void Function(String storylineId)? onOpenPossible;

  /// How the Needs You rows are ordered. The screen holds the preference and
  /// hands the same value to the overview and to [firstFindTarget], because
  /// the three have to draw one pile in one order — the `+N more` row opens
  /// the list the rail was showing, and Enter opens the row under the eyes.
  final NeedsYouSort needsYouSort;

  /// Whether the Day column draws the calendar at all — the host passes
  /// `calendarShowsMirror`. False shows "Calendar not connected" and no rows.
  final bool calendarShown;

  /// Whether the Inbox stack carries its Today section — the host passes
  /// `calendarShowsToday`, which stays false until a tick has answered.
  final bool todayShown;

  /// What is still ahead today, at most three (`remainingToday`).
  final List<CalendarEvent> todayMeetings;

  /// Brief glances by event id, each drawn under its Today meeting row so
  /// the morning look at the rail already says where each meeting stands.
  /// Model output, so plain text.
  final Map<String, String> todayGlances;

  /// The display zone the Today rows' times are read in. Null draws no
  /// meeting rows: a time printed in the wrong zone is worse than none.
  final CalendarZone? calendarZone;

  /// The host's clock reading for this build, so the countdowns and the
  /// pane agree about what time it is.
  final DateTime? now;

  /// Invites still owed an answer, a series counted once. Zero hides the
  /// Invites row.
  final int invitesCount;

  /// The Day column's rows, `(day, summary)` — `upcomingDays`.
  final List<(CalendarDate, DaySummary)> dayRows;

  /// Today in the display zone. Null draws no day rows.
  final CalendarDate? today;

  /// The day the Day pane is showing; null is today.
  final CalendarDate? selectedDay;

  /// Whether the Day pane is showing the invites rather than a day.
  final bool showingInvites;

  /// Opens one day in the Day pane. Null leaves the day rows inert.
  final void Function(CalendarDate day)? onSelectDay;

  /// Opens the invites list. Null leaves the Invites rows inert.
  final VoidCallback? onOpenInvites;

  /// Opens one event beside the main pane, by its Graph id. Null sends a
  /// Today meeting row to the Day stop instead, so the row still goes
  /// somewhere on a host that has no side panel to open it in.
  final void Function(String eventId)? onOpenEvent;

  /// The threads asking for a time, drawn as the Day column's **Scheduling
  /// asks · N** section above the days. Built by the host, which owns each
  /// row's search; empty, or a calendar not shown, draws no section.
  final List<SchedulingAskRow> schedulingAsks;

  /// What an ask row's presses do. Null, or a null [calendarZone], draws the
  /// folded heads only and nothing opens — a convenience for a test about
  /// the section rather than the rows.
  final SchedulingAskCallbacks? askCallbacks;

  const AppRail({
    super.key,
    required this.conversations,
    required this.selectedId,
    required this.selectedSection,
    this.selectedSource,
    required this.onSelectConversation,
    required this.onSelectSection,
    this.storylines = const [],
    this.dismissed = const [],
    this.possible = const [],
    this.selectedStorylineId,
    this.selectedLaterDay,
    this.laterCount = 0,
    this.laterDays = const [],
    this.needsYouThreshold = NeedsYouTuning.defaultThreshold,
    this.processingSince,
    this.onSelectStoryline,
    this.onSelectLaterDay,
    this.onKeepSuggestion,
    this.onDismissSuggestion,
    this.onNewStoryline,
    required this.header,
    required this.scope,
    required this.rooms,
    required this.onSelectRoom,
    this.selectedRoomKey,
    this.photos,
    this.find = '',
    this.ownerDomains = const {},
    this.unreadOnly = false,
    this.pendingDraftCount = 0,
    this.filesKind = FilesKind.all,
    this.onSelectFilesKind,
    this.onRestoreStoryline,
    this.onKeepPossible,
    this.onDismissPossible,
    this.onOpenPossible,
    this.needsYouSort = NeedsYouSort.priority,
    this.calendarShown = false,
    this.todayShown = false,
    this.todayMeetings = const [],
    this.todayGlances = const {},
    this.calendarZone,
    this.now,
    this.invitesCount = 0,
    this.dayRows = const [],
    this.today,
    this.selectedDay,
    this.showingInvites = false,
    this.onSelectDay,
    this.onOpenInvites,
    this.onOpenEvent,
    this.schedulingAsks = const [],
    this.askCallbacks,
  });

  /// Fixed: the rail is a landmark, not a resizable pane.
  static const double width = 260;

  /// The key of a Today meeting's brief glance.
  static Key todayGlanceKeyFor(String eventId) =>
      ValueKey('today-glance-$eventId');

  @override
  State<AppRail> createState() => _AppRailState();
}

class _AppRailState extends State<AppRail> {
  /// Everything starts open. A section the user closed stays closed for the
  /// life of the screen.
  final Set<RailSection> _collapsed = {};

  /// The Day column's Scheduling asks, folded to their header. Its own flag
  /// rather than a member of [_collapsed]: the asks share the Day stop's
  /// section with the days, and closing one must not close the other.
  bool _asksCollapsed = false;

  static const double _rowHeight = 32;

  void _toggle(RailSection section) {
    setState(() {
      if (!_collapsed.remove(section)) _collapsed.add(section);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppRail.width,
      child: Material(
        color: BondColors.rail,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.header,
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  vertical: BondSpacing.s12,
                ),
                children: _stack(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the column holds, for the scope it is showing.
  ///
  /// Home is the stack in the order the day is worked: what you owe, what it
  /// belongs to, who it is with, what you put off. Every other scope is one
  /// section, and it does not collapse.
  List<Widget> _stack() {
    switch (widget.scope) {
      case RailSection.home:
      // Drafts & sent is a ROW in the Home stack rather than a stop of its
      // own, so standing on it keeps the whole stack in the column with its
      // header highlighted — the reader has not gone anywhere, they have
      // opened one of the things that was already in front of them.
      case RailSection.drafts:
        return [
          ..._needsYouSection(),
          ..._todaySection(),
          ..._draftsSection(),
          ..._storylinesSection(),
          ..._peopleSection(),
          ..._laterSection(),
        ];
      case RailSection.needsYou:
        return _needsYouSection(collapsible: false);
      case RailSection.day:
        return [..._asksSection(), ..._daySection()];
      case RailSection.storylines:
        return _storylinesSection(collapsible: false);
      case RailSection.people:
        return _peopleSection(collapsible: false);
      case RailSection.files:
        return _filesSection();
      case RailSection.archive:
        return _laterSection(collapsible: false);
      case RailSection.ai:
        // The AI stop's pane IS the settings screen; there is no list of
        // anything to put beside it, and a column that repeated the pane's own
        // section names would be a second table of contents for one screen.
        return [
          _header(RailSection.ai, badge: null, collapsed: false,
              collapsible: false),
          _placeholder('Models, rules and the log'),
        ];
    }
  }

  List<Widget> _needsYouSection({bool collapsible = true}) {
    // Ordered BEFORE the filtering, which is itself before the truncation.
    // Both edges matter: `+N more` has to open the list in the order the rail
    // showed, and Enter has to open the row the reader is looking at — so the
    // order is applied to the whole pile and everything downstream narrows it.
    final needsYou = sortNeedsYou(
      widget.needsYouSort,
      needsYouRows(
        widget.conversations,
        threshold: widget.needsYouThreshold,
      ),
    );

    // Filtered BEFORE the truncation, and the order matters twice over. It is
    // what makes Find useful at all — cutting to five and then filtering would
    // search the top five rather than the pile — and it is the whole reason
    // `firstFindTarget` can promise Enter opens the row under the reader's
    // eyes.
    final needle = normalizeFind(widget.find);
    final matching = [
      for (final c in needsYou)
        if (conversationMatches(c, needle,
                ownerDomains: widget.ownerDomains) &&
            (!widget.unreadOnly || c.hasUnread))
          c,
    ];

    // The badge counts everything that qualified — UNFILTERED — and the list
    // shows the top handful of what survived. A badge that agreed with the
    // truncated list would understate the work, which is the one number in the
    // rail that must not be flattering; a badge that shrank as the reader
    // typed would let them hide their own work by mistyping a name.
    final shown = matching.length > AttentionTuning.topCount
        ? matching.sublist(0, AttentionTuning.topCount)
        : matching;
    final overflow = matching.length - shown.length;

    return _section(
      RailSection.needsYou,
      collapsible: collapsible,
      rows: [
        for (final c in shown)
          _item(
            c,
            // Bold is unread here as everywhere (D5). What makes a Needs You
            // row loud is the badge over the section, the accent dot on the
            // row and the ask in its own words — three signals that say
            // "yours", instead of one that also has to mean "new".
            bold: c.hasUnread,
            processing: showsProcessing(c, since: widget.processingSince),
          ),
        if (overflow > 0) _more(overflow),
      ],
      badge: needsYou.isEmpty ? null : _badge(needsYou.length, attention: true),
    );
  }

  /// A header row and nothing under it: the PANE is the list of drafts, and a
  /// column that repeated it would be a second copy of the same list, one of
  /// them always a beat behind the other. So this section is a link — with a
  /// count on it, which is the one thing a link can usefully say.
  ///
  /// Neither Find nor the unread toggle touches it. There is nothing here to
  /// narrow, and a row that vanished while the reader typed a colleague's name
  /// would take the way into the pane with it.
  List<Widget> _draftsSection() => _section(
        RailSection.drafts,
        collapsible: false,
        rows: const [],
        badge: widget.pendingDraftCount == 0
            ? null
            : _badge(widget.pendingDraftCount, attention: false),
      );

  List<Widget> _storylinesSection({bool collapsible = true}) {
    final needle = normalizeFind(widget.find);
    final onNew = widget.onNewStoryline;
    return _section(
      RailSection.storylines,
      collapsible: collapsible,
      // The one door into a storyline a person declares before anything is in
      // it. It sits on the section header because that is where the list it
      // adds to is, and it is absent rather than inert when the host has no
      // handler for it.
      action: onNew == null
          ? null
          : _storylineAction(
              Icons.add,
              'New storyline',
              onNew,
              key: AppRail.newStorylineKey,
            ),
      rows: [
        for (final s in storylineRows(widget.storylines))
          if (storylineMatches(s, needle)) _storylineItem(s),
        // Between the live rows and the dismissed ones, behind a fold of its
        // own: the model found these groups and would not vouch for them, so
        // they ask more quietly than a suggestion and more loudly than
        // history. Not narrowed by Find, for the dismissed fold's reason.
        if (widget.possible.isNotEmpty)
          PossibleStorylinesFold(
            possible: widget.possible,
            onKeep: widget.onKeepPossible,
            onDismiss: widget.onDismissPossible,
            onOpen: widget.onOpenPossible,
            fill: BondColors.rail,
          ),
        // Under both, and behind a fold: what the user already said no to must
        // not compete with what is still asking. Not narrowed by Find — a
        // dismissed suggestion is not a place to go.
        if (widget.dismissed.isNotEmpty)
          DismissedStorylinesFold(
            dismissed: widget.dismissed,
            onRestore: widget.onRestoreStoryline,
            fill: BondColors.rail,
          ),
      ],
      placeholder: 'Suggestions arrive after processing',
    );
  }

  List<Widget> _peopleSection({bool collapsible = true}) {
    final needle = normalizeFind(widget.find);
    return _section(
      RailSection.people,
      collapsible: collapsible,
      rows: [
        for (final room in widget.rooms)
          if (roomMatches(room, needle) &&
              (!widget.unreadOnly || room.unread > 0))
            _roomItem(room),
      ],
      placeholder: 'Nobody yet',
    );
  }

  /// The four shelves, as rows.
  ///
  /// No counts on them, unlike Later's days: a count per kind is a fourth
  /// query for a number nobody acts on, and the pane's own pills already say
  /// which shelf is up. It does not collapse, because it IS the column here —
  /// a chevron that emptied it would be an affordance that lied.
  ///
  /// Neither Find nor the unread toggle touches it, on the drafts section's
  /// precedent: there is nothing here to narrow, and a row that vanished while
  /// the reader typed a colleague's name would take the way into a shelf with
  /// it.
  List<Widget> _filesSection() => _section(
        RailSection.files,
        collapsible: false,
        rows: [
          for (final kind in FilesKind.values) _filesKindItem(kind),
        ],
      );

  Widget _filesKindItem(FilesKind kind) {
    final selected = kind == widget.filesKind;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        key: ValueKey('files-kind-${kind.name}'),
        color: selected ? BondColors.onDarkTint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: widget.onSelectFilesKind == null
              ? null
              : () => widget.onSelectFilesKind!(kind),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  kind.label,
                  style: BondType.small.copyWith(
                    color: selected
                        ? BondColors.onDarkPrimary
                        : BondColors.onDarkSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Later's day rows, unless the reader is finding something.
  ///
  /// A day is not findable: it has no title to match, and leaving the rows
  /// there under a needle nothing in them answers would be the one section
  /// that ignored the filter. The header and its badge stay — the pile is
  /// still there, and saying how much is deferred is not a search result.
  /// The unread toggle leaves it alone: deferred mail is deferred whether or
  /// not it has been read.
  List<Widget> _laterSection({bool collapsible = true}) => _section(
        RailSection.archive,
        collapsible: collapsible,
        rows: [
          if (normalizeFind(widget.find).isEmpty)
            for (final (dayKey, count) in widget.laterDays)
              _laterDayItem(dayKey, count),
        ],
        // Deferred mail only, though the section now holds done threads too:
        // a done pile grows without bound and asks nothing of anyone, and
        // badging it would put a number on the rail that never goes back down.
        badge: widget.laterCount == 0
            ? null
            : _badge(widget.laterCount, attention: false),
        // Only when there is genuinely nothing deferred, and never while a
        // needle is up: a pile with no day breakdown must not read as an empty
        // one, and neither must a pile whose rows are merely being filtered
        // past.
        placeholder:
            widget.laterCount == 0 && normalizeFind(widget.find).isEmpty
                ? 'Nothing deferred yet'
                : null,
      );

  /// The Day column's threads asking for a time, above the days.
  ///
  /// The header and its chevron both fold the rows away and bring them back:
  /// the section is dismissable without being lost, and its count stays in
  /// view while it is folded. Neither selects anything, since the Day stop is
  /// already where the reader is. Not narrowed by Find, the day rows' rule.
  List<Widget> _asksSection() {
    if (!widget.calendarShown || widget.schedulingAsks.isEmpty) {
      return const [];
    }
    void toggle() => setState(() => _asksCollapsed = !_asksCollapsed);
    final zone = widget.calendarZone;
    final callbacks = widget.askCallbacks;
    return [
      _header(
        RailSection.day,
        label: 'Scheduling asks · ${widget.schedulingAsks.length}',
        badge: null,
        collapsed: _asksCollapsed,
        collapsible: true,
        onLabelTap: toggle,
        onChevronTap: toggle,
        labelKey: AppRail.asksHeaderKey,
        chevronKey: AppRail.asksChevronKey,
        highlight: false,
      ),
      if (!_asksCollapsed)
        for (final row in widget.schedulingAsks)
          if (zone != null && callbacks != null)
            SchedulingAskTile(
              key: ValueKey('ask-tile-${row.source}|${row.key}'),
              row: row,
              zone: zone,
              callbacks: callbacks,
            )
          else
            _calendarRow(label: row.subject, selected: false, onTap: null),
      const SizedBox(height: BondSpacing.s12),
    ];
  }

  /// The Day stop's column: the invites row, then one row per upcoming day.
  ///
  /// Neither Find nor the unread toggle touches it. A day is not a thread, and
  /// a column of days that thinned out while the reader typed a name would say
  /// their Thursday had emptied.
  ///
  /// Not collapsible: the days are what the stop is for, and the asks section
  /// above it has its own chevron.
  List<Widget> _daySection() {
    final today = widget.today;
    final rows = <Widget>[
      if (widget.calendarShown && widget.invitesCount > 0)
        _calendarRow(
          label: 'Invites · ${widget.invitesCount}',
          selected: widget.showingInvites && widget.scope == RailSection.day,
          onTap: widget.onOpenInvites,
        ),
      if (widget.calendarShown && today != null)
        for (final (day, summary) in widget.dayRows)
          _calendarRow(
            label: dayRowLabel(day, today, summary),
            selected: widget.scope == RailSection.day &&
                !widget.showingInvites &&
                (widget.selectedDay ?? today) == day,
            onTap: widget.onSelectDay == null
                ? null
                : () => widget.onSelectDay!(day),
          ),
    ];
    return _section(
      RailSection.day,
      collapsible: false,
      rows: rows,
      placeholder: widget.calendarShown ? null : 'Calendar not connected',
    );
  }

  /// The Inbox stack's slice of the calendar: what is still ahead today, and
  /// the invites owed. Only once a tick has said the calendar is there — see
  /// [AppRail.todayShown] — so the stack does not grow a section and lose it
  /// again on a launch whose first answer is "no calendar".
  ///
  /// A meeting row opens the event panel beside whatever the main pane is
  /// showing — the reader glancing at "what's next" wants the meeting, not a
  /// change of stop. Without [AppRail.onOpenEvent] it falls back to the Day
  /// stop, which is the next best answer to the same question.
  List<Widget> _todaySection() {
    if (!widget.todayShown) return const [];
    final zone = widget.calendarZone;
    final now = widget.now ?? DateTime.now();
    final rows = <Widget>[
      if (zone != null)
        for (final e in widget.todayMeetings.take(3))
          if (e.startUtc != null) ...[
            _calendarRow(
              label: '${formatEventTime(zone, e.startUtc!)} · '
                  '${e.subject.trim().isEmpty ? '(no subject)' : e.subject.trim()}',
              selected: false,
              onTap: widget.onOpenEvent != null
                  ? () => widget.onOpenEvent!(e.id)
                  : () => widget.onSelectSection(RailSection.day),
              trailing: ClockTick(
                initial: now,
                builder: (_, t) => Text(
                  meetingCountdown(e, t.toUtc()) ?? '',
                  style: BondType.caption.copyWith(color: BondColors.railAccent),
                ),
              ),
            ),
            if ((widget.todayGlances[e.id] ?? '').isNotEmpty)
              _todayGlance(e.id, widget.todayGlances[e.id]!),
          ],
      if (widget.invitesCount > 0)
        _calendarRow(
          label: 'Invites · ${widget.invitesCount}',
          selected: false,
          onTap: widget.onOpenInvites,
        ),
    ];
    return _section(
      RailSection.day,
      label: 'Today',
      rows: rows,
      placeholder: 'Nothing else today',
    );
  }

  /// A brief's glance under its Today meeting row, indented to the row's
  /// label, in the placeholder's muted ink.
  Widget _todayGlance(String id, String glance) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s12 + BondSpacing.s8,
        0,
        BondSpacing.s12 + BondSpacing.s8,
        BondSpacing.s4,
      ),
      child: Text(
        glance,
        key: AppRail.todayGlanceKeyFor(id),
        style: BondType.caption.copyWith(color: BondColors.onDarkMuted),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// One calendar row — a day, the invites, a meeting — in the look of a Later
  /// day row: a label, and at most something small trailing it.
  Widget _calendarRow({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: onTap,
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: BondType.small.copyWith(
                        color: selected
                            ? BondColors.onDarkPrimary
                            : BondColors.onDarkSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _section(
    RailSection section, {
    required List<Widget> rows,
    Widget? badge,
    Widget? action,
    String? placeholder,
    bool collapsible = true,
    String? label,
  }) {
    final collapsed = collapsible && _collapsed.contains(section);
    return [
      _header(
        section,
        label: label,
        badge: badge,
        action: action,
        collapsed: collapsed,
        collapsible: collapsible,
      ),
      if (!collapsed) ...[
        ...rows,
        if (rows.isEmpty && placeholder != null) _placeholder(placeholder),
      ],
      const SizedBox(height: BondSpacing.s12),
    ];
  }

  /// The label selects the section's overview; the chevron collapses it. Two
  /// targets in one row rather than a third affordance nobody would find.
  ///
  /// [collapsible] is false when this section is the ONLY thing in the column:
  /// there is nothing for a chevron to reveal underneath it, and one that
  /// emptied the column would be an affordance that lied. The Day stop's days
  /// keep that rule even under the Scheduling asks section (see
  /// [_daySection]).
  ///
  /// [action] is a section-wide control, rendered after the badge and before
  /// the chevron — the one place in the row that is neither the label's target
  /// nor the chevron's. Null on every section but Storylines, which renders
  /// nothing extra and lays out exactly as it did.
  ///
  /// [label] overrides the section's own name on the header — the Today
  /// section is a slice of the Day stop and says so by name.
  ///
  /// [onLabelTap] and [onChevronTap] replace the two targets' usual acts —
  /// the Scheduling asks header folds itself from both, on a flag of its own
  /// — and [highlight] false keeps it from lighting up as the selected
  /// section beside the Day header that really is.
  Widget _header(
    RailSection section, {
    required Widget? badge,
    required bool collapsed,
    Widget? action,
    bool collapsible = true,
    String? label,
    VoidCallback? onLabelTap,
    VoidCallback? onChevronTap,
    Key? labelKey,
    Key? chevronKey,
    bool highlight = true,
  }) {
    final selected = highlight && widget.selectedSection == section;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: SizedBox(
          height: _rowHeight,
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  key: labelKey,
                  onTap: onLabelTap ?? () => widget.onSelectSection(section),
                  borderRadius: BondRadii.smAll,
                  hoverColor: BondColors.onDarkFaint,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BondSpacing.s8,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        (label ?? section.label).toUpperCase(),
                        style: BondType.caption.copyWith(
                          color: BondColors.onDarkMuted,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.96,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
              ?badge,
              ?action,
              if (collapsible)
                InkWell(
                  key: chevronKey,
                  onTap: onChevronTap ?? () => _toggle(section),
                  borderRadius: BondRadii.fullAll,
                  hoverColor: BondColors.onDarkFaint,
                  child: Padding(
                    padding: const EdgeInsets.all(BondSpacing.s4),
                    child: AnimatedRotation(
                      turns: collapsed ? -0.25 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: const Icon(
                        Icons.expand_more,
                        size: 16,
                        color: BondColors.onDarkMuted,
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(width: BondSpacing.s8),
            ],
          ),
        ),
      ),
    );
  }

  /// One Needs You thread, titled by the ASK — see [needsYouTitleFor] — with
  /// the person after it in quieter ink.
  ///
  /// [processing] says the model has not finished with this thread yet, and it
  /// overrides the ink: whatever the row would otherwise claim about
  /// itself is a half-formed answer, so it reads quiet — muted ink and a
  /// hollow dot — until the answer is whole.
  Widget _item(
    Conversation c, {
    required bool bold,
    bool processing = false,
  }) {
    final selected = widget.selectedId == c.id &&
        (widget.selectedSource == null || widget.selectedSource == c.source);

    // Bold is the whole grammar and it says ONE thing everywhere: you have not
    // read this. It used to mean "you owe this" in Needs You and "unread" in
    // the section under it, which is two grammars in one column — and a reader
    // who has to know which section they are looking at to read a font weight
    // is reading nothing. What Needs You owes is said by the section's badge,
    // by the accent dot on the row, and by the ask the row is titled with.
    final color = processing
        ? BondColors.onDarkMuted
        : (selected || bold)
            ? BondColors.onDarkPrimary
            : BondColors.onDarkSecondary;

    final title = needsYouTitleFor(c);
    final who = needsYouWhoFor(c);
    final style = BondType.small.copyWith(
      color: color,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
    );
    // Plain text when the row is just the person, rich only when there is a
    // suffix to quieten: a Text with data on it is what every finder in the
    // suite reads, and a RichText where one is not needed would cost that for
    // nothing.
    final label = who == null
        ? Text(
            title,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        : Text.rich(
            TextSpan(
              text: title,
              style: style,
              children: [
                TextSpan(
                  text: who,
                  style: style.copyWith(
                    color: BondColors.onDarkMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: () => widget.onSelectConversation(c.source, c.id),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: BondSpacing.s8,
              ),
              child: Row(
                children: [
                  Container(
                    width: BondSpacing.s8,
                    height: BondSpacing.s8,
                    // Hollow while the model works: the dot is the row's claim
                    // about itself, and an outline is that claim not filled in
                    // yet.
                    decoration: processing
                        ? BoxDecoration(
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: BondColors.onDarkBorder),
                          )
                        : BoxDecoration(
                            shape: BoxShape.circle,
                            // The dot is what carries "yours" now that bold
                            // does not: filled and warm for a thread on the
                            // hook, hollow grey for one merely being watched.
                            color: isNeedsYou(
                              c,
                              threshold: widget.needsYouThreshold,
                            )
                                ? BondColors.railAccent
                                : BondColors.onDarkBorder,
                          ),
                  ),
                  const SizedBox(width: BondSpacing.s8),
                  Expanded(child: label),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One People room: a colleague, and every thread with them in it — their
  /// own, and the ones they share with four other people.
  ///
  /// A face, because a room is about WHO and a name beside their photograph is
  /// how a reader picks a row out of a column of names. The no-sender room
  /// keeps the dot: it stands for nobody, so there is no face to draw.
  ///
  /// The badge is the room's Needs You count in the attention red where there
  /// is one, and the thread count in grey where there is not — the two
  /// numbers a reader wants from a row they are deciding whether to open, and
  /// never both, because a row with two counts on it has neither.
  Widget _roomItem(PersonRoom room) {
    final selected = widget.selectedRoomKey == room.key;
    final bold = room.unread > 0;
    // Only when every thread in the room came from one connector. A person on
    // both would otherwise be marked as whichever the newest thread happened
    // to be, which is a mark that changes when nothing about them did.
    final title = room.sources.length == 1
        ? withSourceGlyph(room.sources.first, room.title)
        : room.title;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: () => widget.onSelectRoom(room.key),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Row(
                children: [
                  if (room.people.length == 1)
                    BondAvatar(
                      name: room.people.first.display,
                      address: room.people.first.email,
                      size: 20,
                      photoKey: photoKeyFor(address: room.people.first.email),
                      photos: widget.photos,
                    )
                  else
                    Container(
                      width: BondSpacing.s8,
                      height: BondSpacing.s8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: bold
                            ? BondColors.railAccent
                            : BondColors.onDarkBorder,
                      ),
                    ),
                  const SizedBox(width: BondSpacing.s8),
                  Expanded(
                    child: Text(
                      title,
                      style: BondType.small.copyWith(
                        color: (selected || bold)
                            ? BondColors.onDarkPrimary
                            : BondColors.onDarkSecondary,
                        fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (room.needsYou > 0)
                    _badge(room.needsYou, attention: true)
                  else
                    _badge(room.threads.length, attention: false),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The tail of a truncated Needs You. It opens the section rather than any
  /// one thread: the rows it stands for are ranked, and picking one for the
  /// user would be picking the wrong one.
  Widget _more(int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: () => widget.onSelectSection(RailSection.needsYou),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              // Indented past where the dots sit, so it reads as a footnote to
              // the rows above rather than as another one of them.
              padding: const EdgeInsets.only(
                left: BondSpacing.s8 + BondSpacing.s8 + BondSpacing.s8,
                right: BondSpacing.s8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '+$count more',
                  style: BondType.caption
                      .copyWith(color: BondColors.onDarkMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One deferred day. The count is in the label rather than in a badge: it is
  /// part of what the row says, not a status hanging off it.
  Widget _laterDayItem(String dayKey, int count) {
    final selected = widget.selectedLaterDay == dayKey;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: widget.onSelectLaterDay == null
              ? null
              : () => widget.onSelectLaterDay!(dayKey),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  laterDayLabel(dayKey, count),
                  style: BondType.small.copyWith(
                    color: selected
                        ? BondColors.onDarkPrimary
                        : BondColors.onDarkSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One storyline. A suggestion reads as a question — it carries the two
  /// answers rather than a count — and a live storyline reads like a thread,
  /// with the same dot-and-bold grammar the conversation rows use.
  Widget _storylineItem(Storyline storyline) {
    final selected = widget.selectedStorylineId == storyline.id;
    final suggested = storyline.isSuggested;
    final open = storyline.openCount > 0;

    final color = (selected || (!suggested && open))
        ? BondColors.onDarkPrimary
        : BondColors.onDarkSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.rail,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: widget.onSelectStoryline == null
              ? null
              : () => widget.onSelectStoryline!(storyline.id),
          borderRadius: BondRadii.smAll,
          hoverColor: BondColors.onDarkFaint,
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              child: Row(
                children: [
                  Container(
                    width: BondSpacing.s8,
                    height: BondSpacing.s8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // A suggestion is always live-coloured: it is the one
                      // row in the rail that is asking for something.
                      color: (suggested || open)
                          ? BondColors.railAccent
                          : BondColors.onDarkBorder,
                    ),
                  ),
                  const SizedBox(width: BondSpacing.s8),
                  Expanded(
                    child: Text(
                      storyline.title.isEmpty
                          ? NameStorylineTask.fallbackTitle
                          : storyline.title,
                      style: BondType.small.copyWith(
                        color: color,
                        fontWeight: (!suggested && open)
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (suggested) ...[
                    _storylineAction(
                      Icons.check,
                      'Keep',
                      widget.onKeepSuggestion == null
                          ? null
                          : () => widget.onKeepSuggestion!(storyline.id),
                    ),
                    _storylineAction(
                      Icons.close,
                      'Dismiss',
                      widget.onDismissSuggestion == null
                          ? null
                          : () => widget.onDismissSuggestion!(storyline.id),
                    ),
                  ] else if (open)
                    _badge(storyline.openCount, attention: false),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Keep / Dismiss, and the Storylines header's New storyline. Small and
  /// quiet: they sit inside a row whose main target is somewhere else — opening
  /// the storyline, or selecting the section — and a button loud enough to
  /// compete with that would get mis-tapped.
  Widget _storylineAction(
    IconData icon,
    String tooltip,
    VoidCallback? onTap, {
    Key? key,
  }) {
    return Tooltip(
      key: key,
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.fullAll,
        hoverColor: BondColors.onDarkTint,
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s4),
          child: Icon(icon, size: 16, color: BondColors.onDarkMuted),
        ),
      ),
    );
  }

  Widget _placeholder(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BondSpacing.s12 + BondSpacing.s8,
        vertical: BondSpacing.s4,
      ),
      child: Text(
        text,
        style: BondType.caption.copyWith(color: BondColors.onDarkMuted),
        maxLines: 2,
      ),
    );
  }

  /// A count pill. [attention] is the red one — reserved for work the user is
  /// holding up; everything else counts in grey.
  Widget _badge(int count, {required bool attention}) {
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s4),
      decoration: BoxDecoration(
        color: attention ? BondColors.railBadge : BondColors.onDarkTint,
        borderRadius: BondRadii.fullAll,
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: BondType.caption.copyWith(
          color: attention
              ? BondColors.onDarkPrimary
              : BondColors.onDarkSecondary,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
