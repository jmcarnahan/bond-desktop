import 'package:flutter/material.dart';

import '../models/message_models.dart';
import '../services/conversation_state.dart';
import '../theme/tokens.dart';
import 'app_rail.dart';
import 'time_format.dart';

/// Everything the app decided could wait, laid out so none of it is hidden.
///
/// The rule this panel exists to keep: **deferred is not deleted.** Every
/// deferred thread appears here in full — sender, subject, and the line it was
/// carrying — with nothing behind a disclosure triangle and nothing summarised
/// away. Later is a reading order, not a filter, and a digest the LO cannot
/// trust to be complete is one they will stop opening, which puts them back to
/// reading everything in arrival order.
///
/// Grouped by sender inside each day, because the correction this view exists
/// to collect is sender-scoped: seeing eight rows from one address in a row is
/// what makes "keep this sender in the inbox" an obvious answer rather than a
/// setting to go looking for.
class LaterDigestPanel extends StatelessWidget {
  /// The whole inbox. The panel picks the deferred threads out itself, so the
  /// caller never has to keep two filters in agreement.
  final List<Conversation> conversations;

  /// A `yyyy-mm-dd` key to show only that day, or null for every day with its
  /// own header.
  final String? dayFilter;

  final void Function(String conversationId) onOpen;

  /// "This sender belongs in my inbox", by address — the standing correction.
  final void Function(String address, String source) onKeepSender;

  /// "This one thread belongs in my inbox", by `(source, key)` — the narrow
  /// one, for when the sender rule is right and this message is the exception.
  final void Function(String source, String conversationKey) onKeepThread;

  const LaterDigestPanel({
    super.key,
    required this.conversations,
    required this.dayFilter,
    required this.onOpen,
    required this.onKeepSender,
    required this.onKeepThread,
  });

  /// Namespaced so it cannot collide with anything a menu might carry later.
  static const String _justThisThread = '__just_this_thread__';

  /// Deferred threads for the day in question, grouped by day then by sender,
  /// each group in the order the caller handed them over.
  ///
  /// The sender key is the display name and not the address: two addresses
  /// that show the same name are the same person to the reader, and splitting
  /// them into two groups would look like a bug. The ACTIONS still use the
  /// address, taken from the row they sit on.
  List<(String, List<(String, List<Conversation>)>)> _grouped() {
    final days = <String, Map<String, List<Conversation>>>{};
    for (final c in laterRows(conversations)) {
      final dayKey = dayKeyOfIso(c.lastMessageAt) ?? '';
      if (dayFilter != null && dayKey != dayFilter) continue;
      final who = c.primaryParticipant?.display ?? '(no sender)';
      (days[dayKey] ??= <String, List<Conversation>>{})
          .putIfAbsent(who, () => <Conversation>[])
          .add(c);
    }

    final dayKeys = days.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final dayKey in dayKeys)
        (
          dayKey,
          [
            for (final entry in days[dayKey]!.entries) (entry.key, entry.value),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped();
    if (grouped.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(BondSpacing.s32),
          child: Text(
            'Nothing deferred.',
            style: BondType.small,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: BondSpacing.s24),
      children: [
        for (final (dayKey, senders) in grouped) ...[
          // Suppressed when the caller already named the day: repeating it at
          // the top of a list that only contains it is a wasted line.
          if (dayFilter == null) _dayHeader(dayKey),
          for (final (who, rows) in senders) ...[
            _senderHeader(who, rows),
            for (final c in rows) _line(c),
          ],
        ],
      ],
    );
  }

  Widget _dayHeader(String dayKey) {
    final label =
        formatDayLabel(dayKey) ?? (dayKey.isEmpty ? 'Undated' : dayKey);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s4,
        BondSpacing.s16,
        BondSpacing.s4,
        BondSpacing.s8,
      ),
      child: Text(label.toUpperCase(), style: BondType.label),
    );
  }

  /// The sender's name once, with the correction that applies to all of their
  /// rows beside it. Putting the button up here rather than on every line is
  /// what keeps a group of nine from reading as nine separate decisions.
  Widget _senderHeader(String who, List<Conversation> rows) {
    final owner = _addressRowOf(rows);
    final address = owner?.primaryEmail;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BondSpacing.s4,
        BondSpacing.s12,
        BondSpacing.s4,
        BondSpacing.s4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              who,
              style: BondType.body.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (owner != null && address != null)
            TextButton.icon(
              // The source rides along with the address: a sender rule is
              // applied to the rows of ONE source, and a Teams identity keyed
              // against the email rows (or vice versa) would move nothing.
              onPressed: () => onKeepSender(address, owner.source),
              icon: const Icon(Icons.arrow_upward, size: 14),
              label: const Text('Keep in inbox'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: BondSpacing.s8,
                ),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  /// The first row of this sender's group that carries an address. Null when
  /// none does, which hides the sender-scoped button — a rule keyed on an
  /// empty address would apply to every anonymous sender at once.
  static Conversation? _addressRowOf(List<Conversation> rows) {
    for (final c in rows) {
      final email = c.primaryEmail;
      if (email != null && email.isNotEmpty) return c;
    }
    return null;
  }

  /// One thread: subject, then whatever it was last saying. Both visible, both
  /// full-width — this is the reading view, not a preview of one.
  Widget _line(Conversation c) {
    final subject = stripReFw(c.subject);
    final cta = c.ctaText;
    final secondary =
        (cta != null && cta.isNotEmpty) ? cta : c.lastMessagePreview;

    return Material(
      color: BondColors.surface,
      child: InkWell(
        onTap: () => onOpen(c.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: BondSpacing.s8,
            vertical: BondSpacing.s8,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      subject.isEmpty ? '(no subject)' : subject,
                      style: BondType.small.copyWith(color: BondColors.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (secondary != null && secondary.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        secondary,
                        style: BondType.caption,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz),
                iconSize: 18,
                tooltip: 'Keep in inbox',
                itemBuilder: (context) => const [
                  PopupMenuItem<String>(
                    value: _justThisThread,
                    child: Text('Just this thread'),
                  ),
                ],
                onSelected: (_) => onKeepThread(c.source, c.id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
