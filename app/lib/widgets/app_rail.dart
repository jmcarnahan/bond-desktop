import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../theme/tokens.dart';

/// The rail's four stops. [storylines] and [later] are placeholders this
/// phase — they exist so the shape of the product is on screen before the
/// features that fill them land.
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

/// What the LO is on the hook for: anything awaiting their reply, plus
/// anything triage left an ask on that is not already closed. Input order is
/// preserved — the caller hands these over newest-first.
List<Conversation> needsYouRows(List<Conversation> all) => [
      for (final c in all)
        if (c.state == ConversationState.needsReply ||
            (c.state != ConversationState.done &&
                c.ctaText?.isNotEmpty == true))
          c,
    ];

/// Every live thread, resolved ones dropped.
List<Conversation> conversationRows(List<Conversation> all) => [
      for (final c in all)
        if (c.state != ConversationState.done) c,
    ];

/// The one line a rail row has room for. Who it is beats what it is about:
/// at 260px a subject truncates to nothing useful, a name does not.
String railTitleFor(Conversation c) {
  final who = c.primaryParticipant?.display ?? '';
  if (who.isNotEmpty) return who;
  final subject = _stripReplyPrefixes(c.subject ?? '');
  if (subject.isNotEmpty) return subject;
  return '(no subject)';
}

/// The dark left rail: sections, one line per thread, and whatever account
/// controls the screen hands down as a [footer].
///
/// The rail owns only its collapse state. Selection lives on the screen, so
/// the rail can be rebuilt from scratch on any data change without losing the
/// user's place.
class AppRail extends StatefulWidget {
  final List<Conversation> conversations;

  /// The open thread, when one is open.
  final String? selectedId;

  /// The section whose overview is showing. Null while a thread is open.
  final RailSection? selectedSection;

  final void Function(String conversationId) onSelectConversation;
  final void Function(RailSection section) onSelectSection;

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
    final needsYou = needsYouRows(widget.conversations);
    final open = conversationRows(widget.conversations);

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
                    rows: needsYou,
                    badge: needsYou.isEmpty
                        ? null
                        : _badge(needsYou.length, attention: true),
                  ),
                  ..._section(
                    RailSection.storylines,
                    rows: const [],
                    placeholder: 'Suggestions arrive after processing',
                  ),
                  ..._section(
                    RailSection.conversations,
                    rows: open,
                  ),
                  ..._section(
                    RailSection.later,
                    rows: const [],
                    placeholder: 'Nothing deferred yet',
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
    required List<Conversation> rows,
    Widget? badge,
    String? placeholder,
  }) {
    final collapsed = _collapsed.contains(section);
    return [
      _header(section, badge: badge, collapsed: collapsed),
      if (!collapsed) ...[
        for (final c in rows) _item(c),
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

  Widget _item(Conversation c) {
    final selected = widget.selectedId == c.id;
    final needsReply = c.state == ConversationState.needsReply;

    // Bold is the whole grammar: a thread that wants the LO reads heavier
    // than one that is merely open. Nothing else in the rail is bold.
    final color = (selected || needsReply)
        ? BondColors.onDarkPrimary
        : BondColors.onDarkSecondary;

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
                      color: needsReply
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
                        fontWeight:
                            needsReply ? FontWeight.w600 : FontWeight.w500,
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

  /// A count pill. [attention] is the red one — reserved for work the LO is
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
