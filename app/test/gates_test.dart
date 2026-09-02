import 'dart:convert';

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/gates.dart';
import 'package:flutter_test/flutter_test.dart';

/// An inbound message with only the fields the gates read.
Message message({
  String source = 'email',
  String? from = 'sarah@example.com',
  Map<String, String>? headers,
}) =>
    Message(
      id: 'm1',
      source: source,
      outbound: false,
      fromAddress: from,
      sourceMetaJson: headers == null ? null : jsonEncode({'headers': headers}),
    );

void main() {
  group('self', () {
    test('the signed-in mailbox gates, case-insensitively', () {
      expect(
        gateFor(message(from: 'LO@bond.com'), userAddress: 'lo@bond.com'),
        'self',
      );
      expect(
        gateFor(message(from: 'lo@bond.com'), userAddress: 'LO@BOND.com'),
        'self',
      );
    });

    test('a null or empty userAddress skips the gate entirely', () {
      expect(gateFor(message(from: 'lo@bond.com'), userAddress: null), isNull);
      expect(gateFor(message(from: 'lo@bond.com'), userAddress: ''), isNull);
    });

    test('beats no_reply — who sent it is the stronger signal', () {
      expect(
        gateFor(
          message(from: 'noreply@bond.com'),
          userAddress: 'noreply@bond.com',
        ),
        'self',
      );
    });
  });

  group('no_reply', () {
    const gated = [
      'no-reply@x.com',
      'noreply@x.com',
      'no_reply@x.com',
      'no.reply@x.com',
      'do.not.reply@x.com',
      'donotreply@x.com',
      'notification@x.com',
      'notifications@x.com',
      'alert@x.com',
      'alerts@x.com',
      'mailer-daemon@x.com',
      'postmaster@x.com',
      'bounce@x.com',
      'bounces@x.com',
      'NoReply@X.com',
    ];

    for (final address in gated) {
      test('$address gates', () {
        expect(gateFor(message(from: address), userAddress: null), 'no_reply');
      });
    }

    // The prefix anchor doing its job. Every one of these is a plausible
    // human or product mailbox that a substring match would have swallowed.
    const allowed = [
      'not-a-noreply@x.com',
      'nota@x.com',
      'renotify@x.com',
      'salerts@x.com',
      'no@x.com',
      'sarah@x.com',
      'rebounce@x.com',
    ];

    for (final address in allowed) {
      test('$address does not gate', () {
        expect(gateFor(message(from: address), userAddress: null), isNull);
      });
    }

    test('matches the local part only, never the domain', () {
      expect(
        gateFor(message(from: 'sarah@noreply.com'), userAddress: null),
        isNull,
      );
    });
  });

  group('newsletter', () {
    test('list-unsubscribe gates', () {
      expect(
        gateFor(
          message(headers: const {'list-unsubscribe': '<mailto:u@x.com>'}),
          userAddress: null,
        ),
        'newsletter',
      );
    });

    test('list-id gates', () {
      expect(
        gateFor(
          message(headers: const {'list-id': '<news.x.com>'}),
          userAddress: null,
        ),
        'newsletter',
      );
    });

    for (final value in const ['bulk', 'list', 'junk', 'auto_reply', 'BULK']) {
      test('precedence $value gates', () {
        expect(
          gateFor(
            message(headers: {'precedence': value}),
            userAddress: null,
          ),
          'newsletter',
        );
      });
    }

    test('precedence first-class is ordinary mail', () {
      expect(
        gateFor(
          message(headers: const {'precedence': 'first-class'}),
          userAddress: null,
        ),
        isNull,
      );
    });
  });

  group('auto_generated', () {
    test('auto-submitted with any value but "no" gates', () {
      expect(
        gateFor(
          message(headers: const {'auto-submitted': 'auto-generated'}),
          userAddress: null,
        ),
        'auto_generated',
      );
      expect(
        gateFor(
          message(headers: const {'auto-submitted': 'auto-replied'}),
          userAddress: null,
        ),
        'auto_generated',
      );
    });

    test('auto-submitted: no is the explicit "a human sent this"', () {
      expect(
        gateFor(
          message(headers: const {'auto-submitted': 'no'}),
          userAddress: null,
        ),
        isNull,
      );
    });

    test('x-auto-response-suppress gates on presence alone', () {
      expect(
        gateFor(
          message(headers: const {'x-auto-response-suppress': 'All'}),
          userAddress: null,
        ),
        'auto_generated',
      );
    });
  });

  group('nothing to gate on', () {
    test('an ordinary email with no headers proceeds to the model', () {
      expect(gateFor(message(), userAddress: 'lo@bond.com'), isNull);
    });

    test('a message with no sender proceeds', () {
      expect(gateFor(message(from: null), userAddress: 'lo@bond.com'), isNull);
    });

    test('malformed source_meta_json is read as no headers', () {
      final broken = Message(
        id: 'm1',
        outbound: false,
        fromAddress: 'sarah@x.com',
        sourceMetaJson: 'not json',
      );
      expect(broken.headers, isEmpty);
      expect(gateFor(broken, userAddress: null), isNull);
    });

    test('a source this app has never heard of has no gates', () {
      expect(
        gateFor(
          message(source: 'slack', from: 'noreply@x.com'),
          userAddress: null,
        ),
        isNull,
      );
    });
  });

  group('teams', () {
    Message chat({String? body, String? preview}) => Message(
          id: 'c1',
          source: 'teams',
          outbound: false,
          fromAddress: 'teams:user-1',
          bodyText: body,
          bodyPreview: preview,
        );

    test('a message with words in it passes', () {
      expect(gateFor(chat(body: 'can you send the CD?'), userAddress: null),
          isNull);
    });

    test('a body that stripped down to nothing gates', () {
      expect(gateFor(chat(body: '   '), userAddress: null), 'empty');
      expect(gateFor(chat(), userAddress: null), 'empty');
    });

    test('the preview stands in when no body is stored', () {
      expect(gateFor(chat(preview: 'a snippet'), userAddress: null), isNull);
    });

    test('none of the email gates apply — a chat has no headers and no '
        'no-reply mailboxes', () {
      final noreply = Message(
        id: 'c2',
        source: 'teams',
        outbound: false,
        fromAddress: 'teams:noreply@x.com',
        bodyText: 'a real sentence',
        sourceMetaJson: jsonEncode({
          'headers': {'list-unsubscribe': '<mailto:x@y.com>'},
        }),
      );
      expect(gateFor(noreply, userAddress: null), isNull);
    });
  });

  group('triageStatusOnInsert', () {
    const cutoff = '2026-08-22T00:00:00Z';

    test('an inbound message inside the window is queued', () {
      expect(
        triageStatusOnInsert(
          outbound: false,
          receivedAt: '2026-08-29T10:00:00Z',
          backlogCutoff: cutoff,
        ),
        ('pending', null),
      );
    });

    test('the reader’s own message is skipped whatever its date', () {
      expect(
        triageStatusOnInsert(
          outbound: true,
          receivedAt: '2026-08-29T10:00:00Z',
          backlogCutoff: cutoff,
        ),
        ('skipped', 'outbound'),
      );
      // Outbound is asked first: a sent message older than the window is still
      // "outbound", which is the reason a reader would recognise.
      expect(
        triageStatusOnInsert(
          outbound: true,
          receivedAt: '2026-01-01T10:00:00Z',
          backlogCutoff: cutoff,
        ),
        ('skipped', 'outbound'),
      );
    });

    test('an inbound message older than the cutoff is backlog', () {
      expect(
        triageStatusOnInsert(
          outbound: false,
          receivedAt: '2026-08-21T23:59:59Z',
          backlogCutoff: cutoff,
        ),
        ('skipped', 'backlog'),
      );
      // The boundary belongs to the window, matching the mail drain's own
      // `>=` comparison everywhere else.
      expect(
        triageStatusOnInsert(
          outbound: false,
          receivedAt: cutoff,
          backlogCutoff: cutoff,
        ),
        ('pending', null),
      );
    });

    test('a date nobody recorded is never backlog', () {
      expect(
        triageStatusOnInsert(outbound: false, backlogCutoff: cutoff),
        ('pending', null),
      );
      expect(
        triageStatusOnInsert(
          outbound: false,
          receivedAt: '',
          backlogCutoff: cutoff,
        ),
        ('pending', null),
      );
    });

    test('no cutoff never backlogs — the chat ingest passes none', () {
      expect(
        triageStatusOnInsert(
          outbound: false,
          receivedAt: '2020-01-01T00:00:00Z',
        ),
        ('pending', null),
      );
    });
  });
}
