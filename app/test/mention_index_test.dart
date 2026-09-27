import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/mention_index.dart';
import 'package:flutter_test/flutter_test.dart';

Message _msg({
  String id = 'm1',
  bool outbound = false,
  bool addressedMe = false,
  List<String> actionItems = const [],
  bool? needsYouVerdict,
}) {
  return Message(
    id: id,
    outbound: outbound,
    addressedMe: addressedMe,
    actionItems: actionItems,
    needsYouVerdict: needsYouVerdict,
  );
}

void main() {
  group('namesOwner', () {
    // One table for the whole rule: the definition of "this message names you"
    // is the thing the navigator counts, the marker draws and the walk steps
    // along, so it is pinned in one readable place rather than inferred from
    // three widget tests.
    final cases = <String, (Message, bool)>{
      'an inbound message addressed to the owner': (
        _msg(addressedMe: true),
        true,
      ),
      'an inbound message carrying an action item for the owner': (
        _msg(actionItems: ['send the deck']),
        true,
      ),
      'both at once is still one mention': (
        _msg(addressedMe: true, actionItems: ['send the deck']),
        true,
      ),
      'an inbound message that did neither': (_msg(), false),
      'the owner addressing themselves in their own reply': (
        _msg(outbound: true, addressedMe: true),
        false,
      ),
      'an outbound message with action items the owner wrote down': (
        _msg(outbound: true, actionItems: ['send the deck']),
        false,
      ),
      'an action item that is only whitespace': (
        _msg(actionItems: ['   ']),
        false,
      ),
      'a whitespace item beside a real one': (
        _msg(actionItems: ['  ', 'send the deck']),
        true,
      ),
      // The Jira broadcast: an extracted task on a message the judge read and
      // said is somebody else's.
      'an action item on a message the judge said no to': (
        _msg(actionItems: ['Review the issue'], needsYouVerdict: false),
        false,
      ),
      'an action item the judge agreed with': (
        _msg(actionItems: ['send the deck'], needsYouVerdict: true),
        true,
      ),
      'a real mention the judge said no to is still a mention': (
        _msg(addressedMe: true, needsYouVerdict: false),
        true,
      ),
    };

    cases.forEach((name, expected) {
      test(name, () {
        expect(namesOwner(expected.$1), expected.$2);
      });
    });

    test('an empty action-items list is not a mention', () {
      // The extraction pass writes an empty list for "nothing asked of you",
      // which is most messages in a busy thread.
      expect(namesOwner(_msg(actionItems: const [])), isFalse);
    });
  });

  group('mentionIndexOf', () {
    test('keeps transcript order and drops everything else', () {
      final index = mentionIndexOf([
        _msg(id: 'a'),
        _msg(id: 'b', addressedMe: true),
        _msg(id: 'c', outbound: true),
        _msg(id: 'd', actionItems: ['review the draft']),
        _msg(id: 'e'),
      ]);
      expect(index, ['b', 'd']);
    });

    test('a thread that names the owner nowhere indexes to nothing', () {
      expect(mentionIndexOf([_msg(id: 'a'), _msg(id: 'b')]), isEmpty);
    });

    test('no messages at all is empty, not an error', () {
      expect(mentionIndexOf(const []), isEmpty);
    });

    test('a message with no id is skipped', () {
      // An id is what a jump scrolls to and a flash is keyed by, so a row
      // without one cannot be a stop on the walk however loudly it names you.
      expect(
        mentionIndexOf([_msg(id: '', addressedMe: true), _msg(id: 'b',
            addressedMe: true)]),
        ['b'],
      );
    });
  });

  group('stepMention', () {
    const index = ['a', 'b', 'c'];

    test('the first step forward lands on the first mention', () {
      // Not the second: null means "you have not started", so the first press
      // must not skip the mention nearest the top.
      expect(stepMention(index, null, forward: true), 'a');
    });

    test('the first step back lands on the last mention', () {
      expect(stepMention(index, null, forward: false), 'c');
    });

    test('forward walks the index in order', () {
      expect(stepMention(index, 'a', forward: true), 'b');
      expect(stepMention(index, 'b', forward: true), 'c');
    });

    test('back walks it the other way', () {
      expect(stepMention(index, 'c', forward: false), 'b');
      expect(stepMention(index, 'b', forward: false), 'a');
    });

    test('the walk STOPS at each end rather than wrapping', () {
      // Wrapping would teleport a reader who pressed once too often from the
      // bottom of the thread to the top, with nothing on screen saying so.
      expect(stepMention(index, 'c', forward: true), isNull);
      expect(stepMention(index, 'a', forward: false), isNull);
    });

    test('a message that is not a mention starts the walk over', () {
      // The reader scrolled somewhere else by hand; the next press is a fresh
      // start rather than a step from a stop that is not on the index.
      expect(stepMention(index, 'zz', forward: true), 'a');
      expect(stepMention(index, 'zz', forward: false), 'c');
    });

    test('an empty index has no step in either direction', () {
      expect(stepMention(const [], null, forward: true), isNull);
      expect(stepMention(const [], 'a', forward: false), isNull);
    });

    test('a single mention is one stop with nothing either side', () {
      expect(stepMention(const ['only'], null, forward: true), 'only');
      expect(stepMention(const ['only'], 'only', forward: true), isNull);
      expect(stepMention(const ['only'], 'only', forward: false), isNull);
    });
  });
}
