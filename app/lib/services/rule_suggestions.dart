import 'package:flutter/foundation.dart' show immutable;

import '../models/label_models.dart';
import '../models/message_models.dart';
import 'classification.dart';

/// Rules the owner has already written with their hands, offered back to them
/// as one sentence — requirement 12d.
///
/// Nothing here learns anything. It counts what a person did: three threads
/// dismissed that share a sender, a domain, a kind of mail or the front of a
/// subject is the owner having answered the same question three times, and the
/// offer is the app asking whether it should stop asking. That is why the
/// threshold is a count of THREADS and not a model's confidence, and why every
/// suggestion can name the evidence that produced it.
///
/// Pure, like `gates.dart` and `classification.dart` beside it: the rows arrive
/// as arguments, there is no clock, no store and no I/O, so the whole set is
/// table-testable and a test never has to stage a database to ask what the app
/// would offer.
///
/// **`feedback_events` is DERIVED.** The history these suggestions are counted
/// from is in `MessageStore.derivedTables`, so Clear AI results empties it and
/// the suggestions start again from nothing. That is deliberate: the events are
/// the app's record of what it saw, a reset says "forget what you worked out
/// about my mail", and an offer that survived it would be the app quoting
/// evidence the owner just asked it to throw away. The rules the owner ACCEPTED
/// are rows in `label_rules`, which a reset does not touch.

/// One thread the owner acted on, reduced to the four things a rule can be
/// about.
///
/// Row-shaped like the models it sits beside: [fromRow] reads a joined row —
/// one `feedback_events` row's thread, plus the newest kept inbound message on
/// it — through nullable casts with defaults, so a half-written row produces
/// evidence that groups with nothing rather than throwing inside a count.
@immutable
class RuleEvidence {
  /// The connector, because a `conversation_key` is unique only within one and
  /// two connectors' keys must never count as the same thread.
  final String source;
  final String conversationKey;

  /// The sender's address, LOWERCASED — the same folding `label_rules` does at
  /// write time, so a suggestion's value can be stored verbatim. Empty when the
  /// row named nobody.
  final String senderAddress;

  /// The subject as stored. Empty when there was none.
  final String subject;

  /// [classificationOf]'s answer for the message, or null when nothing on the
  /// row says. Null groups with nothing: "mail I have no name for" is not a
  /// kind of mail somebody can write a rule about.
  final String? classification;

  const RuleEvidence({
    required this.source,
    required this.conversationKey,
    this.senderAddress = '',
    this.subject = '',
    this.classification,
  });

  /// A joined history row: `feedback_events` → `conversations` → the thread's
  /// newest kept inbound message, with the message's own columns on it.
  ///
  /// The classification is computed HERE rather than in SQL because it is a
  /// Dart rule over headers, a display name and a subject shape — see
  /// `classification.dart`, which owns the question — and a second spelling of
  /// it in a query would answer differently from the matcher the rules run
  /// through.
  factory RuleEvidence.fromRow(Map<String, Object?> row) {
    final message = Message.fromRow(row);
    return RuleEvidence(
      source: row['source'] as String? ?? 'email',
      conversationKey: row['conversation_key'] as String? ?? '',
      senderAddress: (row['from_address'] as String? ?? '').trim().toLowerCase(),
      subject: (row['subject'] as String? ?? '').trim(),
      classification: classificationOf(message),
    );
  }

  /// The thread this is about, for counting DISTINCT threads: the same thread
  /// dismissed twice is one thread the owner has an opinion about, not two.
  String get threadKey => '$source|$conversationKey';

  /// The part after the `@`, lowercased, or empty when there is no address.
  String get senderDomain {
    final at = senderAddress.indexOf('@');
    if (at < 0 || at == senderAddress.length - 1) return '';
    return senderAddress.substring(at + 1);
  }

  /// The front of the subject, when it has one a rule could match on — see
  /// [subjectPrefixOf], which this delegates to.
  String? get subjectPrefix => subjectPrefixOf(subject);

  @override
  String toString() =>
      'RuleEvidence($threadKey, $senderAddress, $classification)';
}

