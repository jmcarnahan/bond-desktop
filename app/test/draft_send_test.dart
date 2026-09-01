import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/draft_provider.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/composer.dart' show SendCapability;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/test_db.dart';

/// The send path, end to end below the widget.
///
/// The load-bearing assertion is the last group: constructing the notifier,
/// loading it, generating, editing and dismissing all leave [RecordingMail]
/// untouched. Only [DraftNotifier.send] — which only the composer's button
/// calls — reaches Graph.

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

  /// Thrown instead of answering, when set.
  Object? failure;

  /// What `createReply` answers with.
  Map<String, dynamic> reply = const {
    'id': 'graph-draft-1',
    'webLink': 'https://outlook.example/draft-1',
  };

  RecordingMail(super.auth, {required super.httpClient});

  @override
  Future<Map<String, dynamic>> createReplyDraft(String messageId) async {
    calls.add('createReply:$messageId');
    final error = failure;
    if (error != null) throw error;
    return reply;
  }

  @override
  Future<void> updateDraftBody(String draftId, String text) async {
    calls.add('updateBody:$draftId');
    bodies.add(text);
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> sendDraft(String draftId) async {
    calls.add('send:$draftId');
    final error = failure;
    if (error != null) throw error;
  }
}

const String _sendGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send';

const String _readWriteGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/Mail.ReadWrite';

const String _coreGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

