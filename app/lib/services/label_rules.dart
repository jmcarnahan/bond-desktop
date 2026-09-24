/// Which standing rule, if any, speaks about one message.
///
/// Pure — no I/O, no clock, no store — for `gates.dart`'s reason: this is the
/// one authority on what a rule matches, and it is called from three places
/// that could otherwise each grow their own answer. The triage gate asks it
/// about arriving mail, the needs-you pass asks it about a message it is about
/// to judge, and `MessageStore.applyLabelRule` asks it about every message in
/// the lookback window when a rule is first created. A retroactive apply that
/// moved a different set of threads from the one the gate will act on tomorrow
/// is exactly the failure one function prevents.
///
/// It answers WHICH rule, never what to do about it. The disposition is the
/// caller's business, and so is [LabelRule.unlessMentionsMe] — the exception is
/// spent through the needs-you floor, where "the owner was singled out" is a
/// fact about the stored row rather than about the rule.
library;

import '../models/label_models.dart';

/// The rule that speaks about this message, or null when none does.
///
/// [rules] is the whole table as `MessageStore.listLabelRules` returns it; a
/// caller with one rule in hand passes a single-element list, which is what the
/// retroactive walk does.
///
/// PRECEDENCE, when several rules match: **sender, then domain, then subject,
/// then classification** — most specific wins. An address is one mailbox; a
/// domain is an organisation; a subject prefix is a shape many senders share;
/// a classification is a whole population of mail. So a rule about one
/// colleague's address beats one about their employer's domain, and both beat
/// "every meeting response". Within one kind the LONGEST [LabelRule.scopeValue]
/// wins, which makes `eu.example.com` beat `example.com` and `Accepted: Q3` beat
/// `Accepted:`, and an exact tie breaks alphabetically so the answer is stable
/// whatever order the rows came back in.
///
/// [senderAddress] and [senderName] are the message's own; [subject] its
/// subject; [classification] the KIND of message, computed by the caller (the
/// pipeline names it — `meeting_response`, `tracker_notification`,
/// `automated_notification`) and compared here as a plain string. A null
/// classification simply matches no classification-scoped rule, which is what a
/// build that has not worked out the kind yet should read as.
///
/// [source] and [senderName] are accepted and not read, deliberately. They are
/// what every caller already has, and a matcher whose signature changed with
/// each new scope kind would be an edit at all three call sites for a rule kind
/// none of them knows about: a display-name scope and a source-scoped rule are
/// both plausible next rows in this table. The domain rule needs no `source`
/// test of its own — a Teams sender address is `teams:<id>` with no `@` in it,
/// so it cannot match a domain scope by construction.
LabelRule? matchLabelRule(
  List<LabelRule> rules, {
  required String source,
  String? senderAddress,
  String? senderName,
  String? subject,
  String? classification,
}) {
  if (rules.isEmpty) return null;
  final address = senderAddress?.trim().toLowerCase() ?? '';
  final subjectText = subject?.trim().toLowerCase() ?? '';
  final kind = classification?.trim().toLowerCase() ?? '';

  LabelRule? best;
  var bestRank = -1;
  for (final rule in rules) {
    if (!_matches(rule, address: address, subject: subjectText, kind: kind)) {
      continue;
    }
    final rank = _rankOf(rule.scopeKind);
    if (rank < 0) continue;
    if (best == null || rank > bestRank || _beats(rule, best, rank, bestRank)) {
      best = rule;
      bestRank = rank;
    }
  }
  return best;
}

/// Whether one rule's scope covers this message, ignoring precedence.
///
/// Every comparison is against an already-lowercased [LabelRule.scopeValue] —
/// the store folds it at write time — so nothing here folds per row.
bool _matches(
  LabelRule rule, {
  required String address,
  required String subject,
  required String kind,
}) {
  final value = rule.scopeValue;
  if (value.isEmpty) return false;
  switch (rule.scopeKind) {
    // One mailbox, exactly. A rule about `alex@example.com` says nothing about
    // `alex@eu.example.com`, which is a different mailbox that happens to read
    // similarly.
    case LabelRule.scopeSender:
      return address.isNotEmpty && address == value;
    // The organisation: the address's domain part, or any subdomain of it. The
    // leading dot in the suffix test is what keeps `notexample.com` out of a
    // rule about `example.com`.
    case LabelRule.scopeDomain:
      final at = address.lastIndexOf('@');
      if (at < 0 || at == address.length - 1) return false;
      final domain = address.substring(at + 1);
      return domain == value || domain.endsWith('.$value');
    // A PREFIX and not a substring: these rules are made for the owner out of a
    // subject they are looking at (`Accepted:`, `[JIRA]`), and a substring rule
    // would catch every reply that quoted one of them in the middle of its own
    // subject.
    case LabelRule.scopeSubject:
      return subject.isNotEmpty && subject.startsWith(value);
    // Exact, against a string this layer does not compute. A classification the
    // caller could not work out is empty and matches nothing.
    case LabelRule.scopeClassification:
      return kind.isNotEmpty && kind == value;
    // A kind a later build added. Inert rather than fatal.
    default:
      return false;
  }
}

/// Precedence rank, highest first, or -1 for a scope kind this build does not
/// know. See the table in [matchLabelRule].
int _rankOf(String scopeKind) => switch (scopeKind) {
      LabelRule.scopeSender => 3,
      LabelRule.scopeDomain => 2,
      LabelRule.scopeSubject => 1,
      LabelRule.scopeClassification => 0,
      _ => -1,
    };

/// The within-a-kind tie-break: longer scope value first, then alphabetical.
///
/// Both halves exist to make the answer independent of row order. A store that
/// returned its rules newest-first and one that returned them by id would
/// otherwise hide a thread under different words.
bool _beats(LabelRule candidate, LabelRule best, int rank, int bestRank) {
  if (rank != bestRank) return false;
  if (candidate.scopeValue.length != best.scopeValue.length) {
    return candidate.scopeValue.length > best.scopeValue.length;
  }
  return candidate.scopeValue.compareTo(best.scopeValue) < 0;
}
