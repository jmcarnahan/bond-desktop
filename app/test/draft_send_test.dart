import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/draft_provider.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_mail.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:bond_inbox/widgets/composer.dart' show SendCapability;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

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
  late Database db;
  late MessageStore store;
  late InMemoryTokenStore tokens;
  late RecordingMail mail;
  late List<Uri> launched;
  late int syncsAfterSend;

  final never = MockClient((_) async => http.Response('never dialled', 500));

  setUp(() {
    db = openDbAt(':memory:');
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
      key,
      onSent: () async => syncsAfterSend++,
      launch: (url) async {
        launched.add(url);
        return true;
      },
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  void seedDraft({String key = 'conv-1', String body = 'Friday works.'}) {
    store.upsertDraft(
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
      seedDraft();
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
      seedDraft(body: 'the suggestion nobody approved');
      final notifier = notifierFor();
      await notifier.load();

      await notifier.send('what I actually wrote');

      expect(mail.bodies, ['what I actually wrote']);
    });

    test('marks the draft sent and records the implicit signal', () async {
      seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.send('Friday works.');

      final draft = store.getDraft('email', 'conv-1')!;
      expect(draft['status'], 'sent');
      expect(draft['graph_draft_id'], 'graph-draft-1');
      final feedback = db.select(
        'SELECT * FROM feedback_events WHERE scope_key = ?',
        ['conv-1'],
      );
      expect(feedback.single['origin'], 'implicit');
      expect(feedback.single['direction'], 'up');
    });

    test('refreshes the inbox afterwards rather than faking a row', () async {
      // No optimistic message is written: the sent mail lands in sentitems and
      // folds in normally, so nothing can be left behind if the sync disagrees.
      seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.send('Friday works.');

      expect(syncsAfterSend, 1);
      expect(
        db.select("SELECT * FROM messages WHERE direction = 'outbound'"),
        isEmpty,
      );
    });

    test('a Graph failure leaves the draft unsent, with a readable reason',
        () async {
      seedDraft();
      mail.failure = const GraphMailException('Mailbox is over quota.');
      final notifier = notifierFor();
      await notifier.load();

      final outcome = await notifier.send('Friday works.');

      expect(outcome, SendOutcome.failed);
      expect(notifier.state.error, 'Mailbox is over quota.');
      expect(notifier.state.sending, isFalse);
      expect(store.getDraft('email', 'conv-1')!['status'], 'suggested');
      expect(syncsAfterSend, 0);
    });

    test('an auth failure surfaces its own message', () async {
      seedDraft();
      mail.failure = const NotSignedIn();
      final notifier = notifierFor();
      await notifier.load();

      expect(await notifier.send('Friday works.'), SendOutcome.failed);
      expect(notifier.state.error, contains('not signed in'));
    });

    test('a draft with nothing to reply to refuses rather than guessing',
        () async {
      final notifier = notifierFor();
      await notifier.load();

      expect(await notifier.send('Friday works.'), SendOutcome.failed);
      expect(mail.calls, isEmpty);
    });

    test('empty text never reaches Graph', () async {
      seedDraft();
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
      seedDraft();
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
      final draft = store.getDraft('email', 'conv-1')!;
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
      seedDraft();
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
      seedDraft();
      final notifier = notifierFor();

      await notifier.load();

      expect(notifier.state.body, 'Friday works.');
      expect(notifier.state.evidence, 'Sarah wants the lock extended.');
      expect(notifier.state.replyToMessageId, 'inbound-1');
    });

    test('an edit is stored and stops it being the model\'s', () async {
      seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      notifier.markEdited('Monday, actually.');

      final draft = store.getDraft('email', 'conv-1')!;
      expect(draft['status'], 'edited');
      expect(draft['body'], 'Monday, actually.');
      expect(notifier.state.body, 'Monday, actually.');
    });

    test('a dismissed draft reads as no draft, and the row survives', () async {
      seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      notifier.dismiss();

      expect(notifier.state.body, isNull);
      // The row stays so the next list load does not immediately write another.
      expect(store.getDraft('email', 'conv-1')!['status'], 'dismissed');
    });

    test('generate clears the old draft and queues a fresh one', () async {
      seedDraft();
      final notifier = notifierFor();
      await notifier.load();

      await notifier.generate();

      expect(store.getDraft('email', 'conv-1'), isNull);
      expect(
        db
            .select("SELECT status FROM work_items WHERE task_kind = 'draft'")
            .single['status'],
        'pending',
      );
      expect(notifier.state.body, isNull);
    });
  });

  group('nothing sends on its own', () {
    test('constructing, loading, generating, editing and dismissing reach '
        'Graph never', () async {
      seedDraft();
      final notifier = notifierFor();

      await notifier.load();
      await notifier.generate();
      seedDraft();
      await notifier.load();
      notifier.markEdited('a reply I never sent');
      notifier.dismiss();
      // Well past every debounce and timer this notifier owns.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(mail.calls, isEmpty);
      expect(launched, isEmpty);
      expect(syncsAfterSend, 0);
      expect(store.getDraft('email', 'conv-1')!['status'], isNot('sent'));
    });
  });
}
