import '../models/message_models.dart';
import 'rule_suggestions.dart' show subjectPrefixOf;

/// "Select similar" over the drawn Needs You rows — requirement 12c's one click
/// that clears a whole class of mail.
///
/// Pure, like `rule_suggestions.dart` beside it: the rows arrive as arguments
/// and nothing here reads a store, so the three scopes are table-testable.
///
/// Each scope answers the same question a label rule on that scope would, as
/// closely as a drawn row allows, so a reader who selects a class and then
/// writes a rule about it is not surprised by what the rule catches:
/// - [SimilarScope.sender] is one mailbox, exactly.
/// - [SimilarScope.domain] is the address's domain part, exactly. Narrower
///   than a domain RULE, which also takes subdomains: a chip labelled
///   `example.test` selecting `eu.example.test` would select rows its own
///   label does not name.
/// - [SimilarScope.subject] is [subjectPrefixOf] and the prefix test
///   `label_rules._matches` runs, so the chip selects exactly what a subject
///   rule would.
enum SimilarScope { sender, domain, subject }

/// The value [row] carries for [scope], folded, or null when the scope does not
/// apply to it — no address, a Teams sender (`teams:<id>`, no domain), a
/// subject with no machine-written front.
///
/// The sender is who the thread is waiting on
/// ([Conversation.latestInboundFrom]), else the row's own participant — the
/// address `m` and the Drop senders button key their rule on.
String? similarValueOf(Conversation row, SimilarScope scope) {
  switch (scope) {
    case SimilarScope.sender:
      return _address(row);
    case SimilarScope.domain:
      final address = _address(row);
      if (address == null) return null;
      final at = address.lastIndexOf('@');
      if (at < 0 || at == address.length - 1) return null;
      return address.substring(at + 1);
    case SimilarScope.subject:
      return subjectPrefixOf(row.subject);
  }
}

/// Every row in [rows] that shares [seed]'s value for [scope], in [rows]'
/// order, the seed included when it is among them. Empty when the scope does
/// not apply to the seed.
List<Conversation> similarRows(
  List<Conversation> rows,
  Conversation seed,
  SimilarScope scope,
) {
  final value = similarValueOf(seed, scope);
  if (value == null) return const [];
  return [
    for (final row in rows)
      if (_matches(row, scope, value)) row,
  ];
}

bool _matches(Conversation row, SimilarScope scope, String value) {
  switch (scope) {
    case SimilarScope.sender:
    case SimilarScope.domain:
      return similarValueOf(row, scope) == value;
    // A PREFIX test on the whole subject rather than a comparison of two
    // prefixes: the rule matcher asks `startsWith`, and a subject whose own
    // prefix reads differently can still start with this one.
    case SimilarScope.subject:
      return (row.subject ?? '').trim().toLowerCase().startsWith(value);
  }
}

String? _address(Conversation row) {
  final raw = (row.latestInboundFrom ?? row.primaryEmail)?.trim().toLowerCase();
  return raw == null || raw.isEmpty ? null : raw;
}
