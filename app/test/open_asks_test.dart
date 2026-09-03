import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/open_asks.dart';
import 'package:flutter_test/flutter_test.dart';

Message _msg({
  String id = 'm1',
  bool outbound = false,
  String? receivedAt = '2026-08-25T09:00:00',
  bool? needsAction,
  bool? replyExpected,
  List<String> actionItems = const [],
  String? deadline,
}) {
  return Message(
    id: id,
    outbound: outbound,
    receivedAt: receivedAt,
    needsAction: needsAction,
    replyExpected: replyExpected,
    actionItems: actionItems,
    deadline: deadline,
  );
}

bool _open(
  Message m, {
  String? lastOutboundAt,
  bool conversationDone = false,
}) =>
    hasOpenAsk(
      m,
      lastOutboundAt: lastOutboundAt,
      conversationDone: conversationDone,
    );

void main() {
  group('hasOpenAsk', () {
    test('needsAction alone is an ask', () {
      expect(_open(_msg(needsAction: true)), isTrue);
    });

    test('replyExpected alone is an ask', () {
      expect(_open(_msg(replyExpected: true)), isTrue);
    });

    test('both true is still one ask', () {
      expect(_open(_msg(needsAction: true, replyExpected: true)), isTrue);
      expect(
        openAskCount(
          [_msg(needsAction: true, replyExpected: true)],
          conversationDone: false,
        ),
        1,
      );
    });

    test('null on both means not judged, which is not an ask', () {
      // NULL is "no pass has looked at this message" — it must never read as
      // "the sender wants something".
      expect(_open(_msg()), isFalse);
    });

    test('judged and answered nothing is not an ask', () {
      expect(_open(_msg(needsAction: false, replyExpected: false)), isFalse);
    });

    test('an outbound message after the ask closes it', () {
      expect(
        _open(
          _msg(needsAction: true, receivedAt: '2026-08-25T09:00:00'),
          lastOutboundAt: '2026-08-25T10:00:00',
        ),
        isFalse,
      );
    });

    test('an outbound message before the ask leaves it open', () {
      expect(
        _open(
          _msg(needsAction: true, receivedAt: '2026-08-25T09:00:00'),
          lastOutboundAt: '2026-08-25T08:00:00',
        ),
        isTrue,
      );
    });

    test('an outbound message at the same instant does not close it', () {
      // Strictly after, or it did not answer this one.
      expect(
        _open(
          _msg(needsAction: true, receivedAt: '2026-08-25T09:00:00'),
          lastOutboundAt: '2026-08-25T09:00:00',
        ),
        isTrue,
      );
    });

    test('a done conversation closes everything', () {
      expect(
        _open(_msg(needsAction: true), conversationDone: true),
        isFalse,
      );
    });

    test('outbound messages never carry asks', () {
      expect(_open(_msg(outbound: true, needsAction: true)), isFalse);
    });

    test('an unorderable ask is closed by any timestamped reply', () {
      expect(
        _open(
          _msg(needsAction: true, receivedAt: null),
          lastOutboundAt: '2026-08-25T09:00:00',
        ),
        isFalse,
      );
    });

    test('an unorderable ask with no reply at all stays open', () {
      expect(_open(_msg(needsAction: true, receivedAt: null)), isTrue);
    });
  });

  group('latestOutboundAt', () {
    test('an empty thread has none', () {
      expect(latestOutboundAt(const []), isNull);
    });

    test('an all-inbound thread has none', () {
      expect(
        latestOutboundAt([_msg(id: 'a'), _msg(id: 'b')]),
        isNull,
      );
    });

    test('two outbound messages give the later one', () {
      expect(
        latestOutboundAt([
          _msg(id: 'a', outbound: true, receivedAt: '2026-08-25T09:00:00'),
          _msg(id: 'b', outbound: true, receivedAt: '2026-08-26T09:00:00'),
        ]),
        '2026-08-26T09:00:00',
      );
    });

    test('an outbound message without a timestamp is ignored', () {
      expect(
        latestOutboundAt([
          _msg(id: 'a', outbound: true, receivedAt: '2026-08-25T09:00:00'),
          _msg(id: 'b', outbound: true, receivedAt: null),
        ]),
        '2026-08-25T09:00:00',
      );
    });
  });

  group('openAskCount', () {
    test('counts only the asks a reply has not answered', () {
      final thread = [
        _msg(id: 'a', needsAction: true, receivedAt: '2026-08-25T08:00:00'),
        _msg(id: 'b', outbound: true, receivedAt: '2026-08-25T09:00:00'),
        _msg(id: 'c', needsAction: true, receivedAt: '2026-08-25T10:00:00'),
        _msg(id: 'd', replyExpected: true, receivedAt: '2026-08-25T11:00:00'),
      ];
      expect(openAskCount(thread, conversationDone: false), 2);
    });
  });
}
