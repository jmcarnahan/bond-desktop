import 'dart:convert';

import 'package:bond_inbox/services/notify/desktop_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

/// The payload that has to survive a trip through the operating system.
///
/// A toast hands back one string, written by whatever build posted it and read
/// by whatever build is running when it is tapped. So the round trip is pinned
/// here, and so is the far more important half: every way that string can be
/// wrong answers null, because a tap the app cannot read is a tap it must not
/// act on.

void main() {
  group('NotificationTarget', () {
    test('a single-thread target comes back exactly as it went in', () {
      const target = NotificationTarget(
        source: 'teams',
        conversationKey: 'chat-19:abc',
      );

      final back = NotificationTarget.decode(target.encode());

      expect(back, isNotNull);
      expect(back!.source, 'teams');
      expect(back.conversationKey, 'chat-19:abc');
      expect(back.storylineId, isNull);
      expect(back.count, 1);
    });

    test('the storyline and the count survive with it', () {
      const target = NotificationTarget(
        source: 'email',
        conversationKey: 'c1',
        storylineId: 'sl-1',
        count: 4,
      );

      final back = NotificationTarget.decode(target.encode())!;

      expect(back.storylineId, 'sl-1');
      expect(back.count, 4);
    });

    test('nothing at all decodes to nothing', () {
      expect(NotificationTarget.decode(null), isNull);
      expect(NotificationTarget.decode(''), isNull);
    });

    test('a string that is not JSON decodes to nothing', () {
      expect(NotificationTarget.decode('garbage'), isNull);
    });

    test('a bare id decodes to nothing', () {
      // The shape a hand-rolled "just put the key in the payload" would take,
      // and the one this app must never act on: `abc123` is valid nothing.
      expect(NotificationTarget.decode('abc123'), isNull);
    });

    test('valid JSON that is not a map decodes to nothing', () {
      expect(NotificationTarget.decode('[1,2,3]'), isNull);
      expect(NotificationTarget.decode('"c1"'), isNull);
    });

    test('another version of the shape decodes to nothing', () {
      // A build that meant something else by these field names. Guessing would
      // navigate somewhere nobody asked for.
      expect(
        NotificationTarget.decode(jsonEncode({
          'v': 2,
          'source': 'email',
          'conversationKey': 'c1',
          'count': 1,
        })),
        isNull,
      );
      expect(
        NotificationTarget.decode(
          jsonEncode({'source': 'email', 'conversationKey': 'c1', 'count': 1}),
        ),
        isNull,
      );
    });

    test('a payload missing either half of the address decodes to nothing', () {
      // Both halves are required: a key with no source can open the wrong
      // connector's thread, and a source with no key opens nothing.
      for (final body in [
        {'v': 1, 'source': 'email', 'count': 1},
        {'v': 1, 'source': 'email', 'conversationKey': '', 'count': 1},
        {'v': 1, 'conversationKey': 'c1', 'count': 1},
        {'v': 1, 'source': '', 'conversationKey': 'c1', 'count': 1},
      ]) {
        expect(NotificationTarget.decode(jsonEncode(body)), isNull,
            reason: '$body');
      }
    });

    test('a count that is not a number decodes to nothing', () {
      expect(
        NotificationTarget.decode(jsonEncode({
          'v': 1,
          'source': 'email',
          'conversationKey': 'c1',
          'count': 'two',
        })),
        isNull,
      );
    });
  });

  group('NoopDesktopNotifier', () {
    test('says so, refuses authorization, and shows nothing quietly', () async {
      const notifier = NoopDesktopNotifier();

      expect(notifier.supported, isFalse);
      expect(await notifier.ensureAuthorized(), isFalse);
      // Not a throw — degradation is a class, and its callers do not branch.
      await notifier.show(const DesktopNotification(
        title: 'A message needs you',
        body: '',
        target: NotificationTarget(source: 'email', conversationKey: 'c1'),
      ));
    });
  });
}
