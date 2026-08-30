import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/attention.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// A [MailSync] that never touches a socket. These tests are about what the
/// corrections write, so nothing here needs the network to do anything at all.
class SilentSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

void main() {
  late Database db;
  late MessageStore store;
  late SilentSync sync;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
    sync = SilentSync();
  });

  tearDown(() => db.close());

  /// One thread with one inbound message from [from].
  void seed(
    String key, {
    String from = 'eric@x.com',
    String state = 'waiting',
    String receivedAt = '2026-08-28T10:00:00Z',
  }) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
    store.upsertMessage({
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_address': from,
      'received_at': receivedAt,
    });
  }

  ConversationsNotifier notifier() =>
      ConversationsNotifier(store, sync, attention: AttentionService(store));

  List<Map<String, Object?>> events() => [
        for (final row
            in db.select('SELECT * FROM feedback_events ORDER BY id ASC'))
          Map<String, Object?>.from(row),
      ];

  List<Conversation> rows(ConversationsNotifier n) =>
      (n.state as ConversationsLoaded).conversations;

  Conversation rowFor(ConversationsNotifier n, String id) =>
      rows(n).firstWhere((c) => c.id == id);

  group('sendSenderToLater', () {
    test('records the event, sets the rule, moves the threads, reloads',
        () async {
      seed('c1');
      seed('c2');
      seed('c3', from: 'dana@y.com');
      final n = notifier();
      await n.load();

      final affected = await n.sendSenderToLater('eric@x.com');

      expect(affected, 2);
      expect(store.getSenderPref('eric@x.com'), 'later');

      final event = events().single;
      expect(event['scope'], 'sender');
      expect(event['scope_key'], 'eric@x.com');
      expect(event['direction'], 'down');
      expect(event['origin'], 'explicit');

      // Reloaded, so the rows on screen already carry the new bucket.
      expect(rowFor(n, 'c1').bucket, 'later');
      expect(rowFor(n, 'c2').bucket, 'later');
      expect(rowFor(n, 'c3').bucket, isNull);
    });

    test('the event key is lowercased whatever the caller passed', () async {
      seed('c1');
      final n = notifier();
      await n.load();

      await n.sendSenderToLater('Eric@X.com');

      expect(events().single['scope_key'], 'eric@x.com');
    });

    test('deferred threads leave the rail sections they were in', () async {
      seed('c1', state: 'needs_reply');
      final n = notifier();
      await n.load();
      expect(needsYouRows(rows(n)), hasLength(1));

      await n.sendSenderToLater('eric@x.com');

      expect(needsYouRows(rows(n)), isEmpty);
      expect(conversationRows(rows(n)), isEmpty);
      expect(laterRows(rows(n)), hasLength(1));
    });
  });

  group('keepSenderInInbox', () {
    test('records, sets keep, and brings the threads back', () async {
      seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');

      final affected = await n.keepSenderInInbox('eric@x.com');

      expect(affected, 1);
      expect(store.getSenderPref('eric@x.com'), 'keep');
      expect(rowFor(n, 'c1').bucket, isNull);
      expect(events().map((e) => e['direction']), ['down', 'up']);
    });

    test('a keep rule survives the scoring sweep that runs on every load',
        () async {
      seed('c1');
      final n = notifier();
      await n.load();
      await n.keepSenderInInbox('eric@x.com');

      await n.load();

      expect(rowFor(n, 'c1').bucket, isNull);
    });
  });

  group('undo', () {
    test('restores "there was no rule", which is not "the rule was keep"',
        () async {
      seed('c1');
      final n = notifier();
      await n.load();

      final previous = n.senderPref('eric@x.com');
      expect(previous, isNull);
      await n.sendSenderToLater('eric@x.com');
      expect(store.getSenderPref('eric@x.com'), 'later');

      await n.restoreSenderPref('eric@x.com', previous);

      expect(store.getSenderPref('eric@x.com'), isNull);
      expect(rowFor(n, 'c1').bucket, isNull);
    });

    test('restores an earlier rule rather than clearing it', () async {
      seed('c1');
      final n = notifier();
      await n.load();
      await n.keepSenderInInbox('eric@x.com');

      final previous = n.senderPref('eric@x.com');
      await n.sendSenderToLater('eric@x.com');
      await n.restoreSenderPref('eric@x.com', previous);

      expect(store.getSenderPref('eric@x.com'), 'keep');
      expect(rowFor(n, 'c1').bucket, isNull);
    });

    test('restoring a later rule re-defers the threads', () async {
      seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');

      final previous = n.senderPref('eric@x.com');
      await n.keepSenderInInbox('eric@x.com');
      await n.restoreSenderPref('eric@x.com', previous);

      expect(store.getSenderPref('eric@x.com'), 'later');
      expect(rowFor(n, 'c1').bucket, 'later');
    });

    test('the undo is itself recorded, in the opposite direction', () async {
      seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');
      await n.restoreSenderPref('eric@x.com', null);

      expect(events().map((e) => e['direction']), ['down', 'up']);
      expect(events().every((e) => e['origin'] == 'explicit'), isTrue);
    });
  });

  group('thread-scoped corrections', () {
    test('sendThreadToLater buckets exactly one thread, as the user', () async {
      seed('c1');
      seed('c2');
      final n = notifier();
      await n.load();

      await n.sendThreadToLater('email', 'c1');

      expect(rowFor(n, 'c1').bucket, 'later');
      expect(rowFor(n, 'c2').bucket, isNull);
      expect(store.bucketReasons()['c1'], 'user');
      // No sender rule was set: this was about the thread, not the person.
      expect(store.getSenderPref('eric@x.com'), isNull);

      final event = events().single;
      expect(event['scope'], 'thread');
      expect(event['scope_key'], 'c1');
      expect(event['direction'], 'down');
    });

    test('keepThreadInInbox lifts a thread out of a sender-wide rule',
        () async {
      seed('c1');
      seed('c2');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');

      await n.keepThreadInInbox('email', 'c1');

      expect(rowFor(n, 'c1').bucket, isNull);
      expect(rowFor(n, 'c2').bucket, 'later');
    });

    test('and the exemption survives the sweep on every later load', () async {
      // The bug this guards: the sweep runs on every load, sees the sender rule
      // still in force, and re-defers the thread — which would make the button
      // look like it did nothing.
      seed('c1');
      seed('c2');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');
      await n.keepThreadInInbox('email', 'c1');

      await n.load();
      await n.load();

      expect(rowFor(n, 'c1').bucket, isNull);
      expect(rowFor(n, 'c2').bucket, 'later',
          reason: 'the rest of the sender rule is untouched');
    });

    test('a later sender-wide correction still overrides the exemption',
        () async {
      // A newer instruction about a wider set. The person saying "all of this
      // sender's mail" means all of it, including the one they excepted before.
      seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');
      await n.keepThreadInInbox('email', 'c1');

      await n.sendSenderToLater('eric@x.com');

      expect(rowFor(n, 'c1').bucket, 'later');
    });

    test('a hand-deferred thread survives every later load', () async {
      seed('c1');
      final n = notifier();
      await n.load();
      await n.sendThreadToLater('email', 'c1');

      await n.load();

      expect(rowFor(n, 'c1').bucket, 'later');
      expect(store.bucketReasons()['c1'], 'user');
    });
  });

  group('implicit signals', () {
    test('opening a thread records a quiet up', () {
      final n = notifier();
      n.noteThreadOpened('c1');

      final event = events().single;
      expect(event['scope'], 'thread');
      expect(event['scope_key'], 'c1');
      expect(event['direction'], 'up');
      expect(event['origin'], 'implicit');
    });

    test('marking done records a quiet down', () async {
      seed('c1', state: 'needs_reply');
      final n = notifier();
      await n.load();

      await n.markDone('c1');

      final event = events().single;
      expect(event['direction'], 'down');
      expect(event['origin'], 'implicit');
    });

    test('a mark-done that failed to save records nothing', () async {
      seed('c1', state: 'needs_reply');
      final n = ConversationsNotifier(_UnwritableStore(db), sync);
      await n.load();

      await n.markDone('c1');

      expect(events(), isEmpty,
          reason: 'the app must not learn from something that did not happen');
    });
  });

  group('scoring runs before the rows are read', () {
    test('a load leaves scores on the rows it returns', () async {
      seed('c1', state: 'needs_reply');
      final n = notifier();

      await n.load();

      expect(rowFor(n, 'c1').attentionScore, isNotNull);
    });

    test('with no service wired the load still works', () async {
      seed('c1');
      final n = ConversationsNotifier(store, sync);
      await n.load();

      expect(rows(n), hasLength(1));
      expect(rowFor(n, 'c1').attentionScore, isNull);
    });
  });

  group('the threshold re-filters Needs You', () {
    test('a thread below the cut leaves Needs You but stays in Conversations',
        () async {
      // A waiting thread with an ask scores around the waiting base, which is
      // below the default cut.
      store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'waiting',
        'cta_text': 'Send the appraisal',
        'last_message_at': DateTime.now().toUtc().toIso8601String(),
      });
      final n = notifier();
      await n.load();

      final all = rows(n);
      expect(needsYouRows(all), hasLength(1),
          reason: 'with no threshold everything eligible is in');
      expect(
        needsYouRows(all, threshold: AttentionTuning.defaultThreshold),
        isEmpty,
      );
      expect(conversationRows(all), hasLength(1),
          reason: 'nothing the threshold cuts is ever hidden entirely');
    });
  });

  group('prefs provider', () {
    test('reads what is stored, writes what is set', () {
      store.setPref(attentionThresholdKey, '0.8');
      store.setPref(aboutMeKey, 'I am a loan officer.');

      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      expect(container.read(appPrefsProvider).attentionThreshold, 0.8);
      expect(container.read(appPrefsProvider).aboutMe, 'I am a loan officer.');

      container.read(appPrefsProvider.notifier).setAttentionThreshold(0.3);
      expect(container.read(appPrefsProvider).attentionThreshold, 0.3);
      expect(store.getPref(attentionThresholdKey), '0.3');
    });

    test('an unreadable stored threshold falls back to the default', () {
      store.setPref(attentionThresholdKey, 'somewhat');

      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(appPrefsProvider).attentionThreshold,
        AttentionTuning.defaultThreshold,
      );
    });

    test('a value outside the slider range is clamped before it is stored', () {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      container.read(appPrefsProvider.notifier).setAttentionThreshold(9);
      expect(container.read(appPrefsProvider).attentionThreshold, 1.0);
    });
  });

  group('provider wiring', () {
    test('the attention service is wired into the real conversations provider',
        () async {
      seed('c1', state: 'needs_reply');
      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        syncServiceProvider.overrideWithValue(sync),
      ]);
      addTearDown(container.dispose);

      await container.read(conversationsProvider.notifier).load();
      final state = container.read(conversationsProvider) as ConversationsLoaded;

      expect(state.conversations.single.attentionScore, isNotNull);
    });
  });
}

/// A store whose state write fails, for the "records nothing on failure" case.
class _UnwritableStore extends MessageStore {
  _UnwritableStore(super.db);

  @override
  void setConversationState(
    String source,
    String conversationKey,
    ConversationState state,
  ) {
    throw StateError('disk is full');
  }
}
