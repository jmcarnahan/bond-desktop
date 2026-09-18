import 'dart:convert';

import 'package:bond_inbox/services/llm/partial_json.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reader that turns a half-arrived JSON object into the words a person is
/// waiting to read.
///
/// Split at EVERY boundary rather than at a few chosen ones, because every
/// interesting failure of an incremental parser is a boundary: inside a key,
/// inside an escape, between the two halves of a surrogate pair, after the
/// backslash and before the `u`. A handful of hand-picked splits would test the
/// four the author thought of.

/// A draft in the shape `DraftTask` asks for, carrying every awkward thing a
/// model actually writes: a newline, an escaped quote, an accented letter as a
/// `\uXXXX` escape, and an emoji as a surrogate pair.
const String draftJson =
    r'{"evidence":"Tom Alvarez asks whether Friday still works.",'
    r'"options":[{"stance":"Accept","reply_body":"Friday works \u2014 see you at seven."},'
    r'{"stance":"Decline","reply_body":"Cannot make Friday, sorry."}],'
    r'"reply_body":"Hi Tom,\n\nFriday works. You said \"seven\" at the caf\u00e9 \ud83d\ude00\n\nAlex"}';

/// Every string VALUE the object holds, by the path the reader should report
/// it under — decoded by `dart:convert` rather than written out again, so the
/// expectation cannot drift from the fixture.
Map<String, String> expectedStrings() {
  final decoded = jsonDecode(draftJson) as Map<String, dynamic>;
  final options = decoded['options'] as List;
  return {
    'evidence': decoded['evidence'] as String,
    'options[0].stance': (options[0] as Map)['stance'] as String,
    'options[0].reply_body': (options[0] as Map)['reply_body'] as String,
    'options[1].stance': (options[1] as Map)['stance'] as String,
    'options[1].reply_body': (options[1] as Map)['reply_body'] as String,
    'reply_body': decoded['reply_body'] as String,
  };
}

/// Feeds [chunks] through one reader and returns the deltas concatenated per
/// path, in the order the paths first appeared.
Map<String, String> readAll(List<String> chunks) {
  final reader = PartialJsonStrings();
  final out = <String, String>{};
  for (final chunk in chunks) {
    for (final part in reader.feed(chunk)) {
      out[part.path] = (out[part.path] ?? '') + part.delta;
    }
  }
  return out;
}

void main() {
  group('PartialJsonStrings', () {
    test('reads every string value whole, split at any single boundary', () {
      final expected = expectedStrings();
      for (var i = 1; i < draftJson.length; i++) {
        final read = readAll([
          draftJson.substring(0, i),
          draftJson.substring(i),
        ]);
        expect(read, expected, reason: 'split after character $i');
      }
    });

    test('and split into three, at any pair of boundaries', () {
      final expected = expectedStrings();
      for (var i = 1; i < draftJson.length; i++) {
        for (var j = i; j < draftJson.length; j++) {
          final read = readAll([
            draftJson.substring(0, i),
            draftJson.substring(i, j),
            draftJson.substring(j),
          ]);
          expect(read, expected, reason: 'split after $i and $j');
        }
      }
    });

    test('never emits a key, however the keys are split', () {
      // Implied by the maps above matching exactly, and stated on its own
      // because it is the property the composer depends on: a preview that
      // printed `reply_body` as text would be showing the reader the wiring.
      for (var i = 1; i < draftJson.length; i++) {
        final read = readAll([
          draftJson.substring(0, i),
          draftJson.substring(i),
        ]);
        expect(read.keys.toSet(), expectedStrings().keys.toSet());
        // None of the four key spellings appears in any value, so a key that
        // leaked into the text would show up here as well as in the paths.
        final text = read.values.join();
        for (final key in ['evidence', 'options', 'stance', 'reply_body']) {
          expect(text.contains(key), isFalse, reason: 'key $key leaked');
        }
      }
    });

    test('a truncated tail is not an error — it is the rest, not yet here', () {
      for (var i = 0; i <= draftJson.length; i++) {
        final reader = PartialJsonStrings();
        expect(() => reader.feed(draftJson.substring(0, i)), returnsNormally);
      }
    });

    test('an escape split across chunks still decodes', () {
      // The four places an escape can be cut, one per chunk boundary.
      const before = r'{"reply_body":"see you \u';
      expect(readAll([before, r'2014 Friday"}']), {
        'reply_body': 'see you — Friday',
      });
      expect(readAll([r'{"reply_body":"see you \u20', r'14 Friday"}']), {
        'reply_body': 'see you — Friday',
      });
      expect(readAll([r'{"reply_body":"a\', r'nb"}']), {'reply_body': 'a\nb'});
      expect(readAll([r'{"reply_body":"a\', r'"b"}']), {'reply_body': 'a"b'});
    });

    test('holds a high surrogate back until its low half arrives', () {
      final reader = PartialJsonStrings();
      // The words before it, and NOT the half-emoji: a lone surrogate on
      // screen is worse than a beat of nothing.
      expect(reader.feed(r'{"reply_body":"hi \ud83d'), [
        (path: 'reply_body', delta: 'hi '),
      ]);
      final rest = reader.feed(r'\ude00 there"}');
      expect(rest.single.path, 'reply_body');
      expect(rest.single.delta, '😀 there');
    });

    test('an unpaired high surrogate is emitted rather than dropped', () {
      // Dart strings tolerate a lone unit, and losing a character the model
      // wrote would be the worse failure.
      final read = readAll([r'{"reply_body":"\ud83dx"}']);
      expect(read['reply_body'], '\ud83dx');
    });

    test('numbers, booleans and nulls emit nothing at all', () {
      final read = readAll([
        '{"n":42,"pi":3.5,"yes":true,"no":false,"nothing":null,'
            '"only":"this one"}',
      ]);
      expect(read, {'only': 'this one'});
    });

    test('paths carry array positions and nesting', () {
      final read = readAll([
        '{"options":[{"stance":"a"},{"stance":"b","reply_body":"c"}],"d":"e"}',
      ]);
      expect(read, {
        'options[0].stance': 'a',
        'options[1].stance': 'b',
        'options[1].reply_body': 'c',
        'd': 'e',
      });
    });

    test('a value arriving in pieces is reported in pieces, in order', () {
      final reader = PartialJsonStrings();
      expect(reader.feed('{"reply_body":"Hi '), [
        (path: 'reply_body', delta: 'Hi '),
      ]);
      expect(reader.feed('Tom'), [(path: 'reply_body', delta: 'Tom')]);
      expect(reader.feed('"}'), isEmpty);
    });
  });
}
