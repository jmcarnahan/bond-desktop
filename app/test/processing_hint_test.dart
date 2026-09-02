import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/widgets/processing_hint.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one rule that decides whether a row says "thinking…".
///
/// Busy is necessary and nowhere near sufficient: on a fresh mailbox every
/// row is busy, and a hint on all of them would read as a hung app rather
/// than as work in progress.
void main() {
  final since = DateTime.utc(2026, 8, 29, 12);

  Conversation conv({int pending = 2, String? lastMessageAt}) => Conversation(
        id: 'conv-1',
        aiPendingCount: pending,
        lastMessageAt: lastMessageAt,
      );

  test('mail that arrived this session, still being worked on, says so', () {
    expect(
      showsProcessing(
        conv(lastMessageAt: '2026-08-29T12:30:00Z'),
        since: since,
      ),
      isTrue,
    );
  });

  test('nothing queued against the thread, nothing to say', () {
    expect(
      showsProcessing(
        conv(pending: 0, lastMessageAt: '2026-08-29T12:30:00Z'),
        since: since,
      ),
      isFalse,
    );
  });

  test('no session start — the host has not opted in — stays quiet', () {
    expect(
      showsProcessing(conv(lastMessageAt: '2026-08-29T12:30:00Z'), since: null),
      isFalse,
    );
  });

  test('first-run backlog stays quiet', () {
    // The ~250 messages a fresh mailbox lands are all pending and all older
    // than the app itself. The rail's "Triaging N remaining…" caption is what
    // tells that story; the rows say nothing.
    expect(
      showsProcessing(
        conv(lastMessageAt: '2026-08-01T09:00:00Z'),
        since: since,
      ),
      isFalse,
    );
  });

  test('a thread with no timestamp stays quiet', () {
    expect(showsProcessing(conv(), since: since), isFalse);
  });

  test('a timestamp that does not parse stays quiet', () {
    expect(
      showsProcessing(conv(lastMessageAt: 'sometime tuesday'), since: since),
      isFalse,
    );
  });

  test('a message that landed exactly at the session start stays quiet', () {
    // `isAfter`, not `!isBefore`: the tie is the one case where "arrived while
    // you were watching" is a guess, and the quiet answer is the right guess.
    expect(
      showsProcessing(
        conv(lastMessageAt: since.toIso8601String()),
        since: since,
      ),
      isFalse,
    );
  });
}
