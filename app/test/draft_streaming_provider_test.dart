import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/draft_provider.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/draft_stream.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_auth_session.dart';
import 'fixtures/test_db.dart';

/// The composer's side of a streamed draft: what it accumulates, whose deltas
/// it accepts, and when it lets go of them.
///
/// The preview is the one piece of draft state that is NOT a row, so the rules
/// about when it disappears are the whole of this file. It must survive a
/// reload that ran for some other reason — the inbox re-reads on every kind of
/// progress — and it must be gone the moment the stored suggestion exists, or
/// the reader would be looking at the same reply twice.

/// A backend that would notice if anything here reached for it. Nothing does:
/// a preview is text arriving over a bus.
class _NeverMail implements MailBackend {
  @override
  Future<SentDraft> sendDraft(String draftId) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('StreamingDraft', () {
    test('appends to the reply body, delta after delta', () {
      const empty = StreamingDraft.empty();
      expect(empty.isEmpty, isTrue);

      final grown = empty
          .apply('reply_body', 'Hi Tom,')
          .apply('reply_body', ' Friday works.');

      expect(grown.replyBody, 'Hi Tom, Friday works.');
      expect(grown.options, isEmpty);
      // The value is new each time; nothing mutates in place.
      expect(empty.replyBody, isEmpty);
    });

    test('grows the options list by index, in whatever order they arrive', () {
      final grown = const StreamingDraft.empty()
          .apply('options[0].stance', 'Acc')
          .apply('options[1].stance', 'Decline')
          .apply('options[0].stance', 'ept')
          .apply('options[1].reply_body', 'Cannot make it.')
          .apply('options[0].reply_body', 'Friday works.');

      expect(grown.options.length, 2);
      expect(grown.options[0], (stance: 'Accept', body: 'Friday works.'));
      expect(grown.options[1], (stance: 'Decline', body: 'Cannot make it.'));
    });

    test('an option that arrives out of order fills the gap rather than '
        'landing in the wrong card', () {
      final grown =
          const StreamingDraft.empty().apply('options[1].stance', 'Second');

      expect(grown.options.length, 2);
      expect(grown.options[0], (stance: '', body: ''));
      expect(grown.options[1].stance, 'Second');
    });

    test('a path nobody recognises changes nothing', () {
      const empty = StreamingDraft.empty();
      expect(identical(empty.apply('evidence', 'ignored'), empty), isTrue);
      expect(identical(empty.apply('options[99].stance', 'x'), empty), isTrue);
    });
  });

