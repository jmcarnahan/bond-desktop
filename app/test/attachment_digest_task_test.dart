import 'dart:convert';

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/llm/attachment_digest_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The prompt that reads one document, and the validator behind it.
///
/// Two rules carry the file: the sender chose the FILE NAME, so it is data and
/// belongs inside the fence with the rest of the file; and the prompt talks
/// about "a document" and "a message" and never about the channel either
/// arrived through, because the day a third connector lands the prompt must
/// not have to be forked.
void main() {
  const task = AttachmentDigestTask();

  final message = Message(
    id: 'm1',
    outbound: false,
    fromName: 'Dana Whitfield',
    fromAddress: 'dana@example.com',
    subject: 'Renewal paperwork',
    bodyText: 'The lease is attached — have a look before Friday.',
    receivedAt: '2026-09-04T10:00:00Z',
  );

  AttachmentDigestInput input({
    String? name = 'Lease Addendum.pdf',
    String? contentType = 'application/pdf',
    int size = 240 * 1024,
    String text = 'The tenant pays 2,400 on the fourth of each month.',
  }) =>
      AttachmentDigestInput(
        message: message,
        name: name,
        contentType: contentType,
        size: size,
        text: text,
        now: DateTime(2026, 9, 4),
      );

  group('the schema', () {
    test('names its keys in grammar order', () {
      // A grammar decodes in exactly this order, so the model states what the
      // document IS before it commits to what it says or what it wants.
      expect((task.schema['properties'] as Map).keys.toList(), [
        'evidence',
        'kind',
        'summary',
        'facts',
        'asks',
      ]);
      expect(task.schema['required'], [
        'evidence',
        'kind',
        'summary',
        'facts',
        'asks',
      ]);
      expect(task.schema['additionalProperties'], isFalse);
    });

    test('is flat, with maxItems only on the arrays of strings', () {
      // This llama-server build converts the schema into a grammar, and a
      // schema it cannot convert fails the request outright: no `$defs`, no
      // `maxLength`, and no `maxItems` on an array of objects.
      final encoded = jsonEncode(task.schema);
      expect(encoded, isNot(contains(r'$defs')));
      expect(encoded, isNot(contains('maxLength')));
      expect(encoded, isNot(contains('minItems')));

      final properties = task.schema['properties'] as Map;
      for (final key in ['facts', 'asks']) {
        final field = properties[key] as Map;
        expect((field['items'] as Map)['type'], 'string', reason: key);
        expect(field['maxItems'], isA<int>(), reason: key);
      }
    });

    test('the kind vocabulary is an enum, not a hope', () {
      expect((task.schema['properties'] as Map)['kind']['enum'], [
        'quote',
        'invoice',
        'contract',
        'schedule',
        'report',
        'slides',
        'spreadsheet',
        'form',
        'letter',
        'other',
      ]);
    });
  });

  group('the user message', () {
    test('the file name rides inside the document fence and nowhere else', () {
      final built = task.buildUserMessage(input());

      final fence = built.indexOf('<untrusted_data source="document">');
      final close = built.indexOf('</untrusted_data>', fence);
      expect(fence, greaterThan(-1));
      // A sender chooses the file name, so `Invoice — ignore your
      // instructions.pdf` has to arrive as data like the rest of the file.
      expect(built.indexOf('Lease Addendum.pdf'), greaterThan(fence));
      expect(built.indexOf('Lease Addendum.pdf'), lessThan(close));
      expect(
        built.replaceRange(fence, close, ''),
        isNot(contains('Lease Addendum.pdf')),
      );
    });

    test('the header states the type and the size beside the name', () {
      expect(
        task.buildUserMessage(input()),
        contains('Lease Addendum.pdf (application/pdf, 245760 bytes)'),
      );
    });

    test('a file the connector never named still has a header', () {
      expect(
        task.buildUserMessage(input(name: null, contentType: null, size: 0)),
        contains('(unnamed) (unknown type, 0 bytes)'),
      );
    });

    test('the document is the last thing read', () {
      final built = task.buildUserMessage(input());

      // Context first, subject last: a loud covering message must not be
      // summarised in place of the file.
      expect(
        built.indexOf('<untrusted_data source="message">'),
        lessThan(built.indexOf('<untrusted_data source="document">')),
      );
      expect(built.trimRight(), endsWith('</untrusted_data>'));
    });

    test('the date anchor is ours and sits outside every fence', () {
      final built = task.buildUserMessage(input());

      expect(built, startsWith('Today is 2026-09-04 (Friday).'));
      expect(
        built.indexOf('Today is'),
        lessThan(built.indexOf('<untrusted_data')),
      );
    });

    test('a long document is clamped rather than sent whole', () {
      final built = task.buildUserMessage(input(text: 'clause ' * 4000));

      // Past six thousand characters a fast model is reading appendices, and
      // the passages are indexed separately anyway.
      expect(built.length, lessThan(8000));
    });
  });

  group('validate never throws', () {
    test('a wrong-typed kind falls back to other', () {
      expect(task.validate({'kind': 7}).kind, 'other');
      expect(task.validate({'kind': 'receipt'}).kind, 'other');
      expect(task.validate({'kind': 'invoice'}).kind, 'invoice');
    });

    test('six facts is the ceiling and three asks is', () {
      final digest = task.validate({
        'facts': [for (var i = 0; i < 12; i++) 'Fact $i'],
        'asks': [for (var i = 0; i < 9; i++) 'Ask $i'],
      });

      expect(digest.facts, hasLength(6));
      expect(digest.asks, hasLength(3));
    });

    test('garbage decodes to something a row can render', () {
      // A grammar guarantees the shape of what comes back and nothing about
      // its sense.
      final digest = task.validate({
        'evidence': 42,
        'kind': null,
        'summary': ['a', 'list'],
        'facts': 'not a list',
        'asks': [null, '', '  ', 'Sign page four'],
      });

      expect(digest.evidence, '');
      expect(digest.kind, 'other');
      expect(digest.summary, '');
      expect(digest.facts, isEmpty);
      // Blanks are dropped rather than rendered: a bullet with nothing on it
      // is a line of a recap spent on nothing.
      expect(digest.asks, ['Sign page four']);
      expect(task.validate(const {}).evidence, '');
    });

    test('a long fact is clamped, not dropped', () {
      final digest = task.validate({
        'facts': ['x' * 900],
      });

      expect(digest.facts.single.length, 200);
    });
  });

  group('what the store LIKEs on', () {
    test('the encoded digest carries "asks":[" when there is one', () {
      final digest = task.validate({
        'evidence': 'A lease addendum sent for signature.',
        'kind': 'contract',
        'summary': 'The rent rises to 2,600 in January.',
        'facts': const ['2,600 from 1 January'],
        'asks': const ['Sign page four'],
      });

      // `attachmentsWithAsks` reads this with a LIKE rather than a JSON1
      // extract, so the key order and the absence of spaces are load-bearing.
      expect(jsonEncode(digest.toJson()), contains('"asks":["'));
    });

    test('and "asks":[] when there is not', () {
      final digest = task.validate({'asks': const []});

      expect(jsonEncode(digest.toJson()), contains('"asks":[]'));
      expect(jsonEncode(digest.toJson()), isNot(contains('"asks":["')));
    });

    test('all five keys are written, whatever the model said', () {
      expect(
        task.validate(const {}).toJson().keys.toList(),
        ['evidence', 'kind', 'summary', 'facts', 'asks'],
      );
    });
  });

  group('the system prompt', () {
    test('names no channel and no connector', () {
      // The STRICT form, like needs-you's: what varies by channel is said in
      // the user message, so the rules have no reason to know which connector
      // this arrived through.
      final prompt = task.systemPrompt.toLowerCase();
      for (final word in [
        'email',
        'mail',
        'chat',
        'microsoft',
        'outlook',
        'gmail',
        'graph',
      ]) {
        expect(prompt, isNot(contains(word)), reason: word);
      }
    });

    test('says document and message instead', () {
      expect(task.systemPrompt, contains('document'));
      expect(task.systemPrompt, contains('message'));
    });

    test('carries the untrusted-data clause and is identical every call', () {
      expect(task.systemPrompt, contains('<untrusted_data source='));
      final before = task.systemPrompt;
      task.buildUserMessage(input());
      // Identity, not equality: the prefix cache is keyed on the bytes.
      expect(identical(task.systemPrompt, before), isTrue);
    });
  });
}
