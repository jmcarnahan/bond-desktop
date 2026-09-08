import 'package:flutter/material.dart';

import '../models/drafts_models.dart';
import '../theme/tokens.dart';
import 'inline_alert.dart';
import 'time_format.dart';

/// The model's outbox and the user's own: every suggestion still waiting, and
/// what has already gone out.
///
/// The two belong on one screen because they are two ends of the same
/// question — what have I said, and what has something offered to say for me.
/// Slack has a Drafts & sent view for exactly the first half; this one has a
/// second half because the drafts here were not written by the user.
///
/// A pane with no providers in it: everything it draws is a prop, so its host
/// is the only place the reads happen and this file can be pumped on its own.
class DraftsPane extends StatelessWidget {
  final List<PendingDraft> drafts;
  final List<SentRow> sent;

  /// Whether a read has come back. False draws a spinner rather than two empty
  /// sections claiming there is nothing to send.
  final bool loaded;

  /// Passed in rather than read, so the relative times in a test are a fact the
  /// test states.
  final DateTime now;

  /// The sentence to show when the newest read failed. The rows already on
  /// screen stay under it — a pane that blanked on a failed re-read would throw
  /// away a list that is still perfectly true — so this is a banner OVER the
  /// list, never a replacement for it. Null is the ordinary state.
  final String? error;

  final void Function(PendingDraft) onOpenDraft;
  final void Function(PendingDraft) onDismiss;
  final void Function(SentRow) onOpenSent;

  const DraftsPane({
    super.key,
    required this.drafts,
    required this.sent,
    required this.loaded,
    required this.now,
    required this.onOpenDraft,
    required this.onDismiss,
    required this.onOpenSent,
    this.error,
  });

  /// Keyed by the draft's own key in the store — `(source, message)` — because
  /// a conversation key is not unique across connectors and a row index moves
  /// the moment anything is dismissed.
  static Key draftKeyFor(String source, String replyToMessageId) =>
      ValueKey('draft-$source-$replyToMessageId');

  static Key dismissKeyFor(String source, String replyToMessageId) =>
      ValueKey('draft-dismiss-$source-$replyToMessageId');

  static Key sentKeyFor(String source, String messageId) =>
      ValueKey('sent-$source-$messageId');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(BondSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Drafts & sent', style: BondType.title),
          const SizedBox(height: BondSpacing.s16),
          if (error != null) ...[
            InlineAlert(
              severity: InlineAlertSeverity.error,
              text: error!,
              maxLines: 2,
            ),
            const SizedBox(height: BondSpacing.s12),
          ],
          Expanded(
            child: loaded
                ? ListView(
                    children: [
                      _label('SUGGESTED', drafts.length),
                      if (drafts.isEmpty)
                        _empty('No suggested replies waiting.')
                      else
                        for (final draft in drafts) _draftRow(draft),
                      const SizedBox(height: BondSpacing.s16),
                      _label('SENT', sent.length),
                      if (sent.isEmpty)
                        _empty('Nothing sent yet.')
                      else
                        for (final row in sent) _sentRow(row),
                    ],
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }

  /// The section label and its count, in the list pane's own idiom — the two
  /// lists on this screen are lists of threads' worth of work, and they should
  /// read like every other sectioned list in the app.
  Widget _label(String text, int count) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s8),
        child: Row(
          children: [
            Text(text, style: BondType.label),
            const SizedBox(width: BondSpacing.s8),
            Text('$count', style: BondType.caption),
          ],
        ),
      );

  Widget _empty(String text) => Padding(
        padding: const EdgeInsets.only(bottom: BondSpacing.s8),
        child: Text(text, style: BondType.small),
      );

  /// One suggestion. Dismiss sits OUTSIDE the card's ink, on the list pane's
  /// Reopen precedent: the card's whole job is to open the thread, and a button
  /// inside it competing for the same tap is a button that gets hit by accident.
  Widget _draftRow(PendingDraft draft) {
    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _card(
              key: draftKeyFor(draft.source, draft.replyToMessageId),
              title: '${draft.who ?? '(unknown)'} · '
                  '${draft.subject ?? '(no subject)'}',
              // The first LINE of the suggestion. A reply opens with a
              // greeting, so a row that ran on into the paragraph under it
              // would be a row nobody can scan.
              preview: draft.body.split('\n').first.trim(),
              trailing: relativeTime(draft.updatedAt, now) ?? '',
              onTap: () => onOpenDraft(draft),
            ),
          ),
          const SizedBox(width: BondSpacing.s8),
          TextButton(
            key: dismissKeyFor(draft.source, draft.replyToMessageId),
            onPressed: () => onDismiss(draft),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: BondSpacing.s8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }

  /// One sent message.
  ///
  /// An echo says so in its time caption rather than being hidden: the user
  /// watched the reply leave, and the only provisional thing about the row is
  /// its id. `· syncing` comes off when the Sent Items copy lands and takes the
  /// echo's place, which happens on a later sync and not on anything this pane
  /// does.
  ///
  /// A row with nobody in `to` is titled by its subject alone. That is the
  /// ordinary shape of a CHAT: the Teams connector stores no recipients on a
  /// message because the chat's own subject already names everyone in it, and
  /// a title that opened with "(no recipient)" would call the most common sent
  /// row in a Teams mailbox broken.
  Widget _sentRow(SentRow row) {
    final subject = row.subject ?? '(no subject)';
    final title = switch (row.to.length) {
      0 => subject,
      1 => '${row.to.first} · $subject',
      _ => '${row.to.first} +${row.to.length - 1} · $subject',
    };
    final time = relativeTime(row.sentAt, now) ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: BondSpacing.s8),
      child: _card(
        key: sentKeyFor(row.source, row.messageId),
        title: title,
        preview: row.preview ?? '',
        trailing: row.echo ? '$time · syncing'.trim() : time,
        onTap: () => onOpenSent(row),
      ),
    );
  }

  /// The card both halves wear — the storylines overview's idiom, because both
  /// lists are lists of things one tap opens.
  Widget _card({
    required Key key,
    required String title,
    required String preview,
    required String trailing,
    required VoidCallback onTap,
  }) {
    return Material(
      key: key,
      color: BondColors.surface,
      borderRadius: BondRadii.mdAll,
      child: InkWell(
        onTap: onTap,
        borderRadius: BondRadii.mdAll,
        child: Container(
          padding: const EdgeInsets.all(BondSpacing.s12),
          decoration: BoxDecoration(
            borderRadius: BondRadii.mdAll,
            border: Border.all(color: BondColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: BondType.body.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        preview,
                        style: BondType.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing.isNotEmpty) ...[
                const SizedBox(width: BondSpacing.s8),
                Text(trailing, style: BondType.caption),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
