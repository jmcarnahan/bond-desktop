import 'dart:convert';

import 'package:bond_inbox/models/attachment_models.dart';
import 'package:bond_inbox/services/attachments/attachment_digest_lines.dart';
import 'package:flutter_test/flutter_test.dart';

/// One line per document, for the judgement that decides whether the owner is
/// needed.
///
/// The lines go inside a fence the caller wraps, so nothing here escapes
/// anything — what it does have to get right is which rows earn a line at all,
/// and that a file's own name never runs away with the prompt.
void main() {
  Map<String, Object?> row({
    String? name = 'Lease Addendum.pdf',
    String summary = 'The rent rises to 2,600 in January.',
    List<String> asks = const [],
    bool digested = true,
  }) =>
      {
        'name': name,
        'digest_json': digested
            ? jsonEncode(AttachmentDigest(
                evidence: 'A lease addendum sent for signature.',
                kind: 'contract',
                summary: summary,
                asks: asks,
              ).toJson())
            : null,
      };

  test('a document says what it is and what it wants', () {
    final lines = attachmentDigestLines([
      row(asks: const ['Sign and return by Thursday', 'Confirm the new rent']),
    ]);

    expect(lines.single,
        'Lease Addendum.pdf: The rent rises to 2,600 in January. '
        'Asks: Sign and return by Thursday; Confirm the new rent');
  });

  test('a document that wants nothing says only what it is', () {
    expect(
      attachmentDigestLines([row()]).single,
      'Lease Addendum.pdf: The rent rises to 2,600 in January.',
    );
  });

  test('a document nobody has read yet earns no line', () {
    // "Not read yet" and "says nothing" are different states, and a name with
    // nothing after it would put the first in front of the model as the second.
    expect(attachmentDigestLines([row(digested: false)]), isEmpty);
  });

  test('a nameless file still says so', () {
    expect(attachmentDigestLines([row(name: null)]).single,
        startsWith('a file: '));
  });

  test('one runaway line cannot be the whole prompt', () {
    final line = attachmentDigestLines([row(summary: 'S' * 900)]).single;

    expect(line.length, 300);
  });

  test('a digest nothing can parse is skipped rather than thrown on', () {
    expect(
      attachmentDigestLines([
        {'name': 'Broken.pdf', 'digest_json': '{not json'},
      ]),
      isEmpty,
    );
  });

  test('an empty ask is not an ask', () {
    expect(
      attachmentDigestLines([row(asks: const ['  ', ''])]).single,
      isNot(contains('Asks:')),
    );
  });
}
