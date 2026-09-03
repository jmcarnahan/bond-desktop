import 'package:bond_inbox/services/extract_handler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card one message is embedded from.
///
/// Its shape is what makes [cardHash] mean anything: the hash is the only
/// thing standing between a re-run and a wasted embedding call, and it can
/// only be trusted while the same message reliably produces the same string.
void main() {
  group('shape', () {
    test('is always four segments, empty ones included', () {
      final card = buildMessageCard(
        subject: null,
        sender: '',
        summary: null,
        body: null,
      );

      expect(card, ' |  |  | ');
      expect(card.split(' | '), hasLength(4));
    });

    test('keeps the empty slots when only some parts are known', () {
      final card = buildMessageCard(
        subject: 'a',
        sender: 'From: b',
        summary: null,
        body: null,
      );

      expect(card, 'a | From: b |  | ');
    });

    test('orders subject, sender, summary, body', () {
      final card = buildMessageCard(
        subject: 'Launch date',
        sender: 'From: Sarah <sarah@x.com>',
        summary: 'Sarah is asking whether Thursday holds.',
        body: 'Can we still ship on Thursday?',
      );

      expect(
        card,
        'Launch date | From: Sarah <sarah@x.com> | '
        'Sarah is asking whether Thursday holds. | '
        'Can we still ship on Thursday?',
      );
    });

    test('trims each part rather than embedding the whitespace', () {
      final card = buildMessageCard(
        subject: 'Launch date',
        sender: '  From: Sarah  ',
        summary: '  a summary  ',
        body: '\n\n the body \n',
      );

      expect(card, 'Launch date | From: Sarah | a summary | the body');
    });
  });

  group('subject', () {
    test('drops Re: and Fwd: so a reply embeds where its thread does', () {
      final reply = buildMessageCard(
        subject: 'Re: Launch date',
        sender: 'From: b',
        summary: null,
        body: null,
      );
      final forward = buildMessageCard(
        subject: 'Fwd: Launch date',
        sender: 'From: b',
        summary: null,
        body: null,
      );

      expect(reply, startsWith('Launch date | '));
      expect(forward, startsWith('Launch date | '));
      expect(reply, forward);
    });
  });

  group('body cap', () {
    test('clips at exactly messageCardBodyCap characters', () {
      // A vector averaged over four thousand characters of quoted thread is a
      // vector about email in general.
      final long = 'x' * (messageCardBodyCap + 500);

      final card = buildMessageCard(
        subject: 's',
        sender: 'From: b',
        summary: 'm',
        body: long,
      );

      expect(card, 's | From: b | m | ${'x' * messageCardBodyCap}');
      expect(card.split(' | ').last, hasLength(messageCardBodyCap));
    });

    test('a body one character under the cap is untouched', () {
      final body = 'y' * (messageCardBodyCap - 1);

      final card = buildMessageCard(
        subject: 's',
        sender: 'From: b',
        summary: 'm',
        body: body,
      );

      expect(card.split(' | ').last, body);
    });
  });

  group('hashing', () {
    test('the same message twice is the same hash — the guard that saves the '
        'call', () {
      String card() => buildMessageCard(
            subject: 'Launch date',
            sender: 'From: Sarah <sarah@x.com>',
            summary: 'Thursday?',
            body: 'Can we still ship on Thursday?',
          );

      expect(cardHash(card()), cardHash(card()));
    });

    test('a changed body is a changed hash', () {
      final before = buildMessageCard(
        subject: 'Launch date',
        sender: 'From: Sarah',
        summary: 'Thursday?',
        body: 'Can we still ship on Thursday?',
      );
      final after = buildMessageCard(
        subject: 'Launch date',
        sender: 'From: Sarah',
        summary: 'Thursday?',
        body: 'Can we still ship on Friday?',
      );

      expect(cardHash(before), isNot(cardHash(after)));
    });

    test('a changed summary is a changed hash', () {
      final before = buildMessageCard(
        subject: 'Launch date',
        sender: 'From: Sarah',
        summary: null,
        body: 'Thursday?',
      );
      final after = buildMessageCard(
        subject: 'Launch date',
        sender: 'From: Sarah',
        summary: 'Sarah is asking about the ship date.',
        body: 'Thursday?',
      );

      expect(cardHash(before), isNot(cardHash(after)));
    });
  });
}
