import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart' show Message;
import 'package:bond_inbox/providers/draft_provider.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The undo window on a quick reply.
///
/// The assertion this file exists for is the negative one: for as long as the
/// window is open, NOTHING has been asked of Graph. A cancel inside it, and a
/// notifier disposed inside it, both leave the mailbox untouched — because a
/// send the user believed they took back must never turn up in somebody's
/// inbox.

class InMemoryTokenStore implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

/// Records every Graph call the send flow makes, in order.
class RecordingMail extends GraphMail {
  final List<String> calls = [];
  final List<String> bodies = [];

  /// Held open by a test that needs to look at the state MID-SEND — the send
  /// waits on this instead of returning, which is the only way to observe the
  /// window between the undo timer firing and the reply landing.
  Completer<void>? holdSend;

  RecordingMail(super.auth, {required super.httpClient});

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async {
    calls.add('createReply:$messageId');
    return const {
      'id': 'graph-draft-1',
      'webLink': 'https://outlook.example/draft-1',
      'conversationId': 'conv-1',
      'internetMessageId': '<reply-1@bond.local>',
    };
  }

  @override
  Future<void> updateDraftBody(String draftId, String text) async {
    calls.add('updateBody:$draftId');
    bodies.add(text);
  }

  @override
  Future<SentDraft> sendDraft(String draftId) async {
    calls.add('send:$draftId');
    await holdSend?.future;
    return const SentDraft(
      draftId: 'graph-draft-1',
      conversationId: 'conv-1',
      internetMessageId: '<reply-1@bond.local>',
      subject: 'Re: Launch date',
      to: [Recipient(address: 'sarah@x.com')],
      sentAt: '2026-08-30T12:00:00Z',
    );
  }
}

const String _sendGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send';

