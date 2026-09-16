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

  /// Which addresses the name rules take and which they leave alone. WHICH
  /// slug each one comes back with is the `reasons` group below — the two are
  /// separate questions, and the replay of these gates against the golden set
  /// scores both.
  group('sender shapes', () {
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
      // The token rule: the word says itself in the middle of a local part,
      // and every one of these was reaching the model under the old anchor.
      'orders-noreply@example.com',
      'noreply+billing@example.com',
      'noreply2@example.com',
      // The compact word needs no delimiter at all: nothing a person is named
      // contains it, and a real mailbox buried it in a longer run of letters.
      'opsnoreplyrelay@example.com',
      'donotreplyservice@example.com',
      // Contrived as an address, and gated all the same: a rule that had to
      // keep this one out is a rule that let the three above through.
      'not-a-noreply@x.com',
      // Monitoring.
      'monitoring@example.com',
      'monitoring-eu@example.com',
      'prod-monitoring@example.com',
      // Build and service mailboxes.
      'svc-deploy@example.com',
      'build-bot@example.com',
      'bot-relay@example.com',
      'ci@example.com',
      'builds@example.com',
      'pipelines@example.com',
    ];

    for (final address in gated) {
      test('$address gates', () {
        expect(gateFor(message(from: address), userAddress: null), isNotNull);
      });
    }

    // The delimiters doing their job. Every one of these is a plausible
    // human or product mailbox that a substring match would have swallowed.
    const allowed = [
      'nota@x.com',
      'renotify@x.com',
      'salerts@x.com',
      'no@x.com',
      'sarah@x.com',
      'rebounce@x.com',
      'nota@example.com',
      'renotify@example.com',
      'salerts@example.com',
      'abbott@example.com',
      'remonitoring@example.com',
      'cicd-team@example.com',
      // An issue tracker and a code host, deliberately ungated: the same
      // shape is a gold drop and a gold keep on the set, so the thing that
      // separates them is the tenant, not the name.
      'jira@example.com',
      'github@example.com',
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

  /// The exact slug per shape, and it is exact on purpose: these are the
  /// golden set's own drop-reason names, so a replay of the gates scores the
  /// reason column and not only the verdict.
  group('reasons', () {
    const reasons = {
      'noreply@example.com': 'no_reply',
      'no.reply@x.com': 'no_reply',
      'NoReply@X.com': 'no_reply',
      'donotreplyservice@example.com': 'no_reply',
      'orders-noreply@example.com': 'no_reply',
      'noreply+billing@example.com': 'no_reply',
      'noreply2@example.com': 'no_reply',
      'opsnoreplyrelay@example.com': 'no_reply',
      'not-a-noreply@x.com': 'no_reply',
      'notifications@example.com': 'no_reply',
      'alerts@example.com': 'no_reply',
      'mailer-daemon@example.com': 'no_reply',
      'postmaster@example.com': 'no_reply',
      'bounces@example.com': 'no_reply',
      'monitoring@example.com': 'monitoring',
      'monitoring-eu@example.com': 'monitoring',
      'prod-monitoring@example.com': 'monitoring',
      'svc-deploy@example.com': 'machine_sender',
      'build-bot@example.com': 'machine_sender',
      'bot-relay@example.com': 'machine_sender',
      'ci@example.com': 'machine_sender',
      'builds@example.com': 'machine_sender',
      'pipelines@example.com': 'machine_sender',
    };

    reasons.forEach((address, reason) {
      test('$address is $reason', () {
        expect(gateFor(message(from: address), userAddress: null), reason);
      });
    });
  });

  /// The owner's own standing rule, which is data rather than a pattern: it
  /// arrives as an argument and the call site is what read the table.
  group('sender_rule', () {
    test('a drop rule gates an ordinary human address', () {
      expect(
        gateFor(
          message(from: 'sarah@example.com'),
          userAddress: null,
          senderDisposition: 'drop',
        ),
        'sender_rule',
      );
    });

    test('and is asked before every name rule below it', () {
      // The reason a reader would recognise is the one they wrote, not the
      // one the address happens to also earn.
      expect(
        gateFor(
          message(from: 'noreply@example.com'),
          userAddress: null,
          senderDisposition: 'drop',
        ),
        'sender_rule',
      );
    });

    test("but never before self — the owner's own mail is still their own",
        () {
      expect(
        gateFor(
          message(from: 'lo@bond.com'),
          userAddress: 'lo@bond.com',
          senderDisposition: 'drop',
        ),
        'self',
      );
    });

    test('every other disposition changes nothing', () {
      for (final disposition in [null, 'later', 'keep']) {
        expect(
          gateFor(
            message(from: 'sarah@example.com'),
            userAddress: null,
            senderDisposition: disposition,
          ),
          isNull,
          reason: 'disposition $disposition',
        );
      }
    });

    test('a chat from a dropped sender is gated too', () {
      final chat = Message(
        id: 'c1',
        source: 'teams',
        outbound: false,
        fromAddress: 'teams:user-1',
        bodyText: 'can you send the CD?',
      );
      expect(
        gateFor(chat, userAddress: null, senderDisposition: 'drop'),
        'sender_rule',
      );
      expect(gateFor(chat, userAddress: null), isNull);
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

  /// The one thing in `gates.dart` that never gates anything: a loose read of
  /// a local part, used to decide whether a failed detail fetch is worth one
  /// more attempt before the message is classified with no headers at all.
  group('suspectMachineSender', () {
    test('the machine mailboxes whose headers are worth waiting for', () {
      for (final local in [
        'svc-monitoring',
        'prod-alerts',
        'ops-digest',
        'noreply',
        'orders-noreply',
        'digest',
        'build-bot',
        'bot-relay',
        'ci',
        'postmaster',
        'system-notifier',
        'mailer',
      ]) {
        expect(suspectMachineSender(local), isTrue, reason: local);
      }
    });

    test('a person is not a machine, and neither is a word containing one', () {
      for (final local in [
        'sarah.chen',
        // `bot` mid-word with no delimiter either side — the whole reason the
        // pattern asks for one.
        'abbott',
        'robin',
        '',
        'cicd-team',
      ]) {
        expect(suspectMachineSender(local), isFalse, reason: local);
      }
    });

    test('it is wider than the gates, deliberately', () {
      // `prod-alerts@` is a machine mailbox every delimited gate refuses —
      // `alerts` is prefix-anchored — which is exactly the message whose
      // headers decide it.
      expect(
        gateFor(message(from: 'prod-alerts@example.com'), userAddress: null),
        isNull,
      );
      expect(suspectMachineSender('prod-alerts'), isTrue);
    });
  });
}
