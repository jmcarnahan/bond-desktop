import 'package:bond_inbox/services/sender_display.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one rule under every place a sender is named: **a `teams:` id is never
/// shown to the reader.** It is an identity key the row is filed by, and it
/// reached the screen — sender line and avatar letter both — for every chat bot
/// Graph handed over with no display name.
///
/// Pure, so the table is the test. What it pins is the order of the rungs and
/// the fact that the pseudo-address is the ONLY address that gets skipped: a
/// bare mail address still names its sender better than any word this file
/// could put there.
void main() {
  group('displaySenderName', () {
    test('a name wins, whatever the address is', () {
      expect(
        displaySenderName(
          name: 'Sarah Whitfield',
          address: 'sarah@example.com',
        ),
        'Sarah Whitfield',
      );
      expect(
        displaySenderName(
          name: 'Release Facilitator',
          address: 'teams:8e55a7b1-4c2d-4f1a-9b3e-77d0c1e2a5f4',
        ),
        'Release Facilitator',
      );
    });

    test('a mail address stands in for a name it does not have', () {
      expect(
        displaySenderName(address: 'dana@example.com'),
        'dana@example.com',
      );
      expect(
        displaySenderName(name: '', address: 'dana@example.com'),
        'dana@example.com',
      );
      expect(
        displaySenderName(name: '   ', address: 'dana@example.com'),
        'dana@example.com',
      );
    });

    test('a teams id never stands in for anything', () {
      expect(
        displaySenderName(address: 'teams:8e55a7b1-4c2d-4f1a-9b3e-77d0c1e2a5f4'),
        unknownSenderName,
      );
      expect(
        displaySenderName(
          name: '',
          address: 'teams:8e55a7b1-4c2d-4f1a-9b3e-77d0c1e2a5f4',
        ),
        unknownSenderName,
      );
      // Whitespace ahead of it is still the same key — an address is compared
      // the way it would be shown, trimmed.
      expect(
        displaySenderName(address: '  teams:app-9'),
        unknownSenderName,
      );
    });

    test('nothing at all is the fallback', () {
      expect(displaySenderName(), unknownSenderName);
      expect(displaySenderName(name: '', address: ''), unknownSenderName);
      expect(displaySenderName(name: null, address: null), unknownSenderName);
    });

    test('the caller may say its own last word', () {
      // The transcript's own message and a list card have said `You` and
      // `(no sender)` since long before this file, and neither wording is this
      // file's to change.
      expect(displaySenderName(fallback: 'You'), 'You');
      expect(
        displaySenderName(address: 'teams:app-9', fallback: '(no sender)'),
        '(no sender)',
      );
      // The fallback is the LAST rung and never overrides a usable name.
      expect(
        displaySenderName(name: 'Dana Ruiz', fallback: 'You'),
        'Dana Ruiz',
      );
    });
  });

  group('isPseudoAddress', () {
    test('only a teams id is one', () {
      expect(isPseudoAddress('teams:app-9'), isTrue);
      expect(isPseudoAddress('sarah@example.com'), isFalse);
      expect(isPseudoAddress(''), isFalse);
      expect(isPseudoAddress(null), isFalse);
      // A mail address that merely mentions the word is not a key.
      expect(isPseudoAddress('teams@example.com'), isFalse);
    });
  });

  group('isBotSender', () {
    test('the word ingest writes for a nameless application says so', () {
      expect(isBotSender(name: botSenderName, address: 'teams:app-9'), isTrue);
      // Whitespace around it is the same word.
      expect(isBotSender(name: '  Bot  '), isTrue);
    });

    test('a chat sender with an id and no name is the same bot, older', () {
      // A row stored before ingest named its bots. A Teams PERSON arrives from
      // Graph with a display name, so a name-less chat sender is the
      // application whose name Graph withheld.
      expect(isBotSender(address: 'teams:8e55a7b1-4c2d'), isTrue);
      expect(isBotSender(name: '', address: 'teams:8e55a7b1-4c2d'), isTrue);
    });

    test('a person is not', () {
      expect(
        isBotSender(name: 'Sarah Whitfield', address: 'teams:u1'),
        isFalse,
      );
      expect(isBotSender(name: 'Dana Ruiz', address: 'dana@example.com'),
          isFalse);
      // A mail sender known only by address is a person nobody named, not a
      // bot: mail carries no application senders for this to be about.
      expect(isBotSender(address: 'noreply@example.com'), isFalse);
      expect(isBotSender(), isFalse);
    });
  });
}