void main() {
  late BondDatabase db;
  late MessageStore store;
  late InMemoryTokenStore tokens;
  late RecordingMail mail;
  late List<Uri> launched;
  late int syncsAfterSend;

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
    launched = [];
    syncsAfterSend = 0;
  });

  tearDown(() => db.close());

  DraftNotifier notifierFor({String key = 'conv-1'}) {
    final notifier = DraftNotifier(
      store,
      GraphAuth(httpClient: never, store: tokens),
      mail,
      (source: 'email', conversationKey: key),
      onSent: () async => syncsAfterSend++,
      launch: (url) async {
        launched.add(url);
        return true;
      },
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  Future<void> seedDraft({
    String key = 'conv-1',
    String body = 'Friday works.',
  }) async {
    await store.upsertDraft(
      source: 'email',
      conversationKey: key,
      replyToMessageId: 'inbound-1',
      body: body,
      evidence: 'Sarah wants the lock extended.',
    );
  }

  group('capability', () {
    test('Mail.Send is the top rung', () async {
      final notifier = notifierFor();
      await notifier.load();

      expect(notifier.state.capability, SendCapability.send);
    });

    test('Mail.ReadWrite alone drops to the Outlook hand-off', () async {
      tokens.values['granted_scopes'] = _readWriteGrant;
      final notifier = notifierFor();
      await notifier.load();

      expect(notifier.state.capability, SendCapability.draftToOutlook);
    });

    test('a degraded grant can only copy', () async {
      tokens.values['granted_scopes'] = _coreGrant;
      final notifier = notifierFor();
      await notifier.load();

      expect(notifier.state.capability, SendCapability.copyOnly);
    });

    test('and so can a signed-out app', () async {
      tokens.values.clear();
      final notifier = notifierFor();
      await notifier.load();

      expect(notifier.state.capability, SendCapability.copyOnly);
    });
  });

  group('send', () {
    test('creates, fills and sends — in that order', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      final outcome = await notifier.send('Friday works. — Jo');

      expect(outcome, SendOutcome.sent);
      expect(mail.calls, [
        'createReply:inbound-1',
        'updateBody:graph-draft-1',
        'send:graph-draft-1',
      ]);
      expect(mail.bodies, ['Friday works. — Jo']);
    });

    test('sends what it was handed, not what was stored', () async {
      // The whole reason the body is an argument: a send can only ever carry
      // the text that was on screen in front of whoever pressed the button.
      await seedDraft(body: 'the suggestion nobody approved');
      final notifier = notifierFor();
      await notifier.load();

      await notifier.send('what I actually wrote');

      expect(mail.bodies, ['what I actually wrote']);
    });

    test('marks the draft sent and records the implicit signal', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.send('Friday works.');

      final draft = (await store.getDraft('email', 'conv-1'))!;
      expect(draft['status'], 'sent');
      expect(draft['graph_draft_id'], 'graph-draft-1');
      final feedback = await db.customSelect(
        'SELECT * FROM feedback_events WHERE scope_key = ?',
        variables: [Variable('conv-1')],
      ).get();
      expect(feedback.single.data['origin'], 'implicit');
      expect(feedback.single.data['direction'], 'up');
    });

    test('refreshes the inbox afterwards rather than faking a row', () async {
      // No optimistic message is written: the sent mail lands in sentitems and
      // folds in normally, so nothing can be left behind if the sync disagrees.
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.send('Friday works.');

      expect(syncsAfterSend, 1);
      expect(
        await db
            .customSelect("SELECT * FROM messages WHERE direction = 'outbound'")
            .get(),
        isEmpty,
      );
    });

    test('a Graph failure leaves the draft unsent, with a readable reason',
        () async {
      await seedDraft();
      mail.failure = const GraphMailException('Mailbox is over quota.');
      final notifier = notifierFor();
      await notifier.load();

      final outcome = await notifier.send('Friday works.');

      expect(outcome, SendOutcome.failed);
      expect(notifier.state.error, 'Mailbox is over quota.');
      expect(notifier.state.sending, isFalse);
      expect((await store.getDraft('email', 'conv-1'))!['status'], 'suggested');
      expect(syncsAfterSend, 0);
    });

    test('an auth failure surfaces its own message', () async {
      await seedDraft();
      mail.failure = const NotSignedIn();
      final notifier = notifierFor();
      await notifier.load();

      expect(await notifier.send('Friday works.'), SendOutcome.failed);
      expect(notifier.state.error, contains('not signed in'));
    });

    test('a thread with no inbound mail at all refuses rather than guessing',
        () async {
      final notifier = notifierFor();
      await notifier.load();

      expect(await notifier.send('Friday works.'), SendOutcome.failed);
      expect(mail.calls, isEmpty);
    });

    test('no draft row falls back to the newest inbound message', () async {
      // Threads below the attention threshold never earn a generated draft,
      // but the LO can still reply to them — the send targets exactly what
      // the draft handler itself would have replied to.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'older-inbound',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'received_at': '2026-08-29T10:00:00Z',
      });
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'newest-inbound',
        'conversation_key': 'conv-1',
        'direction': 'inbound',
        'received_at': '2026-08-30T10:00:00Z',
      });
      final notifier = notifierFor();
      await notifier.load();

      final outcome = await notifier.send('Typed from scratch.');

      expect(outcome, SendOutcome.sent);
      expect(mail.calls.first, 'createReply:newest-inbound');
      expect(mail.bodies, ['Typed from scratch.']);
    });

    test('a completed send retires the composer text for good', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();
      final epochBefore = notifier.state.sendEpoch;

      await notifier.send('Friday works.');

      // The epoch bump is what rebuilds the reply box empty — the sent text
      // must not sit armed behind a re-enabled button.
      expect(notifier.state.sendEpoch, epochBefore + 1);
      // And the sent row reads as "no suggestion", so nothing re-offers it.
      expect(notifier.state.body, isNull);

      // The composer's trailing edit debounce can fire after the send lands;
      // it must not rewrite the record of what was actually sent.
      await notifier.markEdited('Friday works. — but different now');
      expect((await store.getDraft('email', 'conv-1'))!['status'], 'sent');
    });

    test('a failed send keeps the text on the table', () async {
      await seedDraft();
      mail.failure = const GraphMailException('Graph said no.');
      final notifier = notifierFor();
      await notifier.load();

      expect(await notifier.send('Friday works.'), SendOutcome.failed);
      // No epoch bump: the composer keeps the words for the retry.
      expect(notifier.state.sendEpoch, 0);
      expect(notifier.state.body, 'Friday works.');
    });

    test('empty text never reaches Graph', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      expect(await notifier.send('   '), SendOutcome.failed);
      expect(mail.calls, isEmpty);
    });
  });

  group('the lesser rungs', () {
    test('Mail.ReadWrite saves to Outlook and opens it, without sending',
        () async {
      tokens.values['granted_scopes'] = _readWriteGrant;
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      final outcome = await notifier.send('Friday works.');

      expect(outcome, SendOutcome.savedToOutlook);
      expect(mail.calls, [
        'createReply:inbound-1',
        'updateBody:graph-draft-1',
      ]);
      expect(mail.calls, isNot(contains('send:graph-draft-1')));
      expect(launched.single.toString(), 'https://outlook.example/draft-1');
      final draft = (await store.getDraft('email', 'conv-1'))!;
      // Not `sent` — it was not sent, and saying so would be a lie the next
      // reader acts on.
      expect(draft['status'], 'suggested');
      expect(draft['web_link'], 'https://outlook.example/draft-1');
    });

    test('copyOnly touches neither Graph nor the browser', () async {
      final copied = <String>[];
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      tokens.values['granted_scopes'] = _coreGrant;
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      expect(await notifier.send('Friday works.'), SendOutcome.copied);
      expect(copied, ['Friday works.']);
      expect(mail.calls, isEmpty);
      expect(launched, isEmpty);
    });
  });

  group('the draft itself', () {
    test('loads what the queue wrote', () async {
      await seedDraft();
      final notifier = notifierFor();

      await notifier.load();

      expect(notifier.state.body, 'Friday works.');
      expect(notifier.state.evidence, 'Sarah wants the lock extended.');
      expect(notifier.state.replyToMessageId, 'inbound-1');
    });

    test('an edit is stored and stops it being the model\'s', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.markEdited('Monday, actually.');

      final draft = (await store.getDraft('email', 'conv-1'))!;
      expect(draft['status'], 'edited');
      expect(draft['body'], 'Monday, actually.');
      expect(notifier.state.body, 'Monday, actually.');
    });

    test('a dismissed draft reads as no draft, and the row survives', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.dismiss();

      expect(notifier.state.body, isNull);
      // The row stays so the next list load does not immediately write another.
      expect((await store.getDraft('email', 'conv-1'))!['status'], 'dismissed');
    });

    test('generate clears the old draft and queues a fresh one', () async {
      await seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.generate();

      expect(await store.getDraft('email', 'conv-1'), isNull);
      expect(
        (await db
                .customSelect(
                  "SELECT status FROM work_items WHERE task_kind = 'draft'",
                )
                .get())
            .single
            .data['status'],
        'pending',
      );
      expect(notifier.state.body, isNull);
    });
  });

  group('nothing sends on its own', () {
    test('constructing, loading, generating, editing and dismissing reach '
        'Graph never', () async {
      await seedDraft();
      final notifier = notifierFor();

      await notifier.load();
      await notifier.generate();
      await seedDraft();
      await notifier.load();
      await notifier.markEdited('a reply I never sent');
      await notifier.dismiss();
      // Well past every debounce and timer this notifier owns.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(mail.calls, isEmpty);
      expect(launched, isEmpty);
      expect(syncsAfterSend, 0);
      expect(
        (await store.getDraft('email', 'conv-1'))!['status'],
        isNot('sent'),
      );
    });
  });
}
