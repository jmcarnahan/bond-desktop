import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/select_similar.dart';
import 'package:flutter_test/flutter_test.dart';

/// Select-similar's three scopes over drawn rows — requirement 12c. Pure: the
/// rows are arguments and nothing here stages a store.
Conversation _row(
  String id, {
  String? from,
  String? participant,
  String? subject,
  String source = 'email',
}) =>
    Conversation(
      id: id,
      source: source,
      subject: subject,
      latestInboundFrom: from,
      participants: [
        if (participant != null) Participant(name: 'P', email: participant),
      ],
    );

void main() {
  final rows = [
    _row('a', from: 'Ops@Example.test', subject: 'Accepted: Weekly sync'),
    _row('b', from: 'ops@example.test', subject: 'Accepted: Offsite'),
    _row('c', from: 'lee@example.test', subject: '[JIRA] (KEY-12) Fix login'),
    _row('d', from: 'sam@eu.example.test', subject: 'Re: Budget'),
    _row('e', participant: 'kim@example.test', subject: 'Hello'),
    _row('f', from: 'teams:8f2c', source: 'teams', subject: 'Standup'),
  ];
  List<String> ids(List<Conversation> out) => [for (final c in out) c.id];

  test('sender is one mailbox exactly, folded', () {
    expect(ids(similarRows(rows, rows[0], SimilarScope.sender)), ['a', 'b']);
    expect(similarValueOf(rows[0], SimilarScope.sender), 'ops@example.test');
  });

  test('falls back to the participant when no inbound sender was read', () {
    expect(similarValueOf(rows[4], SimilarScope.sender), 'kim@example.test');
  });

  test('domain is the part after the @, and a subdomain is not it', () {
    expect(
      ids(similarRows(rows, rows[0], SimilarScope.domain)),
      ['a', 'b', 'c', 'e'],
    );
    expect(ids(similarRows(rows, rows[3], SimilarScope.domain)), ['d']);
  });

  test('a Teams sender has no domain, so the scope does not apply', () {
    expect(similarValueOf(rows[5], SimilarScope.domain), isNull);
    expect(similarRows(rows, rows[5], SimilarScope.domain), isEmpty);
    expect(ids(similarRows(rows, rows[5], SimilarScope.sender)), ['f']);
  });

  test('subject selects what a subject rule on the prefix would', () {
    expect(ids(similarRows(rows, rows[1], SimilarScope.subject)), ['a', 'b']);
    expect(ids(similarRows(rows, rows[2], SimilarScope.subject)), ['c']);
    // A reply marker names no kind of mail — see subjectPrefixOf.
    expect(similarRows(rows, rows[3], SimilarScope.subject), isEmpty);
    expect(similarRows(rows, rows[4], SimilarScope.subject), isEmpty);
  });
}