void main() {
  /// Short enough that a suite is not held for five seconds a send, long
  /// enough that the awaits inside a test land well before it fires.
  const window = Duration(milliseconds: 50);

  late BondDatabase db;
  late MessageStore store;
  late InMemoryTokenStore tokens;
  late RecordingMail mail;

  final never = MockClient((_) async => http.Response('never dialled', 500));

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    tokens = InMemoryTokenStore();
    tokens.values['refresh_token'] = 'rt';
    tokens.values['granted_scopes'] = _sendGrant;
    mail = RecordingMail(
      GraphAuth(httpClient: never, store: tokens),
      httpClient: never,
    );
  });

  tearDown(() => db.close());

  DraftNotifier notifierFor({bool disposeAtEnd = true}) {
    final notifier = DraftNotifier(
      store,
      GraphAuth(httpClient: never, store: tokens),
      mail,
      (source: 'email', conversationKey: 'conv-1'),
      undoWindow: window,
    );
    if (disposeAtEnd) addTearDown(notifier.dispose);
    return notifier;
  }

  Future<void> seedDraft() async {
    await store.upsertConversation({
      'conversation_key': 'conv-1',
      'subject': 'Launch date',
      'state': 'needs_reply',
      'cta_text': 'Sarah is waiting on a date.',
      'cta_urgency': 'high',
    });
    await store.upsertMessage({
      'source_message_id': 'inbound-1',
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'from_address': 'sarah@x.com',
      'received_at': '2026-08-29T10:00:00Z',
    });
    await store.upsertDraft(
      source: 'email',
      conversationKey: 'conv-1',
      replyToMessageId: 'inbound-1',
      body: 'Friday works.',
    );
  }

  /// Waits past the window with room to spare, then lets the send's own awaits
  /// settle.
  Future<void> elapse() async {
    await Future<void>.delayed(window * 4);
    await Future<void>.delayed(Duration.zero);
  }

  group('the window', () {
    test('nothing reaches Graph while it is open', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('Friday works.');

      expect(mail.calls, isEmpty);
      expect(notifier.state.pending?.body, 'Friday works.');
    });

    test('a cancel inside it means the reply never goes', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('Friday works.');
      notifier.cancelQueuedSend();
      await elapse();

      expect(mail.calls, isEmpty);
      expect(notifier.state.pending, isNull);
      expect((await store.getDraft('email', 'conv-1'))!['status'], 'suggested');
    });

    test('cancelling twice is the same as cancelling once', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('Friday works.');
      notifier.cancelQueuedSend();
      notifier.cancelQueuedSend();
      await elapse();

      expect(mail.calls, isEmpty);
    });

    test('cancelling when nothing is queued does nothing at all', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      notifier.cancelQueuedSend();

      expect(notifier.state.pending, isNull);
      expect(mail.calls, isEmpty);
    });

    test('letting it close sends exactly once', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('Friday works. — Jo');
      await elapse();

      expect(mail.calls, [
        'createReply:inbound-1',
        'updateBody:graph-draft-1',
        'send:graph-draft-1',
      ]);
      expect(mail.bodies, ['Friday works. — Jo']);
      expect(notifier.state.pending, isNull);
      expect((await store.getDraft('email', 'conv-1'))!['status'], 'sent');
    });

    test('a second queued send is refused while one is pending', () async {
      // A second pending send would need a second undo, and the bar only
      // offers one.
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('the first one');
      await notifier.queueSend('the second one');

      expect(notifier.state.pending?.body, 'the first one');

      await elapse();
      expect(mail.bodies, ['the first one']);
    });

    test('an empty body is not a send worth queueing', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('   ');
      await elapse();

      expect(notifier.state.pending, isNull);
      expect(mail.calls, isEmpty);
    });

    test('the bubble outlives the undo window until the send completes',
        () async {
      // `pending` clears the instant the timer fires — it has to, or a late
      // undo would half-cancel a reply already on the wire. Without
      // `inFlightBody` picking the text up in the same write, the bubble would
      // blink out for the length of the network call and blink back when the
      // stored row arrived, which reads as a send that failed.
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();
      mail.holdSend = Completer<void>();

      await notifier.queueSend('Friday works.');
      expect(notifier.state.pending?.body, 'Friday works.');
      expect(notifier.state.inFlightBody, isNull,
          reason: 'nothing is in flight while the window is open');

      await elapse();

      expect(notifier.state.pending, isNull, reason: 'the window closed');
      expect(notifier.state.inFlightBody, 'Friday works.');
      expect(mail.calls, contains('send:graph-draft-1'));

      mail.holdSend!.complete();
      await elapse();

      // Cleared only once the row it hands over to is stored.
      expect(notifier.state.inFlightBody, isNull);
      expect(
        await db
            .customSelect(
              "SELECT source_message_id FROM messages "
              "WHERE direction = 'outbound'",
            )
            .getSingle()
            .then((r) => r.data['source_message_id']),
        'local:graph-draft-1',
      );
    });

    test('a cancelled send never puts one up at all', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('Friday works.');
      notifier.cancelQueuedSend();
      await elapse();

      expect(notifier.state.inFlightBody, isNull);
    });
  });

  /// Which text the transcript draws under the thread, and — the half that is
  /// easy to get wrong — when it must draw none.
  ///
  /// Pure state: no store, no notifier. The rule it encodes is that the bubble
  /// and the stored row are the same reply, so they may never be on screen
  /// together.
  group('bubbleBody', () {
    Message outbound(String body) =>
        Message(id: 'm1', outbound: true, source: 'email', bodyText: body);

    Message inbound(String body) =>
        Message(id: 'm0', outbound: false, source: 'email', bodyText: body);

    test('the undo window\'s text wins while it is open', () {
      // Whatever else is in the transcript. The user can still take this back,
      // so it is the thing to show.
      final state = DraftState(
        pending: (body: 'Friday works.', sendsAt: DateTime(2026, 8, 30)),
        inFlightBody: 'an older send',
      );

      expect(state.bubbleBody([outbound('Friday works.')]), 'Friday works.');
    });

    test('the in-flight text shows until its row is stored', () {
      const state = DraftState(inFlightBody: 'Friday works.');

      expect(state.bubbleBody(const []), 'Friday works.');
      // The message being answered says the same words back — a quote, or a
      // one-word "Thanks". It is not the reply.
      expect(
        state.bubbleBody([inbound('Friday works.')]),
        'Friday works.',
      );
      // And an earlier reply of the user's own is a different message.
      expect(
        state.bubbleBody([outbound('Monday, actually.')]),
        'Friday works.',
      );
    });

    test('and steps aside the moment that row arrives', () {
      // Both send arms store the row before `onSent`, and the transcript
      // re-reads on the epoch bump — so without this the reply would be on
      // screen twice for the length of the post-send sync.
      const state = DraftState(inFlightBody: 'Friday works.');

      expect(
        state.bubbleBody([inbound('Any word?'), outbound('Friday works.')]),
        isNull,
      );
    });

    test('nothing in flight draws nothing', () {
      expect(const DraftState().bubbleBody(const []), isNull);
      expect(const DraftState().bubbleBody([outbound('Friday works.')]), isNull);
    });
  });

  group('disposal', () {
    test('cancels the queued send rather than flushing it', () async {
      // The last thing the user did was navigate away. Firing a send on the
      // way out is the one behaviour nobody could have taken back.
      await seedDraft();
      final notifier = notifierFor(disposeAtEnd: false);
      await notifier.load();

      await notifier.queueSend('Friday works.');
      notifier.dispose();
      await elapse();

      expect(mail.calls, isEmpty);
      expect((await store.getDraft('email', 'conv-1'))!['status'], 'suggested');
    });
  });

  group('what a completed send does to the thread', () {
    test('flips it to waiting and clears the CTA', () async {
      // The reply leaving IS the needs-you exit, and it says so now rather
      // than whenever the next sync folds the sent copy in.
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.queueSend('Friday works.');
      await elapse();

      final row = (await db
              .customSelect(
                  'SELECT state, cta_text, cta_urgency FROM conversations '
                  "WHERE source = 'email' AND conversation_key = 'conv-1'")
              .getSingle())
          .data;
      expect(row['state'], 'waiting');
      expect(row['cta_text'], null);
      expect(row['cta_urgency'], 'normal');
    });
  });
}
