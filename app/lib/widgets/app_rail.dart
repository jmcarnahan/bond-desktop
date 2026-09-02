import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../models/storyline_models.dart';
import '../services/attention.dart';
import '../theme/tokens.dart';
import 'source_glyph.dart';
import 'time_format.dart';

/// The rail's four stops.
enum RailSection { needsYou, storylines, conversations, later }

extension RailSectionLabel on RailSection {
  String get label => switch (this) {
        RailSection.needsYou => 'Needs You',
        RailSection.storylines => 'Storylines',
        RailSection.conversations => 'Conversations',
        RailSection.later => 'Later',
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
/// THE predicate the two sections partition on: Needs You is everything this
/// returns true for, Conversations is every live thread it returns false for.
/// One function rather than a filter in each, because two filters that were
/// meant to be complements are two filters that will eventually disagree — and
/// the symptom is mail in both sections, or in neither.
///
/// Three tests: nothing deferred to Later, which is the whole point of Later;
/// nothing already closed; nothing scoring below [threshold], which is what the
/// volume slider moves.
bool isNeedsYou(Conversation c, {double threshold = 0}) {
  if (c.bucket == 'later') return false;
  if (c.state == ConversationState.done) return false;
  if ((c.attentionScore ?? 0) < threshold) return false;
  return c.state == ConversationState.needsReply ||
      (c.ctaText?.isNotEmpty == true);
}

/// What the user is on the hook for, loudest first — [isNeedsYou], sorted.
///
/// The sort is needs-reply first, then score. Two blocks rather than one
/// ordering because they answer different questions: the top block is work the
/// user is holding up, the bottom is work someone else is, and a waiting thread
/// with an urgent ask must not outrank a reply the user owes however loudly it
/// scores. Ties keep input order, so the store's newest-first ordering shows
/// through and the list does not reshuffle between reads.
List<Conversation> needsYouRows(
  List<Conversation> all, {
  double threshold = 0,
}) {
  final rows = <(int, Conversation)>[];
  var index = 0;
  for (final c in all) {
    if (!isNeedsYou(c, threshold: threshold)) continue;
    rows.add((index++, c));
  }

  rows.sort((a, b) {
    final byBlock = _needsReplyRank(a.$2).compareTo(_needsReplyRank(b.$2));
    if (byBlock != 0) return byBlock;
    final byScore =
        (b.$2.attentionScore ?? 0).compareTo(a.$2.attentionScore ?? 0);
    if (byScore != 0) return byScore;
    // Dart's sort is not stable, so the original position is carried through
    // and used as the final tie-break rather than trusted implicitly.
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, c) in rows) c];
}

int _needsReplyRank(Conversation c) =>
    c.state == ConversationState.needsReply ? 0 : 1;

/// Whether a Needs You row belongs to the quieter second block — waiting on
/// somebody else, and rendered dimmed so the two halves read apart at a glance.
bool isWaitingRow(Conversation c) => c.state != ConversationState.needsReply;

/// Every live thread the user does not owe an answer: resolved ones dropped,
/// deferred ones dropped, and everything Needs You claimed dropped.
///
/// The complement of [isNeedsYou], not a second opinion about it — exactly one
/// section claims each thread, so the counts on the rail add up and nothing is
/// asked for twice. Since it is the complement at the SAME [threshold], a
/// thread the slider cut out of Needs You lands here rather than nowhere: that
/// is what makes turning the slider up safe. The mail moves down a section, it
/// never disappears.
List<Conversation> conversationRows(
  List<Conversation> all, {
  double threshold = 0,
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
/// Dismissed and archived storylines never reach the rail; the store's default
/// query does not return them.
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

/// The one line a rail row has room for. Who it is beats what it is about:
/// at 260px a subject truncates to nothing useful, a name does not.
///
/// A chat is marked with a leading glyph and mail is not — see
/// `withSourceGlyph`. At this width the participant's name is often all the
/// two have to tell them apart, and the same colleague can be on both.
String railTitleFor(Conversation c) {
  final who = c.primaryParticipant?.display ?? '';
  if (who.isNotEmpty) return withSourceGlyph(c.source, who);
  final subject = _stripReplyPrefixes(c.subject ?? '');
  if (subject.isNotEmpty) return withSourceGlyph(c.source, subject);
  return withSourceGlyph(c.source, '(no subject)');
}

/// The dark left rail: sections, one line per thread, and whatever account
/// controls the screen hands down as a [footer].
///
/// The rail owns only its collapse state. Selection lives on the screen, so
/// the rail can be rebuilt from scratch on any data change without losing the
/// user's place.
class AppRail extends StatefulWidget {
  final List<Conversation> conversations;

  /// Suggestions and live storylines together, suggestions first. Empty is
  /// the normal state before the clustering pass has run, and the section
  /// says so rather than going blank.
  final List<Storyline> storylines;

  /// The open thread, when one is open.
  final String? selectedId;

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

  /// Score a thread must reach to appear in Needs You. Zero — the default —
  /// lets everything eligible through, which is what a host with no slider
  /// wants.
  final double attentionThreshold;

  final void Function(String conversationId) onSelectConversation;
  final void Function(RailSection section) onSelectSection;

  /// Opens one day's Later digest. Null leaves the day rows unclickable, which
  /// is what a host that does not render a digest wants.
  final void Function(String dayKey)? onSelectLaterDay;

  /// Null hides the storyline affordances entirely, which is what a host that
  /// does not carry storylines wants.
  final void Function(String storylineId)? onSelectStoryline;
  final void Function(String storylineId)? onKeepSuggestion;
  final void Function(String storylineId)? onDismissSuggestion;

  /// Account block, refresh, sign-out — built by the screen, pinned to the
  /// bottom by the rail.
  final Widget? footer;

  const AppRail({
    super.key,
    required this.conversations,
    required this.selectedId,
    required this.selectedSection,
    required this.onSelectConversation,
    required this.onSelectSection,
    this.storylines = const [],
    this.selectedStorylineId,
    this.selectedLaterDay,
    this.laterCount = 0,
    this.laterDays = const [],
    this.attentionThreshold = 0,
    this.onSelectStoryline,
    this.onSelectLaterDay,
    this.onKeepSuggestion,
    this.onDismissSuggestion,
    this.footer,
  });

  /// Fixed: the rail is a landmark, not a resizable pane.
  static const double width = 260;

  @override
  State<AppRail> createState() => _AppRailState();
}

class _AppRailState extends State<AppRail> {
  /// Everything starts open. A section the user closed stays closed for the
  /// life of the screen.
  final Set<RailSection> _collapsed = {};

  static const double _rowHeight = 32;

  void _toggle(RailSection section) {
    setState(() {
      if (!_collapsed.remove(section)) _collapsed.add(section);
    });
  }

  @override
  Widget build(BuildContext context) {
    final needsYou = needsYouRows(
      widget.conversations,
      threshold: widget.attentionThreshold,
    );
    final open = conversationRows(
      widget.conversations,
      threshold: widget.attentionThreshold,
    );

    // The badge counts everything that qualified, the list shows the top
    // handful. A badge that agreed with the truncated list would understate
    // the work, which is the one number in the rail that must not be flattering.
    final shown = needsYou.length > AttentionTuning.topCount
        ? needsYou.sublist(0, AttentionTuning.topCount)
        : needsYou;
    final overflow = needsYou.length - shown.length;

    return SizedBox(
      width: AppRail.width,
      child: Material(
        color: BondColors.ink,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  vertical: BondSpacing.s12,
                ),
                children: [
                  ..._section(
                    RailSection.needsYou,
                    rows: [
                      for (final c in shown)
                        _item(c, dimmed: isWaitingRow(c), bold: true),
                      if (overflow > 0) _more(overflow),
                    ],
                    badge: needsYou.isEmpty
                        ? null
                        : _badge(needsYou.length, attention: true),
                  ),
                  ..._section(
                    RailSection.storylines,
                    rows: [
                      for (final s in storylineRows(widget.storylines))
                        _storylineItem(s),
                    ],
                    placeholder: 'Suggestions arrive after processing',
                  ),
                  ..._section(
                    RailSection.conversations,
                    rows: [for (final c in open) _item(c, bold: c.hasUnread)],
                  ),
                  ..._section(
                    RailSection.later,
                    rows: [
                      for (final (dayKey, count) in widget.laterDays)
                        _laterDayItem(dayKey, count),
                    ],
                    badge: widget.laterCount == 0
                        ? null
                        : _badge(widget.laterCount, attention: false),
                    // Only when there is genuinely nothing deferred. A pile
                    // with no day breakdown must not read as an empty one.
                    placeholder: widget.laterCount == 0
                        ? 'Nothing deferred yet'
                        : null,
                  ),
                ],
              ),
            ),
            if (widget.footer != null) ...[
              const Divider(height: 1, color: BondColors.onDarkBorder),
              widget.footer!,
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _section(
    RailSection section, {
    required List<Widget> rows,
    Widget? badge,
    String? placeholder,
  }) {
    final collapsed = _collapsed.contains(section);
    return [
      _header(section, badge: badge, collapsed: collapsed),
      if (!collapsed) ...[
        ...rows,
        if (rows.isEmpty && placeholder != null) _placeholder(placeholder),
      ],
      const SizedBox(height: BondSpacing.s12),
    ];
  }

  /// The label selects the section's overview; the chevron collapses it. Two
  /// targets in one row rather than a third affordance nobody would find.
  Widget _header(
    RailSection section, {
    required Widget? badge,
    required bool collapsed,
  }) {
    final selected = widget.selectedSection == section;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.ink,
        borderRadius: BondRadii.smAll,
        child: SizedBox(
          height: _rowHeight,
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => widget.onSelectSection(section),
                  borderRadius: BondRadii.smAll,
                  hoverColor: BondColors.onDarkFaint,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BondSpacing.s8,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        section.label.toUpperCase(),
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
              InkWell(
                onTap: () => _toggle(section),
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One thread. [dimmed] drops it to the muted ink used for the quieter half
  /// of Needs You — a thread on the list because someone else is late, not
  /// because the user is.
  Widget _item(Conversation c, {required bool bold, bool dimmed = false}) {
    final selected = widget.selectedId == c.id;

    // Bold is the whole grammar, and it says a different thing in each section
    // because the sections ask different questions. In Needs You every row is
    // bold: you owe this. In Conversations bold means you have not read this.
    // Nothing else in the rail is bold, and the caller decides which question
    // this row is answering.
    final color = (selected || (bold && !dimmed))
        ? BondColors.onDarkPrimary
        : (dimmed ? BondColors.onDarkMuted : BondColors.onDarkSecondary);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s12),
      child: Material(
        color: selected ? BondColors.onDarkTint : BondColors.ink,
        borderRadius: BondRadii.smAll,
        child: InkWell(
          onTap: () => widget.onSelectConversation(c.id),
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
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: bold
                          ? BondColors.seaGlassOnDark
                          : BondColors.onDarkBorder,
                    ),
                  ),
                  const SizedBox(width: BondSpacing.s8),
                  Expanded(
                    child: Text(
                      railTitleFor(c),
                      style: BondType.small.copyWith(
                        color: color,
                        fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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
        color: BondColors.ink,
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
        color: selected ? BondColors.onDarkTint : BondColors.ink,
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
        color: selected ? BondColors.onDarkTint : BondColors.ink,
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
                          ? BondColors.seaGlassOnDark
                          : BondColors.onDarkBorder,
                    ),
                  ),
                  const SizedBox(width: BondSpacing.s8),
                  Expanded(
                    child: Text(
                      storyline.title.isEmpty
                          ? '(untitled)'
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

  /// Keep / Dismiss. Small and quiet: they sit inside a row whose main target
  /// is opening the storyline, and a pair of buttons loud enough to compete
  /// with that would get mis-tapped.
  Widget _storylineAction(
    IconData icon,
    String tooltip,
    VoidCallback? onTap,
  ) {
    return Tooltip(
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
        color: attention ? BondColors.error : BondColors.onDarkTint,
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
