import 'package:bond_inbox/services/conversation_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed, ordered timestamps. String order IS chronological order here, which
/// is the property the whole fold rests on.
const String t1 = '2026-08-20T09:00:00Z';
const String t2 = '2026-08-20T12:00:00Z';
const String t3 = '2026-08-21T08:00:00Z';

/// One row of the state-machine table.
typedef FoldCase = ({
  String name,
  ConvSnapshot? existing,
  bool outbound,
  String? receivedAt,
  String expectedState,
});

ConvSnapshot snap({
  String state = stateWaiting,
  String? lastInboundAt,
  String? lastOutboundAt,
  String? lastMessageAt,
  String? subject,
  String? preview,
}) =>
    ConvSnapshot(
      state: state,
      lastInboundAt: lastInboundAt,
      lastOutboundAt: lastOutboundAt,
      lastMessageAt: lastMessageAt,
      lastMessagePreview: preview,
      subject: subject,
    );

void main() {
  group('foldMessage transitions', () {
    const cases = <FoldCase>[
      (
        name: 'the first inbound on a new thread asks for a reply',
        existing: null,
        outbound: false,
        receivedAt: t1,
        expectedState: stateNeedsReply,
      ),
      (
        name: 'the first outbound on a new thread waits',
        existing: null,
        outbound: true,
        receivedAt: t1,
        expectedState: stateWaiting,
      ),
    ];

    for (final c in cases) {
      test(c.name, () {
        final result = foldMessage(
          c.existing,
          outbound: c.outbound,
          receivedAt: c.receivedAt,
        );
        expect(result.state, c.expectedState);
      });
    }

    test('inbound newer than the last reply asks for a reply', () {
      final result = foldMessage(
        snap(state: stateWaiting, lastOutboundAt: t1),
        outbound: false,
        receivedAt: t2,
      );
      expect(result.state, stateNeedsReply);
    });

    test('inbound OLDER than the last reply changes nothing', () {
      // The reply that is already sent answered this message. A late-arriving
      // delta page must not resurrect it as an open ask.
      final result = foldMessage(
        snap(state: stateWaiting, lastOutboundAt: t3),
        outbound: false,
        receivedAt: t2,
      );
      expect(result.state, stateWaiting);
    });

    test('inbound at the SAME time as the last reply changes nothing', () {
      // The inbound guard is strictly less-than, so a tie does not reopen.
      final result = foldMessage(
        snap(state: stateWaiting, lastOutboundAt: t2),
        outbound: false,
        receivedAt: t2,
      );
      expect(result.state, stateWaiting);
    });

    test('outbound at the SAME time as the last inbound wins the tie', () {
      // The asymmetry, pinned: the outbound guard is <=, so a reply sharing a
      // timestamp with the mail it answers still closes the ask. Flipping
      // this to < leaves threads demanding a reply that was already sent.
      final result = foldMessage(
        snap(state: stateNeedsReply, lastInboundAt: t2),
        outbound: true,
        receivedAt: t2,
      );
      expect(result.state, stateWaiting);
    });

    test('outbound older than the newest inbound leaves the ask standing', () {
      final result = foldMessage(
        snap(state: stateNeedsReply, lastInboundAt: t3),
        outbound: true,
        receivedAt: t2,
      );
      expect(result.state, stateNeedsReply);
    });

    test('a qualifying inbound reopens a thread a human marked done', () {
      final result = foldMessage(
        snap(state: stateDone, lastOutboundAt: t1, lastInboundAt: t1),
        outbound: false,
        receivedAt: t2,
      );
      expect(result.state, stateNeedsReply);
    });

    test('a non-qualifying inbound leaves done alone', () {
      final result = foldMessage(
        snap(state: stateDone, lastOutboundAt: t3),
        outbound: false,
        receivedAt: t2,
      );
      expect(result.state, stateDone);
    });

    test('no outbound can undo done', () {
      for (final receivedAt in [t1, t2, t3]) {
        final result = foldMessage(
          snap(state: stateDone, lastInboundAt: t2),
          outbound: true,
          receivedAt: receivedAt,
        );
        expect(result.state, stateDone, reason: 'outbound at $receivedAt');
      }
    });

    test('the guard reads the snapshot BEFORE this message folds in', () {
      // Folding the timestamp first would make every outbound satisfy its own
      // <= guard against itself, and the fold would always say waiting.
      final result = foldMessage(
        snap(state: stateNeedsReply, lastInboundAt: t3),
        outbound: true,
        receivedAt: t1,
      );
      expect(result.state, stateNeedsReply);
      expect(result.lastOutboundAt, t1);
    });

    test('the input snapshot is not mutated', () {
      final existing = snap(state: stateWaiting, lastInboundAt: t1);
      foldMessage(existing, outbound: false, receivedAt: t3);
      expect(existing.state, stateWaiting);
      expect(existing.lastInboundAt, t1);
    });
  });

  group('foldMessage timestamps and preview', () {
    test('high-water marks only move forward', () {
      var s = foldMessage(null, outbound: false, receivedAt: t3);
      s = foldMessage(s, outbound: false, receivedAt: t1);
      expect(s.lastInboundAt, t3);
      expect(s.lastMessageAt, t3);
    });

    test('the newest message owns the preview', () {
      var s = foldMessage(null,
          outbound: false, receivedAt: t1, preview: 'oldest');
      s = foldMessage(s, outbound: true, receivedAt: t3, preview: 'newest');
      s = foldMessage(s, outbound: false, receivedAt: t2, preview: 'middle');
      expect(s.lastMessagePreview, 'newest');
      expect(s.lastMessageAt, t3);
    });

    test('inbound and outbound stamps are tracked separately', () {
      var s = foldMessage(null, outbound: false, receivedAt: t1);
      s = foldMessage(s, outbound: true, receivedAt: t2);
      expect(s.lastInboundAt, t1);
      expect(s.lastOutboundAt, t2);
      expect(s.lastMessageAt, t2);
    });
  });

  group('foldMessage with no timestamp', () {
    test('never satisfies the inbound guard', () {
      final result = foldMessage(
        snap(state: stateWaiting),
        outbound: false,
        receivedAt: null,
      );
      expect(result.state, stateWaiting,
          reason: 'an unorderable message cannot prove it is the newest');
      expect(result.lastInboundAt, isNull);
      expect(result.lastMessageAt, isNull);
    });

    test('never satisfies the outbound guard', () {
      final result = foldMessage(
        snap(state: stateNeedsReply),
        outbound: true,
        receivedAt: null,
      );
      expect(result.state, stateNeedsReply);
      expect(result.lastOutboundAt, isNull);
    });

    test('an empty timestamp counts as no timestamp', () {
      final result =
          foldMessage(null, outbound: false, receivedAt: '', preview: 'p');
      expect(result.state, stateWaiting);
      expect(result.lastMessageAt, isNull);
    });

    test('still supplies a subject and a first preview', () {
      final result = foldMessage(
        null,
        outbound: false,
        receivedAt: null,
        subject: 'Re: Docs',
        preview: 'something',
      );
      expect(result.subject, 'Docs');
      expect(result.lastMessagePreview, 'something');
    });

    test('does not overwrite a dated message\'s preview', () {
      var s = foldMessage(null,
          outbound: false, receivedAt: t2, preview: 'dated');
      s = foldMessage(s, outbound: false, receivedAt: null, preview: 'undated');
      expect(s.lastMessagePreview, 'dated');
    });
  });

  group('subject', () {
    test('the first non-empty subject names the thread', () {
      var s = foldMessage(null, outbound: false, receivedAt: t1, subject: '');
      expect(s.subject, isNull);
      s = foldMessage(s, outbound: true, receivedAt: t2, subject: 'Closing');
      s = foldMessage(s, outbound: false, receivedAt: t3, subject: 'Renamed');
      expect(s.subject, 'Closing');
    });

    test('stripReFw removes stacked reply and forward markers', () {
      expect(stripReFw('Re: Re: Fwd: Hello'), 'Hello');
      expect(stripReFw('RE: FW: 412 Alder Court'), '412 Alder Court');
      expect(stripReFw('  fwd:  spaced  '), 'spaced');
      expect(stripReFw('RE[2]: Numbered'), 'Numbered');
      expect(stripReFw('Hello'), 'Hello');
      expect(stripReFw(''), '');
      expect(stripReFw(null), '');
      // A subject that is nothing but markers has no name left in it.
      expect(stripReFw('Re:'), '');
      // Not a marker — "Reader" starts with "Re" but is not "Re:".
      expect(stripReFw('Reader question'), 'Reader question');
    });
  });

  group('conversationKeyFor', () {
    test('uses the Graph conversation id when there is one', () {
      expect(conversationKeyFor('conv-abc', 'msg-1'), 'conv-abc');
    });

    test('a message with no thread is its own thread, namespaced', () {
      expect(conversationKeyFor(null, 'x'), 'msg:x');
      expect(conversationKeyFor('', 'x'), 'msg:x');
    });
  });

  group('outboundResolves', () {
    // Mirrors foldMessage's outbound guard exactly — including the `<=` tie
    // rule — so ingest can clear side state (the CTA) on the same transition
    // the fold takes to waiting, and never on any other.
    test('answers everything when there is no inbound at all', () {
      expect(outboundResolves(null, '2026-09-01T10:00:00Z'), isTrue);
      expect(outboundResolves(ConvSnapshot(), '2026-09-01T10:00:00Z'), isTrue);
    });

    test('a reply at or after the newest inbound resolves', () {
      final s = ConvSnapshot(lastInboundAt: '2026-09-01T10:00:00Z');
      expect(outboundResolves(s, '2026-09-01T11:00:00Z'), isTrue);
      // The tie goes to the reply, exactly as the fold's `<=` does.
      expect(outboundResolves(s, '2026-09-01T10:00:00Z'), isTrue);
    });

    test('a reply older than the newest inbound resolves nothing', () {
      final s = ConvSnapshot(lastInboundAt: '2026-09-01T10:00:00Z');
      expect(outboundResolves(s, '2026-09-01T09:00:00Z'), isFalse);
    });

    test('an undated reply can be ordered against nothing', () {
      expect(outboundResolves(ConvSnapshot(), null), isFalse);
      expect(outboundResolves(ConvSnapshot(), ''), isFalse);
    });
  });
}
