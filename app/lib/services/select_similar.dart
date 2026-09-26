import '../models/message_models.dart';

/// "Select similar" over the drawn Needs You rows — requirement 12c's one click
/// that clears a whole class of mail.
///
/// Pure: the rows arrive as arguments and nothing here reads a store, so the
/// three scopes are table-testable.
///
/// Each scope names a class a reader can see on the drawn row, so what the chip
/// selects is exactly what its label says:
/// - [SimilarScope.sender] is one mailbox, exactly.
/// - [SimilarScope.domain] is the address's domain part, exactly, and never its
///   subdomains: a chip labelled `example.test` selecting `eu.example.test`
///   would select rows its own label does not name.
/// - [SimilarScope.subject] is [subjectPrefixOf] and a prefix test, so the chip
///   selects the rows whose subject opens with the same machine-written front.
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
    // prefixes: a subject whose own prefix reads differently can still start
    // with this one.
    case SimilarScope.subject:
      return (row.subject ?? '').trim().toLowerCase().startsWith(value);
  }
}

String? _address(Conversation row) {
  final raw = (row.latestInboundFrom ?? row.primaryEmail)?.trim().toLowerCase();
  return raw == null || raw.isEmpty ? null : raw;
}

/// The front of a subject, when it has one select-similar can group by.
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
/// kind of mail, and select-similar on `re:` would select every reply.
///
/// Lowercased, because the chip compares folded values.
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
/// this one only names the prefix select-similar groups by.
final RegExp _bracketedTag = RegExp(r'^\s*\[[^\]]{1,24}\]\s*');

const int _subjectPrefixCap = 24;
const int _subjectPrefixFloor = 3;
