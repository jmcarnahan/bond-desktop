import 'package:flutter_test/flutter_test.dart';

import 'fixtures/corpus.dart';
import 'fixtures/prose_cases.dart';

/// The invariants `llm_prose_live_test.dart` assumes and cannot check.
///
/// The live bench needs a model server, so it runs almost never; these run on
/// every change. What they guard is the difference between a bench that
/// measured the prose slot and one that measured a broken fixture: a card with
/// the wrong number of segments is input the app never sends, a recap line
/// with no sender is a line nobody said, a draft case naming an id the corpus
/// does not have crashes twenty minutes into a live run, and a draft case
/// whose last message is the OWNER's asks the model to reply to itself.

void main() {
  group('the naming cases', () {
    test('every card is the four-segment card the app builds', () {
      for (final nameCase in nameCases) {
        for (final card in nameCase.cards) {
          // Exactly three separators, so exactly four segments — the shape
          // `buildConversationCard` produces and `NameStorylineTask` is fed in
          // production. A segment carrying its own ' | ' would split the card
          // into something the model reads as a different field.
          expect(
            ' | '.allMatches(card).length,
            3,
            reason: '${nameCase.id}: $card',
          );
        }
      }
    });

    test('every storyline has two to four threads to name', () {
      for (final nameCase in nameCases) {
        expect(nameCase.cards.length, inInclusiveRange(2, 4),
            reason: nameCase.id);
      }
    });
  });

  group('the recap cases', () {
    test('every line names who said it', () {
      // `[subject] sender: text`, the subject bracket dropped when there is
      // none — `StorylineService._recapLine`'s shape, and the one thing these
      // hand-written fixtures can get wrong that the naming cases cannot,
      // since those are built by the production formatter. A line with no
      // `sender: ` is a line the model reads as narration by nobody.
      final line = RegExp(r'^(\[[^\]]+\] )?[^:\[\]]+: \S');
      for (final recapCase in recapCases) {
        for (final message in recapCase.messageLines) {
          expect(line.hasMatch(message), isTrue,
              reason: '${recapCase.id}: $message');
        }
      }
    });

    test('every window is one the store could have produced', () {
      for (final recapCase in recapCases) {
        // `recentStorylineMessages` takes the newest twelve. A fixture with
        // more would bench the model on a window the app never sends, and one
        // with fewer than two would not be a storyline told across threads.
        expect(recapCase.messageLines.length, inInclusiveRange(2, 12),
            reason: recapCase.id);
        expect(recapCase.title, isNotEmpty, reason: recapCase.id);
      }
    });

    test('the owner is rendered as You, never by name', () {
      // The recap prompt's hardest judgement is who is waiting on whom, and
      // `_recapLine` answers it by naming the inbox owner `You` — a fixture
      // that wrote "Alex Rivera:" instead would be benching a mailbox
      // belonging to somebody else.
      for (final recapCase in recapCases) {
        for (final message in recapCase.messageLines) {
          expect(message.contains('Alex Rivera:'), isFalse,
              reason: '${recapCase.id}: $message');
        }
      }
    });
  });

  group('the draft cases', () {
    test('every message id names a corpus entry', () {
      for (final draft in draftCases) {
        for (final id in draft.messageIds) {
          expect(corpusById.containsKey(id), isTrue,
              reason: '${draft.id} names $id, which the corpus does not have');
        }
      }
    });

    test('the reply target is always inbound', () {
      for (final draft in draftCases) {
        final thread = draftThread(draft);
        expect(thread, isNotEmpty, reason: draft.id);
        // The last message is what the draft answers. An outbound one would
        // have the model reply to the inbox owner's own words.
        expect(thread.last.message.outbound, isFalse,
            reason: '${draft.id}: ${thread.last.id} is outbound');
      }
    });
  });

  test('every case id is unique', () {
    // The ids are what a live run's printed output is read by, and two rows
    // labelled the same are two rows nobody can tell apart.
    final ids = [
      for (final nameCase in nameCases) nameCase.id,
      for (final recapCase in recapCases) recapCase.id,
      for (final draft in draftCases) draft.id,
    ];
    expect(ids.toSet().length, ids.length, reason: ids.toString());
  });
}