/// The front of a subject, when it has one a rule could match on.
///
/// Two shapes and no others, because these are the two a machine writes and a
/// person does not: a bracketed tag at the very start (`[JIRA] `) and
/// everything up to and including a short leading colon (`Accepted: `). The
/// colon rule is capped at [_subjectPrefixCap] characters so a sentence with
/// a colon in the middle of it is prose rather than a prefix, and anything
/// under [_subjectPrefixFloor] is too short to mean anything.
///
/// A reply or forward marker (`Re:`, `Fw:`, `Fwd:`, `AW:`, `SV:`) is NOT a
/// prefix: a person's mail client writes it, not a machine, so it names no
/// kind of mail — a rule on `re:` would hide every reply, and select-similar
/// on it would select them all.
///
/// Lowercased, because `label_rules.scope_value` is stored folded and the
/// matcher compares folded. Top-level rather than on [RuleEvidence] because
/// select-similar asks the same question of a drawn row, and the chip must
/// select exactly what a subject rule written from it would match.
String? subjectPrefixOf(String? subject) {
  final text = subject?.trim() ?? '';
  if (text.isEmpty) return null;
  final bracket = _bracketedTag.firstMatch(text);
  if (bracket != null) return _prefixOrNull(bracket.group(0)!);
  final colon = text.indexOf(':');
  if (colon < 0 || colon > _subjectPrefixCap) return null;
  final prefix = _prefixOrNull(text.substring(0, colon + 1));
  if (prefix == null) return null;
  final word = prefix.substring(0, prefix.length - 1).trim();
  return _replyMarkers.contains(word) ? null : prefix;
}

String? _prefixOrNull(String raw) {
  final prefix = raw.trim().toLowerCase();
  return prefix.length < _subjectPrefixFloor ? null : prefix;
}

/// The markers a mail client puts in front of a subject it is answering or
/// passing on, in the languages a mailbox here is likely to meet (`AW` and
/// `SV` are the German and Scandinavian replies).
const Set<String> _replyMarkers = {'re', 'fw', 'fwd', 'aw', 'sv'};

/// A bracketed tag at the very start of a subject. `classification.dart` has
/// its own copy of this shape for its own question, and the two are deliberately
/// separate: that one decides what a message IS from several signals at once,
/// this one only names the characters a `subject` rule would match.
final RegExp _bracketedTag = RegExp(r'^\s*\[[^\]]{1,24}\]\s*');

const int _subjectPrefixCap = 24;
const int _subjectPrefixFloor = 3;

/// One rule the app is offering to write, and the evidence for it.
@immutable
class RuleSuggestion {
  /// The disposition a suggestion can carry that [LabelRule] cannot: "always
  /// keep this sender in Needs You", which is a `sender_prefs` answer rather
  /// than a label rule. It is here because 12d asks both questions in one
  /// place, and a caller switches on this field to know which writer to use.
  static const String keepInNeedsYou = 'keep';

  /// One of [LabelRule]'s scope kinds.
  final String scopeKind;

  /// What the rule would be about, folded the way `label_rules` stores it.
  final String scopeValue;

  /// [LabelRule.hideNeedsYou] or [keepInNeedsYou].
  final String disposition;

  /// How many DISTINCT threads taught this. Shown, because a person deciding
  /// whether to let the app act on their behalf is owed the count that
  /// convinced it.
  final int threadCount;

  const RuleSuggestion({
    required this.scopeKind,
    required this.scopeValue,
    required this.disposition,
    required this.threadCount,
  });

  /// The stable name of this offer, and the key a "Not now" is remembered
  /// under. Built from the three facts that make it the same offer: a wider
  /// count next month is the same question asked again, and a person who said
  /// not now should not be asked it again.
  String get key => '$disposition:$scopeKind:$scopeValue';

  /// Whether this suggestion is a `label_rules` row (rather than a sender
  /// preference), which is what decides who writes it.
  bool get isLabelRule => disposition != keepInNeedsYou;

  /// The offer in one sentence: what the owner did, then what the app would do
  /// about it. Second person and a count, never a percentage — the evidence is
  /// the owner's own actions and they can check it.
  String get words => '$_finding $_question';

  String get _finding => switch (disposition) {
        keepInNeedsYou => 'You keep coming back to $scopeValue.',
        _ => switch (scopeKind) {
            LabelRule.scopeSender =>
              "You've marked $threadCount threads from $scopeValue done.",
            LabelRule.scopeDomain =>
              "You've marked $threadCount threads from $scopeValue done.",
            LabelRule.scopeClassification =>
              "You've marked $threadCount ${_kindWords(scopeValue)} done.",
            LabelRule.scopeSubject =>
              "You've marked done $threadCount threads starting "
                  "'$scopeValue'.",
            _ => "You've marked $threadCount threads like this done.",
          },
      };

