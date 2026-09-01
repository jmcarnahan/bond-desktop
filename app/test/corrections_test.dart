import 'package:bond_inbox/data/database.dart' show BondDatabase;
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

import 'fixtures/test_db.dart';

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
  late BondDatabase db;
  late MessageStore store;
  late SilentSync sync;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    sync = SilentSync();
  });

  tearDown(() => db.close());

  /// One thread with one inbound message from [from].
  Future<void> seed(
    String key, {
    String from = 'eric@x.com',
    String state = 'waiting',
    String receivedAt = '2026-08-28T10:00:00Z',
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
    await store.upsertMessage({
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_address': from,
      'received_at': receivedAt,
    });
  }

  ConversationsNotifier notifier() =>
      ConversationsNotifier(store, sync, attention: AttentionService(store));

  Future<List<Map<String, Object?>>> events() async => [
        for (final row in await db
            .customSelect('SELECT * FROM feedback_events ORDER BY id ASC')
            .get())
          Map<String, Object?>.from(row.data),
      ];

  List<Conversation> rows(ConversationsNotifier n) =>
      (n.state as ConversationsLoaded).conversations;

  Conversation rowFor(ConversationsNotifier n, String id) =>
      rows(n).firstWhere((c) => c.id == id);

  group('sendSenderToLater', () {
    test('records the event, sets the rule, moves the threads, reloads',
        () async {
      await seed('c1');
      await seed('c2');
      await seed('c3', from: 'dana@y.com');
      final n = notifier();
      await n.load();

      final affected = await n.sendSenderToLater('eric@x.com');

      expect(affected, 2);
      expect(await store.getSenderPref('eric@x.com'), 'later');

      final event = (await events()).single;
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
      await seed('c1');
      final n = notifier();
      await n.load();

      await n.sendSenderToLater('Eric@X.com');

      expect((await events()).single['scope_key'], 'eric@x.com');
    });

    test('a teams sender re-files the TEAMS rows, and reports their count',
        () async {
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-1',
        'subject': 'chat-1',
        'state': 'waiting',
        'last_message_at': '2026-08-28T10:00:00Z',
        'last_inbound_at': '2026-08-28T10:00:00Z',
      });
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'chat-1-m1',
        'conversation_key': 'chat-1',
        'direction': 'inbound',
        'from_address': 'teams:29:abc',
        'received_at': '2026-08-28T10:00:00Z',
      });
      final n = notifier();
      await n.load();

      // Keyed against the email rows this would match nothing and the toast
      // would report "0 threads moved" over a move that eventually happens
      // anyway via the sweep.
      final affected =
          await n.sendSenderToLater('teams:29:abc', source: 'teams');

      expect(affected, 1);
      final bucket = (await db.customSelect(
        "SELECT bucket FROM conversation_ai WHERE source = 'teams' "
        "AND conversation_key = 'chat-1'",
      ).get()).single.data['bucket'];
      expect(bucket, 'later');
    });

    test('deferred threads leave the rail sections they were in', () async {
      await seed('c1', state: 'needs_reply');
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
      await seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');

      final affected = await n.keepSenderInInbox('eric@x.com');

      expect(affected, 1);
      expect(await store.getSenderPref('eric@x.com'), 'keep');
      expect(rowFor(n, 'c1').bucket, isNull);
      expect((await events()).map((e) => e['direction']), ['down', 'up']);
    });

    test('a keep rule survives the scoring sweep that runs on every load',
        () async {
      await seed('c1');
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
      await seed('c1');
      final n = notifier();
      await n.load();

      final previous = await n.senderPref('eric@x.com');
      expect(previous, isNull);
      await n.sendSenderToLater('eric@x.com');
      expect(await store.getSenderPref('eric@x.com'), 'later');

      await n.restoreSenderPref('eric@x.com', previous);

      expect(await store.getSenderPref('eric@x.com'), isNull);
      expect(rowFor(n, 'c1').bucket, isNull);
    });

    test('restores an earlier rule rather than clearing it', () async {
      await seed('c1');
      final n = notifier();
      await n.load();
      await n.keepSenderInInbox('eric@x.com');

      final previous = await n.senderPref('eric@x.com');
      await n.sendSenderToLater('eric@x.com');
      await n.restoreSenderPref('eric@x.com', previous);

      expect(await store.getSenderPref('eric@x.com'), 'keep');
      expect(rowFor(n, 'c1').bucket, isNull);
    });

    test('restoring a later rule re-defers the threads', () async {
      await seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');

      final previous = await n.senderPref('eric@x.com');
      await n.keepSenderInInbox('eric@x.com');
      await n.restoreSenderPref('eric@x.com', previous);

      expect(await store.getSenderPref('eric@x.com'), 'later');
      expect(rowFor(n, 'c1').bucket, 'later');
    });

    test('the undo is itself recorded, in the opposite direction', () async {
      await seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');
      await n.restoreSenderPref('eric@x.com', null);

      expect((await events()).map((e) => e['direction']), ['down', 'up']);
      expect((await events()).every((e) => e['origin'] == 'explicit'), isTrue);
    });
  });

  group('thread-scoped corrections', () {
    test('sendThreadToLater buckets exactly one thread, as the user', () async {
      await seed('c1');
      await seed('c2');
      final n = notifier();
      await n.load();

      await n.sendThreadToLater('email', 'c1');

      expect(rowFor(n, 'c1').bucket, 'later');
      expect(rowFor(n, 'c2').bucket, isNull);
      expect((await store.bucketReasons())['c1'], 'user');
      // No sender rule was set: this was about the thread, not the person.
      expect(await store.getSenderPref('eric@x.com'), isNull);

      final event = (await events()).single;
      expect(event['scope'], 'thread');
      expect(event['scope_key'], 'c1');
      expect(event['direction'], 'down');
    });

    test('keepThreadInInbox lifts a thread out of a sender-wide rule',
        () async {
      await seed('c1');
      await seed('c2');
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
      await seed('c1');
      await seed('c2');
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
      await seed('c1');
      final n = notifier();
      await n.load();
      await n.sendSenderToLater('eric@x.com');
      await n.keepThreadInInbox('email', 'c1');

      await n.sendSenderToLater('eric@x.com');

      expect(rowFor(n, 'c1').bucket, 'later');
    });

    test('a hand-deferred thread survives every later load', () async {
      await seed('c1');
      final n = notifier();
      await n.load();
      await n.sendThreadToLater('email', 'c1');

      await n.load();

      expect(rowFor(n, 'c1').bucket, 'later');
      expect((await store.bucketReasons())['c1'], 'user');
    });
  });

  group('implicit signals', () {
    test('opening a thread records a quiet up', () async {
      final n = notifier();
      await n.noteThreadOpened('c1');

      final event = (await events()).single;
      expect(event['scope'], 'thread');
      expect(event['scope_key'], 'c1');
      expect(event['direction'], 'up');
      expect(event['origin'], 'implicit');
    });

    test('marking done records a quiet down', () async {
      await seed('c1', state: 'needs_reply');
      final n = notifier();
      await n.load();

      await n.markDone('c1');

      final event = (await events()).single;
      expect(event['direction'], 'down');
      expect(event['origin'], 'implicit');
    });

    test('a mark-done that failed to save records nothing', () async {
      await seed('c1', state: 'needs_reply');
      final n = ConversationsNotifier(_UnwritableStore(db), sync);
      await n.load();

      await n.markDone('c1');

      expect(await events(), isEmpty,
          reason: 'the app must not learn from something that did not happen');
    });
  });

  group('markRead', () {
    test('zeroes the row before the write, and the store agrees after it',
        () async {
      await seed('c1');
      final n = notifier();
      await n.load();
      expect(rowFor(n, 'c1').unreadCount, 1);

      final pending = n.markRead('email', 'c1');
      expect(rowFor(n, 'c1').hasUnread, isFalse,
          reason: 'the row un-bolds on the click, not on the write');

      await pending;
      expect((await store.loadConversations()).single.unreadCount, 0);
    });

    test('leaves every other thread unread', () async {
      await seed('c1');
      await seed('c2');
      final n = notifier();
      await n.load();

      await n.markRead('email', 'c1');

      expect(rowFor(n, 'c1').unreadCount, 0);
      expect(rowFor(n, 'c2').unreadCount, 1);
    });
  });

  group('scoring runs before the rows are read', () {
    test('a load leaves scores on the rows it returns', () async {
      await seed('c1', state: 'needs_reply');
      final n = notifier();

      await n.load();

      expect(rowFor(n, 'c1').attentionScore, isNotNull);
    });

    test('with no service wired the load still works', () async {
      await seed('c1');
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
      await store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'waiting',
        'cta_text': 'Send the homepage copy',
        'last_message_at': DateTime.now().toUtc().toIso8601String(),
      });
      final n = notifier();
      await n.load();

      final all = rows(n);
      expect(needsYouRows(all), hasLength(1),
          reason: 'with no threshold everything eligible is in');
      expect(conversationRows(all), isEmpty,
          reason: 'and what Needs You claims, Conversations does not repeat');

      expect(
        needsYouRows(all, threshold: AttentionTuning.defaultThreshold),
        isEmpty,
      );
      expect(
        conversationRows(all, threshold: AttentionTuning.defaultThreshold),
        hasLength(1),
        reason: 'nothing the threshold cuts is ever hidden entirely',
      );
    });
  });

  group('prefs provider', () {
    test('reads what is stored, writes what is set', () async {
      await store.setPref(attentionThresholdKey, '0.8');
      await store.setPref(aboutMeKey, 'I run a small design studio.');

      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      expect(container.read(appPrefsProvider).attentionThreshold, 0.8);
      expect(container.read(appPrefsProvider).aboutMe, 'I run a small design studio.');

      await container.read(appPrefsProvider.notifier).setAttentionThreshold(0.3);
      expect(container.read(appPrefsProvider).attentionThreshold, 0.3);
      expect(await store.getPref(attentionThresholdKey), '0.3');
    });

    test('an unreadable stored threshold falls back to the default', () async {
      await store.setPref(attentionThresholdKey, 'somewhat');

      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      expect(
        container.read(appPrefsProvider).attentionThreshold,
        AttentionTuning.defaultThreshold,
      );
    });

    test('a value outside the slider range is clamped before it is stored',
        () async {
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      await container.read(appPrefsProvider.notifier).ready;

      await container.read(appPrefsProvider.notifier).setAttentionThreshold(9);
      expect(container.read(appPrefsProvider).attentionThreshold, 1.0);
    });
  });

  group('provider wiring', () {
    test('the attention service is wired into the real conversations provider',
        () async {
      await seed('c1', state: 'needs_reply');
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
  Future<void> setConversationState(
    String source,
    String conversationKey,
    ConversationState state,
  ) async {
    throw StateError('disk is full');
  }
}
