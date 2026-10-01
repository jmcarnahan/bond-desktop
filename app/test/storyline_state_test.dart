import 'dart:convert';
import 'dart:io';

import 'package:bond_inbox/services/decision/storyline_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart storyline renderers against the texts the Python rendered for the
/// same inputs. `test/fixtures/decision/render_cases_v2.json` is regenerated
/// by jev-prototype `distill/export/render_fixtures_v2.py` after any change to
/// `distill/eval_questions/renderers.py`, and never edited by hand; its cases
/// are fictional. Byte for byte: the storyline heads were trained on the
/// Python's output.

/// Where two strings first differ, and a window of each around it.
String _firstDifference(String actual, String expected) {
  final n = actual.length < expected.length ? actual.length : expected.length;
  var i = 0;
  while (i < n && actual.codeUnitAt(i) == expected.codeUnitAt(i)) {
    i++;
  }
  String window(String s) {
    final from = i < 40 ? 0 : i - 40;
    final to = i + 40 > s.length ? s.length : i + 40;
    return jsonEncode(s.substring(from, to));
  }

  return 'first difference at UTF-16 index $i '
      '(actual length ${actual.length}, expected ${expected.length})\n'
      '  actual:   ${window(actual)}\n'
      '  expected: ${window(expected)}';
}

String _thread(Map<String, dynamic> t) => renderStorylineThread(
      subject: t['subject'] as String?,
      participants: (t['participants'] as List?)?.cast<String?>(),
      messages: (t['messages'] as List?)
          ?.cast<Map<String, dynamic>>()
          .map((m) => StorylineMessage(
                who: m['who'] as String?,
                text: m['text'] as String?,
              ))
          .toList(),
    );

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/decision/render_cases_v2.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final cases = (fixture['cases'] as Map<String, dynamic>)
      .map((k, v) => MapEntry(k, (v as List).cast<Map<String, dynamic>>()));

  void expectBytes(String actual, String expected, String id) {
    if (actual != expected) fail('$id: ${_firstDifference(actual, expected)}');
  }

  test('the fixture is bond-state/2 with all 174 cases', () {
    expect(fixture['renderer'], 'bond-state/2');
    expect(cases['thread'], hasLength(52));
    expect(cases['pair'], hasLength(41));
    expect(cases['membership'], hasLength(41));
    expect(cases['charter'], hasLength(40));
  });

  test("the constants and the whitespace set are the Python's", () {
    final c = fixture['constants'] as Map<String, dynamic>;
    expect(c['THREAD_MESSAGES'], storylineThreadMessages);
    expect(c['MESSAGE_CAP'], storylineMessageCap);
    expect(c['WHO_CAP'], storylineWhoCap);
    expect(c['SUBJECT_CAP'], storylineSubjectCap);
    expect(c['PEOPLE_MAX'], storylinePeopleMax);
    expect(c['PEOPLE_NAME_CAP'], storylinePeopleNameCap);
    expect(c['TITLE_CAP'], storylineTitleCap);
    expect(c['CHARTER_CAP'], storylineCharterCap);
    expect(c['MESSAGE_SEP'], storylineMessageSep);
    expect(
      storylineWhitespace,
      (fixture['whitespace_code_points'] as List).cast<int>().toSet(),
    );
  });

  group('thread', () {
    for (final c in cases['thread']!) {
      test('${c['id']}: ${c['why']}', () {
        expectBytes(_thread(c['input'] as Map<String, dynamic>),
            c['expected'] as String, c['id'] as String);
      });
    }
  });

  group('pair, both orders', () {
    for (final c in cases['pair']!) {
      test('${c['id']}: ${c['why']}', () {
        final input = c['input'] as Map<String, dynamic>;
        final a = _thread(input['a'] as Map<String, dynamic>);
        final b = _thread(input['b'] as Map<String, dynamic>);
        expectBytes(renderStorylinePair(a, b), c['expected'] as String,
            c['id'] as String);
        expectBytes(renderStorylinePair(b, a),
            c['expected_reversed'] as String, '${c['id']} reversed');
      });
    }
  });

  group('membership', () {
    for (final c in cases['membership']!) {
      test('${c['id']}: ${c['why']}', () {
        final input = c['input'] as Map<String, dynamic>;
        expectBytes(
          renderStorylineMembership(
            title: input['title'] as String?,
            charter: input['charter'] as String?,
            threadText: _thread(input['thread'] as Map<String, dynamic>),
          ),
          c['expected'] as String,
          c['id'] as String,
        );
      });
    }
  });

  group('charter', () {
    for (final c in cases['charter']!) {
      test('${c['id']}: ${c['why']}', () {
        final input = c['input'] as Map<String, dynamic>;
        expectBytes(
          renderStorylineCharter(
            title: input['title'] as String?,
            charter: input['charter'] as String?,
          ),
          c['expected'] as String,
          c['id'] as String,
        );
      });
    }
  });

  group('pyLower', () {
    test("İ lowers to i + U+0307, as Python's does", () {
      expect(pyLower('İpek'), 'i̇pek');
      expect(pyLower('IPEK'), 'ipek');
    });

    test('a word-final capital sigma lowers to ς, a medial one to σ', () {
      expect(pyLower('ΟΔΥΣΣΕΑΣ Π'), 'οδυσσεας π');
      expect(pyLower('ΣΑΣ'), 'σας');
      expect(pyLower('Σ'), 'σ');
      expect(pyLower('AΣ.'), 'aς.');
      expect(pyLower("AΣ'Β"), "aσ'β");
    });

    test('ß stays ß: lower, not case folding', () {
      expect(pyLower('Jana Strauß'), 'jana strauß');
      expect(pyLower('JANA STRAUSS'), 'jana strauss');
    });
  });
}
