import 'package:bond_inbox/services/storyline_lint.dart';
import 'package:flutter_test/flutter_test.dart';

/// The charter lint, as a table of fictional sentences.
///
/// Every string here is invented and every name is on an `example.com`-shaped
/// cast: the rule is lexical, so what it needs is coverage of the SHAPES a
/// naming pass produces, not of anybody's real mail.
///
/// What is being pinned is mostly the near misses. A rule that refuses "Dana
/// Whitfield" and also refuses "Dana and Priya on the River Street fit-out"
/// would throw away the storylines this round exists to grow, so each verdict
/// is paired with the sentence that must survive it.
void main() {
  const people = ['Dana Whitfield', 'Priya Raman', 'Alex Rivera'];

  String? lint(String charter, {String title = 'River office lease'}) =>
      charterLint(title: title, charter: charter, participants: people);

  group('placeholder', () {
    test('a placeholder word in the charter is refused', () {
      expect(lint('Miscellaneous threads that did not fit elsewhere.'),
          'placeholder');
      expect(lint('Various items raised during the quarter.'), 'placeholder');
      expect(lint('Assorted follow-ups after the walkthrough.'), 'placeholder');
      expect(lint('Unrelated items parked here.'), 'placeholder');
    });

    test('a placeholder word in the TITLE is refused whatever the charter says',
        () {
      expect(
        charterLint(
          title: 'Untitled storyline',
          charter: 'Fitting out the second-floor suite on River Street.',
          participants: people,
        ),
        'placeholder',
      );
    });

    test('a word that merely contains one passes', () {
      // "variously" is not "various": the rule is on whole words.
      expect(lint('The variously timed inspections of the suite.'), isNull);
    });

    test('general and other are ordinary English about real work', () {
      // Both were in this list and both were wrong. A lint that refused them
      // would throw away exactly the specific storylines it exists to protect.
      expect(
        lint("The general contractor's schedule for the River Street suite."),
        isNull,
      );
      expect(lint('The other suite on River Street.'), isNull);
    });
  });

  group('person', () {
    test('a charter that is only the people is refused', () {
      expect(lint('Dana Whitfield.'), 'person');
      expect(lint('Threads between Dana and Priya.'), 'person');
      expect(lint('Messages involving Alex Rivera and Priya Raman.'), 'person');
    });

    test('the people plus a subject passes', () {
      expect(
        lint('Dana and Priya on the River Street fit-out schedule.'),
        isNull,
      );
      // Three word characters is the floor, so a one-word subject counts.
      expect(lint('Dana on the lease.'), isNull);
    });

    test('a charter naming nobody on the threads is not a roster', () {
      expect(lint('The quarterly budget.'), isNull);
      // Somebody who is not a participant is a subject this rule cannot
      // account for, so it declines rather than guessing.
      expect(lint('Threads about Marcus.'), isNull);
    });

    test('with no participants nothing is a roster', () {
      expect(
        charterLint(
          title: 'A group',
          charter: 'Dana Whitfield.',
          participants: const [],
        ),
        isNull,
      );
    });
  });

  group('category', () {
    test('a bare class of message is refused', () {
      expect(lint('Emails from the leasing team.'), 'category');
      expect(lint('All notifications the building sends.'), 'category');
      expect(lint('Invoices and receipts.'), 'category');
      expect(lint('The updates that arrive each week.'), 'category');
    });

    test('a preposition with nothing after it names no subject', () {
      // "Updates on" is a sentence that stopped, not a charter that says what
      // the updates are about.
      expect(lint('Updates on'), 'category');
      expect(lint('Invoices for '), 'category');
    });

    test('a class of message ABOUT something specific passes', () {
      expect(lint('Emails about the River Street fit-out.'), isNull);
      expect(lint('Invoices for the sprinkler work.'), isNull);
      expect(lint('Alerts on the second-floor suite handover.'), isNull);
    });

    test('the same nouns mid-sentence are ordinary description', () {
      expect(
        lint('Signing the suite lease, including the invoices it generates.'),
        isNull,
      );
    });
  });

  test('a specific charter passes every rule', () {
    expect(
      lint('Signing and fitting out the second-floor suite on River Street: '
          'the addendum, the capped allowance clause and the handover of keys.'),
      isNull,
    );
  });

  test('placeholder is decided before person and category', () {
    // All three would fire. The most certain verdict is the one reported, so
    // a reader counting reasons gets one answer per storyline.
    expect(lint('Miscellaneous emails from Dana.'), 'placeholder');
  });

  test('an empty charter is not a verdict on its own', () {
    // The naming pass writing nothing is a different failure from the naming
    // pass writing a roster, and it is not this function's to report.
    expect(lint(''), isNull);
    expect(lint('   '), isNull);
  });
}
