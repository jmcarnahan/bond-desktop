import 'package:flutter/foundation.dart' show immutable;

import 'message_models.dart';

/// One row of the Archive's Last 7 days view: a thread that left the owner's
/// sight, when, and what took it — requirement 12i's "with the label and rule
/// that did it". Built by `MessageStore.recentlyDismissed`, which says why it
/// unions two populations and why `feedback_events` is not the source.
@immutable
class DismissedThread {
  final Conversation conversation;

  /// The newer of the thread's dismissal stamp and its rule filing, in the
  /// store's ISO shape. What the view orders by.
  final String dismissedAt;

  /// The rule that filed it, when the newer event was a rule's. Null means the
  /// owner closed it by hand.
  final String? ruleId;

  /// The rule's scope — the address, domain, subject prefix or kind of mail it
  /// is about. Null for a hand dismissal and for a rule deleted since it filed
  /// the thread (its links outlive it).
  final String? ruleScopeKind;
  final String? ruleScopeValue;

  /// The name of the label the rule filed the thread under.
  final String? ruleLabelName;

  const DismissedThread({
    required this.conversation,
    required this.dismissedAt,
    this.ruleId,
    this.ruleScopeKind,
    this.ruleScopeValue,
    this.ruleLabelName,
  });

  factory DismissedThread.fromRow(Map<String, Object?> row) {
    String? text(String key) {
      final value = row[key] as String?;
      return value == null || value.isEmpty ? null : value;
    }

    return DismissedThread(
      conversation: Conversation.fromRow(row),
      dismissedAt: row['dismissed_at'] as String? ?? '',
      ruleId: text('rule_id'),
      ruleScopeKind: text('rule_scope_kind'),
      ruleScopeValue: text('rule_scope_value'),
      ruleLabelName: text('rule_label_name'),
    );
  }

  /// Whether a rule, rather than the owner, took this thread.
  bool get byRule => ruleId != null;

  /// Whether Reopen applies: only a thread that is actually closed. A rule
  /// never closes one, so a rule-filed row offers Reopen only if the owner also
  /// closed it.
  bool get reopenable => conversation.state == ConversationState.done;

  /// The line under the row's title, which REPLACES its preview:
  /// `Marked done · <labels>` or `Filed by rule "<scope>" · <label>`.
  ///
  /// A rule has no name of its own — it is a word pointed at a scope — so the
  /// scope is the name: it is what the owner typed or picked when they made
  /// it, and the label after the dot is the word it files under. A rule
  /// deleted since reads `Filed by a rule`, which is still true.
  String get caption {
    if (byRule) {
      final scope = ruleScopeValue;
      final who = scope == null ? 'Filed by a rule' : 'Filed by rule "$scope"';
      final label = ruleLabelName;
      return label == null ? who : '$who · $label';
    }
    final labels = [for (final l in conversation.labels) l.name];
    return labels.isEmpty
        ? 'Marked done'
        : 'Marked done · ${labels.join(', ')}';
  }
}