  group('DraftNotifier', () {
    late BondDatabase db;
    late MessageStore store;
    late DraftStreamBus bus;

    setUp(() {
      db = testDb();
      store = MessageStore(db);
      bus = DraftStreamBus();
    });

    tearDown(() async {
      bus.dispose();
      await db.close();
    });

    DraftNotifier notifierFor({String key = 'conv-1'}) {
      final notifier = DraftNotifier(
        store,
        FakeAuthSession(signedIn: true),
        _NeverMail(),
        (source: 'email', conversationKey: key),
        stream: bus,
      );
      addTearDown(notifier.dispose);
      return notifier;
    }

    Future<void> seedInbound({
      String id = 'm1',
      String key = 'conv-1',
    }) async {
      await store.upsertMessage({
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'inbound',
        'subject': 'Dinner on Friday?',
        'from_name': 'Tom Alvarez',
        'from_address': 'tom@example.com',
        'received_at': '2026-09-17T10:00:00Z',
        'body_text': 'Does Friday still work?',
      });
    }

    void publish(
      DraftNotifier notifier,
      String path,
      String delta, {
      String source = 'email',
      String key = 'conv-1',
      String id = 'm1',
    }) {
      bus.publish(DraftStreamEvent(
        source: source,
        conversationKey: key,
        sourceMessageId: id,
        path: path,
        delta: delta,
      ));
    }

    void publishDone({String id = 'm1', String key = 'conv-1'}) {
      bus.publish(DraftStreamEvent.done(
        source: 'email',
        conversationKey: key,
        sourceMessageId: id,
      ));
    }

    /// One turn of the event loop, which is all a broadcast delivery needs.
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('accumulates the deltas of its own conversation', () async {
      final notifier = notifierFor();
      await notifier.load();

      publish(notifier, 'reply_body', 'Hi Tom,');
      publish(notifier, 'reply_body', ' Friday works.');
      publish(notifier, 'options[0].stance', 'Accept');
      await settle();

      expect(notifier.state.streaming!.replyBody, 'Hi Tom, Friday works.');
      expect(notifier.state.streaming!.options.single.stance, 'Accept');
    });

    test('and ignores another conversation, and another source', () async {
      final notifier = notifierFor();
      await notifier.load();

      publish(notifier, 'reply_body', 'wrong thread', key: 'conv-2');
      publish(notifier, 'reply_body', 'wrong source', source: 'teams');
      await settle();

      expect(notifier.state.streaming, isNull);
    });

    test('a reload for some other reason leaves the preview alone', () async {
      final notifier = notifierFor();
      await notifier.load();
      publish(notifier, 'reply_body', 'half a sentence');
      await settle();

      // The inbox re-reads on every kind of progress; this is one of those.
      await notifier.load();

      expect(notifier.state.streaming!.replyBody, 'half a sentence');
    });

    test('two drafts in flight on one thread: the first one wins the preview',
        () async {
      // The prose lane can run wider than one, and a thread can hold two
      // unanswered messages. Interleaved into one preview they would read as a
      // reply to neither.
      final notifier = notifierFor();
      await notifier.load();

      publish(notifier, 'reply_body', 'Hi Tom, ');
      publish(notifier, 'reply_body', 'Dear Nina, ', id: 'm2');
      publish(notifier, 'reply_body', 'Friday works.');
      publish(notifier, 'options[0].stance', 'Accept', id: 'm2');
      await settle();

      expect(notifier.state.streaming!.replyBody, 'Hi Tom, Friday works.');
      expect(notifier.state.streaming!.options, isEmpty);
    });

    test('and a done for the other one leaves that preview alone', () async {
      final notifier = notifierFor();
      await notifier.load();
      publish(notifier, 'reply_body', 'Hi Tom, Friday');
      await settle();

      publishDone(id: 'm2');
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(notifier.state.streaming!.replyBody, 'Hi Tom, Friday');
    });

    test('a retry starts a fresh preview rather than appending to the one '
        'that failed', () async {
      final notifier = notifierFor();
      await notifier.load();
      publish(notifier, 'reply_body', 'the attempt that failed');
      await settle();

      // Done, then the retry's first words INSIDE the 400 ms reload window —
      // before the load that would have cleared the preview has run.
      publishDone();
      await settle();
      publish(notifier, 'reply_body', 'the retry');
      await settle();

      expect(notifier.state.streaming!.replyBody, 'the retry');

      // And the reload the `done` scheduled does not take the retry with it.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(notifier.state.streaming!.replyBody, 'the retry');
    });

    test('done clears it, in the same read that stages the stored row',
        () async {
      final notifier = notifierFor();
      await seedInbound();
      await notifier.load();
      publish(notifier, 'reply_body', 'Hi Tom, Friday');
      await settle();
      expect(notifier.state.streaming, isNotNull);

      // What the handler does: the row first, then the word that it is done.
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'conv-1',
        replyToMessageId: 'm1',
        body: 'Hi Tom, Friday works.',
        evidence: 'Tom asks whether Friday still works.',
        status: 'suggested',
      );
      publishDone();

      // The reload behind `done` is the notifier's own debounce.
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(notifier.state.streaming, isNull);
      expect(notifier.state.body, 'Hi Tom, Friday works.');
    });

    test('asking for a new draft clears the last one\'s preview', () async {
      final notifier = notifierFor();
      await seedInbound();
      await notifier.load();
      publish(notifier, 'reply_body', 'the previous attempt');
      await settle();

      await notifier.generate();

      expect(notifier.state.streaming, isNull);
      expect(notifier.state.draft, isNull);
    });

    test('a notifier with no bus never sees a preview', () async {
      final notifier = DraftNotifier(
        store,
        FakeAuthSession(signedIn: true),
        _NeverMail(),
        (source: 'email', conversationKey: 'conv-1'),
      );
      addTearDown(notifier.dispose);
      await notifier.load();

      bus.publish(const DraftStreamEvent(
        source: 'email',
        conversationKey: 'conv-1',
        sourceMessageId: 'm1',
        path: 'reply_body',
        delta: 'nobody is listening',
      ));
      await settle();

      expect(notifier.state.streaming, isNull);
    });
  });
}
