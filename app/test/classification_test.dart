import 'dart:convert';

import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/classification.dart';
import 'package:flutter_test/flutter_test.dart';

/// A message carrying only the fields `classificationOf` reads, in the blob
/// shape the detail fetch writes: `headers` and `meeting` are two named keys
/// under one JSON object, each present only when there is something to say.
Message message({
  String source = 'email',
  String? from = 'dana.whitlock@example.com',
  String? fromName,
  String? subject,
  String? meeting,
  Map<String, String>? headers,
}) =>
    Message(
      id: 'm1',
      source: source,
      outbound: false,
      fromName: fromName,
      fromAddress: from,
      subject: subject,
      sourceMetaJson: headers == null && meeting == null
          ? null
          : jsonEncode({
              'headers': ?headers,
              'meeting': ?meeting,
            }),
    );

void main() {
  /// Graph said what the message is, and nothing else gets a vote.
  group('meeting', () {
    const responses = [
      'meetingAccepted',
      'meetingDeclined',
      'meetingCancelled',
      // The regional spelling and the typo Microsoft shipped, both matched on
      // purpose: see `meetingResponseTypes` in `gates.dart`.
      'meetingCanceled',
      'meetingTentativelyAccepted',
      'meetingTenativelyAccepted',
    ];

    for (final type in responses) {
      test('$type is a meeting_response', () {
        expect(classificationOf(message(meeting: type)), 'meeting_response');
      });
    }

    test('meetingRequest is an invite, which is a different class of mail', () {
      expect(
        classificationOf(message(meeting: 'meetingRequest')),
        'meeting_invite',
      );
    });

    test('the value is read case-folded — the field is stored verbatim', () {
      expect(
        classificationOf(message(meeting: 'MEETINGACCEPTED')),
        'meeting_response',
      );
    });

    test('a meeting value nobody here knows falls through, it does not end '
        'the walk', () {
      // `none` is in Graph's own enum and rides ordinary mail. A tracker
      // notification carrying it is still a tracker notification.
      expect(
        classificationOf(
          message(
            meeting: 'none',
            headers: const {'x-jira-fingerprint': 'a1b2c3'},
          ),
        ),
        'tracker_notification',
      );
      expect(classificationOf(message(meeting: 'none')), isNull);
    });

    test('null is "nobody said", which is every row written before the field',
        () {
      expect(classificationOf(message(subject: 'Accepted: weekly sync')), isNull,
          reason: 'a subject shape is the gate\'s fallback, not a class');
    });
  });

  /// Header names and a display-name suffix, which the tracker stamps on its
  /// own mail. No tracker DOMAIN appears in this file or in the one it tests.
  group('tracker_notification', () {
    test('the fingerprint header', () {
      expect(
        classificationOf(
          message(headers: const {'x-jira-fingerprint': 'a1b2c3d4'}),
        ),
        'tracker_notification',
      );
    });

    for (final header in const [
      'x-atlassian-token',
      'x-atlassian-mail-counter',
      'x-atlassian-request-id',
    ]) {
      test('$header — the family is matched by prefix', () {
        expect(
          classificationOf(message(headers: {header: 'anything'})),
          'tracker_notification',
        );
      });
    }

    test('the (Jira) display-name suffix: one person relayed by a mailbox', () {
      expect(
        classificationOf(
          message(
            fromName: 'Dana Whitlock (Jira)',
            from: 'jira@tracker.example.com',
          ),
        ),
        'tracker_notification',
      );
      expect(
        classificationOf(message(fromName: 'Dana Whitlock (Jira Software)')),
        'tracker_notification',
      );
    });

    test('and only as a suffix — a parenthesis mid-name is somebody\'s name',
        () {
      expect(
        classificationOf(message(fromName: 'Dana (Jira) Whitlock reports')),
        isNull,
      );
      expect(classificationOf(message(fromName: 'Dana Whitlock')), isNull);
    });

    test('a bracketed subject tag plus an automated sender', () {
      expect(
        classificationOf(
          message(
            from: 'notifications@tracker.example.com',
            subject: '[JIRA] (BOND-42) [Backend] - Renewal export times out',
          ),
        ),
        'tracker_notification',
      );
    });

    test('or a bracketed tag plus an automated HEADER, no sender shape needed',
        () {
      expect(
        classificationOf(
          message(
            from: 'jira@tracker.example.com',
            subject: '[JIRA] (BOND-42) - Renewal export times out',
            headers: const {'list-id': '<issues.tracker.example.com>'},
          ),
        ),
        'tracker_notification',
      );
    });

    test('the bracketed tag NEVER answers alone — a colleague writes one too',
        () {
      expect(
        classificationOf(
          message(
            from: 'dana.whitlock@example.com',
            subject: '[URGENT] can you look at the renewal export?',
          ),
        ),
        isNull,
      );
      // The bare tracker local part is the address the decision record says no
      // name rule may judge, so it is not an automated sender shape here.
      expect(
        classificationOf(
          message(
            from: 'jira@tracker.example.com',
            subject: '[JIRA] (BOND-42) - Renewal export times out',
          ),
        ),
        isNull,
      );
    });

    test('a bracketed sentence is prose, not a tag', () {
      expect(
        classificationOf(
          message(
            from: 'notifications@tracker.example.com',
            subject: '[a much longer bracketed aside than any tag] hello',
          ),
        ),
        isNull,
      );
    });
  });

  group('automated_notification', () {
    for (final value in const ['auto-generated', 'auto-replied', 'AUTO-NOTIFIED']) {
      test('auto-submitted: $value', () {
        expect(
          classificationOf(message(headers: {'auto-submitted': value})),
          'automated_notification',
        );
      });
    }

    test('auto-submitted: no is RFC 3834 for "a human sent this"', () {
      expect(
        classificationOf(message(headers: const {'auto-submitted': 'no'})),
        isNull,
      );
    });

    for (final header in const ['list-id', 'list-unsubscribe', 'list-post']) {
      test('$header means sent to a list', () {
        expect(
          classificationOf(message(headers: {header: '<x.example.com>'})),
          'automated_notification',
        );
      });
    }
  });

  /// Which signal answers when several are true at once. The order is the
  /// order of how much each one knows.
  group('precedence', () {
    test('the meeting field beats every shape below it', () {
      expect(
        classificationOf(
          message(
            meeting: 'meetingCancelled',
            fromName: 'Dana Whitlock (Jira)',
            subject: '[JIRA] (BOND-42) - Renewal export times out',
            headers: const {
              'x-jira-fingerprint': 'a1b2c3',
              'list-id': '<issues.tracker.example.com>',
              'auto-submitted': 'auto-generated',
            },
          ),
        ),
        'meeting_response',
      );
    });

    test('an invite with tracker headers is still an invite', () {
      expect(
        classificationOf(
          message(
            meeting: 'meetingRequest',
            headers: const {'x-atlassian-token': 'abc'},
          ),
        ),
        'meeting_invite',
      );
    });

    test('tracker beats automated: the digest carries List-Id as well, and '
        'the owner who wrote a rule about tracker mail meant that mail', () {
      expect(
        classificationOf(
          message(
            fromName: 'Dana Whitlock (Jira)',
            headers: const {
              'list-unsubscribe': '<mailto:u@tracker.example.com>',
              'auto-submitted': 'auto-generated',
            },
          ),
        ),
        'tracker_notification',
      );
    });
  });

  group('nothing here says', () {
    test('a colleague writing a sentence', () {
      expect(
        classificationOf(
          message(
            fromName: 'Dana Whitlock',
            subject: 'renewal export',
            headers: const {'precedence': 'first-class'},
          ),
        ),
        isNull,
      );
    });

    test('a bare row with no blob at all', () {
      expect(classificationOf(message()), isNull);
      expect(classificationOf(message(from: null)), isNull);
    });

    test('malformed source_meta_json reads as no headers and no meeting', () {
      final broken = Message(
        id: 'm1',
        outbound: false,
        fromAddress: 'dana.whitlock@example.com',
        sourceMetaJson: 'not json',
      );
      expect(classificationOf(broken), isNull);
    });

    test('a chat message carries none of these shapes', () {
      final chat = Message(
        id: 'c1',
        source: 'teams',
        outbound: false,
        fromAddress: 'teams:user-1',
        fromName: 'Dana Whitlock',
        bodyText: 'did the renewal export finish?',
      );
      expect(classificationOf(chat), isNull);
    });
  });
}