  /// The words on the button that says yes. Short, and it names the OUTCOME
  /// rather than the mechanism: a reader agreeing to this is agreeing to what
  /// happens to their mail, not to a row in a table.
  String get acceptWords => switch (disposition) {
        keepInNeedsYou => 'Always keep',
        _ => 'Hide these',
      };

  String get _question => switch (disposition) {
        keepInNeedsYou => 'Always keep them in Needs You?',
        _ => 'Hide these from Needs You in future?',
      };

  /// A stored classification as a plural a sentence can carry.
  static String _kindWords(String classification) => switch (classification) {
        'meeting_response' => 'meeting responses',
        'meeting_invite' => 'meeting invitations',
        'tracker_notification' => 'ticket notifications',
        'automated_notification' => 'automated notifications',
        // An open set: a kind a later build wrote reads as words rather than as
        // a token, the same rule the picker's offer chips take.
        _ => '${classification.replaceAll('_', ' ')} threads',
      };

  @override
  bool operator ==(Object other) =>
      other is RuleSuggestion &&
      other.scopeKind == scopeKind &&
      other.scopeValue == scopeValue &&
      other.disposition == disposition &&
      other.threadCount == threadCount;

  @override
  int get hashCode =>
      Object.hash(scopeKind, scopeValue, disposition, threadCount);

  @override
  String toString() =>
      'RuleSuggestion($disposition, $scopeKind=$scopeValue, $threadCount)';
}

/// How many threads it takes before the app says anything. Three, because two
/// is a coincidence and four is a person who has already done the work twice
/// over.
const int defaultSuggestionThreshold = 3;

/// What the app would offer to do about the mail the owner keeps handling by
/// hand, best offer first.
///
/// [dismissed] is the threads the owner filed away and [kept] the ones they
/// came back to; both are DISTINCT-ed by thread here, so a caller may hand over
/// one row per feedback event without thinking about it.
///
/// [existing] takes rules the owner already has out of the running: offering to
/// write a rule that is already written is the app failing to remember its own
/// state, and it would be the offer a person trusts least. [settledSenders] does
/// the same job for `sender_prefs` — the addresses the owner has already ruled
/// on from a row's own Dismiss-everything or Keep-in-inbox press, which are not
/// `label_rules` rows and are just as much an answer. [suppressed] takes out the
/// offers they answered "not now" — see [RuleSuggestion.key].
///
/// The order is best-evidence first, then [LabelRule]'s own precedence
/// (sender over domain over subject over classification) so two offers with the
/// same count arrive in the order the matcher would apply them, then the value
/// so the result never depends on the input's order. A caller showing ONE row
/// takes the first.
List<RuleSuggestion> suggestRules({
  required List<RuleEvidence> dismissed,
  List<RuleEvidence> kept = const [],
  int threshold = defaultSuggestionThreshold,
  Iterable<LabelRule> existing = const [],
  Set<String> settledSenders = const {},
  Set<String> suppressed = const {},
}) {
  if (threshold < 1) return const [];
  final already = {
    for (final rule in existing) '${rule.scopeKind}:${rule.scopeValue}',
    // A sender the owner has already ruled on one way or the other, from
    // `sender_prefs` — the table the Dismiss-everything and Keep-in-inbox
    // presses write. Same silence, same reason.
    for (final address in settledSenders)
      '${LabelRule.scopeSender}:${address.toLowerCase()}',
  };

  // Threads, not events: one thread the owner dismissed twice is one opinion.
  final downs = _byThread(dismissed);
  final ups = _byThread(kept);

  final out = <RuleSuggestion>[];

  void offer(String kind, String value, String disposition, Set<String> hits) {
    if (hits.length < threshold) return;
    // Any rule on this scope silences BOTH offers about it, whichever way it
    // points: the owner has already said what to do with this sender, and the
    // app offering the opposite would be arguing with its own state.
    if (already.contains('$kind:$value')) return;
    final suggestion = RuleSuggestion(
      scopeKind: kind,
      scopeValue: value,
      disposition: disposition,
      threadCount: hits.length,
    );
    if (suppressed.contains(suggestion.key)) return;
    out.add(suggestion);
  }

  // Which threads each candidate scope would have covered. Sets rather than
  // counters, because the domain rule below has to ask WHICH threads a group
  // holds and not just how many.
  final senders = <String, Set<String>>{};
  final domains = <String, Set<String>>{};
  final kinds = <String, Set<String>>{};
  final prefixes = <String, Set<String>>{};
  final sendersInDomain = <String, Set<String>>{};

  for (final e in downs) {
    if (e.senderAddress.isNotEmpty) {
      senders.putIfAbsent(e.senderAddress, () => {}).add(e.threadKey);
    }
    final domain = e.senderDomain;
    if (domain.isNotEmpty) {
      domains.putIfAbsent(domain, () => {}).add(e.threadKey);
      sendersInDomain.putIfAbsent(domain, () => {}).add(e.senderAddress);
    }
    final kind = e.classification;
    if (kind != null && kind.isNotEmpty) {
      kinds.putIfAbsent(kind, () => {}).add(e.threadKey);
    }
    final prefix = e.subjectPrefix;
    if (prefix != null) {
      prefixes.putIfAbsent(prefix, () => {}).add(e.threadKey);
    }
  }

  senders.forEach((value, hits) =>
      offer(LabelRule.scopeSender, value, LabelRule.hideNeedsYou, hits));
  domains.forEach((value, hits) {
    // A domain whose evidence is all one address is a WIDER rule than the
    // evidence supports: the sender offer above already covers those threads,
    // and this one would also cover their colleagues.
    if ((sendersInDomain[value]?.length ?? 0) < 2) return;
    offer(LabelRule.scopeDomain, value, LabelRule.hideNeedsYou, hits);
  });
  prefixes.forEach((value, hits) =>
      offer(LabelRule.scopeSubject, value, LabelRule.hideNeedsYou, hits));
  kinds.forEach((value, hits) => offer(
      LabelRule.scopeClassification, value, LabelRule.hideNeedsYou, hits));

  // The reverse offer, and SENDERS only: "you keep coming back to this person"
  // is a sentence about a person. The same claim about a domain or a kind of
  // mail would be the app inferring a relationship from a shape.
  //
  // A sender the app is about to offer to HIDE is left out here rather than
  // offered both ways: two contradictory offers about one person is the app
  // having no opinion while sounding like it has two, and the honest thing is to
  // say neither until the evidence stops being mixed. Below the threshold the
  // keep offer stands — a single dismissal among a dozen replies is a thread
  // that was finished, not a disagreement.
  final keeps = <String, Set<String>>{};
  for (final e in ups) {
    if (e.senderAddress.isEmpty) continue;
    // Mail-shaped addresses only. A Teams sender is `teams:<id>` — no `@` —
    // and the keep offer's writer is the MAIL sender-preference path, keyed
    // under `source = 'email'`; offering to keep a chat sender would write a
    // row the Teams pass never reads, a press that silently does nothing.
    if (!e.senderAddress.contains('@')) continue;
    if ((senders[e.senderAddress]?.length ?? 0) >= threshold) continue;
    keeps.putIfAbsent(e.senderAddress, () => {}).add(e.threadKey);
  }
  keeps.forEach((value, hits) => offer(
      LabelRule.scopeSender, value, RuleSuggestion.keepInNeedsYou, hits));

  out.sort((a, b) {
    final byCount = b.threadCount.compareTo(a.threadCount);
    if (byCount != 0) return byCount;
    final byKind = _kindRank(a.scopeKind).compareTo(_kindRank(b.scopeKind));
    if (byKind != 0) return byKind;
    return a.scopeValue.compareTo(b.scopeValue);
  });
  return out;
}

/// One thread's evidence, keeping the FIRST row for each thread: the rows arrive
/// newest first from the history read, and the newest row is the one whose
/// sender and subject the owner was looking at when they acted.
List<RuleEvidence> _byThread(List<RuleEvidence> rows) {
  final seen = <String>{};
  final out = <RuleEvidence>[];
  for (final row in rows) {
    if (row.conversationKey.isEmpty) continue;
    if (seen.add(row.threadKey)) out.add(row);
  }
  return out;
}

/// `matchLabelRule`'s precedence, spelled here for the tie-break only: two
/// offers with the same evidence arrive in the order the matcher would apply
/// them, so the one a reader is shown is the one that would win.
int _kindRank(String kind) => switch (kind) {
      LabelRule.scopeSender => 0,
      LabelRule.scopeDomain => 1,
      LabelRule.scopeSubject => 2,
      LabelRule.scopeClassification => 3,
      _ => 4,
    };
